# ledger v0.2 Specification

**Status:** Design — required before networked deployment
**Date:** 2026-05-18
**Depends on:** `docs/storage-redesign-v2.md`, `docs/mcp-security-spec.md`

---

## 1. Scope

This spec defines the minimum feature set for `ledger` v0.2. The primary gate for v0.2 is:
1. Networked deployment safety (MCP stdio transport)
2. Unbounded storage (remove the 256-byte write-back limit)
3. Security compliance for V6, V10, V15, V29, V30

v0.2 does NOT require HTTP transport, multi-tenant billing, or full audit logging. Those are v0.3+.

---

## 2. Feature Delta from v0.1.x

### 2.1 Storage (RT-19 root fix)

Implement `docs/storage-redesign-v2.md` design:
- Temp-file + rename pattern for atomic writes to `.ledger-invoices` and `.ledger-data`
- No fixed 256-byte write buffer — invoices are appended one JSONL line at a time
- Remove `STORAGE_LIMIT_EXCEEDED` error code
- Add `STORE_WRITE_FAILED` `disk_full` field (when ENOSPC detected)
- Startup: detect and clean `.ledger-invoices-tmp` / `.ledger-data-tmp`
- Remove `invoice count` `storage_note` advisory (no longer needed)

**Zero v0.2 APIs required:**
- `std.fs.openForWrite(fs, path)` — creates or truncates, returns File
- `std.fs.rename(fs, from_path, to_path)` — atomic rename
- `std.fs.delete(fs, path)` — file deletion

### 2.2 MCP stdio transport

Implement MCP JSON-RPC stdio server. Exposes:
- `ledger_register` — maps to `register` command
- `ledger_invoice_create` — maps to `invoice create`
- `ledger_invoice_list` — maps to `invoice list`
- `ledger_invoice_count` — maps to `invoice count`

MCP server requirements (per `docs/mcp-security-spec.md`):
- §3: Tool names must use `ledger_` prefix
- §4: Sign manifest with cosign; return `manifest_sha256` in `tools/list`
- §5.1: 1 MiB message size limit
- §5.2: Reject `initialize` re-invocation with `-32002`
- §5.3: All parameters validated before processing (same validation as CLI)
- §5.5: Notification rate limit 100/sec, queue depth 1024
- §5.6: Errors must not include internal paths or stack traces
- §6.1: Present server identity in `initialize` response
- §7: Rate limiting (10/hour register, 1000/hour invoice_create, 3000/hour invoice_list)
- §8: Tool annotations (`readOnly`, `destructive`, `idempotent`, `cost_usd`, `decision_required`, `untrusted_fields`)

### 2.3 Binary signing (V6)

Per `.github/workflows/release.yml`:
- Reproducible build: two independent builds must produce SHA-identical binaries
- cosign keyless signing (Sigstore OIDC)
- syft SBOM (SPDX format)
- grype CVE gate (critical CVEs block release)
- Grype pinned by commit SHA (V33 full mitigation)

### 2.4 WriteError full fix (V20)

- Implement temp-file + rename (covered by 2.1 storage fix)
- After v0.2 storage fix, all writes are atomic: either the new file exists or the old one does — no partial-write corruption

---

## 3. API Changes

### 3.1 Error codes removed

- `STORAGE_LIMIT_EXCEEDED` — removed (unbounded storage)

### 3.2 Error codes added / modified

- `STORE_WRITE_FAILED`: add `disk_full: boolean` field
- New MCP-only errors (per MCP JSON-RPC spec):
  - `REQUEST_TOO_LARGE` (-32001)
  - `ALREADY_INITIALIZED` (-32002)
  - `UNKNOWN_TOOL` (-32003)
  - `RATE_LIMITED` — with `retry_after_seconds` field
  - `UNAUTHORIZED` — for auth-required operations (v0.3+)

### 3.3 New commands

- `ledger version` — same as `--version` but as a subcommand (MCP compatibility)
- `ledger describe` — same as `--describe` but as a subcommand

### 3.4 `invoice count` changes

Remove `storage_note` field from response (no longer meaningful with unbounded storage). Return only:
```json
{"count": N, "status": "ok"}
```

### 3.5 `--describe` additions

- Add `"min_version": "0.2.0"` to MCP manifest section
- Add V30 advisory: `"sdk_note": "Verify MCP SDK version >= May 2026 before integrating"`
- Remove `STORAGE_LIMIT_EXCEEDED` from error_codes

---

## 4. Non-Goals for v0.2

The following are explicitly deferred to v0.3+:

- HTTP transport (stdio only in v0.2)
- API key authentication (single-tenant in v0.2 — environment variable only)
- Per-org rate limits (flat rate limits in v0.2)
- Full audit log (structured JSONL to `.ledger-audit`)
- Multi-tenant isolation (single org per process in v0.2)
- `invoice delete` / `store reset` commands
- HMAC data integrity on store records

---

## 5. Security Compliance Gate

All of the following must be resolved before v0.2 ships:

| Item | Requirement | Source |
|------|------------|--------|
| V6 binary signing | Reproducible build + cosign + SBOM + grype gate | `release.yml` |
| V7a–f MCP JSON-RPC | §5.1–5.6 of mcp-security-spec.md implemented | mcp-security-spec.md |
| V10 manifest signing | cosign-signed manifest, hash in tools/list | mcp-security-spec.md §4 |
| V15 description lint | CI gate passes before publish | mcp-security-spec.md §4.3 |
| V17 error policy | No internal paths in MCP error responses | mcp-security-spec.md §5.6 |
| V20 WriteError | Atomic writes via temp-file+rename | storage-redesign-v2.md |
| V29 server identity | Ed25519 key in initialize response | mcp-security-spec.md §2.5 |
| V30 SDK audit | SDK version ≥ May 2026 verified | mcp-security-spec.md §2.6 |
| V33 grype SHA pin | SHA digest (not tag) in release.yml | release.yml |
| RT-19 storage | STORAGE_LIMIT_EXCEEDED removed, unbounded JSONL | storage-redesign-v2.md |

---

## 6. v0.2 Eval Tests (required before release)

- [ ] Create 100 invoices without hitting any storage limit
- [ ] Simulate disk full during invoice create → `STORE_WRITE_FAILED` with `disk_full:true`, original file intact
- [ ] MCP cold-agent test: fresh LLM given only `tools/list` response completes invoice creation in ≤ 3 round-trips
- [ ] MCP re-initialization attack (V7e): second `initialize` returns `-32002`
- [ ] MCP notification flood (V7f): 1000 notifications in 1 second → server survives, queue bounded
- [ ] Tool name shadowing: `register` (unprefixed) returns `UNKNOWN_TOOL`
- [ ] Rate limit: 1001st `invoice_create` in one hour returns `RATE_LIMITED` with `retry_after_seconds`
- [ ] Manifest hash drift detection: agent detects changed tool description hash
