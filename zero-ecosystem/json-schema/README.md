# json-schema — JSON Schema Draft-07 Subset Validator

**Status:** Implemented — `jsonschema_mini.0` (Zero v0.1.x, 1000+ lines)
**Version:** 0.1.8  
**Eval:** 30/30 cases pass (EC-01 through EC-30)

---

## Why

Agents composing pipelines need to validate tool outputs against expected schemas before passing them to the next stage. Without a validator, schema drift is silent — a field goes missing and the downstream agent gets a null where it expected a string. In human software this is caught by tests; in agent software it causes hallucination cascades.

A JSON Schema validator in Zero gives every Zero tool an embeddable, statically-linked validation layer with no runtime dependency.

---

## Agent-facing interface

```bash
# Validate data against a schema (both inline as args)
jsonschema validate --schema '{"type":"object","required":["id"]}' --data '{"id":"u1"}'

# Cold-start discovery
jsonschema --describe
```

**Success:**
```json
{"valid": true, "schema_version": 1}
```

**Failure:**
```json
{
  "valid": false,
  "schema_version": 1,
  "errors": [
    {"path": "$.currency", "code": "ENUM_MISMATCH"},
    {"path": "$.amount", "code": "TYPE_MISMATCH"}
  ]
}
```

---

## Scope (Draft-07 subset, v0.1)

**Implemented:**
- `type` — string, number, integer, boolean, null, array, object
- `required` — array of required property names
- `properties` — per-property sub-schema
- `minLength` / `maxLength` — string length constraints
- `minimum` / `maximum` — numeric range (uses explicit flag, no sentinel)
- `enum` — exact value match (strings and numbers)
- `const` — exact single-value match (strings and non-strings; raw-byte comparison for non-strings)
- `additionalProperties: false` — reject data keys absent from `properties`
- nested `properties` (depth 2) — type/minLength/maxLength/minimum/maximum for depth-2 properties; path `$.outer.inner`

**Deferred to v0.2:**
- `pattern` — regex (no stdlib regex in Zero v0.1.x)
- `$ref` / `definitions` — schema composition
- `oneOf` / `anyOf` / `allOf`
- `additionalProperties` (schema object form — e.g. `{"type":"string"}`)
- `format` (date-time, email, uri)
- nested `properties` (depth > 2; enum/const at depth 2 — deferred to v0.2)

---

## Size limits (v0.1 constraints)

| Limit | Value |
|-------|-------|
| Max schema bytes | 4096 |
| Max data bytes | 4096 |
| Max properties | 8 |
| Max required fields | 8 |
| Max enum values | 8 (scan unbounded; storage capacity is 8) |
| Max errors reported | 16 |
| Max integer digits | 18 (overflow clamp applied) |
| Depth | depth 1 (full), depth 2 (type/min/max/minLength/maxLength) |

---

## Known limitations

- **Unrecognized `type` values (P3):** If the schema `"type"` field contains an unrecognized value (not one of the 7 JSON Schema types), type checking is silently disabled for that property. Validate your schema against a trusted source before use.

- **Unicode-escaped schema keywords (P3, RT-119):** Schema keyword names (`"type"`, `"required"`, `"properties"`, etc.) are matched by raw byte comparison. A schema key written as a Unicode escape sequence (e.g., `"type"` instead of `"type"`) is not recognized as the keyword — its constraint is silently skipped. This only applies when the attacker controls the schema; in fixed-schema deployments the risk is negligible.

- **Duplicate key shadowing (P4, RT-119b):** When data contains duplicate keys (`{"age":1,"age":"bad"}`), only the first occurrence is validated. If the downstream consumer uses last-wins semantics, a type violation on the last value would not be caught. Consistent with RFC 8259 (behavior undefined for duplicate names).

- **Enum numeric representation (P3, RT-121):** Numeric enum values use raw byte comparison. `1.0` and `1e0` will NOT match enum `[1]` even though they represent the same value. Use consistent integer representation for numeric enum values (no trailing `.0`, no scientific notation).

- **`const` object/array whitespace (P3, RT-141):** `const` for object and array values uses raw byte comparison. Schema `{"const": {"k":"v"}}` will NOT match data `{"k": "v"}` (extra space after `:`), even though they represent the same structure. For object/array const values, use byte-for-byte identical JSON text representation.

- **`const` + `type` dual error (P3, RT-142):** When both `type` and `const` are declared and data fails the type check, both TYPE_MISMATCH and CONST_MISMATCH are emitted for the same field. This is correct per JSON Schema Draft-07 (keywords are independent), but agent self-correction loops should handle this by fixing the type — which will also fix the const violation.

- **Depth-2 `required` not enforced (P3, RT-150):** The `required` keyword in a nested object sub-schema (depth 2) is silently ignored. If `"address": {"type":"object","required":["city"],"properties":{"city":...}}` and data has `{"address":{}}`, no REQUIRED_MISSING is emitted for the missing nested `city`. Workaround: validate the nested object separately or upgrade to v0.2 when recursive `validateAgainst` is available.

- **Depth-2 `additionalProperties:false` not enforced (P3, RT-151):** The `additionalProperties` keyword in a nested object sub-schema is silently ignored. Extra keys in a depth-2 nested object do not trigger ADDITIONAL_PROPERTY. Same workaround as RT-150.

- **Integer overflow clamp (P4):** Integers with more than 18 digits are clamped to ±9,999,999,999. Very large integer data values (astronomically large) may get false MINIMUM/MAXIMUM errors if the schema constraint is near the 10B boundary.

---

## Eval cases (30/30 pass)

| Case | Description |
|------|-------------|
| EC-01 | Valid object — all required fields present |
| EC-02 | Missing required field → REQUIRED_MISSING |
| EC-03 | Wrong type (string where integer expected) → TYPE_MISMATCH |
| EC-04 | String too long → MAX_LENGTH |
| EC-05 | String too short → MIN_LENGTH |
| EC-06 | Enum mismatch → ENUM_MISMATCH |
| EC-07 | Multiple errors in one document |
| EC-08 | Empty object, minimal schema → valid |
| EC-09 | Value below explicit minimum → MINIMUM |
| EC-10 | `--describe` cold-start |
| EC-11 | RT-116 regression: property key with `\"` → error path is valid JSON |
| EC-12 | RT-117 regression: value -10B, no minimum constraint → valid (no false MINIMUM) |
| EC-13 | RT-117 regression: value +10B, no maximum constraint → valid (no false MAXIMUM) |
| EC-14 | RT-116b regression: 20-digit integer clamped to 9.99B → exceeds `maximum:100` → MAXIMUM (no crash) |
| EC-15 | RT-118 regression: `\n` escape vs `\t` escape — different sequences must not match |
| EC-16 | RT-118 bypass: required `foo"bar` must not match data key `foo"b` (old bug: prematurely matched at escaped-quote byte) |
| EC-17 | RT-120 regression: `A` (6 raw bytes) is 1 code point — `maxLength:1` must pass (no false MAX_LENGTH) |
| EC-18 | RT-120 bypass: `A` is 1 code point — `minLength:3` must fail MIN_LENGTH (pre-fix: inflated count of 5 silently passed) |
| EC-19 | RT-120 regression: `AB` = 2 code points — `maxLength:2` must pass |
| EC-20 | RT-122 regression: `integer` + `minimum:1`, data `0` → MINIMUM (not spurious TYPE_MISMATCH) |
| EC-21 | RT-121 bypass: `1e5` must NOT match enum `[1,2,3]` — scientific notation truncation bypass |
| EC-22 | RT-121 baseline: exact integer `1` still matches enum `[1]` after raw-byte fix |
| EC-23 | `additionalProperties:false` — extra key `extra` in data → ADDITIONAL_PROPERTY with path `$.extra` |
| EC-24 | `additionalProperties:false` — data has only declared properties → valid:true |
| EC-25 | `const` string match — data value `"v1"` exactly equals const `"v1"` → valid:true |
| EC-26 | `const` string mismatch — data value `"v2"` does not equal const `"v1"` → CONST_MISMATCH |
| EC-27 | nested properties depth-2: `address.city` is string type → valid:true |
| EC-28 | nested properties depth-2: `address.zip` declared integer but data has string → TYPE_MISMATCH at `$.address.zip` |
| EC-29 | nested depth-2: `info.tag` exceeds maxLength:3 → MAX_LENGTH at `$.info.tag` |
| EC-30 | nested depth-2: `stats.count` value 0 below minimum:1 → MINIMUM at `$.stats.count` |

---

## Version history

- v0.1.8 (2026-05-23): nested depth-2 FULL CONSTRAINTS — added minLength/maxLength/minimum/maximum validation for depth-2 nested properties; new arrays `np_min_len/np_max_len[8]i64`, `np_minimum/np_maximum[8]i64`, `np_has_min/np_has_max[8]bool`; all depth-2 constraint errors use pidx=201 sentinel with err_parent_prop_idx + err_nested_key_pos for `$.outer.inner` path. EC-29, EC-30 added. 30/30 eval cases pass.
- v0.1.7 (2026-05-23): nested properties depth-2 IMPLEMENTED — when a property's sub-schema has `type: object` and a `properties` key, the validator walks the nested data object and type-checks each declared nested property. Error code 2 (TYPE_MISMATCH) emitted with path `$.outer.inner`. New arrays: `prop_has_nested[8]bool`, `prop_nested_props_pos[8]usize`, `np_key_pos[8]usize`, `np_type[8]u8`, `err_nested_key_pos[16]usize`, `err_parent_prop_idx[16]usize`; pidx=201 sentinel for nested errors. V50 IMPLEMENTED: `_audit_fail()` added to both ledger and forge bridges (writes rc to `.heros-audit-failed` on auth failures). EC-27, EC-28 added. 28/28 eval cases pass.
- v0.1.6 (2026-05-23): `const` IMPLEMENTED — exact single-value constraint; string comparison via `jsonStrEq` (escape-aware); non-string comparison via raw-byte comparison (reuses RT-121 pattern); error code 10 = CONST_MISMATCH; `prop_has_const[8]bool` + `prop_const_pos[8]usize` added; const check is independent of `type` (runs after `if p_type != 0` block). EC-25, EC-26 added. 26/26 eval cases pass.
- v0.1.5 (2026-05-23): `additionalProperties: false` IMPLEMENTED — data keys absent from `properties` emit ADDITIONAL_PROPERTY (code 9) with `$.key` path from data span; pidx=200 sentinel in err_prop_idx; `err_data_key_pos[16]usize` added. EC-23, EC-24 added. 24/24 eval cases pass.
- v0.1.4 (2026-05-23): RT-122 FIXED — `typeCompatible` condition `data_type==4` corrected to `data_type==3`; integer-typed fields now correctly perform range checks instead of spurious TYPE_MISMATCH. RT-121 FIXED — enum numeric comparison switched from `jsonParseInt` (truncates at 'e') to raw byte comparison; `1e5` no longer bypasses enum `[1]`. P3 limitation: `1.0` won't match enum `[1]` (use consistent numeric representation). EC-20, EC-21, EC-22 added.
- v0.1.3 (2026-05-23): RT-120 FIXED — `jsonStringLen` now counts `\uXXXX` as 1 code point (advance 6, count 1) instead of 5. Prevents minLength bypass via Unicode-escaped data and eliminates false maxLength rejections. EC-17, EC-18, EC-19 regression tests added.
- v0.1.2 (2026-05-23): RT-118 FIXED — `jsonStrEq` now escape-aware; `\"` inside a key no longer prematurely ends comparison, preventing required-field bypass. EC-15, EC-16 regression tests added.
- v0.1.1 (2026-05-23): RT-116 FIXED — escaped quote in property name caused broken JSON error path. RT-117 FIXED — false MINIMUM/MAXIMUM for values outside ±9.99B sentinel. `jsonParseInt` overflow guard (18-digit cap). EC-11 through EC-14 added.
- v0.1.0 (2026-05-19): Initial implementation. type, required, properties, minLength/maxLength, minimum/maximum, enum. 10 eval cases.
