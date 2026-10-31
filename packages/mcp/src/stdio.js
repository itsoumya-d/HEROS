// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2026 Soumya Debnath
//
// MCP stdio transport: one JSON-RPC message per line on stdin, one response per
// line on stdout. Diagnostics go to stderr so stdout stays machine-readable.

import readline from "node:readline";
import { createSession } from "./server.js";
import { rpcError } from "./errors.js";

const MAX_MESSAGE_BYTES = 1024 * 1024;

export function createStdioHandler(
  server,
  {
    session = createSession({ id: "stdio" }),
    write = (line) => process.stdout.write(`${line}\n`),
  } = {}
) {
  return async function handleLine(line) {
    if (!line || !line.trim()) return;
    if (Buffer.byteLength(line, "utf8") > MAX_MESSAGE_BYTES) {
      write(
        JSON.stringify(
          rpcError(null, -32001, "Message too large (max 1 MiB)")
        )
      );
      return;
    }

    let message;
    try {
      message = JSON.parse(line);
    } catch {
      write(
        JSON.stringify(
          rpcError(null, -32700, "Parse error: message is not valid JSON")
        )
      );
      return;
    }

    const response = await server.handleMessage(message, session);
    if (response) write(JSON.stringify(response));
  };
}

export function runStdio(server) {
  const handleLine = createStdioHandler(server);
  const input = readline.createInterface({
    input: process.stdin,
    crlfDelay: Infinity,
  });

  let queue = Promise.resolve();
  input.on("line", (line) => {
    queue = queue
      .then(() => handleLine(line))
      .catch(() => {
        process.stdout.write(
          `${JSON.stringify(
            rpcError(null, -32603, "Internal bridge error")
          )}\n`
        );
      });
  });

  input.on("close", () => process.exit(0));
  process.on("SIGINT", () => process.exit(0));
  process.on("SIGTERM", () => process.exit(0));
  if (process.platform !== "win32") {
    process.on("SIGPIPE", () => process.exit(0));
  }
}
