# HEROS Pricing Model

**Philosophy:** Agent-native infrastructure should be free to try, cheap to run, and priced on usage — not seats. Agents don't have expense accounts; the humans deploying them do.

---

## Tiers

### Free — Self-Hosted

**Price:** $0  
**Who:** Developers evaluating, hobbyists, open source projects

- Full forge and ledger source available
- Compile and run anywhere (Linux x86-64, Docker)
- Community support only (GitHub issues)
- No SLA

Self-hosting requires the Zero compiler toolchain. Binaries are pre-compiled and available as release artifacts.

---

### Developer — $0/mo (Free hosted tier)

**Price:** Free forever  
**Who:** Individual developers, early-stage startups, solo agents

- Hosted MCP endpoint (no server required)
- 1,000 forge analyses/month
- 10,000 ledger invoice creates/month
- Unlimited reads (invoice list, count, describe)
- Single org per account
- Email support

**Limits reset monthly.** No credit card required to start.

---

### Pro — $49/mo

**Price:** $49/month (flat)  
**Who:** Teams running autonomous agent pipelines in production

- Everything in Developer, plus:
- 50,000 forge analyses/month
- 500,000 ledger operations/month
- Multiple orgs per account
- API key management (rotate, revoke, audit)
- Rate limit bypass for burst workloads
- Audit log export (JSONL)
- Priority support (24h response SLA)

**Over-limit:** $0.001 per forge analysis, $0.0001 per ledger operation

---

### Team — $149/mo

**Price:** $149/month (flat)  
**Who:** Small teams (2–10 developers) running multiple agent pipelines, each needing separate org isolation

- Everything in Pro, plus:
- 5 API key sets (one per developer or agent environment)
- 200,000 forge analyses/month
- 2,000,000 ledger operations/month
- Org isolation per key (each key scoped to its own org namespace)
- Shared audit log across all keys (single JSONL export)
- Priority support (12h response SLA)

**Over-limit:** $0.001 per forge analysis, $0.0001 per ledger operation

---

### Enterprise — Custom

**Price:** Custom contract  
**Who:** Companies running >1M agent operations/month, or requiring compliance/audit controls

- Everything in Pro, plus:
- Custom rate limits
- SAML SSO
- Private deployment (VPC, on-prem)
- SOC 2 Type II report on request
- Custom data retention policy
- Dedicated support channel (Slack)
- SLA: 99.9% uptime

Contact: [soumyadebnath1619@gmail.com](mailto:soumyadebnath1619@gmail.com)

---

## Why This Model

**Usage-based beats seat-based for agents.** A single agent deployment can generate thousands of operations per hour. Per-seat pricing punishes the teams running the most valuable agent pipelines. Per-operation pricing aligns cost with value.

**Free hosted tier removes friction.** The #1 barrier to adoption for developer tools is the distance between "I found this" and "I'm using it." Requiring deployment before any value is delivered kills 90% of potential users. Free hosted tier gets agents running in < 5 minutes with zero infrastructure.

**Flat Pro pricing is predictable.** Startups building on HEROS need to budget infrastructure costs without per-operation anxiety. Flat $49/month covers all but the highest-volume deployments, with a known overage rate that scales linearly.

---

## Unit Economics (Reference)

| Metric | Developer | Pro | Team |
|---|---|---|---|
| Monthly forge analyses included | 1,000 | 50,000 | 200,000 |
| Monthly ledger operations included | 10,000 | 500,000 | 2,000,000 |
| Storage included | 100 MB | 10 GB | 50 GB |
| API key sets | 1 | 1 | 5 |
| Cost per forge analysis | $0 (in limit) | $0 / $0.001 (over) | $0 / $0.001 (over) |
| Cost per ledger operation | $0 (in limit) | $0 / $0.0001 (over) | $0 / $0.0001 (over) |

**Margin target:** 70%+ gross margin on hosted tier. Binary is static; marginal cost of one additional analysis is dominated by compute (< $0.00001 at current pricing) and storage (negligible).

---

## Competitive Positioning

| Alternative | Pricing | Agent-native? | Open source? |
|---|---|---|---|
| Flyway | Per-developer seat | No | Community edition |
| Liquibase | Per-developer seat | No | Community edition |
| Supabase Migrations | Bundled with Supabase hosting | Partial | Yes |
| HEROS forge | Per-operation, free tier | Yes | Yes |
| Stripe API (for invoicing) | 2.9% + 30¢ per transaction | Partial | No |
| HEROS ledger | Per-operation, free tier | Yes | Yes |

The key differentiation is not price — it's design intent. Every alternative listed was designed for humans. HEROS was designed for agents from the first line of code.

---

## Launch Pricing Notes

For launch (v0.1 → v0.2):

- **Start with free only.** All users on free tier. Collect usage data, talk to users, understand which operations matter.
- **No credit card gate.** Every friction point before first value is lost users.
- **Introduce Pro at 50 users.** Once 50 developers are running HEROS in real agent pipelines, introduce the Pro tier.
- **Introduce Team at 10 Pro subscribers.** Once teams form around HEROS (multiple developers sharing an agent stack), introduce the Team tier. This is a natural upgrade path: one developer evangelizes, the team adopts.
- **Price anchored to Vercel/Railway, not AWS.** Developers building agent apps are comparison-shopping against Vercel ($20/mo), Railway ($20/mo), Supabase ($25/mo). $49/mo Pro fits naturally. $149/mo Team is priced at the Vercel/Netlify Team tier ($100-150), which developer teams treat as standard infrastructure cost.
