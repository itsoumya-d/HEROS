// SPDX-License-Identifier: MIT
// MCP surface for the ephemeral migration shadow sandbox.

import { ToolError } from "../errors.js";
import { auditSuccess } from "../security.js";
import { analyzeShadow, ShadowError } from "../shadow.js";

const MAX_SCHEMA_BYTES = 65_536;

const definition = {
  name: "forge_shadow_analyze",
  title: "Analyze migration in an ephemeral shadow database",
  description:
    "Execute a schema migration against a throwaway SQLite database seeded with deterministic rows, report per-operation data loss and errors, and return a list-wise decision recommendation. Never mutates the caller's database.",
  inputSchema: {
    type: "object",
    required: ["from_schema", "to_schema"],
    additionalProperties: false,
    properties: {
      from_schema: {
        type: "string",
        description: "Current Forge-format schema.",
        maxLength: MAX_SCHEMA_BYTES
      },
      to_schema: {
        type: "string",
        description: "Desired Forge-format schema.",
        maxLength: MAX_SCHEMA_BYTES
      },
      sample_rows: {
        type: "integer",
        minimum: 1,
        maximum: 5,
        description: "Deterministic rows to seed per table (default 3)."
      },
      static_risk: {
        type: "number",
        minimum: 0,
        maximum: 1,
        description: "Optional forge risk score to combine with shadow evidence."
      }
    }
  },
  outputSchema: {
    type: "object",
    properties: {
      ok: { type: "boolean" },
      engine: { type: "string" },
      operations: { type: "array" },
      summary: { type: "object" },
      recommended_decision: { type: "string" },
      decision_required: { type: "boolean" },
      listwise: { type: "object" }
    }
  },
  annotations: {
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false,
    readOnly: true,
    destructive: false,
    idempotent: true,
    decisionRequired: false
  }
};

function requireSchema(value, field) {
  if (typeof value !== "string") {
    throw new ToolError(
      "MISSING_FLAG",
      `${field} is required and must be a string`,
      { flag: field, retryable: true }
    );
  }
  if (Buffer.byteLength(value, "utf8") > MAX_SCHEMA_BYTES) {
    throw new ToolError(
      "INVALID_INPUT",
      `${field} exceeds the ${MAX_SCHEMA_BYTES}-byte limit`,
      { field, retryable: false }
    );
  }
  return value;
}

export function createShadowTools({ rateLimiter }) {
  return [
    {
      definition,
      async call(args, ctx) {
        const limit = rateLimiter.check(
          `forge_shadow_analyze:${ctx.sessionId}`,
          100,
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
              limit_tool: "forge_shadow_analyze"
            }
          );
        }

        const fromSchema = requireSchema(args.from_schema, "from_schema");
        const toSchema = requireSchema(args.to_schema, "to_schema");

        let sampleRows = 3;
        if (args.sample_rows !== undefined) {
          if (
            !Number.isInteger(args.sample_rows) ||
            args.sample_rows < 1 ||
            args.sample_rows > 5
          ) {
            throw new ToolError(
              "INVALID_INPUT",
              "sample_rows must be an integer from 1 to 5",
              { field: "sample_rows", retryable: false }
            );
          }
          sampleRows = args.sample_rows;
        }

        let staticRisk;
        if (args.static_risk !== undefined) {
          if (
            typeof args.static_risk !== "number" ||
            !Number.isFinite(args.static_risk) ||
            args.static_risk < 0 ||
            args.static_risk > 1
          ) {
            throw new ToolError(
              "INVALID_INPUT",
              "static_risk must be a number from 0 to 1",
              { field: "static_risk", retryable: false }
            );
          }
          staticRisk = args.static_risk;
        }

        let result;
        try {
          result = await analyzeShadow({
            fromSchema,
            toSchema,
            sampleRows,
            staticRisk
          });
        } catch (error) {
          if (error instanceof ShadowError) {
            return {
              ok: false,
              error_code: error.code,
              error: error.message,
              retryable: false,
              ...error.details
            };
          }
          throw new ToolError(
            "SHADOW_FAILED",
            `Shadow analysis failed: ${error instanceof Error ? error.message : String(error)}`,
            { retryable: true }
          );
        }

        await auditSuccess({
          dataDir: ctx.dataDir,
          auth: ctx.auth,
          tool: "forge_shadow_analyze"
        });

        return {
          ...result,
          _rate_limit: {
            remaining: limit.remaining,
            reset_at: limit.resetAt,
            limit: limit.limit,
            window: "per_hour"
          }
        };
      }
    }
  ];
}
