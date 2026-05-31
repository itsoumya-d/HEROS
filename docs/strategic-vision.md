# HEROS Strategic Vision — The Agent Operations Stack

**Date:** 2026-05-31  
**Author:** Soumya Debnath  
**Status:** Founder's working document — honest analysis, not pitch deck

---

## The Core Thesis

Every human software system eventually develops an **operations layer** — the infrastructure
that ensures reliability, safety, auditability, and accountability. For cloud computing, this
layer is AWS + Datadog + Splunk + PagerDuty + Stripe. These companies collectively represent
hundreds of billions in market value, not because they have flashy products, but because
**they sit in the critical path of every operation.**

Autonomous AI agents are becoming their own category of software system. They write code,
modify databases, spend money, manage infrastructure, and act on PII. They will need the same
operations layer — rebuilt from scratch, because the human-optimized versions (Flyway, Stripe,
HashiCorp Vault, Splunk) were designed for humans who click "confirm," not agents that parse
JSON and loop.

**HEROS is building that operations layer.** The five current tools — forge, ledger, guardian,
vault, audit — are the first primitives of what becomes the standard agent ops platform.

---

## Why the Timing Is Right Now

**The MCP standardization event (late 2024)** created a stable protocol for agent↔tool calling.
Before MCP, every agent framework had a different tool-calling convention. After MCP, there is
a universal interface. This is analogous to HTTP/1.1 standardizing web protocols in 1997 — it
created the foundation for a generation of web infrastructure companies.

**The first production incidents are happening now.** Agents with production database
credentials are being deployed. Table drops happen. Duplicate invoices get issued. Unauthorized
API calls run in loops. These are not hypothetical risks — they are the founding incidents that
create regulatory and organizational demand for agent safety infrastructure.

**The EU AI Act's agentic provisions are entering force.** High-risk AI systems acting on
regulated data (financial records, health data, infrastructure) must maintain audit trails and
human oversight mechanisms. HEROS's `decision_required` flag and tamper-evident `audit` log
are direct implementations of these requirements — before they are mandated.

**The orchestration layer is consolidating.** Claude Code, Cursor, LangGraph, and a handful of
others will become the dominant agent orchestration platforms. The window to become the standard
ops layer they integrate with (rather than build themselves) is open for approximately 18-24
months. After that, major orchestrators either build their own or have committed to a standard.

---

## The Platform Map

Each HEROS tool addresses a specific point where agents fail in production today:

```
AGENT OPERATION LOOP
        │
        ▼
┌───────────────┐     ┌─────────────────────────────────────┐
│  PLANNING     │────▶│  guardian: "is this safe to do?"     │
│  (what to do) │     │  forge: "is this migration safe?"    │
└───────────────┘     └─────────────────────────────────────┘
        │
        ▼
┌───────────────┐     ┌─────────────────────────────────────┐
│  CREDENTIALS  │────▶│  vault: "what key do I use for X?"  │
│  (auth to do  │     │  HMAC auth on ledger/forge bridges  │
│   it with)    │     └─────────────────────────────────────┘
└───────────────┘
        │
        ▼
┌───────────────┐     ┌─────────────────────────────────────┐
│  EXECUTION    │────▶│  (the actual operation)              │
│  (doing it)   │     │  DB migration, API call, file write  │
└───────────────┘     └─────────────────────────────────────┘
        │
        ▼
┌───────────────┐     ┌─────────────────────────────────────┐
│  ACCOUNTING   │────▶│  ledger: "record this transaction"   │
│  (what did    │     │  audit: "append tamper-evident log"  │
│   it cost?)   │     └─────────────────────────────────────┘
└───────────────┘
```

The goal is for every step in an agent's action loop to pass through a HEROS primitive. Not
because HEROS owns the loop, but because the HEROS primitives are the *correct* way to do
each step — the ones that produce audit trails, prevent accidents, and recover from failures.

---

## The Expansion Roadmap

### Phase 1: Core Primitives (Current — v0.1)
What we have:
- **forge** — DB migration safety (15 op types, 5 risk tiers, human approval nonce)
- **ledger** — Agent accounting (invoices, org, HMAC auth, idempotency)
- **guardian** — Universal operation safety oracle (6 categories, same approval protocol)
- **vault** — Agent-native credential storage
- **audit** — Tamper-evident compliance log

### Phase 2: Depth and Ecosystem (v0.2, ~6 months)
Priority improvements:
1. **forge: emit the fix** — given a CRITICAL migration, generate the zero-downtime DDL.
   Pure compute fits Zero's model; this turns forge from an advisor into a planner.
2. **ledger: double-entry** — balanced journal entries, account hierarchies, balance queries.
   The primitive that makes agent financial records auditable by humans and regulators.
3. **Native Zero MCP server** — retire bash bridges once Zero ships `world.in` (stdin).
4. **forge + Squawk integration** — add Squawk (Rust binary, free, Postgres lock-hazard
   detection) as a second-pass validator; the combination catches both generic and
   dialect-specific risks.
5. **OpenTelemetry tracing** — `otel-cli exec` wrapping each bridge invocation; spans
   compatible with all major observability backends; MCP semantic conventions.

### Phase 3: Platform and Distribution (v0.3, ~12 months)
1. **Hosted MCP endpoint** — managed service; one config block, no self-host.
2. **Per-agent identity** — each agent gets a unique identity bound to its HEROS API key;
   audit log entries carry agent identity rather than just org.
3. **Budget enforcement** — ledger gains `budget_set/check` operations; agents halt before
   overspending, not after.
4. **guardian: file system integration** — forge detects DB schema changes; a parallel
   system detects dangerous file system mutations in agent-managed directories.
5. **Webhook notifications** — when an agent's operation is blocked by guardian or forge,
   send a webhook to the human operator for async approval.

### Phase 4: The Safety OS (v0.4+, ~24 months)
The long-horizon vision: HEROS becomes the **permission and audit fabric for all agent actions**,
analogous to what AWS IAM is for cloud resources.

An agent's capabilities are defined not by what it can technically call, but by what HEROS
allows it to call — with full audit trail, budget enforcement, and human override capability.
This is the "IAM for agents" vision: every tool call goes through a HEROS permission check,
every action is logged in the tamper-evident audit, every budget constraint is enforced.

---

## Realistic Market Sizing

**Comparable infrastructure companies:**
- Datadog: ~$2.5B ARR, ~10,000 paying enterprise customers
- Stripe: ~$14B ARR, ~millions of developers
- HashiCorp Vault: acquired at ~$6.9B

**The agent safety infrastructure TAM:**

Scenario A (base): 50,000 companies deploying meaningful agent workloads by 2029, average
$10K/year spend on agent ops infrastructure → **$500M ARR**.

Scenario B (regulatory pull): The EU AI Act and financial regulations mandate audit trails for
autonomous agent operations. All enterprises running agents in regulated domains need compliance
infrastructure. 500,000 companies at $5K/year → **$2.5B ARR**.

Scenario C (platform): HEROS becomes the default ops layer for the top 5 agent orchestration
platforms. Network effects from orchestrator integration drive adoption. $10B+ ARR in the 2032
timeframe is plausible but requires winning the integration race.

**Best honest estimate: $500M–$5B ARR by 2032**, depending on regulatory velocity and
orchestrator integration success. This is a Datadog-scale company, not a Google-scale company.
The trillion-dollar framing requires assumptions about agent volume that aren't yet defensible.

---

## The Most Important Strategic Risk

**Absorption into runtimes.** Anthropic, OpenAI, or Google could decide that agent safety is
a platform responsibility and build forge/guardian-equivalent functionality into the agent
runtime. If Claude Code ships native schema migration risk classification, HEROS has no
distribution channel to Claude Code users.

**Mitigation:** Build deep integrations across all major orchestrators simultaneously. Become
the reference implementation that orchestrators *point to* rather than compete with. Publish
open standards (the `--describe` self-description format, the approval-nonce protocol) that
other tool builders adopt — making HEROS the standard rather than a single product.

**The deeper moat:** The risk classification *corpus*. If HEROS accumulates data about which
operations caused production incidents (anonymized, aggregate), that data improves risk
classification in ways that a runtime-level integration cannot easily replicate. The corpus is
the moat; the tools are the collection mechanism.

---

## Open Source Tools Integration Plan

Based on open source research (May 2026), highest-priority integrations for HEROS:

| Tool | What it adds | Priority | Integration point |
|------|-------------|----------|------------------|
| **Squawk** | Postgres-specific lock hazard detection (Rust binary, free) | High | forge bash bridge second-pass |
| **otel-cli** | MCP-spec-aligned spans, bash-native, no runtime deps | High | All bridges (optional, env-var gated) |
| **GNAP protocol** | Zero-cost multi-agent coordination via git+JSON | Medium | New `herd` tool for forge+ledger coordination |
| **Litestream** | SQLite replication for ledger/vault state | Medium | Production deployment guide |
| **sqlite-utils** | JSON queries on ledger/audit JSONL (Python stdlib) | Low | Operational tooling |

None of these require cloning large runtimes (no Node.js, no JVM). All work from bash.

---

## What Success Looks Like in 12 Months

1. **10 companies using forge in production** — forge pre-migration checks running in real
   agent pipelines against real PostgreSQL databases. This validates demand.
2. **YC W27 batch** — funded, with distribution access to 200+ agent-first companies in the
   batch.
3. **Hosted endpoint live** — the commercial layer deployed; first paid customers.
4. **forge v0.2 shipped** — emit the zero-downtime migration DDL; this is the feature that
   turns forge from a classifier into a planner and drives the next wave of adoption.
5. **OWASP Agentic Top-10 reference implementation** — HEROS cited as the canonical example
   of how to implement pre-execution risk gates (ASI01, ASI09) in agent tooling.

The path from "pre-revenue open source project" to "funded, revenue-generating infrastructure
company" runs through users. Every other metric is a proxy. The immediate priority is finding
10 teams that run agents against databases and getting them to try forge.
