# jsonschema v0.1.7 — Nested Properties Design

**Status:** Design / pre-implementation spec  
**Target:** v0.1.7  
**Prerequisite:** None — implementable in Zero v0.1.x (no stdlib additions needed)  
**Scope:** Depth-2 nested `properties` for a single object-typed parent property

---

## Problem

Current jsonschema_mini.0 (v0.1.6) validates flat objects only. Schema:
```json
{"type":"object","properties":{"user":{"type":"object","properties":{"name":{"type":"string","minLength":1}}}}}
```
Against data `{"user":{"name":""}}` — the nested `minLength:1` constraint on `name` is silently ignored. Agents composing pipelines with structured sub-objects get no validation on inner fields.

---

## Scope (v0.1.7 depth limit = 1 nesting level)

Support one parent property with `type:object` + `properties` sub-schema. Sub-properties support: `type`, `minLength`, `maxLength`, `minimum`, `maximum`, `enum`, `const`. Excludes: `required` for nested, `additionalProperties` for nested, depth > 2.

If the schema has multiple object-typed properties with nested sub-schemas, only the first one (lowest index in `prop_key_pos`) is validated at depth 2. The rest are validated at depth 1 (type:object check only, sub-properties ignored). This is a documented P3 limitation.

---

## New arrays (after existing `prop_has_const`/`prop_const_pos` declarations)

```zero
// Depth-2 nested properties (first object-typed property with sub-schema only)
let mut nested_parent_idx: usize = 255  // 255 = none
let mut nested_prop_key_pos:   [8]usize = [0, 0, 0, 0, 0, 0, 0, 0]
let mut nested_prop_type:      [8]u8    = [0, 0, 0, 0, 0, 0, 0, 0]
let mut nested_prop_min_len:   [8]i64   = [-1, -1, -1, -1, -1, -1, -1, -1]
let mut nested_prop_max_len:   [8]i64   = [-1, -1, -1, -1, -1, -1, -1, -1]
let mut nested_prop_minimum:   [8]i64   = [0, 0, 0, 0, 0, 0, 0, 0]
let mut nested_prop_maximum:   [8]i64   = [0, 0, 0, 0, 0, 0, 0, 0]
let mut nested_prop_has_min:   [8]bool  = [false, false, false, false, false, false, false, false]
let mut nested_prop_has_max:   [8]bool  = [false, false, false, false, false, false, false, false]
let mut nested_prop_has_enum:  [8]bool  = [false, false, false, false, false, false, false, false]
let mut nested_prop_enum_pos:  [8]usize = [0, 0, 0, 0, 0, 0, 0, 0]
let mut nested_prop_has_const: [8]bool  = [false, false, false, false, false, false, false, false]
let mut nested_prop_const_pos: [8]usize = [0, 0, 0, 0, 0, 0, 0, 0]
let mut nested_prop_count: usize = 0
```

---

## Error index encoding

Current `err_prop_idx` ranges:
- `0–7`: depth-1 property errors
- `64–127`: **new — depth-2 property errors**: `64 + parent_depth1_idx * 8 + nested_prop_idx`
- `128–135`: required field errors (`128 + req_idx`)
- `200`: additional property sentinel

Range 64–127 = 64 values = 8 parents × 8 children. No overlap with existing ranges.

---

## Parse phase changes

In the sub-schema parsing loop (after `pconst_pos` check), add:

```
// Depth-2: if this property has type=object and we haven't set nested_parent_idx yet,
// check for a nested "properties" sub-schema.
if prop_type[prop_count] == 1 && nested_parent_idx == 255 {
    let pn_pos = findKey(sch_sp, sch_len, sub_start, "properties")
    let pn_ws  = if pn_pos < sch_len { skipWS(sch_sp, sch_len, pn_pos) } else { sch_len }
    if pn_ws < sch_len && sch_sp[pn_ws] == 123 {
        nested_parent_idx = prop_count
        let mut np = pn_ws + 1
        while np < sch_len && nested_prop_count < 8 {
            np = skipWS(sch_sp, sch_len, np)
            if np >= sch_len || sch_sp[np] == 125 { np = sch_len }  // end
            else if sch_sp[np] != 34 { np = sch_len }               // unexpected
            else {
                nested_prop_key_pos[nested_prop_count] = np
                let nke = skipJsonString(sch_sp, sch_len, np)
                let ncp = skipWS(sch_sp, sch_len, nke)
                if ncp >= sch_len || sch_sp[ncp] != 58 { np = sch_len }
                else {
                    let nss = skipWS(sch_sp, sch_len, ncp + 1)
                    if nss < sch_len && sch_sp[nss] == 123 {
                        let ntpp = findKey(sch_sp, sch_len, nss, "type")
                        if ntpp < sch_len { nested_prop_type[nested_prop_count] = parseTypeCode(sch_sp, sch_len, ntpp) }
                        let nminlp = findKey(sch_sp, sch_len, nss, "minLength")
                        if nminlp < sch_len { nested_prop_min_len[nested_prop_count] = jsonParseInt(sch_sp, sch_len, nminlp) }
                        let nmaxlp = findKey(sch_sp, sch_len, nss, "maxLength")
                        if nmaxlp < sch_len { nested_prop_max_len[nested_prop_count] = jsonParseInt(sch_sp, sch_len, nmaxlp) }
                        let nminp = findKey(sch_sp, sch_len, nss, "minimum")
                        if nminp < sch_len { nested_prop_minimum[nested_prop_count] = jsonParseInt(sch_sp, sch_len, nminp); nested_prop_has_min[nested_prop_count] = true }
                        let nmaxp = findKey(sch_sp, sch_len, nss, "maximum")
                        if nmaxp < sch_len { nested_prop_maximum[nested_prop_count] = jsonParseInt(sch_sp, sch_len, nmaxp); nested_prop_has_max[nested_prop_count] = true }
                        let nenp = findKey(sch_sp, sch_len, nss, "enum")
                        if nenp < sch_len {
                            let nenpw = skipWS(sch_sp, sch_len, nenp)
                            if nenpw < sch_len && sch_sp[nenpw] == 91 {
                                nested_prop_has_enum[nested_prop_count] = true
                                nested_prop_enum_pos[nested_prop_count] = nenpw
                            }
                        }
                        let nconstp = findKey(sch_sp, sch_len, nss, "const")
                        if nconstp < sch_len { nested_prop_has_const[nested_prop_count] = true; nested_prop_const_pos[nested_prop_count] = nconstp }
                    }
                    np = skipJsonValue(sch_sp, sch_len, nss)
                    np = skipWS(sch_sp, sch_len, np)
                    if np < sch_len && sch_sp[np] == 44 { np = np + 1 }
                    nested_prop_count = nested_prop_count + 1
                }
            }
        }
    }
}
```

---

## Validate phase changes

After the `const` check block (line ~729 in v0.1.6) but still inside `if matched_prop < 255`, add a depth-2 inner scan when this property matches the nested parent:

```
// Depth-2 validation: scan nested object properties
if matched_prop == nested_parent_idx {
    let nds = skipWS(dat_sp, dat_len, data_val_pos)
    if nds < dat_len && dat_sp[nds] == 123 {
        let mut ndp = nds + 1
        while ndp < dat_len {
            ndp = skipWS(dat_sp, dat_len, ndp)
            if ndp >= dat_len || dat_sp[ndp] == 125 { ndp = dat_len }
            else if dat_sp[ndp] != 34 { ndp = dat_len }
            else {
                let nkp = ndp
                ndp = skipJsonString(dat_sp, dat_len, ndp)
                ndp = skipWS(dat_sp, dat_len, ndp)
                if ndp >= dat_len || dat_sp[ndp] != 58 { ndp = dat_len }
                else {
                    ndp = ndp + 1; ndp = skipWS(dat_sp, dat_len, ndp)
                    let nvp = ndp

                    // Match nested prop
                    let mut npi: usize = 0; let mut nm: usize = 255
                    while npi < nested_prop_count {
                        if jsonStrEq(sch_sp, sch_len, nested_prop_key_pos[npi], dat_sp, dat_len, nkp) {
                            nm = npi; npi = nested_prop_count
                        }
                        npi = npi + 1
                    }

                    if nm < 255 {
                        let enc = 64 + matched_prop * 8 + nm
                        let npt = nested_prop_type[nm]
                        if npt != 0 {
                            let nvjt = detectValueType(dat_sp, dat_len, nvp)
                            let mut nvt: u8 = 0
                            if nvjt == 1 { nvt = 1 } if nvjt == 2 { nvt = 7 }
                            if nvjt == 3 { nvt = 2 } if nvjt == 4 { nvt = 3 }
                            if nvjt == 5 { nvt = 5 } if nvjt == 6 { nvt = 6 }
                            if typeCompatible(npt, nvt) == false {
                                if err_count < 16 { err_codes[err_count] = 2; err_prop_idx[err_count] = enc; err_count = err_count + 1 }
                            } else {
                                if npt == 2 && nvt == 2 {
                                    let nsl = jsonStringLen(dat_sp, dat_len, nvp) as i64
                                    if nested_prop_min_len[nm] >= 0 && nsl < nested_prop_min_len[nm] {
                                        if err_count < 16 { err_codes[err_count] = 3; err_prop_idx[err_count] = enc; err_count = err_count + 1 }
                                    }
                                    if nested_prop_max_len[nm] >= 0 && nsl > nested_prop_max_len[nm] {
                                        if err_count < 16 { err_codes[err_count] = 4; err_prop_idx[err_count] = enc; err_count = err_count + 1 }
                                    }
                                }
                                if (npt == 3 || npt == 4) && nvt == 3 {
                                    let nnv = jsonParseInt(dat_sp, dat_len, nvp)
                                    if nested_prop_has_min[nm] && nnv < nested_prop_minimum[nm] {
                                        if err_count < 16 { err_codes[err_count] = 5; err_prop_idx[err_count] = enc; err_count = err_count + 1 }
                                    }
                                    if nested_prop_has_max[nm] && nnv > nested_prop_maximum[nm] {
                                        if err_count < 16 { err_codes[err_count] = 6; err_prop_idx[err_count] = enc; err_count = err_count + 1 }
                                    }
                                }
                                if nested_prop_has_enum[nm] {
                                    let nea = nested_prop_enum_pos[nm]
                                    let mut nep = nea + 1; let mut nem = false
                                    while nep < sch_len && nem == false {
                                        nep = skipWS(sch_sp, sch_len, nep)
                                        if nep >= sch_len || sch_sp[nep] == 93 { nep = sch_len }
                                        else {
                                            let ndvt2 = detectValueType(dat_sp, dat_len, nvp)
                                            let nevt2 = detectValueType(sch_sp, sch_len, nep)
                                            if ndvt2 == 3 && nevt2 == 3 {
                                                if jsonStrEq(dat_sp, dat_len, nvp, sch_sp, sch_len, nep) { nem = true }
                                            }
                                            if ndvt2 != 3 && ndvt2 == nevt2 {
                                                let ds2 = skipWS(dat_sp, dat_len, nvp); let de2 = skipJsonValue(dat_sp, dat_len, nvp)
                                                let es2 = skipWS(sch_sp, sch_len, nep); let ee2 = skipJsonValue(sch_sp, sch_len, nep)
                                                let dl2 = de2 - ds2; let el2 = ee2 - es2
                                                if dl2 == el2 {
                                                    let mut bi2: usize = 0; let mut bm2 = true
                                                    while bi2 < dl2 && bm2 {
                                                        if dat_sp[ds2 + bi2] != sch_sp[es2 + bi2] { bm2 = false }
                                                        bi2 = bi2 + 1
                                                    }
                                                    if bm2 { nem = true }
                                                }
                                            }
                                            nep = skipJsonValue(sch_sp, sch_len, nep); nep = skipWS(sch_sp, sch_len, nep)
                                            if nep < sch_len && sch_sp[nep] == 44 { nep = nep + 1 }
                                        }
                                    }
                                    if nem == false {
                                        if err_count < 16 { err_codes[err_count] = 7; err_prop_idx[err_count] = enc; err_count = err_count + 1 }
                                    }
                                }
                            }
                        }
                        if nested_prop_has_const[nm] {
                            let ncvp = nested_prop_const_pos[nm]; let ncws = skipWS(sch_sp, sch_len, ncvp)
                            let ndvt3 = detectValueType(dat_sp, dat_len, nvp); let ncvt3 = detectValueType(sch_sp, sch_len, ncws)
                            let mut ncm = false
                            if ndvt3 == 3 && ncvt3 == 3 { if jsonStrEq(dat_sp, dat_len, nvp, sch_sp, sch_len, ncws) { ncm = true } }
                            if ndvt3 != 3 && ndvt3 == ncvt3 {
                                let ds3 = skipWS(dat_sp, dat_len, nvp); let de3 = skipJsonValue(dat_sp, dat_len, nvp)
                                let cs3 = skipWS(sch_sp, sch_len, ncws); let ce3 = skipJsonValue(sch_sp, sch_len, ncws)
                                let dl3 = de3 - ds3; let cl3 = ce3 - cs3
                                if dl3 == cl3 {
                                    let mut bi3: usize = 0; let mut bm3 = true
                                    while bi3 < dl3 && bm3 {
                                        if dat_sp[ds3 + bi3] != sch_sp[cs3 + bi3] { bm3 = false }
                                        bi3 = bi3 + 1
                                    }
                                    if bm3 { ncm = true }
                                }
                            }
                            if ncm == false {
                                if err_count < 16 { err_codes[err_count] = 10; err_prop_idx[err_count] = enc; err_count = err_count + 1 }
                            }
                        }
                    }

                    ndp = skipJsonValue(dat_sp, dat_len, nvp); ndp = skipWS(dat_sp, dat_len, ndp)
                    if ndp < dat_len && dat_sp[ndp] == 44 { ndp = ndp + 1 }
                }
            }
        }
    }
}
```

---

## Error emission changes

In the error path-emission section, insert a new branch BEFORE the existing `if pidx >= 128` check:

```
if pidx >= 64 && pidx < 128 {
    // Depth-2 error: $.parent_key.child_key
    // Find parent index by linear scan (avoids division operator)
    let mut pi3: usize = 0
    let mut n_parent_found = false
    while pi3 < prop_count && n_parent_found == false {
        let base = 64 + pi3 * 8
        if pidx >= base && pidx < base + 8 {
            // pi3 is the parent; nested_idx = pidx - base
            let nested_idx = pidx - base
            // Emit parent key from prop_key_pos[pi3]
            let pk3 = prop_key_pos[pi3]
            let pk3p = skipWS(sch_sp, sch_len, pk3)
            if pk3p < sch_len && sch_sp[pk3p] == 34 {
                let mut pk3q = pk3p + 1
                while pk3q < sch_len {
                    let b3 = sch_sp[pk3q]
                    if b3 == 34 { pk3q = sch_len }
                    else if b3 == 92 {
                        pk3q = pk3q + 1
                        if pk3q < sch_len { fn_cb[0] = 92; check world.out.write(fn_cb); fn_cb[0] = sch_sp[pk3q]; check world.out.write(fn_cb); pk3q = pk3q + 1 }
                    } else { fn_cb[0] = b3; check world.out.write(fn_cb); pk3q = pk3q + 1 }
                }
            }
            check world.out.write(".")
            // Emit child key from nested_prop_key_pos[nested_idx]
            if nested_idx < nested_prop_count {
                let ck3 = nested_prop_key_pos[nested_idx]
                let ck3p = skipWS(sch_sp, sch_len, ck3)
                if ck3p < sch_len && sch_sp[ck3p] == 34 {
                    let mut ck3q = ck3p + 1
                    while ck3q < sch_len {
                        let b4 = sch_sp[ck3q]
                        if b4 == 34 { ck3q = sch_len }
                        else if b4 == 92 {
                            ck3q = ck3q + 1
                            if ck3q < sch_len { fn_cb[0] = 92; check world.out.write(fn_cb); fn_cb[0] = sch_sp[ck3q]; check world.out.write(fn_cb); ck3q = ck3q + 1 }
                        } else { fn_cb[0] = b4; check world.out.write(fn_cb); ck3q = ck3q + 1 }
                    }
                }
            }
            n_parent_found = true
        }
        pi3 = pi3 + 1
    }
} else {
    // existing pidx >= 128 ... else ... branches
}
```

---

## Eval cases for v0.1.7

**EC-27**: nested valid — `{"type":"object","properties":{"user":{"type":"object","properties":{"name":{"type":"string","minLength":1}}}}}` against `{"user":{"name":"Alice"}}` → `valid:true`

**EC-28**: nested type mismatch — same schema, data `{"user":{"name":42}}` → `valid:false`, `CONST_MISMATCH`... no, `TYPE_MISMATCH`, path=`$.user.name`

**EC-29**: nested minLength — same schema, data `{"user":{"name":""}}` → `valid:false`, `MIN_LENGTH`, path=`$.user.name`

---

## Security surface (RT-147 pre-analysis)

- **OOB risk**: `nested_idx = pidx - base` where `base = 64 + pi3 * 8`. If `pi3` is the correct parent, `nested_idx` is in `[0, 7]`, which is valid index into `[8]usize` arrays. `pi3` is bounded by `prop_count < 8`, so `base` is in `[64, 120]`. Since `pidx` is stored as `64 + matched_prop * 8 + nm` where both `matched_prop < 8` and `nm < 8`, the range is `[64, 127]`. At emission time, `pi3 * 8 + 64 <= pidx < pi3 * 8 + 72` means `nested_idx = pidx - base` is in `[0, 7]`. SAFE.

- **First-property-only limit**: `nested_parent_idx` stores only one parent. If a schema has multiple object-typed properties, the second one's sub-properties are silently ignored. No OOB — just a coverage gap. P3 documented limitation.

- **Nested data value not an object**: If schema has `type:object` for a parent property but data value is not an object (type mismatch already emitted), the depth-2 scan is still attempted (`if matched_prop == nested_parent_idx`). The check `if nds < dat_len && dat_sp[nds] == 123` gates entry into the inner scan. If data value is not `{`, the scan is skipped. SAFE.

---

## Version bump

- Version: `0.1.6` → `0.1.7`
- New eval cases: EC-27, EC-28, EC-29 (nested valid, nested type mismatch, nested minLength)
- Total: 29 eval cases
- `--describe` flags description updated to include "nested properties (depth 2)"
