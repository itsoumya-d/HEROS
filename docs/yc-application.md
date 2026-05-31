# HEROS — Y Combinator Application

**Category:** Software for Agents (YC Requests for Startups, Summer 2026)
**Stage:** Open-source release shipped; pre-revenue, pre-users
**Team:** 1 (solo founder)
**Repo:** https://github.com/itsoumya-d/HEROS
**Contact:** Soumya Debnath — soumyadebnath1619@gmail.com

> Every claim below is backed by a file in this repository.
> Paths are cited inline so a reviewer can verify, not just read.

---

## What does HEROS do? (≤150 words)

HEROS is the agent operations stack — infrastructure rebuilt for autonomous agents as the
primary caller, starting with the primitives every agent-built system needs:

- **forge** — pre-execution database migration safety: classifies any schema change into
  SAFE/NOTABLE/MEDIUM/HIGH/CRITICAL before it runs, issues human-approval nonces for
  data-loss operations, gives agents a `decision_required` halt flag with zero false negatives.
- **ledger** — idempotent agent accounting: org registration, invoice create/list/count,
  HMAC-SHA256 auth, idempotency keys on every write.
- **guardian** — universal safety oracle: the same pre-execution risk gate as forge, but for
  *any* operation — file system, shell commands, network calls, infrastructure changes,
  code execution, data access.
- **vault** — agent-native credential storage: named secrets with scoped access, audit log,
  no human dashboard required.
- **audit** — tamper-evident compliance log: append-only, chain-hashed JSONL every agent
  action can write to; `audit_verify` detects any alteration.

All five ship as MCP servers (Claude Code, Cursor, any MCP orchestrator). All are self-describing
via `--describe`. All return JSON on every code path, exit 0 always.

---

## Why now? (≤100 words)

MCP standardized agent↔tool calling in 2024-2025. Now developers hand agents production
database credentials, cloud access, and API keys — tools designed for humans clicking "confirm."
The EU AI Act's agentic provisions require audit trails for autonomous systems acting on
regulated data; US financial regulators are signaling similar requirements. The window to
define agent-native operations infrastructure is open *now*, before Flyway adds a `--json` flag
and Stripe adds "agent mode." Every week of delay is a week competitors spend embedding into
the orchestrators (LangGraph, Claude Code, Cursor) that HEROS needs as distribution channels.

---

## What have you built?

Five working, security-hardened MCP servers with CI-gated evals and signed releases.

**forge v0.1.4:** PostgreSQL schema-migration risk engine. 15 operation types (drop_table,
drop_column, add_column NOT NULL, type change, FK add/drop, etc.) across 5 risk tiers.
CRITICAL/HIGH ops fire `decision_required: true` + single-use human-approval nonce (V39
protocol). 33 binary eval cases gate CI. (`forge/eval-cases.jsonl`, `forge/eval-bridge.sh`)

**ledger v0.1.11:** Idempotent invoice + org accounting. `register`, `invoice create/list/count`,
each write idempotency-keyed. HMAC-SHA256 API-key auth, token-bucket rate limiting, `flock`-
guarded atomic writes, ASCII-only field validation. 25 binary eval cases gate CI.

**guardian v0.1.0:** Universal operation safety oracle. Same approval-nonce protocol as forge
extended to 6 operation categories (file_system, shell_command, network_request, infrastructure,
code_execution, data_access). Pure bash bridge — no binary required. 35 CI-gated eval cases.
(`guardian/eval-cases.jsonl`, `guardian/eval-bridge.sh`)

**vault v0.1.0:** Agent-native secret storage. Named secrets, scoped access, flock-protected
writes, access audit log. Idempotent by name. (`vault/mcp-manifest.json`)

**audit v0.1.0:** Tamper-evident append-only log. Chain-hashed JSONL: each entry hashes the
previous. `audit_verify` detects any deletion or modification. (`audit/mcp-manifest.json`)

**Both forge + ledger:** JSON on every code path, exit 0 always, `--describe` self-discovery,
MCP 2025-11-25 compliant, reproducible builds, cosign-signed binaries + manifests, SBOM + vuln
scan in CI. (`docs/supply-chain-spec.md`, `.github/workflows/release.yml`)

---

## What do you understand that others don't?

**The MCP contract is the product.** Human dev tools ship three surfaces (SDK, CLI, web UI).
An agent-native tool ships one: a `--describe` payload + signed MCP manifest. A cold LLM
learns the entire interface from a single call — no docs site. Every HEROS tool is built
around this constraint from line one.

**Risk before execution, not after.** Flyway/Liquibase apply a migration and report success.
forge reports the danger *before* anything runs. The same pattern — guardian's universal
risk gate — extends to every irreversible agent action, not just database migrations.

**JSON on every code path, including errors.** `retryable: true/false` in every error response
means agents branch on a code, never on text. This is the reliability primitive every agent
needs but no existing tool provides.

**Idempotency is a first-class constraint.** An agent that retries without idempotency keys
double-charges or double-registers. Every write in HEROS is idempotency-keyed and returns the
original result on replay. This eliminates an entire class of "phantom duplicate" bugs.

**Untrusted-field annotations prevent prompt injection.** Fields like `memo` and `to` are
explicitly marked `UNTRUSTED` in output schemas and manifests. This surfaces the indirect
prompt-injection risk (OWASP Agentic ASI06, MITRE AML.T0054) to the orchestrator.

---

## YC RFS "Software for Agents" Summer 2026 — direct mapping

> *"Rebuild every major software category for a world where the next trillion users are not
> people but AI agents … agents need machine-readable interfaces: APIs, MCPs, and CLIs …
> per-agent tokens with scoped permissions, usage-based billing, audit trails."*
> — YC Summer 2026 RFS

| RFS requirement | What HEROS delivers | Evidence |
|---|---|---|
| Machine-readable interfaces (APIs, MCPs, CLIs) | All 5 tools are MCP stdio servers + CLIs; zero web UI | `*/mcp-manifest.json`, `*/mcp-bridge.sh` |
| Per-agent tokens with scoped permissions | `vault_secret_set/get`, HMAC-scoped API keys (ro/rw), per-org rate limits | `ledger/key-gen.sh`, `docs/auth-v2-spec.md` |
| Agents take real-world actions safely | forge pre-migration risk gate + guardian universal risk gate | `forge/eval-bridge.sh` (V39), `guardian/eval-bridge.sh` |
| Usage-based billing / audit trails | ledger idempotent invoice tracking + audit tamper-evident log | `ledger/mcp-manifest.json`, `audit/` |
| Programmatic discovery and onboarding | `--describe` self-describing API; manifest signed by CI | `forge/src/describe.0`, `ledger/src/schema.0` |
| No human in the loop for provisioning | `ledger_register` idempotent on cold start; `vault_secret_set` idempotent | `ledger/mcp-manifest.json` state_model |

**Where HEROS exceeds the ask:** most agent tools treat security as a post-launch concern.
HEROS ships keyless signing, reproducible builds, SBOM, vuln-scan gate, OWASP Agentic Top-10
audit, and a documented red-team log in v0.1. It also ships the *first* pre-execution risk gate
that covers non-database operations — a gap no funded competitor addresses.

---

## Architecture

Two layers per tool. The **bridge** (`*/mcp-bridge.sh`) owns the JSON-RPC 2.0 session, file
I/O, auth, rate limiting, and idempotency state. The **binary** (`forge_mini.0`,
`ledger_mini.0`) is a pure function: args in → JSON out → exit, no network, no files.

User input never reaches the shell as text — it is extracted with `jq --arg` and passed as
separate `execve` array elements. There is **zero `eval`** in any script. The security surface
is fully auditable. (`docs/threat-model.md`, `docs/mcp-security-spec.md`)

guardian, vault, and audit are pure bash bridges — no Zero binary — because their logic is
inherently I/O-bound (risk rule matching, file storage, chain hashing). The same security
constraints apply.

---

## Traction (stated honestly)

**Pre-revenue, pre-users.** What exists is evidence of execution quality, not market demand:

- forge: 33 CI-gated binary evals; ledger: 25; guardian: 35; all passing.
- forge bridge V39 approval-nonce protocol + ledger HMAC auth covered by dedicated CI eval jobs.
- Documented adversarial security process: red-team report (`docs/redteam-cycle1.md`), threat
  model with OWASP Agentic Top-10 mapping (`docs/threat-model.md`), fix log of P0–P2 findings
  resolved (JSON-injection, TOCTOU race, non-atomic write, table-name injection, non-ASCII bypass).
- Reproducible, cosign-signed releases with SBOM + critical-vuln gate in CI.

The next milestone is users to validate demand, not bigger numbers.

---

## Business model

All tools are open-source (MIT) and self-hostable for free, forever. The commercial layer is a
**hosted MCP endpoint** (not yet deployed) priced on usage — because agents don't have expense
accounts and humans deploying them need predictable cost. Indicative tiers (`docs/pricing.md`):
free developer tier, **Pro $49/mo flat**, **Team $149/mo flat**, Enterprise custom. No
per-transaction fee, unlike Stripe's 2.9%+30¢. These are planning assumptions, not revenue.

---

## Competition

| | forge | ledger | guardian | vault |
|---|---|---|---|---|
| Flyway / Liquibase | JVM, human-readable output, no pre-execution risk gate | — | — | — |
| Stripe | — | 2.9%+30¢/txn; human dashboard | — | — |
| HashiCorp Vault | — | — | — | Large daemon, not MCP-native |
| **HEROS** | JSON-only, MCP-native, pre-execution risk + approval gate | JSON-only, MCP-native, idempotency, no txn fee | Universal risk gate — first of its kind | Lightweight, MCP-native, audit-logged |

---

## Roadmap (the v0.2 wedge)

1. **Native Zero MCP server** once Zero ships stdin/file I/O — retire bash bridges, go fully
   static-binary.
2. **forge: emit the fix** — generate zero-downtime migration DDL, not just the risk score.
   Turns forge from an advisor into a planner.
3. **ledger: double-entry** — balanced debit/credit journal entries and account balances.
4. **guardian: integration with Squawk** — add Squawk (Rust binary, Postgres-specific lock
   hazard detection) as a second-pass validator inside forge for dialect-specific risks.
5. **Hosted endpoint** — one config block away from all five tools with no self-host step.
6. **OpenTelemetry tracing** — wrap each bridge invocation with `otel-cli exec` for spans
   compatible with Datadog, Honeycomb, Grafana Tempo, using MCP semantic conventions.

---

## Founder

**Soumya Debnath** — soumyadebnath1619@gmail.com. Built the full HEROS platform solo: five
MCP tools in Zero lang + bash, the eval harness, a documented red-team/threat-model process,
signed reproducible CI, and the launch material. The application demonstrates the ability to
ship security-hardened agent infrastructure end-to-end, alone, at speed.

## What do you need from YC?

1. **Users** — introductions to teams running autonomous agents against real databases, money
   movement, and production infrastructure, to validate demand and shape v0.2.
2. **Distribution** — the YC network is full of agent-first companies that all need a database
   safety layer, an audit trail, and agent credential management.
3. **Credibility** — YC backing turns "interesting open-source project" into "infrastructure
   I'll trust in my production agent loop."
