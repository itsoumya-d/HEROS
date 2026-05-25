# jsonschema v0.2 — Keyword Scope Document

**Date:** 2026-05-23  
**Current version:** 0.1.8 (30/30 eval cases — nested depth-2 type + min/max/length constraints in v0.1.7/v0.1.8)  
**Target:** v0.2 (blocked on Zero v0.2 release)  

---

## Summary table

| Keyword | Complexity | Zero v0.2 blocker | Security surface | Priority |
|---------|------------|-------------------|-----------------|----------|
| `pattern` | Medium | Regex stdlib | Regex injection, ReDoS | P2 |
| `additionalProperties` (schema-object form) | Medium | None (v0.1.x capable) | Sub-schema injection | P3 |
| `$ref` / `definitions` | High | Recursive walker | Cyclic $ref DoS | P2 |
| `oneOf` / `anyOf` / `allOf` | High | None | N-schema evaluation | P3 |
| `format` | Low | None (validation only) | No injection surface | P4 |
| `$schema` meta-validation | Low | None | None | P4 |
| Nested `properties` (depth > 1) | Medium | None | OOB via deep nesting | P2 |

---

## Keyword details

### 1. `pattern` (P2, blocked on Zero v0.2 regex stdlib)

**Spec:** Validates that a string value matches a ECMA-262 regular expression.

**Zero v0.2 blocker:** Zero v0.1.x has no regex engine in stdlib. This is the only keyword that requires regex.

**Implementation approach (v0.2):**
```
findKey(schema, "pattern") → string pos
If found and data property is string type:
  regex = extractJsonString(schema, pattern_pos)
  if !regexMatch(data_string, regex): emit PATTERN_MISMATCH (code 10)
```

**Eval cases needed (estimate: 4, numbered EC-47+):**
- EC-47: `pattern: "^[a-z]+$"` matches → valid
- EC-48: `pattern: "^[a-z]+$"` doesn't match → PATTERN_MISMATCH
- EC-49: `pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"` (date format) → valid date
- EC-50: `pattern` on non-string property → ignored (no error; only validates strings)

**Security surface:**
- **ReDoS (RT-138 scope):** Catastrophic backtracking on attacker-controlled regex in schema. Mitigations: (1) if attacker controls schema, this is already a trusted-schema deployment issue; (2) Zero regex engine should have backtracking limit. Evaluate when stdlib regex is available.
- **Regex injection:** If schema is user-supplied, attacker can craft regex that always matches (bypass) or always fails (DoS). Same trusted-schema caveat.
- **P3 known limitation (RT-119 extension):** Unicode-escaped pattern keywords would be silently ignored (same as other keywords).

---

### 2. `additionalProperties` (schema-object form, no v0.2 blocker)

**Status:** `additionalProperties: false` is implemented in v0.1.5. The schema-object form (`{"type":"string"}`) is deferred.

**Spec:** When `additionalProperties` is a schema object, additional properties in data must validate against that sub-schema.

**Implementation approach (no new Zero APIs needed):**
```
After existing additionalProperties:false detection:
  if value at addl_pos is '{' (123) → has_addl_schema = true; addl_schema_pos = addl_pos
  
In data-walk loop, when matched_prop == 255 && has_addl_schema:
  validate data value against addl_schema_pos (reuse existing constraint extraction)
  emit errors with pidx=202 sentinel (pidx=200 = additionalProperties:false, pidx=201 = nested property error — RT-153)
```

**Constraint:** Flat-object only (v0.1 depth constraint). Sub-schema can have type/minLength/maxLength/minimum/maximum/enum — same keywords as property sub-schemas.

**Eval cases needed (estimate: 3, numbered EC-44+):**
- EC-44: `additionalProperties: {"type": "string"}` — extra key with string value → valid
- EC-45: `additionalProperties: {"type": "string"}` — extra key with integer value → TYPE_MISMATCH
- EC-46: `additionalProperties: {"type": "string", "maxLength": 5}` — extra key too long → MAX_LENGTH

**Security surface:**
- Sub-schema injection: if attacker controls `additionalProperties` schema value, they can inject constraints. Same trusted-schema caveat.
- **RT-153 collision guard**: pidx=200 = additionalProperties:false sentinel; pidx=201 = nested property error sentinel (v0.1.7+); pidx=202 RESERVED for schema-object additional property errors. Do not reuse 200 or 201.

---

### 3. `$ref` / `definitions` (P2, no v0.2 blocker but complex)

**Spec:** Schema composition via `$ref: "#/definitions/MyType"`. `definitions` is a map of named sub-schemas.

**Implementation approach:**
```
findKey(schema, "$ref") → string: "#/definitions/TypeName"
Extract TypeName from $ref value
findKey(schema, "definitions") → object pos
findKey(definitions_object, TypeName) → sub-schema pos
Validate data against sub-schema
```

**Zero v0.2 constraint:** No recursion limit enforcement except Zero's call stack. For v0.1.5 flat-object walker, `$ref` within a property sub-schema would need recursive calls. Zero v0.1.x does allow function recursion — it's not the language, it's our implementation not having a recursive validate function.

**Blocker:** Our `validate` command is a monolithic `main` function (not a recursive helper). Refactoring to a `validateAgainst(sub_schema_pos)` helper function would be needed.

**Cyclic $ref DoS risk:** `"$ref": "#/definitions/A"` where `definitions.A.$ref = "#/definitions/A"` → infinite loop. Must detect cycles with a visited-set (requires a small set, e.g. `[8]usize` visited positions).

**Eval cases needed (estimate: 4, numbered EC-34+):**
- EC-34: Simple `$ref` to definitions → valid
- EC-35: `$ref` to non-existent definition → SCHEMA_ERROR
- EC-36: Cyclic `$ref` → SCHEMA_ERROR (cycle detected, no infinite loop)
- EC-37: `$ref` + type mismatch via definition → TYPE_MISMATCH

**Security surface:**
- Cyclic `$ref` DoS — must guard with visited-set
- Schema size limit (4096 bytes) bounds definitions length
- P3: `$ref` to external URL (`$ref: "http://..."`) is NOT supported; only `#/definitions/...` anchors. Must detect and reject non-anchor refs.

---

### 4. `oneOf` / `anyOf` / `allOf` (P3, no v0.2 blocker but complex)

**Spec:**
- `allOf`: data must validate against all sub-schemas
- `anyOf`: data must validate against at least one sub-schema
- `oneOf`: data must validate against exactly one sub-schema

**Implementation approach:**
```
findKey(schema, "allOf") → array pos
For each sub-schema in array (up to 8):
  validate data against sub-schema
  if any fail: ALLOF_MISMATCH (code 11)

Similar for anyOf (at least 1 must pass) and oneOf (exactly 1 must pass).
```

**Zero constraint:** Array of sub-schemas within 4096-byte schema limit. Up to 8 sub-schemas (matching other array limits). Requires the recursive `validateAgainst` helper from `$ref` work.

**Eval cases needed (estimate: 6, numbered EC-38+):**
- EC-38: `allOf: [{"type":"string"}, {"minLength":3}]` — both pass → valid
- EC-39: `allOf: [{"type":"string"}, {"minLength":10}]` — second fails → error
- EC-40: `anyOf: [{"type":"string"}, {"type":"integer"}]` — integer data → valid
- EC-41: `anyOf: [{"type":"string"}, {"type":"boolean"}]` — integer data → error
- EC-42: `oneOf: [{"type":"string"}, {"type":"integer"}]` — string data → valid (exactly 1 match)
- EC-43: `oneOf: [{"type":"number"}, {"type":"integer"}]` — integer data → error (2 schemas match, not 1)

**Security surface:** N-schema evaluation is O(N×M) where M = data property count. With 8 sub-schemas × 8 properties = 64 validation ops max — bounded. No DoS concern within current limits.

---

### 5. `format` (P4, no blocker)

**Spec:** Semantic validation of strings against known formats (date-time, email, uri, etc.).

**JSON Schema position:** `format` is annotation-only in Draft 2020-12 (validation is opt-in). For agent-facing use, `format` as validation adds value.

**Implementation approach:**
```
In property sub-schema parsing: findKey(sub_schema, "format") → string
Store prop_format[8]u8 (small enum: 0=none, 1=date, 2=datetime, 3=email, 4=uri)
In data-walk: if p_type == 2 (string) && prop_format[mp] != 0:
  validate against format-specific byte scanner
  emit FORMAT_MISMATCH (code 12)
```

**Date scanner (format: "date"):** `YYYY-MM-DD` — 10-char exact scan, digits + dashes, month 01-12, day 01-31. No calendar validation (P4 limitation: Feb 30 would pass).

**Email scanner (format: "email"):** Contains exactly one `@`, local part non-empty, domain has at least one `.`. Simplified (RFC 5321 full validation is 500+ lines).

**URI scanner (format: "uri"):** Starts with scheme (`[a-z]+:`). Simplified.

**Eval cases needed (estimate: 3, numbered EC-51+):**
- EC-51: `format: "date"` — `"2026-05-23"` → valid
- EC-52: `format: "date"` — `"not-a-date"` → FORMAT_MISMATCH
- EC-53: `format: "email"` — `"user@example.com"` → valid

**Security surface:** No injection risk (byte scanning only, no regex). Known limitation: format validation is approximate — false negatives are more likely than false positives.

---

### 6. `$schema` meta-validation (P4, no blocker)

**Spec:** The `$schema` keyword declares which schema dialect the schema uses. Validators may reject schemas with unknown `$schema` values.

**Current behavior:** `$schema` is silently ignored (findKey skips unknown top-level keywords).

**Implementation approach:**
```
findKey(schema, "$schema") → string
If present and not "http://json-schema.org/draft-07/schema" and not
  "https://json-schema.org/draft/2020-12/schema":
  emit SCHEMA_ERROR: unsupported $schema dialect
```

**Rationale for deferring:** The validator correctly handles Draft-07 subset regardless of `$schema` declaration. Rejecting on unknown `$schema` prevents forward compatibility (a schema declaring 2020-12 that only uses Draft-07 keywords would break). Only add if agent deployments need strict schema-version enforcement.

**Eval cases needed (estimate: 1):**
- EC-54: `$schema: "https://json-schema.org/draft/2020-12/schema"` — accepted (our implemented subset)

---

### 7. Nested `properties` (depth 2 PARTIALLY IMPLEMENTED in v0.1.8; depth 3+ deferred to v0.2)

**v0.1.8 status (2026-05-23):** Depth-2 nested properties are now validated with type/minLength/maxLength/minimum/maximum constraints. Path emission: `$.outer.inner`. EC-27..EC-30 added (30/30 total).

**v0.1.8 gaps (P3, deferred to v0.2):**
- `required` at depth 2 (RT-150): silently ignored — missing nested required keys not flagged
- `additionalProperties:false` at depth 2 (RT-151): silently ignored — extra nested keys not flagged  
- `enum`/`const` at depth 2: deferred — flat-array design doesn't include np_enum_pos/np_const_pos
- Depth 3+: requires `validateAgainst` recursive helper

**v0.2 approach:** Extract `validateAgainst(sub_schema_pos, depth)` recursive helper. Replace flat depth-2 walk with recursive call. Enforce depth limit 3 via counter. This eliminates the flat-array approach entirely and handles depth N uniformly.

**Remaining eval cases for v0.2 (depth-3+ or depth-2 gaps):**
- EC-31: depth-2 `required` enforced (RT-150 gap)
- EC-32: depth-2 `additionalProperties:false` enforced (RT-151 gap)
- EC-33: depth-3 (triple-nested) type check

---

## v0.2 implementation order (updated 2026-05-23)

1. **`validateAgainst` recursive helper** — foundational; unlocks depth 3+, $ref, allOf/anyOf/oneOf, depth-2 required/additionalProperties
2. **Depth-2 remaining gaps** (`required`, `additionalProperties:false`, `enum`, `const`) — use validateAgainst for uniform handling
3. **`$ref` / `definitions`** — uses validateAgainst; cyclic ref guard needed
4. **`allOf` / `anyOf` / `oneOf`** — uses validateAgainst
5. **`additionalProperties` (schema-object form)** — small addendum
6. **`pattern`** — blocked on regex stdlib
7. **`format`** — nice-to-have
8. **`$schema` meta-validation** — low value

## v0.2 eval target

Current: 30/30 (EC-01 through EC-30, v0.1.8)  
v0.2 target: ~54/54 (adds EC-31..EC-54: depth-2 gaps + $ref + allOf/anyOf/oneOf + additionalProperties-schema + pattern + format + $schema)
- RT-157 correction: prior estimate ~45 under-counted. Correct tally: 24 new cases across 7 feature areas (3+4+6+3+4+3+1 = 24) → 30+24 = 54.

## v0.2 size target

Current: ~1050 lines, <100 KiB binary  
v0.2 estimate: ~1400 lines — still well within 100 KiB budget given Zero's tight codegen
