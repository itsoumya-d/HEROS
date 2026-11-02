"""HEROS-RLVR-Studio: deterministic SQLite shadow verifier and Dr.GRPO/DAPO engine.

This module bridges HEROS' deterministic schema-risk gate (``forge``) with
PyTorch post-training. It has two responsibilities:

1. Score a model completion against a real (in-memory) SQLite shadow database,
   not against a text heuristic. A migration that drops rows is detected by
   snapshotting table counts before and after execution.
2. Provide the Dr.GRPO / DAPO loss primitives used by the QLoRA runner, without
   requiring a GPU or PyTorch at import time. PyTorch is an opt-in dependency
   (``pip install 'heros-rlvr[gpu]'``); the verifier itself is pure stdlib.

The security posture is intentionally narrow: model-authored SQL is untrusted.
The shadow connection denies ``ATTACH``/``DETACH``, ``PRAGMA writable_schema``,
and ``load_extension`` before any statement executes.

The pure-Python reference implementations live in ``advantages.py``,
``sampling.py`` and ``losses.py``. This module is the differentiable adapter used
by the trainer: advantages and dynamic sampling delegate to those modules, and
the tensor loss is pinned against ``grpo_loss`` by a parity test.
"""

from __future__ import annotations

import json
import re
import sqlite3
from dataclasses import dataclass
from typing import Dict, Sequence, Tuple

from .advantages import dr_grpo_advantages
from .sampling import has_learning_signal

try:  # PyTorch is optional so the core verifier stays dependency-free.
    import torch

    TORCH_AVAILABLE = True
except ImportError:  # pragma: no cover - exercised only in torch-free CI
    torch = None  # type: ignore[assignment]
    TORCH_AVAILABLE = False


def _require_torch():
    if not TORCH_AVAILABLE:
        raise RuntimeError(
            "PyTorch is required for Dr.GRPO/DAPO loss computation. "
            "Install it with: pip install 'heros-rlvr[gpu]'"
        )
    return torch


@dataclass(frozen=True)
class MigrationTask:
    """A deterministic database schema migration verification prompt."""

    task_id: str
    from_ddl: str
    seed_sql: str
    requirement: str
    expected_risk_tier: str  # "SAFE" | "NOTABLE" | "MEDIUM" | "HIGH" | "CRITICAL"
    expected_data_loss: bool
    decision_required: bool
    source_schema: str = ""  # human-readable original schema, for the prompt
    target_schema: str = ""  # human-readable requested schema, for the prompt
    hazard: str = ""  # dataset hazard class, e.g. "drop_column"


@dataclass(frozen=True)
class VerificationReceipt:
    """Audit receipt emitted by the deterministic HEROS shadow verifier."""

    task_id: str
    total_reward: float
    format_reward: float
    shadow_exec_reward: float
    risk_calibration_reward: float
    miracle_step_penalty: float
    shadow_row_loss_detected: bool
    error_code: str  # "OK" | "MISSING_BLOCKS" | "INVALID_JSON" | "SQL_EXEC_ERROR" | "REQUIREMENT_MISS"
    target_schema_matched: bool | None = None


class DeterministicForgeShadowVerifier:
    """Execute proposed migrations in an ephemeral SQLite shadow gate.

    Reward composition (maximum ``2.0``)::

        format            0.25
        shadow execution  0.75
        calibration       1.00  (0.50 risk tier + 0.25 data loss + 0.25 approval)
        miracle penalty  -0.40  (destructive claim without a reasoning trace)
    """

    THINK_PATTERN = re.compile(r"<think>(.*?)</think>", re.DOTALL)
    SQL_PATTERN = re.compile(r"<sql_migration>(.*?)</sql_migration>", re.DOTALL)
    JSON_PATTERN = re.compile(r"<forge_manifest>(.*?)</forge_manifest>", re.DOTALL)
    DESTRUCTIVE_KEYWORDS = ("drop table", "drop column", "truncate", "delete from")

    def verify_rollout(self, task: MigrationTask, completion: str) -> VerificationReceipt:
        think_match = self.THINK_PATTERN.search(completion)
        sql_match = self.SQL_PATTERN.search(completion)
        json_match = self.JSON_PATTERN.search(completion)

        if not (think_match and sql_match and json_match):
            return VerificationReceipt(
                task_id=task.task_id,
                total_reward=-1.0,
                format_reward=-1.0,
                shadow_exec_reward=0.0,
                risk_calibration_reward=0.0,
                miracle_step_penalty=0.0,
                shadow_row_loss_detected=False,
                error_code="MISSING_BLOCKS",
            )

        think_text = think_match.group(1).strip().lower()
        proposed_sql = sql_match.group(1).strip()
        manifest_raw = json_match.group(1).strip()

        try:
            manifest = json.loads(manifest_raw)
        except json.JSONDecodeError:
            manifest = None

        if not isinstance(manifest, dict):
            return VerificationReceipt(
                task_id=task.task_id,
                total_reward=-0.5,
                format_reward=-0.5,
                shadow_exec_reward=0.0,
                risk_calibration_reward=0.0,
                miracle_step_penalty=0.0,
                shadow_row_loss_detected=False,
                error_code="INVALID_JSON",
            )

        format_reward = 0.25
        exec_ok, row_loss_detected, schema_matched = self._run_sqlite_shadow_gate(
            task.from_ddl, task.seed_sql, proposed_sql, task.target_schema
        )

        if not exec_ok:
            return VerificationReceipt(
                task_id=task.task_id,
                total_reward=-0.5,
                format_reward=format_reward,
                shadow_exec_reward=-0.75,
                risk_calibration_reward=0.0,
                miracle_step_penalty=0.0,
                shadow_row_loss_detected=False,
                error_code="SQL_EXEC_ERROR",
            )

        # Executing valid SQL is not the same as performing the requested
        # migration. A no-op or unrelated ADD COLUMN is a failed migration, not
        # a partial success; this closes the loophole observed in the 500-step
        # run. Without this, the model learns format compliance and nothing else.
        shadow_exec_reward = 0.75 if schema_matched else -0.75

        pred_risk = str(manifest.get("risk_tier", "")).upper()
        pred_loss = bool(manifest.get("has_data_loss", False))
        pred_decision = bool(manifest.get("decision_required", False))

        calibration_score = 0.0
        if pred_risk == task.expected_risk_tier:
            calibration_score += 0.5
        if pred_loss == (task.expected_data_loss or row_loss_detected):
            calibration_score += 0.25
        if pred_decision == task.decision_required:
            calibration_score += 0.25

        # "Miracle step": the model asserts data loss or emits destructive SQL
        # without explaining the operation in its reasoning trace.
        miracle_penalty = 0.0
        sql_lower = proposed_sql.lower()
        has_destructive_sql = any(k in sql_lower for k in self.DESTRUCTIVE_KEYWORDS)
        if (pred_loss or has_destructive_sql) and len(think_text) < 20:
            miracle_penalty = 0.4

        total = format_reward + shadow_exec_reward + calibration_score - miracle_penalty
        return VerificationReceipt(
            task_id=task.task_id,
            total_reward=round(total, 4),
            format_reward=format_reward,
            shadow_exec_reward=shadow_exec_reward,
            risk_calibration_reward=calibration_score,
            miracle_step_penalty=miracle_penalty,
            shadow_row_loss_detected=row_loss_detected,
            error_code="OK" if schema_matched else "REQUIREMENT_MISS",
            target_schema_matched=schema_matched,
        )

    @staticmethod
    def _deny_unsafe_sql(action, arg1, arg2, db_name, trigger):  # noqa: ANN001
        """SQLite authorizer: deny filesystem escape and extension loading."""
        if action in (sqlite3.SQLITE_ATTACH, sqlite3.SQLITE_DETACH):
            return sqlite3.SQLITE_DENY
        if action == sqlite3.SQLITE_PRAGMA and str(arg1 or "").lower() == "writable_schema":
            return sqlite3.SQLITE_DENY
        if action == sqlite3.SQLITE_FUNCTION and str(arg1 or "").lower() == "load_extension":
            return sqlite3.SQLITE_DENY
        return sqlite3.SQLITE_OK

    @classmethod
    def _run_sqlite_shadow_gate(
        cls, from_ddl: str, seed_sql: str, migration_sql: str, target_schema: str = ""
    ) -> Tuple[bool, bool, bool]:
        """Apply a migration to an ephemeral DB and detect row loss.

        Returns ``(executed, row_loss_detected, schema_matched)``. Any SQLite
        error, including a denied authorizer action, returns
        ``(False, False, False)``. When ``target_schema`` is empty the schema
        check is skipped and the third value is ``True`` for compatibility with
        hand-built tasks that only specify DDL and rows.
        """
        conn = sqlite3.connect(":memory:")
        try:
            conn.set_authorizer(cls._deny_unsafe_sql)
            conn.executescript(from_ddl)
            if seed_sql.strip():
                conn.executescript(seed_sql)

            before_counts = cls._snapshot_table_counts(conn)
            conn.executescript(migration_sql)
            after_counts = cls._snapshot_table_counts(conn)

            row_loss = any(
                after_counts.get(table, 0) < count_before
                for table, count_before in before_counts.items()
            )
            schema_matched = (
                True
                if not target_schema.strip()
                else cls._schema_matches(conn, target_schema)
            )
            return True, row_loss, schema_matched
        except (sqlite3.Error, sqlite3.Warning):
            return False, False, False
        finally:
            conn.close()

    @classmethod
    def _schema_matches(cls, conn: sqlite3.Connection, target_schema: str) -> bool:
        """Compare the post-migration SQLite schema to a Forge target schema."""
        target = cls._parse_target_schema(target_schema)
        if target is None:
            return False
        actual_tables = {
            str(row[0])
            for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"
            ).fetchall()
        }
        if actual_tables != set(target):
            return False
        for table, expected_columns in target.items():
            quoted = table.replace('"', '""')
            rows = conn.execute(f'PRAGMA table_info("{quoted}");').fetchall()
            actual = {
                str(row[1]): (
                    cls._sqlite_affinity(str(row[2])),
                    bool(row[3]) or bool(row[5]),
                    bool(row[5]),
                )
                for row in rows
            }
            if set(actual) != set(expected_columns):
                return False
            for name, (expected_type, expected_not_null, expected_pk) in expected_columns.items():
                actual_type, actual_not_null, actual_pk = actual[name]
                if actual_type != expected_type or actual_pk != expected_pk:
                    return False
                if actual_not_null != (expected_not_null or expected_pk):
                    return False
        return True

    @classmethod
    def _parse_target_schema(
        cls, text: str
    ) -> Dict[str, Dict[str, Tuple[str, bool, bool]]] | None:
        """Parse the small Forge ``TABLE``/``COLUMN`` subset used by the dataset."""
        tables: Dict[str, Dict[str, Tuple[str, bool, bool]]] = {}
        current: str | None = None
        for raw_line in text.splitlines():
            line = raw_line.strip()
            if not line:
                continue
            upper = line.upper()
            if upper.startswith("TABLE "):
                name = line[6:].strip()
                if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                    return None
                if name in tables:
                    return None
                tables[name] = {}
                current = name
                continue
            if upper.startswith("COLUMN "):
                if current is None:
                    return None
                parts = line[7:].split()
                if len(parts) < 2:
                    return None
                name = parts[0]
                if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                    return None
                source_type = re.sub(r"\(.*\)$", "", parts[1].upper())
                sqlite_type = cls._target_sqlite_type(source_type)
                if sqlite_type is None:
                    return None
                flags = " ".join(parts[2:]).upper().replace("_", " ")
                not_null = "NOT NULL" in flags
                primary_key = "PRIMARY KEY" in flags
                if name in tables[current]:
                    return None
                tables[current][name] = (sqlite_type, not_null, primary_key)
                continue
            return None
        if not tables or any(not columns for columns in tables.values()):
            return None
        return tables

    @staticmethod
    def _target_sqlite_type(source_type: str) -> str | None:
        mapping = {
            "BIGINT": "INTEGER",
            "BIGSERIAL": "INTEGER",
            "INT": "INTEGER",
            "INTEGER": "INTEGER",
            "SERIAL": "INTEGER",
            "SMALLINT": "INTEGER",
            "TEXT": "TEXT",
            "VARCHAR": "TEXT",
            "CHAR": "TEXT",
            "CHARACTER": "TEXT",
            "UUID": "TEXT",
            "JSON": "TEXT",
            "JSONB": "TEXT",
            "TIMESTAMP": "TEXT",
            "TIMESTAMPTZ": "TEXT",
            "DATE": "TEXT",
            "TIME": "TEXT",
            "BOOLEAN": "INTEGER",
            "BOOL": "INTEGER",
            "NUMERIC": "REAL",
            "DECIMAL": "REAL",
            "REAL": "REAL",
            "DOUBLE": "REAL",
            "FLOAT": "REAL",
            "BYTEA": "BLOB",
            "BLOB": "BLOB",
        }
        return mapping.get(source_type)

    @staticmethod
    def _sqlite_affinity(declared_type: str) -> str:
        value = declared_type.upper()
        if "INT" in value:
            return "INTEGER"
        if "CHAR" in value or "CLOB" in value or "TEXT" in value:
            return "TEXT"
        if "BLOB" in value or not value.strip():
            return "BLOB"
        if "REAL" in value or "FLOA" in value or "DOUB" in value:
            return "REAL"
        return "NUMERIC"

    @staticmethod
    def _snapshot_table_counts(conn: sqlite3.Connection) -> Dict[str, int]:
        cursor = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"
        )
        counts: Dict[str, int] = {}
        for (table,) in cursor.fetchall():
            quoted = str(table).replace('"', '""')
            row = conn.execute(f'SELECT COUNT(*) FROM "{quoted}";').fetchone()
            counts[str(table)] = int(row[0])
        return counts


class DapoDynamicSampler:
    """DAPO dynamic sampling and Dr.GRPO advantage primitives."""

    @staticmethod
    def is_informative_group(rewards: Sequence[float], min_std: float = 1e-5) -> bool:
        """Return False when every rollout in a prompt group has the same reward.

        Delegates to :func:`heros_rlvr.sampling.has_learning_signal` so the DAPO
        filter has one definition. The ``min_std`` guard rejects groups whose
        spread is numerically indistinguishable from zero.
        """
        return has_learning_signal(list(rewards), min_std=min_std)

    @staticmethod
    def compute_dr_grpo_advantages(rewards):
        """Dr.GRPO advantage: centre rewards on the group mean, no std division.

        The values come from :func:`heros_rlvr.advantages.dr_grpo_advantages`.
        Rewards are verifier outputs, so they are treated as constants; the
        conversion detaches them from any autograd graph by design.
        """
        torch = _require_torch()
        if rewards.ndim != 1:
            raise ValueError(f"rewards must be 1-D (group_size,), got {tuple(rewards.shape)}")
        if rewards.numel() < 2:
            raise ValueError("Dr.GRPO requires a group of at least two rollouts")
        values = dr_grpo_advantages([float(value) for value in rewards.detach().cpu().tolist()])
        return torch.tensor(values, dtype=rewards.dtype, device=rewards.device)


def compute_dr_grpo_token_loss(
    policy_logprobs,
    old_logprobs,
    ref_logprobs,
    completion_mask,
    rewards,
    clip_eps_low: float = 0.2,
    clip_eps_high: float = 0.28,
    kl_beta: float = 0.01,
    max_completion_len: int = 512,
) -> Tuple[object, Dict[str, float]]:
    """Compute the Dr.GRPO + DAPO asymmetric-clipped token-level loss.

    Args:
        policy_logprobs: ``(group_size, max_completion_len)`` current log-probs.
        old_logprobs: same shape, detached rollout log-probs.
        ref_logprobs: same shape, frozen reference log-probs.
        completion_mask: same shape, 1.0 for real completion tokens.
        rewards: ``(group_size,)`` deterministic verifier rewards.
        clip_eps_low: DAPO lower clipping epsilon (default 0.2).
        clip_eps_high: DAPO upper clipping epsilon (default 0.28).
        kl_beta: KL penalty coefficient.
        max_completion_len: constant Dr.GRPO horizon ``L_max``.

    Returns:
        ``(loss, metrics)`` where loss is a scalar tensor and metrics contains
        Python floats for logging.

    The Dr.GRPO reduction is deliberately ``sum(tokens) / (G * L_max)``. It does
    not divide each sequence by its own length and does not divide advantages by
    the group standard deviation, removing the length and difficulty biases
    documented in Liu et al. (arXiv:2503.20783).
    """
    torch = _require_torch()

    if policy_logprobs.ndim != 2:
        raise ValueError("policy_logprobs must be 2-D (group_size, seq_len)")
    if old_logprobs.shape != policy_logprobs.shape:
        raise ValueError("old_logprobs must match policy_logprobs shape")
    if ref_logprobs.shape != policy_logprobs.shape:
        raise ValueError("ref_logprobs must match policy_logprobs shape")
    if completion_mask.shape != policy_logprobs.shape:
        raise ValueError("completion_mask must match policy_logprobs shape")
    if max_completion_len <= 0:
        raise ValueError("max_completion_len must be positive")

    group_size = policy_logprobs.shape[0]
    if rewards.numel() != group_size:
        raise ValueError(
            f"rewards must contain one value per rollout: got {rewards.numel()} "
            f"for group_size={group_size}"
        )

    advantages = DapoDynamicSampler.compute_dr_grpo_advantages(rewards)
    advantages = advantages.to(dtype=policy_logprobs.dtype).unsqueeze(1)  # (G, 1)

    log_ratio = policy_logprobs - old_logprobs.detach()
    ratio = torch.exp(log_ratio)

    surr1 = ratio * advantages
    clipped_ratio = torch.clamp(ratio, 1.0 - clip_eps_low, 1.0 + clip_eps_high)
    surr2 = clipped_ratio * advantages
    policy_objective = torch.minimum(surr1, surr2)

    # k3 KL estimator: exp(ref - policy) - (ref - policy) - 1, always >= 0.
    ref_diff = ref_logprobs.detach() - policy_logprobs
    per_token_kl = torch.exp(ref_diff) - ref_diff - 1.0

    mask = completion_mask.to(dtype=policy_logprobs.dtype)
    per_token_loss = -(policy_objective - kl_beta * per_token_kl) * mask

    loss = per_token_loss.sum() / (group_size * float(max_completion_len))

    with torch.no_grad():
        valid_tokens = mask.sum().clamp(min=1.0)
        mean_kl = (per_token_kl * mask).sum() / valid_tokens
        clip_frac = (
            ((ratio < (1.0 - clip_eps_low)) | (ratio > (1.0 + clip_eps_high))).float() * mask
        ).sum() / valid_tokens

    metrics = {
        "loss": float(loss.item()),
        "mean_reward": float(rewards.mean().item()),
        "reward_std": float(rewards.std(unbiased=False).item()) if group_size > 1 else 0.0,
        "mean_kl": float(mean_kl.item()),
        "clip_fraction": float(clip_frac.item()),
        "valid_tokens": float(valid_tokens.item()),
    }
    return loss, metrics
