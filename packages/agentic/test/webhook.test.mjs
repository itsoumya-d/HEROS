import test from "node:test";
import assert from "node:assert/strict";
import {
  computeWebhookSignature,
  verifyWebhookSignature,
  createWebhookDispatcher
} from "../src/webhook.js";

test("verifyWebhookSignature validates correct HMAC and rejects bad signatures", () => {
  const secret = "whsec_test_secret_key_123";
  const body = JSON.stringify({ id: "evt_001", type: "order.created" });
  const sig = computeWebhookSignature(body, secret);

  assert.equal(verifyWebhookSignature(body, sig, secret), true);
  assert.equal(verifyWebhookSignature(body, `sha256=${sig}`, secret), true);
  assert.equal(verifyWebhookSignature(body, "bad_signature_hex_000000000000000000000000000000000000000000000000", secret), false);
  assert.equal(verifyWebhookSignature(body, "", secret), false);
  assert.equal(verifyWebhookSignature(body, sig, "wrong_secret"), false);
});

test("createWebhookDispatcher processes valid event and returns result", async () => {
  const secret = "whsec_test_secret";
  const dispatcher = createWebhookDispatcher({ secret });
  const body = JSON.stringify({ id: "evt_101", customerId: "cust_1" });
  const sig = computeWebhookSignature(body, secret);

  let called = 0;
  const res = await dispatcher.dispatch(body, sig, async (payload) => {
    called++;
    return { status: "processed", customer: payload.customerId };
  });

  assert.equal(called, 1);
  assert.equal(res.replayed, false);
  assert.equal(res.eventId, "evt_101");
  assert.equal(res.result.status, "processed");
  assert.equal(dispatcher.getProcessedEventsCount(), 1);
});

test("createWebhookDispatcher replays identical eventId without re-executing handler", async () => {
  const secret = "whsec_test_secret";
  const dispatcher = createWebhookDispatcher({ secret });
  const body = JSON.stringify({ id: "evt_replay_99", amount: 500 });
  const sig = computeWebhookSignature(body, secret);

  let executions = 0;
  const handler = async (payload) => {
    executions++;
    return { charged: payload.amount };
  };

  const first = await dispatcher.dispatch(body, sig, handler);
  assert.equal(first.replayed, false);
  assert.equal(first.result.charged, 500);
  assert.equal(executions, 1);

  const second = await dispatcher.dispatch(body, sig, handler);
  assert.equal(second.replayed, true);
  assert.equal(second.result.charged, 500);
  assert.equal(executions, 1); // Handler NOT called again
});

test("createWebhookDispatcher retries on transient errors and succeeds", async () => {
  const secret = "whsec_retry_secret";
  const dispatcher = createWebhookDispatcher({ secret, maxRetries: 3, initialBackoffMs: 5 });
  const body = JSON.stringify({ id: "evt_retry_01", job: "sync" });
  const sig = computeWebhookSignature(body, secret);

  let attempts = 0;
  const res = await dispatcher.dispatch(body, sig, async () => {
    attempts++;
    if (attempts < 2) {
      throw new Error("Temporary network timeout");
    }
    return { ok: true };
  });

  assert.equal(attempts, 2);
  assert.equal(res.attempts, 2);
  assert.equal(res.result.ok, true);
  assert.equal(dispatcher.getDeadLetters().length, 0);
});

test("createWebhookDispatcher routes to dead-letter queue after max attempts exceeded", async () => {
  const secret = "whsec_dlq_secret";
  const dispatcher = createWebhookDispatcher({ secret, maxRetries: 2, initialBackoffMs: 5 });
  const body = JSON.stringify({ id: "evt_failed_01", job: "failing_task" });
  const sig = computeWebhookSignature(body, secret);

  let attempts = 0;
  await assert.rejects(
    async () => {
      await dispatcher.dispatch(body, sig, async () => {
        attempts++;
        throw new Error("Persistent database failure");
      });
    },
    (err) => {
      assert.equal(err.code, "DISPATCH_EXHAUSTED");
      assert.equal(err.attempts, 2);
      return true;
    }
  );

  assert.equal(attempts, 2);
  const dlq = dispatcher.getDeadLetters();
  assert.equal(dlq.length, 1);
  assert.equal(dlq[0].eventId, "evt_failed_01");
  assert.equal(dlq[0].error, "Persistent database failure");
});

test("createWebhookDispatcher rejects invalid signature with 401 status", async () => {
  const dispatcher = createWebhookDispatcher({ secret: "whsec_correct" });
  const body = JSON.stringify({ id: "evt_bad_sig" });

  await assert.rejects(
    async () => {
      await dispatcher.dispatch(body, "invalid_sig", async () => {});
    },
    (err) => {
      assert.equal(err.code, "INVALID_SIGNATURE");
      assert.equal(err.statusCode, 401);
      return true;
    }
  );
});
