# HEROS — Y Combinator Application

**Category:** Software for Agents (YC Requests for Startups)
**Stage:** Open-source release shipped; pre-revenue, pre-users
**Team:** 1 (solo founder)
**Repo:** https://github.com/itsoumya-d/HEROS
**Contact:** Soumya Debnath — soumyadebnath1619@gmail.com

> This is the canonical application document. `forge/yc_application_draft.md` and
> `forge/yc_scorecard.md` are forge-specific supporting material that feed into it.
> Every claim below is backed by a file in this repository — paths are cited inline so
> a reviewer can verify, not just read.

---

## What does HEROS do? (≤150 words)

HEROS is infrastructure rebuilt for autonomous agents as the primary caller — starting
with two backend primitives agent-built apps need on day one: **database migration safety
(`forge`)** and **agent accounting (`ledger`)**.

**forge** analyzes a database schema diff and returns a structured risk assessment *before*
any migration runs: `risk_tier` (SAFE→CRITICAL), `has_data_loss`, a `decision_required` halt
flag, and per-operation guidance — all JSON. An agent reads one object and decides whether to
proceed, gate for human sign-off, or alert.

**ledger** gives agents idempotent invoice and org accounting: register an org, create
invoices with idempotency keys, list and count them — a JSON API with stable error codes and
no human dashboard.

Both ship as MCP servers (Claude Code, Cursor, any MCP orchestrator), as static
sub-100 KiB binaries built in Zero lang. An agent discovers the full API from one
`--describe` call.

---

## Why now? (≤100 words)

MCP standardized agent↔tool calling in the last year, and developers are now handing agents
production database credentials and money movement. The tools they reach for — Flyway and
Liquibase (built for humans reading CI logs) and Stripe (a 2.9%+30¢ dashboard product) — were
never designed for a caller that can't read a stack trace, click "confirm," or recover from an
ambiguous exit code. The window to define the *agent-native* standard for ops infrastructure
is open now, before incumbents bolt an "agent mode" onto human tools. We are building for
agents from the first line of code, not retrofitting.

---

## What have you built? (≤150 words)

Two working, security-hardened tools with MCP transport, signed releases, and CI-gated evals.

**forge:** schema-migration risk engine. 15 operation types (drop_table, drop_column,
add_column, set_not_null, add/drop primary key, unique, foreign key, column type change,
default add/drop) across 5 risk tiers. CRITICAL/HIGH operations fire `decision_required: true`
and require a single-use human-approval nonce minted by the bridge (V39 protocol). 33
binary eval cases gate CI.

**ledger:** idempotent invoice + org accounting. `register`, `invoice create/list/count`,
each write idempotency-keyed. HMAC-SHA256 API-key auth, token-bucket rate limiting,
`flock`-guarded atomic writes, ASCII-only field validation. 25 binary eval cases gate CI.

**Both:** JSON on every code path, exit 0 always, `--describe` self-discovery, MCP 2025-11-25
compliant, reproducible builds, cosign-signed binaries + manifests, SBOM + vuln scan in CI.

---

## What's the most impressive thing you've built? / What do you understand that others don't?

**The MCP contract is the product, not a wrapper around one.** Human dev tools ship three
surfaces (SDK, CLI, web UI). An agent-native tool ships one: a `--describe` payload + a signed
MCP manifest. A cold LLM learns the entire interface from a single call — no docs site.
(`forge/mcp-manifest.json`, `ledger/mcp-manifest.json`; `--describe` in `forge/src/describe.0`,
`ledger/src/schema.0`.)

**JSON on every code path, including errors.** Flyway exits non-zero on failure, Liquibase
prints XML, Stripe returns HTTP-status + body. Every error in HEROS is a stable JSON
`error_code` with a `retryable` boolean — agents branch on a code, never on text.

**Risk before execution, not after.** Flyway/Liquibase apply a migration and report success.
forge reports the danger *before* anything runs. A dropped column caught pre-migration is a
non-event; caught post-migration it's a data-loss incident. forge has zero false negatives on
data-loss operations across its eval set.

**Idempotency is a requirement, not a feature.** An agent that retries without idempotency
keys double-charges or double-registers. Every write in HEROS is idempotency-keyed and returns
the original result on replay (`ledger/src/commands/invoice.0`, `register.0`).

---

## Why Zero lang?

1. **Structural security.** Zero's `World` capability parameter is the *only* I/O surface — the
   binary cannot open a socket or read a file it wasn't handed. The audit surface is the
   argument list. (This is why the bridge, not the binary, owns all I/O — see Architecture.)
2. **No runtime.** A musl-linked ELF64 binary under 100 KiB. No Python/Node/JVM. Drop it in a
   container; cold-start is sub-millisecond vs. 2–5 s of JVM startup per Flyway invocation.
3. **Determinism.** No GC, no stop-the-world pauses — consistent latency in a tight agent loop.

We are among the first non-trivial production Zero codebases. The honest tradeoff: Zero v0.1.x
has no stdin/file I/O, so today a hardened bash **bridge** owns the JSON-RPC session and
persistence and the binary stays a pure function. When Zero ships stdin support we replace the
bridge with a native Zero MCP server. We document this openly rather than hiding it.

---

## Architecture (one paragraph)

Two layers. The **bridge** (`*/mcp-bridge.sh`) owns the JSON-RPC 2.0 session, file I/O, auth,
rate limiting, and idempotency state. The **binary** (`forge_mini.0`, `ledger_mini.0`) is a
pure function: args in → JSON out → exit, no network, no files. User input never reaches the
shell as text — it is extracted with `jq --arg` and passed as separate `execve` array
elements; there is **zero `eval`** in any script. This split makes the security surface fully
auditable.

---

## YC RFS "Software for Agents" — how HEROS maps, and where it exceeds

The 2026 RFS calls for infrastructure that keeps autonomous agents reliable in production.
HEROS targets the failure modes directly:

| RFS theme | What a generic answer does | What HEROS does | Evidence |
|---|---|---|---|
| Agents acting on production systems safely | Logs after the fact | Pre-execution risk gate + mandatory human-approval nonce on destructive ops | `forge/forge_mini.0`, `forge/eval-bridge.sh` (V39) |
| Agent operations / reliability | Hope the agent parses output | JSON on every path; stable error codes; `retryable` flags | `*/mcp-manifest.json`, `eval_log.md` |
| Trustworthy agent tooling | Unsigned scripts off the internet | Reproducible build, cosign-signed binary + manifest, SBOM, grype scan, OWASP Agentic Top 10 audit | `.github/workflows/release.yml`, `docs/threat-model.md` |
| Composability | Bespoke shell glue | MCP stdio servers usable as named tools by any orchestrator | `docs/mcp-setup.md` |

**Where we exceed the bar:** most agent tools treat security and supply chain as
post-launch chores. HEROS ships keyless signing, reproducible builds, an SBOM, a vuln-scan
gate, an OWASP Agentic Top-10 audit, and a documented red-team log *in v0.1*, and gates the
release on behavioral evals so a broken binary can never be signed.

---

## Traction (stated honestly)

We are **pre-revenue and pre-users.** What exists today is evidence of execution quality, not
market demand — and we are explicit about that distinction:

- forge: 33 CI-gated binary eval cases; ledger: 25 — all passing (`*/eval-cases.jsonl`,
  `*/eval_log.md`).
- forge bridge V39 approval-nonce protocol + ledger HMAC auth covered by dedicated CI eval
  jobs (`.github/workflows/release.yml`).
- A documented adversarial security process: red-team report (`docs/redteam-cycle1.md`),
  threat model with OWASP Agentic Top-10 mapping (`docs/threat-model.md`), and a fix log of
  P0–P2 findings resolved (JSON-injection, TOCTOU race, non-atomic write, table-name injection,
  non-ASCII bypass). **Zero `eval` in any shell path.**
- Reproducible, signed releases with SBOM + critical-vuln gate.

The next milestone is **users to talk to**, not bigger numbers we can't substantiate.

---

## Business model

The binaries and bridges are open-source (MIT) and self-hostable for free, forever. The
planned commercial layer is a **hosted MCP endpoint** (not yet deployed) priced on usage, not
seats — because agents don't have expense accounts, the humans deploying them need predictable
cost. Indicative tiers (see `docs/pricing.md`): a free hosted developer tier, **Pro $49/mo
flat**, **Team $149/mo flat**, and custom Enterprise (private deploy, SSO). No per-transaction
fee on ledger, unlike Stripe's 2.9%+30¢. Marginal cost of one forge analysis is a static-binary
execution (≈$0). These are model assumptions for an unlaunched service — presented as a plan,
not as revenue.

---

## Competition

| | forge | ledger |
|---|---|---|
| Flyway / Liquibase / sqitch | Built for human CI/CD; no machine-readable pre-migration risk gate; JVM cold-start 2–5 s | — |
| Stripe | — | 2.9%+30¢/txn; human dashboard; OAuth, not agent-callable |
| Wave / FreshBooks | — | SaaS with human accounts; no programmatic agent path |
| **HEROS** | JSON-only, MCP-native, self-describing, pre-execution risk + approval gate, <100 KiB | JSON-only, MCP-native, idempotency-keyed writes, HMAC auth, no txn fee |

---

## Roadmap (the v0.2 wedge)

1. **Native Zero MCP server** once Zero ships stdin/file I/O — retire the bash bridge.
2. **forge: emit the fix, not just the risk** — generate the suggested SQL DDL and a phased
   zero-downtime rollout plan (pure compute, fits Zero's no-I/O model). This is the feature
   that turns forge from an advisor into an executor's planner.
3. **ledger: true double-entry** — balanced debit/credit journal entries and account balances
   on top of today's invoice/org primitives.
4. **Hosted endpoint** — managed MCP server so an agent is one config block away from both
   tools with no self-host step.

---

## Founder

**Soumya Debnath** — soumyadebnath1619@gmail.com. Built the full HEROS stack solo: two Zero-lang
tools, two MCP bridges, the eval harness, a documented red-team/threat-model process, signed
reproducible CI, and the launch material. The application demonstrates the ability to ship
security-hardened agent infrastructure end-to-end, alone, at speed.

## What do you need from YC?

1. **Users** — introductions to teams running autonomous agents against real databases and
   money movement, to validate demand and shape v0.2.
2. **Distribution** — the YC network is full of agent-first companies that all need a database
   and a way to handle money.
3. **Credibility** — YC backing turns "interesting open-source project" into "infrastructure
   I'll trust in my production agent loop."
