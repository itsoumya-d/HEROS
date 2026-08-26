# Agent Audit Trails: What the 2026 Governance Stack Expects (and Where HEROS Fits)

*Research note — R&D loop run 4 (2026-08-26). Sources cited inline; all external claims belong to their sources.*

## Why this note exists

HEROS's core thesis — explicit actions, receipts, idempotency keys, append-only ledgers — is exactly the raw material that "agent governance" products are now being built to sell. This note surveys what the 2026 governance/audit ecosystem expects from an audit trail, and maps each expectation onto what HEROS already emits vs. what's queued.

## What the ecosystem expects from an agent audit trail

1. **Step-level, not endpoint-level evidence.** Openlayer's June 2026 governance guide argues agents require *step-level* governance because failures compound across chained tool calls; it lists a decision-chain log with timestamp, model version hash, tool invocations, and intermediate outputs per step as EU AI Act Article 12-style evidence ([openlayer.com/blog/ai-agent-governance-guide](https://www.openlayer.com/blog/ai-agent-governance-guide)).
2. **The enforcement decision is the record.** PredictionGuard frames runtime policy enforcement as a control plane whose log must capture: input, which policy applied, the decision (allow / block / rewrite), and the output — ISO/IEC 42001 A.6.2.8 asks for replayable event logs of prompts, tool invocations, outputs, and affected resources across the lifecycle ([predictionguard.com/blog/runtime-ai-policy-enforcement](https://predictionguard.com/blog/runtime-ai-policy-enforcement)). A log without a recorded *decision* is diagnostic, not evidentiary.
3. **Gateway-centralized trails.** MCP/agent gateway vendors (e.g. MintMCP) position unified audit trails across all governed tool connections as the deployment pattern — per-app configuration doesn't survive contact with real orgs ([mintmcp.com/blog/ai-guardrails-tools-platforms](https://www.mintmcp.com/blog/ai-guardrails-tools-platforms)). Guardrails support AI Act risk-management programs but don't by themselves establish compliance with human-oversight/documentation obligations.
4. **Agentic risk = autonomous action.** Domino's composable-guardrails blueprint anchors on the OWASP Top 10 for Agentic Applications: goal hijacking, indirect prompt injection (including via MCP tool descriptions), tool misuse with hallucinated arguments, exfiltration via tool calls, scope creep ([domino.ai/resources/blueprints/composable-guardrails-for-agentic-ai](https://domino.ai/resources/blueprints/composable-guardrails-for-agentic-ai)). The audit trail is the post-hoc detection surface for all of these.

## Mapping onto HEROS

| Ecosystem expectation | HEROS today | Gap / queued idea |
|---|---|---|
| Per-step tool invocation record | `@heros/agentic` action registry + execute endpoint; explicit named actions | Emit a structured receipt per action invocation (action name, schema version, principal, decision, result digest) |
| Decision record (allow/block) | Auth gate (`authorize` callback), risk gate in forge | The authorize/risk *decision itself* isn't currently part of any emitted receipt — add `decision: allow\|deny\|rewrite` + policy id to receipts |
| Idempotency / replay safety | Idempotency keys on ledger invoices, idempotent annotations | Replay-detection events (duplicate key seen → rejected) should also be receipted; they're evidence the control worked |
| Append-only, tamper-evident log | Ledger v2 spec scopes full audit JSONL to v0.3+ (`docs/ledger-v2-spec.md`) | Hash-chain receipts (each receipt includes prev-hash) — cheap, aligns with CertiFlow's evidence-hash approach |
| Centralized gateway trail | N/A (HEROS is a toolkit, not a gateway) | Positioning honesty: HEROS produces the *per-action evidence* a gateway or GRC product consumes; say so in docs rather than implying gateway coverage |
| Model/tool provenance hashes | Not present | Optional `provenance` block on receipts (tool/package version hash) mirrors Openlayer's "model version hash" field |

## Takeaway

The 2026 market has converged on a vocabulary — decision records, replayable traces, tamper-evidence, gateway centralization. HEROS's receipts and idempotency primitives already speak half of it; the cheapest high-leverage move is making the *authorization decision* a first-class field on every receipt, so each action is self-contained audit evidence rather than requiring reconstruction from app logs.
