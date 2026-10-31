// SPDX-License-Identifier: MIT
// Append-only SHA-256 Merkle log for HEROS action receipts.
//
// Leaf:   SHA256(0x00 || canonical_json(unsigned_projection))
// Parent: SHA256(0x01 || left_digest || right_digest)
// Odd nodes are promoted unchanged.

import { createHash } from "node:crypto";
import { canonicalStringify } from "./canonical.js";

export const GENESIS_HASH = "0".repeat(64);

const UNSIGNED_KEYS = [
  "receipt_id",
  "action",
  "input_hash",
  "result_hash",
  "principal",
  "approval_state",
  "idempotency_key",
  "deliberation_hash",
  "annotations",
  "metadata",
  "created_at"
];

export function receiptProjection(receipt) {
  return {
    schema_version: 2,
    receipt_id: receipt.receipt_id,
    action: receipt.action,
    input_hash: receipt.input_hash,
    result_hash: receipt.result_hash,
    principal: receipt.principal,
    approval_state: receipt.approval_state ?? receipt.approval ?? {
      required: false
    },
    idempotency_key: receipt.idempotency_key ?? null,
    deliberation_hash: receipt.deliberation_hash ?? null,
    annotations: receipt.annotations ?? {},
    metadata: receipt.metadata ?? {},
    created_at: receipt.created_at
  };
}

export function leafHash(receipt) {
  return createHash("sha256")
    .update(Buffer.from([0]))
    .update(canonicalStringify(receiptProjection(receipt)))
    .digest("hex");
}

export function parentHash(left, right) {
  return createHash("sha256")
    .update(Buffer.from([1]))
    .update(Buffer.from(left, "hex"))
    .update(Buffer.from(right, "hex"))
    .digest("hex");
}

export function merkleRoot(leaves) {
  if (!Array.isArray(leaves) || leaves.length === 0) {
    return GENESIS_HASH;
  }
  let level = leaves.slice();
  while (level.length > 1) {
    const next = [];
    for (let index = 0; index < level.length; index += 2) {
      next.push(
        index + 1 < level.length
          ? parentHash(level[index], level[index + 1])
          : level[index]
      );
    }
    level = next;
  }
  return level[0];
}

export function inclusionProof(leaves, index) {
  if (!Array.isArray(leaves) || !Number.isInteger(index)) return null;
  if (index < 0 || index >= leaves.length) return null;

  const proof = [];
  let level = leaves.slice();
  let cursor = index;

  while (level.length > 1) {
    const isRight = cursor % 2 === 1;
    const sibling = isRight ? cursor - 1 : cursor + 1;
    if (sibling >= 0 && sibling < level.length) {
      proof.push({
        hash: level[sibling],
        position: isRight ? "left" : "right"
      });
    }

    const next = [];
    for (let offset = 0; offset < level.length; offset += 2) {
      next.push(
        offset + 1 < level.length
          ? parentHash(level[offset], level[offset + 1])
          : level[offset]
      );
    }
    level = next;
    cursor = Math.floor(cursor / 2);
  }

  return {
    leaf: leaves[index],
    index,
    size: leaves.length,
    root: level[0],
    proof
  };
}

export function verifyInclusionProof({ leaf, root, proof }) {
  if (typeof leaf !== "string" || typeof root !== "string") return false;
  if (!Array.isArray(proof)) return false;

  let cursor = leaf;
  for (const step of proof) {
    if (!step || typeof step.hash !== "string") return false;
    if (step.position === "left") {
      cursor = parentHash(step.hash, cursor);
    } else if (step.position === "right") {
      cursor = parentHash(cursor, step.hash);
    } else {
      return false;
    }
  }
  return cursor === root;
}

export function createMerkleReceiptStore({ store } = {}) {
  if (!store || typeof store.append !== "function" || typeof store.list !== "function") {
    throw new Error("createMerkleReceiptStore requires a receipt store with append() and list().");
  }

  const entries = [];
  let loaded = false;

  async function ensureLoaded() {
    if (loaded) return;
    const receipts = await store.list();
    for (const receipt of receipts) {
      entries.push({
        receipt_id: receipt.receipt_id,
        leaf: leafHash(receipt)
      });
    }
    loaded = true;
  }

  function currentLeaves() {
    return entries.map((entry) => entry.leaf);
  }

  return {
    async append(receipt) {
      await ensureLoaded();

      const projected = receiptProjection(receipt);
      const previous = entries.length > 0
        ? entries[entries.length - 1].leaf
        : GENESIS_HASH;

      const candidate = {
        ...receipt,
        approval_state: projected.approval_state,
        deliberation_hash: projected.deliberation_hash,
        prev_hash: previous
      };
      const leaf = leafHash(candidate);
      const root = merkleRoot([...currentLeaves(), leaf]);
      const saved = {
        ...candidate,
        entry_hash: leaf,
        merkle_root: root
      };

      const appended = await store.append(saved);
      entries.push({ receipt_id: saved.receipt_id, leaf });
      return appended;
    },

    async findByIdempotencyKey(key) {
      await ensureLoaded();
      return store.findByIdempotencyKey(key);
    },

    async recordIdempotency(key, actionHash, response) {
      await ensureLoaded();
      return store.recordIdempotency(key, actionHash, response);
    },

    async list() {
      await ensureLoaded();
      return store.list();
    },

    root() {
      return merkleRoot(currentLeaves());
    },

    size() {
      return entries.length;
    },

    inclusionProof(receiptId) {
      const index = entries.findIndex((entry) => entry.receipt_id === receiptId);
      if (index < 0) return null;
      return inclusionProof(currentLeaves(), index);
    },

    async verify() {
      const receipts = await store.list();
      const failures = [];
      const leaves = [];
      let previous = GENESIS_HASH;

      receipts.forEach((receipt, index) => {
        const leaf = leafHash(receipt);
        leaves.push(leaf);

        if (receipt.entry_hash !== undefined && receipt.entry_hash !== leaf) {
          failures.push({
            index,
            receipt_id: receipt.receipt_id,
            reason: "ENTRY_HASH_MISMATCH"
          });
        }
        if (receipt.prev_hash !== undefined && receipt.prev_hash !== previous) {
          failures.push({
            index,
            receipt_id: receipt.receipt_id,
            reason: "PREV_HASH_MISMATCH"
          });
        }
        if (
          receipt.deliberation &&
          receipt.deliberation_hash !== undefined &&
          hashJson(receipt.deliberation.trace) !== receipt.deliberation_hash
        ) {
          failures.push({
            index,
            receipt_id: receipt.receipt_id,
            reason: "DELIBERATION_TRACE_MISMATCH"
          });
        }
        previous = leaf;
      });

      const root = merkleRoot(leaves);
      return {
        ok: failures.length === 0,
        size: receipts.length,
        root,
        failures
      };
    }
  };
}

function hashJson(value) {
  return createHash("sha256")
    .update(canonicalStringify(value))
    .digest("hex");
}

export { UNSIGNED_KEYS };
