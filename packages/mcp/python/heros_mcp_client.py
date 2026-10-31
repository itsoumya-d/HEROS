#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2024-2026 Soumya Debnath
"""Stdlib-only Python client for the HEROS MCP bridge.

Useful for LangGraph / LangChain agents that want to invoke forge and ledger
without depending on a Node MCP client library.

    from heros_mcp_client import HerosMcpClient

    client = HerosMcpClient()
    client.initialize()
    tools = client.list_tools()["result"]["tools"]
    result = client.call_tool(
        "forge_analyze",
        {
            "from_schema": "TABLE users",
            "to_schema": "TABLE users\\nDROP COLUMN email",
        },
    )
    print(result["result"]["content"][0]["text"])
    client.close()
"""

from __future__ import annotations

import json
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Iterable


class McpError(RuntimeError):
    """Raised when the bridge returns a JSON-RPC error."""


class HerosMcpClient:
    def __init__(
        self,
        command: Iterable[str] | str | None = None,
        *,
        args: Iterable[str] | None = None,
        env: dict[str, str] | None = None,
        request_timeout: float = 30.0,
    ) -> None:
        if command is None:
            package_root = Path(__file__).resolve().parent.parent
            command = ["node", str(package_root / "bin" / "heros-mcp.mjs"), "--stdio"]
        elif isinstance(command, str):
            command = [command]

        merged_env = os.environ.copy()
        if env:
            merged_env.update(env)

        self._process = subprocess.Popen(
            list(command) + list(args or []),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=merged_env,
        )
        self._request_timeout = request_timeout
        self._next_id = 0
        self._lock = threading.Lock()
        self._responses: queue.Queue[dict[str, Any]] = queue.Queue()
        self._stderr_lines: list[str] = []

        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self) -> None:
        assert self._process.stdout is not None
        for line in self._process.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self._responses.put(json.loads(line))
            except json.JSONDecodeError:
                self._responses.put(
                    {
                        "jsonrpc": "2.0",
                        "id": None,
                        "error": {"code": -32700, "message": line},
                    }
                )

    def _read_stderr(self) -> None:
        assert self._process.stderr is not None
        for line in self._process.stderr:
            self._stderr_lines.append(line.rstrip())

    @property
    def stderr(self) -> str:
        return "\n".join(self._stderr_lines)

    def _request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        with self._lock:
            if self._process.poll() is not None:
                raise McpError(
                    f"HEROS MCP bridge exited with {self._process.returncode}: {self.stderr}"
                )
            self._next_id += 1
            request_id = self._next_id
            message: dict[str, Any] = {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
            }
            if params is not None:
                message["params"] = params
            assert self._process.stdin is not None
            self._process.stdin.write(json.dumps(message) + "\n")
            self._process.stdin.flush()

            deadline = time.monotonic() + self._request_timeout
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"timed out waiting for {method}")
                try:
                    response = self._responses.get(timeout=remaining)
                except queue.Empty as exc:
                    raise TimeoutError(f"timed out waiting for {method}") from exc
                if response.get("id") == request_id:
                    if "error" in response:
                        raise McpError(
                            f"{method} failed: {response['error'].get('message')}"
                        )
                    return response

    def _notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        message: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        assert self._process.stdin is not None
        self._process.stdin.write(json.dumps(message) + "\n")
        self._process.stdin.flush()

    def initialize(self) -> dict[str, Any]:
        response = self._request(
            "initialize",
            {
                "protocolVersion": "2025-11-25",
                "clientInfo": {"name": "heros-python", "version": "0.2.0"},
            },
        )
        self._notify("notifications/initialized")
        return response

    def list_tools(self) -> dict[str, Any]:
        return self._request("tools/list", {})

    def call_tool(self, name: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        return self._request(
            "tools/call",
            {"name": name, "arguments": arguments or {}},
        )

    def close(self) -> None:
        if self._process.poll() is None:
            try:
                assert self._process.stdin is not None
                self._process.stdin.close()
            except (BrokenPipeError, OSError):
                pass
            try:
                self._process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._process.terminate()
                self._process.wait(timeout=5)


def main() -> int:
    client = HerosMcpClient()
    try:
        client.initialize()
        tools = client.list_tools()["result"]["tools"]
        print(json.dumps({"tools": [tool["name"] for tool in tools]}, indent=2))
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
