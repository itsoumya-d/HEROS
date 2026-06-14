# HEROS Agentic Web SDK Demo

This demo shows how an application can expose explicit, safe actions to AI agents without relying on UI scraping or arbitrary browser control.

## What It Proves

- A website can expose a machine-readable action manifest.
- Agents can call declared actions with structured JSON.
- Protected actions can require auth.
- Sensitive actions can require approval before execution.
- Retries can be made safe with idempotency keys.
- Successful calls emit receipts for auditability.

## Run The SDK Proof

```bash
node --test packages/agentic/test/*.test.mjs
node --test examples/agentic-site/test/*.test.mjs
node examples/agentic-site/agent-demo.mjs
```

Expected summary shape:

```json
{
  "ok": true,
  "manifest_tools": [
    "cart.add_item",
    "catalog.search",
    "checkout.apply_discount"
  ],
  "receipts": ["hr_...", "hr_..."]
}
```

## Run The Sample Site

```bash
node examples/agentic-site/server.mjs
```

The server prints a local URL. The sample exposes:

- `GET /heros/manifest`
- `POST /heros/actions`
- `GET /cart`

The protected action endpoint expects:

```text
Authorization: Bearer demo-agent-key
```

## Route-Level Proof

The demo route tests verify:

- landing page renders
- manifest exposes the expected actions
- malformed JSON returns `BAD_JSON`
- unknown routes return `NOT_FOUND`
- unknown actions return `UNKNOWN_ACTION`
- public catalog search works without auth
- protected cart writes reject missing or bad auth
- idempotency replay returns the original receipt
- approval challenges can be redeemed exactly once

## Demo Flow

1. Fetch `/heros/manifest`.
2. Observe the declared actions: `catalog.search`, `cart.add_item`, and `checkout.apply_discount`.
3. Call `cart.add_item` without auth and receive `UNAUTHORIZED`.
4. Call `cart.add_item` with auth and receive a receipt.
5. Retry `cart.add_item` with the same idempotency key and receive the original receipt.
6. Call `checkout.apply_discount` and receive `APPROVAL_REQUIRED`.
7. Retry with the approval token and receive a successful receipt.

## Boundary

This demo intentionally uses explicit actions. It does not infer actions from arbitrary DOM structure and does not grant agents unrestricted browser control.
