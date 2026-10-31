# HEROS v2 — Verifiable Kernel Architecture

Status: implementation contract for the Node-executable layer. The Zero-lang
`forge` and `ledger` binaries remain the deterministic business-logic core;
v2 adds verification at the MCP/SDK boundary because the Zero compiler is not
available in the current environment.

## 1. Receipt v2 and Merkle audit log

### 1.1 Canonical unsigned projection

A receipt leaf is computed from the receipt's unsigned projection. The
projection excludes fields that are derived from the leaf or tree:

- `merkle_root`
- `inclusion_proof`
- `prev_hash`
- `entry_hash`

The projection binds:

```
schema_version: 2
receipt_id: string
action: string
input_hash: sha256 hex
result_hash: sha256 hex
principal: string
approval_state: { required, approved_by?, approved_at?, token_hash? }
idempotency_key: string | null
deliberation_hash: sha256 hex | null
annotations: object
metadata: object
created_at: ISO-8601 string
```

Hashing rules:

```
leaf   = SHA256(0x00 || canonical_json(projection))
parent = SHA256(0x01 || left || right)   // left/right are 32-byte digests
```

Odd levels promote the final node unchanged (no duplication). `prev_hash` is
the previous leaf hash, or 64 zeros for genesis. This makes the log an
append-only hash chain and a Merkle tree over the same leaves.

### 1.2 Guarantees

1. Changing any unsigned field changes the leaf and the root.
2. Changing `merkle_root` alone does not change the leaf (it is excluded), but
   `verify()` recomputes the root from leaves and rejects a forged root.
3. An inclusion proof verifies only against the root it was issued for.
4. A receipt cannot be silently removed from the middle of the log: the
   `prev_hash` chain and root recomputation both fail.

### 1.3 API (`@heros/agentic`)

```js
import { createMerkleReceiptStore } from "@heros/agentic";

const store = createMerkleReceiptStore({ store: baseStore });
await store.append(receipt);       // adds entry_hash, prev_hash, merkle_root
store.root();                      // current root hex
store.inclusionProof(receiptId);   // { leaf, index, size, root, proof }
await store.verify();              // { ok, size, root, failures }
```

## 2. Score-triggered reflection

Reflection is opt-in per action and is never unconditional.

```js
app.action({
  name: "migration.apply",
  inputSchema,
  verification: {
    threshold: 0.72,
    errorCodes: ["SHADOW_RISK_HIGH"],
    maxAttempts: 1,
    verify: async ({ result }) => ({ score: 0.41, errorCode: "SHADOW_RISK_HIGH" }),
    reflect: async ({ result, verification }) => ({ result: revised })
  },
  handler
});
```

Trigger iff `score < threshold` OR `errorCode` is in `errorCodes`. The
deliberation trace records execute/verify/reflect steps; its canonical hash is
bound into the receipt as `deliberation_hash`. No trigger means no reflection
call and `deliberation.triggered === false`.

## 3. Shadow sandbox and list-wise PRM gate

### 3.1 Engine

`packages/mcp/src/shadow.js` builds an ephemeral SQLite database from the
`from_schema`, seeds deterministic rows, applies the target schema with real
DDL/DML, and compares pre/post values. SQLite is accessed through
`node:sqlite` when available, otherwise the `sqlite3` CLI on a temp file. If
neither is available, the response reports a schema-only fallback engine; it
never claims SQL execution.

### 3.2 Operations

Detected operations: `add_table`, `drop_table`, `add_col`, `drop_col`,
`set_not_null`, `drop_not_null`, `set_default`, `drop_default`, `change_type`.
Each operation reports `executed`, `data_loss`, `error_code`, `rows_affected`,
and a human-readable `detail`.

### 3.3 List-wise PRM

Candidates: `allow`, `require_approval`, `deny`. Each candidate is scored from
a feature vector:

```
[data_loss_count, migration_error_count, destructive_ops,
 medium_ops, rows_at_risk, static_risk]
```

Features are z-normalized across the candidate list, then combined with a
fixed, published weight vector and passed through a softmax. The response
includes every candidate score and the full ranking, so a reviewer can audit
why a decision was recommended. This is a deterministic surrogate, not a
trained model; `score_kind: "deterministic_listwise_surrogate"` is always
present.

### 3.4 Gate rule

`forge_analyze` runs the shadow gate after the binary analysis and before
issuing an approval nonce. The gate may only upgrade:

```
decision_required = static_decision_required || shadow.decision_required
```

It never downgrades a static `CRITICAL` result. If shadow parsing fails, the
response includes `shadow.error_code` and the static decision is unchanged.

## 4. New MCP tool

`forge_shadow_analyze` accepts `from_schema`, `to_schema`, and optional
`sample_rows` (1..5). It returns the static report plus shadow operations,
list-wise scores, and an explicit engine identifier. Rate limit: 100/hour per
session.

## 5. Adversarial suite

The corpus is data-driven and organized by OWASP Agentic Security Initiative
vectors (ASI01–ASI10). Each case declares an expected fail-closed outcome
(error code, rejection, or bounded success). The suite asserts at least 250
cases and zero uncaught exceptions.

## 6. Receipt Inspector

Static, dependency-free HTML at `packages/mcp/ui/receipt-inspector.html`.
It recomputes SHA-256 leaves and Merkle roots in the browser with Web Crypto,
renders inclusion proofs, and never sends data to a server. Source-level
baseline checks run in Node; Playwright smoke runs when a browser is present.
