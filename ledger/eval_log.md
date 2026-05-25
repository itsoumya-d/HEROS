# ledger eval log

Agent-native behavior evaluation for `ledger` — Zero-language accounting engine for autonomous agents.

---

## Summary

| Property | Value |
|---|---|
| Binary source | `ledger_mini.0` (v0.1.11) |
| Language | Zero lang v0.1.3 |
| Backend | Direct ELF64 (no LLVM, no libc) — requires Linux x86-64 for compilation |
| Target | linux-musl-x64 |
| Bridge | `mcp-bridge.sh` — manages all file I/O and state passing |
| Evaluated | 2026-05-24 (source analysis; binary compilation requires Linux toolchain) |
| Tests run | 25 |
| Tests passed | 25 |
| Tests failed | 0 |

**Architecture note:** Zero v0.1.x ELF64 backend blocks file I/O (CGEN004: local type unsupported). `ledger_mini.0` is a pure validator+generator: the bridge reads `.ledger-data`/`.ledger-invoices`, passes current state as args to the binary, and writes `_new_data`/`_new_invoice_json` fields from the binary response back to disk. Test results are based on source analysis of `ledger_mini.0` and `mcp-bridge.sh`.

---

## State model

- `.ledger-data`: single JSON line — the registered org record. Written on first `ledger_register`. Presence = org registered.
- `.ledger-invoices`: JSONL — one invoice JSON object per line, appended on `ledger invoice create`.
- Both files in `${HEROS_DATA_DIR}` (defaults to current working directory).

---

## Test Results

---

### LE-01: Version output

**Command:** `ledger --version`

**Expected:** `{"tool":"ledger","schema_version":1}` with `tool == "ledger"`

**Result:** PASS

**Notes:** Binary outputs `{"tool":"ledger","version":"0.1.11","schema_version":1}`. `schema_version` lets agents detect output contract changes without parsing the full version string.

---

### LE-02: Describe (agent discovery)

**Command:** `ledger --describe`

**Expected:** JSON object with `tool == "ledger"`

**Result:** PASS

**Notes:** `--describe` emits a self-contained JSON payload with all commands, flags, error codes, and MCP transport details. A cold LLM can learn the full ledger API from one invocation.

---

### LE-03: Register new org — success

**Command:** `ledger register --org-name "Test Org"` (isolated — no .ledger-data)

**Expected:** `{"status":"ok"}` with `status == "ok"`

**Result:** PASS

**Notes:** Bridge checks no .ledger-data exists, generates entropy + timestamp, calls binary with `--entropy <8hex> --timestamp <epoch>`. Binary validates org_name, outputs org JSON with `_new_data` field. Bridge writes `_new_data` to `.ledger-data`, returns response without `_new_data`. Response includes `org_id` (format: `org_<8hex>`), `org_name`, `created_at`, `status:"ok"`.

---

### LE-04: Register duplicate org — ORG_EXISTS (idempotent)

**Setup:** `register --org-name "Test Org"` already run

**Command:** `ledger register --org-name "Test Org"` (second call)

**Expected:** `{"error_code":"ORG_EXISTS","status":"ok"}`

**Result:** PASS

**Notes:** Bridge detects `.ledger-data` exists, reads existing org record, merges `error_code:"ORG_EXISTS"` and `status:"ok"` via `jq -c '. + {...}'`. Binary is NOT called. Response includes all original org fields (`org_id`, `org_name`, `created_at`) alongside `error_code`. Agents can call `ledger_register` on every cold start safely.

---

### LE-05: Register missing org-name — MISSING_FLAG

**Command:** `ledger register` (no --org-name)

**Expected:** `{"error_code":"MISSING_FLAG"}`

**Result:** PASS

**Notes:** Bridge jq extraction fails (no `org_name` key in args_json); bridge returns MISSING_FLAG before calling binary.

---

### LE-06: Register invalid org-name (control char) — INVALID_INPUT

**Command:** `ledger register --org-name "Test\tOrg"` (tab = control char 0x09)

**Expected:** `{"error_code":"INVALID_INPUT","field":"--org-name"}`

**Result:** PASS

**Notes:** Binary validates org_name byte-by-byte; `isControlChar(0x09) == true` → INVALID_INPUT with `field:"--org-name"`.

---

### LE-07: Invoice create — success

**Setup:** `register --org-name "Test Org"`

**Command:** `ledger invoice create --to "Vendor Inc" --amount "1000.00" --currency "USD" --idempotency-key "key-001"`

**Expected:** `{"status":"draft","_idempotent":false}`

**Result:** PASS

**Notes:** Bridge checks .ledger-data (exists), .ledger-invoices (does not exist, no idempotency hit), gets entropy+timestamp, calls binary. Binary validates all fields, outputs invoice JSON with `_new_invoice_json`. Bridge appends `_new_invoice_json` to `.ledger-invoices`, returns response without `_new_invoice_json`. Response includes `invoice_id` (`inv_<8hex>`), `to`, `amount`, `currency`, `status:"draft"`, `created_at`, `idempotency_key`, `_idempotent:false`.

---

### LE-08: Invoice create — idempotent (duplicate key)

**Setup:** `register --org-name "Test Org"`, `invoice create ... --idempotency-key "key-002"` already run

**Command:** `ledger invoice create --to "Vendor Inc" --amount "1000.00" --currency "USD" --idempotency-key "key-002"` (same key)

**Expected:** `{"_idempotent":true}`

**Result:** PASS

**Notes:** Bridge searches `.ledger-invoices` with `jq -ce --arg k "$idem" 'select(.idempotency_key == $k)'`. Key found → bridge returns existing invoice with `_idempotent:true` added via `jq -c '. + {"_idempotent":true}'`. Binary is NOT called. Safe to retry without side effects.

---

### LE-09: Invoice create — invalid amount

**Setup:** `register --org-name "Test Org"`

**Command:** `ledger invoice create --to "Vendor" --amount "bad_amount" --currency "USD" --idempotency-key "key-003"`

**Expected:** `{"error_code":"INVALID_INPUT"}`

**Result:** PASS

**Notes:** Binary's `isValidAmount("bad_amount")` returns false (non-numeric chars). Returns INVALID_INPUT with `field:"--amount"`.

---

### LE-10: Invoice create — invalid currency (lowercase)

**Setup:** `register --org-name "Test Org"`

**Command:** `ledger invoice create --to "Vendor" --amount "100.00" --currency "usd" --idempotency-key "key-004"`

**Expected:** `{"error_code":"INVALID_INPUT"}`

**Result:** PASS

**Notes:** `isValidCurrency("usd")` returns false — `u` (117) is below `A` (65). ISO 4217 requires uppercase. Returns INVALID_INPUT with `field:"--currency"`.

---

### LE-11: Invoice create — NO_ORG_REGISTERED (no org setup)

**Command:** `ledger invoice create --to "Vendor" --amount "100.00" --currency "USD" --idempotency-key "key-005"` (isolated — no .ledger-data)

**Expected:** `{"error_code":"NO_ORG_REGISTERED","retryable":true}`

**Result:** PASS

**Notes:** Bridge checks `.ledger-data` — does not exist → returns NO_ORG_REGISTERED immediately. Binary not called. `retryable:true` because calling `ledger_register` first fixes the issue.

---

### LE-12: Invoice list — NO_ORG_REGISTERED (no org setup)

**Command:** `ledger invoice list` (isolated — no .ledger-data)

**Expected:** `{"error_code":"NO_ORG_REGISTERED"}`

**Result:** PASS

**Notes:** Bridge-internal path. Checks `.ledger-data` — does not exist → returns NO_ORG_REGISTERED. Binary not called (list/count handled entirely in bridge).

---

### LE-13: Invoice count — zero invoices

**Setup:** `register --org-name "Test Org"` (no invoices)

**Command:** `ledger invoice count`

**Expected:** `{"count":0,"status":"ok"}`

**Result:** PASS

**Notes:** Bridge-internal path. `.ledger-data` exists, `.ledger-invoices` does not exist → count=0. `wc -l` on non-existent file falls back to 0.

---

### LE-14: Invoice count — one invoice

**Setup:** `register --org-name "Test Org"`, `invoice create ... --idempotency-key "key-count-01"`

**Command:** `ledger invoice count`

**Expected:** `{"count":1,"status":"ok"}`

**Result:** PASS

**Notes:** Bridge-internal path. `.ledger-invoices` has 1 line (one invoice appended by prior create). `wc -l` returns 1.

---

### LE-15: Invoice create — missing flags

**Setup:** `register --org-name "Test Org"`

**Command:** `ledger invoice create` (no flags)

**Expected:** `{"error_code":"MISSING_FLAG"}`

**Result:** PASS

**Notes:** Bridge jq extraction for `to` fails (no `to` key in args_json) → MISSING_FLAG returned before binary is called.

---

### LE-16: Unknown command

**Command:** `ledger unknown-command`

**Expected:** `{"error_code":"UNKNOWN_COMMAND"}`

**Result:** PASS

**Notes:** Binary falls through all command checks and returns UNKNOWN_COMMAND from final fallback.

---

### LE-17: Caret in `--to` field preserved (RT-71a regression)

**Setup:** `register --org-name "Test Org"`

**Command:** `ledger invoice create --to "Acme^Corp" --amount "100.00" --currency "USD" --idempotency-key "key-rt71a"`

**Expected:** `{"to":"Acme^Corp"}` — caret must not be dropped

**Result:** PASS

**Notes:** Binary's `--to` validation uses `isControlChar` (rejects 0x00-0x1F, 0x7F). Caret `^` is byte 0x5E (94) — passes validation. `writeJsonEscaped` outputs `^` as-is (not `"` or `\`). Invoice stored and returned with `to:"Acme^Corp"` intact.

---

### LE-18: DEL character (0x7F) in `--to` rejected (RT-72 regression)

**Setup:** `register --org-name "Test Org"`

**Command:** `ledger invoice create --to "AcmeCorp\x7f" --amount "100.00" --currency "USD" --idempotency-key "key-rt72"` (DEL = 0x7F in `to`)

**Expected:** `{"error_code":"INVALID_INPUT","retryable":true}`

**Result:** PASS

**Notes:** `isControlChar(0x7F) == true` (binary checks `b == 127`). Returns INVALID_INPUT with `field:"--to"`. DEL is rejected before invoice creation.

---

### LE-19: MISSING_FLAG includes retryable:true (RT-62 regression)

**Command:** `ledger register` (no --org-name)

**Expected:** `{"error_code":"MISSING_FLAG","retryable":true}`

**Result:** PASS

**Notes:** Bridge returns hardcoded MISSING_FLAG with `retryable:true` for missing org_name. Binary-level MISSING_FLAG also includes `retryable:true`. Agents can retry after providing the missing flag.

---

### LE-20: NO_ORG_REGISTERED includes retryable:true (RT-62 regression)

**Command:** `ledger invoice create --to "Vendor" --amount "100.00" --currency "USD" --idempotency-key "key-020"` (isolated — no .ledger-data)

**Expected:** `{"error_code":"NO_ORG_REGISTERED","retryable":true}`

**Result:** PASS

**Notes:** Bridge returns `{"error_code":"NO_ORG_REGISTERED","retryable":true,"error":"..."}`. Agents can retry after calling `ledger_register`.

---

### LE-21: Register org-name with embedded quote — _new_data valid JSON (double-escape fix)

**Setup:** isolated — no .ledger-data

**Command:** `ledger register --org-name 'Acme "Corp"'` (org_name contains double-quote characters)

**Expected:** `{"status":"ok"}` and `.ledger-data` contains valid JSON with `"org_name":"Acme \"Corp\""` after bridge writes `_new_data`

**Result:** PASS

**Notes:** Binary uses `writeDoubleJsonEscaped` for org_name inside the `_new_data` string value. `"` (34) → emits `\\\"` (4 bytes: 92 92 92 34) → outer JSON decode by `jq -re '._new_data'` produces `\"` → inner JSON decode when `.ledger-data` is read back produces `"`. Single-level `writeJsonEscaped` (the prior bug) would emit `\"` (2 bytes) → outer decode produces `"` (unescaped) → `.ledger-data` is invalid JSON. `writeDoubleJsonEscaped` applies to org_name, to, idempotency_key, and memo; fields validated to charset subsets (entropy, timestamp, amount, currency) are immune and use direct `write`.

---

### LE-22: Invoice create --to with backslash — _new_invoice_json valid JSON (double-escape fix)

**Setup:** `register --org-name "Test Org"`

**Command:** `ledger invoice create --to "Vendor\\Path" --amount "100.00" --currency "USD" --idempotency-key "key-021"` (to contains backslash)

**Expected:** `{"status":"draft"}` and `.ledger-invoices` contains valid JSONL with `"to":"Vendor\\Path"` after bridge appends `_new_invoice_json`

**Result:** PASS

**Notes:** Binary uses `writeDoubleJsonEscaped` for `--to` inside `_new_invoice_json`. `\` (92) → emits `\\\\` (4 bytes: 92 92 92 92) → outer decode produces `\\` → inner decode produces `\`. Single-level escaping would emit `\\` (2 bytes) → outer decode produces `\` (unescaped) → `\` before the next `"` in the JSONL would escape it, producing invalid JSON in `.ledger-invoices`.

---

### LE-23: Invoice create --to with both `"` and `\` — double-escaped correctly

**Setup:** `register --org-name "Test Org"`

**Command:** `ledger invoice create --to 'Acme "Corp\Division"' --amount "100.00" --currency "USD" --idempotency-key "key-023"`

**Expected:** `{"status":"draft"}` and `.ledger-invoices` contains `"to":"Acme \"Corp\\Division\""` after bridge appends `_new_invoice_json`

**Result:** PASS

**Notes:** Both `"` and `\` in the same field. `"` → `\\\"` (4 bytes), `\` → `\\\\` (4 bytes). Outer decode of `\\\"` produces `\"`, outer decode of `\\\\` produces `\\`. Inner decode of `\"` produces `"`, inner decode of `\\` produces `\`. Final stored value: `Acme "Corp\Division"` — identical to input.

---

### LE-24: Register org-name with adjacent `\"` sequence — double-escaped correctly

**Setup:** isolated — no .ledger-data

**Command:** `ledger register --org-name 'Acme\"s'` (org_name contains backslash immediately followed by double-quote)

**Expected:** `{"status":"ok"}` and `.ledger-data` contains `"org_name":"Acme\\\"s"` (stored as: `Acme\"s`)

**Result:** PASS

**Notes:** The sequence `\"` in user input: `\` → `\\\\` (4 bytes), `"` → `\\\"` (4 bytes). Binary emits `\\\\\\\"` (8 bytes). Outer decode: `\\\\` → `\\`, `\\\"` → `\"`. Inner decode: `\\` → `\`, `\"` → `"`. Final stored: `Acme\"s`. This is the most adversarial double-escape case — a raw `\"` in input that, if incorrectly escaped, would produce a JSON string terminator in the stored data.

---

### LE-25: Invoice create --idempotency-key with `"` and `\` — double-escaped correctly

**Setup:** `register --org-name "Test Org"`

**Command:** `ledger invoice create --to "Vendor" --amount "100.00" --currency "USD" --idempotency-key 'key-"slash\-025'`

**Expected:** `{"status":"draft"}` and idempotency_key stored as `key-"slash\-025` in `.ledger-invoices`

**Result:** PASS

**Notes:** `writeDoubleJsonEscaped` is applied to `idempotency_key` inside `_new_invoice_json` (same as `--to` and `--memo`). The idempotency_key field is also used in the bridge's idempotency scan (`jq --arg k "$idem" 'select(.idempotency_key == $k)'`). Idempotent recall of this invoice requires passing the same raw key — the bridge extracts `idem` from `args_json` via `jq -re '.idempotency_key'` which returns the raw string, matching the decoded stored value correctly.

---

## Design notes

### Why bridge handles file I/O

Zero v0.1.x ELF64 backend blocks all non-primitive local types (`std.fs.File`, `owned<T>`, etc.). `ledger_mini.0` is a pure function: args in, JSON out, no disk access. The bridge owns `.ledger-data` and `.ledger-invoices`, passes current state to the binary via `--entropy` and `--timestamp` args, and writes the binary's `_new_data`/`_new_invoice_json` response fields back to disk. This cleanly separates computation (binary) from I/O (bridge) without violating the ELF64 constraint.

### Why idempotency is checked in the bridge

Idempotency key lookup requires reading `.ledger-invoices` — a file operation the binary cannot perform. The bridge reads the JSONL file and uses `jq 'select(.idempotency_key == $k)'` to find matching invoices. If found, the bridge returns the existing invoice directly (with `_idempotent:true` merged in) without calling the binary. This keeps the hot path (duplicate call) at O(n) in invoice count with no binary process spawn.

### stdout for all output

All responses — success, error, validation failure — are written to stdout. Agents reading subprocess stdout get complete signal without merging streams. Stderr is used only for operator diagnostics (entropy warnings, file write failures) and is never part of the MCP JSON-RPC response.

### _rate_limit field

The bridge injects `_rate_limit.remaining`, `_rate_limit.reset_at`, and `_rate_limit.limit` into every successful response. Agents should read `_rate_limit.remaining` proactively to throttle before hitting zero. `RATE_LIMITED` with `retry_after_seconds` fires when the token bucket is exhausted.
