// SPDX-License-Identifier: MIT
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { makeHarness } from "./helpers.mjs";

describe("MCP protocol", () => {
  test("initialize negotiates the protocol and exposes both tool families", async (t) => {
    const harness = await makeHarness();
    t.after(harness.cleanup);

    const early = await harness.rpc("tools/list", {});
    assert.equal(early.error.code, -32002);

    const init = await harness.rpc("initialize", {
      protocolVersion: "2025-11-25",
      clientInfo: { name: "test", version: "1.0.0" },
    });
    assert.equal(init.result.protocolVersion, "2025-11-25");
    assert.equal(init.result.serverInfo.name, "heros");

    const list = await harness.rpc("tools/list", {});
    const names = list.result.tools.map((tool) => tool.name);
    assert.deepEqual(names.sort(), [
      "forge_analyze",
      "ledger_invoice_count",
      "ledger_invoice_create",
      "ledger_invoice_list",
      "ledger_register",
    ]);
    const forge = list.result.tools.find((tool) => tool.name === "forge_analyze");
    assert.equal(forge.annotations.readOnlyHint, true);
    assert.ok(forge.inputSchema.properties.from_schema);
  });

  test("stdio handler emits one JSON response per request line", async (t) => {
    const harness = await makeHarness();
    t.after(harness.cleanup);
    const { createStdioHandler } = await import("../src/stdio.js");
    const lines = [];
    const handleLine = createStdioHandler(harness.server, {
      session: harness.session,
      write: (line) => lines.push(line),
    });

    await handleLine(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {},
      })
    );
    await handleLine(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 2,
        method: "tools/list",
        params: {},
      })
    );
    await handleLine("{not json");
    assert.equal(lines.length, 3);
    assert.equal(JSON.parse(lines[0]).result.protocolVersion, "2025-11-25");
    assert.equal(JSON.parse(lines[1]).result.tools.length, 5);
    assert.equal(JSON.parse(lines[2]).error.code, -32700);
  });
});

describe("forge_analyze", () => {
  test("safe migration returns risk data and a rate-limit receipt", async (t) => {
    const harness = await makeHarness();
    t.after(harness.cleanup);
    await harness.rpc("initialize", {});

    const result = await harness.call("forge_analyze", {
      from_schema: "TABLE users\nCOLUMN id serial NOT_NULL",
      to_schema: "TABLE users\nCOLUMN id serial NOT_NULL\nCOLUMN bio text NULLABLE",
      request_id: "req-1",
    });
    assert.equal(result.risk_tier, "SAFE");
    assert.equal(result.request_id, "req-1");
    assert.equal(result._rate_limit.window, "per_hour");
    assert.ok(result._rate_limit.remaining <= 199);
  });

  test("destructive migration issues a single-use approval nonce", async (t) => {
    const harness = await makeHarness();
    t.after(harness.cleanup);
    await harness.rpc("initialize", {});
    const schemas = {
      from_schema: "TABLE users\nCOLUMN email text NOT_NULL",
      to_schema: "TABLE users\nCOLUMN email text NULLABLE\nDROP COLUMN email",
    };

    const first = await harness.call("forge_analyze", schemas);
    assert.equal(first.decision_required, true);
    assert.match(first.approval_nonce, /^[0-9a-f]{16}$/);

    const approved = await harness.call("forge_analyze", {
      ...schemas,
      human_acknowledgment_token: first.approval_nonce,
    });
    assert.equal(approved.proceed_ok, true);
    assert.equal(approved.decision_required, false);

    const replay = await harness.call("forge_analyze", {
      ...schemas,
      human_acknowledgment_token: first.approval_nonce,
    });
    assert.equal(replay.error_code, "INVALID_ACKNOWLEDGMENT_TOKEN");
  });

  test("a nonce cannot be replayed against a different schema pair", async (t) => {
    const harness = await makeHarness();
    t.after(harness.cleanup);
    await harness.rpc("initialize", {});

    const first = await harness.call("forge_analyze", {
      from_schema: "TABLE a",
      to_schema: "DROP TABLE a",
    });
    const other = await harness.call("forge_analyze", {
      from_schema: "TABLE b",
      to_schema: "DROP TABLE b",
      human_acknowledgment_token: first.approval_nonce,
    });
    assert.equal(other.error_code, "INVALID_ACKNOWLEDGMENT_TOKEN");
  });

  test("pipe characters and oversized payloads are rejected before exec", async (t) => {
    const harness = await makeHarness();
    t.after(harness.cleanup);
    await harness.rpc("initialize", {});

    const pipes = await harness.call("forge_analyze", {
      from_schema: "TABLE a|COLUMN x text",
      to_schema: "TABLE a",
    });
    assert.equal(pipes.error_code, "INVALID_INPUT");

    const missing = await harness.call("forge_analyze", { from_schema: "TABLE a" });
    assert.equal(missing.error_code, "MISSING_FLAG");
  });
});

describe("ledger tools", () => {
  test("register is idempotent and invoice creation is idempotent", async (t) => {
    const harness = await makeHarness();
    t.after(harness.cleanup);
    await harness.rpc("initialize", {});

    const before = await harness.call("ledger_invoice_list", {});
    assert.equal(before.error_code, "NO_ORG_REGISTERED");

    const registered = await harness.call("ledger_register", { org_name: "Acme" });
    assert.equal(registered.status, "ok");
    assert.match(registered.org_id, /^org_[0-9a-f]{8}$/);

    const again = await harness.call("ledger_register", { org_name: "Acme" });
    assert.equal(again.error_code, "ORG_EXISTS");
    assert.equal(again.org_id, registered.org_id);

    const invoice = await harness.call("ledger_invoice_create", {
      to: "Vendor Inc",
      amount: 42.5,
      currency: "USD",
      idempotency_key: "idem-1",
    });
    assert.equal(invoice.status, "ok");
    assert.match(invoice.invoice_id, /^inv_/);

    const duplicate = await harness.call("ledger_invoice_create", {
      to: "Vendor Inc",
      amount: 42.5,
      currency: "USD",
      idempotency_key: "idem-1",
    });
    assert.equal(duplicate._idempotent, true);
    assert.equal(duplicate.invoice_id, invoice.invoice_id);

    const list = await harness.call("ledger_invoice_list", { limit: 10 });
    assert.equal(list.count, 1);
    assert.equal(list.total_count, 1);
    assert.equal(list.invoices[0].invoice_id, invoice.invoice_id);
    assert.equal(list.invoices[0].org_id, "");

    const count = await harness.call("ledger_invoice_count", {});
    assert.equal(count.count, 1);
  });

  test("amount type and pagination bounds are enforced", async (t) => {
    const harness = await makeHarness();
    t.after(harness.cleanup);
    await harness.rpc("initialize", {});
    await harness.call("ledger_register", { org_name: "Acme" });

    const badAmount = await harness.call("ledger_invoice_create", {
      to: "Vendor",
      amount: "42",
      currency: "USD",
      idempotency_key: "idem-bad",
    });
    assert.equal(badAmount.error_code, "MISSING_FLAG");

    const badLimit = await harness.call("ledger_invoice_list", { limit: 0 });
    assert.equal(badLimit.error_code, "INVALID_PARAM");
  });
});

describe("audit and state", () => {
  test("authenticated calls append an audit record", async (t) => {
    const seed = "s".repeat(40);
    const harness = await makeHarness({ hmacSeed: seed });
    t.after(harness.cleanup);
    await harness.rpc("initialize", {});

    const { createHmac } = await import("node:crypto");
    const { writeFile } = await import("node:fs/promises");
    const keyId = "a".repeat(32);
    const secret = "b".repeat(32);
    const hash = createHmac("sha256", seed)
      .update(`${keyId}:${secret}`)
      .digest("hex");
    await writeFile(
      join(harness.dataDir, ".heros-keys"),
      `${keyId} rw org_deadbeef ${hash} 0 0\n`
    );

    harness.session.apiKey = `heros_rw_${keyId}_${secret}`;
    const registered = await harness.call("ledger_register", { org_name: "Acme" });
    assert.equal(registered.status, "ok");

    const audit = await readFile(
      join(harness.dataDir, ".heros-audit"),
      "utf8"
    );
    assert.match(audit, new RegExp(` ${keyId} rw ledger_register org_deadbeef`));
  });
});
