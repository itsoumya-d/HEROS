// SPDX-License-Identifier: MIT
// Ephemeral migration shadow sandbox + deterministic list-wise decision scorer.
//
// The sandbox is intentionally separate from the Zero-lang risk engine: it
// executes the migration against a throwaway SQLite database, observes row
// values before/after, and reports only what it measured. When SQLite is not
// available it falls back to a conservative schema-only analysis and says so.

import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const MAX_SCHEMA_BYTES = 65_536;
const DEFAULT_SAMPLE_ROWS = 3;
const IDENT_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
const TYPE_RE = /^[A-Za-z][A-Za-z0-9_]*$/;

export class ShadowError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = "ShadowError";
    this.code = code;
    this.details = details;
  }
}

export function parseForgeSchema(text) {
  if (typeof text !== "string") {
    throw new ShadowError("SHADOW_INVALID_SCHEMA", "Schema must be a string.");
  }
  if (Buffer.byteLength(text, "utf8") > MAX_SCHEMA_BYTES) {
    throw new ShadowError(
      "SHADOW_SCHEMA_TOO_LARGE",
      `Schema exceeds ${MAX_SCHEMA_BYTES} bytes.`
    );
  }

  const lines = text.replace(/\r\n?/g, "\n").split("|").join("\n").split("\n");
  const tables = new Map();
  let current = null;

  for (const raw of lines) {
    const line = raw.trim();
    if (!line) continue;
    const tokens = line.split(/\s+/);
    const keyword = tokens[0].toUpperCase();

    if (keyword === "TABLE") {
      if (tokens.length !== 2 || !IDENT_RE.test(tokens[1])) {
        throw new ShadowError(
          "SHADOW_INVALID_SCHEMA",
          `Invalid TABLE declaration: ${line.slice(0, 80)}`
        );
      }
      if (tables.has(tokens[1])) {
        throw new ShadowError(
          "SHADOW_INVALID_SCHEMA",
          `Duplicate table: ${tokens[1]}`
        );
      }
      current = {
        name: tokens[1],
        columns: new Map(),
        order: []
      };
      tables.set(current.name, current);
      continue;
    }

    if (keyword === "COLUMN") {
      if (!current) {
        throw new ShadowError(
          "SHADOW_INVALID_SCHEMA",
          "COLUMN declared before any TABLE."
        );
      }
      if (tokens.length < 4) {
        throw new ShadowError(
          "SHADOW_INVALID_SCHEMA",
          `Invalid COLUMN declaration: ${line.slice(0, 80)}`
        );
      }
      const [, name, type, nullability, ...modifiers] = tokens;
      if (!IDENT_RE.test(name)) {
        throw new ShadowError(
          "SHADOW_INVALID_SCHEMA",
          `Invalid column name: ${name.slice(0, 80)}`
        );
      }
      if (!TYPE_RE.test(type)) {
        throw new ShadowError(
          "SHADOW_INVALID_SCHEMA",
          `Invalid column type: ${type.slice(0, 80)}`
        );
      }
      if (!/^(NOT_NULL|NULLABLE)$/i.test(nullability)) {
        throw new ShadowError(
          "SHADOW_INVALID_SCHEMA",
          `Column ${name} must be NOT_NULL or NULLABLE.`
        );
      }
      if (current.columns.has(name)) {
        throw new ShadowError(
          "SHADOW_INVALID_SCHEMA",
          `Duplicate column ${name} in table ${current.name}.`
        );
      }

      let primary = false;
      let hasDefault = false;
      for (const modifier of modifiers) {
        const upper = modifier.toUpperCase();
        if (upper === "PRIMARY_KEY") primary = true;
        else if (upper === "DEFAULT") hasDefault = true;
        else {
          throw new ShadowError(
            "SHADOW_INVALID_SCHEMA",
            `Unknown column modifier ${modifier.slice(0, 40)}.`
          );
        }
      }

      current.columns.set(name, {
        name,
        type: type.toLowerCase(),
        nullable: nullability.toUpperCase() === "NULLABLE",
        primary,
        hasDefault
      });
      current.order.push(name);
      continue;
    }

    // DROP tokens are pseudo-operations used by adversarial fixtures. They do
    // not belong to a schema definition and are ignored here; the diff between
    // the from/to table sets still captures real dropped tables and columns.
    if (keyword === "DROP") continue;

    throw new ShadowError(
      "SHADOW_INVALID_SCHEMA",
      `Unknown schema token: ${keyword.slice(0, 40)}`
    );
  }

  if (tables.size === 0) {
    throw new ShadowError(
      "SHADOW_INVALID_SCHEMA",
      "Schema must declare at least one TABLE."
    );
  }
  for (const table of tables.values()) {
    if (table.order.length === 0) {
      throw new ShadowError(
        "SHADOW_INVALID_SCHEMA",
        `Table ${table.name} has no columns.`
      );
    }
  }

  return { tables };
}

export function diffSchemaModels(fromModel, toModel) {
  const operations = [];

  for (const [tableName, fromTable] of fromModel.tables) {
    const toTable = toModel.tables.get(tableName);
    if (!toTable) {
      operations.push({ type: "drop_table", table: tableName, column: null });
      continue;
    }

    for (const columnName of fromTable.order) {
      if (!toTable.columns.has(columnName)) {
        operations.push({
          type: "drop_col",
          table: tableName,
          column: columnName
        });
      }
    }

    for (const columnName of toTable.order) {
      const toColumn = toTable.columns.get(columnName);
      const fromColumn = fromTable.columns.get(columnName);
      if (!fromColumn) {
        operations.push({
          type: "add_col",
          table: tableName,
          column: columnName
        });
        continue;
      }
      if (fromColumn.nullable !== toColumn.nullable) {
        operations.push({
          type: toColumn.nullable ? "drop_not_null" : "set_not_null",
          table: tableName,
          column: columnName
        });
      }
      if (fromColumn.hasDefault !== toColumn.hasDefault) {
        operations.push({
          type: toColumn.hasDefault ? "set_default" : "drop_default",
          table: tableName,
          column: columnName
        });
      }
      if (fromColumn.type !== toColumn.type) {
        operations.push({
          type: "change_type",
          table: tableName,
          column: columnName,
          from_type: fromColumn.type,
          to_type: toColumn.type
        });
      }
    }
  }

  for (const [tableName] of toModel.tables) {
    if (!fromModel.tables.has(tableName)) {
      operations.push({ type: "add_table", table: tableName, column: null });
    }
  }

  return operations;
}

export function scoreCandidateList(features) {
  const dataLoss = clamp01(features.data_loss_count ?? 0);
  const errors = clamp01(features.migration_error_count ?? 0);
  const destructive = clamp01((features.destructive_ops ?? 0) / 5);
  const medium = clamp01((features.medium_ops ?? 0) / 5);
  const rows = clamp01(Math.log10(1 + (features.rows_at_risk ?? 0)) / 3);
  const staticRisk = clamp01(features.static_risk ?? 0);

  const raw = [
    {
      decision: "allow",
      raw_score:
        1.0 -
        1.2 * dataLoss -
        1.4 * errors -
        0.6 * destructive -
        0.3 * medium -
        0.2 * rows -
        0.8 * staticRisk
    },
    {
      decision: "require_approval",
      raw_score:
        0.2 +
        0.9 * dataLoss +
        1.0 * errors +
        0.4 * destructive +
        0.3 * medium +
        0.2 * rows +
        0.5 * staticRisk
    },
    {
      decision: "deny",
      raw_score:
        -0.2 +
        0.6 * dataLoss +
        1.6 * errors +
        0.3 * destructive +
        0.2 * medium +
        0.3 * rows +
        0.9 * staticRisk
    }
  ];

  const max = Math.max(...raw.map((candidate) => candidate.raw_score));
  const exponentials = raw.map((candidate) => Math.exp(candidate.raw_score - max));
  const total = exponentials.reduce((sum, value) => sum + value, 0);

  return raw
    .map((candidate, index) => ({
      decision: candidate.decision,
      raw_score: round(candidate.raw_score),
      probability: round(exponentials[index] / total)
    }))
    .sort((left, right) => right.probability - left.probability)
    .map((candidate, index) => ({ ...candidate, rank: index + 1 }));
}

export async function analyzeShadow({
  fromSchema,
  toSchema,
  sampleRows = DEFAULT_SAMPLE_ROWS,
  staticRisk
} = {}) {
  const rows = normalizeSampleRows(sampleRows);
  const fromModel = parseForgeSchema(fromSchema);
  const toModel = parseForgeSchema(toSchema);
  const operations = diffSchemaModels(fromModel, toModel);

  const database = await openDatabase();
  const results = [];
  const beforeByTable = new Map();

  try {
    if (database.engine !== "schema-only") {
      for (const table of fromModel.tables.values()) {
        database.exec(createTableSql(table.name, table));
        seedRows(database, table, rows);
        beforeByTable.set(table.name, selectAll(database, table.name));
      }
    }

    const operationsByTable = new Map();
    for (const operation of operations) {
      const list = operationsByTable.get(operation.table) ?? [];
      list.push(operation);
      operationsByTable.set(operation.table, list);
    }

    for (const [tableName, tableOperations] of operationsByTable) {
      const fromTable = fromModel.tables.get(tableName) ?? null;
      const toTable = toModel.tables.get(tableName) ?? null;
      const beforeRows = beforeByTable.get(tableName) ?? [];

      if (database.engine === "schema-only") {
        for (const operation of tableOperations) {
          results.push(staticAttribute(operation, beforeRows, toTable));
        }
        continue;
      }

      if (!fromTable && toTable) {
        let error = null;
        try {
          database.exec(createTableSql(toTable.name, toTable));
        } catch (caught) {
          error = normalizeSqliteError(caught);
        }
        for (const operation of tableOperations) {
          results.push({
            ...operation,
            executed: error === null,
            data_loss: false,
            rows_affected: 0,
            error_code: error?.code ?? null,
            detail: error
              ? error.message
              : "New table created in the shadow database."
          });
        }
        continue;
      }

      if (fromTable && !toTable) {
        let error = null;
        try {
          database.exec(`DROP TABLE ${quoteIdent(fromTable.name)}`);
        } catch (caught) {
          error = normalizeSqliteError(caught);
        }
        for (const operation of tableOperations) {
          results.push({
            ...operation,
            executed: error === null,
            data_loss: beforeRows.length > 0,
            rows_affected: beforeRows.length,
            error_code: error?.code ?? null,
            detail: error
              ? error.message
              : `Dropped table held ${beforeRows.length} seeded row(s).`
          });
        }
        continue;
      }

      let executionError = null;
      try {
        rebuildTable(database, fromTable, toTable);
      } catch (caught) {
        executionError = normalizeSqliteError(caught);
      }

      const afterRows = executionError
        ? beforeRows
        : selectAll(database, toTable.name);

      for (const operation of tableOperations) {
        results.push(
          attributeOperation({
            operation,
            beforeRows,
            afterRows,
            fromTable,
            toTable,
            executionError
          })
        );
      }
    }
  } finally {
    database.close();
  }

  const summary = summarize(results);
  const ranking = scoreCandidateList({
    data_loss_count: summary.data_loss_count,
    migration_error_count: summary.migration_error_count,
    destructive_ops: summary.destructive_ops,
    medium_ops: summary.medium_ops,
    rows_at_risk: summary.rows_at_risk,
    static_risk:
      staticRisk === undefined ? summary.inferred_static_risk : clamp01(staticRisk)
  });

  const riskTier =
    summary.migration_error_count > 0
      ? "CRITICAL"
      : summary.data_loss_count > 0
        ? "HIGH"
        : summary.destructive_ops > 0
          ? "MEDIUM"
          : summary.medium_ops > 0
            ? "NOTABLE"
            : "SAFE";

  return {
    schema_version: 1,
    ok: true,
    engine: database.engine,
    sample_rows: rows,
    warning:
      database.engine === "schema-only"
        ? "SQLite is unavailable; this is a conservative schema-only analysis, not executed SQL."
        : null,
    operations: results,
    summary,
    risk_tier: riskTier,
    decision_required:
      ranking[0].decision !== "allow" ||
      summary.data_loss_count > 0 ||
      summary.migration_error_count > 0,
    recommended_decision: ranking[0].decision,
    confidence: ranking[0].probability,
    listwise: {
      kind: "deterministic_listwise_surrogate",
      candidates: ranking,
      weights: {
        allow: { base: 1.0, data_loss: -1.2, errors: -1.4, destructive: -0.6, medium: -0.3, rows: -0.2, static: -0.8 },
        require_approval: { base: 0.2, data_loss: 0.9, errors: 1.0, destructive: 0.4, medium: 0.3, rows: 0.2, static: 0.5 },
        deny: { base: -0.2, data_loss: 0.6, errors: 1.6, destructive: 0.3, medium: 0.2, rows: 0.3, static: 0.9 }
      }
    }
  };
}

function attributeOperation({
  operation,
  beforeRows,
  afterRows,
  fromTable,
  toTable,
  executionError
}) {
  const column = operation.column;
  const base = {
    ...operation,
    executed: executionError === null,
    data_loss: false,
    rows_affected: 0,
    error_code: executionError?.code ?? null
  };

  if (operation.type === "drop_col") {
    const nonNull = beforeRows.filter(
      (row) => row[column] !== null && row[column] !== undefined
    ).length;
    return {
      ...base,
      data_loss: nonNull > 0,
      rows_affected: nonNull,
      detail: `${nonNull} seeded row(s) held a non-null value in ${column}.`
    };
  }

  if (operation.type === "add_col") {
    const toColumn = toTable.columns.get(column);
    const violation =
      !toColumn.nullable &&
      !toColumn.hasDefault &&
      beforeRows.length > 0;
    return {
      ...base,
      executed: executionError === null && !violation,
      rows_affected: beforeRows.length,
      error_code: violation
        ? "ADD_NOT_NULL_WITHOUT_DEFAULT"
        : base.error_code,
      detail: violation
        ? `Adding non-null ${column} without a default fails on ${beforeRows.length} existing row(s).`
        : executionError
          ? executionError.message
          : "Column added; existing rows were copied."
    };
  }

  if (operation.type === "set_not_null") {
    const nulls = beforeRows.filter(
      (row) => row[column] === null || row[column] === undefined
    ).length;
    return {
      ...base,
      rows_affected: nulls,
      error_code:
        executionError === null && nulls > 0
          ? "NOT_NULL_VIOLATION"
          : base.error_code,
      detail:
        nulls > 0
          ? `${nulls} seeded row(s) contain NULL in ${column}.`
          : executionError
            ? executionError.message
            : "No seeded NULL values blocked the constraint."
    };
  }

  if (operation.type === "change_type") {
    let changed = 0;
    if (executionError === null) {
      const length = Math.max(beforeRows.length, afterRows.length);
      for (let index = 0; index < length; index += 1) {
        const before = beforeRows[index]?.[column];
        const after = afterRows[index]?.[column];
        if (cellText(before) !== cellText(after)) changed += 1;
      }
    }
    return {
      ...base,
      data_loss: changed > 0,
      rows_affected: changed,
      detail: executionError
        ? executionError.message
        : changed > 0
          ? `${changed} seeded value(s) changed value under ${operation.from_type} -> ${operation.to_type}.`
          : "Seeded values survived the type change without changing text."
    };
  }

  if (operation.type === "drop_table") {
    return {
      ...base,
      data_loss: beforeRows.length > 0,
      rows_affected: beforeRows.length,
      detail: executionError
        ? executionError.message
        : `Dropped table held ${beforeRows.length} seeded row(s).`
    };
  }

  return {
    ...base,
    rows_affected: 0,
    detail: executionError
      ? executionError.message
      : fromTable && toTable
        ? "No row values changed for this operation."
        : "Operation applied."
  };
}

function staticAttribute(operation, beforeRows, toTable) {
  const conservativeRows = beforeRows.length || DEFAULT_SAMPLE_ROWS;
  const base = {
    ...operation,
    executed: false,
    data_loss: false,
    rows_affected: 0,
    error_code: null
  };

  if (operation.type === "drop_table" || operation.type === "drop_col") {
    return {
      ...base,
      data_loss: true,
      rows_affected: conservativeRows,
      detail: "SQLite unavailable: data-loss possibility is conservative, not measured."
    };
  }
  if (operation.type === "set_not_null") {
    return {
      ...base,
      error_code: "NOT_NULL_VIOLATION_UNVERIFIED",
      detail: "SQLite unavailable: existing NULLs could not be checked."
    };
  }
  if (operation.type === "change_type") {
    return {
      ...base,
      data_loss: true,
      rows_affected: conservativeRows,
      detail: "SQLite unavailable: cast fidelity could not be measured."
    };
  }
  if (operation.type === "add_col" && toTable) {
    const column = toTable.columns.get(operation.column);
    if (column && !column.nullable && !column.hasDefault && conservativeRows > 0) {
      return {
        ...base,
        error_code: "ADD_NOT_NULL_WITHOUT_DEFAULT",
        rows_affected: conservativeRows,
        detail: "Adding a non-null column without a default fails on existing rows."
      };
    }
  }
  return { ...base, detail: "Schema-only operation; no row-level effect." };
}

function summarize(results) {
  const dataLoss = results.filter((result) => result.data_loss).length;
  const errors = results.filter((result) => result.error_code).length;
  const destructive = results.filter((result) =>
    ["drop_table", "drop_col", "set_not_null"].includes(result.type)
  ).length;
  const medium = results.filter((result) =>
    ["change_type", "drop_not_null"].includes(result.type)
  ).length;
  const rowsAtRisk = results.reduce(
    (max, result) => Math.max(max, result.rows_affected ?? 0),
    0
  );

  return {
    operation_count: results.length,
    data_loss_count: dataLoss,
    migration_error_count: errors,
    destructive_ops: destructive,
    medium_ops: medium,
    rows_at_risk: rowsAtRisk,
    inferred_static_risk: clamp01(
      0.25 * destructive + 0.1 * medium + 0.5 * dataLoss + 0.6 * errors
    )
  };
}

function normalizeSampleRows(value) {
  if (value === undefined || value === null) return DEFAULT_SAMPLE_ROWS;
  if (!Number.isInteger(value) || value < 1 || value > 5) {
    throw new ShadowError(
      "SHADOW_INVALID_SAMPLE_ROWS",
      "sample_rows must be an integer from 1 to 5."
    );
  }
  return value;
}

function createTableSql(name, table) {
  const definitions = table.order.map((columnName) => {
    const column = table.columns.get(columnName);
    let definition = `${quoteIdent(columnName)} ${sqlType(column.type)}`;
    if (column.primary) definition += " PRIMARY KEY";
    if (!column.nullable && !column.primary) definition += " NOT NULL";
    if (column.hasDefault) definition += ` DEFAULT ${defaultSql(column)}`;
    return definition;
  });
  return `CREATE TABLE ${quoteIdent(name)} (${definitions.join(", ")})`;
}

function rebuildTable(database, fromTable, toTable) {
  const temporary = `__shadow_rebuild_${fromTable.name}`;
  const targetColumns = toTable.order;
  const expressions = targetColumns.map((columnName) => {
    const toColumn = toTable.columns.get(columnName);
    const fromColumn = fromTable.columns.get(columnName);
    if (fromColumn) {
      return fromColumn.type === toColumn.type
        ? quoteIdent(columnName)
        : `CAST(${quoteIdent(columnName)} AS ${sqlType(toColumn.type)})`;
    }
    return toColumn.hasDefault ? defaultSql(toColumn) : "NULL";
  });

  database.exec("BEGIN IMMEDIATE");
  try {
    database.exec(createTableSql(temporary, toTable));
    database.exec(
      `INSERT INTO ${quoteIdent(temporary)} (${targetColumns
        .map(quoteIdent)
        .join(", ")}) SELECT ${expressions.join(", ")} FROM ${quoteIdent(fromTable.name)}`
    );
    database.exec(`DROP TABLE ${quoteIdent(fromTable.name)}`);
    database.exec(
      `ALTER TABLE ${quoteIdent(temporary)} RENAME TO ${quoteIdent(toTable.name)}`
    );
    database.exec("COMMIT");
  } catch (error) {
    try {
      database.exec("ROLLBACK");
    } catch {
      // Preserve the original failure.
    }
    throw error;
  }
}

function seedRows(database, table, count) {
  for (let row = 1; row <= count; row += 1) {
    const values = table.order.map((columnName) => {
      const column = table.columns.get(columnName);
      return sqlLiteral(seedValue(column, row, count));
    });
    database.exec(
      `INSERT INTO ${quoteIdent(table.name)} (${table.order
        .map(quoteIdent)
        .join(", ")}) VALUES (${values.join(", ")})`
    );
  }
}

function seedValue(column, row, totalRows) {
  if (column.primary) return row;
  if (column.nullable && row === totalRows) return null;

  switch (column.type) {
    case "serial":
    case "integer":
    case "bigint":
      return row * 10;
    case "decimal":
      return row + 0.5;
    case "boolean":
      return row % 2;
    case "timestamptz":
      return `2026-01-0${Math.min(row, 9)}T00:00:00Z`;
    case "json":
      return JSON.stringify({ n: row });
    case "uuid":
      return `00000000-0000-0000-0000-${String(row).padStart(12, "0")}`;
    case "text":
      if (column.name.toLowerCase().includes("email")) {
        return `user${row}@example.com`;
      }
      if (column.name.toLowerCase().includes("name")) {
        return `name${row}`;
      }
      return `value${row}`;
    default:
      return `value${row}`;
  }
}

function defaultSql(column) {
  switch (column.type) {
    case "serial":
    case "integer":
    case "bigint":
    case "boolean":
      return "0";
    case "decimal":
      return "0.0";
    case "json":
      return "'{}'";
    case "uuid":
      return "'00000000-0000-0000-0000-000000000000'";
    case "timestamptz":
      return "'1970-01-01T00:00:00Z'";
    default:
      return "''";
  }
}

function sqlType(type) {
  switch (type) {
    case "serial":
    case "integer":
    case "bigint":
    case "boolean":
      return "INTEGER";
    case "decimal":
      return "REAL";
    default:
      return "TEXT";
  }
}

function selectAll(database, tableName) {
  try {
    return database.all(`SELECT * FROM ${quoteIdent(tableName)}`);
  } catch {
    return [];
  }
}

function sqlLiteral(value) {
  if (value === null || value === undefined) return "NULL";
  if (typeof value === "number") return String(value);
  return `'${String(value).replace(/'/g, "''")}'`;
}

function quoteIdent(name) {
  return `"${String(name).replace(/"/g, '""')}"`;
}

function cellText(value) {
  return value === null || value === undefined ? "<null>" : String(value);
}

function normalizeSqliteError(error) {
  const message = error instanceof Error ? error.message : String(error);
  let code = "MIGRATION_FAILED";
  if (/NOT NULL constraint failed/i.test(message)) code = "NOT_NULL_VIOLATION";
  else if (/UNIQUE constraint failed/i.test(message)) code = "UNIQUE_VIOLATION";
  else if (/no such column/i.test(message)) code = "MISSING_COLUMN";
  else if (/no such table/i.test(message)) code = "MISSING_TABLE";
  return { code, message: message.slice(0, 240) };
}

async function openDatabase() {
  try {
    const { DatabaseSync } = await import("node:sqlite");
    const database = new DatabaseSync(":memory:");
    return {
      engine: "node:sqlite",
      exec(sql) {
        database.exec(sql);
      },
      all(sql) {
        return database.prepare(sql).all();
      },
      close() {
        try {
          database.close();
        } catch {
          // Already closed.
        }
      }
    };
  } catch {
    return openSqliteCli();
  }
}

function openSqliteCli() {
  let directory = null;
  let path = null;
  try {
    directory = mkdtempSync(join(tmpdir(), "heros-shadow-"));
    path = join(directory, "shadow.sqlite");
    execFileSync("sqlite3", ["--version"], { stdio: "ignore" });
  } catch {
    if (directory) {
      try {
        rmSync(directory, { recursive: true, force: true });
      } catch {
        // Best effort.
      }
    }
    return {
      engine: "schema-only",
      exec() {
        throw new Error("SQLite is unavailable.");
      },
      all() {
        return [];
      },
      close() {}
    };
  }

  return {
    engine: "sqlite3-cli",
    exec(sql) {
      execFileSync("sqlite3", ["-batch", "-bail", path], {
        input: sql,
        stdio: ["pipe", "pipe", "pipe"],
        maxBuffer: 8 * 1024 * 1024
      });
    },
    all(sql) {
      const output = execFileSync("sqlite3", ["-json", "-batch", path], {
        input: sql,
        encoding: "utf8",
        maxBuffer: 8 * 1024 * 1024
      });
      const text = output.trim();
      return text ? JSON.parse(text) : [];
    },
    close() {
      try {
        rmSync(directory, { recursive: true, force: true });
      } catch {
        // Best effort.
      }
    }
  };
}

function clamp01(value) {
  if (!Number.isFinite(value)) return 0;
  return Math.min(1, Math.max(0, value));
}

function round(value) {
  return Math.round(value * 1_000_000) / 1_000_000;
}
