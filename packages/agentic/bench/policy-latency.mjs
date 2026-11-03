// SPDX-License-Identifier: MIT
// Reproducible p99 latency for the HEROS agentic execute/policy path.
//
// This measures in-process validation + authorization + receipt append, not
// network or model inference. Run after a warmup; do not compare across machines
// without recording hardware and Node version.

import { performance } from "node:perf_hooks";
import {
  createAgenticApp,
  createMemoryReceiptStore
} from "../src/index.js";

const samples = Number(process.env.SAMPLES ?? 5000);
const warmup = Number(process.env.WARMUP ?? 200);
// This isolates validation + authorization + receipt append. The Merkle wrapper
// recomputes the root on every append (O(n)); measure that separately if the
// question is log throughput, not policy latency.
const app = createAgenticApp({
  receiptStore: createMemoryReceiptStore()
});
app.action({
  name: "bench.noop",
  inputSchema: {
    type: "object",
    additionalProperties: false,
    properties: { value: { type: "integer", minimum: 1, maximum: 10 } }
  },
  handler: ({ input }) => ({ value: input.value })
});

for (let index = 0; index < warmup; index += 1) {
  await app.execute({ name: "bench.noop", input: { value: 1 } });
}

const latencies = [];
for (let index = 0; index < samples; index += 1) {
  const start = performance.now();
  const response = await app.execute({ name: "bench.noop", input: { value: 1 } });
  if (!response.ok) throw new Error("benchmark action failed");
  latencies.push(performance.now() - start);
}

latencies.sort((left, right) => left - right);
const percentile = (fraction) =>
  latencies[Math.min(latencies.length - 1, Math.floor(latencies.length * fraction))];
const mean = latencies.reduce((sum, value) => sum + value, 0) / latencies.length;
const result = {
  samples,
  warmup,
  mean_ms: Number(mean.toFixed(4)),
  p50_ms: Number(percentile(0.5).toFixed(4)),
  p95_ms: Number(percentile(0.95).toFixed(4)),
  p99_ms: Number(percentile(0.99).toFixed(4)),
  p999_ms: Number(percentile(0.999).toFixed(4)),
  max_ms: Number(latencies[latencies.length - 1].toFixed(4)),
  p99_threshold_ms: 4.5,
  p99_pass: percentile(0.99) < 4.5,
  node: process.version,
  platform: process.platform,
  arch: process.arch
};
console.log(JSON.stringify(result, null, 2));
if (!result.p99_pass) process.exitCode = 1;
