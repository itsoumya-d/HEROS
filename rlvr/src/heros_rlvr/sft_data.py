"""Deterministic SFT targets for migration tasks.

The RL reward now requires the final schema to match ``target_schema``. A base
model that cannot produce that schema needs supervised examples before another
RL run. This module derives a target-satisfying SQL script from the old and new
Forge schemas; it does not call a model.

The generated SQL is intentionally conservative:

- add/drop columns use SQLite ``ALTER TABLE`` where possible;
- single-column renames use ``RENAME COLUMN``;
- type, NOT NULL, and primary-key changes use a table rebuild;
- rows are copied for every column that survives the change.

The output is a training target, not a production migration plan. It is tested
against the same target-schema verifier used by the reward.
"""

from __future__ import annotations

import json
import re
from typing import Dict, Iterable, List, Sequence

from .gpu_trainer import MigrationTask
from .qlora_runner import TableSpec, parse_forge_schema

IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def _quote(value: str) -> str:
    if not IDENTIFIER.match(value):
        raise ValueError(f"unsafe identifier: {value!r}")
    return f'"{value}"'


def _column_sql(column, default_for_not_null: bool = False) -> str:
    piece = f"{_quote(column.name)} {column.sqlite_type}"
    if column.primary_key:
        piece += " PRIMARY KEY"
    if column.not_null:
        piece += " NOT NULL"
        if default_for_not_null:
            piece += f" DEFAULT {_default_literal(column.sqlite_type)}"
    return piece


def _default_literal(sqlite_type: str) -> str:
    if sqlite_type == "INTEGER":
        return "0"
    if sqlite_type == "REAL":
        return "0.0"
    if sqlite_type == "BLOB":
        return "X'00'"
    return "''"


def _create_table(
    table: TableSpec, name: str | None = None, defaults_for: set[str] | None = None
) -> str:
    target = _quote(name or table.name)
    defaults_for = defaults_for or set()
    columns = ", ".join(
        _column_sql(column, default_for_not_null=column.name in defaults_for)
        for column in table.columns
    )
    return f"CREATE TABLE {target} ({columns});"


def _same_column(old, new) -> bool:
    return (
        old.sqlite_type == new.sqlite_type
        and old.not_null == new.not_null
        and old.primary_key == new.primary_key
    )


def _rename_map(old: TableSpec, new: TableSpec) -> Dict[str, str] | None:
    old_names = [column.name for column in old.columns]
    new_names = [column.name for column in new.columns]
    removed = [name for name in old_names if name not in new_names]
    added = [name for name in new_names if name not in old_names]
    if len(removed) == 1 and len(added) == 1:
        return {removed[0]: added[0]}
    return None


def _rebuild_table(old: TableSpec, new: TableSpec, rename: Dict[str, str] | None) -> List[str]:
    temporary = f"__heros_tmp_{new.name}"
    if len(temporary) > 60:
        temporary = "__heros_tmp"
    old_names = {column.name for column in old.columns}
    added_not_null = {
        column.name
        for column in new.columns
        if column.name not in old_names and column.not_null
    }
    statements = [_create_table(new, temporary, defaults_for=added_not_null)]
    copy_pairs = []
    for column in new.columns:
        source = column.name
        if rename and column.name in rename.values():
            source = next(key for key, value in rename.items() if value == column.name)
        if source in old_names:
            copy_pairs.append((column.name, source))
    if copy_pairs:
        target_columns = ", ".join(_quote(target) for target, _ in copy_pairs)
        source_columns = ", ".join(_quote(source) for _, source in copy_pairs)
        statements.append(
            f"INSERT INTO {_quote(temporary)} ({target_columns}) "
            f"SELECT {source_columns} FROM {_quote(old.name)};"
        )
    statements.append(f"DROP TABLE {_quote(old.name)};")
    statements.append(f"ALTER TABLE {_quote(temporary)} RENAME TO {_quote(new.name)};")
    return statements


def _table_sql(old: TableSpec | None, new: TableSpec | None) -> List[str]:
    if old is None and new is not None:
        return [_create_table(new)]
    if old is not None and new is None:
        return [f"DROP TABLE {_quote(old.name)};"]
    if old is None or new is None:
        return []
    if [c.name for c in old.columns] == [c.name for c in new.columns] and all(
        _same_column(a, b) for a, b in zip(old.columns, new.columns)
    ):
        return []

    rename = _rename_map(old, new)
    if rename is not None and all(
        _same_column(old_col, new_col)
        for old_col, new_col in (
            (
                next(c for c in old.columns if c.name == source),
                next(c for c in new.columns if c.name == target),
            )
            for source, target in rename.items()
        )
    ) and len(old.columns) == len(new.columns):
        source, target = next(iter(rename.items()))
        return [
            f"ALTER TABLE {_quote(old.name)} RENAME COLUMN {_quote(source)} TO {_quote(target)};"
        ]

    old_by_name = {c.name: c for c in old.columns}
    new_by_name = {c.name: c for c in new.columns}
    added = [c for c in new.columns if c.name not in old_by_name]
    removed = [c for c in old.columns if c.name not in new_by_name]
    shared_changed = any(
        not _same_column(old_by_name[name], new_by_name[name])
        for name in old_by_name.keys() & new_by_name.keys()
    )
    if not added and not removed and not shared_changed:
        return []
    if not added and removed and not shared_changed:
        return [
            f"ALTER TABLE {_quote(old.name)} DROP COLUMN {_quote(column.name)};"
            for column in removed
        ]
    if added and not removed and not shared_changed:
        return [
            f"ALTER TABLE {_quote(old.name)} ADD COLUMN "
            f"{_column_sql(column, default_for_not_null=column.not_null)};"
            for column in added
        ]
    return _rebuild_table(old, new, rename)


def target_sql_for_task(task: MigrationTask) -> str:
    """Return a target-satisfying SQL script for one task, or ``""`` if unknown."""
    if not task.source_schema or not task.target_schema:
        return ""
    old_tables = {table.name: table for table in parse_forge_schema(task.source_schema)}
    new_tables = {table.name: table for table in parse_forge_schema(task.target_schema)}
    statements: List[str] = []
    for name in sorted(set(old_tables) | set(new_tables)):
        statements.extend(_table_sql(old_tables.get(name), new_tables.get(name)))
    return "\n".join(statements)


def target_completion(task: MigrationTask) -> str:
    """Build a complete SFT target with tags and the task's expected manifest."""
    sql = target_sql_for_task(task)
    if not sql:
        raise ValueError(f"cannot derive target SQL for {task.task_id}")
    manifest = {
        "risk_tier": task.expected_risk_tier,
        "has_data_loss": task.expected_data_loss,
        "decision_required": task.decision_required,
    }
    return (
        "<think>The target schema is reached with a deterministic migration; "
        "existing rows are copied where the schema is rebuilt.</think>\n"
        f"<sql_migration>\n{sql}\n</sql_migration>\n"
        f"<forge_manifest>{json.dumps(manifest, sort_keys=True)}</forge_manifest>"
    )
