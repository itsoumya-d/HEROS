# Rate Limiting Specification — ledger + forge v0.2

**Version:** 0.1  
**Status:** Design spec — implementation target v0.2  
**Threat coverage:** ASI02 (Agent Signup Flooding), V8 (Rate Limit Bypass / DoS), §7 of mcp-security-spec.md

---

## 1. Threat Model

### ASI02 — Agent Signup Flooding

OWASP Agentic Top 10 (December 2025) ASI02: "Uncontrolled Resource Consumption."

An autonomous agent (or fleet of agents) calls `ledger_register` in a tight loop. Since `ledger_register` is idempotent *per org name*, an agent using a generated or random org name on each call produces a new `.ledger-data` write on every invocation. Impact:

- Disk filled with org records (denial of service for legitimate operations)
- Idempotency cache invalidated by volume (idempotency key space exhausted)
- Agent-controlled org names stored on disk — potential for later social engineering or log poisoning
- In networked/multi-tenant v0.2: cross-org resource exhaustion

**Attack surface:**
- `ledger_register` — most dangerous; creates persistent on-disk state
- `ledger_invoice_create` — secondary; fills `.ledger-invoices` (already limited by 255-byte buffer in v0.1; unbounded in v0.2)
- `forge_analyze` — stateless but CPU-bound; parallel flood is a DoS vector
- `tools/list` — can be used to fingerprint the server in bulk scanning attacks

### V8 — Rate Limit Bypass

Agents discovering rate limit error codes may attempt bypass strategies:
- Distributing calls across multiple connections (IP rotation)
- Spoofing or omitting agent identity headers
- Using burst traffic to exhaust server capacity before limits kick in
- Re-initializing the MCP session to reset counters (mitigated by V7e — bridge rejects re-init)

---

## 2. Rate Limit Dimensions

Rate limits are applied in three independent dimensions, all of which must pass:

### 2.1 Per-IP Limits

Applies to the network address of the MCP client connecting to the server. In v0.2 (networked deployment), this is the TCP remote address. For stdio transport (v0.1), IP limits are not applicable (single-process).

Protects against: distributed signup flooding, scanner bots, credential stuffing.

### 2.2 Per-Org Limits

Applies to the registered org identity established via `ledger_register`. The org is identified by its `org_id` (stable UUID stored in `.ledger-data`). Tools that require a registered org (invoice create, invoice list, invoice count) use the on-disk org identity; no caller-supplied org ID is trusted.

Protects against: an agent that has registered once then calls invoice operations in a tight loop.

### 2.3 Per-Agent-Identity (v0.2 roadmap)

In v0.2, agents MAY present an optional `X-Agent-ID` header (or `agent_id` in MCP params). If present, it is used as a distinct rate-limit bucket alongside IP. This allows legitimate high-volume agents to be granted higher limits without opening the IP tier to all callers.

**Security note:** Agent IDs are untrusted self-declarations. They cannot be used to *relax* security checks — only to *narrow* rate-limit buckets. An agent claiming a premium tier without a verified API key still receives the default tier.

---

## 3. Token Bucket Algorithm

Each rate-limit bucket uses a token bucket (also called a "leaky bucket with burst"):

```
bucket:
  capacity:    N              (max burst)
  tokens:      N              (starts full)
  refill_rate: N / window_s   (tokens per second)
  last_refill: unix_timestamp
```

On each request:
1. Compute tokens to add: `min(capacity, tokens + refill_rate × (now - last_refill))`
2. If `tokens >= 1`: decrement tokens by 1, allow request
3. If `tokens < 1`: reject with `RATE_LIMITED`

**Why token bucket over fixed window:** Fixed window resets create burst vulnerability — an agent can make N calls at 23:59:59 and N more at 00:00:01 without triggering limits. Token bucket drains continuously; bursts are permitted up to `capacity` then throttled smoothly.

### Storage

Rate-limit state is stored in memory (not on disk). State is lost on process restart. This is acceptable for v0.2 bridge model (each bridge instance is independent). Future networked v0.3 would use Redis or equivalent for cross-instance state.

---

## 4. Limit Table

All limits are defaults. Operators may override per-tool limits via an environment variable config (see §6).

| Tool | Per-IP | Per-Org | Burst (per-org) | Notes |
|------|--------|---------|-----------------|-------|
| `ledger_register` | 10/hour | 5/hour | 2 | Creates on-disk state; lowest limit |
| `ledger_invoice_create` | — | 1000/hour | 20 | Per-org; IP not tracked for authenticated calls |
| `ledger_invoice_list` | — | 3000/hour | 60 | Read-only; higher limit |
| `ledger_invoice_count` | — | 6000/hour | 120 | Lightweight read; 2× list limit |
| `forge_analyze` | 200/hour | 500/hour | 10 | CPU-bound; IP limit applies (stateless) |
| `tools/list` | 60/hour | — | 5 | Server fingerprinting vector |
| `initialize` | 30/hour | — | 3 | Session establishment |

**Rationale for `ledger_register` being lowest:**
- Creates permanent on-disk state (disk exhaustion risk)
- Legitimate use: 1 call at startup (idempotent); rarely needs more than 1-2/hour
- 10/IP/hour allows legitimate retry-on-failure without enabling flooding

**Rationale for `forge_analyze` having an IP limit:**
- `forge_analyze` is stateless — no registered org required
- Without an IP limit, any caller (unauthenticated) could flood the CPU
- Per-IP limit provides the only defense for the stateless tool path

---

## 5. Rate Limit Error Response

When a limit is exceeded, the tool returns:

```json
{
  "error_code": "RATE_LIMITED",
  "error": "Too many requests. Retry after the specified delay.",
  "retry_after_seconds": 47,
  "limit_type": "per_org",
  "limit_tool": "ledger_invoice_create",
  "retryable": true
}
```

Fields:
- `error_code`: always `"RATE_LIMITED"` (stable, machine-readable)
- `error`: human-readable explanation
- `retry_after_seconds`: integer — the minimum wait before retry. Calculated as time until the bucket refills by 1 token. Agents MUST NOT retry before this expires.
- `limit_type`: `"per_ip"` | `"per_org"` | `"per_agent_id"` — identifies which bucket was exhausted
- `limit_tool`: the tool name that triggered the limit
- `retryable`: always `true` for `RATE_LIMITED` — the error is transient

The MCP `isError` flag in the tool response wrapper is set to `true`:
```json
{"content":[{"type":"text","text":"{\"error_code\":\"RATE_LIMITED\",...}"}],"isError":true}
```

### `_rate_limit` in Success Responses

Every successful tool response includes a `_rate_limit` field to enable proactive throttling by agents:

```json
{
  "status": "ok",
  "org_id": "...",
  "_rate_limit": {
    "remaining": 847,
    "reset_at": 1747526400,
    "limit": 1000,
    "window": "per_hour"
  }
}
```

Agents reading `_rate_limit.remaining` can pause before exhaustion rather than discovering the limit at call time. This eliminates unnecessary `RATE_LIMITED` errors for well-behaved agents.

---

## 6. Operator Configuration

Rate limits can be adjusted per deployment via environment variables. The bridge reads these at startup; they are not changeable at runtime.

```bash
LEDGER_RATE_REGISTER_IP=10          # per-IP/hour for ledger_register (default: 10)
LEDGER_RATE_INVOICE_CREATE_ORG=1000 # per-org/hour for invoice_create (default: 1000)
LEDGER_RATE_INVOICE_LIST_ORG=3000   # per-org/hour for invoice_list (default: 3000)
LEDGER_RATE_INVOICE_COUNT_ORG=6000  # per-org/hour for invoice_count (default: 6000)
LEDGER_RATE_TOOLS_LIST_IP=60        # per-IP/hour for tools/list (default: 60)
LEDGER_RATE_INITIALIZE_IP=30        # per-IP/hour for MCP initialize (default: 30)
FORGE_RATE_ANALYZE_IP=200           # per-IP/hour for forge_analyze (default: 200)
FORGE_RATE_ANALYZE_ORG=500          # per-org/hour for forge_analyze (default: 500)
```

**Security constraint:** Operator-set values MUST NOT exceed 10× the default. Values above the ceiling are silently clamped to the ceiling. This prevents accidental or malicious "effectively unlimited" configurations.

---

## 7. Agent-Facing Documentation Requirements

The `--describe` output for each tool MUST include:

```json
{
  "rate_limits": {
    "per_org": "1000/hour",
    "burst": 20,
    "on_rate_limited": "wait retry_after_seconds before retrying; _rate_limit.remaining in responses for proactive throttling"
  }
}
```

The MCP manifest `input_schema` for each tool MUST note in the description field that `_rate_limit` is present in all successful responses and that `RATE_LIMITED` is a retryable error.

---

## 8. Implementation Notes for v0.2

### Where rate limiting runs

Rate limiting runs in the bridge script (`mcp-bridge.sh`), not in the Zero binary. This is because:
- The Zero binary is stateless and spawned per-call (ELF64 constraint)
- The bridge is the long-running process that owns session and state
- Token buckets are stored as bash associative arrays in bridge memory

### Bridge associative array design

```bash
declare -A BUCKETS  # key: "tool:dimension:value" → "tokens:last_refill_epoch"

# Example:
# BUCKETS["ledger_register:ip:10.0.0.1"]="10:1747526000"
# BUCKETS["ledger_invoice_create:org:org_abc"]="998:1747526010"
```

`SECONDS` builtin provides epoch in bash. Token arithmetic is integer-only (use fixed-point: store tokens×100 for one decimal of precision). On each call, recompute with `$(( ... ))`.

### Memory bounds

The `BUCKETS` associative array is unbounded in the base design. A DoS attacker could create many distinct IPs or org IDs to inflate the array. Mitigation: evict entries not accessed in the last `window` seconds before each insert. The eviction scan is O(N) but `N` is bounded in practice by the IP/org space of legitimate callers.

For high-scale v0.2 deployments (networked), replace the bash associative array with a Redis `ZSET` TTL pattern or an in-process Zero rate limiter when Zero v0.2 supports persistent in-process state.

### Failure mode

If the rate limit check itself fails (e.g., corrupted `BUCKETS` entry), fail open — allow the request. Rate limiting is a defense-in-depth control; the Zero binary's own input validation remains the primary security layer.

---

## 9. Eval Tests

| Test | Setup | Expected Result |
|------|-------|-----------------|
| RL-01: Normal below limit | Send 5 `ledger_register` calls from same IP | All succeed; `_rate_limit.remaining` decrements |
| RL-02: Burst allowed | Send 2 `ledger_register` calls back-to-back | Both succeed (burst=2) |
| RL-03: Hard limit hit | Send 11 `ledger_register` calls in rapid succession | 11th returns `RATE_LIMITED`; `retry_after_seconds` > 0 |
| RL-04: Agent respects retry_after | Agent waits `retry_after_seconds` then retries | Next call succeeds |
| RL-05: Per-org limit independent of per-IP | Two distinct IPs, same org, hit org limit | Both IPs blocked; `limit_type: "per_org"` |
| RL-06: `_rate_limit` in response | One successful `ledger_invoice_create` | Response contains `_rate_limit.remaining`, `_rate_limit.reset_at` |
| RL-07: forge_analyze IP limit | 201 `forge_analyze` calls from same IP | 201st returns `RATE_LIMITED`; `limit_type: "per_ip"` |
| RL-08: Operator config respected | Set `LEDGER_RATE_REGISTER_IP=5`; send 6 calls | 6th returns `RATE_LIMITED` at the lower limit |
| RL-09: Ceiling enforcement | Set `LEDGER_RATE_REGISTER_IP=999999` (above 10×) | Bridge clamps to 100; 101st call returns `RATE_LIMITED` |
| RL-10: RATE_LIMITED error code in --describe | Cold agent reads `ledger --describe` | `RATE_LIMITED` present in `error_codes` with `retryable:true` |

---

## 10. Cross-references

- ASI02 attack surface: `docs/threat-model.md` V37
- MCP rate limiting stub: `docs/mcp-security-spec.md` §7
- V8 (Rate Limit Bypass): `docs/threat-model.md` V8
- Storage redesign (affects invoice flooding surface): `docs/storage-redesign-v2.md`
- Notification flood limit (100/sec, queue depth 1024): `docs/mcp-security-spec.md` §5.5 (V7f)
