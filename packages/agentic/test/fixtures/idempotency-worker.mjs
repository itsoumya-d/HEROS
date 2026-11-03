// SPDX-License-Identifier: MIT
// One worker process for the cross-process idempotency test. Every worker uses
// the same receipt file and idempotency key; only the leader may run handler().

import { appendFile } from "node:fs/promises";
import { createAgenticApp, createFileReceiptStore } from "../../src/index.js";

const storePath = process.env.HEROS_STORE_PATH;
const counterPath = process.env.HEROS_COUNTER_PATH;
const idempotencyKey = process.env.HEROS_IDEMPOTENCY_KEY;

if (!storePath || !counterPath || !idempotencyKey) {
  throw new Error("HEROS_STORE_PATH, HEROS_COUNTER_PATH, and HEROS_IDEMPOTENCY_KEY are required");
}

const app = createAgenticApp({
  receiptStore: createFileReceiptStore({ path: storePath })
});

app.action({
  name: "worker.record",
  inputSchema: {
    type: "object",
    additionalProperties: false,
    properties: {
      value: { type: "integer", minimum: 1, maximum: 10 }
    }
  },
  annotations: {
    idempotent: true
  },
  handler: async ({ input }) => {
    await appendFile(counterPath, `${process.pid}\n`);
    await new Promise((resolve) => setTimeout(resolve, 75));
    return { value: input.value, pid: process.pid };
  }
});

const response = await app.execute({
  name: "worker.record",
  input: { value: 1 },
  idempotencyKey
});

process.stdout.write(
  JSON.stringify({
    ok: response.ok,
    idempotent: response._idempotent,
    receipt_id: response.receipt?.receipt_id ?? null,
    error_code: response.error_code ?? null
  })
);
