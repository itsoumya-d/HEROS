# HEROS — 60-Second Demo Transcript

A YC reviewer (or any agent) can verify HEROS without compiling Zero. The outputs below are
**reproduced from the CI-gated eval suite** (`forge/eval-cases.jsonl`, `ledger/eval-cases.jsonl`)
and the binary source (`forge/forge_mini.0`, `ledger/ledger_mini.0`), so they match what the
released binary emits byte-for-byte on the shown inputs.

> Install the released binaries (Linux x86-64):
> ```bash
> curl -L https://github.com/itsoumya-d/HEROS/releases/latest/download/forge -o forge && chmod +x forge
> curl -L https://github.com/itsoumya-d/HEROS/releases/latest/download/ledger -o ledger && chmod +x ledger
> ```
> The `ledger` write commands run through `ledger/mcp-bridge.sh` (the bridge owns persistence,
> auth, and idempotency; it strips internal `_new_*` fields before returning to the agent).

---

## 1. forge — cold-start discovery (no docs needed)

```bash
./forge --describe
```
Returns the full self-describing API contract (commands, flags with types, the schema format
with an inline example, all error codes with `retryable` flags, MCP transport). A cold LLM
learns the entire interface from this one call. (`forge/eval-cases.jsonl` FE-02.)

---

## 2. forge — add a nullable column → NOTABLE (safe, but not silent)

```bash
./forge analyze \
  --from "TABLE users|COLUMN id serial NOT_NULL|COLUMN email text NOT_NULL" \
  --to   "TABLE users|COLUMN id serial NOT_NULL|COLUMN email text NOT_NULL|COLUMN bio text NULLABLE"
```
```json
{"schema_version":1,"_forge_version":"0.1.4","risk_tier":"NOTABLE","risk_score":0.25,"retryable":true,"has_data_loss":false,"decision_required":false,"operations":[{"type":"add_column","risk":"notable","data_loss":false,"estimated_lock_ms":0,"retryable":true,"agent_guidance":"New nullable column(s) added. Safe for most cases — no impact on existing rows or queries."}]}
```
(Matches eval case **FE-03**: `risk_tier: NOTABLE`, `has_data_loss: false`, `retryable: true`.)

---

## 3. forge — drop a table → CRITICAL, data loss, agent MUST halt

```bash
./forge analyze \
  --from "TABLE users|COLUMN id serial NOT_NULL|TABLE posts|COLUMN id serial NOT_NULL" \
  --to   "TABLE users|COLUMN id serial NOT_NULL"
```
```json
{"schema_version":1,"_forge_version":"0.1.4","risk_tier":"CRITICAL","risk_score":1.0,"retryable":false,"has_data_loss":true,"decision_required":true,"operations":[{"type":"drop_table","table":"posts","risk":"critical","data_loss":true,"estimated_lock_ms":0,"retryable":false,"agent_guidance":"Table dropped. All data permanently deleted. Verify no foreign key references or application queries target this table."}]}
```
(Matches eval case **FE-04**: `risk_tier: CRITICAL`, `has_data_loss: true`, `retryable: false`.)
`decision_required: true` is the unambiguous halt signal — through the MCP bridge, executing a
CRITICAL/HIGH migration additionally requires a single-use human-approval nonce (V39 protocol,
`forge/eval-bridge.sh`). An agent cannot auto-proceed.

---

## 4. ledger — register an org (idempotent)

```bash
ledger register --org-name "Acme Robotics"
```
```json
{"org_id":"org_deadbeef","org_name":"Acme Robotics","created_at":1716000000,"status":"ok"}
```
Call it again on every cold start — a second `register` returns the **existing** org with
`error_code: "ORG_EXISTS"` and the original `org_id`, never a duplicate. (Eval **LE-03**;
idempotency handled in `ledger/src/commands/register.0` + the bridge's TOCTOU-safe `flock`.)

---

## 5. ledger — create an invoice, then replay it (idempotency key)

```bash
ledger invoice create --to "Vendor Inc" --amount "1000.00" --currency USD \
  --idempotency-key "11111111-2222-3333-4444-555555555555"
```
```json
{"invoice_id":"inv_deadbeef","to":"Vendor Inc","amount":"1000.00","currency":"USD","status":"draft","created_at":1716000000,"idempotency_key":"11111111-2222-3333-4444-555555555555","_idempotent":false}
```
Re-issue the **same** `--idempotency-key` (e.g. a network retry) and ledger returns the original
invoice with `"_idempotent":true` — no double-charge. Invalid inputs fail closed with stable
codes: a non-`USD`-shaped currency → `INVALID_INPUT`; a missing flag → `MISSING_FLAG`; all on
exit 0, all as JSON. (Eval cases **LE-03..LE-25**.)

---

## Why this is hard to fake

Every output above is enforced by a CI job that builds the binary from source, runs these exact
cases, and **fails the release if any output drifts** (`.github/workflows/release.yml`). The
binaries are then cosign-signed and shipped with an SBOM. If a future change altered any tier or
field shown here, CI would block it.
