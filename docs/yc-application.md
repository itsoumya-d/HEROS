# HEROS — YC Application Draft

**Category:** Software for Agents (YC RFS)  
**Stage:** Post-launch, pre-revenue  
**Prepared:** 2026-05-24

---

## Company

**Company name:** HEROS  
**URL:** https://github.com/soumyadebnath/heros  
**Founded:** 2026  
**Location:** Remote  
**Team:** 1 (solo founder)

---

## What does HEROS do? (150 words)

HEROS is infrastructure for autonomous agents — starting with the two backend services every AI-powered application needs: database migration safety and financial accounting.

**forge** analyzes database schema migrations and returns a structured risk assessment before any migration runs. Risk tier, data loss boolean, lock duration estimate, and per-operation guidance — all in JSON. An agent can read one output and decide whether to proceed, gate, or alert, with no human watching.

**ledger** is double-entry accounting for agents. Register an org, create invoices with idempotency keys, and list transactions — all via a JSON API with stable error codes. No Stripe dashboard required.

Both ship as MCP servers (Claude Code, Cursor, any MCP-compatible orchestrator). Both are static binaries (~7-35 KiB) built in Zero lang — no runtime, no GC, no dynamic dependencies. Agents can discover the complete API from a single `--describe` call.

---

## Why now? (100 words)

The MCP ecosystem launched six months ago. Thousands of developers are building autonomous agents that need to manage databases and track money. They're using Flyway (designed for humans with migration GUIs), Liquibase (XML-first, 15-year-old API), and Stripe (2.9% + 30¢ per transaction, human-oriented dashboard). None of these were designed for agents as the primary user.

The window to define the standard for agent-native infrastructure is now — before incumbents add an "agent mode" to legacy tools. We're not retrofitting human tools. We're building from scratch for agents, in a language (Zero) designed for the same era.

---

## What have you built? (150 words)

Two production-quality tools with MCP transport, security hardening, and comprehensive evaluation:

**forge v0.1.4:** Schema migration risk engine. Detects 15 operation types (drop_table, add_column, set_not_null, add_primary_key, add_foreign_key, column type changes, etc.) with correct risk tier and PostgreSQL lock estimates. 38 eval tests documented; 33 binary-testable cases in CI. 239+ red-team security cycles. Zero false negatives on data-loss operations. Implements V39 human acknowledgment token protocol for CRITICAL/HIGH migrations (agents cannot auto-proceed without human sign-off).

**ledger v0.1.11:** Agent accounting engine. Idempotent org registration, invoice creation with idempotency keys, JSONL invoice storage. 25 binary-level eval tests. File locking (TOCTOU-safe), atomic writes (crash-safe), rate limiting, HMAC-SHA256 API key authentication. ASCII-only enforcement on all user fields.

Both: MCP 2025-11-25 protocol compliant, OWASP Agentic Top 10 audited, self-describing via `--describe`, exit 0 on all code paths.

---

## Why Zero lang? (100 words)

Zero is a new systems language from Vercel Labs designed for the same era as agents. We chose it because:

1. **Capability model** — Zero's `World` parameter is the only I/O surface. The binary literally cannot make network calls or read files it wasn't explicitly given. Security is structural, not policy.

2. **No runtime** — ELF64 musl-linked binary. No Python, no Node, no JVM. Drop it in a container and run it. 7-35 KiB vs 50+ MB for any Python alternative.

3. **Deterministic latency** — no GC, no stop-the-world pauses. Agents calling forge in a tight migration loop get consistent sub-millisecond response times.

We're the reference implementation of non-trivial Zero code. When Zero ships v0.2 (stdin support), we'll replace the bash bridges with native Zero MCP servers.

---

## What do you understand that others don't?

**The MCP contract is the product.** Traditional developer tools ship SDKs, CLIs, and web UIs — three different interfaces with three maintenance surfaces. Agent-native tools ship one interface: a `--describe` payload and an MCP manifest. A cold LLM discovers the complete API from one call. No documentation site required.

**JSON on every code path.** Sounds obvious. But Flyway exits non-zero on error (agents must catch exceptions), Liquibase prints XML to stdout (agents must parse XML), and Stripe returns HTTP status codes (agents must merge status + body). Every single error path in forge and ledger emits a stable JSON error code. Agents branch on `error_code`, not text matching.

**Idempotency is not optional for agents.** An agent that retries without idempotency keys creates duplicate invoices. An agent that retries without idempotency tracking creates duplicate orgs. Every write operation in HEROS accepts an idempotency key and returns the same result on duplicate calls. This is not a feature — it's a requirement for agent-safe infrastructure.

**The blast radius of a schema mistake is catastrophic.** Flyway and Liquibase apply migrations and tell you whether they succeeded. forge tells you the risk BEFORE applying. A dropped column detected by forge before the migration runs is a non-event. A dropped column detected after is a data loss incident.

---

## Competition

| | forge | ledger |
|---|---|---|
| **Flyway** | Designed for human CI/CD pipelines. No machine-readable risk assessment. No pre-migration gate. | — |
| **Liquibase** | XML-first API. No per-operation risk tier. No agent quickstart. | — |
| **sqitch** | Change management for humans. No JSON output. | — |
| **Stripe** | — | 2.9% + 30¢/transaction. Human dashboard. No idempotency keys on invoice create. |
| **Wave/FreshBooks** | — | SaaS with user accounts. Not callable by agents without OAuth. |
| **HEROS** | JSON-only, MCP-native, self-describing, pre-migration risk scoring | JSON-only, MCP-native, idempotency keys, no transaction fees |

---

## Traction

- 38 forge eval tests documented (eval_log); 33 binary-testable cases pass in CI
- 25 ledger binary-testable eval cases pass in CI
- 239+ red-team security cycles; all P1/P2 issues resolved; zero `eval` in any shell path
- OWASP Agentic AI Top 10 (ASI01–ASI10) audited and documented
- 4 critical/high security bugs found and fixed (TOCTOU race, non-atomic write, table-name injection guard, non-ASCII input bypass)
- MCP 2025-11-25 protocol compliant; ready for MCP registry submission
- Zero false negatives on data-loss operations across all test scenarios

---

## Business model

**Free hosted tier:** 1,000 forge analyses + 10,000 ledger operations/month. No credit card. Goal: get agents running in < 5 minutes.

**Pro:** $49/month flat. 50,000 forge analyses + 500,000 ledger operations. Priority support. API key management.

**Team:** $149/month flat. 200,000 forge analyses + 2,000,000 ledger operations. 5 API key sets for org isolation across multiple developers or agent environments.

**Enterprise:** Custom pricing. Private deployment, SOC 2, SAML SSO, dedicated support.

No transaction fees on ledger (unlike Stripe's 2.9% + 30¢). Pricing is pure usage-based — agents don't have expense accounts, but the humans deploying them need predictable costs.

---

## The path to $1M ARR

- 500 Pro customers × $49/mo × 12 = $294,000 ARR
- 200 Team customers × $149/mo × 12 = $357,600 ARR
- 25 Enterprise customers × $1,000/mo × 12 = $300,000 ARR
- Combined: $951,600 ARR — achievable with 725 paying customers
- Break-even: ~170 Pro customers or ~80 Team customers or ~20 Enterprise customers

The marginal cost of one additional forge analysis is < $0.00001 (static binary execution). Gross margin target: 70%+ at scale.

---

## Founder

**Soumya Debnath** — [soumyadebnath1619@gmail.com](mailto:soumyadebnath1619@gmail.com)

Built the full HEROS stack solo: two Zero-lang tools, two MCP servers, 239+ security red-team cycles, comprehensive eval harness, pricing model, and launch strategy. Demonstrated ability to ship high-quality, security-hardened infrastructure at speed.

---

## What do you need?

1. **Users** — developers building autonomous agent pipelines who need safe schema migration and reliable accounting.
2. **Distribution** — YC network access to companies building agent-first products (they all need databases and money).
3. **Credibility** — YC backing transforms "cool project" into "infrastructure I'll bet my production agent on."

The tools are built. The security is hardened. The MCP manifests are ready for registry submission. We need users to talk to and distribution to reach them.
