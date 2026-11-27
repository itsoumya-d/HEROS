#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2026 Soumya Debnath

import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import { createMcpServer, SERVER_VERSION } from "../src/server.js";
import { createHttpServer } from "../src/http.js";
import { runStdio } from "../src/stdio.js";

const execFileAsync = promisify(execFile);
const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..", "..", "..");

function printHelp() {
  process.stderr.write(`HEROS MCP bridge ${SERVER_VERSION}

Usage:
  heros-mcp [--stdio] [--data-dir <dir>] [--forge-bin <path>] [--ledger-bin <path>]
  heros-mcp --http [--host 127.0.0.1] [--port 8787] [options]

Transports:
  --stdio              JSON-RPC over stdin/stdout (default)
  --http               Streamable HTTP at /mcp, health at /healthz

Options:
  --host <host>        HTTP bind host (default 127.0.0.1)
  --port <port>        HTTP port, 0 picks a free port (default 8787)
  --data-dir <dir>     Ledger state directory (default $HEROS_DATA_DIR or cwd)
  --forge-bin <path>   forge executable (default $HEROS_FORGE_BIN or "forge")
  --ledger-bin <path>  ledger executable (default $HEROS_LEDGER_BIN or "ledger")
  --help               Show this help
  --version            Print the bridge version

Environment:
  HEROS_DATA_DIR, HEROS_FORGE_BIN, HEROS_LEDGER_BIN, FORGE_BIN, LEDGER_BIN,
  HEROS_HMAC_SEED, HEROS_API_KEY, HEROS_MCP_ALLOW_ORIGIN

Examples:
  heros-mcp --stdio
  heros-mcp --http --port 8787 --data-dir ~/.heros
`);
}

function parseArgs(argv) {
  const options = {
    transport: "stdio",
    host: process.env.HEROS_MCP_HOST ?? "127.0.0.1",
    port: Number(process.env.HEROS_MCP_PORT ?? 8787),
    dataDir: process.env.HEROS_DATA_DIR ?? process.cwd(),
    forgeBin:
      process.env.HEROS_FORGE_BIN ??
      process.env.FORGE_BIN ??
      "forge",
    ledgerBin:
      process.env.HEROS_LEDGER_BIN ??
      process.env.LEDGER_BIN ??
      "ledger",
  };

  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index];
    const next = () => {
      const value = argv[++index];
      if (value === undefined) throw new Error(`Missing value for ${arg}`);
      return value;
    };

    switch (arg) {
      case "--stdio":
        options.transport = "stdio";
        break;
      case "--http":
        options.transport = "http";
        break;
      case "--host":
        options.host = next();
        break;
      case "--port":
        options.port = Number(next());
        if (!Number.isInteger(options.port) || options.port < 0 || options.port > 65535) {
          throw new Error("--port must be an integer between 0 and 65535");
        }
        break;
      case "--data-dir":
        options.dataDir = resolve(next());
        break;
      case "--forge-bin":
        options.forgeBin = next();
        break;
      case "--ledger-bin":
        options.ledgerBin = next();
        break;
      case "--help":
      case "-h":
        printHelp();
        process.exit(0);
        break;
      case "--version":
        process.stdout.write(`${SERVER_VERSION}\n`);
        process.exit(0);
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return options;
}

async function loadManifest(path, label) {
  let raw;
  try {
    raw = await readFile(path, "utf8");
  } catch {
    throw new Error(
      `${label} manifest not found at ${path}; set HEROS_${label.toUpperCase()}_MANIFEST`
    );
  }
  const manifest = JSON.parse(raw);
  if (!Array.isArray(manifest.tools)) {
    throw new Error(`${label} manifest has no tools array`);
  }
  return manifest;
}

function makeRunner(label, bin) {
  return async (args) => {
    try {
      const { stdout } = await execFileAsync(bin, args, {
        encoding: "utf8",
        timeout: 60_000,
        maxBuffer: 16 * 1024 * 1024,
        windowsHide: true,
      });
      return stdout;
    } catch (error) {
      if (error.code === "ENOENT") {
        throw new Error(
          `${label} binary not found (${bin}); set HEROS_${label.toUpperCase()}_BIN to its path`
        );
      }
      throw new Error(`${label} failed: ${error.message}`);
    }
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));

  const forgeManifestPath =
    process.env.HEROS_FORGE_MANIFEST ??
    join(repoRoot, "forge", "mcp-manifest.json");
  const ledgerManifestPath =
    process.env.HEROS_LEDGER_MANIFEST ??
    join(repoRoot, "ledger", "mcp-manifest.json");

  const [forgeManifest, ledgerManifest] = await Promise.all([
    loadManifest(forgeManifestPath, "forge"),
    loadManifest(ledgerManifestPath, "ledger"),
  ]);

  const server = createMcpServer({
    forgeManifest,
    ledgerManifest,
    runForge: makeRunner("forge", options.forgeBin),
    runLedger: makeRunner("ledger", options.ledgerBin),
    dataDir: options.dataDir,
  });

  if (options.transport === "stdio") {
    runStdio(server);
    return;
  }

  const httpServer = createHttpServer(server, {
    allowOrigin: process.env.HEROS_MCP_ALLOW_ORIGIN ?? "*",
  });
  const address = await httpServer.listen({
    host: options.host,
    port: options.port,
  });
  process.stderr.write(
    `HEROS MCP server listening at ${address.url} (health: http://${address.host}:${address.port}/healthz)\n`
  );

  const shutdown = async () => {
    await httpServer.close();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((error) => {
  process.stderr.write(`[heros-mcp] ${error.message}\n`);
  process.exit(1);
});
