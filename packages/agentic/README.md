# @heros/agentic

`@heros/agentic` is the first HEROS web SDK surface: an explicit action registry that lets an app expose safe, authenticated, auditable actions to AI agents.

It does not try to make any UI magically clickable. Developers declare the actions they want agents to use, attach schemas and safety policy, and expose a deterministic JSON manifest plus an execute endpoint.

## Install

```bash
npm install @heros/agentic
```

Create a starter site:

```bash
npx @heros/agentic init my-agentic-site
```

Check the local environment:

```bash
npx @heros/agentic doctor
```

Until the package is published, use the local workspace:

```bash
npm install file:packages/agentic
node packages/agentic/bin/heros-agentic.mjs doctor
```

## Import

```js
import { createAgenticApp, createFileReceiptStore } from "@heros/agentic";
```

Type declarations are included with the package.

## Minimal Server

```js
const heros = createAgenticApp({
  name: "shop",
  version: "0.1.0",
  receiptStore: createFileReceiptStore({ path: ".heros/receipts.json" }),
  authorize: ({ context }) => context.apiKey === process.env.AGENT_API_KEY
    ? { principal: "agent:shop", scopes: ["cart:write"] }
    : false
});

heros.action({
  name: "cart.add_item",
  title: "Add item",
  description: "Add a catalog item to a shopping cart.",
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
      quantity: {
        type: "integer",
        minimum: 1,
        maximum: 10
      }
    }
  },
  authRequired: true,
  annotations: {
    idempotent: true
  },
  handler: async ({ input, auth }) => {
    return {
      added: true,
      sku: input.sku,
      quantity: input.quantity,
      principal: auth.principal
    };
  }
});
```

Expose `heros.manifest()` from a discovery route, then call `heros.execute()` from your action route.

```js
app.get("/heros/manifest", (req, res) => {
  res.json(heros.manifest());
});

app.post("/heros/actions", async (req, res) => {
  const response = await heros.execute({
    name: req.body.name,
    input: req.body.input,
    context: {
      apiKey: req.headers.authorization?.replace("Bearer ", "")
    },
    idempotencyKey: req.body.idempotencyKey,
    approvalToken: req.body.approvalToken
  });
  res.json(response);
});
```

## Manifest

`manifest()` returns a machine-readable, MCP-compatible tool surface:

- app name, version, and protocol version
- one tool per registered action
- JSON input schema for each action
- annotations for read-only, destructive, idempotent, and decision-required behavior

## Execute

`execute()` accepts structured JSON and always returns a deterministic JSON shape.

Successful actions return:

```json
{
  "ok": true,
  "action": "cart.add_item",
  "result": {},
  "receipt": {},
  "_idempotent": false
}
```

Failures return:

```json
{
  "ok": false,
  "error_code": "INVALID_INPUT",
  "error": "Input does not match the action schema.",
  "retryable": false
}
```

## Auth

Set `authRequired: true` on protected actions. The app-level `authorize` callback receives the action, input, and request context. Return `false` to deny, `true` to allow, or `{ principal, scopes }` to attach an auditable caller identity.

## Approval

Set `approvalRequired: true` when an action needs a human decision before execution. The first call returns `APPROVAL_REQUIRED` with an `approval_token`. After a human approves the request, pass that token to `execute()`. Tokens are bound to the action name and input hash, expire, and can be used once.

## Idempotency

Pass `idempotencyKey` for actions that should be safe to retry. HEROS replays the original response for the same key and same input, and returns `IDEMPOTENCY_CONFLICT` if the key is reused with different input.

## Receipt

Every successful action emits a receipt with:

- receipt id
- action name
- input hash
- result hash
- principal
- approval proof when required
- idempotency key when provided
- action annotations
- timestamp

Receipts are stored in memory by default. Use `createFileReceiptStore()` for dependency-free single-process persistence, or provide a database-backed `receiptStore` for multi-process production deployments.

## Durable Stores

```js
import {
  createAgenticApp,
  createFileApprovalStore,
  createFileReceiptStore
} from "@heros/agentic";

const heros = createAgenticApp({
  receiptStore: createFileReceiptStore({ path: ".heros/receipts.json" }),
  approvalStore: createFileApprovalStore({ path: ".heros/approvals.json" })
});
```

The file stores persist receipts, idempotency records, and approval tokens across process restarts. Use a database-backed store when multiple app processes write to the same action surface.

## Production Checklist

- Keep actions explicit; do not expose arbitrary DOM clicks or free-form code execution.
- Require auth for all state-changing actions.
- Require approval for destructive or high-value actions.
- Use strict schemas with `additionalProperties: false`, length limits, charset limits, and `safeText: true` on user-facing strings.
- Persist receipts and idempotency records outside process memory.
- Run `npm run test:agentic`, `npm run test:agentic-site`, and `npm run demo:agentic` before shipping.
