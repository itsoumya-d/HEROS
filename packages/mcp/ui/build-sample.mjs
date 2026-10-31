// Generates verifiable sample receipts for the static Receipt Inspector.
// Run: node packages/mcp/ui/build-sample.mjs

import { writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  createAgenticApp,
  createMemoryApprovalStore,
  createMemoryReceiptStore,
  createMerkleReceiptStore
} from "../../agentic/src/index.js";

const here = dirname(fileURLToPath(import.meta.url));
let tick = 0;
const clock = () => new Date(Date.UTC(2026, 9, 31, 12, 0, tick++));

const baseStore = createMemoryReceiptStore();
const store = createMerkleReceiptStore({ store: baseStore });
const approvalStore = createMemoryApprovalStore();

const app = createAgenticApp({
  name: "heros-receipt-inspector",
  version: "0.3.0",
  receiptStore: store,
  approvalStore,
  clock,
  authorize: ({ context }) =>
    context.apiKey ? { principal: "agent:release-bot" } : false
});

app.action({
  name: "catalog.search",
  title: "Search catalog",
  description: "Read-only catalog lookup.",
  inputSchema: {
    type: "object",
    required: ["query"],
    additionalProperties: false,
    properties: {
      query: { type: "string", minLength: 1, maxLength: 64, safeText: true }
    }
  },
  authRequired: true,
  annotations: { readOnly: true, idempotent: true },
  receiptMetadata: { surface: "catalog", risk: "none" },
  handler: ({ input }) => ({ matches: 3, query: input.query })
});

app.action({
  name: "migration.apply",
  title: "Apply schema migration",
  description: "Approval-gated migration with score-triggered reflection.",
  inputSchema: {
    type: "object",
    required: ["from_schema", "to_schema"],
    additionalProperties: false,
    properties: {
      from_schema: { type: "string", minLength: 1, maxLength: 512, safeText: true },
      to_schema: { type: "string", minLength: 1, maxLength: 512, safeText: true }
    }
  },
  authRequired: true,
  approvalRequired: true,
  annotations: { destructive: true },
  receiptMetadata: { surface: "forge", gate: "shadow+listwise" },
  verification: {
    threshold: 0.72,
    errorCodes: ["SHADOW_RISK_HIGH"],
    maxAttempts: 1,
    verify: async ({ result }) => ({
      score: result.risk_score < 0.4 ? 0.91 : 0.31,
      errorCode: result.risk_score < 0.4 ? null : "SHADOW_RISK_HIGH"
    }),
    reflect: async () => ({
      result: {
        plan: "expand -> backfill -> contract",
        risk_score: 0.22,
        shadow: { dropped_columns: 1, rows_at_risk: 3 }
      }
    })
  },
  handler: () => ({
    plan: "drop email immediately",
    risk_score: 0.82,
    shadow: { dropped_columns: 1, rows_at_risk: 3 }
  })
});

app.action({
  name: "invoice.create",
  title: "Create invoice",
  description: "Idempotent invoice creation.",
  inputSchema: {
    type: "object",
    required: ["to", "amount"],
    additionalProperties: false,
    properties: {
      to: { type: "string", minLength: 1, maxLength: 64, safeText: true },
      amount: { type: "number", minimum: 0.01, maximum: 1000000 }
    }
  },
  authRequired: true,
  annotations: { idempotent: true },
  receiptMetadata: { surface: "ledger" },
  handler: ({ input }) => ({ invoice_id: "inv_demo_001", amount: input.amount })
});

await app.execute({
  name: "catalog.search",
  input: { query: "wasm kernels" },
  context: { apiKey: "demo" }
});

const challenge = await app.execute({
  name: "migration.apply",
  input: {
    from_schema: "users(id,email)",
    to_schema: "users(id)"
  },
  context: { apiKey: "demo" }
});

await app.execute({
  name: "migration.apply",
  input: {
    from_schema: "users(id,email)",
    to_schema: "users(id)"
  },
  context: { apiKey: "demo" },
  approvalToken: challenge.approval.approval_token
});

await app.execute({
  name: "invoice.create",
  input: { to: "Vendor Inc", amount: 4200 },
  context: { apiKey: "demo" },
  idempotencyKey: "invoice-demo-001"
});

const receipts = await store.list();
const payload = {
  generated_at: "2026-10-31T12:00:00.000Z",
  schema_version: 2,
  merkle_root: store.root(),
  receipts
};

await writeFile(
  join(here, "sample-receipts.json"),
  `${JSON.stringify(payload, null, 2)}\n`
);
console.log(JSON.stringify({
  receipts: receipts.length,
  root: store.root(),
  verified: (await store.verify()).ok
}));
