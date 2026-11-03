// SPDX-License-Identifier: MIT

import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";

const CORPUS = new URL("../corpus/corpus.jsonl", import.meta.url);
const MANIFEST = new URL("../corpus/manifest.json", import.meta.url);
const VERDICTS = new Set([
  "bounded",
  "bounded_or_error",
  "rejected",
  "INVALID_INPUT",
  "UNKNOWN_ACTION",
  "OK",
  "INVALID_API_KEY",
  "API_KEY_REVOKED",
  "NO_ORG_REGISTERED",
  "INSUFFICIENT_SCOPE",
  "INVALID_ACKNOWLEDGMENT_TOKEN",
  "DECISION_REQUIRED"
]);

test("committed corpus matches its manifest", async () => {
  const manifest = JSON.parse(await readFile(MANIFEST, "utf8"));
  const text = await readFile(CORPUS, "utf8");
  const lines = text.split(/\r?\n/).filter(Boolean);
  const records = lines.map((line) => JSON.parse(line));

  assert.equal(manifest.case_count, 500);
  assert.equal(records.length, 500);
  assert.equal(
    createHash("sha256").update(`${lines.join("\n")}\n`).digest("hex"),
    manifest.sha256
  );

  const ids = new Set();
  for (const record of records) {
    assert.equal(typeof record.case_id, "string");
    assert.equal(ids.has(record.case_id), false, `duplicate ${record.case_id}`);
    ids.add(record.case_id);
    assert.equal(VERDICTS.has(record.expected), true, record.case_id);
    assert.ok(record.input !== undefined, record.case_id);
    assert.ok(record.group && record.surface && record.source, record.case_id);
    assert.ok(Array.isArray(record.asi) && record.asi.length > 0, record.case_id);
    const token = record.input?.human_acknowledgment_token;
    if (token && typeof token === "object" && token.$runtime) {
      assert.equal(typeof record.setup, "object", `${record.case_id} setup`);
      assert.equal(record.setup.kind, "approval_replay");
    }
  }
  assert.equal(ids.size, 500);

  const groupCounts = {};
  const surfaceCounts = {};
  const asiCounts = {};
  for (const record of records) {
    groupCounts[record.group] = (groupCounts[record.group] ?? 0) + 1;
    surfaceCounts[record.surface] = (surfaceCounts[record.surface] ?? 0) + 1;
    for (const tag of record.asi) {
      asiCounts[tag] = (asiCounts[tag] ?? 0) + 1;
    }
  }

  for (const group of manifest.groups) {
    assert.equal(groupCounts[group.name], group.count, group.name);
  }
  assert.deepEqual(surfaceCounts, manifest.surfaces);
  assert.deepEqual(
    Object.fromEntries(
      Object.entries(asiCounts).sort(([left], [right]) => left.localeCompare(right))
    ),
    manifest.asi
  );

  assert.equal(text.includes("C:\\Users"), false);
  assert.equal(text.includes("AppData"), false);
});
