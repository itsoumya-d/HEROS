// SPDX-License-Identifier: MIT
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { makeHarness } from "./helpers.mjs";
import { createHttpServer } from "../src/http.js";

async function startHttp(t) {
  const harness = await makeHarness();
  t.after(harness.cleanup);
  const http = createHttpServer(harness.server);
  const address = await http.listen({ host: "127.0.0.1", port: 0 });
  t.after(() => http.close());
  return { harness, http, endpoint: address.url, base: `http://127.0.0.1:${address.port}` };
}

async function post(endpoint, body, headers = {}) {
  return fetch(endpoint, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json",
      ...headers,
    },
    body: JSON.stringify(body),
  });
}

async function initialize(endpoint) {
  const response = await post(endpoint, {
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2025-11-25",
      clientInfo: { name: "http-test", version: "1.0.0" },
    },
  });
  assert.equal(response.status, 200);
  const sessionId = response.headers.get("mcp-session-id");
  assert.match(sessionId, /^[0-9a-f]{32}$/);
  const body = await response.json();
  assert.equal(body.result.protocolVersion, "2025-11-25");
  return sessionId;
}

describe("Streamable HTTP transport", () => {
  test("initialize, tools/list, and tools/call share a session", async (t) => {
    const { endpoint, base } = await startHttp(t);
    const sessionId = await initialize(endpoint);

    const list = await post(
      endpoint,
      { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} },
      { "mcp-session-id": sessionId }
    );
    assert.equal(list.status, 200);
    const listBody = await list.json();
    assert.equal(listBody.result.tools.length, 5);
    assert.equal(list.headers.get("mcp-session-id"), sessionId);

    const call = await post(
      endpoint,
      {
        jsonrpc: "2.0",
        id: 3,
        method: "tools/call",
        params: {
          name: "forge_analyze",
          arguments: {
            from_schema: "TABLE users",
            to_schema: "TABLE users\nCOLUMN email text NULLABLE",
          },
        },
      },
      { "mcp-session-id": sessionId }
    );
    assert.equal(call.status, 200);
    const callBody = await call.json();
    const result = JSON.parse(callBody.result.content[0].text);
    assert.equal(result.risk_tier, "SAFE");

    const health = await fetch(`${base}/healthz`);
    assert.equal(health.status, 200);
    const healthBody = await health.json();
    assert.equal(healthBody.ok, true);
    assert.ok(healthBody.tools.includes("forge_analyze"));
  });

  test("requests without a session are rejected", async (t) => {
    const { endpoint } = await startHttp(t);
    const response = await post(endpoint, {
      jsonrpc: "2.0",
      id: 7,
      method: "tools/list",
      params: {},
    });
    assert.equal(response.status, 400);
    const body = await response.json();
    assert.equal(body.error.code, -32600);
  });

  test("SSE responses carry the JSON-RPC result", async (t) => {
    const { endpoint } = await startHttp(t);
    const sessionId = await initialize(endpoint);
    const response = await post(
      endpoint,
      {
        jsonrpc: "2.0",
        id: 4,
        method: "tools/list",
        params: {},
      },
      {
        "mcp-session-id": sessionId,
        accept: "text/event-stream",
      }
    );
    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type"), /text\/event-stream/);
    const text = await response.text();
    const dataLine = text
      .split("\n")
      .find((line) => line.startsWith("data: "));
    assert.ok(dataLine);
    const payload = JSON.parse(dataLine.slice(6));
    assert.equal(payload.result.tools.length, 5);
  });

  test("GET opens an SSE stream with a keepalive comment", async (t) => {
    const { endpoint } = await startHttp(t);
    const sessionId = await initialize(endpoint);
    const controller = new AbortController();
    const response = await fetch(endpoint, {
      method: "GET",
      headers: {
        accept: "text/event-stream",
        "mcp-session-id": sessionId,
      },
      signal: controller.signal,
    });
    assert.equal(response.status, 200);
    const reader = response.body.getReader();
    const first = await reader.read();
    const text = new TextDecoder().decode(first.value);
    assert.match(text, /: connected/);
    controller.abort();
  });

  test("DELETE terminates the session and notifications return 202", async (t) => {
    const { endpoint } = await startHttp(t);
    const sessionId = await initialize(endpoint);

    const notification = await post(
      endpoint,
      { jsonrpc: "2.0", method: "notifications/initialized" },
      { "mcp-session-id": sessionId }
    );
    assert.equal(notification.status, 202);

    const deleted = await fetch(endpoint, {
      method: "DELETE",
      headers: { "mcp-session-id": sessionId },
    });
    assert.equal(deleted.status, 204);

    const after = await post(
      endpoint,
      { jsonrpc: "2.0", id: 8, method: "tools/list", params: {} },
      { "mcp-session-id": sessionId }
    );
    assert.equal(after.status, 400);
  });

  test("unsupported protocol versions are rejected", async (t) => {
    const { endpoint } = await startHttp(t);
    const response = await post(
      endpoint,
      { jsonrpc: "2.0", id: 9, method: "initialize", params: {} },
      { "mcp-protocol-version": "2024-01-01" }
    );
    assert.equal(response.status, 400);
  });
});
