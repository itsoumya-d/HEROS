// Injects the generated sample receipts into the self-contained inspector.
// Run: node packages/mcp/ui/build-inspector.mjs

import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const template = await readFile(join(here, "receipt-inspector.template.html"), "utf8");
const sample = await readFile(join(here, "sample-receipts.json"), "utf8");

if (!template.includes("__SAMPLE_RECEIPTS__")) {
  throw new Error("template is missing the __SAMPLE_RECEIPTS__ placeholder");
}

await writeFile(
  join(here, "receipt-inspector.html"),
  template.replace("__SAMPLE_RECEIPTS__", sample.trim())
);
console.log("wrote packages/mcp/ui/receipt-inspector.html");
