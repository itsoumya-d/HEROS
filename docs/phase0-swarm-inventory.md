# Phase 0 — Swarm Inventory: Sub-agents, Tools, and Gap Assignments

**Last updated:** 2026-05-24  
**Zero version:** v0.1.3  
**Project root:** `E:/HEROS/`  
**Purpose:** Enumerate every AI sub-agent channel and MCP tool available in this Claude Code session, then assign each ecosystem gap in `zero-ecosystem/` to a specific sub-agent type with a loop trigger and current status. This is the operational map for the perpetual research → design → build → eval → checkpoint → repeat mission.

---

## 1. Sub-agent Channels

All sub-agents are launched via the Agent tool. Multiple Agent calls in a single message run **concurrently** — the main session is a dispatcher, not a sequential worker. Every sub-agent here can also run with `run_in_background=true` for fire-and-monitor dispatch.

### 1.1 Explore

**Role:** Fast, read-only code and file exploration. Does not write files. Best for traversal tasks where the answer is already in the codebase or docs.

**Search breadths available:** `quick`, `medium`, `very thorough`

**Use cases for this project:**
- `quick` — check if a Zero stdlib function exists before starting a design (e.g., "does `std.fs.openAppend` appear in the v0.1.3 cheatsheet?")
- `medium` — trace all callers of a pattern across `zero-ecosystem/` subdirs (e.g., "how many tools use `std.fs.create` vs `std.fs.openOrRaise`?")
- `very thorough` — full audit of a new Zero release: enumerate every new stdlib symbol, every changed signature, every new error code

**When NOT to use:** Any task requiring file writes, design decisions, or multi-step state. Hand off to `general-purpose` or `code-architect`.

---

### 1.2 Plan

**Role:** Architecture and implementation planning. Produces structured plans with numbered steps, dependency ordering, and trade-off analysis. Does not execute plans.

**Use cases for this project:**
- Design the implementation sequence for a gap (e.g., "plan the build order for `kv-store` given that `std.fs.rename` is blocked")
- Produce a migration plan when a new Zero version unblocks multiple gaps simultaneously
- Design the eval case structure for a new Zero tool before writing a single line of `.0` code

**Output contract:** Plans should be written as numbered step lists with explicit blockers and acceptance criteria so a downstream `general-purpose` agent can execute them deterministically.

---

### 1.3 code-reviewer

**Role:** Code review — bugs, security issues, naming conventions, edge cases. Reads existing code and emits a structured list of findings.

**Use cases for this project:**
- Audit `jsonschema_mini.0` after each new constraint is added (catches off-by-one in range checks, missed error paths, enum bypass vectors)
- Review `zeval.sh` for bash injection risks before it becomes the CI gate
- Regression scan every time a Zero version bump changes a stdlib signature — check all existing `.0` files for broken call sites

**Important:** Every new Zero tool should pass a `code-reviewer` pass before its eval case count is considered final. The `json-schema` gap went through 8 reviewer cycles (v0.1.0 → v0.1.8) catching RT-116 through RT-151.

---

### 1.4 feature-dev:code-architect

**Role:** Designs feature architectures and produces implementation blueprints — interface definitions, data flow diagrams (as text), module boundaries, error taxonomy.

**Use cases for this project:**
- Design the `kv-store` atomic-write protocol (temp-file + rename dance) before Zero has `std.fs.rename` — so the design is ready the moment the blocker clears
- Produce the `--describe` JSON schema for every new Zero tool (this is the agent-facing contract, must be locked before implementation)
- Design the `mcp-server` native Zero port architecture so it can be assembled in a single sprint when `world.in` ships in v0.2

**Output format:** Blueprint documents that live in `zero-ecosystem/<gap>/README.md` under a "Design" section. Include: agent-facing CLI interface, internal data structures (as Zero `shape`/`choice` pseudocode), eval case skeleton.

---

### 1.5 feature-dev:code-explorer

**Role:** Traces execution paths, maps architecture layers, answers "how does X connect to Y" questions.

**Use cases for this project:**
- Trace the full execution path of `jsonschema validate` from arg parsing through error emission — used to find untested branches before adding eval cases
- Map which Zero stdlib modules each gap depends on (produces the dependency graph for the capability roadmap)
- Explore how `zeval.sh` wraps the binary and where the field-matching logic could silently fail

---

### 1.6 feature-dev:code-reviewer

**Role:** Reviews code for quality issues — redundancy, dead code, unclear naming, missing docs. Complementary to `code-reviewer` which focuses on bugs/security.

**Use cases for this project:**
- Quality pass on `zlog` implementation before shipping v0.1.0 — checks for consistent naming conventions (`zlog` vs `logger` vs `log_entry`)
- Review `zeval.sh` for readability and maintainability before it becomes the CI gate
- Spot dead branches in `jsonschema_mini.0` that accumulated across 8 versions

---

### 1.7 claude (general-purpose catch-all)

**Role:** Multi-purpose. Used when the task doesn't fit a specialist role: quick calculations, formatting, summarizing, small edits.

**Use cases for this project:**
- Format a raw JSONL eval case file into a readable table for a README
- Summarize a Zero GitHub release notes page into a "what changed for our gaps" bullet list
- Translate a bash eval script output into the `zeval` JSONL case format

---

### 1.8 claude-code-guide

**Role:** Claude Code / Agent SDK / Anthropic API specialist. Answers questions about how to use Claude Code itself, agent orchestration patterns, and the Anthropic API.

**Use cases for this project:**
- When designing the native MCP stdio server in Zero: "what does the MCP protocol expect on stdin for a `tools/call` request?" — produces the exact byte format `mcp-server/` must handle
- Debug Agent tool dispatch patterns — why did a parallel dispatch not run concurrently?
- Optimize prompt caching strategy for the perpetual loop's system prompt

---

### 1.9 general-purpose

**Role:** Multi-step research across large codebases. Can read many files, synthesize findings, and produce structured reports. The workhorse for tasks that require more than a single Explore traversal.

**Use cases for this project:**
- Full gap status audit: read all 10 `zero-ecosystem/<gap>/README.md` files, cross-reference against the Zero stdlib cheatsheet, produce an updated gap registry with accurate blockers
- New Zero release triage: read release notes + all gap READMEs + cheatsheet → emit a ranked list of "now unblocked" gaps
- Eval coverage audit: read all existing `.jsonl` eval case files and identify which code paths in each `.0` file have no corresponding test case

---

### 1.10 agent-sdk-dev:agent-sdk-verifier-py

**Role:** Python Agent SDK verification. Tests that Python code using the Anthropic SDK behaves correctly.

**Use cases for this project:**
- When the `mcp-server` gap ships: verify that a Python MCP client can call the native Zero MCP server over stdio
- Verify that a Python orchestrator correctly dispatches Zero tools as subprocesses and handles non-zero exit codes

---

### 1.11 agent-sdk-dev:agent-sdk-verifier-ts

**Role:** TypeScript Agent SDK verification. Tests TypeScript/Node.js code using the Anthropic SDK.

**Use cases for this project:**
- Verify that a TypeScript Claude Code extension can invoke Zero binaries as tool calls
- Test the MCP stdio server protocol compliance from a TypeScript MCP client when `mcp-server` ships

---

## 2. MCP Tool Channels

MCP tools extend the session's reach beyond the local filesystem. Each tool below is relevant to at least one mission activity.

### 2.1 mcp__claude_ai_Supabase__*

**Relevant tools:** `execute_sql`, `list_tables`, `apply_migration`, `get_logs`, `get_advisors`

**Project use:**
- **v0.2 gap prep:** When `kv-store` ships, Supabase can host the authoritative schema registry — a table mapping tool names to their `--describe` JSON schemas. Zero tools self-register on first run.
- **eval log persistence:** Store eval run results (passed/failed counts, failure diffs) in a structured table instead of markdown files. Query: "show all eval regressions since 2026-05-19."
- **rate-limiter state (v0.2):** If `rate-limiter` stays blocked on native Zero file-lock, Supabase can serve as the shared state store for a bash-bridged rate limiter.

**Auth status:** Requires authentication before first use in a new session (`mcp__claude_ai_Supabase__authenticate`).

---

### 2.2 mcp__plugin_context7_context7__*

**Relevant tools:** `resolve-library-id`, `query-docs`

**Project use:**
- **Every research cycle:** Before assuming a Zero stdlib function exists, call `query-docs` for the Zero language library ID. Training data may not reflect v0.1.3 additions (e.g., `std.crypto.hmac32`, `std.proc.spawn`, `std.io.bufferedReader` — all appeared after v0.1.1).
- **MCP spec research:** Query MCP protocol docs to get exact message formats for the `mcp-server` gap design.
- **Trigger:** Call at the start of every loop cycle where a Zero version bump is suspected.

---

### 2.3 WebFetch / WebSearch

**Project use:**
- **Zero release tracking:** `WebSearch` for "vercel-labs/zero release v0.2" to detect when `world.in` and `std.fs.rename` ship — the two blockers clearing the most P1 gaps (`mcp-server`, `kv-store`, `rate-limiter`).
- **MCP spec updates:** Monitor `spec.modelcontextprotocol.io` for protocol version changes that affect the `mcp-server` design.
- **Competitor tracking:** Search for other agent-native CLI tool ecosystems (similar to the Zero primitive library concept) to identify gaps we haven't thought of yet.
- **Zero GitHub issues:** `WebFetch` the Zero GitHub issue tracker to check V34 (`world.in`) and RT-19 (`std.fs.rename`) status before starting a blocked gap.

---

### 2.4 mcp__claude_ai_Google_Drive__*

**Project use:**
- Archive design documents and eval logs to Drive for durability beyond local disk
- Store the `--describe` JSON schema for each shipped tool as a Drive doc, making them searchable by external agents
- Archive `docs/` snapshots at each checkpoint so the design history is recoverable even if `E:/HEROS/` is reset

**Auth status:** Requires authentication (`mcp__claude_ai_Google_Drive__authenticate`).

---

### 2.5 mcp__plugin_atlassian_atlassian__* / mcp__plugin_asana_asana__*

**Project use:**
- Track gap work items as Jira/Asana tickets with explicit blocker links (e.g., `mcp-server` ticket blocked by Zero v0.2 release ticket)
- Auto-create tickets when a new gap is identified during a research cycle
- Update ticket status when a gap transitions from "Blocked" to "Design" to "Implemented"

**Auth status:** Each requires `authenticate` → `complete_authentication` before first use.

---

## 3. Ecosystem Gap → Sub-agent Assignments

Each row maps one `zero-ecosystem/` gap to its primary sub-agent type, the event that re-activates its build loop, and current status as of 2026-05-24.

---

### 3.1 json-schema (`zero-ecosystem/json-schema/`)

| Field | Value |
|---|---|
| **Status** | Implemented — v0.1.8, 30/30 eval cases pass |
| **Binary** | `jsonschema_mini.0` → `jsonschema-linux-x64.bin` |
| **Primary sub-agent** | `code-reviewer` |
| **Next loop trigger** | (a) New Zero stdlib function that enables `$ref` / `oneOf` / `anyOf` — currently deferred; (b) a new red-team cycle finds a bypass in depth-2 validation |
| **Loop action** | `code-reviewer` audits `jsonschema_mini.0` for new bypass vectors; if found, `feature-dev:code-architect` designs the fix, main session implements, eval case count increments |
| **Known deferred work** | `pattern` (no stdlib regex), `$ref`/`definitions`, `oneOf`/`anyOf`/`allOf`, `additionalProperties` schema-object form, `format` keywords, depth-2 `required`, depth-2 `additionalProperties: false`, depth>2 nested |

---

### 3.2 logger (`zero-ecosystem/logger/`)

| Field | Value |
|---|---|
| **Status** | Design — v0.1.0 not yet implemented; blocker: none |
| **Binary** | `zlog_mini.0` exists as scaffold; not yet complete |
| **Primary sub-agent** | `general-purpose` (multi-step: design → build → eval in one pass) |
| **Next loop trigger** | Next available build sprint (no external blocker — this is gated only on session bandwidth) |
| **Loop action** | `general-purpose` reads `logger/README.md`, implements the write path (`std.fs.create` + rewrite pattern), implements `tail`, writes 8 eval cases (EL-01 through EL-08), runs eval, checkpoints |
| **v0.2 delta** | When `std.fs.openAppend` ships, dispatch `feature-dev:code-architect` to redesign write path from O(N) rewrite to O(1) append |

---

### 3.3 eval-harness (`zero-ecosystem/eval-harness/`)

| Field | Value |
|---|---|
| **Status** | Design — `zeval.sh` skeleton exists; not yet complete |
| **Binary** | Bash script (not a Zero binary); wraps Zero binaries |
| **Primary sub-agent** | `general-purpose` |
| **Next loop trigger** | Any existing Zero tool needs a CI-grade eval gate (immediate — `logger` and `kv-store` both need this before their eval counts are trustworthy) |
| **Loop action** | `general-purpose` reads `eval-harness/README.md`, implements the `zeval.sh` core loop using `jq` for field-subset matching, writes 5 meta-eval cases (EZ-01 through EZ-05), migrates `ledger/eval_log.md` to JSONL format as proof-of-concept |
| **Milestone** | When `zeval` ships, all future Zero tools use it as the eval gate. Manually-written `eval_log.md` files become deprecated. |

---

### 3.4 kv-store (`zero-ecosystem/kv-store/`)

| Field | Value |
|---|---|
| **Status** | Design — blocked on `std.fs.rename` (RT-19) for atomic writes |
| **Primary sub-agent** | `feature-dev:code-architect` (design now, build when unblocked) |
| **Next loop trigger** | Zero release containing `std.fs.rename` / `std.fs.delete` — check Zero GitHub RT-19 via `WebFetch` each cycle |
| **Loop action** | When unblocked: `code-architect` finalizes temp-file + rename protocol → `general-purpose` implements `zkv set/get/delete` → `code-reviewer` audits for race conditions → eval |
| **Pre-unblock work** | `feature-dev:code-architect` can design the full CLI interface and `--describe` schema now; implementation waits on RT-19 |

---

### 3.5 rate-limiter (`zero-ecosystem/rate-limiter/`)

| Field | Value |
|---|---|
| **Status** | Blocked — needs `world.in` (V34) + file-lock for shared state; bash implementation exists in `docs/rate-limit-spec.md` |
| **Primary sub-agent** | `Plan` (design the native Zero port architecture while blocked) |
| **Next loop trigger** | Zero v0.2 ships `world.in`; also triggered if `kv-store` ships (kv-store can serve as the shared state backend, removing the file-lock dependency) |
| **Loop action** | When `kv-store` is available: `Plan` produces native Zero port plan using `zkv` as state store; `general-purpose` implements `zlimit check --key --bucket --rate --window`; `code-reviewer` audits for timing attacks on the token bucket |

---

### 3.6 mcp-server (`zero-ecosystem/mcp-server/`)

| Field | Value |
|---|---|
| **Status** | Blocked — `world.in` (stdin) not available until Zero v0.2 (V34) |
| **Primary sub-agent** | `feature-dev:code-architect` (design now); `general-purpose` (build when unblocked) |
| **Next loop trigger** | Zero v0.2 release — check via `WebSearch "vercel-labs/zero v0.2"` at the start of each research cycle |
| **Loop action** | When `world.in` ships: `code-architect` finalizes the stdio message loop design from `docs/mcp-security-spec.md` → `general-purpose` implements `tools/list` + `tools/call` handlers → `agent-sdk-dev:agent-sdk-verifier-py` verifies protocol compliance → `code-reviewer` audits for injection via tool arguments |
| **Pre-unblock work** | `feature-dev:code-architect` should complete the full protocol design (message framing, error codes, tool registration schema) so implementation is a mechanical translation exercise |

---

### 3.7 http-router (`zero-ecosystem/http-router/`)

| Field | Value |
|---|---|
| **Status** | Blocked — `std.net` socket I/O not available |
| **Primary sub-agent** | `Plan` (minimal — track blocker, no design investment until `std.net` is scoped) |
| **Next loop trigger** | Zero roadmap confirms `std.net` target version; use `WebSearch` + context7 to monitor |
| **Loop action** | When `std.net` ships: `feature-dev:code-architect` designs the router shape/handler pattern → `general-purpose` implements → `agent-sdk-dev:agent-sdk-verifier-ts` tests HTTP compliance |
| **Note** | Lower priority than `mcp-server`; stdio MCP server covers the agent integration surface for v0.2 |

---

### 3.8 jwt (`zero-ecosystem/jwt/`)

| Field | Value |
|---|---|
| **Status** | Design — blocked on HMAC-SHA256; `std.crypto` currently has `hash32` + `hmac32` (32-bit) but not HMAC-SHA256 (256-bit) |
| **Primary sub-agent** | `Explore` (monitor `std.crypto` expansion each Zero release) |
| **Next loop trigger** | Zero stdlib adds `std.crypto.hmacSha256` or equivalent; also triggered when `crypto` gap ships (see 3.10) |
| **Loop action** | When HMAC-SHA256 is available: `general-purpose` implements HS256 verify path (base64url decode header+payload, recompute HMAC, constant-time compare); `code-reviewer` audits for timing side-channels |
| **Pre-unblock work** | `feature-dev:code-architect` designs the base64url decoder in pure Zero using `std.mem` and lookup tables — this is implementable now and is a dependency for both `jwt` and `crypto` |

---

### 3.9 openapi (`zero-ecosystem/openapi/`)

| Field | Value |
|---|---|
| **Status** | Design — no blocker; implementable once a Zero tool has a stable `--describe` schema |
| **Primary sub-agent** | `general-purpose` |
| **Next loop trigger** | Any Zero tool ships a stable `--describe` schema (immediate: `jsonschema` already has one) |
| **Loop action** | `general-purpose` reads `jsonschema --describe` output → implements `openapi emit --binary ./jsonschema` → outputs OpenAPI 3.1 YAML → `code-reviewer` validates against the OAS spec |
| **Value** | Enables API gateway integration for all Zero tools without any code changes to the tools themselves |

---

### 3.10 crypto (`zero-ecosystem/crypto/`)

| Field | Value |
|---|---|
| **Status** | Blocked — `std.crypto` has `hash32`, `hmac32`, `secureRandomU32`, `constantTimeEql` but not HMAC-SHA256, AES-GCM, or base64 |
| **Primary sub-agent** | `Explore` (monitor Zero stdlib; very thorough search on each release) |
| **Next loop trigger** | Zero adds any of: `std.crypto.hmacSha256`, `std.crypto.aesgcm`, `std.codec.base64` |
| **Loop action** | Incrementally implement each primitive as it becomes available; `code-reviewer` audits each for timing-safety (`std.crypto.constantTimeEql` must be used for all comparison paths); `agent-sdk-dev:agent-sdk-verifier-py` cross-validates output against Python's `hmac` / `cryptography` libraries |

---

## 4. Parallel Dispatch Model

The main session is a dispatcher. Sub-agents are workers. The pattern is: identify independent tasks → launch all in one message → collect results → synthesize → checkpoint → repeat.

### 4.1 Core dispatch rule

If task B does not require the output of task A, launch A and B in the same message. Each Agent call in a single message runs concurrently. Concurrency is free — use it.

If task B requires A's output (e.g., "implement after design is approved"), run A first, collect output, then launch B.

### 4.2 New Zero release dispatch

When a new Zero release drops (detected via `WebSearch` or `WebFetch` on the Zero GitHub releases page), dispatch all of the following in a single message:

1. **`Explore` (very thorough)** → read `docs/zero-idioms-cheatsheet.md` + all `zero-ecosystem/*/README.md` + new release notes → emit: list of stdlib symbols added/changed, list of blockers that have cleared
2. **`general-purpose`** → enumerate new MCP spec sections (if any) via context7 → emit: any new protocol requirements that affect `mcp-server` design
3. **`code-reviewer`** → audit all existing `.0` source files for broken call sites caused by changed stdlib signatures → emit: list of files needing updates before they'll compile
4. **`feature-dev:code-architect`** → for each newly-unblocked gap, produce an implementation blueprint → emit: ordered build queue

Collect all four outputs before writing any code. Synthesize: which gaps moved from Blocked to Design? Which from Design to Build-ready? Update `zero-ecosystem/README.md` in one checkpoint commit.

### 4.3 Perpetual gap loop dispatch

For each unblocked P1 gap, the loop runs as:

```
[research]   Explore (medium) → check for new stdlib that improves the gap
[design]     feature-dev:code-architect → finalize --describe schema + data structures
[build]      general-purpose → implement in Zero, write eval cases
[eval]       general-purpose → run zeval, report pass/fail
[review]     code-reviewer → security + quality pass
[checkpoint] main session → update README.md, bump version, tag
[repeat]     goto research with next sub-gap
```

When multiple gaps are unblocked simultaneously, run each gap's `[research]` phase in parallel. Do not parallelize `[build]` across gaps unless they have zero shared files — concurrent writes to the same `.0` file cause merge conflicts.

### 4.4 Red-team cycle dispatch

At the start of each red-team cycle (currently cycle 150+), dispatch:

1. **`code-reviewer`** → audit all shipped binaries for the red-team checklist (path traversal, input length overflow, escape sequence bypass, timing side-channels)
2. **`Explore` (very thorough)** → search all `.0` source files for patterns matching known Zero sharp edges (unchecked `std.args.get` without `.has` guard, arrays initialized without `[0, ...]`, `raise` without `raises` declaration)
3. **`feature-dev:code-explorer`** → trace execution paths through `jsonschema_mini.0` to find branches unreachable by the current 30 eval cases

Collect all three before writing any fixes. Triage findings by severity (P1 = bypass, P2 = crash, P3 = silent wrong output, P4 = cosmetic). Fix P1 and P2 in the same cycle. Defer P3/P4 to next cycle with a new eval case added as a regression guard.

### 4.5 Background dispatch for long research

Use `run_in_background=true` for Agent calls that are slow and whose results are not needed immediately:

- Context7 doc fetches (can be slow; fire and continue with local work)
- WebSearch for Zero release monitoring (fire at session start; check result before first build step)
- Full codebase audit scans (very thorough Explore; fire while writing a design doc)

Do not use `run_in_background` when the result is needed to decide the next step. Use it only when you have other meaningful work to do while waiting.

---

## 5. Session Startup Checklist

Run these in parallel at the start of every session:

```
1. Explore (quick)       → check zero-ecosystem/README.md for current gap statuses
2. WebSearch             → "vercel-labs/zero" latest release — has v0.2 shipped?
3. context7 query-docs   → Zero stdlib — any new symbols since last session?
4. Explore (medium)      → scan E:/HEROS/ for any uncommitted work from last session
```

Only after collecting all four results: decide which gap loop to activate, which blockers have cleared, and whether the cheatsheet at `docs/zero-idioms-cheatsheet.md` needs updating.

---

## 6. Gap Priority Queue (as of 2026-05-24)

Ordered by: (unblocked AND high value) first, then (unblocked, lower value), then (blocked, monitor).

| Priority | Gap | Status | Blocking on | Next action |
|---|---|---|---|---|
| 1 | eval-harness | Design, no blocker | Session bandwidth | Implement `zeval.sh`; 5 meta-eval cases |
| 2 | logger | Design, no blocker | Session bandwidth | Implement `zlog`; 8 eval cases |
| 3 | openapi | Design, no blocker | Stable `--describe` exists | Implement emitter for `jsonschema` |
| 4 | json-schema v0.2 | Deferred features | Zero stdlib regex | Monitor; `code-reviewer` on next red-team cycle |
| 5 | kv-store | Design, blocked | `std.fs.rename` (RT-19) | Finalize CLI design; build when unblocked |
| 6 | mcp-server | Blocked | `world.in` (V34) | Finalize protocol design now; build on Zero v0.2 |
| 7 | rate-limiter | Blocked | `world.in` + file-lock OR `kv-store` | Unblocked when `kv-store` ships |
| 8 | jwt | Blocked | HMAC-SHA256 in stdlib | Pre-build base64url decoder now |
| 9 | openapi | Design | — | After `logger` + `eval-harness` |
| 10 | http-router | Blocked | `std.net` (no roadmap date) | Monitor only |
| 11 | crypto | Blocked | `std.crypto` expansion | Monitor; implement each primitive as it lands |
