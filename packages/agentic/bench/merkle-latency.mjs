// SPDX-License-Identifier: MIT
// Reproducible append latency for the signed Merkle receipt log.
//
// This measures the in-process Merkle wrapper plus Ed25519 signing, not the
// file store's whole-file rewrite. The root is maintained incrementally, so
// append cost should grow with log(size), not size.

import { generateKeyPairSync } from "node:crypto";
import { performance } from "node:perf_hooks";
import {
  createMemoryReceiptStore,
  createMerkleReceiptStore
} from "../src/index.js";

const samples = Number(process.env.SAMPLES ?? 5000);
const warmup = Number(process.env.WARMUP ?? 200);
const { privateKey, publicKey } = generateKeyPairSync("ed25519");
const store = createMerkleReceiptStore({
  store: createMemoryReceiptStore(),
  signer: { privateKey, publicKey }
});

function receipt(index) {
  return {
    receipt_id: `hr_${String(index).padStart(6, "0")}`,
    action: "bench.merkle",
    input_hash: `input-${index}`,
    result_hash: `result-${index}`,
    principal: "agent:bench",
    approval: { required: false },
    idempotency_key: null,
    deliberation: null,
    deliberation_hash: null,
    annotations: { destructive: false },
    metadata: {},
    created_at: "2026-11-03T00:00:00.000Z"
  };
}

for (let index = 0; index < warmup; index += 1) {
  await store.append(receipt(index));
}

const latencies = [];
for (let index = 0; index < samples; index += 1) {
  const start = performance.now();
  const saved = await store.append(receipt(warmup + index));
  if (!saved.merkle_root_signature || !saved.merkle_root) {
    throw new Error("append did not return a signed Merkle root");
  }
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
  tree_size: store.size(),
  node: process.version,
  platform: process.platform,
  arch: process.arch
};
console.log(JSON.stringify(result, null, 2));
