// SPDX-License-Identifier: MIT
// Copyright (c) 2024-2026 Soumya Debnath
//
// Filesystem helpers owned by the MCP bridge. The Zero binaries stay pure
// compute; this layer owns state, locks, atomic writes, and timestamps.

import { promises as fs } from "node:fs";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import { ToolError } from "./errors.js";

export const STATE_FILES = Object.freeze({
  data: ".ledger-data",
  invoices: ".ledger-invoices",
  keys: ".heros-keys",
  audit: ".heros-audit",
  auditFailed: ".heros-audit-failed",
  dataLock: ".ledger-data.lock",
  invoiceLock: ".ledger-invoices.lock",
});

export function statePaths(dataDir) {
  return {
    dataDir,
    data: join(dataDir, STATE_FILES.data),
    invoices: join(dataDir, STATE_FILES.invoices),
    keys: join(dataDir, STATE_FILES.keys),
    audit: join(dataDir, STATE_FILES.audit),
    auditFailed: join(dataDir, STATE_FILES.auditFailed),
    dataLock: join(dataDir, STATE_FILES.dataLock),
    invoiceLock: join(dataDir, STATE_FILES.invoiceLock),
  };
}

export async function ensureDataDir(dataDir) {
  await fs.mkdir(dataDir, { recursive: true });
}

export async function pathExists(path) {
  try {
    await fs.access(path);
    return true;
  } catch {
    return false;
  }
}

export async function assertNoSymlink(path, { fatal = true } = {}) {
  try {
    const stat = await fs.lstat(path);
    if (stat.isSymbolicLink()) {
      if (fatal) {
        throw new ToolError(
          "STORE_LOCK_FAILED",
          `Security: ${path} is a symlink; state files must be regular files`,
          { retryable: false }
        );
      }
    }
  } catch (error) {
    if (error.code === "ENOENT") return;
    throw error;
  }
}

export async function assertStateFilesSafe(paths) {
  for (const path of [
    paths.data,
    paths.invoices,
    paths.keys,
    paths.dataLock,
    paths.invoiceLock,
  ]) {
    await assertNoSymlink(path);
  }
}

export async function readJsonFile(path) {
  let raw;
  try {
    raw = await fs.readFile(path, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw new ToolError("STORE_READ_FAILED", `Failed to read ${path}`, {
      retryable: false,
    });
  }

  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("not an object");
    }
    return parsed;
  } catch {
    throw new ToolError("STORE_READ_FAILED", `Failed to parse ${path}`, {
      retryable: false,
    });
  }
}

export async function writeJsonAtomic(path, value) {
  const tempPath = `${path}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
  try {
    await fs.writeFile(tempPath, `${JSON.stringify(value)}\n`, { mode: 0o600 });
    await fs.rename(tempPath, path);
  } catch {
    await fs.unlink(tempPath).catch(() => {});
    throw new ToolError("STORE_WRITE_FAILED", `Failed to persist ${path}`, {
      retryable: true,
    });
  }
}

export async function readJsonLines(path) {
  let raw;
  try {
    raw = await fs.readFile(path, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw new ToolError("STORE_READ_FAILED", `Failed to read ${path}`, {
      retryable: false,
    });
  }

  const records = [];
  for (const line of raw.split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      const parsed = JSON.parse(line);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        records.push(parsed);
      }
    } catch {
      throw new ToolError("STORE_READ_FAILED", `Failed to parse ${path}`, {
        retryable: false,
      });
    }
  }
  return records;
}

export async function appendJsonLine(path, value) {
  try {
    await fs.appendFile(path, `${JSON.stringify(value)}\n`, { mode: 0o600 });
  } catch {
    throw new ToolError("STORE_WRITE_FAILED", `Failed to append to ${path}`, {
      retryable: true,
    });
  }
}

export async function appendAudit(path, line) {
  try {
    await fs.appendFile(path, `${line}\n`, { mode: 0o600 });
  } catch {
    // Auditing is best-effort; a full disk must not turn a successful tool call
    // into a failure. Operators can alert on missing audit lines.
  }
}

/**
 * Cross-platform advisory lock. Uses O_EXCL creation instead of flock(2), so it
 * behaves the same on Linux, macOS, and Windows. Stale locks are removed after
 * `staleMs`; callers still surface LOCK_TIMEOUT rather than hanging forever.
 */
export async function withFileLock(
  lockPath,
  fn,
  { timeoutMs = 10_000, staleMs = 30_000, retryMs = 25 } = {}
) {
  await assertNoSymlink(lockPath);
  const started = Date.now();

  for (;;) {
    let handle;
    try {
      handle = await fs.open(lockPath, "wx", 0o600);
    } catch (error) {
      if (error.code !== "EEXIST") {
        throw new ToolError(
          "STORE_LOCK_FAILED",
          `Failed to create lock ${lockPath}; check permissions and disk space`,
          { retryable: true }
        );
      }

      try {
        const stat = await fs.stat(lockPath);
        if (Date.now() - stat.mtimeMs > staleMs) {
          await fs.unlink(lockPath).catch(() => {});
          continue;
        }
      } catch {
        // The lock disappeared between open() and stat(); retry.
        continue;
      }

      if (Date.now() - started > timeoutMs) {
        throw new ToolError(
          "LOCK_TIMEOUT",
          "Store lock unavailable; another bridge process may be busy",
          { retryable: true }
        );
      }
      await new Promise((resolve) => setTimeout(resolve, retryMs));
      continue;
    }

    try {
      await handle.writeFile(String(process.pid));
      return await fn();
    } finally {
      await handle.close().catch(() => {});
      await fs.unlink(lockPath).catch(() => {});
    }
  }
}
