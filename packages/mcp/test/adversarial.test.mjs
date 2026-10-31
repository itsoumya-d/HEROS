// SPDX-License-Identifier: MIT
// 290-case adversarial boundary corpus. Cases are grouped by OWASP Agentic
// Security Initiative (ASI) vector families. Each case must fail closed or
// return a bounded JSON result; no case may throw or crash the server.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createSession } from "../src/server.js";
import { createAgenticApp } from "../../agentic/src/index.js";
import { makeHarness } from "./helpers.mjs";

const USER_SCHEMA = "TABLE users\nCOLUMN id serial NOT_NULL PRIMARY_KEY\nCOLUMN email text NOT_NULL";
const DROP_EMAIL_SCHEMA = "TABLE users\nCOLUMN id serial NOT_NULL PRIMARY_KEY";
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
let authSeed;
let authKeys;

before(async () => {
  harness = await makeHarness({ rateLimiter: permissiveLimiter() });
  await harness.rpc("initialize", {});

  app = createAgenticApp({
    authorize: () => ({ principal: "agent:adversarial" })
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

  authSeed = "z".repeat(40);
  authHarness = await makeHarness({
    rateLimiter: permissiveLimiter(),
    hmacSeed: authSeed
  });
  await authHarness.rpc("initialize", {});
  const validKeyId = "1".repeat(32);
  const validSecret = "2".repeat(32);
  authKeys = {
    validRo: `heros_ro_${validKeyId}_${validSecret}`,
    validRoId: validKeyId,
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

test("ASI05/ASI09: 60 malformed JSON-RPC messages never crash the server", async () => {
  const cases = [];

  const explicit = [
    null,
    undefined,
    [],
    [{}],
    "not-an-object",
    42,
    true,
    {},
    { jsonrpc: "2.0" },
    { jsonrpc: "1.0", id: 1, method: "ping" },
    { id: 1, method: "ping" },
    { jsonrpc: "2.0", id: {}, method: "ping" },
    { jsonrpc: "2.0", id: [], method: "ping" },
    { jsonrpc: "2.0", id: "x".repeat(5000), method: "ping" },
    { jsonrpc: "2.0", id: 1, method: "" },
    { jsonrpc: "2.0", id: 1, method: 42 },
    { jsonrpc: "2.0", id: 1, method: null },
    { jsonrpc: "2.0", id: 1, method: "tools/call", params: [] },
    { jsonrpc: "2.0", id: 1, method: "tools/call", params: "x" },
    { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: 42 } },
    { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "Bad Name" } },
    { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "a", arguments: [] } },
    { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "nope" } },
    { jsonrpc: "2.0", id: 1, method: "unknown/method", params: {} },
    { jsonrpc: "2.0", id: 1, method: "initialize", params: [] },
    { jsonrpc: "2.0", id: 1, method: "tools/list", params: [] },
    { jsonrpc: "2.0", id: 1, method: "ping", params: [] },
    { jsonrpc: "2.0", id: 1, method: "notifications/initialized" },
    { jsonrpc: "2.0", method: "ping" },
    { jsonrpc: "2.0", method: 42 },
    { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "forge_analyze", arguments: null } }
  ];
  for (const message of explicit) {
    cases.push({ message, session: harness.session });
  }

  const methods = [
    "",
    " ",
    "\\u0000",
    "tools/call",
    "tools/list",
    "initialize",
    "ping",
    "unknown",
    "a".repeat(500),
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
  let index = 0;
  while (cases.length < 60) {
    cases.push({
      message: {
        jsonrpc: "2.0",
        id: `case-${index}`,
        method: methods[index % methods.length],
        params: params[index % params.length]
      },
      session: harness.session
    });
    index += 1;
  }

  const failures = [];
  for (const [caseIndex, entry] of cases.entries()) {
    try {
      const response = await harness.server.handleMessage(entry.message, entry.session);
      if (response !== null) {
        assert.equal(typeof response, "object");
        assert.equal(Array.isArray(response), false);
        if (response.error) {
          assert.equal(typeof response.error.code, "number");
          assert.equal(typeof response.error.message, "string");
        }
      }
    } catch (error) {
      failures.push(`case ${caseIndex}: threw ${error.message}`);
    }
  }
  assert.equal(cases.length, 60);
  report(failures, "JSON-RPC", cases.length);
});

test("ASI01/ASI02: 78 agentic inputs fail closed under schema validation", async () => {
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
    "ＢＯＯＫ-１",
    "📚-1",
    "BOOK\u202e-1",
    "-DROP TABLE users",
    "' OR 1=1 --",
    "../../etc/passwd",
    "__proto__",
    "constructor",
    "prototype",
    null,
    42,
    true,
    [],
    {},
    "BOOK_1",
    "BOOK.1",
    " BOOK-1",
    "BOOK-1 ",
    "BÖÖK-1",
    "A-"
  ];
  for (const sku of skus) {
    mutations.push({ ...valid, sku });
  }

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
    Number.MAX_SAFE_INTEGER,
    Number.MIN_SAFE_INTEGER,
    NaN,
    Infinity
  ];
  for (const quantity of quantities) {
    mutations.push({ ...valid, quantity });
  }

  mutations.push(
    { sku: "BOOK-1" },
    { quantity: 2 },
    {},
    { sku: "BOOK-1", quantity: 2, extra: true },
    JSON.parse('{"sku":"BOOK-1","quantity":2,"constructor":{"prototype":{"x":1}}}'),
    JSON.parse('{"sku":"BOOK-1","quantity":2,"__proto__":{"polluted":true}}'),
    null,
    [],
    "input",
    42,
    true
  );

  const idempotencyKeys = [
    "",
    " ",
    "key with space",
    "key\nnewline",
    "key/with/slash",
    "key\\backslash",
    "k".repeat(161),
    "ключ",
    "emoji-📚",
    "null\u0000byte"
  ];
  for (const idempotencyKey of idempotencyKeys) {
    mutations.push({ ...valid, idempotencyKey });
  }

  const cases = [
    ...mutations.map((input) => ({ name: "cart.add_item", input })),
    ...Array.from({ length: 8 }, (_, index) => ({
      name: `unknown.action.${index}`,
      input: valid
    })),
    ...Array.from({ length: 6 }, (_, index) => ({
      name: "cart.add_item",
      input: valid,
      idempotencyKey: `valid-key-${index}`
    }))
  ];

  const failures = [];
  let caseCount = 0;
  for (const [index, request] of cases.entries()) {
    caseCount += 1;
    try {
      const response = await app.execute(request);
      if (request.name.startsWith("unknown.")) {
        assert.equal(response.error_code, "UNKNOWN_ACTION");
        continue;
      }
      if (index < mutations.length) {
        assert.equal(response.ok, false, `mutation ${index} unexpectedly succeeded`);
        assert.equal(response.error_code, "INVALID_INPUT");
      } else {
        // The six valid idempotency cases are a control group; they must run.
        assert.equal(response.ok, true);
      }
    } catch (error) {
      failures.push(`case ${index}: threw ${error.message}`);
    }
  }
  assert.equal(caseCount, 78);
  report(failures, "agentic", caseCount);
});

test("ASI03/ASI10: 31 invalid or over-scoped API keys never execute a tool", async () => {
  const target = { ...authHarness.session, initialized: true };
  const cases = [
    "heros_ro_" + "1".repeat(32) + "_" + "9".repeat(32),
    "heros_rw_" + "1".repeat(32) + "_" + "9".repeat(32),
    "heros_ro_short_secret",
    "heros_xx_" + "1".repeat(32) + "_" + "2".repeat(32),
    "heros_ro_" + "Z".repeat(32) + "_" + "2".repeat(32),
    "heros_ro_" + "1".repeat(31) + "_" + "2".repeat(32),
    "heros_ro_" + "1".repeat(33) + "_" + "2".repeat(32),
    "heros_ro_" + "1".repeat(32) + "_" + "2".repeat(31),
    "heros_ro_" + "1".repeat(32) + "_" + "2".repeat(33),
    "heros_ro_" + "1".repeat(32) + "_" + "2".repeat(32) + "\n",
    "heros_ro_" + "1".repeat(32) + "_" + "2".repeat(32) + " ",
    " heros_ro_" + "1".repeat(32) + "_" + "2".repeat(32),
    "heros_ro_" + "1".repeat(32) + "_" + "2".repeat(32) + "_extra",
    "heros_ro_" + "1".repeat(32),
    "heros_ro",
    "heros",
    authKeys.validRo,
    "",
    "null",
    "undefined",
    "Bearer " + "1".repeat(32),
    "heros_ro_" + "1".repeat(32) + "_" + "2".repeat(32) + "\u0000",
    "heros_ro_" + "1".repeat(32) + "_" + "2".repeat(32) + "\nmore",
    "heros_ro_" + "1".repeat(32) + "_" + "2".repeat(32) + "\t",
    "heros_ro_" + "1".repeat(32) + "_" + "2".repeat(32) + "'",
    "heros_ro_" + "1".repeat(32) + "_" + "2".repeat(32) + "\"",
    "heros_ro_" + "1".repeat(32) + "_" + "2".repeat(32) + ";",
    "heros_ro_" + "1".repeat(32) + "_" + "2".repeat(32) + "/../",
    "heros_ro_" + "1".repeat(32) + "_" + "2".repeat(32) + "📚",
    "heros_ro_" + "1".repeat(32) + "_" + "2".repeat(32) + "\u202e",
    authKeys.revoked
  ];

  const failures = [];
  for (const [index, key] of cases.entries()) {
    const session = createSession({
      id: `auth-case-${index}`,
      apiKey: key
    });
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
            idempotency_key: `auth-${index}`
          }
        },
        session
      );
      const payload = JSON.parse(response.result.content[0].text);
      if (key === authKeys.validRo) {
        assert.equal(payload.error_code, "INSUFFICIENT_SCOPE");
      } else if (key === "") {
        assert.equal(payload.error_code, "NO_ORG_REGISTERED");
      } else if (key === authKeys.revoked) {
        assert.equal(payload.error_code, "API_KEY_REVOKED");
      } else {
        assert.equal(payload.error_code, "INVALID_API_KEY", `case ${index}`);
      }
    } catch (error) {
      failures.push(`case ${index}: ${error.message}`);
    }
  }
  assert.equal(cases.length, 31);
  report(failures, "auth", cases.length);
});

test("ASI05/ASI06: 60 hostile forge schema payloads are bounded or rejected", async () => {
  const payloads = [];
  const suffixes = [
    "\n",
    "\r\n",
    "\u0000",
    "\u0001",
    "\u001f",
    "\u007f",
    "📚",
    "\u202e",
    "\u001b[31m",
    "' OR 1=1 --",
    "\"; DROP TABLE users; --",
    "../../etc/passwd",
    "__proto__",
    "constructor",
    "A".repeat(128),
    "TABLE duplicate",
    "COLUMN x text MAYBE",
    "DROP TABLE users",
    "|",
    "\t"
  ];
  for (const suffix of suffixes) {
    payloads.push({ from_schema: USER_SCHEMA, to_schema: `${USER_SCHEMA}${suffix}` });
  }
  for (const suffix of suffixes) {
    payloads.push({ from_schema: `${USER_SCHEMA}${suffix}`, to_schema: USER_SCHEMA });
  }
  while (payloads.length < 60) {
    const index = payloads.length;
    payloads.push({
      from_schema: index % 2 === 0 ? USER_SCHEMA : `TABLE t${index}\nCOLUMN id text NOT_NULL`,
      to_schema: index % 3 === 0 ? `${USER_SCHEMA}\nCOLUMN c${index} text NULLABLE` : USER_SCHEMA
    });
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
  assert.equal(payloads.length, 60);
  report(failures, "forge", payloads.length);
});

test("ASI05: 30 malformed shadow schemas fail without executing SQL", async () => {
  const schemas = [
    "",
    " ",
    "\n\n",
    "TABLE",
    "TABLE ",
    "TABLE 1bad",
    "TABLE a-b",
    "TABLE ../escape",
    "TABLE a; DROP TABLE x",
    "COLUMN id text NOT_NULL",
    "TABLE a",
    "TABLE a|COLUMN",
    "TABLE a|COLUMN id",
    "TABLE a|COLUMN id text",
    "TABLE a|COLUMN id text MAYBE",
    "TABLE a|COLUMN id 123 NOT_NULL",
    "TABLE a|COLUMN id text NOT_NULL SORCERY",
    "TABLE a|TABLE a",
    "TABLE a|COLUMN id text NOT_NULL|COLUMN id text NULLABLE",
    "TABLE a|COLUMN id text NOT_NULL|x".repeat(1000),
    "TABLE a\u0000|COLUMN id text NOT_NULL",
    "TABLE a📚|COLUMN id text NOT_NULL",
    "TABLE \u202e|COLUMN id text NOT_NULL",
    "TABLE \"a\"|COLUMN id text NOT_NULL",
    "TABLE a|COLUMN \"id\" text NOT_NULL",
    "TABLE a|COLUMN id text NOT_NULL|PRIMARY",
    "DROP TABLE a",
    "DROP COLUMN id",
    "TABLE a|COLUMN id text NOT_NULL|UNKNOWN token",
    "TABLE a|COLUMN id text NOT_NULL|COLUMN "
  ];

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
  report(failures, "shadow", schemas.length);
});

test("ASI02/ASI07: 30 approval tokens cannot be replayed or rebound", async () => {
  const first = await harness.call("forge_analyze", {
    from_schema: USER_SCHEMA,
    to_schema: DROP_EMAIL_SCHEMA
  });
  assert.match(first.approval_nonce, /^[0-9a-f]{16}$/);
  const approved = await harness.call("forge_analyze", {
    from_schema: USER_SCHEMA,
    to_schema: DROP_EMAIL_SCHEMA,
    human_acknowledgment_token: first.approval_nonce
  });
  assert.equal(approved.proceed_ok, true);

  const cases = [];
  cases.push({
    token: first.approval_nonce,
    from_schema: USER_SCHEMA,
    to_schema: DROP_EMAIL_SCHEMA
  });
  for (let index = 0; index < 9; index += 1) {
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
    "a".repeat(64),
    null,
    42,
    true,
    [],
    {},
    "a".repeat(65),
    "\u0000".repeat(16),
    "📚".repeat(8),
    "DROP TABLE users",
    "../",
    "nonce"
  ];
  for (let index = 0; index < 20; index += 1) {
    cases.push({
      token: malformed[index % malformed.length],
      from_schema: USER_SCHEMA,
      to_schema: `${USER_SCHEMA}\nCOLUMN note${index} text NULLABLE`
    });
  }

  const failures = [];
  for (const [index, entry] of cases.entries()) {
    try {
      const result = await harness.call("forge_analyze", {
        from_schema: entry.from_schema,
        to_schema: entry.to_schema,
        ...(entry.token === undefined
          ? {}
          : { human_acknowledgment_token: entry.token })
      });
      if (
        typeof entry.token === "number" ||
        typeof entry.token === "boolean" ||
        Array.isArray(entry.token) ||
        (typeof entry.token === "object" && entry.token !== null) ||
        (typeof entry.token === "string" && entry.token.length > 64)
      ) {
        assert.equal(result.error_code, "INVALID_INPUT", `case ${index}`);
      } else if (entry.token === null) {
        // An explicit null is treated as no token; a safe migration runs.
        assert.equal(result.error_code, undefined);
      } else {
        assert.equal(
          result.error_code,
          "INVALID_ACKNOWLEDGMENT_TOKEN",
          `case ${index}`
        );
      }
    } catch (error) {
      failures.push(`case ${index}: threw ${error.message}`);
    }
  }
  assert.equal(cases.length, 30);
  report(failures, "approval", cases.length);
});
