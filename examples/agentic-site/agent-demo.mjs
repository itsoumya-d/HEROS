import assert from "node:assert/strict";
import { createDemoServer } from "./server.mjs";

const started = await createDemoServer();

try {
  const manifest = await getJson(`${started.url}/heros/manifest`);
  assert.equal(manifest.name, "heros-agentic-site-demo");
  assert.equal(manifest.tools.some((tool) => tool.name === "cart.add_item"), true);

  const denied = await callAction(started.url, {
    name: "cart.add_item",
    input: { sku: "BOOK-1", quantity: 1 }
  });
  assert.equal(denied.error_code, "UNAUTHORIZED");

  const add = await callAction(started.url, {
    name: "cart.add_item",
    input: { sku: "BOOK-1", quantity: 1 },
    idempotencyKey: "demo-add-book"
  }, "demo-agent-key");
  assert.equal(add.ok, true);
  assert.match(add.receipt.receipt_id, /^hr_/);

  const replay = await callAction(started.url, {
    name: "cart.add_item",
    input: { sku: "BOOK-1", quantity: 1 },
    idempotencyKey: "demo-add-book"
  }, "demo-agent-key");
  assert.equal(replay.ok, true);
  assert.equal(replay._idempotent, true);
  assert.equal(replay.receipt.receipt_id, add.receipt.receipt_id);

  const challenge = await callAction(started.url, {
    name: "checkout.apply_discount",
    input: { code: "SAVE-25" }
  }, "demo-agent-key");
  assert.equal(challenge.error_code, "APPROVAL_REQUIRED");

  const approved = await callAction(started.url, {
    name: "checkout.apply_discount",
    input: { code: "SAVE-25" },
    approvalToken: challenge.approval.approval_token
  }, "demo-agent-key");
  assert.equal(approved.ok, true);
  assert.equal(approved.receipt.approval.required, true);

  const cart = await getJson(`${started.url}/cart`);
  assert.equal(cart.cart.length, 1);
  assert.equal(cart.discount, "SAVE-25");

  console.log(JSON.stringify({
    ok: true,
    manifest_tools: manifest.tools.map((tool) => tool.name),
    receipts: [add.receipt.receipt_id, approved.receipt.receipt_id],
    cart
  }, null, 2));
} finally {
  await new Promise((resolve) => started.server.close(resolve));
}

async function getJson(url) {
  const response = await fetch(url);
  return response.json();
}

async function callAction(url, body, apiKey = "") {
  const response = await fetch(`${url}/heros/actions`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(apiKey ? { authorization: `Bearer ${apiKey}` } : {})
    },
    body: JSON.stringify(body)
  });
  return response.json();
}
