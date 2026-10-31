// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2026 Soumya Debnath
//
// MCP 2025-11-25 server core shared by the stdio and Streamable HTTP transports.

import {
  ToolError,
  rpcError,
  rpcResult,
  toolContent,
} from "./errors.js";
import {
  ApprovalStore,
  RateLimiter,
  auditFailure,
  authenticate,
  authErrorCode,
} from "./security.js";
import { createForgeTools } from "./tools/forge.js";
import { createLedgerTools } from "./tools/ledger.js";
import { createShadowTools } from "./tools/shadow.js";

export const MCP_PROTOCOL_VERSION = "2025-11-25";
export const SERVER_NAME = "heros";
export const SERVER_VERSION = "0.3.0";
const MAX_ID_BYTES = 4096;
const TOOL_NAME_PATTERN = /^[a-z][a-z0-9_]*$/;

export function createSession({ id, apiKey } = {}) {
  return {
    sessionId: id ?? "stdio",
    initialized: false,
    initRequested: false,
    apiKey,
    auth: null,
    clientInfo: null,
  };
}

export function createMcpServer({
  forgeManifest,
  ledgerManifest,
  runForge,
  runLedger,
  dataDir,
  hmacSeed = process.env.HEROS_HMAC_SEED,
  rateLimiter = new RateLimiter(),
  approvals = new ApprovalStore(),
  version = SERVER_VERSION,
} = {}) {
  if (!forgeManifest || !ledgerManifest) {
    throw new Error("createMcpServer requires forgeManifest and ledgerManifest");
  }
  if (typeof runForge !== "function" || typeof runLedger !== "function") {
    throw new Error("createMcpServer requires runForge and runLedger functions");
  }
  if (!dataDir) throw new Error("createMcpServer requires dataDir");

  const tools = [
    ...createForgeTools({ manifest: forgeManifest, runForge, approvals, rateLimiter }),
    ...createShadowTools({ rateLimiter }),
    ...createLedgerTools({ manifest: ledgerManifest, runLedger, rateLimiter }),
  ];
  const byName = new Map(tools.map((tool) => [tool.definition.name, tool]));
  const definitions = tools.map((tool) => tool.definition);

  async function resolveAuth(session) {
    const key = session.apiKey ?? process.env.HEROS_API_KEY ?? "";
    try {
      session.auth = await authenticate({ apiKey: key, dataDir, hmacSeed });
      return null;
    } catch (error) {
      if (error instanceof ToolError) {
        await auditFailure({ dataDir, rc: authErrorCode(error) });
        return error;
      }
      throw error;
    }
  }

  async function handleMessage(message, session) {
    session.dataDir = dataDir;
    if (!message || typeof message !== "object" || Array.isArray(message)) {
      return rpcError(null, -32600, "Invalid Request: message must be a JSON object");
    }

    const hasId = Object.prototype.hasOwnProperty.call(message, "id");
    const method = message.method;
    const id = message.id ?? null;

    if (typeof id === "string" && Buffer.byteLength(id, "utf8") > MAX_ID_BYTES) {
      return rpcError(null, -32600, "Invalid Request: id must not exceed 4096 bytes");
    }

    if (!hasId) {
      if (typeof method !== "string") return null;
      if (
        method === "notifications/initialized" &&
        session.initRequested
      ) {
        session.initialized = true;
      }
      return null;
    }

    if (message.jsonrpc !== "2.0") {
      return rpcError(id, -32600, 'Invalid Request: jsonrpc field must be "2.0"');
    }
    if (typeof method !== "string") {
      return rpcError(id, -32600, "Invalid Request: method must be a string");
    }

    switch (method) {
      case "initialize": {
        if (session.initRequested) {
          return rpcError(id, -32003, "Already initialized — re-initialization rejected");
        }
        session.initRequested = true;
        session.initialized = true;
        session.clientInfo = message.params?.clientInfo ?? null;
        return rpcResult(id, {
          protocolVersion: MCP_PROTOCOL_VERSION,
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: SERVER_NAME, version },
          instructions:
            "HEROS tools enforce deterministic validation, idempotency, rate limits, and human approval gates for destructive schema migrations.",
        });
      }

      case "tools/list": {
        if (!session.initialized) {
          return rpcError(id, -32002, "Server not initialized — send initialize first");
        }
        return rpcResult(id, { tools: definitions });
      }

      case "tools/call": {
        if (!session.initialized) {
          return rpcError(id, -32002, "Server not initialized — send initialize first");
        }
        const params = message.params;
        if (!params || typeof params !== "object" || Array.isArray(params)) {
          return rpcError(id, -32602, "Invalid params: params must be an object");
        }
        if (typeof params.name !== "string") {
          return rpcError(id, -32602, "Invalid params: params.name must be a string");
        }
        if (!TOOL_NAME_PATTERN.test(params.name)) {
          return rpcError(
            id,
            -32602,
            "Invalid params: tool name must match [a-z][a-z0-9_]+"
          );
        }
        if (
          params.arguments !== undefined &&
          params.arguments !== null &&
          (typeof params.arguments !== "object" || Array.isArray(params.arguments))
        ) {
          return rpcError(
            id,
            -32602,
            "Invalid params: params.arguments must be an object"
          );
        }

        const tool = byName.get(params.name);
        if (!tool) {
          return rpcResult(
            id,
            toolContent(
              {
                error_code: "UNKNOWN_TOOL",
                error: `No such tool: ${params.name}`,
                retryable: false,
              },
              { isError: true }
            )
          );
        }

        const authError = await resolveAuth(session);
        if (authError) {
          return rpcResult(
            id,
            toolContent(authError.toJSON(), { isError: true })
          );
        }

        try {
          const result = await tool.call(params.arguments ?? {}, session);
          const isError = Boolean(
            result &&
              typeof result === "object" &&
              Object.prototype.hasOwnProperty.call(result, "error_code")
          );
          return rpcResult(id, toolContent(result, { isError }));
        } catch (error) {
          if (error instanceof ToolError) {
            return rpcResult(id, toolContent(error.toJSON(), { isError: true }));
          }
          return rpcResult(
            id,
            toolContent(
              {
                error_code: "INTERNAL_ERROR",
                error: error instanceof Error ? error.message : String(error),
                retryable: false,
              },
              { isError: true }
            )
          );
        }
      }

      case "ping":
        return rpcResult(id, {});

      default:
        return rpcError(
          id,
          -32601,
          `Method not found: ${String(method).slice(0, 200)}`
        );
    }
  }

  return {
    protocolVersion: MCP_PROTOCOL_VERSION,
    serverInfo: { name: SERVER_NAME, version },
    tools: definitions,
    handleMessage,
    toolNames: definitions.map((tool) => tool.name),
  };
}
