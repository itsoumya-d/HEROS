# Ledger v0.2 Auth Scope Audit

**Date:** 2026-05-23  
**Cycle:** 59  
**Tracks:** V44 (Agent Identity Gap, P1), `docs/auth-v2-spec.md`

---

## Objective

Map every ledger command to the required changes for v0.2 API key authentication. Identify which changes go in the binary (Zero source), which go in the MCP bridge, and what new eval cases are needed.

---

## Current state

All commands use implicit org context: the binary reads `.ledger-data` to get `org_id`. No API key is involved. The bridge passes calls straight through.

---

## Per-command change table

| Command | Scope | Binary change | Bridge change | New error codes | Audit log |
|---------|-------|--------------|---------------|-----------------|-----------|
| `register` | rw | None — bridge validates key before invoking; binary still writes `.ledger-data` as now | `_validate_api_key` before dispatch; scope must be `rw`; on success append `.heros-audit` | INVALID_API_KEY, API_KEY_REVOKED, INSUFFICIENT_SCOPE | `register` + `key_id` + `org_id` + timestamp |
| `invoice create` | rw | None — reads `.ledger-data` for org context as now | Validate key (`rw`); audit append | INVALID_API_KEY, API_KEY_REVOKED, INSUFFICIENT_SCOPE | `invoice_create` + `key_id` + `org_id` |
| `invoice list` | ro | None | Validate key (`ro` or `rw`); audit append | INVALID_API_KEY, API_KEY_REVOKED | `invoice_list` + `key_id` |
| `invoice count` | ro | None | Validate key (`ro` or `rw`); audit append | INVALID_API_KEY, API_KEY_REVOKED | `invoice_count` + `key_id` |
| `key create` | bootstrap | New command in `ledger/src/commands/key.0`: parse `--scope ro|rw`; write key record to `.heros-keys` with bridge-computed HMAC hash | Bridge computes `key_id` (16-byte urandom hex) + `secret` (32-byte urandom hex) + HMAC-SHA256(key_id, secret); invokes binary with computed fields; binary writes to `.heros-keys` | KEY_ALREADY_EXISTS (max 10 keys), INVALID_INPUT (bad scope) | `key_create` + `key_id` |
| `key list` | ro | New command: reads `.heros-keys`, outputs non-secret fields (key_id, scope, created, revoked) | Validate key (`ro` or `rw`); audit append | INVALID_API_KEY | `key_list` + `key_id` |
| `key rotate` | rw | New command: marks old key revoked, writes new key record (60-sec overlap); returns new full key once | Bridge computes new key material; validates old key first; invokes binary with both old and new key data | INVALID_API_KEY, API_KEY_REVOKED | `key_rotate` + `old_key_id` + `new_key_id` |
| `key revoke` | rw | New command: sets `revoked=1` for `--key-id`; immediate, no overlap | Validate caller key (`rw`); invoke binary; audit append | INVALID_API_KEY, API_KEY_REVOKED (already revoked) | `key_revoke` + `revoked_key_id` + `actor_key_id` |

---

## Binary changes summary (Zero v0.1.x)

### `ledger/src/main.0`

```
// Add key command dispatch (after invoice block):
if std.mem.eql(std.mem.span(cmd.value), std.mem.span("key")) {
    check key.run(world)
    return
}
```

### New `ledger/src/commands/key.0`

Subcommands: `create`, `list`, `rotate`, `revoke`.

**`.heros-keys` format (one key per line):**
```
<key_id> <scope> <org_id> <hmac_sha256_hex> <created_epoch_s> <revoked>
```

`key list` output: reads `.heros-keys`, emits JSON array of `{key_id, scope, created, revoked}` objects. The `hmac_sha256_hex` field is NEVER included in output.

`key revoke --key-id <id>`: rewrites `.heros-keys` with the matching line's revoked field set to `1`. Uses same flat-file rewrite pattern as existing invoice store. **RT-127:** binary rewrites the file atomically (or documents the non-atomic risk as P3 for v0.2, same as RT-19 for invoices).

### `ledger/src/schema.0`

Add to error codes list: `INVALID_API_KEY`, `API_KEY_REVOKED`, `INSUFFICIENT_SCOPE`, `KEY_ALREADY_EXISTS`.

Add `key` command group documentation.

### No changes to `register.0` or `invoice.0`

The binary commands themselves don't validate the key — that is fully bridge-side. The binary runs after the bridge has verified the caller is legitimate.

---

## Bridge changes summary (`ledger/mcp-bridge.sh`)

### 1. Key validation guard (all non-trivial calls)

```bash
# At top of invoke_ledger(), after arg extraction:
_HEROS_KEY="${HEROS_API_KEY:-}"
_ORG_ID=""
if [[ -n "$_HEROS_KEY" ]]; then
    _ORG_ID=$(_validate_api_key "$_HEROS_KEY") || {
        local _code=$?
        case $_code in
            2) echo '{"error_code":"API_KEY_REVOKED","retryable":false,"hint":"rotate key via ledger key rotate"}'; return ;;
            3) echo '{"error_code":"INSUFFICIENT_SCOPE","retryable":false}'; return ;;
            *) echo '{"error_code":"INVALID_API_KEY","retryable":false}'; return ;;
        esac
    }
fi
```

### 2. Scope check

```bash
_check_scope() {
    local required="$1" key_scope="$2"
    [[ "$required" == "ro" ]] && return 0
    [[ "$key_scope" == "rw" ]] && return 0
    return 1
}
```

Applied: `register` and `invoice_create` and `key_rotate` and `key_revoke` check `rw`. `invoice_list`, `invoice_count`, `key_list` accept `ro`.

### 3. Audit log append

```bash
_audit() {
    local key_id="$1" scope="$2" tool="$3" org_id="${4:-}"
    local epoch
    epoch=$(date +%s 2>/dev/null || echo "0")
    printf '%s %s %s %s %s\n' "$epoch" "$key_id" "$scope" "$tool" "$org_id" \
        >> "${HEROS_DATA_DIR:-.}/.heros-audit" 2>/dev/null || true
}
```

Called after every successful tool invocation.

### 4. Key management tool dispatch

New tools exposed in `tools/list`: `ledger_key_create`, `ledger_key_list`, `ledger_key_rotate`, `ledger_key_revoke`. These are bridge-side for key_create/rotate (HMAC computation); binary handles file I/O.

---

## Security analysis of the scheme

### RT-127: `.heros-keys` file injection via HMAC seed

The bridge computes `HMAC-SHA256(key_id, secret)` using `HEROS_HMAC_SEED` as the outer key. If an attacker can inject a crafted key_id or secret into the hash computation:

- `key_id` is generated by the bridge from `/dev/urandom` hex — not user-controlled
- `secret` is generated by the bridge from `/dev/urandom` hex — not user-controlled
- `HEROS_HMAC_SEED` is an env var set by operator — not user-controlled

**CONFIRMED SAFE**: all three inputs to the HMAC are operator/bridge-controlled. An attacker cannot forge a valid key hash.

### RT-128: Timing attack on HMAC comparison

The spec requires constant-time comparison. Bash `[[ "$computed_hash" != "$stored_hash" ]]` is NOT constant-time (short-circuit on first differing byte). 

**P2 finding:** HMAC comparison in bridge is timing-vulnerable. An attacker making many rapid requests can infer partial hash bytes via timing differences.

**Mitigation:** Use `openssl pkeyutl` or a constant-time comparison (Python `hmac.compare_digest`). For the bash bridge:

```bash
# Constant-time comparison: XOR all bytes, check if sum is 0
_ct_eq() {
    local a="$1" b="$2"
    [[ "${#a}" -ne "${#b}" ]] && return 1
    python3 -c "import hmac,sys; sys.exit(0 if hmac.compare_digest('$a','$b') else 1)" 2>/dev/null
}
```

**P2 RT-128: constant-time HMAC comparison** — add to auth-v2-spec.md and implement in bridge.

### RT-129: `.heros-audit` log injection via key_id

The audit log line is: `printf '%s %s %s %s %s\n' epoch key_id scope tool org_id`. If key_id contains whitespace or newlines, it could inject extra log lines.

**Analysis:** `key_id` is validated as `^[0-9a-f]{32}$` (32 hex chars) — no whitespace or newlines possible. **CONFIRMED SAFE.**

### RT-130: Scope escalation via HEROS_API_KEY spoofing

An agent providing `--api-key heros_rw_...` in the MCP tool arguments (not env var) could try to inject a key with higher scope. 

**Analysis:** The bridge reads `HEROS_API_KEY` from environment only — not from MCP tool arguments. Agent callers cannot supply a different key per-call. **CONFIRMED SAFE** as long as bridge doesn't expose key as a tool parameter.

---

## New eval cases (auth regression suite, `ledger/eval-bridge-auth.sh`)

| Case | Scenario | Expected |
|------|----------|----------|
| AE-01 | Valid rw key → invoice create | `valid:true`, audit entry |
| AE-02 | Missing HEROS_API_KEY | `INVALID_API_KEY` |
| AE-03 | Revoked key | `API_KEY_REVOKED` |
| AE-04 | ro key + invoice create (rw op) | `INSUFFICIENT_SCOPE` |
| AE-05 | ro key + invoice list (ro op) | success |
| AE-06 | Wrong HMAC (tampered key) | `INVALID_API_KEY` |
| AE-07 | key_id not in .heros-keys | `INVALID_API_KEY` |
| AE-08 | Key create → key list → key_id appears (non-secret) | success; no secret in output |

---

## Implementation order

1. **Bridge first (v0.2 bridge PR):** `_validate_api_key`, scope check, audit log — no binary changes needed
2. **Binary second (v0.2 binary PR):** `key.0` commands, schema.0 error codes, main.0 dispatch
3. **Eval:** `eval-bridge-auth.sh` (AE-01 through AE-08)
4. **Threat model update:** V44 status → PARTIALLY MITIGATED (bridge-side); DONE when both PRs merged and eval passes
