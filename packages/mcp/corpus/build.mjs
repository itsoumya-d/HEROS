// SPDX-License-Identifier: MIT
// Build the standalone P02 adversarial corpus from the executable tests.
//
// The tests remain the source of truth. When HEROS_CORPUS_OUT is set, each
// case appends one record. This script runs both test files, validates the 500
// records, and writes corpus.jsonl plus manifest.json. With --check it
// regenerates into a temporary file and fails if the committed files are stale.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const corpusDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(corpusDir, "..", "..", "..");
const check = process.argv.includes("--check");

const GROUPS = [
  { name: "jsonrpc-base", surface: "jsonrpc", asi: ["ASI05", "ASI09"], count: 60, source: "adversarial.test.mjs" },
  { name: "agentic-base", surface: "agentic", asi: ["ASI01", "ASI02"], count: 78, source: "adversarial.test.mjs" },
  { name: "auth-base", surface: "auth", asi: ["ASI03", "ASI10"], count: 31, source: "adversarial.test.mjs" },
  { name: "forge-base", surface: "forge", asi: ["ASI05", "ASI06"], count: 60, source: "adversarial.test.mjs" },
  { name: "shadow-base", surface: "shadow", asi: ["ASI05"], count: 30, source: "adversarial.test.mjs" },
  { name: "approval-base", surface: "approval", asi: ["ASI02", "ASI07"], count: 30, source: "adversarial.test.mjs" },
  { name: "jsonrpc-extra", surface: "jsonrpc", asi: ["ASI05", "ASI09"], count: 40, source: "corpus211.test.mjs" },
  { name: "agentic-extra", surface: "agentic", asi: ["ASI01", "ASI02"], count: 30, source: "corpus211.test.mjs" },
  { name: "auth-extra", surface: "auth", asi: ["ASI03", "ASI10"], count: 25, source: "corpus211.test.mjs" },
  { name: "forge-extra", surface: "forge", asi: ["ASI05", "ASI06"], count: 30, source: "corpus211.test.mjs" },
  { name: "shadow-extra", surface: "shadow", asi: ["ASI05"], count: 30, source: "corpus211.test.mjs" },
  { name: "approval-extra", surface: "approval", asi: ["ASI02", "ASI07"], count: 30, source: "corpus211.test.mjs" },
  { name: "destructive-gate", surface: "destructive", asi: ["ASI08", "ASI09"], count: 26, source: "corpus211.test.mjs" }
];

const EXPECTED_VERDICTS = new Set([
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

function fail(message) {
  console.error(message);
  process.exitCode = 1;
}

const tempDir = await mkdtemp(join(tmpdir(), "heros-corpus-"));

const testFiles = [
  "packages/mcp/test/adversarial.test.mjs",
  "packages/mcp/test/corpus211.test.mjs"
];
const run = spawnSync(
  process.execPath,
  ["--test", ...testFiles],
  {
    cwd: repoRoot,
    env: { ...process.env, HEROS_CORPUS_DIR: tempDir },
    encoding: "utf8",
    timeout: 120_000
  }
);

if (run.status !== 0) {
  console.error(run.stdout || "");
  console.error(run.stderr || "");
  fail(`corpus test run failed with status ${run.status}`);
  process.exit(1);
}

const workerFiles = (await readdir(tempDir))
  .filter((name) => name.endsWith(".jsonl"))
  .sort();
const raw = (
  await Promise.all(
    workerFiles.map((name) => readFile(join(tempDir, name), "utf8"))
  )
).join("");
const records = raw
  .split(/\r?\n/)
  .filter(Boolean)
  .map((line, index) => {
    try {
      return JSON.parse(line);
    } catch {
      throw new Error(`invalid JSONL at line ${index + 1}`);
    }
  });

if (records.length !== 500) {
  fail(`expected 500 records, found ${records.length}`);
  process.exit(1);
}

const byId = new Set();
const byGroup = new Map(GROUPS.map((group) => [group.name, []]));
for (const record of records) {
  if (typeof record.case_id !== "string" || byId.has(record.case_id)) {
    fail(`missing or duplicate case_id: ${record.case_id}`);
  }
  byId.add(record.case_id);
  if (!byGroup.has(record.group)) {
    fail(`unknown group: ${record.group}`);
    continue;
  }
  if (!EXPECTED_VERDICTS.has(record.expected)) {
    fail(`unexpected verdict for ${record.case_id}: ${record.expected}`);
  }
  byGroup.get(record.group).push(record);
}

for (const group of GROUPS) {
  const groupRecords = byGroup.get(group.name);
  if (groupRecords.length !== group.count) {
    fail(`${group.name}: expected ${group.count}, found ${groupRecords.length}`);
  }
  for (const record of groupRecords) {
    if (
      record.surface !== group.surface ||
      record.source !== group.source ||
      record.asi.join(",") !== group.asi.join(",")
    ) {
      fail(`${record.case_id}: metadata does not match group ${group.name}`);
    }
  }
}

const ordered = GROUPS.flatMap((group) =>
  byGroup
    .get(group.name)
    .slice()
    .sort((left, right) => left.case_id.localeCompare(right.case_id))
);
const corpusText = `${ordered.map((record) => JSON.stringify(record)).join("\n")}\n`;

const surfaces = {};
const asiCounts = {};
for (const record of ordered) {
  surfaces[record.surface] = (surfaces[record.surface] ?? 0) + 1;
  for (const tag of record.asi) {
    asiCounts[tag] = (asiCounts[tag] ?? 0) + 1;
  }
}

const manifest = {
  schema_version: 1,
  name: "heros-adversarial-corpus",
  version: "1.0.0",
  case_count: ordered.length,
  source_tests: testFiles,
  groups: GROUPS.map((group) => ({
    name: group.name,
    surface: group.surface,
    asi: group.asi,
    count: group.count,
    source: group.source
  })),
  surfaces,
  asi: Object.fromEntries(
    Object.entries(asiCounts).sort(([left], [right]) => left.localeCompare(right))
  ),
  sha256: createHash("sha256").update(corpusText).digest("hex")
};
const manifestText = `${JSON.stringify(manifest, null, 2)}\n`;

if (check) {
  const existingCorpus = await readFile(join(corpusDir, "corpus.jsonl"), "utf8").catch(() => null);
  const existingManifest = await readFile(join(corpusDir, "manifest.json"), "utf8").catch(() => null);
  if (existingCorpus !== corpusText || existingManifest !== manifestText) {
    fail("corpus files are stale; run: npm run corpus:build");
    process.exit(1);
  }
  console.log(`corpus check passed: ${ordered.length} cases, sha256 ${manifest.sha256}`);
} else {
  await mkdir(corpusDir, { recursive: true });
  await writeFile(join(corpusDir, "corpus.jsonl"), corpusText);
  await writeFile(join(corpusDir, "manifest.json"), manifestText);
  console.log(`wrote ${ordered.length} cases to ${join(corpusDir, "corpus.jsonl")}`);
  console.log(`sha256 ${manifest.sha256}`);
}

await rm(tempDir, { recursive: true, force: true });
