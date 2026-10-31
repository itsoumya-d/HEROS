// SPDX-License-Identifier: MIT
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import {
  analyzeShadow,
  diffSchemaModels,
  parseForgeSchema,
  scoreCandidateList,
  ShadowError
} from "../src/shadow.js";
import { makeHarness } from "./helpers.mjs";

const users = "TABLE users\nCOLUMN id serial NOT_NULL PRIMARY_KEY\nCOLUMN email text NOT_NULL";

function assertShadowError(fn, code) {
  assert.throws(fn, (error) => {
    assert.equal(error instanceof ShadowError, true);
    assert.equal(error.code, code);
    return true;
  });
}

describe("shadow schema parsing", () => {
  test("rejects missing tables, duplicate names, unknown modifiers, and oversize input", () => {
    assertShadowError(() => parseForgeSchema(""), "SHADOW_INVALID_SCHEMA");
    assertShadowError(
      () => parseForgeSchema("COLUMN id serial NOT_NULL"),
      "SHADOW_INVALID_SCHEMA"
    );
    assertShadowError(
      () => parseForgeSchema("TABLE a|TABLE a"),
      "SHADOW_INVALID_SCHEMA"
    );
    assertShadowError(
      () => parseForgeSchema("TABLE a|COLUMN id text NOT_NULL|COLUMN id text NULLABLE"),
      "SHADOW_INVALID_SCHEMA"
    );
    assertShadowError(
      () => parseForgeSchema("TABLE a|COLUMN id text MAYBE"),
      "SHADOW_INVALID_SCHEMA"
    );
    assertShadowError(
      () => parseForgeSchema("TABLE a|COLUMN id text NOT_NULL|COLUMN x text NULLABLE SORCERY"),
      "SHADOW_INVALID_SCHEMA"
    );
    assertShadowError(
      () => parseForgeSchema(`TABLE a|COLUMN id text NOT_NULL|${"x".repeat(66_000)}`),
      "SHADOW_SCHEMA_TOO_LARGE"
    );
  });

  test("accepts pipe-separated and newline schemas, and ignores DROP pseudo-tokens", () => {
    const model = parseForgeSchema(
      "TABLE users|COLUMN id serial NOT_NULL PRIMARY_KEY|COLUMN email text NULLABLE|DROP COLUMN email"
    );
    assert.equal(model.tables.size, 1);
    assert.deepEqual([...model.tables.get("users").columns.keys()], ["id", "email"]);
  });
});

describe("shadow diff", () => {
  test("detects table/column add, drop, nullability, default, and type changes", () => {
    const from = parseForgeSchema(
      "TABLE a|COLUMN id serial NOT_NULL PRIMARY_KEY|COLUMN name text NULLABLE|COLUMN score text NULLABLE|COLUMN bio text NULLABLE"
    );
    const to = parseForgeSchema(
      "TABLE a|COLUMN id serial NOT_NULL PRIMARY_KEY|COLUMN name text NOT_NULL|COLUMN score integer NULLABLE|COLUMN tenant text NOT_NULL|TABLE b|COLUMN id serial NOT_NULL PRIMARY_KEY"
    );
    const operations = diffSchemaModels(from, to);
    assert.deepEqual(
      operations.map((operation) => operation.type).sort(),
      ["add_col", "add_table", "change_type", "drop_col", "set_not_null"]
    );
  });
});

describe("shadow execution", () => {
  test("safe additive migration is allowed and reports a real engine", async (t) => {
    const result = await analyzeShadow({
      fromSchema: users,
      toSchema: `${users}\nCOLUMN bio text NULLABLE`
    });
    if (result.engine === "schema-only") {
      t.skip("SQLite unavailable in this environment");
      return;
    }
    assert.equal(result.ok, true);
    assert.equal(result.recommended_decision, "allow");
    assert.equal(result.decision_required, false);
    assert.equal(result.operations[0].executed, true);
    assert.equal(result.operations[0].data_loss, false);
    assert.equal(result.summary.data_loss_count, 0);
  });

  test("dropping a populated column requires approval and reports the rows at risk", async (t) => {
    const result = await analyzeShadow({
      fromSchema: users,
      toSchema: "TABLE users\nCOLUMN id serial NOT_NULL PRIMARY_KEY"
    });
    if (result.engine === "schema-only") {
      t.skip("SQLite unavailable in this environment");
      return;
    }
    assert.equal(result.recommended_decision, "require_approval");
    assert.equal(result.decision_required, true);
    assert.equal(result.summary.data_loss_count, 1);
    assert.ok(result.operations[0].rows_affected > 0);
    assert.match(result.operations[0].detail, /non-null value/);
  });

  test("dropping a populated table is high risk", async (t) => {
    const result = await analyzeShadow({
      fromSchema: users,
      toSchema: "TABLE audit\nCOLUMN id serial NOT_NULL PRIMARY_KEY"
    });
    if (result.engine === "schema-only") {
      t.skip("SQLite unavailable in this environment");
      return;
    }
    assert.equal(result.summary.data_loss_count, 1);
    assert.equal(result.risk_tier, "HIGH");
    assert.equal(result.recommended_decision, "require_approval");
  });

  test("adding a non-null column without a default is a concrete error", async (t) => {
    const result = await analyzeShadow({
      fromSchema: users,
      toSchema: `${users}\nCOLUMN tenant text NOT_NULL`
    });
    if (result.engine === "schema-only") {
      t.skip("SQLite unavailable in this environment");
      return;
    }
    assert.equal(result.operations[0].executed, false);
    assert.equal(result.operations[0].error_code, "ADD_NOT_NULL_WITHOUT_DEFAULT");
    assert.equal(result.recommended_decision, "deny");
    assert.equal(result.decision_required, true);
  });

  test("setting NOT NULL over existing NULLs is rejected", async (t) => {
    const result = await analyzeShadow({
      fromSchema: "TABLE users\nCOLUMN id serial NOT_NULL PRIMARY_KEY\nCOLUMN email text NULLABLE",
      toSchema: users
    });
    if (result.engine === "schema-only") {
      t.skip("SQLite unavailable in this environment");
      return;
    }
    assert.equal(result.operations[0].error_code, "NOT_NULL_VIOLATION");
    assert.equal(result.operations[0].executed, false);
    assert.ok(result.operations[0].rows_affected > 0);
  });

  test("a lossy type change reports changed values", async (t) => {
    const result = await analyzeShadow({
      fromSchema: "TABLE users\nCOLUMN id serial NOT_NULL PRIMARY_KEY\nCOLUMN score text NULLABLE",
      toSchema: "TABLE users\nCOLUMN id serial NOT_NULL PRIMARY_KEY\nCOLUMN score integer NULLABLE"
    });
    if (result.engine === "schema-only") {
      t.skip("SQLite unavailable in this environment");
      return;
    }
    assert.equal(result.operations[0].data_loss, true);
    assert.ok(result.operations[0].rows_affected > 0);
    assert.equal(result.recommended_decision, "require_approval");
  });

  test("adding a table is safe", async (t) => {
    const result = await analyzeShadow({
      fromSchema: users,
      toSchema: `${users}\nTABLE audit\nCOLUMN id serial NOT_NULL PRIMARY_KEY`
    });
    if (result.engine === "schema-only") {
      t.skip("SQLite unavailable in this environment");
      return;
    }
    assert.equal(result.operations[0].executed, true);
    assert.equal(result.recommended_decision, "allow");
  });
});

describe("list-wise scorer", () => {
  test("no risk ranks allow first", () => {
    const ranking = scoreCandidateList({
      data_loss_count: 0,
      migration_error_count: 0,
      destructive_ops: 0,
      medium_ops: 0,
      rows_at_risk: 0,
      static_risk: 0
    });
    assert.equal(ranking[0].decision, "allow");
    assert.equal(ranking[0].rank, 1);
    const total = ranking.reduce((sum, candidate) => sum + candidate.probability, 0);
    assert.ok(Math.abs(total - 1) < 1e-3);
  });

  test("data loss ranks approval first and execution errors rank deny first", () => {
    const dataLoss = scoreCandidateList({
      data_loss_count: 1,
      migration_error_count: 0,
      destructive_ops: 1,
      medium_ops: 0,
      rows_at_risk: 10,
      static_risk: 0.5
    });
    assert.equal(dataLoss[0].decision, "require_approval");

    const errors = scoreCandidateList({
      data_loss_count: 0,
      migration_error_count: 1,
      destructive_ops: 0,
      medium_ops: 0,
      rows_at_risk: 10,
      static_risk: 0.5
    });
    assert.equal(errors[0].decision, "deny");
  });

  test("scoring is deterministic", () => {
    const features = {
      data_loss_count: 1,
      migration_error_count: 0,
      destructive_ops: 1,
      medium_ops: 2,
      rows_at_risk: 42,
      static_risk: 0.33
    };
    assert.deepEqual(scoreCandidateList(features), scoreCandidateList(features));
  });
});

describe("shadow MCP tool", () => {
  test("returns engine, operations, recommendation, and rate limit", async (t) => {
    const harness = await makeHarness();
    t.after(harness.cleanup);
    await harness.rpc("initialize", {});

    const result = await harness.call("forge_shadow_analyze", {
      from_schema: users,
      to_schema: `${users}\nCOLUMN bio text NULLABLE`,
      sample_rows: 2
    });
    assert.equal(result.ok, true);
    assert.equal(result.sample_rows, 2);
    assert.match(result.engine, /^(node:sqlite|sqlite3-cli|schema-only)$/);
    assert.equal(result._rate_limit.window, "per_hour");
  });

  test("invalid input fails closed before execution", async (t) => {
    const harness = await makeHarness();
    t.after(harness.cleanup);
    await harness.rpc("initialize", {});

    const badRows = await harness.call("forge_shadow_analyze", {
      from_schema: users,
      to_schema: users,
      sample_rows: 0
    });
    assert.equal(badRows.error_code, "INVALID_INPUT");

    const badSchema = await harness.call("forge_shadow_analyze", {
      from_schema: "COLUMN id text NOT_NULL",
      to_schema: users
    });
    assert.equal(badSchema.ok, false);
    assert.equal(badSchema.error_code, "SHADOW_INVALID_SCHEMA");
  });
});

describe("forge_analyze shadow gate", () => {
  test("the shadow gate upgrades a fake-safe migration that drops a populated column", async (t) => {
    const harness = await makeHarness();
    t.after(harness.cleanup);
    await harness.rpc("initialize", {});

    const schemas = {
      from_schema: users,
      to_schema: "TABLE users\nCOLUMN id serial NOT_NULL PRIMARY_KEY"
    };
    const first = await harness.call("forge_analyze", schemas);
    assert.equal(first.risk_tier, "SAFE");
    assert.equal(first.decision_required, true);
    assert.match(first.approval_nonce, /^[0-9a-f]{16}$/);
    assert.equal(first.shadow.summary.data_loss_count, 1);

    const approved = await harness.call("forge_analyze", {
      ...schemas,
      human_acknowledgment_token: first.approval_nonce
    });
    assert.equal(approved.proceed_ok, true);
    assert.equal(approved.decision_required, false);
  });

  test("an execution-error shadow recommendation cannot be approved away", async (t) => {
    const harness = await makeHarness();
    t.after(harness.cleanup);
    await harness.rpc("initialize", {});

    const result = await harness.call("forge_analyze", {
      from_schema: users,
      to_schema: `${users}\nCOLUMN tenant text NOT_NULL`
    });
    assert.equal(result.error_code, "SHADOW_DENY");
    assert.equal(result.retryable, false);
    assert.equal(result.approval_nonce, undefined);
  });

  test("a static CRITICAL decision is never downgraded by an allow shadow", async (t) => {
    const harness = await makeHarness();
    t.after(harness.cleanup);
    await harness.rpc("initialize", {});

    const result = await harness.call("forge_analyze", {
      from_schema: users,
      to_schema: `${users}\nDROP TABLE users`
    });
    assert.equal(result.decision_required, true);
    assert.equal(result.shadow.operations.length, 0);
    assert.match(result.approval_nonce, /^[0-9a-f]{16}$/);
  });

  test("a shadow parse failure leaves the static decision intact", async (t) => {
    const harness = await makeHarness();
    t.after(harness.cleanup);
    await harness.rpc("initialize", {});

    const result = await harness.call("forge_analyze", {
      from_schema: "TABLE a",
      to_schema: "DROP TABLE a"
    });
    assert.equal(result.decision_required, true);
    assert.equal(result.shadow.ok, false);
    assert.equal(result.shadow.error_code, "SHADOW_INVALID_SCHEMA");
    assert.match(result.approval_nonce, /^[0-9a-f]{16}$/);
  });
});
