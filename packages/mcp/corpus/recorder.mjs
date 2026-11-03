// SPDX-License-Identifier: MIT
// Optional recorder used by the adversarial tests. When HEROS_CORPUS_DIR is
// set, each process writes its own JSONL file. Without the env var this is a
// no-op, so normal test runs are unchanged.

import { appendFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const outputDir = process.env.HEROS_CORPUS_DIR;
const outputPath = outputDir ? join(outputDir, `${process.pid}.jsonl`) : null;
let directoryReady = false;

function encode(value) {
  if (value === undefined) return { $undefined: true };
  if (typeof value === "number" && !Number.isFinite(value)) {
    return { $number: String(value) };
  }
  if (Array.isArray(value)) return value.map(encode);
  if (value && typeof value === "object") {
    const encoded = {};
    for (const [key, item] of Object.entries(value)) {
      encoded[key] = encode(item);
    }
    return encoded;
  }
  return value;
}

export function recordCase({
  group,
  index,
  surface,
  asi,
  source,
  input,
  expected,
  allowedErrorCodes,
  setup
}) {
  if (!outputPath) return;
  if (!directoryReady) {
    mkdirSync(outputDir, { recursive: true });
    directoryReady = true;
  }
  const record = {
    case_id: `${group}-${String(index + 1).padStart(3, "0")}`,
    group,
    surface,
    asi,
    source,
    input: encode(input),
    expected
  };
  if (allowedErrorCodes) {
    record.allowed_error_codes = allowedErrorCodes;
  }
  if (setup) {
    record.setup = setup;
  }
  appendFileSync(outputPath, `${JSON.stringify(record)}\n`);
}
