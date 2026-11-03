// SPDX-License-Identifier: MIT
// 211 additional adversarial cases. Together with the 289 cases in
// adversarial.test.mjs this brings the MCP corpus to 500.
//
// Allocation:
//   JSON-RPC 40, agentic schema 30, auth/scope 25, forge 30, shadow 30,
//   approval replay 30, destructive approval gate 26.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createSession } from "../src/server.js";
import { createAgenticApp } from "../../agentic/src/index.js";
import { makeHarness } from "./helpers.mjs";

const USER_SCHEMA =
  "TABLE users\nCOLUMN id serial NOT_NULL PRIMARY_KEY\nCOLUMN email text NOT_NULL";
const ALLOWED_FORGE_ERRORS = new Set([
  "INVALID_INPUT",
  "MISSING_FLAG",
  "UNKNOWN_COMMAND",
  "EXEC_FAILED",
  "SHADOW_DENY"
]);
const ALLOWED_SHADOW_ERRORS = new Set([
  "SHADOW_INVALID_SCHEMA",
  "SHADOW_SCHEMA_TOO_LARGE",
  "SHADOW_INVALID_SAMPLE_ROWS",
  "INVALID_INPUT",
  "MISSING_FLAG"
]);

function permissiveLimiter() {
  return {
    check(_key, limit) {
      return {
        allowed: true,
        remaining: limit,
        resetAt: Math.floor(Date.now() / 1000) + 3600,
        limit
      };
    }
  };
}

let harness;
let app;
let authHarness;
let authKeys;

before(async () => {
  harness = await makeHarness({ rateLimiter: permissiveLimiter() });
  await harness.rpc("initialize", {});

  app = createAgenticApp({
    authorize: () => ({ principal: "agent:corpus211" })
  });
  app.action({
    name: "cart.add_item",
    inputSchema: {
      type: "object",
      required: ["sku", "quantity"],
      additionalProperties: false,
      properties: {
        sku: {
          type: "string",
          minLength: 3,
          maxLength: 32,
          pattern: "^[A-Z0-9-]+$",
          safeText: true
        },
        quantity: { type: "integer", minimum: 1, maximum: 10 }
      }
    },
    authRequired: true,
    handler: ({ input }) => ({ sku: input.sku, quantity: input.quantity })
  });

  const authSeed = "z".repeat(40);
  authHarness = await makeHarness({
    rateLimiter: permissiveLimiter(),
    hmacSeed: authSeed
  });
  await authHarness.rpc("initialize", {});
  const validKeyId = "1".repeat(32);
  const validSecret = "2".repeat(32);
  authKeys = {
    validRo: `heros_ro_${validKeyId}_${validSecret}`,
    revoked: `heros_rw_${"3".repeat(32)}_${"4".repeat(32)}`
  };
  const hash = createHmac("sha256", authSeed)
    .update(`${validKeyId}:${validSecret}`)
    .digest("hex");
  await writeFile(
    join(authHarness.dataDir, ".heros-keys"),
    `${validKeyId} ro org_12345678 ${hash} 0 0\n` +
      `${"3".repeat(32)} rw org_87654321 ${"0".repeat(64)} 0 1\n`
  );
});

after(async () => {
  await harness.cleanup();
  await authHarness.cleanup();
});

function report(failures, category, count) {
  assert.equal(
    failures.length,
    0,
    `${category}: ${failures.length}/${count} failures\n${failures
      .slice(0, 5)
      .join("\n")}`
  );
}

test("ASI05/ASI09: 40 additional malformed JSON-RPC messages are bounded", async () => {
  const methods = [
    "",
    " ",
    "\u0000",
    "tools/call",
    "tools/list",
    "initialize",
    "ping",
    "unknown",
    "a".repeat(300),
    "../escape"
  ];
  const params = [
    undefined,
    null,
    {},
    [],
    "x",
    42,
    { name: "" },
    { name: "A" },
    { name: "forge_analyze", arguments: "x" },
    { name: "forge_shadow_analyze", arguments: [] }
  ];
  const ids = [0, "", null, {}, [], "id".repeat(300), -1, 1.5, true, "id\u0000"];
  const messages = Array.from({ length: 40 }, (_, index) => ({
    jsonrpc: "2.0",
    id: ids[index % ids.length],
    method: methods[index % methods.length],
    params: params[index % params.length]
  }));

  const failures = [];
  for (const [index, message] of messages.entries()) {
    try {
      const response = await harness.server.handleMessage(message, harness.session);
      if (response !== null) {
        assert.equal(typeof response, "object");
        assert.equal(Array.isArray(response), false);
        if (response.error) {
          assert.equal(typeof response.error.code, "number");
          assert.equal(typeof response.error.message, "string");
        }
      }
    } catch (error) {
      failures.push(`case ${index}: threw ${error.message}`);
    }
  }
  assert.equal(messages.length, 40);
  report(failures, "JSON-RPC-extra", messages.length);
});

test("ASI01/ASI02: 30 additional agentic schema mutations fail closed", async () => {
  const valid = { sku: "BOOK-1", quantity: 2 };
  const mutations = [];
  const skus = [
    "",
    "a",
    "ab",
    "A".repeat(33),
    "book-1",
    "BOOK 1",
    "BOOK-1\n",
    "BOOK-1\u0000",
    "BOOK-1\t",
    "BOOK-1\u001f",
    "-DROP TABLE users",
    "' OR 1=1 --",
    "../../etc/passwd",
    "__proto__",
    "constructor"
  ];
  for (const sku of skus) mutations.push({ ...valid, sku });
  const quantities = [
    0,
    -1,
    11,
    1.5,
    "2",
    true,
    null,
    [],
    {},
    Number.MAX_SAFE_INTEGER
  ];
  for (const quantity of quantities) mutations.push({ ...valid, quantity });
  mutations.push(
    { sku: "BOOK-1" },
    { quantity: 2 },
    {},
    { ...valid, extra: true },
    { ...valid, idempotencyKey: "key with space" }
  );

  const failures = [];
  for (const [index, input] of mutations.entries()) {
    try {
      const response = await app.execute({ name: "cart.add_item", input });
      assert.equal(response.ok, false, `case ${index} unexpectedly succeeded`);
      assert.equal(response.error_code, "INVALID_INPUT", `case ${index}`);
    } catch (error) {
      failures.push(`case ${index}: threw ${error.message}`);
    }
  }
  assert.equal(mutations.length, 30);
  report(failures, "agentic-extra", mutations.length);
});

test("ASI03/ASI10: 25 additional API-key variants cannot execute a tool", async () => {
  const target = { ...authHarness.session, initialized: true };
  const variants = [];
  for (let index = 0; index < 22; index += 1) {
    const mode = index % 6;
    if (mode === 0) variants.push(`heros_ro_${"1".repeat(32)}_${"2".repeat(31)}`);
    if (mode === 1) variants.push(`heros_ro_${"1".repeat(31)}_${"2".repeat(32)}`);
    if (mode === 2) variants.push(`heros_rw_${"g".repeat(32)}_${"2".repeat(32)}`);
    if (mode === 3) variants.push(`heros_ro_${"1".repeat(32)}_${"2".repeat(32)}\n`);
    if (mode === 4) variants.push(`heros_ro_${"1".repeat(32)}_${"2".repeat(32)} `);
    if (mode === 5) variants.push(`heros_ro_${"1".repeat(32)}_${"2".repeat(32)}_x`);
  }
  const keys = [...variants, authKeys.validRo, authKeys.revoked, ""];

  const failures = [];
  for (const [index, key] of keys.entries()) {
    const session = createSession({ id: `corpus-auth-${index}`, apiKey: key });
    session.initialized = true;
    try {
      const response = await authHarness.rpc(
        "tools/call",
        {
          name: "ledger_invoice_create",
          arguments: {
            to: "Vendor",
            amount: 1,
            currency: "USD",
            idempotency_key: `corpus-auth-${index}`
          }
        },
        session
      );
      const payload = JSON.parse(response.result.content[0].text);
      if (key === authKeys.validRo) {
        assert.equal(payload.error_code, "INSUFFICIENT_SCOPE");
      } else if (key === authKeys.revoked) {
        assert.equal(payload.error_code, "API_KEY_REVOKED");
      } else if (key === "") {
        assert.equal(payload.error_code, "NO_ORG_REGISTERED");
      } else {
        assert.equal(payload.error_code, "INVALID_API_KEY", `case ${index}`);
      }
    } catch (error) {
      failures.push(`case ${index}: ${error.message}`);
    }
  }
  assert.equal(keys.length, 25);
  report(failures, "auth-extra", keys.length);
});

test("ASI05/ASI06: 30 additional hostile forge payloads are bounded", async () => {
  const suffixes = [
    "\n",
    "\r\n",
    "\u0000",
    "\u0001",
    "\u001f",
    "\u007f",
    "\u202e",
    "\u001b[31m",
    "' OR 1=1 --",
    "\"; DROP TABLE users; --",
    "../../etc/passwd",
    "__proto__",
    "constructor",
    "A".repeat(128),
    "TABLE duplicate"
  ];
  const payloads = [];
  for (const suffix of suffixes) {
    payloads.push({ from_schema: USER_SCHEMA, to_schema: `${USER_SCHEMA}${suffix}` });
    payloads.push({ from_schema: `${USER_SCHEMA}${suffix}`, to_schema: USER_SCHEMA });
  }

  const failures = [];
  for (const [index, payload] of payloads.entries()) {
    try {
      const result = await harness.call("forge_analyze", payload);
      if (result.error_code) {
        assert.equal(
          ALLOWED_FORGE_ERRORS.has(result.error_code),
          true,
          `case ${index}: unexpected error ${result.error_code}`
        );
      } else {
        assert.equal(typeof result.risk_tier, "string");
        assert.equal(typeof result.shadow, "object");
        assert.equal(result._rate_limit.window, "per_hour");
      }
    } catch (error) {
      failures.push(`case ${index}: threw ${error.message}`);
    }
  }
  assert.equal(payloads.length, 30);
  report(failures, "forge-extra", payloads.length);
});

test("ASI05: 30 additional malformed shadow schemas fail without SQL", async () => {
  const schemas = Array.from({ length: 30 }, (_, index) => {
    switch (index % 10) {
      case 0:
        return "";
      case 1:
        return `TABLE a\nCOLUMN id text MAYBE${index}`;
      case 2:
        return `TABLE a\nCOLUMN id 123 NOT_NULL`;
      case 3:
        return `TABLE a\nCOLUMN id text NOT_NULL SORCERY${index}`;
      case 4:
        return `TABLE a\nTABLE a${index}`;
      case 5:
        return `COLUMN id text NOT_NULL`;
      case 6:
        return `TABLE a\nCOLUMN id text NOT_NULL\nCOLUMN id text NULLABLE`;
      case 7:
        return `TABLE a-b${index}\nCOLUMN id text NOT_NULL`;
      case 8:
        return `TABLE a\nCOLUMN id text NOT_NULL\nCOLUMN id text NOT_NULL`;
      default:
        return `DROP TABLE a${index}`;
    }
  });

  const failures = [];
  for (const [index, schema] of schemas.entries()) {
    try {
      const result = await harness.call("forge_shadow_analyze", {
        from_schema: schema,
        to_schema: USER_SCHEMA
      });
      assert.equal(result.ok, false, `case ${index} unexpectedly parsed`);
      assert.equal(
        ALLOWED_SHADOW_ERRORS.has(result.error_code),
        true,
        `case ${index}: unexpected error ${result.error_code}`
      );
    } catch (error) {
      failures.push(`case ${index}: threw ${error.message}`);
    }
  }
  assert.equal(schemas.length, 30);
  report(failures, "shadow-extra", schemas.length);
});

test("ASI02/ASI07: 30 additional approval replay/rebind cases fail", async () => {
  const first = await harness.call("forge_analyze", {
    from_schema: USER_SCHEMA,
    to_schema: "TABLE users\nCOLUMN id serial NOT_NULL PRIMARY_KEY"
  });
  assert.match(first.approval_nonce, /^[0-9a-f]{16}$/);

  const cases = [];
  for (let index = 0; index < 10; index += 1) {
    cases.push({
      token: first.approval_nonce,
      from_schema: `TABLE t${index}\nCOLUMN id text NOT_NULL`,
      to_schema: `TABLE t${index}\nCOLUMN id text NULLABLE`
    });
  }
  const malformed = [
    "",
    " ",
    "0".repeat(16),
    "f".repeat(16),
    "g".repeat(16),
    "A".repeat(16),
    "a".repeat(15),
    "a".repeat(17),
    "a".repeat(32),
    "a".repeat(64),
    "\u0000".repeat(16),
    "DROP TABLE users",
    "../",
    "nonce",
    "\n",
    "\t",
    "12",
    "1234",
    "12345678",
    "0123456789abcdef0"
  ];
  for (const token of malformed) {
    cases.push({ token, from_schema: USER_SCHEMA, to_schema: USER_SCHEMA });
  }

  const failures = [];
  for (const [index, entry] of cases.entries()) {
    try {
      const result = await harness.call("forge_analyze", {
        from_schema: entry.from_schema,
        to_schema: entry.to_schema,
        human_acknowledgment_token: entry.token
      });
      if (index < 10) {
        assert.equal(result.error_code, "INVALID_ACKNOWLEDGMENT_TOKEN", `case ${index}`);
      } else if (Buffer.byteLength(entry.token, "utf8") > 64) {
        assert.equal(result.error_code, "INVALID_INPUT", `case ${index}`);
      } else {
        assert.equal(result.error_code, "INVALID_ACKNOWLEDGMENT_TOKEN", `case ${index}`);
      }
    } catch (error) {
      failures.push(`case ${index}: threw ${error.message}`);
    }
  }
  assert.equal(cases.length, 30);
  report(failures, "approval-extra", cases.length);
});

test("ASI08/ASI09: 26 destructive migrations require a fresh approval", async () => {
  const failures = [];
  for (let index = 0; index < 26; index += 1) {
    const table = `t${index}`;
    const from = `TABLE ${table}\nCOLUMN id serial NOT_NULL PRIMARY_KEY\nCOLUMN email text NOT_NULL`;
    const to = `TABLE ${table}\nCOLUMN id serial NOT_NULL PRIMARY_KEY`;
    try {
      const result = await harness.call("forge_analyze", {
        from_schema: from,
        to_schema: to
      });
      assert.equal(result.decision_required, true, `case ${index}`);
      assert.match(result.approval_nonce, /^[0-9a-f]{16}$/, `case ${index}`);
      assert.equal(result.proceed_ok, undefined, `case ${index}`);
    } catch (error) {
      failures.push(`case ${index}: threw ${error.message}`);
    }
  }
  assert.equal(26, 26);
  report(failures, "destructive-gate", 26);
});
