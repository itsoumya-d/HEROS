# Receipt Inspector

Static, dependency-free verifier for HEROS Merkle receipt logs.

```bash
# 1. Generate sample receipts from the real SDK (writes sample-receipts.json)
node packages/mcp/ui/build-sample.mjs

# 2. Inject the sample into the self-contained HTML
node packages/mcp/ui/build-inspector.mjs

# 3. Run the Playwright smoke audit (requires a global Playwright + Chromium)
node packages/mcp/ui/audit-browser.mjs
```

Open `receipt-inspector.html` directly, or serve the directory:

```bash
python3 -m http.server 8080 --directory packages/mcp/ui
```

## What it verifies

- Recomputes each leaf from the unsigned receipt projection.
- Checks `entry_hash` and the `prev_hash` chain.
- Recomputes the SHA-256 Merkle root and compares it with the log tail.
- Verifies each receipt's inclusion proof against the current root.
- Recomputes `deliberation_hash` from the deliberation trace.
- Loading a tampered log flips the integrity banner to failed and lists the
  failing receipt.

All hashing happens in the browser with Web Crypto. No receipt data is sent to
a server. The inspector is read-only.

## Evidence

`audit-browser.mjs` writes screenshots to `artifacts/`:

- `receipt-inspector-desktop.png` (1440×900)
- `receipt-inspector-tablet.png` (768×1024)
- `receipt-inspector-mobile.png` (390×844)
- `receipt-inspector-tampered.png`

The audit checks 44px interactive targets, horizontal overflow, console errors,
and tamper detection. Source-level checks live in
`packages/mcp/test/ui.test.mjs`.
