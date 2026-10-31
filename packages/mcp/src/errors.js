// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2026 Soumya Debnath

export class ToolError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = "ToolError";
    this.code = code;
    this.details = details;
  }

  toJSON() {
    return {
      error_code: this.code,
      error: this.message,
      ...this.details,
    };
  }
}

export function rpcResult(id, result) {
  return { jsonrpc: "2.0", id, result };
}

export function rpcError(id, code, message, data) {
  const error = { code, message };
  if (data !== undefined) error.data = data;
  return { jsonrpc: "2.0", id: id ?? null, error };
}

export function toolContent(value, { isError = false } = {}) {
  return {
    content: [{ type: "text", text: JSON.stringify(value) }],
    structuredContent: value,
    isError,
  };
}
