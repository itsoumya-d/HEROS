// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2026 Soumya Debnath
//
// Ledger tool implementations. The Zero ledger binary validates and generates
// IDs; this bridge owns persistence, idempotency lookup, locking, and pagination.

import { randomBytes } from "node:crypto";
import { ToolError } from "../errors.js";
import { requireScope, auditSuccess } from "../security.js";
import {
  appendJsonLine,
  assertStateFilesSafe,
  pathExists,
  readJsonFile,
  readJsonLines,
  statePaths,
  withFileLock,
  writeJsonAtomic,
} from "../io.js";

const LIMITS = Object.freeze({
  ledger_register: { limit: 10, burst: 2, dimension: "per_ip" },
  ledger_invoice_create: { limit: 1000, burst: 20, dimension: "per_org" },
  ledger_invoice_list: { limit: 3000, burst: 60, dimension: "per_org" },
  ledger_invoice_count: { limit: 6000, burst: 120, dimension: "per_org" },
});

function definitionFromManifest(tool) {
  return {
    name: tool.name,
    title: tool.title,
    description: tool.description,
    inputSchema: tool.input_schema,
    outputSchema: tool.output_schema,
    annotations: {
      ...tool.annotations,
      readOnlyHint: Boolean(tool.annotations?.readOnly),
      destructiveHint: Boolean(tool.annotations?.destructive),
      idempotentHint: Boolean(tool.annotations?.idempotent),
      openWorldHint: false,
    },
  };
}

function parseBinaryJson(stdout) {
  const text = typeof stdout === "string" ? stdout.trim() : "";
  if (!text) {
    throw new ToolError("EXEC_FAILED", "ledger produced empty output", {
      retryable: true,
    });
  }
  try {
    const parsed = JSON.parse(text);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("not an object");
    }
    return parsed;
  } catch {
    throw new ToolError("EXEC_FAILED", "ledger produced invalid JSON", {
      retryable: false,
    });
  }
}

function rateLimitField(limit) {
  return {
    remaining: limit.remaining,
    reset_at: limit.resetAt,
    limit: limit.limit,
    window: "per_hour",
  };
}

function enforceRateLimit(toolName, ctx, rateLimiter) {
  const config = LIMITS[toolName];
  const limit = rateLimiter.check(
    `${toolName}:${ctx.sessionId}`,
    config.limit,
    config.burst
  );
  if (!limit.allowed) {
    throw new ToolError(
      "RATE_LIMITED",
      "Too many requests. Retry after the specified delay.",
      {
        retryable: true,
        retry_after_seconds: Math.max(
          1,
          limit.resetAt - Math.floor(Date.now() / 1000)
        ),
        limit_type: config.dimension,
        limit_tool: toolName,
      }
    );
  }
  return limit;
}

function stringField(args, field, { required = true, max = 256 } = {}) {
  const value = args[field];
  if (value === undefined || value === null) {
    if (!required) return undefined;
    throw new ToolError(
      "MISSING_FLAG",
      `${field} is required and must be a string`,
      { flag: field, retryable: true }
    );
  }
  if (typeof value !== "string") {
    throw new ToolError(
      "MISSING_FLAG",
      `${field} is required and must be a string`,
      { flag: field, retryable: true }
    );
  }
  if (Buffer.byteLength(value, "utf8") > max) {
    throw new ToolError(
      "INVALID_PARAM",
      `${field} exceeds ${max} characters`,
      { flag: field, retryable: false }
    );
  }
  return value;
}

function integerField(args, field, fallback, min, max) {
  const value = args[field] ?? fallback;
  if (
    typeof value !== "number" ||
    !Number.isInteger(value) ||
    value < min ||
    value > max
  ) {
    throw new ToolError(
      "INVALID_PARAM",
      `${field} must be an integer between ${min} and ${max}`,
      { flag: field, retryable: false }
    );
  }
  return value;
}

function entropyHex() {
  return randomBytes(4).toString("hex");
}

function timestampSeconds() {
  return String(Math.floor(Date.now() / 1000));
}

function withoutInternal(result, field) {
  const copy = { ...result };
  delete copy[field];
  return copy;
}

export function createLedgerTools({ manifest, runLedger, rateLimiter }) {
  const byName = new Map(manifest.tools.map((tool) => [tool.name, tool]));
  const missing = Object.keys(LIMITS).filter((name) => !byName.has(name));
  if (missing.length) {
    throw new Error(`ledger manifest is missing tools: ${missing.join(", ")}`);
  }

  const tools = [];

  tools.push({
    definition: definitionFromManifest(byName.get("ledger_register")),
    async call(args, ctx) {
      requireScope(ctx.auth, "rw");
      const limit = enforceRateLimit("ledger_register", ctx, rateLimiter);
      const orgName = stringField(args, "org_name", { max: 256 });
      const paths = statePaths(ctx.dataDir);
      await assertStateFilesSafe(paths);

      const existing = await readJsonFile(paths.data);
      if (existing) {
        return {
          ...withoutInternal(existing, "_new_data"),
          error_code: "ORG_EXISTS",
          retryable: false,
          status: "ok",
          _rate_limit: rateLimitField(limit),
        };
      }

      return withFileLock(paths.dataLock, async () => {
        const raced = await readJsonFile(paths.data);
        if (raced) {
          return {
            ...withoutInternal(raced, "_new_data"),
            error_code: "ORG_EXISTS",
            retryable: false,
            status: "ok",
            _rate_limit: rateLimitField(limit),
          };
        }

        let stdout;
        try {
          stdout = await runLedger([
            "register",
            "--org-name",
            orgName,
            "--entropy",
            entropyHex(),
            "--timestamp",
            timestampSeconds(),
          ]);
        } catch (error) {
          throw new ToolError(
            "EXEC_FAILED",
            `ledger could not be executed: ${error.message}`,
            { retryable: true }
          );
        }

        const parsed = parseBinaryJson(stdout);
        if (parsed.error_code) return parsed;
        const newData = parsed._new_data;
        if (typeof newData !== "string" || !newData) {
          throw new ToolError(
            "EXEC_FAILED",
            "ledger did not return _new_data",
            { retryable: false }
          );
        }

        let dataObject;
        try {
          dataObject = JSON.parse(newData);
        } catch {
          throw new ToolError(
            "EXEC_FAILED",
            "ledger returned malformed _new_data",
            { retryable: false }
          );
        }
        await writeJsonAtomic(paths.data, dataObject);
        const result = {
          ...withoutInternal(parsed, "_new_data"),
          _rate_limit: rateLimitField(limit),
        };
        await auditSuccess({
          dataDir: ctx.dataDir,
          auth: ctx.auth,
          tool: "ledger_register",
        });
        return result;
      });
    },
  });

  tools.push({
    definition: definitionFromManifest(byName.get("ledger_invoice_create")),
    async call(args, ctx) {
      requireScope(ctx.auth, "rw");
      const limit = enforceRateLimit("ledger_invoice_create", ctx, rateLimiter);
      const to = stringField(args, "to", { max: 256 });
      const currency = stringField(args, "currency", { max: 8 });
      const idempotencyKey = stringField(args, "idempotency_key", { max: 128 });
      const memo = stringField(args, "memo", { required: false, max: 512 });

      if (
        typeof args.amount !== "number" ||
        !Number.isFinite(args.amount)
      ) {
        throw new ToolError(
          "MISSING_FLAG",
          "amount is required and must be a number",
          { flag: "amount", retryable: true }
        );
      }
      const amount = args.amount;

      const paths = statePaths(ctx.dataDir);
      await assertStateFilesSafe(paths);
      if (!(await pathExists(paths.data))) {
        throw new ToolError(
          "NO_ORG_REGISTERED",
          "Call ledger_register first to provision an org",
          { retryable: true }
        );
      }

      return withFileLock(paths.invoiceLock, async () => {
        const invoices = await readJsonLines(paths.invoices);
        const existing = invoices.find(
          (invoice) =>
            invoice.idempotency_key === idempotencyKey &&
            (invoice.org_id ?? "") === (ctx.auth.orgId ?? "")
        );
        if (existing) {
          return {
            ...existing,
            _idempotent: true,
            _rate_limit: rateLimitField(limit),
          };
        }

        const cliArgs = [
          "invoice",
          "create",
          "--to",
          to,
          "--amount",
          String(amount),
          "--currency",
          currency,
          "--idempotency-key",
          idempotencyKey,
          "--entropy",
          entropyHex(),
          "--timestamp",
          timestampSeconds(),
        ];
        if (memo !== undefined && memo !== "") cliArgs.push("--memo", memo);

        let stdout;
        try {
          stdout = await runLedger(cliArgs);
        } catch (error) {
          throw new ToolError(
            "EXEC_FAILED",
            `ledger could not be executed: ${error.message}`,
            { retryable: true }
          );
        }

        const parsed = parseBinaryJson(stdout);
        if (parsed.error_code) return parsed;
        const newInvoice = parsed._new_invoice_json;
        if (typeof newInvoice !== "string" || !newInvoice) {
          throw new ToolError(
            "EXEC_FAILED",
            "ledger did not return _new_invoice_json",
            { retryable: false }
          );
        }

        let invoiceObject;
        try {
          invoiceObject = JSON.parse(newInvoice);
        } catch {
          throw new ToolError(
            "EXEC_FAILED",
            "ledger returned malformed _new_invoice_json",
            { retryable: false }
          );
        }
        invoiceObject = {
          ...invoiceObject,
          org_id: ctx.auth.orgId ?? "",
        };
        await appendJsonLine(paths.invoices, invoiceObject);

        const result = {
          ...withoutInternal(parsed, "_new_invoice_json"),
          org_id: ctx.auth.orgId ?? "",
          _rate_limit: rateLimitField(limit),
        };
        await auditSuccess({
          dataDir: ctx.dataDir,
          auth: ctx.auth,
          tool: "ledger_invoice_create",
        });
        return result;
      });
    },
  });

  tools.push({
    definition: definitionFromManifest(byName.get("ledger_invoice_list")),
    async call(args, ctx) {
      requireScope(ctx.auth, "ro");
      const limit = enforceRateLimit("ledger_invoice_list", ctx, rateLimiter);
      const limitValue = integerField(args, "limit", 100, 1, 1000);
      const offset = integerField(args, "offset", 0, 0, Number.MAX_SAFE_INTEGER);
      const paths = statePaths(ctx.dataDir);
      await assertStateFilesSafe(paths);

      if (!(await pathExists(paths.data))) {
        throw new ToolError(
          "NO_ORG_REGISTERED",
          "Call ledger_register first to provision an org",
          { retryable: true }
        );
      }

      const invoices = (await readJsonLines(paths.invoices)).filter(
        (invoice) => (invoice.org_id ?? "") === (ctx.auth.orgId ?? "")
      );
      const page = invoices.slice(offset, offset + limitValue);
      return {
        invoices: page,
        count: page.length,
        total_count: invoices.length,
        has_more: offset + limitValue < invoices.length,
        status: "ok",
        _rate_limit: rateLimitField(limit),
      };
    },
  });

  tools.push({
    definition: definitionFromManifest(byName.get("ledger_invoice_count")),
    async call(args, ctx) {
      requireScope(ctx.auth, "ro");
      const limit = enforceRateLimit("ledger_invoice_count", ctx, rateLimiter);
      const paths = statePaths(ctx.dataDir);
      await assertStateFilesSafe(paths);

      if (!(await pathExists(paths.data))) {
        throw new ToolError(
          "NO_ORG_REGISTERED",
          "Call ledger_register first to provision an org",
          { retryable: true }
        );
      }

      const count = (await readJsonLines(paths.invoices)).filter(
        (invoice) => (invoice.org_id ?? "") === (ctx.auth.orgId ?? "")
      ).length;
      return {
        count,
        status: "ok",
        _rate_limit: rateLimitField(limit),
      };
    },
  });

  return tools;
}
