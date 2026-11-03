# HEROS agentic threat model

Status: living document, 2026-11-03.
Scope: `@soumyadebnath1619/agentic` and the HEROS MCP tool surface in this
repository. This document describes what the tests in `packages/agentic/test`
and `packages/mcp/test` actually exercise; it is not a claim of formal
verification.

## 1. Assets

| Asset | Why it matters |
|---|---|
| Action definitions and schemas | An injected or over-broad action can turn an agent into an arbitrary executor. |
| Receipts (action, input hash, result hash, principal, approval) | The audit trail is the evidence that an action happened and who approved it. |
| Idempotency records | A replay must not duplicate a side effect. |
| Approval tokens | A destructive action must not run on a stale or rebound approval. |
| Ed25519 signing key | Whoever holds it can attest to a Merkle root. |
| Merkle inclusion proofs | They let a third party verify one receipt without the whole log. |

## 2. Trust boundaries

```
untrusted caller / model output
        |
        v
  schema validation + auth + approval      <- in-process policy
        |
        v
  action handler (application code)        <- trusted only as far as the app
        |
        v
  receipt store + file locks + Merkle log  <- local filesystem
        |
        v
  browser verifier / third-party auditor   <- verifies proofs, trusts the key
```

The model output, tool arguments, and any text copied from a web page are
untrusted. The application handler, the signing key, and the local filesystem
are trusted for the purposes of this document. A compromised host is out of
scope.

## 3. Adversaries considered

1. A prompt-injected agent that supplies malformed, oversized, or hostile tool
   arguments.
2. A caller with a missing, revoked, or over-scoped API key.
3. A replaying client that reuses an idempotency key, approval token, or signed
   proof.
4. A concurrent client that races the same idempotency key from many processes.
5. A tamperer who edits a stored receipt or proof after the fact.
6. A malicious or buggy migration that would drop data without approval.

Not considered: a compromised operating system, a malicious Node.js runtime,
side-channel attacks on Ed25519, or a distributed attacker who can write to the
same files from another host.

## 4. Threats and controls

| # | Threat | Control | Evidence |
|---|---|---|---|
| T1 | Malformed JSON-RPC or MCP frames crash the server | Bounded parsing, error envelopes, no throw across the transport | 100 malformed JSON-RPC cases in `packages/mcp/test` |
| T2 | Agent input escapes the action schema | Strict object schemas, `additionalProperties: false`, length/charset limits, `safeText` | 108 agentic schema cases |
| T3 | Invalid, revoked, or under-scoped key executes a tool | HMAC-backed key file, scope check, revocation flag | 56 auth/scope cases |
| T4 | Hostile schema payload is interpreted as SQL | Forge/shadow parsers reject unknown grammar; SQLite shadow runs in a sandbox | 90 forge payload cases and 60 malformed shadow schemas |
| T5 | Destructive migration runs without a human decision | `decision_required` plus approval nonce bound to schema pair; `SHADOW_DENY` cannot be approved away | 26 destructive-gate cases plus the approval suite |
| T6 | Approval token is replayed or rebound to different input | One-use token bound to action and input hash, with expiry | 60 approval replay/rebind cases |
| T7 | Duplicate side effect from a retry | Idempotency record keyed by caller key and action hash; conflict on changed input | in-process replay and conflict tests |
| T8 | Duplicate side effect from concurrent callers in one process | In-flight promise map; followers replay the leader | 64-concurrent in-process test: 1 handler, 1 receipt |
| T9 | Duplicate side effect from concurrent OS processes | Host-local per-key lock file plus a global store lock; followers re-check the recorded response | 64-process test: 1 handler log line, 1 receipt, 63 `_idempotent: true` |
| T10 | Receipt is edited after it is written | SHA-256 leaf over the unsigned projection, `prev_hash` chain, Merkle root, optional Ed25519 root signature | Merkle and signature tests; `store.verify()` reports mismatches |
| T11 | Proof is tampered with in transit | Ed25519 signature over a domain-separated root; browser verifies the path and signature | browser PASS on a valid proof, FAIL on a tampered signature |
| T12 | Model output causes an unverified migration to be recorded as success | Score-triggered reflection and a target-schema requirement check (`REQUIREMENT_MISS`) | `rlvr` tests and the P01 held-out evaluation |

## 5. Residual risks and limits

These are known and must not be presented as solved.

1. **The lock is host-local, not distributed.** `withFileLock` uses exclusive
   file creation on one filesystem. It is not claimed to work on NFS, SMB, or
   two hosts writing the same file.
2. **Stale-lock recovery is time-based.** A lock older than 120 s may be
   removed. A handler that legitimately runs longer than that can lose
   exclusivity.
3. **Crash window between receipt and idempotency record.** The receipt append
   and the idempotency write are separate operations. A crash between them can
   leave a receipt without a replay record. The window is small but real.
4. **The file store rewrites the whole JSON file.** This is simple and
   dependency-free, but it is not a database: there is no `fsync`, no
   incremental write, and no compaction. Large logs will be slow and a full
   disk can corrupt the last write.
5. **Merkle root updates are incremental; the file store is still not.** The
   wrapper maintains a frontier and updates the root in **O(log n)**. Measured
   p99 was **0.62 ms at 5200 signed receipts** with an in-memory store, versus
   **33.8 ms** at 5000 receipts before the frontier. `createFileReceiptStore`
   still rewrites the whole JSON file on each append, and `verify()` recomputes
   every leaf, so end-to-end file-store logging remains O(n).
6. **Signing-key custody is out of scope.** The repository has no key rotation,
   revocation, or HSM integration. A leaked key can sign a different root.
7. **A valid proof is not a freshness proof.** It proves inclusion in the tree
   whose root was signed. A verifier must obtain the expected root from a
   trusted checkpoint; otherwise an old but valid proof can be replayed.
8. **The browser verifier trusts the page and `proof.json` it loads.** It
   detects a tampered proof or signature, not a compromised web server.
9. **The agentic app does not rate-limit by itself.** Rate limiting lives in the
   MCP layer. A direct `createAgenticApp()` integration must add its own.
10. **Schema validation is a strict subset of JSON Schema.** It covers the
    fields used by the tests; it is not a general JSON Schema implementation.

## 6. Verification commands

```bash
npm run test:agentic   # 38 pass
npm run test:mcp       # 53 pass
npm run bench:policy   # p99 < 4.5 ms
```

The 64-process test is part of `npm run test:agentic`; it spawns 64 Node
workers against one receipt file and asserts one handler execution, one
receipt, and 63 replayed responses.

## 7. Reporting

Open an issue in `itsoumya-d/HEROS` with the affected component, the exact
command, and the smallest reproducible input. Do not include live API keys,
signing keys, or private receipt contents.
