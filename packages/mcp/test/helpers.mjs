// SPDX-License-Identifier: MIT
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { createMcpServer, createSession } from "../src/server.js";

process.env.HEROS_API_KEY = "";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..", "..");

export async function loadManifests() {
  const [forge, ledger] = await Promise.all([
    readFile(join(repoRoot, "forge", "mcp-manifest.json"), "utf8"),
    readFile(join(repoRoot, "ledger", "mcp-manifest.json"), "utf8"),
  ]);
  return { forgeManifest: JSON.parse(forge), ledgerManifest: JSON.parse(ledger) };
}

export function createFakeForge() {
  return async (args) => {
    const fromIndex = args.indexOf("--from");
    const toIndex = args.indexOf("--to");
    const from = fromIndex >= 0 ? args[fromIndex + 1] : "";
    const to = toIndex >= 0 ? args[toIndex + 1] : "";
    const requestIdIndex = args.indexOf("--request-id");
    const requestId =
      requestIdIndex >= 0 ? args[requestIdIndex + 1] : undefined;
    const destructive = to.includes("DROP") || from.includes("DROP");

    return JSON.stringify({
      schema_version: 1,
      risk_tier: destructive ? "CRITICAL" : "SAFE",
      risk_score: destructive ? 0.97 : 0,
      retryable: false,
      has_data_loss: destructive,
      decision_required: destructive,
      ...(requestId ? { request_id: requestId } : {}),
      operations: [],
    });
  };
}

export function createFakeLedger() {
  let sequence = 0;
  return async (args) => {
    if (args[0] === "register") {
      const orgName = args[args.indexOf("--org-name") + 1];
      const entropy = args[args.indexOf("--entropy") + 1];
      const timestamp = Number(args[args.indexOf("--timestamp") + 1]);
      const orgId = `org_${entropy.slice(0, 8)}`;
      const data = {
        org_id: orgId,
        org_name: orgName,
        created_at: timestamp,
      };
      return JSON.stringify({
        status: "ok",
        org_id: orgId,
        org_name: orgName,
        _new_data: JSON.stringify(data),
      });
    }

    if (args[0] === "invoice" && args[1] === "create") {
      const value = (flag) => {
        const index = args.indexOf(flag);
        return index >= 0 ? args[index + 1] : undefined;
      };
      const timestamp = Number(value("--timestamp"));
      const entropy = value("--entropy");
      sequence += 1;
      const invoice = {
        invoice_id: `inv_${entropy}${sequence}`,
        to: value("--to"),
        amount: Number(value("--amount")),
        currency: value("--currency"),
        idempotency_key: value("--idempotency-key"),
        ...(value("--memo") ? { memo: value("--memo") } : {}),
        created_at: timestamp,
      };
      return JSON.stringify({
        status: "ok",
        invoice_id: invoice.invoice_id,
        _new_invoice_json: JSON.stringify(invoice),
      });
    }

    throw new Error(`fake ledger does not implement ${args.join(" ")}`);
  };
}

export async function makeHarness(options = {}) {
  const dataDir = await mkdtemp(join(tmpdir(), "heros-mcp-"));
  const manifests = await loadManifests();
  const server = createMcpServer({
    ...manifests,
    runForge: options.runForge ?? createFakeForge(),
    runLedger: options.runLedger ?? createFakeLedger(),
    dataDir,
    hmacSeed: options.hmacSeed,
    ...(options.rateLimiter ? { rateLimiter: options.rateLimiter } : {}),
  });
  const session = createSession({ id: options.sessionId ?? "test-session" });
  if (options.apiKey !== undefined) session.apiKey = options.apiKey;

  let counter = 0;
  async function rpc(method, params, target = session) {
    const message = {
      jsonrpc: "2.0",
      id: ++counter,
      method,
      ...(params === undefined ? {} : { params }),
    };
    return server.handleMessage(message, target);
  }

  async function call(name, args, target = session) {
    const response = await rpc(
      "tools/call",
      { name, arguments: args },
      target
    );
    if (!response.result) throw new Error(JSON.stringify(response));
    return JSON.parse(response.result.content[0].text);
  }

  async function cleanup() {
    await rm(dataDir, { recursive: true, force: true });
  }

  return {
    dataDir,
    server,
    session,
    rpc,
    call,
    cleanup,
    manifests,
  };
}
