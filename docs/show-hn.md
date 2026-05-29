# Show HN: HEROS — Database migrations and accounting rebuilt for AI agents

**Hacker News submission draft**  
Target: Tuesday/Wednesday 8-9am EST — aim for 3rd-5th slot on front page

---

## Title

```
Show HN: HEROS – Database migrations and agent accounting rebuilt for AI agents (Zero lang)
```

*Alt titles (A/B test):*
- `Show HN: I rebuilt schema migrations and accounting for AI agents in a 7KB static binary`
- `Show HN: forge + ledger — MCP tools for agents that need safe DB migrations and invoicing`

---

## Post Body

Hi HN,

I've been thinking about a specific problem: every tool agents use today was designed for a human at a keyboard. Flyway assumes you'll read its output. Stripe assumes you'll click its dashboard. When an agent tries to use them, things break in subtle ways.

I built two tools to fix this:

**forge** — schema migration risk analysis. Before running any migration, forge returns a structured JSON risk assessment: risk tier (SAFE/NOTABLE/MEDIUM/HIGH/CRITICAL), data loss boolean, PostgreSQL lock duration estimate, and per-operation agent guidance. If the migration would drop a table or lose data, agents get `decision_required: true` and must obtain a human acknowledgment token before proceeding. They literally cannot auto-proceed.

**ledger** — agent-native accounting for agents. Register an org, create invoices with idempotency keys, list transactions. No Stripe dashboard. No transaction fees. JSON-only API with stable error codes.

Both ship as MCP servers (Claude Code, Cursor, any MCP client). Both are static binaries (~7-35 KiB) built in Zero lang — no runtime, no GC, no Python, no Node.

**The weird/interesting part:** They're written in Zero, a new systems language from Vercel Labs. Zero's capability model means the binary literally cannot make network calls or read files it wasn't explicitly given — security is structural, not policy. I'm probably the largest non-trivial Zero codebase outside Vercel.

**Security:** a documented red-team audit process. Found and fixed: TOCTOU race condition in invoice creation (flock -x across check+write+append), non-atomic .ledger-data writes (mktemp+mv), table-name injection in the Zero binary, non-ASCII byte bypass in field validation.

Try it in 60 seconds with Claude Code:
```bash
curl -L https://github.com/itsoumya-d/HEROS/releases/latest/download/forge -o forge && chmod +x forge
./forge --describe  # full API contract, no docs needed
```

Or ask Claude: "Add forge and ledger as MCP tools" — the manifests are self-describing.

Source: https://github.com/itsoumya-d/HEROS  
Docs: [docs/getting-started.md]

Happy to answer questions about Zero lang, the agent-native design decisions, or the security audit process.

---

## Expected Questions + Answers

**Q: Why Zero lang instead of Go/Rust?**
A: Zero's capability model gives you structural security guarantees. The binary cannot make syscalls it wasn't compiled with permission for. For agent-facing infrastructure, that's worth a lot. Also: 7 KiB binary vs 8+ MB for any Go equivalent.

**Q: What's the business model?**
A: Free hosted tier (1K forge analyses + 10K ledger operations/month), Pro at $49/mo (50K + 500K), Team at $149/mo (5 key sets, 200K + 2M). Same pricing as Vercel/Railway — developers expect this tier structure.

**Q: Isn't this too niche?**
A: Every company running autonomous agents eventually needs to migrate their database safely and track money. YC's Spring 2025 batch was >50% agentic AI. Every one of those companies will hit this problem.

**Q: How does the human acknowledgment token work?**
A: forge issues a 64-bit nonce when `decision_required: true`. The nonce expires in 5 minutes and is single-use. The agent must present it on the second call after getting human sign-off. This is protocol-level enforcement — no way for an agent to bypass it without the nonce.

**Q: Why not just use existing migration tools with a JSON output flag?**
A: Flyway/Liquibase don't give you pre-migration risk assessment. They tell you if a migration succeeded; they don't tell you it would drop a column before you run it. forge's entire value is the risk analysis BEFORE execution.

**Q: Is Zero production-ready?**
A: For this use case, yes. Zero v0.1.3 produces deterministic ELF64 binaries. The forge binary has been exercised by the CI-gated eval harness. The constraint (no stdin in v0.1.x) is why bash bridges exist — Zero v0.2 will support stdin, at which point the bridges become Zero-native MCP servers.

---

## Timing

- **Post:** Tuesday or Wednesday, 8-9am EST
- **Monitor:** Be online for first 2 hours to respond to comments
- **Cross-post:** X thread immediately after posting, r/ClaudeAI same day
- **Follow-up:** Reply to every top-level comment within 1 hour of posting
