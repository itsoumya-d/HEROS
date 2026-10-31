import test from "node:test";
import assert from "node:assert/strict";
import {
  createAgenticApp,
  createMemoryReceiptStore,
  createMerkleReceiptStore
} from "../src/index.js";

const schema = {
  type: "object",
  required: ["question"],
  additionalProperties: false,
  properties: {
    question: {
      type: "string",
      minLength: 1,
      maxLength: 200,
      safeText: true
    }
  }
};

function buildAction(verification, handler = () => ({ answer: "draft" })) {
  return {
    name: "reason.answer",
    inputSchema: schema,
    verification,
    handler
  };
}

test("no verification means no reflection and no deliberation", async () => {
  let reflected = 0;
  const app = createAgenticApp();
  app.action(buildAction(undefined));
  const response = await app.execute({
    name: "reason.answer",
    input: { question: "What is 2+2?" }
  });

  assert.equal(response.ok, true);
  assert.equal(reflected, 0);
  assert.equal(response.receipt.deliberation, null);
  assert.equal(response.receipt.deliberation_hash, null);
});

test("a low verifier score triggers exactly one reflection and rebinds the receipt", async () => {
  const base = createMemoryReceiptStore();
  const store = createMerkleReceiptStore({ store: base });
  const scores = [0.2, 0.93];
  let verifierCalls = 0;
  let reflectCalls = 0;

  const app = createAgenticApp({ receiptStore: store });
  app.action(buildAction({
    threshold: 0.7,
    maxAttempts: 1,
    verify: async () => ({ score: scores[verifierCalls++] }),
    reflect: async () => {
      reflectCalls += 1;
      return { result: { answer: "revised" } };
    }
  }));

  const response = await app.execute({
    name: "reason.answer",
    input: { question: "Explain entropy." }
  });

  assert.equal(response.ok, true);
  assert.equal(response.result.answer, "revised");
  assert.equal(verifierCalls, 2);
  assert.equal(reflectCalls, 1);
  assert.equal(response.receipt.deliberation.triggered, true);
  assert.equal(response.receipt.deliberation.attempts, 1);
  assert.equal(response.receipt.deliberation.initial_score, 0.2);
  assert.equal(response.receipt.deliberation.final_score, 0.93);
  assert.equal(response.receipt.deliberation.trace.length, 4);
  assert.equal(
    response.receipt.deliberation_hash,
    response.receipt.deliberation.trace_hash
  );
  assert.equal((await store.verify()).ok, true);
});

test("a high verifier score does not reflect", async () => {
  let reflectCalls = 0;
  const app = createAgenticApp();
  app.action(buildAction({
    threshold: 0.7,
    verify: async () => ({ score: 0.95 }),
    reflect: async () => {
      reflectCalls += 1;
      return { result: { answer: "should-not-run" } };
    }
  }));

  const response = await app.execute({
    name: "reason.answer",
    input: { question: "Name a prime." }
  });

  assert.equal(reflectCalls, 0);
  assert.equal(response.result.answer, "draft");
  assert.equal(response.receipt.deliberation.triggered, false);
  assert.equal(response.receipt.deliberation.attempts, 0);
});

test("a configured stable error code triggers reflection even with a high score", async () => {
  let reflectCalls = 0;
  const app = createAgenticApp();
  app.action(buildAction({
    threshold: 0.5,
    errorCodes: ["SHADOW_RISK_HIGH"],
    verify: async () => ({ score: 0.99, errorCode: "SHADOW_RISK_HIGH" }),
    reflect: async () => {
      reflectCalls += 1;
      return { result: { answer: "safe-plan" } };
    }
  }));

  const response = await app.execute({
    name: "reason.answer",
    input: { question: "Drop the users table." }
  });

  assert.equal(reflectCalls, 1);
  assert.equal(response.result.answer, "safe-plan");
  assert.equal(response.receipt.deliberation.triggered, true);
  assert.equal(response.receipt.deliberation.final_error_code, "SHADOW_RISK_HIGH");
});

test("maxAttempts zero records the trigger but never reflects", async () => {
  let reflectCalls = 0;
  const app = createAgenticApp();
  app.action(buildAction({
    threshold: 0.8,
    maxAttempts: 0,
    verify: async () => ({ score: 0.1 }),
    reflect: async () => {
      reflectCalls += 1;
      return { result: { answer: "no" } };
    }
  }));

  const response = await app.execute({
    name: "reason.answer",
    input: { question: "Try again." }
  });

  assert.equal(reflectCalls, 0);
  assert.equal(response.result.answer, "draft");
  assert.equal(response.receipt.deliberation.triggered, true);
  assert.equal(response.receipt.deliberation.attempts, 0);
});

test("verifier failures fail closed with VERIFIER_FAILED", async () => {
  const app = createAgenticApp();
  app.action(buildAction({
    verify: async () => {
      throw new Error("verifier offline");
    }
  }));

  const response = await app.execute({
    name: "reason.answer",
    input: { question: "Q" }
  });

  assert.equal(response.ok, false);
  assert.equal(response.error_code, "VERIFIER_FAILED");
  assert.equal(response.retryable, false);
});

test("a verifier returning a non-numeric score fails closed", async () => {
  const app = createAgenticApp();
  app.action(buildAction({
    verify: async () => ({ score: "high" })
  }));

  const response = await app.execute({
    name: "reason.answer",
    input: { question: "Q" }
  });

  assert.equal(response.error_code, "VERIFIER_FAILED");
});

test("reflection failures fail closed with REFLECTION_FAILED", async () => {
  const app = createAgenticApp();
  app.action(buildAction({
    threshold: 0.9,
    verify: async () => ({ score: 0.1 }),
    reflect: async () => {
      throw new Error("reflector offline");
    }
  }));

  const response = await app.execute({
    name: "reason.answer",
    input: { question: "Q" }
  });

  assert.equal(response.ok, false);
  assert.equal(response.error_code, "REFLECTION_FAILED");
});
