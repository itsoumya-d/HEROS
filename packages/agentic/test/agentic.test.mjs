import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  createAgenticApp,
  createFileApprovalStore,
  createFileReceiptStore,
  createMemoryApprovalStore,
  createMemoryReceiptStore
} from "../src/index.js";

const addItemSchema = {
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
    quantity: {
      type: "integer",
      minimum: 1,
      maximum: 10
    }
  }
};

test("registers actions and exposes an MCP-shaped manifest", () => {
  const app = createAgenticApp({
    name: "shop-agentic",
    version: "0.1.0",
    description: "Shop actions for agents."
  });

  app.action({
    name: "cart.add_item",
    title: "Add item",
    description: "Add a catalog item to the cart.",
    inputSchema: addItemSchema,
    authRequired: true,
    annotations: {
      idempotent: true
    },
    handler: () => ({ added: true })
  });

  const manifest = app.manifest();
  assert.equal(manifest.mcp_protocol_version, "2025-11-25");
  assert.equal(manifest.tools.length, 1);
  assert.equal(manifest.tools[0].name, "cart.add_item");
  assert.equal(manifest.tools[0].annotations.idempotent, true);
  assert.equal(manifest.tools[0].input_schema.properties.sku.safeText, true);
});

test("rejects unsafe user-facing action metadata", () => {
  const app = createAgenticApp();

  assert.throws(
    () => app.action({
      name: "cart.add_item",
      title: "Add cafe item",
      description: "Caf\u00e9 action.",
      inputSchema: addItemSchema,
      handler: () => ({})
    }),
    /printable ASCII/
  );

  assert.throws(
    () => app.action({
      name: "cart add item",
      inputSchema: addItemSchema,
      handler: () => ({})
    }),
    /Action name/
  );
});

test("executes a valid action and emits an auditable receipt", async () => {
  const receiptStore = createMemoryReceiptStore();
  const app = createAgenticApp({
    receiptStore,
    authorize: () => ({ principal: "agent:test" })
  });

  app.action({
    name: "cart.add_item",
    title: "Add item",
    description: "Add a catalog item to the cart.",
    inputSchema: addItemSchema,
    authRequired: true,
    handler: ({ input }) => ({
      line: `${input.sku}:${input.quantity}`
    })
  });

  const response = await app.execute({
    name: "cart.add_item",
    input: { sku: "BOOK-1", quantity: 2 },
    context: { apiKey: "test" }
  });

  assert.equal(response.ok, true);
  assert.equal(response.action, "cart.add_item");
  assert.equal(response.result.line, "BOOK-1:2");
  assert.match(response.receipt.receipt_id, /^hr_/);
  assert.equal(response.receipt.principal, "agent:test");
  assert.equal(response.receipt.approval.required, false);
  assert.equal((await receiptStore.list()).length, 1);
});

test("rejects invalid input with deterministic error shape", async () => {
  const app = createAgenticApp();
  app.action({
    name: "cart.add_item",
    inputSchema: addItemSchema,
    handler: () => ({})
  });

  const wrongType = await app.execute({
    name: "cart.add_item",
    input: { sku: "BOOK-1", quantity: "2" }
  });
  assert.equal(wrongType.ok, false);
  assert.equal(wrongType.error_code, "INVALID_INPUT");
  assert.equal(wrongType.retryable, false);

  const extraField = await app.execute({
    name: "cart.add_item",
    input: { sku: "BOOK-1", quantity: 2, coupon: "SAVE" }
  });
  assert.equal(extraField.error_code, "INVALID_INPUT");
  assert.match(extraField.issues.join(" "), /not allowed/);

  const unsafeText = await app.execute({
    name: "cart.add_item",
    input: { sku: "BOOK-\n", quantity: 2 }
  });
  assert.equal(unsafeText.error_code, "INVALID_INPUT");
});

test("preserves auth denial for protected actions", async () => {
  const app = createAgenticApp({
    authorize: ({ context }) => context.apiKey === "ok"
      ? { principal: "agent:authorized", scopes: ["cart:write"] }
      : false
  });

  app.action({
    name: "cart.add_item",
    inputSchema: addItemSchema,
    authRequired: true,
    handler: () => ({ added: true })
  });

  const denied = await app.execute({
    name: "cart.add_item",
    input: { sku: "BOOK-1", quantity: 1 }
  });
  assert.equal(denied.ok, false);
  assert.equal(denied.error_code, "UNAUTHORIZED");

  const allowed = await app.execute({
    name: "cart.add_item",
    input: { sku: "BOOK-1", quantity: 1 },
    context: { apiKey: "ok" }
  });
  assert.equal(allowed.ok, true);
  assert.equal(allowed.receipt.principal, "agent:authorized");
});

test("requires, redeems, and invalidates approval tokens", async () => {
  const app = createAgenticApp({
    approvalStore: createMemoryApprovalStore(),
    authorize: () => ({ principal: "agent:checkout" })
  });

  app.action({
    name: "checkout.apply_discount",
    title: "Apply discount",
    description: "Apply a discount to the current cart.",
    inputSchema: {
      type: "object",
      required: ["code"],
      additionalProperties: false,
      properties: {
        code: {
          type: "string",
          minLength: 3,
          maxLength: 24,
          pattern: "^[A-Z0-9-]+$",
          safeText: true
        }
      }
    },
    authRequired: true,
    approvalRequired: true,
    annotations: {
      destructive: true
    },
    handler: ({ input }) => ({ applied: input.code })
  });

  const challenge = await app.execute({
    name: "checkout.apply_discount",
    input: { code: "SAVE-25" },
    context: { apiKey: "ok" }
  });
  assert.equal(challenge.ok, false);
  assert.equal(challenge.error_code, "APPROVAL_REQUIRED");
  assert.match(challenge.approval.approval_token, /^ha_/);

  const mismatched = await app.execute({
    name: "checkout.apply_discount",
    input: { code: "OTHER" },
    context: { apiKey: "ok" },
    approvalToken: challenge.approval.approval_token
  });
  assert.equal(mismatched.error_code, "INVALID_APPROVAL_TOKEN");

  const approved = await app.execute({
    name: "checkout.apply_discount",
    input: { code: "SAVE-25" },
    context: { apiKey: "ok" },
    approvalToken: challenge.approval.approval_token
  });
  assert.equal(approved.ok, true);
  assert.equal(approved.receipt.approval.required, true);
  assert.equal(approved.receipt.approval.approved_by, "agent:checkout");

  const reused = await app.execute({
    name: "checkout.apply_discount",
    input: { code: "SAVE-25" },
    context: { apiKey: "ok" },
    approvalToken: challenge.approval.approval_token
  });
  assert.equal(reused.error_code, "INVALID_APPROVAL_TOKEN");
});

test("replays idempotent results and rejects idempotency conflicts", async () => {
  let calls = 0;
  const app = createAgenticApp();
  app.action({
    name: "cart.add_item",
    inputSchema: addItemSchema,
    annotations: {
      idempotent: true
    },
    handler: () => {
      calls += 1;
      return { calls };
    }
  });

  const first = await app.execute({
    name: "cart.add_item",
    input: { sku: "BOOK-1", quantity: 1 },
    idempotencyKey: "cart-add-1"
  });
  const replay = await app.execute({
    name: "cart.add_item",
    input: { sku: "BOOK-1", quantity: 1 },
    idempotencyKey: "cart-add-1"
  });
  const conflict = await app.execute({
    name: "cart.add_item",
    input: { sku: "BOOK-1", quantity: 2 },
    idempotencyKey: "cart-add-1"
  });

  assert.equal(first.ok, true);
  assert.equal(replay.ok, true);
  assert.equal(replay._idempotent, true);
  assert.equal(replay.receipt.receipt_id, first.receipt.receipt_id);
  assert.equal(calls, 1);
  assert.equal(conflict.error_code, "IDEMPOTENCY_CONFLICT");
});

test("file receipt store persists receipts and idempotency across app instances", async () => {
  const dir = await mkdtemp(join(tmpdir(), "heros-agentic-"));
  const receiptPath = join(dir, "receipts.json");
  let calls = 0;

  function appWithStore() {
    const app = createAgenticApp({
      receiptStore: createFileReceiptStore({ path: receiptPath })
    });
    app.action({
      name: "cart.add_item",
      inputSchema: addItemSchema,
      annotations: {
        idempotent: true
      },
      handler: () => {
        calls += 1;
        return { calls };
      }
    });
    return app;
  }

  const first = await appWithStore().execute({
    name: "cart.add_item",
    input: { sku: "BOOK-1", quantity: 1 },
    idempotencyKey: "persisted-key"
  });
  const replay = await appWithStore().execute({
    name: "cart.add_item",
    input: { sku: "BOOK-1", quantity: 1 },
    idempotencyKey: "persisted-key"
  });
  const receipts = await createFileReceiptStore({ path: receiptPath }).list();

  assert.equal(first.ok, true);
  assert.equal(replay.ok, true);
  assert.equal(replay._idempotent, true);
  assert.equal(replay.receipt.receipt_id, first.receipt.receipt_id);
  assert.equal(receipts.length, 1);
  assert.equal(calls, 1);
});

test("file approval store persists approval challenges across app instances", async () => {
  const dir = await mkdtemp(join(tmpdir(), "heros-agentic-"));
  const approvalPath = join(dir, "approvals.json");

  function appWithStore() {
    const app = createAgenticApp({
      approvalStore: createFileApprovalStore({ path: approvalPath }),
      authorize: () => ({ principal: "agent:checkout" })
    });
    app.action({
      name: "checkout.apply_discount",
      inputSchema: {
        type: "object",
        required: ["code"],
        additionalProperties: false,
        properties: {
          code: {
            type: "string",
            minLength: 3,
            maxLength: 24,
            pattern: "^[A-Z0-9-]+$",
            safeText: true
          }
        }
      },
      authRequired: true,
      approvalRequired: true,
      handler: ({ input }) => ({ applied: input.code })
    });
    return app;
  }

  const challenge = await appWithStore().execute({
    name: "checkout.apply_discount",
    input: { code: "SAVE-25" },
    context: { apiKey: "ok" }
  });
  const approved = await appWithStore().execute({
    name: "checkout.apply_discount",
    input: { code: "SAVE-25" },
    context: { apiKey: "ok" },
    approvalToken: challenge.approval.approval_token
  });
  const reused = await appWithStore().execute({
    name: "checkout.apply_discount",
    input: { code: "SAVE-25" },
    context: { apiKey: "ok" },
    approvalToken: challenge.approval.approval_token
  });

  assert.equal(challenge.error_code, "APPROVAL_REQUIRED");
  assert.equal(approved.ok, true);
  assert.equal(approved.receipt.approval.required, true);
  assert.equal(reused.error_code, "INVALID_APPROVAL_TOKEN");
});
