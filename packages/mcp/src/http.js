// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2026 Soumya Debnath
//
// MCP Streamable HTTP transport. A single /mcp endpoint accepts JSON-RPC over
// POST and can answer with application/json or text/event-stream. Sessions are
// identified by the Mcp-Session-Id header.

import http from "node:http";
import { randomBytes } from "node:crypto";
import { createSession } from "./server.js";
import { rpcError } from "./errors.js";

const MAX_BODY_BYTES = 1024 * 1024;
const DEFAULT_SESSION_TTL_MS = 30 * 60 * 1000;

function sessionId() {
  return randomBytes(16).toString("hex");
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on("data", (chunk) => {
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        const error = new Error("request body too large");
        error.code = "TOO_LARGE";
        reject(error);
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function extractApiKey(req) {
  const authorization = req.headers.authorization;
  if (typeof authorization === "string" && authorization.startsWith("Bearer ")) {
    return authorization.slice("Bearer ".length).trim();
  }
  const headerKey = req.headers["x-heros-api-key"];
  if (typeof headerKey === "string" && headerKey.trim()) return headerKey.trim();
  return undefined;
}

function writeCors(req, res, allowOrigin) {
  const origin = req.headers.origin;
  const allowed =
    allowOrigin === "*" || !origin
      ? allowOrigin
      : String(origin) === allowOrigin
        ? allowOrigin
        : "null";
  res.setHeader("Access-Control-Allow-Origin", allowed);
  res.setHeader("Vary", "Origin");
  res.setHeader(
    "Access-Control-Allow-Headers",
    "Content-Type, Authorization, X-Heros-Api-Key, Mcp-Session-Id, MCP-Protocol-Version"
  );
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS");
  res.setHeader("Access-Control-Expose-Headers", "Mcp-Session-Id");
}

function sendJson(res, status, body, headers = {}) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(payload),
    ...headers,
  });
  res.end(payload);
}

export function createHttpServer(
  server,
  {
    allowOrigin = process.env.HEROS_MCP_ALLOW_ORIGIN ?? "*",
    sessionTtlMs = DEFAULT_SESSION_TTL_MS,
  } = {}
) {
  const sessions = new Map();

  function getSession(id) {
    const entry = sessions.get(id);
    if (!entry) return null;
    entry.lastSeen = Date.now();
    return entry;
  }

  function newSession(apiKey) {
    const id = sessionId();
    const session = createSession({ id, apiKey });
    sessions.set(id, { session, lastSeen: Date.now() });
    return { id, session };
  }

  const httpServer = http.createServer(async (req, res) => {
    writeCors(req, res, allowOrigin);

    if (req.method === "OPTIONS") {
      res.writeHead(204);
      res.end();
      return;
    }

    const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);

    if (req.method === "GET" && url.pathname === "/healthz") {
      sendJson(res, 200, {
        ok: true,
        name: server.serverInfo.name,
        version: server.serverInfo.version,
        protocolVersion: server.protocolVersion,
        tools: server.toolNames,
      });
      return;
    }

    if (url.pathname !== "/mcp") {
      sendJson(res, 404, { error: "not_found" });
      return;
    }

    const protocolHeader = req.headers["mcp-protocol-version"];
    if (
      typeof protocolHeader === "string" &&
      protocolHeader !== server.protocolVersion
    ) {
      sendJson(
        res,
        400,
        rpcError(
          null,
          -32600,
          `Unsupported MCP-Protocol-Version: ${protocolHeader}`
        )
      );
      return;
    }

    if (req.method === "DELETE") {
      const id = req.headers["mcp-session-id"];
      if (typeof id === "string") sessions.delete(id);
      res.writeHead(204, { "Mcp-Session-Id": String(id ?? "") });
      res.end();
      return;
    }

    if (req.method === "GET") {
      const accept = String(req.headers.accept ?? "");
      if (!accept.includes("text/event-stream")) {
        sendJson(res, 405, rpcError(null, -32600, "Accept must include text/event-stream"));
        return;
      }
      const id = req.headers["mcp-session-id"];
      if (typeof id !== "string" || !getSession(id)) {
        sendJson(res, 400, rpcError(null, -32600, "Mcp-Session-Id is required"));
        return;
      }

      res.writeHead(200, {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache, no-transform",
        Connection: "keep-alive",
        "Mcp-Session-Id": id,
      });
      res.write(": connected\n\n");
      const keepalive = setInterval(() => {
        if (!res.writableEnded) res.write(": keepalive\n\n");
      }, 15_000);
      req.on("close", () => clearInterval(keepalive));
      return;
    }

    if (req.method !== "POST") {
      sendJson(res, 405, rpcError(null, -32600, "Method not allowed"));
      return;
    }

    let raw;
    try {
      raw = await readBody(req);
    } catch (error) {
      sendJson(
        res,
        error.code === "TOO_LARGE" ? 413 : 400,
        rpcError(null, -32700, "Parse error: request body could not be read")
      );
      return;
    }

    let payload;
    try {
      payload = JSON.parse(raw);
    } catch {
      sendJson(res, 400, rpcError(null, -32700, "Parse error: message is not valid JSON"));
      return;
    }

    const batch = Array.isArray(payload);
    const messages = batch ? payload : [payload];
    if (messages.length === 0) {
      sendJson(res, 400, rpcError(null, -32600, "Invalid Request: empty batch"));
      return;
    }

    const initializeRequest = messages.find(
      (message) =>
        message &&
        typeof message === "object" &&
        message.method === "initialize" &&
        Object.prototype.hasOwnProperty.call(message, "id")
    );

    let entry = null;
    const providedId = req.headers["mcp-session-id"];
    if (initializeRequest) {
      entry = typeof providedId === "string" ? getSession(providedId) : null;
      if (!entry) entry = newSession(extractApiKey(req));
    } else {
      if (typeof providedId !== "string" || !getSession(providedId)) {
        sendJson(
          res,
          400,
          rpcError(
            messages[0]?.id ?? null,
            -32600,
            "Mcp-Session-Id is required; send initialize first"
          )
        );
        return;
      }
      entry = getSession(providedId);
    }

    const requestKey = extractApiKey(req);
    if (requestKey !== undefined) entry.session.apiKey = requestKey;
    entry.lastSeen = Date.now();

    const responses = [];
    for (const message of messages) {
      const response = await server.handleMessage(message, entry.session);
      if (response) responses.push(response);
    }

    const responseHeaders = { "Mcp-Session-Id": entry.session.sessionId };

    if (responses.length === 0) {
      res.writeHead(202, responseHeaders);
      res.end();
      return;
    }

    const accept = String(req.headers.accept ?? "");
    const wantsSse = accept.includes("text/event-stream");

    if (wantsSse) {
      res.writeHead(200, {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache, no-transform",
        Connection: "keep-alive",
        ...responseHeaders,
      });
      for (const response of responses) {
        res.write(`event: message\ndata: ${JSON.stringify(response)}\n\n`);
      }
      res.end();
      return;
    }

    const body = batch ? responses : responses[0];
    const encoded = JSON.stringify(body);
    res.writeHead(200, {
      "Content-Type": "application/json; charset=utf-8",
      "Content-Length": Buffer.byteLength(encoded),
      ...responseHeaders,
    });
    res.end(encoded);
  });

  httpServer.on("clientError", (error, socket) => {
    if (!socket.writable) return;
    socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
  });

  const sweep = setInterval(() => {
    const cutoff = Date.now() - sessionTtlMs;
    for (const [id, entry] of sessions) {
      if (entry.lastSeen < cutoff) sessions.delete(id);
    }
  }, 60_000);
  sweep.unref();

  function listen({ host = "127.0.0.1", port = 0 } = {}) {
    return new Promise((resolve, reject) => {
      httpServer.once("error", reject);
      httpServer.listen(port, host, () => {
        httpServer.off("error", reject);
        const address = httpServer.address();
        resolve({
          host: address.address,
          port: address.port,
          url: `http://${address.address}:${address.port}/mcp`,
        });
      });
    });
  }

  function close() {
    clearInterval(sweep);
    return new Promise((resolve) => httpServer.close(() => resolve()));
  }

  return { server: httpServer, listen, close, sessions };
}
