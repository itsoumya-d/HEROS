// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2026 Soumya Debnath

import { ToolError } from "../errors.js";
import { auditSuccess } from "../security.js";
import { analyzeShadow, ShadowError } from "../shadow.js";

const MAX_SCHEMA_BYTES = 65_536;
const MAX_REQUEST_ID = 512;
const MAX_ACK_TOKEN = 64;

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

function requireString(value, field, maxBytes) {
  if (typeof value !== "string") {
    throw new ToolError(
      "MISSING_FLAG",
      `${field} is required and must be a string`,
      { flag: field, retryable: true }
    );
  }
  if (Buffer.byteLength(value, "utf8") > maxBytes) {
    throw new ToolError(
      "INVALID_INPUT",
      `${field} exceeds the ${maxBytes}-byte limit`,
      { field, retryable: false }
    );
  }
  return value;
}

function toForgeInline(schema, field) {
  if (schema.includes("|")) {
    throw new ToolError(
      "INVALID_INPUT",
      `${field} must not contain pipe characters (|); use newlines to separate lines`,
      { field, retryable: true }
    );
  }
  return schema.replace(/\r\n?/g, "\n").replace(/\n/g, "|");
}

function parseBinaryJson(stdout) {
  const text = typeof stdout === "string" ? stdout.trim() : "";
  if (!text) {
    throw new ToolError("EXEC_FAILED", "forge produced empty output", {
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
    throw new ToolError("EXEC_FAILED", "forge produced invalid JSON", {
      retryable: true,
    });
  }
}

function normalizeBinaryError(result) {
  if (
    result &&
    typeof result === "object" &&
    result.error &&
    typeof result.error === "object"
  ) {
    return {
      error_code: result.error.code,
      error: result.error.message,
      retryable: result.error.retryable ?? true,
    };
  }
  return result;
}

function shadowErrorMessage(error) {
  const message = error instanceof Error ? error.message : String(error);
  return message.replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, 240);
}

function rateLimitField(limit) {
  return {
    remaining: limit.remaining,
    reset_at: limit.resetAt,
    limit: limit.limit,
    window: "per_hour",
  };
}

export function createForgeTools({
  manifest,
  runForge,
  approvals,
  rateLimiter,
}) {
  const tool = manifest.tools.find((entry) => entry.name === "forge_analyze");
  if (!tool) throw new Error("forge manifest does not define forge_analyze");

  return [
    {
      definition: definitionFromManifest(tool),
      async call(args, ctx) {
        const limit = rateLimiter.check(
          `forge_analyze:${ctx.sessionId}`,
          200,
          10
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
              limit_type: "per_ip",
              limit_tool: "forge_analyze",
            }
          );
        }

        const fromSchema = requireString(
          args.from_schema,
          "from_schema",
          MAX_SCHEMA_BYTES
        );
        const toSchema = requireString(
          args.to_schema,
          "to_schema",
          MAX_SCHEMA_BYTES
        );

        let requestId;
        if (args.request_id !== undefined && args.request_id !== null) {
          if (typeof args.request_id !== "string") {
            throw new ToolError(
              "INVALID_INPUT",
              "request_id must be a string",
              { field: "request_id", retryable: false }
            );
          }
          if (
            Buffer.byteLength(args.request_id, "utf8") > MAX_REQUEST_ID ||
            !/^[\x20-\x7e]+$/.test(args.request_id) ||
            args.request_id.includes('"') ||
            args.request_id.includes("\\")
          ) {
            throw new ToolError(
              "INVALID_INPUT",
              "request_id must be printable ASCII without quotes or backslashes, at most 512 bytes",
              { field: "request_id", retryable: false }
            );
          }
          requestId = args.request_id;
        }

        let acknowledgmentToken;
        if (
          args.human_acknowledgment_token !== undefined &&
          args.human_acknowledgment_token !== null
        ) {
          if (typeof args.human_acknowledgment_token !== "string") {
            throw new ToolError(
              "INVALID_INPUT",
              "human_acknowledgment_token must be a string",
              { field: "human_acknowledgment_token", retryable: false }
            );
          }
          if (
            Buffer.byteLength(args.human_acknowledgment_token, "utf8") >
            MAX_ACK_TOKEN
          ) {
            throw new ToolError(
              "INVALID_INPUT",
              "human_acknowledgment_token exceeds 64 bytes",
              { field: "human_acknowledgment_token", retryable: false }
            );
          }
          acknowledgmentToken = args.human_acknowledgment_token;
        }

        const cliArgs = [
          "analyze",
          "--from",
          toForgeInline(fromSchema, "from_schema"),
          "--to",
          toForgeInline(toSchema, "to_schema"),
        ];
        if (requestId) cliArgs.push("--request-id", requestId);

        let stdout;
        try {
          stdout = await runForge(cliArgs);
        } catch (error) {
          throw new ToolError(
            "EXEC_FAILED",
            `forge could not be executed: ${error.message}`,
            { retryable: true }
          );
        }

        let result = normalizeBinaryError(parseBinaryJson(stdout));
        if (result && typeof result === "object" && result.error_code) {
          return result;
        }

        try {
          const shadow = await analyzeShadow({
            fromSchema,
            toSchema,
            staticRisk:
              typeof result.risk_score === "number"
                ? result.risk_score
                : undefined
          });
          result = {
            ...result,
            shadow,
            decision_required:
              result.decision_required === true || shadow.decision_required === true
          };
        } catch (error) {
          const code = error instanceof ShadowError
            ? error.code
            : "SHADOW_FAILED";
          result = {
            ...result,
            shadow: {
              ok: false,
              error_code: code,
              error: shadowErrorMessage(error),
              retryable: code === "SHADOW_FAILED"
            }
          };
        }

        if (
          result.shadow &&
          result.shadow.ok !== false &&
          result.shadow.recommended_decision === "deny"
        ) {
          return {
            ...result,
            error_code: "SHADOW_DENY",
            error:
              "Shadow sandbox reports a migration execution error. Human approval cannot override a non-executable migration.",
            retryable: false
          };
        }

        if (acknowledgmentToken !== undefined) {
          const redemption = approvals.consume(
            acknowledgmentToken,
            fromSchema,
            toSchema
          );
          if (!redemption.ok) {
            return {
              error_code: "INVALID_ACKNOWLEDGMENT_TOKEN",
              error: redemption.reason,
              retryable: true,
            };
          }
          result = {
            ...result,
            proceed_ok: true,
            decision_required: false,
          };
        } else if (result.decision_required === true) {
          const nonce = approvals.issue(fromSchema, toSchema);
          result = {
            ...result,
            approval_nonce: nonce,
            approval_prompt:
              "Migration has data loss or critical risk. Human sign-off required. Pass this nonce as human_acknowledgment_token after the human principal approves.",
          };
        }

        result = {
          ...result,
          _rate_limit: rateLimitField(limit),
        };

        await auditSuccess({
          dataDir: ctx.dataDir,
          auth: ctx.auth,
          tool: "forge_analyze",
        });
        return result;
      },
    },
  ];
}
