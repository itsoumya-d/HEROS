# Concept Gate — Three Category-Rebuild Proposals

**Status:** AWAITING PICK  
**Date:** 2026-05-24  
**Zero version:** v0.1.3  
**Evaluator:** Internal — YC RFS "Software for Agents" criteria  

This document proposes three category-rebuilds for the "Build Something Agents Want — in Zero" mission. Each is a defensible startup, not a utility. After review, pick one. The perpetual loop begins on the picked category.

---

## How to read this

Each proposal answers eight questions:

1. **Pitch + category** — what category does this rebuild, and what is the one-sentence pitch?
2. **Why incumbents can't ship it** — structural reason, not execution gap
3. **Why Zero, not Go/Rust/TS** — genuine technical moat, not "we already chose Zero"
4. **Agent-facing surface** — exact CLI commands + MCP tool names
5. **Discovery + signup** — how a cold agent learns and provisions, with zero human in the loop
6. **Agent-native economics** — how agents pay, budget, and meter usage
7. **Swarm primitives needed** — gaps in zero-ecosystem/ that must close first
8. **YC RFS score** — 1–5 per criterion, 40 points max

---

## Proposal A: Agent Identity Network (auth.0)

### Pitch + category

**Category:** Identity and Access Management (IAM)  
**Incumbents:** Auth0, Okta, AWS IAM, HashiCorp Vault  

**Pitch:** The IAM primitive where every credential is self-provisioned, every revocation is instant, and the entire lifecycle — provision, rotate, audit, revoke — is driven by machine-readable JSON verbs with no browser, no redirect, and no approval queue.

### Why incumbents can't ship it

Every existing IAM system has a human at the center of its auth model:

- **OAuth 2.0** was designed for human consent (the redirect is the feature, not the bug)
- **Auth0 / Okta** offer API keys but provisioning requires a human to log into a dashboard
- **AWS IAM** roles require a CloudFormation template or console click to create; there is no `aws iam create-key --scope read:s3 --ttl 3600` that outputs a usable credential in one call
- **HashiCorp Vault** is the closest — dynamic secrets are good — but Vault requires operator-provisioned policies; an agent cannot define its own scope constraints without a human pre-configuring a policy template
- **API keys in every SaaS product** are static, org-scoped, and rotated by humans clicking "regenerate"

The structural gap: **no IAM system treats agent-provisioned, agent-scoped, agent-audited credentials as a first-class primitive.** Every system assumes a human configured the permission model.

### Why Zero, not Go/Rust/TS

- **HMAC-SHA256 is pure computation.** Zero's `std.crypto` already has `hmac32`; a full HMAC-SHA256 path is the next gap. A Zero binary can sign and verify tokens with zero runtime — no OpenSSL, no libsodium, no node_modules
- **Binary footprint under 20 KiB.** An agent sandboxed in a Lambda or container can bundle `auth` without a package manager
- **Stateless binary model exactly matches credential verification.** `auth verify --token <t>` is pure: input → output, no persistent connection, safe to call from any context
- **Stable, versioned JSON interface.** `schema_version` in every response means agents detect contract changes without parsing version strings. Go/Rust CLIs typically don't carry schema version metadata

### Agent-facing surface

```
auth provision --scope <scope> --ttl <seconds> [--idempotency-key <k>]
  → {"token":"heros_rw_<id>_<secret>","expires_at":N,"scope":"<scope>","_idempotent":false}

auth verify --token <t> --scope <required-scope>
  → {"valid":true,"principal":"agent_<id>","scope":"rw","expires_at":N}
  → {"valid":false,"error_code":"TOKEN_EXPIRED","retryable":true}

auth rotate --token <t> [--idempotency-key <k>]
  → {"token":"heros_rw_<new-id>_<new-secret>","expires_at":N,"previous_token_revoked":true}

auth revoke --token <t>
  → {"status":"ok","revoked_at":N}

auth audit --scope <scope> --limit <n>
  → JSONL: {"event":"provision","token_id":"<id>","ts":N,"scope":"rw"}\n...

auth --version → {"tool":"auth","version":"0.1.0","schema_version":1}
auth --describe → full capability + error_codes + signup flow JSON
```

**MCP tool names:** `auth_provision`, `auth_verify`, `auth_rotate`, `auth_revoke`, `auth_audit`

### Discovery + signup

A cold agent with no credentials:

```
agent → auth --describe
      ← {"tool":"auth","commands":[...],"signup":{"method":"auth_provision",
         "available_scopes":["read","write","admin"],"ttl_max":86400,
         "note":"Call auth_provision with your required scope. No human approval required."}}

agent → auth provision --scope write --ttl 3600 --idempotency-key agent-cold-start-01
      ← {"token":"heros_rw_4a2f8c1e...","expires_at":1716600000,"scope":"write","_idempotent":false}
```

No email. No redirect. No CAPTCHA. The agent now has a scoped, expiring credential that it can use for every subsequent HEROS tool call.

### Agent-native economics

- **Provision**: metered (100/hour per org)
- **Verify**: free (verification is the hot path; throttling verify would break agents)
- **Rotate / Revoke**: metered but cheap (10/hour per org)
- **Audit**: metered (20 calls/hour, 1000 events per call)
- Every response carries `_rate_limit.remaining`, `_rate_limit.reset_at`, `_rate_limit.limit`
- Agents read `_rate_limit.remaining` proactively before provisioning in bulk

### Swarm primitives needed

| Primitive | Gap | Status | Blocker |
|---|---|---|---|
| HMAC-SHA256 | `zero-ecosystem/crypto/` | Blocked | `std.crypto.hmacSha256` (Zero v0.2) |
| Atomic token storage | `zero-ecosystem/kv-store/` | Design | `std.fs.rename` (Zero v0.2) |
| Audit log append | `zero-ecosystem/logger/` | Implemented v0.1.0 | None |
| Revocation scan | Bridge (bash) | Ready | None |

For v0.1.x: HMAC-SHA256 is handled via `openssl dgst -hmac` in the bridge (same pattern as entropy generation). The binary validates token format and scope; the bridge signs and verifies. Atomic storage via temp+rename in bash (same pattern as RT-19 workaround). Native Zero crypto unblocks the full migration in v0.2.

### YC RFS Score

| Criterion | Score | Notes |
|---|---|---|
| Agent-native output | 5/5 | Every code path → JSON. Token format is machine-parseable (prefixed) |
| Zero ambiguity | 5/5 | `TOKEN_EXPIRED`, `INVALID_SCOPE`, `REVOKED`, `PROVISION_LIMIT_EXCEEDED` — stable codes, `retryable` boolean |
| Discovery | 5/5 | `--describe` + inline `signup` block; cold agent learns and provisions in 2 calls |
| No human-in-loop | 5/5 | Self-provisioning; no dashboard, no email, no consent screen |
| Idempotent/retryable | 5/5 | `--idempotency-key` on provision and rotate; verify is pure read |
| Risk-first | 4/5 | Scope validation, revocation, TTL expiry; no breaker-circuit on suspicious volume yet |
| Minimal surface | 4/5 | 5 commands; auth is inherently stateful — the surface reflects real complexity |
| Composable | 5/5 | MCP transport; forge + ledger verify incoming tokens via `auth_verify` before executing |
| **Total** | **38/40** | |

---

## Proposal B: Agent Task Coordination Network (queue.0)

### Pitch + category

**Category:** Distributed task queues and job coordination  
**Incumbents:** Celery/Redis, BullMQ/Redis, AWS SQS, RabbitMQ, Temporal  

**Pitch:** The task queue where the consumer is a stateless agent sub-process, not a long-running worker — every queue operation is a single CLI invocation, every failure is a structured JSON event, and an orchestrating agent can inspect, retry, and route work across a swarm without a message broker.

### Why incumbents can't ship it

Every existing queue assumes a **persistent connection** from a worker:

- **Celery** uses AMQP/Redis pub/sub — workers register, consume messages in a loop, heartbeat to prove liveness. An LLM agent sub-process cannot hold a socket between tool calls
- **BullMQ** requires Node.js workers with Redis connections. No CLI, no JSON output, no sub-process model
- **AWS SQS** is the closest — polling via CLI is possible. But: message bodies are opaque strings, no structured task type routing, no claim-token semantics, no failure classification with `retryable` flags
- **Temporal** requires Go/Java/Python workers + a running Temporal cluster. Startup cost for an agent swarm is enormous
- **None** of the above let an orchestrating agent ask "what tasks are queued for type `schema_analysis`?" and get a machine-readable answer it can act on without parsing text

The structural gap: **queues were designed for persistent workers, not stateless agent sub-processes.** When a sub-agent claims a task and then gets terminated (rate limit, timeout, context overflow), the queue doesn't know — the claim just expires, but the failure event is unstructured.

### Why Zero, not Go/Rust/TS

- **The stateless binary model is the feature.** Zero's "args in, JSON out, exit" perfectly matches agent task consumption: `queue claim --type analyze-schema` returns a task and exits. The agent processes it, then calls `queue complete --claim-id <id>`. No persistent connection required
- **Bridge-managed state = zero infra.** Queue state lives in a JSONL file the bridge manages. No Redis, no RabbitMQ, no broker to run. An agent can spin up a queue in any directory with no setup
- **Claim-token semantics fit claim-timeout patterns.** Every claim has an `expires_at`; the bridge marks expired claims as available again on the next `queue claim` call. Pure file operations, no daemon
- **Tiny footprint.** The queue binary validates claim logic, generates IDs, classifies failures. The bridge owns the JSONL state. Combined binary <15 KiB

### Agent-facing surface

```
queue push --type <task-type> --payload '<json>' [--priority high|normal|low]
           [--idempotency-key <k>]
  → {"task_id":"tsk_abc12345","status":"queued","position":3,"_idempotent":false}

queue claim --type <task-type> [--claim-ttl <seconds>]
  → {"task_id":"tsk_abc12345","payload":{...},"claim_id":"clm_xyz","expires_at":N}
  → {"status":"empty","retryable":true}  (no tasks of this type)

queue complete --claim-id <id> --result '<json>'
  → {"status":"ok","task_id":"tsk_abc12345","duration_ms":N}

queue fail --claim-id <id> --error '{"code":"SCHEMA_PARSE_FAILED","retryable":true}'
  → {"status":"ok","task_id":"tsk_abc12345","retry_count":2,"next_attempt_at":N}
  → {"status":"ok","task_id":"tsk_abc12345","retry_count":3,"exhausted":true}

queue inspect --task-id <id>
  → {"task_id":"...","status":"claimed","attempts":2,"last_error":{...},"claim_expires_at":N}

queue list --type <task-type> --status queued|claimed|complete|failed [--limit 50]
  → JSONL stream of task summaries

queue types list
  → {"types":["analyze-schema","create-invoice","validate-migration"],"status":"ok"}

queue --version → {"tool":"queue","version":"0.1.0","schema_version":1}
queue --describe → full capability + error_codes + signup flow JSON
```

**MCP tool names:** `queue_push`, `queue_claim`, `queue_complete`, `queue_fail`, `queue_inspect`, `queue_list`, `queue_types_list`

### Discovery + signup

```
agent → queue --describe
      ← {"tool":"queue","commands":[...],"signup":{"method":"queue_provision",
         "note":"Call queue_provision with your org_id to create an isolated task namespace.",
         "requires":"auth_provision scope:write"}}

agent → queue provision --org-id org_abc12345
      ← {"namespace":"ns_abc12345","status":"ok","quota":{"max_tasks":10000,"max_types":50}}
```

A cold agent orchestrator:
1. Calls `queue --describe` to learn the API
2. Provisions a namespace (scoped to its org, isolated from other orgs)
3. Pushes tasks for its sub-agents to claim
4. Sub-agents call `queue claim --type <n>` on each invocation to get work
5. On completion or failure, sub-agents report back via `queue complete` / `queue fail`
6. Orchestrator inspects via `queue list` — all JSON, no dashboard

### Agent-native economics

- **Push**: metered (1000 pushes/hour per org)
- **Claim + complete + fail**: free (the hot path; penalizing these creates perverse incentives)
- **List + inspect**: metered but cheap (100 calls/hour)
- **Retry logic**: automatic up to 3 retries for `retryable:true` failures; subsequent failures require explicit `queue push` from orchestrator
- `_rate_limit` in every response; `RATE_LIMITED` with `retry_after_seconds` when push quota exhausted

### Swarm primitives needed

| Primitive | Gap | Status | Blocker |
|---|---|---|---|
| JSONL append (task file) | Bridge (bash) | Ready | None |
| Claim-token generation | Bridge entropy | Ready | `/dev/urandom` available |
| TTL/expiry scan | Bridge (bash, on each claim) | Ready | None |
| Atomic task state update | `zero-ecosystem/kv-store/` | Design | `std.fs.rename` (Zero v0.2) |
| Namespace isolation | Bridge (per-namespace JSONL) | Ready | None |

**v0.1.x viability:** Higher than auth.0. Queue state fits naturally in a bridge-managed JSONL file (same pattern as `.ledger-invoices`). Claim tokens are entropy-generated by the bridge. TTL expiry is a `date +%s` comparison in bash. The binary validates claim logic and generates structured errors. No Zero v0.2 features required for a functional v0.1 — atomic state update is the only v0.2 improvement.

### YC RFS Score

| Criterion | Score | Notes |
|---|---|---|
| Agent-native output | 5/5 | Every code path → JSON or JSONL. `"status":"empty"` is a machine signal, not a human message |
| Zero ambiguity | 5/5 | `CLAIM_EXPIRED`, `TASK_NOT_FOUND`, `ALREADY_COMPLETE`, `RETRY_EXHAUSTED`, `UNKNOWN_TYPE` — stable codes, `retryable` boolean on every error |
| Discovery | 5/5 | `--describe` + `queue types list` + inline `signup` block |
| No human-in-loop | 5/5 | Self-provisioning namespace; no broker to configure; no dashboard |
| Idempotent/retryable | 5/5 | `--idempotency-key` on push; claim is naturally retry-safe (claim token is unique per attempt); complete/fail are idempotent |
| Risk-first | 5/5 | `retry_count`, `exhausted`, `next_attempt_at` give orchestrators full visibility. `retryable` on failure errors lets sub-agents signal upstream |
| Minimal surface | 5/5 | 7 commands covering the full lifecycle; task type routing adds zero config overhead |
| Composable | 5/5 | MCP transport; forge pushes schema-analysis tasks; ledger pushes invoice-reconciliation tasks; queue.0 is the coordination layer across all HEROS tools |
| **Total** | **40/40** | |

---

## Proposal C: Agent Schema Registry (schema.0)

### Pitch + category

**Category:** API contract management and schema validation  
**Incumbents:** Confluent Schema Registry, Buf.build, SmithyAPI, OpenAPI Hub  

**Pitch:** The schema registry where agents register their tool call formats, validate inputs before invoking tools, detect breaking changes before deploying them, and discover compatible APIs — all via content-addressed JSON verbs with no git workflow, no web UI, and no CI pipeline.

### Why incumbents can't ship it

- **Confluent Schema Registry** was designed for Avro/Protobuf evolution in Kafka pipelines. It has no concept of "validate this JSON against schema version 3 before I call the tool"
- **Buf.build** requires a git repository, a BSR account, and developer-operated `buf push` — none of which an agent can drive
- **SmithyAPI** generates client SDKs from a model definition. Agents don't need SDKs; they need "is this call valid?" in one command
- **OpenAPI Hub / Swagger** stores spec files; it does not validate arbitrary inputs against them and return structured errors
- **JSON Schema validators** (Ajv, jsonschema) exist as libraries but not as agent-callable services with content-addressing, versioning, and diff

The structural gap: **no schema registry was designed for agents to self-register formats and validate their own tool calls before making them.** Every registry assumes a developer chose the schema; agents need to discover schemas, validate against them, and detect drift in the wild.

### Why Zero, not Go/Rust/TS

- **forge already proved the approach.** Zero's schema diff engine (dual-hash dedup, name-aware column diff) is the heart of a schema registry. schema.0 extends it from SQL columns to arbitrary JSON shapes
- **zero-ecosystem/json-schema v0.1.0 is already implemented.** The JSON Schema draft-07 validator written in Zero is the engine; schema.0 is the registry semantics on top
- **Content-addressing uses `std.crypto.hash32`.** Schema IDs are `sch_<djb2+sdbm hash of canonical JSON>`. Same schema → same ID, forever. No coordination required
- **Pure computation.** `schema validate` is a local operation — no network call, no schema server, instant. An agent can validate 100 tool calls in the same pipeline step

### Agent-facing surface

```
schema register --name <n> [--version <v>] --schema '<json-schema>'
                [--idempotency-key <k>]
  → {"schema_id":"sch_a1b2c3d4","name":"invoice_create","version":1,"status":"ok","_idempotent":false}

schema validate --name <n> [--version <v>] --input '<json>'
  → {"valid":true}
  → {"valid":false,"errors":[{"path":"$.amount","code":"TYPE_MISMATCH",
     "expected":"string","got":"number","retryable":true}]}

schema diff --name <n> --from <version> --to <version>
  → {"breaking":true,"changes":[{"field":"$.currency","change":"added_required",
     "risk":"BREAKING","agent_guidance":"Calls not providing currency will fail validation"}]}

schema get --name <n> [--version <v>]
  → {"schema_id":"sch_a1b2c3d4","name":"invoice_create","version":1,"schema":{...}}

schema list [--name <n>]
  → JSONL: {"schema_id":"sch_a1b2c3d4","name":"invoice_create","versions":[1,2,3]}\n...

schema --version → {"tool":"schema","version":"0.1.0","schema_version":1}
schema --describe → full capability + error_codes + signup flow JSON
```

**MCP tool names:** `schema_register`, `schema_validate`, `schema_diff`, `schema_get`, `schema_list`

### Discovery + signup

```
agent → schema --describe
      ← {"tool":"schema","commands":[...],"signup":{"method":"schema_register",
         "note":"Register your first schema. No account required. Schema IDs are content-addressed.",
         "example":{"name":"my_tool_call","schema":{"type":"object","required":["id"],...}}}}

agent → schema register --name invoice_create --schema '{"type":"object","required":["to","amount"],...}'
      ← {"schema_id":"sch_4f3a2b1c","name":"invoice_create","version":1,"status":"ok"}
```

An agent that discovers a new tool:
1. Calls `schema get --name <tool_name>` to find if a schema exists
2. If exists: calls `schema validate --name <tool_name> --input '<my-call>'` before invoking
3. If not: calls `schema register` to publish its own format for others to use
4. On schema update: `schema diff --from <old> --to <new>` detects breaking changes before rolling out

### Agent-native economics

- **Register**: free (creates public goods; encourages ecosystem growth)
- **Validate**: metered (10,000/hour per org — the hot path must be fast and available)
- **Diff**: metered (100/hour — a planning operation, not the hot path)
- **List + get**: free
- Content-addressing means registering the same schema twice costs nothing (idempotent by design)

### Swarm primitives needed

| Primitive | Gap | Status | Blocker |
|---|---|---|---|
| JSON Schema validator | `zero-ecosystem/json-schema/` | **Implemented v0.1.0** | None |
| Schema storage (JSONL) | Bridge (bash) | Ready | None |
| Content hash (schema ID) | `std.crypto.hash32` | Available now | None |
| Schema diff engine | forge `forge_mini.0` logic | Available | Port to schema.0 |
| Versioned KV storage | `zero-ecosystem/kv-store/` | Design | `std.fs.rename` (v0.2) |

**v0.1.x viability:** Highest of the three proposals. json-schema is already implemented. Content hashing is already available. Schema storage is JSONL (same pattern as ledger invoices). The diff engine ports directly from forge. This could ship a functional v0.1.0 in one cycle.

### YC RFS Score

| Criterion | Score | Notes |
|---|---|---|
| Agent-native output | 5/5 | Every code path → JSON or JSONL. Validation errors are structured paths, not prose |
| Zero ambiguity | 5/5 | `SCHEMA_NOT_FOUND`, `VALIDATION_FAILED`, `BREAKING_CHANGE`, `VERSION_EXISTS`, `INCOMPATIBLE_SCHEMA` — stable codes |
| Discovery | 5/5 | `--describe` + content-addressed IDs + inline `signup` block; `schema list` discovers the entire registry |
| No human-in-loop | 5/5 | Self-service registration; content-addressing means no name collision approvals |
| Idempotent/retryable | 5/5 | Content-addressed = naturally idempotent; validate is pure read; diff is pure read |
| Risk-first | 5/5 | `breaking` flag + per-change `risk` tier + `agent_guidance` mirrors forge's design; agents halt before deploying breaking changes |
| Minimal surface | 5/5 | 5 commands; schema format is JSON Schema draft-07 (existing standard, no learning curve) |
| Composable | 5/5 | MCP transport; forge validates migrations against schema.0; ledger validates invoice fields against schema.0; auth validates scope claims against schema.0 |
| **Total** | **40/40** | |

---

## Comparison

| | auth.0 | queue.0 | schema.0 |
|---|---|---|---|
| Category | IAM | Job queues | API contracts |
| RFS score | 38/40 | 40/40 | 40/40 |
| v0.1.x viability | Medium (HMAC needs bridge workaround) | High (pure JSONL + entropy) | Highest (json-schema already done) |
| Unmet need | High (every HEROS tool needs auth) | Highest (swarms have no coordination layer) | Medium (agents work around it today) |
| Ecosystem flywheel | Medium (credential for other tools) | High (forge + ledger become producers; queue.0 is coordination layer) | Medium (validation for other tools' schemas) |
| Incumbent gap | Strong (all IAM assumes human consent) | Strongest (all queues assume persistent worker) | Strong (all registries assume developer workflow) |
| Time to v0.1.0 | 2 cycles (HMAC bridge workaround needed) | 1 cycle (no blockers) | 1 cycle (json-schema done, port forge diff) |

---

## Recommendation

**Pick queue.0.**

Rationale:

**1. Highest unmet need.** The moment you have two agent processes, you have a coordination problem. forge and ledger are tools; queue.0 is the infrastructure that lets an agent orchestrate 10 instances of forge and 10 instances of ledger without race conditions. There is no equivalent primitive in the LLM ecosystem today.

**2. Strongest incumbent gap.** Every existing queue assumes a persistent worker. This is not a design oversight — it is a fundamental architectural decision that makes all existing queues wrong for the agent-swarm use case. This is a category rebuild, not a feature improvement.

**3. Largest ecosystem flywheel.** queue.0 turns forge and ledger from standalone tools into coordination targets. An orchestrating agent pushes `{"type":"analyze-schema","payload":{"from":"...","to":"..."}}` tasks; worker agents claim and execute them. The value of the entire HEROS platform compounds when work can be distributed.

**4. Best Zero fit.** The "stateless binary per operation" model is not a Zero limitation — it is the queue.0 design. Every queue operation is a discrete CLI invocation. This is the rare case where Zero's v0.1.x constraints (no persistent connections, no stdin streaming) are exactly the right model.

**5. Lowest blocker count.** schema.0 is also fast to ship, but schema validation without a running registry is table stakes — agents can already use the zero-ecosystem json-schema binary directly. queue.0 fills a gap nothing else fills.

auth.0 is a prerequisite for production deployments (every HEROS tool needs credential validation) and should be built second. schema.0 is third.

---

## Next step

**Pick one of A (auth.0), B (queue.0), or C (schema.0).**

On pick: the perpetual loop begins.

Loop step 1 (research delta): check Zero v0.1.3 for any stdlib that reduces the v0.1.x workarounds for the chosen category. Check MCP spec 2025-11-25 for transport primitives that affect the design.

Loop step 2: design the `--describe` schema for the picked tool (every command, flag, return field, error code).

Loop step 3: build `<pick>_mini.0` + `mcp-bridge.sh` + `mcp-manifest.json`.

Loop step 4: eval — fresh agent completes a multi-step task using only `--describe`.

Loop step 5: checkpoint — update eval log, YC RFS scorecard, zero-ecosystem gap index. Goto 1.
