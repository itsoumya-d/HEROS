import test from "node:test";
import assert from "node:assert/strict";
import { copyFile, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";

const cliPath = resolve("packages/agentic/bin/heros-agentic.mjs");
const sdkPath = resolve("packages/agentic");

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

test("generated starter reads .env port and key without interpreting shell or Node options", async (t) => {
  const target = await createStarter(t);
  await writeFile(join(target, ".env"), [
    "# Synthetic starter configuration",
    "PORT = 4321 # local port",
    "AGENT_API_KEY='fixture-雪 # $(no-shell)'",
    "NODE_OPTIONS=--require=./must-not-execute.cjs",
    ""
  ].join("\r\n"));
  const result = probeStarter(target, {}, ["fixture-雪 # $(no-shell)", "dev-agent-key"]);
  assert.equal(result.port, 4321);
  assert.equal(result.host, "127.0.0.1");
  assert.deepEqual(result.authorized, [true, false]);
});

test("generated starter preserves process environment precedence", async (t) => {
  const target = await createStarter(t);
  await writeFile(join(target, ".env"), "PORT=4321\nAGENT_API_KEY=file-fixture-key\n");
  const result = probeStarter(target, {
    PORT: "5432",
    AGENT_API_KEY: "process-fixture-key"
  }, ["process-fixture-key", "file-fixture-key", "dev-agent-key"]);
  assert.equal(result.port, 5432);
  assert.deepEqual(result.authorized, [true, false, false]);
});

test("generated starter reads .env beside server.mjs from a different working directory", async (t) => {
  const target = await createStarter(t);
  const cwd = await mkdtemp(join(tmpdir(), "heros-unrelated-"));
  t.after(() => rm(cwd, { recursive: true, force: true }));
  await writeFile(join(target, ".env"), "PORT=4321\nAGENT_API_KEY=starter-fixture-key\n");
  await writeFile(join(cwd, ".env"), "PORT=5432\nAGENT_API_KEY=unrelated-fixture-key\n");
  const result = probeStarter(target, {}, ["starter-fixture-key", "unrelated-fixture-key"], cwd);
  assert.equal(result.port, 4321);
  assert.deepEqual(result.authorized, [true, false]);
});

test("generated starter keeps defaults without .env and respects explicitly empty environment values", async (t) => {
  const target = await createStarter(t);
  const missing = probeStarter(target, {}, ["dev-agent-key", "wrong-fixture-key"]);
  assert.equal(missing.port, 3000);
  assert.deepEqual(missing.authorized, [true, false]);

  await writeFile(join(target, ".env"), "PORT=4321\nAGENT_API_KEY=file-fixture-key\n");
  const empty = probeStarter(target, { PORT: "", AGENT_API_KEY: "" }, ["dev-agent-key", "file-fixture-key"]);
  assert.equal(empty.port, 3000);
  assert.deepEqual(empty.authorized, [true, false]);
});

test("generated doctor loads optional .env without opening a listener", async (t) => {
  const target = await createStarter(t);
  await writeFile(join(target, ".env"), "PORT=4321\nAGENT_API_KEY=doctor-fixture-key\n");
  const result = spawnSync(process.execPath, ["probe.mjs", "--doctor"], {
    cwd: target,
    env: fixtureEnvironment(),
    encoding: "utf8",
    timeout: 10_000
  });
  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(result.stdout.trim().split("\n").at(-1));
  assert.equal(report.listening, false);
  assert.equal(report.configuredPort, "4321");
  assert.match(result.stdout, /"site.status"/);
});

test("generated starter does not hide .env read errors", async (t) => {
  const target = await createStarter(t);
  await mkdir(join(target, ".env"));
  const result = spawnSync(process.execPath, ["server.mjs", "--doctor"], {
    cwd: target,
    env: fixtureEnvironment(),
    encoding: "utf8",
    timeout: 10_000
  });
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /EISDIR/);
});

async function createStarter(t) {
  const target = await mkdtemp(join(tmpdir(), "heros-config-"));
  t.after(() => rm(target, { recursive: true, force: true }));
  const created = spawnSync(process.execPath, [cliPath, "init", target], {
    env: fixtureEnvironment(),
    encoding: "utf8",
    timeout: 10_000
  });
  assert.equal(created.status, 0, created.stderr);
  const packageJson = JSON.parse(await readFile(join(target, "package.json"), "utf8"));
  assert.equal(packageJson.scripts.start, "node server.mjs");
  assert.equal(packageJson.scripts.doctor, "node server.mjs --doctor");
  assert.equal(packageJson.engines.node, "^20.12.0 || >=21.7.0");
  const installed = join(target, "node_modules", "@heros", "agentic");
  await mkdir(join(installed, "src"), { recursive: true });
  await copyFile(join(sdkPath, "package.json"), join(installed, "package.json"));
  await copyFile(join(sdkPath, "src", "index.js"), join(installed, "src", "index.js"));
  // Exercise the generated server and real SDK without installing packages or opening sockets.
  await writeFile(join(target, "probe.mjs"), `
import { Server } from "node:http";
import { Readable } from "node:stream";
let server;
let port;
let host;
Server.prototype.listen = function (configuredPort, configuredHost, ready) {
  server = this;
  port = configuredPort;
  host = configuredHost;
  ready();
  return this;
};
await import("./server.mjs");
const authorized = [];
for (const key of JSON.parse(process.env.FIXTURE_KEYS || "[]")) {
  const req = Readable.from([JSON.stringify({ name: "tasks.create", input: { title: "Fixture task" } })]);
  req.method = "POST";
  req.url = "/heros/actions";
  req.headers = { authorization: "Bearer " + key };
  await server.listeners("request")[0](req, {
    writeHead() {},
    end(body) { authorized.push(JSON.parse(body).ok); }
  });
}
console.log(JSON.stringify({ port, host, authorized, listening: Boolean(server), configuredPort: process.env.PORT }));
`);
  return target;
}

function fixtureEnvironment(overrides = {}) {
  return {
    ...(process.env.SystemRoot ? { SystemRoot: process.env.SystemRoot } : {}),
    ...overrides
  };
}

function probeStarter(target, env, keys, cwd = target) {
  const result = spawnSync(process.execPath, [join(target, "probe.mjs")], {
    cwd,
    env: fixtureEnvironment({ ...env, FIXTURE_KEYS: JSON.stringify(keys) }),
    encoding: "utf8",
    timeout: 10_000
  });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout.trim().split("\n").at(-1));
}

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
