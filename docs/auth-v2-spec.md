# Auth v0.2 Spec — API Key Authentication for ledger + forge

**Status:** Spec — implementation target v0.2  
**Tracks:** V44 (Agent Identity Gap, P1)  
**Author:** Security cycle 56, 2026-05-23  

---

## Problem

The current ledger and forge model uses `org_id` as the sole identity credential. `org_id` is:
- Non-secret (it is returned in `ORG_EXISTS` responses)
- Non-rotating (no revocation mechanism)
- Org-scoped only (no per-agent differentiation within an org)
- Permanent until data deletion

A single leaked `org_id` gives unlimited access to all org data indefinitely. There is no way to:
- Distinguish a compromised agent from a legitimate one
- Revoke access for one agent without affecting all agents in the org
- Audit which agent made which call
- Apply different capability scopes to different agents

**V44 closes this gap with HMAC-SHA256 API keys.**

---

## Key format

```
heros_<scope>_<32-byte-hex-key-id>_<32-byte-hex-secret>
```

Example:
```
heros_rw_4a2f8c1e9b3d0a7f6e5d4c3b2a1f0e9d_8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e
```

Fields:
- `heros_` — product prefix; lets agents identify which tool family issued this key
- `<scope>` — `ro` (read-only) or `rw` (read+write); controls allowed operations
- `<key_id>` — 32 hex chars (128 bits); stable identifier for audit logs; NOT secret
- `<secret>` — 32 hex chars (128 bits); the secret material; never logged

The `org_id` is embedded in the key server-side and looked up from the key_id on each request. The caller never sends `org_id` separately.

---

## Wire protocol

### CLI flag

```bash
ledger register --org-name "Acme" --api-key heros_rw_<key_id>_<secret>
ledger invoice create --to "vendor" --amount 100 --currency USD --api-key heros_rw_<key_id>_<secret>
```

Alternatively, via environment variable:
```bash
export HEROS_API_KEY=heros_rw_<key_id>_<secret>
ledger register --org-name "Acme"
```

Flag takes precedence over env var.

### MCP bridge

The bridge passes `--api-key` as the final argument to every binary invocation. The key comes from the `HEROS_API_KEY` environment variable set in the bridge deployment environment. Agent callers never see or supply the raw key in MCP tool calls.

---

## Server-side validation (v0.2, Zero implementation)

### Key storage format (flat file)

`.heros-keys` file in the data directory, one key per line:
```
<key_id> <scope> <org_id> <hmac_sha256_of_secret> <created_epoch_s> <revoked:0|1>
```

Example:
```
4a2f8c1e9b3d0a7f6e5d4c3b2a1f0e9d rw org_1234 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 1716000000 0
```

The `hmac_sha256_of_secret` is `HMAC-SHA256(key=HEROS_HMAC_SEED, msg=key_id:secret)`. The operator-managed `HEROS_HMAC_SEED` is the HMAC key; `key_id:secret` (colon-joined) is the message. This means:
1. A stolen `.heros-keys` file is useless without also stealing `HEROS_HMAC_SEED`.
2. Both `key_id` and `secret` contribute to the hash — no substitution attacks.
3. `HEROS_HMAC_SEED` must be rotated independently when a server is compromised.

Note: original spec draft described `HMAC-SHA256(key_id, secret)` — bridge implementation uses HMAC_SEED as outer key. Spec corrected 2026-05-23 (RT-133).

### Validation algorithm

```
1. Parse --api-key: split on '_'; validate format: 5 parts, prefix=heros, scope in {ro,rw}
2. Extract key_id and secret from parts[3] and parts[4]
3. Scan .heros-keys for a line matching key_id
4. If not found: return INVALID_API_KEY (retryable:false)
5. If revoked == 1: return API_KEY_REVOKED (retryable:false, hint:"rotate key via `key rotate`")
6. Compute HMAC-SHA256(key_id, secret) using HEROS_HMAC_SEED env var as outer key
7. Compare computed hash to stored hash (constant-time comparison to prevent timing attacks)
8. If mismatch: return INVALID_API_KEY (retryable:false)
9. Check scope: if operation requires write and scope == ro: return INSUFFICIENT_SCOPE (retryable:false)
10. Extract org_id from key record; proceed as current org_id-based logic
```

### Zero v0.2 constraint

Zero v0.1.x has no crypto stdlib. HMAC-SHA256 requires:
- **Option A (v0.2 preferred):** Zero stdlib gains `std.crypto.hmac_sha256` — blocked on Zero v0.2 release
- **Option B (bridge-side, deployable now):** The bridge validates the API key before invoking the binary; binary receives `--org-id` after bridge validation. Bridge uses `openssl dgst -hmac` or similar.

**Bridge-side option (v0.1.x workaround — implemented in `ledger/mcp-bridge.sh`):**

HMAC algorithm: `HMAC-SHA256(key=HEROS_HMAC_SEED, msg=key_id:secret)`. Using `HEROS_HMAC_SEED` (not `key_id`) as the HMAC key prevents an attacker who observes `key_id` from being able to compute the hash — the seed is operator-controlled and never transmitted.

```bash
# In mcp-bridge.sh, before invoking binary:
_validate_api_key() {
    local key="$1" required_scope="${2:-ro}"
    local prefix scope key_id secret
    IFS='_' read -r prefix scope key_id secret <<< "$key"

    # Format: heros_<ro|rw>_<32-hex-key-id>_<32-hex-secret>
    if [[ "$prefix" != "heros" ]] || \
       [[ ! "$scope" =~ ^(ro|rw)$ ]] || \
       [[ ! "$key_id" =~ ^[0-9a-f]{32}$ ]] || \
       [[ ! "$secret" =~ ^[0-9a-f]{32}$ ]]; then
        return 1
    fi

    # key_id is ^[0-9a-f]{32}$ — safe as grep anchor (no regex special chars)
    local record
    record=$(grep "^${key_id} " "${HEROS_DATA_DIR}/.heros-keys" 2>/dev/null) || true
    [[ -z "$record" ]] && return 1

    # Record: key_id scope org_id hmac_hash created_epoch revoked
    local _kid stored_scope stored_org stored_hash _created stored_revoked
    read -r _kid stored_scope stored_org stored_hash _created stored_revoked <<< "$record"

    [[ "$stored_revoked" == "1" ]] && return 2

    # RT-132: empty HMAC seed degrades security — reject before computing
    [[ -z "${HEROS_HMAC_SEED:-}" ]] && return 1
    # HMAC-SHA256(key=HEROS_HMAC_SEED, msg=key_id:secret) — RT-133 corrected formula
    local computed_hash
    computed_hash=$(printf '%s' "${key_id}:${secret}" | \
        openssl dgst -sha256 -hmac "${HEROS_HMAC_SEED}" -binary | \
        xxd -p -c 32 2>/dev/null) || return 1

    # RT-128: constant-time comparison prevents timing oracle on HMAC bytes
    if ! python3 -c "import hmac,sys; sys.exit(0 if hmac.compare_digest(sys.argv[1],sys.argv[2]) else 1)" \
        "$computed_hash" "$stored_hash" 2>/dev/null; then
        return 1
    fi

    # Scope: stored scope must satisfy required scope for this operation
    if [[ "$required_scope" == "rw" && "$stored_scope" == "ro" ]]; then
        return 3
    fi

    echo "$stored_org"
    return 0
}
```

This allows deployment in v0.1.x without waiting for Zero v0.2 crypto stdlib.

---

## Key management commands

### `ledger key create`

```bash
ledger key create --scope rw
```

Response:
```json
{
  "status": "ok",
  "key": "heros_rw_4a2f8c1e9b3d0a7f6e5d4c3b2a1f0e9d_8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e",
  "key_id": "4a2f8c1e9b3d0a7f6e5d4c3b2a1f0e9d",
  "scope": "rw",
  "warning": "Store this key securely. The secret portion cannot be retrieved after creation."
}
```

The full key is returned **once only** at creation time. Subsequent calls return only `key_id`.

### `ledger key list`

```bash
ledger key list
```

Response:
```json
{
  "status": "ok",
  "keys": [
    {"key_id": "4a2f...", "scope": "rw", "created": "2026-05-23T00:00:00Z", "revoked": false},
    {"key_id": "9f3c...", "scope": "ro", "created": "2026-05-20T00:00:00Z", "revoked": false}
  ]
}
```

### `ledger key rotate`

```bash
ledger key rotate --key-id 4a2f8c1e9b3d0a7f6e5d4c3b2a1f0e9d --scope rw
```

Atomically: marks old key as revoked, creates new key, returns new key in response. Both old and new key are valid for a 60-second overlap window to allow in-flight requests to complete.

Response:
```json
{
  "status": "ok",
  "revoked_key_id": "4a2f8c1e9b3d0a7f6e5d4c3b2a1f0e9d",
  "new_key": "heros_rw_7e9d1a3f..._6c4b2a0f...",
  "new_key_id": "7e9d1a3f...",
  "overlap_window_seconds": 60
}
```

### `ledger key revoke`

```bash
ledger key revoke --key-id 4a2f8c1e9b3d0a7f6e5d4c3b2a1f0e9d
```

Immediate revocation (no overlap window). Use when key is believed compromised.

---

## Error codes (new in v0.2)

| Code | Meaning | retryable |
|------|---------|-----------|
| `INVALID_API_KEY` | Key not found, malformed, or HMAC mismatch | false |
| `API_KEY_REVOKED` | Key has been revoked | false |
| `INSUFFICIENT_SCOPE` | Operation requires `rw` but key has `ro` scope | false |
| `KEY_ALREADY_EXISTS` | `key create` called when max keys reached (limit: 10 per org) | false |

All errors include:
```json
{
  "error_code": "INVALID_API_KEY",
  "retryable": false,
  "hint": "Obtain a valid API key via `ledger key create --scope rw`."
}
```

---

## Audit log integration

Every authenticated call appends to `.heros-audit`:
```
<epoch_s> <key_id> <scope> <tool> <org_id> <request_id_or_->
```

Example:
```
1716000123 4a2f8c1e rw invoice_create org_1234 req_abc123
```

The `key_id` (not the full key) is recorded. This enables:
- Per-agent audit trail within an org
- Detection of compromised keys (key_id shows unexpected activity)
- Forensic reconstruction of which agent made which change

---

## Scope model

| Scope | Allowed operations |
|-------|-------------------|
| `ro` | `invoice list`, `invoice count`, `forge analyze` (read-only) |
| `rw` | All `ro` operations + `register`, `invoice create`, forge operations with `decision_required:false` |

Write operations with `decision_required:true` always require an additional explicit acknowledgment (V39 nonce), regardless of scope.

---

## Migration path from org_id model

v0.1.x tools accept `--org-id` directly (current behavior). v0.2 tools:
1. Accept `--api-key` (new, validated as above)
2. Accept `--org-id` with a deprecation warning in the response:
   ```json
   {"_deprecation_warning": "org_id auth deprecated; create an API key via `ledger key create`"}
   ```
3. v0.3: `--org-id` removed; only API key accepted

Agents reading `_deprecation_warning` fields can self-upgrade their auth method.

---

## Threat mitigations

| Threat | Mitigation |
|--------|-----------|
| Leaked org_id unlimited access | org_id no longer accepted as standalone auth in v0.2 |
| Compromised agent credential | Revoke that agent's key_id; other agents unaffected |
| Rainbow table on stored secrets | HMAC-SHA256(key_id, secret) — key_id required to verify |
| Timing attack on HMAC comparison | Constant-time comparison in bridge and binary |
| Key enumeration | key_id is 128-bit random; 2^128 search space |
| MITM interception | Key bound to HEROS_HMAC_SEED in environment; stolen network packet is useless without the seed |
| Scope escalation | Bridge and binary both validate scope independently |

---

## Open items for v0.3 (DPoP)

- Replace HMAC-SHA256 key with DPoP (RFC 9449): agent holds an asymmetric keypair
- `X-DPoP-Proof` header: JWT signed with agent's private key, bound to request method + URI + timestamp
- Server verifies: (1) DPoP JWT signature, (2) access token bound to DPoP public key, (3) timestamp freshness (±5 min)
- Prevents token replay: stolen access token is useless without the private key
- Per-agent keypair: zero-knowledge proof of possession, no shared secret

IETF reference: `draft-ietf-oauth-agentic`, `RFC 9449 (DPoP)`
