// Playwright smoke audit for the static Receipt Inspector.
// Requires a globally installed Playwright with Chromium.
// Run: node packages/mcp/ui/audit-browser.mjs

import { createServer } from "node:http";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { mkdir, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import assert from "node:assert/strict";

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const globalRoot = execFileSync("npm", ["root", "-g"], { encoding: "utf8" }).trim();
const { chromium } = require(join(globalRoot, "playwright"));

const allowed = new Set(["receipt-inspector.html", "sample-receipts.json"]);
const server = createServer(async (request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  const file = url.pathname === "/" ? "receipt-inspector.html" : url.pathname.slice(1);
  if (!allowed.has(file)) {
    response.writeHead(404);
    response.end("not found");
    return;
  }
  try {
    const body = await readFile(join(here, file));
    response.writeHead(200, {
      "content-type": file.endsWith(".html")
        ? "text/html; charset=utf-8"
        : "application/json; charset=utf-8"
    });
    response.end(body);
  } catch (error) {
    response.writeHead(500);
    response.end(String(error));
  }
});

await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const port = server.address().port;
const base = `http://127.0.0.1:${port}/`;
const artifacts = join(here, "artifacts");
await mkdir(artifacts, { recursive: true });

const browser = await chromium.launch({ headless: true });
const results = [];

try {
  for (const viewport of [
    { width: 1440, height: 900, name: "desktop" },
    { width: 768, height: 1024, name: "tablet" },
    { width: 390, height: 844, name: "mobile" }
  ]) {
    const page = await browser.newPage({ viewport });
    const errors = [];
    page.on("console", (message) => {
      if (message.type() === "error") errors.push(`console: ${message.text()}`);
    });
    page.on("pageerror", (error) => errors.push(`pageerror: ${error.message}`));

    await page.goto(base, { waitUntil: "networkidle" });
    await page.waitForFunction(() =>
      document.querySelector("#integrity")?.textContent.includes("Integrity verified")
    );

    assert.equal(await page.locator("#metric-count").textContent(), "3");
    assert.equal(await page.locator("#metric-failures").textContent(), "0");

    await page.getByRole("button", { name: /migration\.apply/ }).click();
    await page.waitForFunction(() =>
      document.querySelector("#detail")?.textContent.includes("proof valid")
    );

    await page.getByRole("button", { name: "Verify log" }).click();
    await page.waitForFunction(() =>
      document.querySelector("#integrity")?.textContent.includes("Integrity verified")
    );

    const smallTargets = await page.evaluate(() =>
      [...document.querySelectorAll("button, select, input[type='search']")]
        .filter((element) => element.getBoundingClientRect().height < 43.5)
        .map((element) => element.outerHTML.slice(0, 100))
    );
    assert.deepEqual(smallTargets, [], `undersized targets at ${viewport.name}`);

    const overflow = await page.evaluate(() =>
      document.documentElement.scrollWidth > window.innerWidth + 1
    );
    assert.equal(overflow, false, `horizontal overflow at ${viewport.name}`);

    await page.screenshot({
      path: join(artifacts, `receipt-inspector-${viewport.name}.png`),
      fullPage: true
    });

    assert.deepEqual(errors, [], `browser errors at ${viewport.name}`);
    results.push({ viewport: `${viewport.width}x${viewport.height}`, ok: true });
    await page.close();
  }

  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const sample = JSON.parse(await readFile(join(here, "sample-receipts.json"), "utf8"));
  const tampered = JSON.parse(JSON.stringify(sample));
  tampered.receipts[0].result_hash = "0".repeat(64);

  await page.goto(base, { waitUntil: "networkidle" });
  await page.setInputFiles("#receipt-file", {
    name: "tampered.json",
    mimeType: "application/json",
    buffer: Buffer.from(JSON.stringify(tampered))
  });
  await page.waitForFunction(() =>
    document.querySelector("#integrity")?.textContent.includes("Integrity failed")
  );
  const failures = Number(await page.locator("#metric-failures").textContent());
  assert.ok(failures > 0, "tampered log must report at least one failure");
  await page.screenshot({
    path: join(artifacts, "receipt-inspector-tampered.png"),
    fullPage: true
  });
  results.push({ viewport: "tamper", ok: true, failures });
  await page.close();
} finally {
  await browser.close();
  server.close();
}

console.log(JSON.stringify({ ok: true, results }, null, 2));
