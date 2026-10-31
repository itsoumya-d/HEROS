import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  canonicalStringify,
  createAgenticApp,
  createFileReceiptStore,
  createMemoryReceiptStore,
  createMerkleReceiptStore,
  GENESIS_HASH,
  inclusionProof,
  leafHash,
  merkleRoot,
  verifyInclusionProof
} from "../src/index.js";

function receipt(index, overrides = {}) {
  return {
    receipt_id: `hr_${String(index).padStart(4, "0")}`,
    action: "test.action",
    input_hash: `input-${index}`,
    result_hash: `result-${index}`,
    principal: "agent:test",
    approval: { required: false },
    idempotency_key: null,
    deliberation: null,
    deliberation_hash: null,
    annotations: {
      readOnly: false,
      destructive: false,
      idempotent: true,
      decisionRequired: false
    },
    metadata: {},
    created_at: "2026-10-31T00:00:00.000Z",
    ...overrides
  };
}

function createTamperableStore() {
  const receipts = [];
  return {
    receipts,
    async append(value) {
      receipts.push(value);
      return value;
    },
    async findByIdempotencyKey() {
      return null;
    },
    async recordIdempotency() {},
    async list() {
      return receipts;
    }
  };
}

test("empty tree root is the genesis digest", () => {
  assert.equal(merkleRoot([]), GENESIS_HASH);
  assert.equal(GENESIS_HASH.length, 64);
});

test("leaf hashes are deterministic and exclude derived fields", () => {
  const base = receipt(1);
  const first = leafHash(base);
  const second = leafHash({
    ...base,
    entry_hash: "f".repeat(64),
    merkle_root: "e".repeat(64),
    prev_hash: "d".repeat(64)
  });
  assert.equal(first, second);
  assert.match(first, /^[0-9a-f]{64}$/);
  assert.notEqual(first, leafHash({ ...base, result_hash: "tampered" }));
});

test("inclusion proofs verify for every position at odd and even sizes", async () => {
  for (const size of [1, 2, 3, 4, 5, 9]) {
    const base = createMemoryReceiptStore();
    const store = createMerkleReceiptStore({ store: base });
    for (let index = 0; index < size; index += 1) {
      await store.append(receipt(index));
    }
    assert.equal(store.size(), size);
    assert.equal(store.root(), merkleRoot(
      Array.from({ length: size }, (_, index) => leafHash(receipt(index)))
    ));
    for (let index = 0; index < size; index += 1) {
      const proof = store.inclusionProof(`hr_${String(index).padStart(4, "0")}`);
      assert.equal(proof.index, index);
      assert.equal(proof.size, size);
      assert.equal(verifyInclusionProof(proof), true);
      const tampered = {
        ...proof,
        proof: proof.proof.map((step, position) =>
          position === 0 ? { ...step, hash: "0".repeat(64) } : step
        )
      };
      if (proof.proof.length > 0) {
        assert.equal(verifyInclusionProof(tampered), false);
      }
    }
  }
});

test("verify detects field tampering and broken prev_hash chain", async () => {
  const base = createTamperableStore();
  const store = createMerkleReceiptStore({ store: base });
  await store.append(receipt(1));
  await store.append(receipt(2));
  await store.append(receipt(3));

  let verified = await store.verify();
  assert.equal(verified.ok, true);
  assert.equal(verified.size, 3);

  base.receipts[1].result_hash = "rewritten-result";
  verified = await store.verify();
  assert.equal(verified.ok, false);
  assert.ok(verified.failures.some((failure) =>
    failure.reason === "ENTRY_HASH_MISMATCH"
  ));

  base.receipts[1].result_hash = "result-2";
  base.receipts[2].prev_hash = "f".repeat(64);
  verified = await store.verify();
  assert.equal(verified.ok, false);
  assert.ok(verified.failures.some((failure) =>
    failure.reason === "PREV_HASH_MISMATCH"
  ));
});

test("verify detects a tampered deliberation trace", async () => {
  const base = createTamperableStore();
  const store = createMerkleReceiptStore({ store: base });
  const trace = [{ step: "execute", result_hash: "abc" }];
  const traceHash = createHash("sha256")
    .update(canonicalStringify(trace))
    .digest("hex");
  await store.append(receipt(1, {
    deliberation: {
      triggered: false,
      trace,
      trace_hash: traceHash
    },
    deliberation_hash: traceHash
  }));

  assert.equal((await store.verify()).ok, true);
  base.receipts[0].deliberation.trace.push({ step: "reflect" });
  const verified = await store.verify();
  assert.equal(verified.ok, false);
  assert.ok(verified.failures.some((failure) =>
    failure.reason === "DELIBERATION_TRACE_MISMATCH"
  ));
});

test("file-backed Merkle log survives a new wrapper instance", async () => {
  const dir = await mkdtemp(join(tmpdir(), "heros-merkle-"));
  const path = join(dir, "receipts.json");

  const first = createMerkleReceiptStore({
    store: createFileReceiptStore({ path })
  });
  await first.append(receipt(1));
  await first.append(receipt(2));
  const root = first.root();

  const second = createMerkleReceiptStore({
    store: createFileReceiptStore({ path })
  });
  await second.append(receipt(3));

  assert.equal(second.size(), 3);
  assert.equal(second.inclusionProof("hr_0002").root, second.root());
  assert.notEqual(second.root(), root);
  assert.equal((await second.verify()).ok, true);
});

test("proof helpers reject malformed input", () => {
  assert.equal(inclusionProof([], 0), null);
  assert.equal(inclusionProof(["a"], 1), null);
  assert.equal(verifyInclusionProof({ leaf: "a", root: "b", proof: [] }), false);
  assert.equal(verifyInclusionProof({ leaf: "a", root: "b", proof: [{ hash: "c", position: "up" }] }), false);
});

test("the execute response carries Merkle fields from the wrapper store", async () => {
  const store = createMerkleReceiptStore({ store: createMemoryReceiptStore() });
  const app = createAgenticApp({ receiptStore: store });
  app.action({
    name: "test.action",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {}
    },
    handler: () => ({ ok: true })
  });

  const response = await app.execute({ name: "test.action", input: {} });
  assert.equal(response.ok, true);
  assert.match(response.receipt.entry_hash, /^[0-9a-f]{64}$/);
  assert.equal(response.receipt.prev_hash, GENESIS_HASH);
  assert.equal(response.receipt.merkle_root, store.root());
  assert.equal(
    verifyInclusionProof(store.inclusionProof(response.receipt.receipt_id)),
    true
  );
});
