# Changelog

## 0.3.0 — 2026-11-03

Release candidate; not yet published.

- **Signed receipts.** Ed25519 signatures over domain-separated Merkle roots,
  signed inclusion proofs, SPKI public-key export, and a browser verifier using
  WebCrypto. `createMerkleReceiptStore({ store, signer })` signs each append.
- **Cross-process idempotency.** File receipt and approval stores take
  host-local lock files around read-modify-write operations. A per-key lock
  serializes check-execute-record across processes. This is not a distributed
  lock; see `THREAT_MODEL.md`.
- **Incremental Merkle root.** The wrapper maintains a frontier, so root
  updates are O(log n). Measured p99 was 0.62 ms at 5200 signed receipts with an
  in-memory store.
- **Threat model.** Ten threat rows plus residual limits, including the
  host-local lock scope, the file store's whole-file rewrite, and O(n) `verify()`
  and proof generation.
- **No breaking API removals.** `AgenticApp.execute` keeps its response shape;
  the former body is now the internal `_execute` used under the idempotency
  lock.

## 0.2.0

Initial public package, published before the signing and locking work above.
