# HEROS — Y Combinator Application

**Category:** Software for Agents (YC Requests for Startups, Summer 2026)
**Stage:** Open-source release shipped; pre-revenue, pre-users
**Team:** 1 (solo founder)
**Repo:** https://github.com/itsoumya-d/HEROS
**Contact:** Soumya Debnath — soumyadebnath1619@gmail.com

> Every claim below is backed by a file in this repository.
> Paths are cited inline so a reviewer can verify, not just read.

---

## The problem, in two real incidents

*July 17–18, 2025 — Replit:* An autonomous agent deleted the production data of 1,206 enterprise
executives during a code freeze. The data was eventually recovered through emergency human
intervention, but the agent had been given production database credentials, ran a migration with
no pre-execution risk check, and reported success. Agents don't read confirmation prompts — they
parse exit codes and move on.

*January 31–February 1, 2026 — Moltbook:* 1.5 million API keys were exposed through a
client-side Supabase secret with no row-level security. The breach is cited in Y Combinator's
own Spring 2026 Requests for Startups as the specific incident motivating a request for
agent-native credential management tooling.

Both failures share the same root cause: agents driving tools designed for humans who click
"confirm." HEROS is the operations layer that assumes the caller is an agent: it returns a
machine-readable risk verdict *before* the destructive action runs, makes idempotency a
requirement not an option, and stores credentials in an agent-native vault with scoped access
keys — the three direct fixes for the two incidents above.

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
database credentials, cloud access, and API keys — tools designed for humans who click "confirm."
The founding production incidents are already on record (Replit July 2025, Moltbook Jan 2026).
OWASP published its Agentic Top 10 (ASI01–ASI10) on December 9, 2025. EU AI Act Articles 12,
14, and 26 — requiring audit trails and human oversight for high-risk AI systems — enter full
enforcement August 2, 2026. The window to define agent-native operations infrastructure is open
*now*, before major orchestrators build safety primitives natively and before the compliance
deadline closes the door on early movers.

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
writes, access audit log. Idempotent by name; delete requires a human-approval nonce. 25
CI-gated eval cases. (`vault/eval-cases.jsonl`, `vault/eval-bridge.sh`)

**audit v0.1.0:** Tamper-evident append-only log. Chain-hashed JSONL: each entry hashes the
previous. `audit_verify` detects any deletion or modification (fixes V3 in the threat model). 22
CI-gated eval cases. (`audit/eval-cases.jsonl`, `audit/eval-bridge.sh`)

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
prompt-injection risk to the orchestrator — mapped to OWASP Agentic Top 10 ASI06 (published
December 9, 2025) and MITRE ATLAS v5.1.0 AML.T0054 (November 2025).

---

## YC RFS "Software for Agents" Summer 2026 — direct mapping

> *"Rebuild every major software category for a world where the next trillion users are not
> people but AI agents … agents need machine-readable interfaces: APIs, MCPs, and CLIs …
> machine-readable docs."*
> — Y Combinator Summer 2026 Requests for Startups
> *(reconstructed from secondary sources; ycombinator.com/rfs requires authentication —
> see `docs/deep-research-report.md` §1 for sourcing details)*

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

- Core MCP tools: forge 33, ledger 25, guardian 35, vault 25, audit 22 — 140 JSONL eval cases,
  all CI-gated and passing.
- Ecosystem bridges: Squawk integration (27 cases), herd coordination (30 cases), Litestream
  replication (22 cases), OpenTelemetry tracing (7 cases), ledger auth suites (20 cases) —
  226 total eval cases across all tools and integrations.
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
| Aembit (GA ~Apr 2026) | — | — | — | Cloud-hosted non-human IAM; not MCP-native, no self-host |
| Claude Code sandbox (open-sourced) | — | — | Single-runtime only (Claude Code); no cross-orchestrator coverage | — |
| **HEROS** | JSON-only, MCP-native, pre-execution risk + approval gate | JSON-only, MCP-native, idempotency, no txn fee | Universal risk gate — all orchestrators; first of its kind | Lightweight, MCP-native, audit-logged, self-hostable |

**Absorption risk and moat:** Anthropic open-sourced Claude Code's sandbox runtime (wraps MCP
servers and arbitrary processes). That is the most direct threat to guardian. HEROS's defense
is identical to Datadog vs CloudWatch — multi-runtime breadth (works with Claude Code, Cursor,
LangGraph, any MCP orchestrator) and domain depth (schema risk corpus, approval-nonce protocol,
chain-hashed audit log). Single-runtime native tools get absorbed; multi-runtime standard
infrastructure gets integrated with.

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

**First hire (planned):** a developer-relations / design-partner engineer — not another backend
builder. The engineering is the part I can do alone; the gap is getting forge into ten real
agent pipelines and turning that feedback into v0.2. The first dollar of YC funding goes to the
person who closes the loop between the code and the users, while I keep shipping the binary.

## What do you need from YC?

1. **Users** — introductions to teams running autonomous agents against real databases, money
   movement, and production infrastructure, to validate demand and shape v0.2.
2. **Distribution** — the YC network is full of agent-first companies that all need a database
   safety layer, an audit trail, and agent credential management.
3. **Credibility** — YC backing turns "interesting open-source project" into "infrastructure
   I'll trust in my production agent loop."
