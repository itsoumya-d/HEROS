# HEROS Launch Strategy

**Version:** v0.1.11 launch (ledger) + v0.1.4 (forge)  
**Target:** Developer community, YC Demo Day, AI agent ecosystem  
**Prepared:** 2026-05-24

---

## The Premise

Every software category needs to be rebuilt for agents as the primary user. HEROS is the first infra layer doing this — starting with the two most universal categories: schema management and accounting.

The YC RFS "Software for Agents" is not a niche. Every company deploying autonomous agents will eventually need:
- Safe schema migration that agents can reason over without human supervision
- Structured financial records that agents can create without invoking Stripe's human-oriented API

HEROS ships both. Today. In production-quality Zero binaries with MCP integration.

---

## Phase 1: Developer Launch (Now — Week 0)

### Where to Launch

**1. Hacker News — Show HN**

Title: `Show HN: HEROS – Database migrations and accounting rebuilt for AI agents`

Key points for the post:
- Both tools ship as MCP servers (plug into Claude Code, Cursor, any MCP client)
- JSON-only output: every code path, including errors, emits stable JSON codes agents can branch on
- Static binaries: drop in a container, run. No Python, no Node, no runtime
- Open source: source in Zero lang (novel angle — explain the language choice)
- Written in Zero (Vercel Labs' new systems language) — genuinely novel tooling angle

**Best time to post:** Tuesday or Wednesday, 8-9am EST. Aim for 2nd or 3rd slot on the front page.

**2. Claude Code MCP Registry / Community**

Both tools are ready for the MCP registry. Submit `mcp-manifest.json` for both forge and ledger. These are the files that enable one-click tool installation. Claude Code users discovering "database migration" or "invoicing" tools via the registry get HEROS.

**3. X/Twitter**

Thread starting with the core insight:
> Every library, every API, every tool you use was designed for a human at a keyboard. We're rebuilding infrastructure for agents. Starting with schema migrations and accounting.
>
> forge: schema migration risk analysis that agents can act on without asking a human
> ledger: agent-native accounting with idempotency keys so agents never double-charge
>
> Both ship as MCP servers. JSON-only. Static binaries. Try in 60 seconds with Claude Code.

Tag: @AnthropicAI, @vercel (Zero lang is theirs), relevant AI builder accounts.

**4. Reddit — r/MachineLearning, r/LocalLLaMA, r/ClaudeAI**

Post in r/ClaudeAI specifically: "I built two MCP tools for Claude Code — database migration risk analysis and agent accounting." Concrete, specific, links to install instructions.

---

## Phase 2: Positioning (Week 1-2)

### The Core Message

**For engineers:** "Infrastructure that speaks agent. Drop in two MCP tools and your agent can safely migrate databases and track invoices — with the same guarantees you'd expect from a production API."

**For founders:** "The accounting and data infrastructure your autonomous agents need. Built for the post-human-in-the-loop era."

**For YC:** "Software for Agents, implemented. Not a pitch for what could exist — two production tools that exist today, in a novel systems language, solving the two most universal backend problems agents face."

### What Makes This Real

Three things differentiate HEROS from "yet another agent tool":

1. **Built in Zero lang** — not Python wrappers around existing tools. This is new infrastructure at the metal level. 7 KiB binary, no GC, capability-model I/O.

2. **Security-first by construction** — Zero's capability model means the binary literally cannot make network calls or read files it wasn't given. OWASP Agentic Top 10 audited. No eval anywhere in the bridge.

3. **Self-describing API** — `--describe` emits the complete contract. A cold LLM with no system prompt discovers the full API from one CLI call. This is the property that makes tools composable across orchestrators.

---

## Phase 3: Content Strategy (Week 2-4)

### Technical Blog Posts

**Post 1:** "Why we built HEROS in Zero lang" — explain the language choice, the capability model, why it matters for agent-facing software. Educational, builds credibility.

**Post 2:** "The 5 ways traditional database migration tools break in agent pipelines" — forge's specific value prop. Risk scoring, JSON output, no interactive prompts. Include example of Flyway failing in an automated context.

**Post 3:** "Idempotency keys are the API contract for agents" — ledger's core insight. Why you can't build reliable agent accounting without them. Include code showing how retry loops work with and without idempotency keys.

**Post 4:** "How we red-teamed 149+ attack cycles on a 7KB binary" — security credibility. Detail the TOCTOU race, the double-escape bug, the argument injection prevention. This is the post that gets HN's security-focused readers.

### Developer Documentation

Priority docs to ship alongside launch:
- `docs/getting-started.md` — 5-minute quickstart from zero to running MCP tools in Claude Code
- `docs/mcp-setup.md` — exact JSON config for Claude Code, Cursor, and other MCP clients
- `docs/threat-model.md` — already exists; link prominently (agents handle sensitive financial data)
- `docs/agent-ux-principles.md` — the 24 principles that guided HEROS design; published as a reference

---

## Phase 4: YC Application Prep

### The Application Angle

HEROS fits the YC RFS "Software for Agents" category exactly. The application should emphasize:

**What we built (not what we're building):** forge and ledger are live. Not prototype, not mockup — production binaries with MCP transport, rate limiting, idempotency, and a documented red-team security process.

**The timing argument:** The MCP ecosystem is 6 months old and growing exponentially. Every AI company building agents needs the same infrastructure: schema management and financial records. The window to define the standards is now.

**The Zero lang angle:** Nobody else is building agent-native infra in a language designed for agent-native software. This is a genuine moat — the compilation target (ELF64 musl), the capability model, the self-describing output format. Building on Zero before v0.2 ships (stdin support) means HEROS will be the reference implementation when the language matures.

**The team:** Solo founder who built a complete production stack (two tools, MCP protocol, a documented red-team process, comprehensive eval suite) from scratch. Execution velocity matters more than team size at this stage.

### Key Numbers for the Application

- 2 production tools shipped
- 38 documented eval tests (forge) + 33 binary-testable eval cases; 25 binary-testable ledger eval cases
- Documented red-team process; all P1/P2 findings resolved
- 4 critical/high security bugs found and fixed (TOCTOU race, non-atomic write, table-name injection guard, non-ASCII input bypass)
- ~7-35 KiB binary size (compare: any Python tool is 50MB+ with dependencies)
- MCP 2025-11-25 protocol compliant
- OWASP Agentic AI Top 10 audited
- Zero `eval` in any shell code path (eval-auth.sh, eval-bridge.sh, all production bridges)

---

## Phase 5: Community Building (Month 2+)

### Target Communities

**Primary:** AI agent builders — people using Claude Code, Cursor, LangGraph, AutoGen, CrewAI, custom agent frameworks. These are the people who will hit the "I need a safe migration" or "I need to track agent costs" problem and find HEROS.

**Secondary:** Developer tool founders — companies building on top of AI agents who need reliable infrastructure. They're thinking about what agent-native versions of Stripe, Vercel, and Supabase look like.

**Tertiary:** Language enthusiasts — Zero lang is new and interesting. The Zero community will care about HEROS as a reference implementation of non-trivial Zero code.

### Growth Loop

1. Developer finds HEROS via HN / MCP registry / X
2. Adds forge or ledger as MCP tool in 60 seconds
3. First real use: agent runs a schema migration or creates an invoice
4. Developer shares the "it just worked" moment
5. Other developers discover via share
6. Repeat

The key metric: time from discovery to first successful MCP tool call. Target < 5 minutes. Every friction point between discovery and first value is a lost user.

---

## Launch Checklist

### Week 0 (Now)

- [ ] Push source to GitHub (public repo)
- [ ] Create GitHub release with precompiled forge and ledger binaries
- [ ] Write and post Show HN
- [ ] Submit to MCP registry (forge and ledger manifests are ready)
- [ ] Post X thread
- [ ] Post to r/ClaudeAI

### Week 1

- [ ] Respond to all HN comments (same day if possible)
- [ ] Publish "Why Zero lang" blog post
- [ ] Add GitHub Actions CI for binary builds
- [ ] Set up hosted free tier (single endpoint, rate-limited)

### Week 2

- [ ] Begin YC application
- [ ] Publish "5 ways migrations break in agent pipelines" post
- [ ] Launch Discord or Slack community (if > 50 users)

### Month 2

- [ ] Pro tier launch ($49/mo)
- [ ] Ship queue.0 (next zero-ecosystem tool — job queues for agents)
- [ ] Expand to more agent-native categories

---

## Anti-Goals

Things we will NOT do at launch:

- **No marketing site first.** Ship the tools. Users care about the tool, not the website.
- **No investor pitch before users.** Talk to developers first. Understand what they actually need. Then raise.
- **No feature creep.** forge does schema risk analysis. ledger does invoicing. Both do these things extremely well. Do not add "AI-powered suggestions" or other distractions before nailing the core.
- **No enterprise sales before product-market fit.** Sell to developers. If developers love it, enterprise follows.

---

## Success Metrics (90 Days)

| Metric | Target |
|---|---|
| GitHub stars | 500+ |
| Active MCP installs | 100+ |
| HN Show HN points | 100+ |
| Discord/Slack members | 50+ |
| Developers using in production | 10+ |
| YC application submitted | Yes |
| Follow-on tool (queue.0) shipped | Yes |

The single most important metric: **developers using HEROS in real agent pipelines** (not toy examples). One developer running 10,000 forge analyses a month on a production agent is worth more than 500 GitHub stars from people who bookmarked the repo.
