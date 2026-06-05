---
description: Verify the HEROS tamper-evident audit chain and explain the result
---

Use the `heros-audit` MCP server to check the integrity of the append-only,
hash-chained audit log.

Steps:
1. Call `audit_verify`.
2. If `valid` is true, report the chain is intact and how many entries were
   verified (`total_count`).
3. If `valid` is false, report `broken_at_entry` — the index where
   `sha256(prev_hash + entry_json)` stopped matching the stored `chain_hash`.
   Explain that this means a logged entry was altered, inserted, or removed after
   the fact, and that the break point is the first tampered link.
4. Offer to call `audit_list` to show recent entries around the break for
   investigation. Do not attempt to "repair" the chain — a tamper-evident log is
   meant to surface tampering, not hide it.
