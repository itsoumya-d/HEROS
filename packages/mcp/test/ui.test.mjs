// SPDX-License-Identifier: MIT
// Source-level baseline checks for the static Receipt Inspector. These are
// explicitly source checks, not a WCAG certification; browser behavior is
// covered by ui/audit-browser.mjs when Playwright is available.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const uiDir = join(here, "..", "ui");

test("receipt inspector meets the baseline-ui source constraints", async () => {
  const html = await readFile(join(uiDir, "receipt-inspector.html"), "utf8");

  assert.match(html, /data-df-color-scale="detailed"/);
  assert.match(html, /data-df-density="compact"/);
  assert.match(html, /100dvh/);
  assert.doesNotMatch(html, /\bh-screen\b/);
  assert.doesNotMatch(html, /\btracking-/);
  assert.doesNotMatch(html, /letter-spacing/);
  assert.doesNotMatch(html, /backdrop-filter/);
  assert.doesNotMatch(html, /blur\(/);
  assert.doesNotMatch(html, /will-change/);
  assert.doesNotMatch(html, /useEffect/);
  assert.match(html, /env\(safe-area-inset/);
  assert.match(html, /prefers-reduced-motion/);
  assert.match(html, /text-wrap:\s*balance/);
  assert.match(html, /text-wrap:\s*pretty/);
  assert.match(html, /font-variant-numeric:\s*tabular-nums/);
  assert.match(html, /@container/);
  assert.match(html, /:focus-visible/);
  assert.match(html, /min-block-size:\s*44px/);
  assert.match(html, /<label[^>]+for="receipt-file"/);
  assert.match(html, /<label[^>]+for="filter-action"/);
  assert.match(html, /<label[^>]+for="filter-search"/);
  assert.match(html, /role="status"/);
  assert.match(html, /aria-live="polite"/);
  assert.match(html, /aria-pressed=/);
  assert.match(html, /aria-label="Copy/);
  assert.doesNotMatch(html, /https?:\/\//);
});

test("embedded sample is a valid three-receipt Merkle log", async () => {
  const raw = await readFile(join(uiDir, "sample-receipts.json"), "utf8");
  const payload = JSON.parse(raw);
  assert.equal(payload.schema_version, 2);
  assert.equal(payload.receipts.length, 3);
  assert.match(payload.merkle_root, /^[0-9a-f]{64}$/);
  assert.equal(payload.receipts[2].merkle_root, payload.merkle_root);
  assert.equal(payload.receipts[0].prev_hash, "0".repeat(64));
  assert.equal(
    payload.receipts[0].entry_hash,
    payload.receipts[1].prev_hash
  );
  assert.equal(
    payload.receipts[1].entry_hash,
    payload.receipts[2].prev_hash
  );
  assert.equal(payload.receipts[1].deliberation.triggered, true);
  assert.equal(
    payload.receipts[1].deliberation_hash,
    payload.receipts[1].deliberation.trace_hash
  );
  assert.equal(payload.receipts[2].idempotency_key, "invoice-demo-001");
});
