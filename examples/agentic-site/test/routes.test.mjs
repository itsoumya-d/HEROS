import test from "node:test";
import assert from "node:assert/strict";
import { createDemoServer } from "../server.mjs";

test("demo server exposes landing page, manifest, and cart state", async () => {
  const started = await createDemoServer();
  try {
    const landing = await fetch(`${started.url}/`);
    const html = await landing.text();
    assert.equal(landing.status, 200);
    assert.match(html, /HEROS Agentic Site Demo/);

    const manifest = await getJson(`${started.url}/heros/manifest`);
    assert.equal(manifest.status, 200);
    assert.deepEqual(
      manifest.body.tools.map((tool) => tool.name),
      ["cart.add_item", "catalog.search", "checkout.apply_discount"]
    );

    const cart = await getJson(`${started.url}/cart`);
    assert.equal(cart.status, 200);
    assert.deepEqual(cart.body, { cart: [], discount: null });
  } finally {
    await closeServer(started);
  }
});

test("demo server returns deterministic route and JSON errors", async () => {
  const started = await createDemoServer();
  try {
    const missing = await getJson(`${started.url}/missing`);
    assert.equal(missing.status, 404);
    assert.equal(missing.body.error_code, "NOT_FOUND");

    const malformed = await postRaw(`${started.url}/heros/actions`, "{");
    assert.equal(malformed.status, 400);
    assert.equal(malformed.body.error_code, "BAD_JSON");

    const notObject = await postRaw(`${started.url}/heros/actions`, "null");
    assert.equal(notObject.status, 400);
    assert.equal(notObject.body.error_code, "BAD_JSON");

    const unknown = await postAction(started.url, {
      name: "missing.action",
      input: {}
    });
    assert.equal(unknown.status, 400);
    assert.equal(unknown.body.error_code, "UNKNOWN_ACTION");
  } finally {
    await closeServer(started);
  }
});

test("demo server protects state-changing actions and allows public catalog search", async () => {
  const started = await createDemoServer();
  try {
    const search = await postAction(started.url, {
      name: "catalog.search",
      input: { query: "kit" }
    });
    assert.equal(search.status, 200);
    assert.equal(search.body.ok, true);
    assert.equal(search.body.result.items[0].sku, "KIT-1");

    const denied = await postAction(started.url, {
      name: "cart.add_item",
      input: { sku: "BOOK-1", quantity: 1 }
    });
    assert.equal(denied.status, 400);
    assert.equal(denied.body.error_code, "UNAUTHORIZED");

    const badKey = await postAction(started.url, {
      name: "cart.add_item",
      input: { sku: "BOOK-1", quantity: 1 }
    }, "wrong-key");
    assert.equal(badKey.status, 400);
    assert.equal(badKey.body.error_code, "UNAUTHORIZED");
  } finally {
    await closeServer(started);
  }
});

test("demo server preserves idempotency and receipts over HTTP", async () => {
  const started = await createDemoServer();
  try {
    const body = {
      name: "cart.add_item",
      input: { sku: "BOOK-1", quantity: 1 },
      idempotencyKey: "route-add-book"
    };
    const first = await postAction(started.url, body, "demo-agent-key");
    const replay = await postAction(started.url, body, "demo-agent-key");
    const conflict = await postAction(started.url, {
      ...body,
      input: { sku: "BOOK-1", quantity: 2 }
    }, "demo-agent-key");
    const cart = await getJson(`${started.url}/cart`);

    assert.equal(first.status, 200);
    assert.equal(first.body.ok, true);
    assert.match(first.body.receipt.receipt_id, /^hr_/);
    assert.equal(replay.status, 200);
    assert.equal(replay.body._idempotent, true);
    assert.equal(replay.body.receipt.receipt_id, first.body.receipt.receipt_id);
    assert.equal(conflict.status, 400);
    assert.equal(conflict.body.error_code, "IDEMPOTENCY_CONFLICT");
    assert.equal(cart.body.cart.length, 1);
  } finally {
    await closeServer(started);
  }
});

test("demo server supports approval challenge and redemption over HTTP", async () => {
  const started = await createDemoServer();
  try {
    const challenge = await postAction(started.url, {
      name: "checkout.apply_discount",
      input: { code: "SAVE-25" }
    }, "demo-agent-key");
    assert.equal(challenge.status, 400);
    assert.equal(challenge.body.error_code, "APPROVAL_REQUIRED");
    assert.match(challenge.body.approval.approval_token, /^ha_/);

    const invalid = await postAction(started.url, {
      name: "checkout.apply_discount",
      input: { code: "OTHER" },
      approvalToken: challenge.body.approval.approval_token
    }, "demo-agent-key");
    assert.equal(invalid.status, 400);
    assert.equal(invalid.body.error_code, "INVALID_APPROVAL_TOKEN");

    const approved = await postAction(started.url, {
      name: "checkout.apply_discount",
      input: { code: "SAVE-25" },
      approvalToken: challenge.body.approval.approval_token
    }, "demo-agent-key");
    assert.equal(approved.status, 200);
    assert.equal(approved.body.ok, true);
    assert.equal(approved.body.receipt.approval.required, true);

    const cart = await getJson(`${started.url}/cart`);
    assert.equal(cart.body.discount, "SAVE-25");
  } finally {
    await closeServer(started);
  }
});

async function getJson(url) {
  const response = await fetch(url);
  return {
    status: response.status,
    body: await response.json()
  };
}

async function postRaw(url, rawBody) {
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json"
    },
    body: rawBody
  });
  return {
    status: response.status,
    body: await response.json()
  };
}

async function postAction(url, body, apiKey = "") {
  const response = await fetch(`${url}/heros/actions`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(apiKey ? { authorization: `Bearer ${apiKey}` } : {})
    },
    body: JSON.stringify(body)
  });
  return {
    status: response.status,
    body: await response.json()
  };
}

async function closeServer(started) {
  await new Promise((resolve) => started.server.close(resolve));
}
