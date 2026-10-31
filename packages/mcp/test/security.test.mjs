// SPDX-License-Identifier: MIT
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  ApprovalStore,
  RateLimiter,
  authenticate,
  parseApiKey,
  requireScope,
} from "../src/security.js";

describe("API keys", () => {
  test("format, scopes, revocation, and HMAC validation", async (t) => {
    const dataDir = await mkdtemp(join(tmpdir(), "heros-keys-"));
    t.after(() => rm(dataDir, { recursive: true, force: true }));
    const seed = "z".repeat(40);
    const keyId = "1".repeat(32);
    const secret = "2".repeat(32);
    const hash = createHmac("sha256", seed)
      .update(`${keyId}:${secret}`)
      .digest("hex");
    await writeFile(
      join(dataDir, ".heros-keys"),
      `${keyId} ro org_12345678 ${hash} 0 0\n` +
        `${"3".repeat(32)} rw org_87654321 ${"0".repeat(64)} 0 1\n`
    );

    assert.deepEqual(parseApiKey(`heros_ro_${keyId}_${secret}`), {
      scope: "ro",
      keyId,
      secret,
    });
    assert.equal(parseApiKey("heros_xx_bad"), null);

    const auth = await authenticate({
      apiKey: `heros_ro_${keyId}_${secret}`,
      dataDir,
      hmacSeed: seed,
    });
    assert.equal(auth.scope, "ro");
    assert.equal(auth.orgId, "org_12345678");

    assert.throws(
      () => requireScope(auth, "rw"),
      (error) => error.code === "INSUFFICIENT_SCOPE"
    );
    requireScope(auth, "ro");

    await assert.rejects(
      () =>
        authenticate({
          apiKey: `heros_ro_${keyId}_${"9".repeat(32)}`,
          dataDir,
          hmacSeed: seed,
        }),
      (error) => error.code === "INVALID_API_KEY"
    );

    await assert.rejects(
      () =>
        authenticate({
          apiKey: `heros_rw_${"3".repeat(32)}_${"4".repeat(32)}`,
          dataDir,
          hmacSeed: seed,
        }),
      (error) => error.code === "API_KEY_REVOKED"
    );

    await assert.rejects(
      () =>
        authenticate({
          apiKey: `heros_ro_${keyId}_${secret}`,
          dataDir,
          hmacSeed: "short",
        }),
      (error) => error.code === "INVALID_API_KEY"
    );
  });
});

describe("RateLimiter", () => {
  test("consumes tokens and reports a retry window", () => {
    const limiter = new RateLimiter();
    const first = limiter.check("tool:session", 2, 1);
    assert.equal(first.allowed, true);
    assert.equal(first.limit, 2);
    const second = limiter.check("tool:session", 2, 1);
    assert.equal(second.allowed, false);
    assert.equal(second.remaining, 0);
    assert.ok(second.resetAt >= Math.floor(Date.now() / 1000));
  });

  test("limit 0 disables a tool without dividing by zero", () => {
    const limiter = new RateLimiter();
    const result = limiter.check("disabled:session", 0, 5);
    assert.equal(result.allowed, false);
    assert.equal(result.resetAt > 0, true);
  });
});

describe("ApprovalStore", () => {
  test("nonces are single-use, schema-bound, and expire", () => {
    let now = 1000;
    const store = new ApprovalStore({ ttlMs: 100, now: () => now });
    const nonce = store.issue("TABLE a", "DROP TABLE a");
    assert.match(nonce, /^[0-9a-f]{16}$/);

    assert.equal(store.consume(nonce, "TABLE a", "DROP TABLE a").ok, true);
    assert.equal(store.consume(nonce, "TABLE a", "DROP TABLE a").ok, false);

    const second = store.issue("TABLE a", "DROP TABLE a");
    assert.equal(store.consume(second, "TABLE b", "DROP TABLE b").ok, false);

    const third = store.issue("TABLE a", "DROP TABLE a");
    now += 101;
    const expired = store.consume(third, "TABLE a", "DROP TABLE a");
    assert.equal(expired.ok, false);
    assert.match(expired.reason, /expired/i);
  });
});
