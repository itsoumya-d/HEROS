# Fleet Evaluation — forge v0.1.3
**Cycle:** 11 | **Date:** 2026-05-18 | **Evaluator:** agent-sim | **Round:** 2 (first round was v0.1.2)

---

## Overview

Five agent archetypes exercised against `forge` v0.1.3. The tool is an agent-native database schema migration analyzer (Zero lang, ~7 KB musl-x64). All output is JSON. This document records what each agent did, what forge returned, what v0.1.2 would have returned instead, and whether the v0.1.3 behavior is correct.

**Key change in v0.1.3:** Column diff now uses hash-set comparison seeded by table name, replacing the count-based comparison from v0.1.2. This closes the false-SAFE vulnerability where a column rename within a preserved table would be misclassified as no-change because the count before and after was identical.

**Schema notation used throughout:** `|` is the line separator. Schema strings are passed to `--from` and `--to`.

---

## Agent 1 — GPT-4-class (reads `--describe` first)

**Model class:** GPT-4-tier, tool-calling, structured output. Reads forge's self-description before issuing any analyze command.

**Task:** Detect whether renaming column `email` to `email_address` within a preserved `users` table is safe to apply.

**Trace:**

```
> forge --describe
<- {
     "commands": ["analyze"],
     "flags": {
       "--from": "schema string, pipe-separated TABLE/COLUMN declarations",
       "--to":   "schema string, pipe-separated TABLE/COLUMN declarations"
     },
     "output_format": "json",
     "risk_tiers": ["SAFE", "NOTABLE", "CRITICAL"],
     "version": "0.1.3"
   }

> forge analyze \
    --from "TABLE users|COLUMN id|COLUMN email|COLUMN created_at" \
    --to   "TABLE users|COLUMN id|COLUMN email_address|COLUMN created_at"
<- {
     "schema_version": 1,
     "risk_tier": "CRITICAL",
     "risk_score": 1.0,
     "retryable": false,
     "has_data_loss": true,
     "decision_required": true,
     "operations": [
       {"op": "drop_column", "table": "users", "column": "email"},
       {"op": "add_column",  "table": "users", "column": "email_address"}
     ]
   }
```

**What v0.1.2 would have returned:**

Under count-based column diff, v0.1.2 sees 3 columns before and 3 columns after. Net delta = 0. No column operations emitted. Result:

```json
{
  "schema_version": 1,
  "risk_tier": "SAFE",
  "risk_score": 0.0,
  "retryable": true,
  "has_data_loss": false,
  "decision_required": false,
  "operations": []
}
```

This is a false-SAFE. An agent acting on this output would apply the migration assuming zero risk, silently dropping the `email` column and creating data loss.

**v0.1.3 behavior:** PASS. The table-seeded hash for `users.email` differs from the hash for `users.email_address`. Both appear in exactly one schema, so both are emitted as operations. `decision_required: true` forces the agent to gate on human or policy approval.

**Agent behavior after correct output:** GPT-4-class agent reads `decision_required: true`, pauses migration pipeline, surfaces the two operations (`drop_column users.email` + `add_column users.email_address`) to the operator. Correct escalation.

**Friction:** None. `--describe` surfaces the flag names and separator convention cleanly. Agent constructs the correct command on the first attempt.

**Time-to-first-success:** 2 round-trips (describe → analyze).

**Error recovery:** N/A — no errors encountered.

**Residual friction points:** The `--describe` output does not document what constitutes a "column rename" vs. independent add/drop. An agent that wants to confirm whether forge treats a rename as atomic (vs. two separate ops) must infer this from the operations list. A `"rename_detection": false` flag in `--describe` would clarify that forge never infers intent — it only reports structural diff.

**Score:** Discovery 10 | Schema Construction 10 | Risk Classification 10 | Error Recovery N/A

---

## Agent 2 — Minimal Scripted Agent (no `--describe`)

**Model class:** Shell script or Python wrapper. Flags hardcoded from developer notes written against v0.1.2 docs. Does not call `--describe` before use.

**Task:** Check whether adding a new `profile_picture_url` column to an existing `users` table is safe.

**Trace:**

```
# Script hardcodes flag names from v0.1.2 notes.
# Developer notes had an older flag style: --schema-from / --schema-to
# (hypothetical drift scenario — same test as cycle 9 Agent 2 pattern)

> forge analyze --schema-from "TABLE users|COLUMN id|COLUMN name" \
                --schema-to   "TABLE users|COLUMN id|COLUMN name|COLUMN profile_picture_url"
<- {"error": "UNKNOWN_FLAG", "flag": "--schema-from", "hint": "use --from", "retryable": false}
```

**Script reads error, corrects flag name:**

```
> forge analyze \
    --from "TABLE users|COLUMN id|COLUMN name" \
    --to   "TABLE users|COLUMN id|COLUMN name|COLUMN profile_picture_url"
<- {
     "schema_version": 1,
     "risk_tier": "NOTABLE",
     "risk_score": 0.25,
     "retryable": true,
     "has_data_loss": false,
     "decision_required": false,
     "operations": [
       {"op": "add_column", "table": "users", "column": "profile_picture_url"}
     ]
   }
```

**What v0.1.2 would have returned:** Identical output for this specific case (pure column addition has no rename ambiguity, so count-based and hash-based diff agree). v0.1.2 regression does not apply here.

**v0.1.3 behavior:** PASS. `add_column` is correctly detected as NOTABLE (additive, no data loss). The `UNKNOWN_FLAG` error with the correct flag name in the `hint` field enables self-correction in one extra round-trip.

**Agent behavior:** Script reads `"hint": "use --from"` from the error payload, rewrites the flag, retries. Succeeds without human intervention.

**Friction:** The script would have been stuck permanently if the error returned only `"error": "INVALID_INPUT"` without naming the offending flag and providing the correct alternative. The `hint` field is load-bearing for scriptable self-correction.

**Residual friction points:** Script has no handling for schema strings that exceed any length limit forge may impose. If the schema has 200 columns, the script does not know whether to chunk the input or whether forge accepts arbitrarily long strings. A `"max_schema_length"` field in the error or in `--describe` would prevent silent truncation bugs.

**Time-to-first-success:** 3 round-trips (failed call + correction + success).

**Score:** Discovery 2 | Schema Construction 6 | Risk Classification 10 | Error Recovery 8

---

## Agent 3 — Adversarial Schema Agent

**Model class:** LLM agent or automated CI hook. Passes a schema change that is designed to look semantically benign — a security-adjacent column rename that a human reviewer might wave through — but which forge must still flag as CRITICAL.

**Task:** Rename column `password_hash` to `password_hash_bcrypt` within a preserved `accounts` table. Verify forge does not infer semantic intent ("still sounds like a hash field") and correctly reports CRITICAL.

**Trace:**

```
> forge analyze \
    --from "TABLE accounts|COLUMN id|COLUMN username|COLUMN password_hash|COLUMN created_at" \
    --to   "TABLE accounts|COLUMN id|COLUMN username|COLUMN password_hash_bcrypt|COLUMN created_at"
<- {
     "schema_version": 1,
     "risk_tier": "CRITICAL",
     "risk_score": 1.0,
     "retryable": false,
     "has_data_loss": true,
     "decision_required": true,
     "operations": [
       {"op": "drop_column", "table": "accounts", "column": "password_hash"},
       {"op": "add_column",  "table": "accounts", "column": "password_hash_bcrypt"}
     ]
   }
```

**What v0.1.2 would have returned:**

Column count: 4 before, 4 after. Net delta = 0. No operations emitted. Result:

```json
{
  "schema_version": 1,
  "risk_tier": "SAFE",
  "risk_score": 0.0,
  "retryable": true,
  "has_data_loss": false,
  "decision_required": false,
  "operations": []
}
```

This is the canonical V9 false-SAFE vulnerability. A CI gate relying on v0.1.2 would have auto-approved this migration, silently dropping all stored `password_hash` values. In a security context this is catastrophic — the entire auth system loses its stored hashes.

**v0.1.3 behavior:** PASS. forge makes no semantic inference about column names. The hash-set comparison treats `password_hash` and `password_hash_bcrypt` as distinct identifiers seeded by table name. Both differ → both emitted as operations → CRITICAL. The "still sounds safe" trap has no effect on the structural diff engine.

**Agent behavior:** Agent (or CI hook) receives `decision_required: true`. In a well-designed pipeline this is a hard gate — the migration cannot proceed without explicit human approval or a policy override. The adversarial "benign-sounding rename" gains no special treatment.

**Friction:** None from forge's side. Residual risk is entirely in the downstream consumer: a CI pipeline that bypasses `decision_required: true` for any reason (e.g., a config flag like `--auto-approve-notable`) would re-introduce the vulnerability at the policy layer, not the detection layer.

**Residual friction points:** forge does not distinguish between a potentially-intentional rename (same prefix, one word longer) and a completely unrelated column swap. Both are emitted as `drop_column` + `add_column`. This is correct behavior — forge does not and should not infer intent — but agents consuming the output may want a `"rename_similarity_hint"` field for UX purposes. This should never affect `risk_tier`.

**Score:** Discovery 10 | Schema Construction 10 | Risk Classification 10 | Error Recovery N/A

---

## Agent 4 — Multi-Table Rename Agent

**Model class:** LLM agent managing a complex migration. The schema change involves two simultaneous operations: a table rename (`payments` → `transactions`) AND a column rename within a separate, preserved table (`orders.status` → `orders.state`).

**Task:** Verify that forge correctly emits both `drop_table` for the table rename and `drop_column` + `add_column` for the column rename, and that the agent correctly interprets the combined result as CRITICAL.

**Trace:**

```
> forge analyze \
    --from "TABLE payments|COLUMN id|COLUMN amount|TABLE orders|COLUMN id|COLUMN status|COLUMN total" \
    --to   "TABLE transactions|COLUMN id|COLUMN amount|TABLE orders|COLUMN id|COLUMN state|COLUMN total"
<- {
     "schema_version": 1,
     "risk_tier": "CRITICAL",
     "risk_score": 1.0,
     "retryable": false,
     "has_data_loss": true,
     "decision_required": true,
     "operations": [
       {"op": "drop_table",  "table": "payments"},
       {"op": "add_table",   "table": "transactions"},
       {"op": "drop_column", "table": "orders", "column": "status"},
       {"op": "add_column",  "table": "orders", "column": "state"}
     ]
   }
```

**What v0.1.2 would have returned:**

Table diff (name-set based, not count-based): `payments` disappears, `transactions` appears → `drop_table` + `add_table` correctly emitted in both versions.

Column diff (count-based in v0.1.2): `orders` has 3 columns before and 3 columns after. Net delta = 0. Column operations for `orders` are NOT emitted.

v0.1.2 result:

```json
{
  "schema_version": 1,
  "risk_tier": "CRITICAL",
  "risk_score": 1.0,
  "retryable": false,
  "has_data_loss": true,
  "decision_required": true,
  "operations": [
    {"op": "drop_table", "table": "payments"},
    {"op": "add_table",  "table": "transactions"}
  ]
}
```

v0.1.2 is CRITICAL (due to the table drop), but the operations list is **incomplete**. The `orders.status` → `orders.state` rename is silently omitted. An agent or human reviewer reading the operations list would believe the only risk is the table rename, not realizing there is also a column-level data loss event in `orders`.

**v0.1.3 behavior:** PASS. The operations list is complete. Both the table-level and column-level operations are present. The agent correctly interprets four distinct operations, all contributing to CRITICAL.

**Agent behavior:** Agent receives four operations. It surfaces them grouped by table: "payments table will be dropped and recreated as transactions; orders.status column will be dropped and recreated as state." Operator sees the full scope. Correct interpretation.

**Friction:** The operations list is flat (array), not grouped by table. An agent building a human-readable summary must group by `"table"` key itself. A `"grouped_operations"` alternative or a `"table_summary"` map in the response would reduce the parsing burden for consumer agents, but the flat list is unambiguous and correct.

**Residual friction points:** The v0.1.2 behavior for this scenario was particularly dangerous: the response was already CRITICAL (due to the table drop), so a pipeline that only checks `risk_tier` would not notice the incomplete operations list. The upgrade to v0.1.3 matters most for pipelines that audit the full `operations` array, not just the tier. Teams that only gate on `risk_tier` received no additional protection from the V9 fix in this scenario — they were already blocking. Teams that use the operations list to generate migration scripts or audit trails received a partial fix with v0.1.2 that was invisibly incomplete.

**Score:** Discovery 10 | Schema Construction 10 | Risk Classification 10 | Error Recovery N/A

---

## Agent 5 — Cold-Agent Same-Column-Different-Table

**Model class:** Fresh LLM with no prior forge context. Receives a schema where `id` exists in both `users` and `orders`. The migration drops `id` from `users` but keeps it in `orders`. Tests that forge does not conflate same-named columns across different tables.

**Task:** Verify that dropping `users.id` is detected as CRITICAL even though `orders.id` still exists in the "to" schema.

**Trace:**

```
> forge analyze \
    --from "TABLE users|COLUMN id|COLUMN email|TABLE orders|COLUMN id|COLUMN total" \
    --to   "TABLE users|COLUMN email|TABLE orders|COLUMN id|COLUMN total"
<- {
     "schema_version": 1,
     "risk_tier": "CRITICAL",
     "risk_score": 1.0,
     "retryable": false,
     "has_data_loss": true,
     "decision_required": true,
     "operations": [
       {"op": "drop_column", "table": "users", "column": "id"}
     ]
   }
```

**What v0.1.2 would have returned:**

Under count-based column diff, v0.1.2 tracks total column counts per table name, not per (table, column) pair. `users` has 2 columns before and 1 column after — delta = -1. `orders` has 2 columns before and 2 columns after — delta = 0. So v0.1.2 would emit a `drop_column` for `users` but not necessarily identify which column was dropped.

More precisely: if v0.1.2's count-based diff emitted a generic `drop_column` for `users` without identifying the column, the operations list would read:

```json
{"op": "drop_column", "table": "users"}
```

(no `"column"` field), which is less precise. The risk tier would be CRITICAL in v0.1.2 as well (column count decreased), but the operations detail would be incomplete.

**Critical sub-case — where v0.1.2 fails for this archetype:** The false-SAFE vulnerability triggers if the to-schema has the same total column count as the from-schema. In this test, `users` loses one column, so v0.1.2 would catch it via count decrease. However, consider a slight variant:

```
--from "TABLE users|COLUMN id|COLUMN email|TABLE orders|COLUMN id|COLUMN total"
--to   "TABLE users|COLUMN name|COLUMN email|TABLE orders|COLUMN id|COLUMN total"
```

Here `users` still has 2 columns before and 2 columns after (`id` dropped, `name` added). v0.1.2 count-based diff: delta = 0, SAFE. v0.1.3 hash-set diff: `users.id` hash missing from "to" set, `users.name` hash missing from "from" set → `drop_column users.id` + `add_column users.name` → CRITICAL.

v0.1.3 behavior for original test: PASS. Table-seeded hashes mean `users::id` and `orders::id` are distinct hash values. The "to" schema contains `orders::id` but not `users::id`. Exactly one operation emitted: `drop_column users.id`. `orders.id` is untouched. The column named `id` in `orders` provides no "cover" for the missing `id` in `users`.

**Agent behavior:** Cold agent receives the response and reads: `risk_tier: CRITICAL`, `has_data_loss: true`, `operations: [drop_column users.id]`. Even without prior context, the agent correctly deduces that the primary key of the `users` table is being dropped. It halts the migration and flags for review.

**Friction:** The cold agent, having no prior context, may be confused that `orders.id` is not listed in operations. It might reason: "id exists in the to-schema, why is it reported as dropped?" The operations list names the table (`"table": "users"`), which disambiguates — but only if the agent reads the `table` field, not just the `column` field. A natural-language `"summary"` field in the response (e.g., `"summary": "Column id dropped from table users (users.id still present in orders is a separate column)"`) would eliminate this confusion for cold LLM consumers.

**Residual friction points:** Agents that scan the to-schema for a column named `id` and conclude "id exists, must be safe" are vulnerable to cross-table aliasing confusion. This is an agent reasoning failure, not a forge failure, but it is predictable enough that the response format could defensively address it.

**Score:** Discovery 9 | Schema Construction 9 | Risk Classification 10 | Error Recovery N/A

---

## Summary Score Table

| Agent | Discovery | Schema Construction | Risk Classification | Error Recovery |
|---|---|---|---|---|
| 1 — GPT-4 + describe | 10 | 10 | 10 | — |
| 2 — Minimal scripted | 2 | 6 | 10 | 8 |
| 3 — Adversarial (benign-looking rename) | 10 | 10 | 10 | — |
| 4 — Multi-table rename | 10 | 10 | 10 | — |
| 5 — Cold agent, same-column-different-table | 9 | 9 | 10 | — |

---

## v0.1.2 vs v0.1.3 Regression Summary

| Scenario | v0.1.2 result | v0.1.3 result | Delta |
|---|---|---|---|
| Agent 1: email → email_address (preserved table) | false-SAFE | CRITICAL | **Fixed** |
| Agent 2: add_column only | NOTABLE (correct) | NOTABLE (correct) | No change |
| Agent 3: password_hash → password_hash_bcrypt (preserved table) | false-SAFE | CRITICAL | **Fixed** |
| Agent 4: table rename + column rename (multi-table) | CRITICAL, incomplete ops | CRITICAL, complete ops | **Fixed** |
| Agent 5: drop users.id (orders.id preserved) | CRITICAL (count decreased) | CRITICAL (hash-set correct) | Correct in both; v0.1.3 is more precise |

---

## Key Findings

1. **The V9 fix closes a wide attack surface.** Any schema migration where a column is renamed within a preserved table — regardless of how semantically similar the old and new names are — was silently classified as SAFE by v0.1.2. This is now correctly classified as CRITICAL in v0.1.3. The fix is structural and requires no per-rename heuristic.

2. **The most dangerous v0.1.2 failure mode was the invisible one.** In Agent 4's scenario, v0.1.2 still returned CRITICAL (due to the table rename) but emitted an incomplete operations list. Pipelines gating on `risk_tier` received no regression — but pipelines using the `operations` array to generate audit trails, migration scripts, or reviewer summaries silently omitted the column-level risk. Teams relying on the operations list for downstream tooling should re-audit any migrations approved under v0.1.2 that involved simultaneous table renames and column renames.

3. **`hint` in error responses is load-bearing for scriptable self-correction.** Agent 2's self-correction from `UNKNOWN_FLAG` worked only because the error payload named the correct flag. This pattern should be applied consistently across all error codes forge can emit. Any error that has a known fix should encode that fix in the response, not just the problem.

4. **Cold LLM agents are vulnerable to cross-table column name aliasing.** Agent 5 highlights a predictable LLM reasoning failure: if a column name exists anywhere in the to-schema, a cold model may incorrectly infer it is "safe" without checking the table qualifier. forge's table-seeded hashes prevent false-SAFE at the engine level, but the response format does not defensively address this confusion. A `"summary"` string in the JSON response would reduce cold-agent reasoning errors at low cost.

5. **Semantic similarity of column names has zero bearing on forge's classification.** `password_hash` → `password_hash_bcrypt` gets the same CRITICAL result as `foo` → `bar`. This is correct and should be documented explicitly in `--describe` to prevent agent authors from assuming any rename is auto-approved if the names are "close enough."

6. **The flat operations array requires consumer-side grouping.** All four of forge's operation types (`drop_table`, `add_table`, `drop_column`, `add_column`) share the same flat array. Agents building human-readable summaries or migration scripts must group by table. A `"by_table"` map in the response (in addition to the flat array for backward compatibility) would reduce parsing friction.

---

## Red-Team Takeaways

1. **Semantic camouflage attack (confirmed mitigated in v0.1.3).** An adversarial schema submitter could rename a high-value column to a name that sounds like a minor variant (`password_hash` → `password_hash_bcrypt`, `user_id` → `user_id_v2`, `ssn` → `ssn_masked`) hoping a downstream reviewer or policy rule would treat it as an annotation change. forge v0.1.3 does not classify these differently from any other rename. The mitigation is structural. Risk: LOW (in forge); risk remains in downstream policy layers that may auto-approve "minor-looking" renames.

2. **Multi-operation camouflage attack (partially present in v0.1.2, confirmed mitigated in v0.1.3).** An adversarial submitter could combine a legitimate CRITICAL table drop (which would trigger a CRITICAL tier regardless) with a hidden column rename in a preserved table. Under v0.1.2, the column rename would be invisible in the operations list — the reviewer focuses on the table drop and approves, not knowing a column rename is also in scope. v0.1.3 emits all operations. Teams should re-audit any compound migrations approved under v0.1.2.

3. **Cross-table column aliasing attack (edge case, not yet mitigated at response layer).** A schema crafted so that a dropped column in table A shares its name with a retained column in table B could confuse a cold LLM agent that scans the to-schema holistically rather than per-table. forge's engine is correct, but the response format does not defensively surface the per-table attribution. Recommend adding a `"summary"` field to the response JSON that names the specific table for each dropped column.

4. **Schema string injection via `--from` / `--to`.** If forge's schema parser does not strictly validate the `TABLE name|COLUMN col` grammar, a crafted schema string with unexpected tokens (e.g., embedded newlines, null bytes, or reserved words) could cause undefined parse behavior. This has not been tested in this cycle but is a natural follow-on red-team exercise. Forge should return a structured `PARSE_ERROR` with the offending token and position, not a crash or silent truncation.

5. **Count-parity rename amplification.** An attacker controlling both the from and to schema strings could construct a schema where N columns are added and N different columns are dropped across multiple preserved tables, all within a single `forge analyze` call. Each of the N renames is a potential data loss event. Under v0.1.2, if N additions and N deletions cancel out in count, the entire set is classified SAFE. Under v0.1.3, each individual rename is detected independently. This is correctly handled — but the amplification factor (how many false-SAFEs a single well-crafted schema could generate in v0.1.2) should be quantified and included in the v0.1.2 security advisory if one is issued.
