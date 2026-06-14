import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, stat } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";

const cliPath = resolve("packages/agentic/bin/heros-agentic.mjs");

test("doctor reports a usable SDK environment", () => {
  const result = spawnSync(process.execPath, [cliPath, "doctor"], {
    encoding: "utf8"
  });

  assert.equal(result.status, 0, result.stderr);
  const body = JSON.parse(result.stdout);
  assert.equal(body.ok, true);
  assert.equal(body.package, "@heros/agentic");
  assert.equal(body.checks.node_20_or_newer, true);
  assert.equal(body.checks.action_registry, true);
  assert.equal(body.checks.execute, true);
  assert.equal(body.checks.receipt, true);
});

test("init creates a starter site without overwriting non-empty directories", async () => {
  const dir = await mkdtemp(join(tmpdir(), "heros-init-"));
  const target = join(dir, "Starter Site");

  const created = spawnSync(process.execPath, [cliPath, "init", target], {
    encoding: "utf8"
  });
  assert.equal(created.status, 0, created.stderr);

  const body = JSON.parse(created.stdout);
  assert.equal(body.ok, true);
  assert.equal(body.directory, target);
  assert.deepEqual(body.endpoints, [
    "GET /",
    "GET /heros/manifest",
    "POST /heros/actions"
  ]);

  const packageJson = JSON.parse(await readFile(join(target, "package.json"), "utf8"));
  assert.equal(packageJson.name, "starter-site");
  assert.equal(packageJson.dependencies["@heros/agentic"], "^0.1.0");
  await stat(join(target, "server.mjs"));
  await stat(join(target, ".env.example"));

  const syntax = spawnSync(process.execPath, ["--check", join(target, "server.mjs")], {
    encoding: "utf8"
  });
  assert.equal(syntax.status, 0, syntax.stderr);

  const blocked = spawnSync(process.execPath, [cliPath, "init", target], {
    encoding: "utf8"
  });
  assert.equal(blocked.status, 1);
  assert.equal(JSON.parse(blocked.stdout).error_code, "COMMAND_FAILED");
});
