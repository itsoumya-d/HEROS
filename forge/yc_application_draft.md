# YC Application Draft — Forge
## Batch: [Current] | Category: Software for Agents (RFS)

**Company:** Forge
**Founder:** Soumya Debnath
**Email:** soumyadebnath1619@gmail.com

---

## What does your company do? (150 words max)

Forge is a database schema migration engine built for autonomous agents. Before an AI agent can execute a database migration, it needs to know: Will this destroy data? Will it lock the table? Is it reversible? Current tools (Flyway, Liquibase) were built for humans who can read logs and press Ctrl+C. Forge is built for agents who need structured JSON risk assessments, stable error codes, and explicit data-loss flags — before execution, not after.

Forge analyzes schema diffs and returns a typed report: `risk_tier` (SAFE/NOTABLE/MEDIUM/HIGH/CRITICAL), `has_data_loss` (boolean), per-operation guidance agents can reason over. An agent can call `forge --describe` once and know everything it needs to use forge correctly.

We're building the ops toolchain agents need to work autonomously on production systems.

---

## Why now? (100 words max)

AI coding agents (Claude, Cursor, Devin) are increasingly given database credentials and told to "fix this bug." The standard workflow — agent writes migration, runs it, hopes for the best — destroys data several times a week across the industry. The missing piece is a risk layer between "agent decides to migrate" and "migration executes." This layer needs to be agent-native from day one: JSON output, no interactivity, stable error codes, programmatic discovery. Every week this layer doesn't exist is another data incident.

---

## What have you built? (150 words max)

Working forge binary (ELF64 linux-musl-x64, ~15.6 KiB) built in Zero lang v0.1.1. The binary:

- `forge --describe` returns a complete machine-readable schema of all commands, input formats, output shapes, and error codes in a single JSON call — including `output_schema` and `migop_schema` blocks so a cold LLM knows exact field names, types, and semantics with no external documentation
- `forge analyze` returns structured risk reports: `risk_tier`, `risk_score`, `has_data_loss`, `decision_required` (explicit halt signal — agents MUST NOT auto-proceed when true), per-operation `agent_guidance`; supports `--request-id` for idempotent retried calls
- `forge --version` returns stable JSON with a `schema_version` field that allows agents to detect breaking output changes independently of the semver string

All output paths emit JSON. Errors go to stdout (not stderr) so agents always get a parseable response. Cold-start agent eval (Test 7): a fresh LLM given only `--describe` output correctly constructed the invocation, identified the right gate fields, and classified the migration risk — with no prior documentation. YC scorecard: 40/40. The MCP manifest allows forge to be used as a native tool by Claude, Cursor, and any MCP-compatible agent.

---

## Why Zero lang? (100 words max)

We chose Zero for a principled reason: agent-native software should be as auditable as the agents using it. Zero's capability model (all I/O flows through an explicit `World` parameter) makes forge's I/O surface completely inspectable. No hidden file handles, no surprise network calls. Zero produces static musl-linked binaries with no runtime dependencies — an agent can drop forge in a container and run it. Zero's type system prevents the silent data corruption bugs that plague Python migration scripts. Zero is to agent-native software what Rust was to systems software: a language that makes the right thing the default.

---

## What do you understand that others don't? (100 words max)

The mistake everyone else makes is building agent integrations as afterthoughts — wrapping existing human-facing tools with thin JSON adapters. Flyway with `--outputType=JSON` still has interactive prompts, ambiguous exit codes, and ANSI escape codes in error messages. The right approach is designing for agents from the first line of code: every function returns a structured type, every error has a stable code, every output path is machine-readable.

Forge is the first migration tool designed this way. The same principles apply to every category of ops tooling: deployment, secret management, access control, monitoring. We're building the category.

---

## Additional Context

### The agent_ux failure mode forge solves

Traditional migration tools fail agents in three specific ways:

1. **Interactivity**: They prompt for confirmation (`Proceed? [y/N]`). Agents calling these as subprocesses hang or send unexpected input.
2. **Mixed output**: They emit human prose, ANSI codes, and progress bars to stdout alongside machine-parseable data. Agents reading stdout get garbled JSON.
3. **Exit code ambiguity**: Exit code 1 means "migration failed," "invalid flag," "no migrations to run," and "I/O error" depending on the tool and version. Agents cannot branch correctly.

Forge eliminates all three: no prompts, JSON-only stdout, and errors encoded in the payload rather than in exit codes.

### Why the binary size matters

At ~18.6 KiB, forge is small enough to be embedded directly in agent scaffolding containers, included in CI images without layer bloat, and distributed as a tool artifact alongside agent-generated migration files. Agent infrastructure has different economics than human infrastructure — tools are invoked many times per session, cold-start time compounds, and binary footprint is a first-class constraint.

### The `schema_version` contract

Every forge response includes `"schema_version": 1`. This single field solves a hard problem in agent tooling: how does an agent know when its cached understanding of a tool's interface is stale? Agents can cache the `--describe` payload and gate re-fetching on this field changing — no documentation polling, no semver parsing, no prompt-engineered version detection.

### Competition

| Tool | JSON output | No interactivity | Stable error codes | Agent discovery | Binary size |
|---|---|---|---|---|---|
| Flyway | Partial | No | No | No | ~50 MB JVM |
| Liquibase | Partial | No | No | No | ~40 MB JVM |
| sqitch | No | No | No | No | Perl runtime |
| **forge** | **Yes (all paths)** | **Yes** | **Yes** | **Yes (`--describe`)** | **~18.6 KiB** |

The JVM-based tools have an additional problem: cold-start latency of 2–5 seconds per invocation. In an agentic loop running 20 migrations, this is 40–100 seconds of JVM startup overhead. forge starts in under 1 millisecond (no libc startup, no dynamic linker, direct ELF64 entry point).

---

*Forge v0.1.0 — Soumya Debnath — soumyadebnath1619@gmail.com*
