// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2026 Soumya Debnath
//
// Authentication, rate limiting, approval nonces, and audit receipts. These
// mirror the invariants enforced by the bash bridges, without requiring bash,
// jq, awk, flock, or GNU coreutils.

import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { promises as fs } from "node:fs";
import { join } from "node:path";
import { ToolError } from "./errors.js";
import { appendAudit } from "./io.js";

const API_KEY_PATTERN = /^heros_(ro|rw)_([0-9a-f]{32})_([0-9a-f]{32})$/;
const NONCE_PATTERN = /^[0-9a-f]{16}$/;

export function parseApiKey(key) {
  if (typeof key !== "string") return null;
  const match = API_KEY_PATTERN.exec(key);
  if (!match) return null;
  return { scope: match[1], keyId: match[2], secret: match[3] };
}

export async function authenticate({ apiKey, dataDir, hmacSeed }) {
  if (!apiKey) return { orgId: "", keyId: "", scope: "anonymous" };

  const parsed = parseApiKey(apiKey);
  if (!parsed) {
    throw new ToolError("INVALID_API_KEY", "API key format is invalid", {
      retryable: false,
      hint: "Expected heros_<ro|rw>_<32-hex-key-id>_<32-hex-secret>",
    });
  }
  if (typeof hmacSeed !== "string" || hmacSeed.length < 32) {
    throw new ToolError(
      "INVALID_API_KEY",
      "HEROS_HMAC_SEED must be at least 32 characters when API keys are enabled",
      { retryable: false }
    );
  }

  let raw;
  try {
    raw = await fs.readFile(join(dataDir, ".heros-keys"), "utf8");
  } catch {
    throw new ToolError("INVALID_API_KEY", "No API keys are provisioned", {
      retryable: false,
    });
  }

  const record = raw
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line.length > 0 && line.split(/\s+/)[0] === parsed.keyId);
  if (!record) {
    throw new ToolError("INVALID_API_KEY", "API key is not recognized", {
      retryable: false,
    });
  }

  const [keyId, scope, orgId, storedHash, , revoked] = record.split(/\s+/);
  if (revoked === "1") {
    throw new ToolError("API_KEY_REVOKED", "API key has been revoked", {
      retryable: false,
      hint: "Rotate the key via ledger key rotate",
    });
  }
  if (!["ro", "rw"].includes(scope) || !/^org_[0-9a-f]{8}$/.test(orgId ?? "")) {
    throw new ToolError("INVALID_API_KEY", "API key record is malformed", {
      retryable: false,
    });
  }

  const expected = createHmac("sha256", hmacSeed)
    .update(`${parsed.keyId}:${parsed.secret}`)
    .digest("hex");
  const expectedBytes = Buffer.from(expected, "hex");
  const storedBytes = Buffer.from(storedHash ?? "", "hex");
  if (
    expectedBytes.length !== storedBytes.length ||
    !timingSafeEqual(expectedBytes, storedBytes)
  ) {
    throw new ToolError("INVALID_API_KEY", "API key is not recognized", {
      retryable: false,
    });
  }

  return { orgId, keyId, scope };
}

export function requireScope(auth, required) {
  if (auth.scope === "anonymous") return;
  if (required === "rw" && auth.scope !== "rw") {
    throw new ToolError(
      "INSUFFICIENT_SCOPE",
      "This operation requires an rw-scoped API key",
      { retryable: false, hint: "Use a key created with --scope rw" }
    );
  }
}

export class RateLimiter {
  constructor() {
    this.buckets = new Map();
  }

  check(key, limit, burst = 10) {
    const now = Date.now();
    const cap = burst * 100;
    let bucket = this.buckets.get(key);
    if (!bucket) bucket = { tokens: cap, last: now };

    if (limit === 0) {
      this.buckets.set(key, bucket);
      return {
        allowed: false,
        remaining: 0,
        resetAt: Math.ceil(now / 1000) + 3600,
        limit,
      };
    }

    const elapsedSeconds = Math.max(0, (now - bucket.last) / 1000);
    const added = Math.floor((elapsedSeconds * limit * 100) / 3600);
    bucket.tokens = Math.min(cap, bucket.tokens + added);
    bucket.last = now;

    const tokensNeeded = 100 - (bucket.tokens % 100);
    const resetAt = Math.ceil(
      now / 1000 + (tokensNeeded * 3600) / (limit * 100)
    );

    if (bucket.tokens >= 100) {
      bucket.tokens -= 100;
      this.buckets.set(key, bucket);
      return {
        allowed: true,
        remaining: Math.floor(bucket.tokens / 100),
        resetAt,
        limit,
      };
    }

    this.buckets.set(key, bucket);
    return { allowed: false, remaining: 0, resetAt, limit };
  }
}

export function schemaHash(schema) {
  return createHash("sha256").update(schema).digest("hex").slice(0, 16);
}

export class ApprovalStore {
  constructor({ ttlMs = 300_000, now = () => Date.now() } = {}) {
    this.ttlMs = ttlMs;
    this.now = now;
    this.pending = new Map();
  }

  issue(fromSchema, toSchema) {
    const nonce = randomBytes(8).toString("hex");
    this.pending.set(nonce, {
      fromHash: schemaHash(fromSchema),
      toHash: schemaHash(toSchema),
      expiresAt: this.now() + this.ttlMs,
    });
    this.sweep();
    return nonce;
  }

  consume(nonce, fromSchema, toSchema) {
    if (typeof nonce !== "string" || !NONCE_PATTERN.test(nonce)) {
      return { ok: false, reason: "Token format invalid. Expected 16 hex characters." };
    }
    const record = this.pending.get(nonce);
    if (!record) {
      return {
        ok: false,
        reason:
          "Token not recognized or already used. Re-run forge_analyze without a token to obtain a fresh one.",
      };
    }
    if (this.now() > record.expiresAt) {
      this.pending.delete(nonce);
      return { ok: false, reason: "Token expired (5-minute TTL)." };
    }
    if (
      record.fromHash !== schemaHash(fromSchema) ||
      record.toHash !== schemaHash(toSchema)
    ) {
      this.pending.delete(nonce);
      return {
        ok: false,
        reason: "Token does not match this schema pair.",
      };
    }
    this.pending.delete(nonce);
    return { ok: true };
  }

  sweep() {
    const now = this.now();
    for (const [nonce, record] of this.pending) {
      if (record.expiresAt < now) this.pending.delete(nonce);
    }
  }
}

export async function auditSuccess({ dataDir, auth, tool }) {
  if (!auth?.keyId) return;
  await appendAudit(
    join(dataDir, ".heros-audit"),
    `${Math.floor(Date.now() / 1000)} ${auth.keyId} ${auth.scope} ${tool} ${
      auth.orgId ?? ""
    }`
  );
}

export async function auditFailure({ dataDir, rc }) {
  await appendAudit(
    join(dataDir, ".heros-audit-failed"),
    `${Math.floor(Date.now() / 1000)} FAIL rc=${rc}`
  );
}

export function authErrorCode(error) {
  if (error instanceof ToolError) {
    if (error.code === "API_KEY_REVOKED") return 2;
    if (error.code === "INSUFFICIENT_SCOPE") return 3;
  }
  return 1;
}
