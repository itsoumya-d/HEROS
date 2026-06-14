#!/usr/bin/env node
import { mkdir, readdir, stat, writeFile } from "node:fs/promises";
import { basename, join, resolve } from "node:path";
import { createAgenticApp } from "../src/index.js";

const VERSION = "0.1.0";

const [command, ...rest] = process.argv.slice(2);

try {
  if (!command || command === "help" || command === "--help" || command === "-h") {
    printHelp();
  } else if (command === "doctor") {
    await doctor();
  } else if (command === "init") {
    await init(rest);
  } else {
    jsonExit({
      ok: false,
      error_code: "UNKNOWN_COMMAND",
      error: `Unknown command: ${command}`,
      retryable: false
    }, 1);
  }
} catch (error) {
  jsonExit({
    ok: false,
    error_code: "COMMAND_FAILED",
    error: safeError(error),
    retryable: false
  }, 1);
}

function printHelp() {
  console.log(`HEROS Agentic CLI ${VERSION}

Usage:
  heros-agentic init [directory] [--force]
  heros-agentic doctor

Commands:
  init      Create a minimal Node website with HEROS agent actions.
  doctor    Print JSON environment readiness for @heros/agentic.

Examples:
  npx @heros/agentic init my-agentic-site
  npx @heros/agentic doctor
`);
}

async function doctor() {
  const app = createAgenticApp({
    name: "heros-agentic-doctor",
    version: VERSION
  });
  app.action({
    name: "doctor.ping",
    title: "Doctor ping",
    description: "Checks that the SDK can register and execute actions.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      properties: {}
    },
    annotations: {
      readOnly: true
    },
    handler: () => ({ pong: true })
  });

  const response = await app.execute({
    name: "doctor.ping",
    input: {}
  });
  const nodeMajor = Number(process.versions.node.split(".")[0]);

  jsonExit({
    ok: nodeMajor >= 20 && response.ok === true,
    package: "@heros/agentic",
    version: VERSION,
    node: process.versions.node,
    platform: process.platform,
    arch: process.arch,
    checks: {
      node_20_or_newer: nodeMajor >= 20,
      action_registry: app.manifest().tools.length === 1,
      execute: response.ok === true,
      receipt: response.ok === true && response.receipt.receipt_id.startsWith("hr_")
    }
  }, nodeMajor >= 20 && response.ok === true ? 0 : 1);
}

async function init(args) {
  const force = args.includes("--force");
  const targetArg = args.find((arg) => !arg.startsWith("-")) || "heros-agentic-site";
  const targetDir = resolve(targetArg);

  await assertWritableTarget(targetDir, force);
  await mkdir(targetDir, { recursive: true });
  await mkdir(join(targetDir, ".heros"), { recursive: true });

  const appName = safePackageName(basename(targetDir) || "heros-agentic-site");
  const files = {
    "package.json": packageJson(appName),
    "server.mjs": serverTemplate(),
    "README.md": readmeTemplate(appName),
    ".env.example": envExample(),
    ".gitignore": gitignoreTemplate()
  };

  for (const [name, contents] of Object.entries(files)) {
    await writeFile(join(targetDir, name), contents);
  }

  jsonExit({
    ok: true,
    directory: targetDir,
    files: Object.keys(files),
    next_steps: [
      `cd ${targetDir}`,
      "npm install",
      "cp .env.example .env",
      "npm start"
    ],
    endpoints: [
      "GET /",
      "GET /heros/manifest",
      "POST /heros/actions"
    ]
  });
}

async function assertWritableTarget(targetDir, force) {
  try {
    const info = await stat(targetDir);
    if (!info.isDirectory()) {
      throw new Error(`${targetDir} exists and is not a directory.`);
    }
    const entries = await readdir(targetDir);
    if (entries.length > 0 && !force) {
      throw new Error(`${targetDir} is not empty. Re-run with --force to overwrite starter files.`);
    }
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return;
    }
    throw error;
  }
}

function packageJson(name) {
  return `${JSON.stringify({
    name,
    version: "0.1.0",
    private: true,
    type: "module",
    scripts: {
      start: "node server.mjs",
      doctor: "node server.mjs --doctor"
    },
    dependencies: {
      "@heros/agentic": "^0.1.0"
    },
    engines: {
      node: ">=20"
    }
  }, null, 2)}\n`;
}

function serverTemplate() {
  return `import { createServer } from "node:http";
import {
  createAgenticApp,
  createFileApprovalStore,
  createFileReceiptStore
} from "@heros/agentic";

const port = Number(process.env.PORT || 3000);
const agentApiKey = process.env.AGENT_API_KEY || "dev-agent-key";
const tasks = [];

const heros = createAgenticApp({
  name: "starter-site",
  version: "0.1.0",
  description: "Starter HEROS agent action surface.",
  receiptStore: createFileReceiptStore({ path: ".heros/receipts.json" }),
  approvalStore: createFileApprovalStore({ path: ".heros/approvals.json" }),
  authorize: ({ context }) => context.apiKey === agentApiKey
    ? { principal: "agent:starter", scopes: ["tasks:write"] }
    : false
});

heros.action({
  name: "site.status",
  title: "Site status",
  description: "Returns basic status for this website.",
  inputSchema: {
    type: "object",
    additionalProperties: false,
    properties: {}
  },
  annotations: {
    readOnly: true
  },
  handler: () => ({
    ok: true,
    task_count: tasks.length
  })
});

heros.action({
  name: "tasks.create",
  title: "Create task",
  description: "Creates a simple task after authenticated agent request.",
  inputSchema: {
    type: "object",
    required: ["title"],
    additionalProperties: false,
    properties: {
      title: {
        type: "string",
        minLength: 1,
        maxLength: 80,
        safeText: true
      }
    }
  },
  authRequired: true,
  annotations: {
    idempotent: true
  },
  handler: ({ input, auth }) => {
    const task = {
      id: \`task_\${tasks.length + 1}\`,
      title: input.title,
      created_by: auth.principal
    };
    tasks.push(task);
    return task;
  }
});

const server = createServer(async (req, res) => {
  const url = new URL(req.url || "/", \`http://\${req.headers.host || "127.0.0.1"}\`);

  if (req.method === "GET" && url.pathname === "/") {
    return sendHtml(res, html());
  }

  if (req.method === "GET" && url.pathname === "/heros/manifest") {
    return sendJson(res, 200, heros.manifest());
  }

  if (req.method === "POST" && url.pathname === "/heros/actions") {
    const body = await readJson(req);
    if (!body.ok || !isObject(body.value)) {
      return sendJson(res, 400, failure("BAD_JSON", "Request body must be a valid JSON object."));
    }

    const response = await heros.execute({
      name: body.value.name,
      input: body.value.input,
      context: {
        apiKey: parseBearer(req.headers.authorization || "")
      },
      idempotencyKey: body.value.idempotencyKey,
      approvalToken: body.value.approvalToken
    });
    return sendJson(res, response.ok ? 200 : 400, response);
  }

  return sendJson(res, 404, failure("NOT_FOUND", "No route matches the request."));
});

if (process.argv.includes("--doctor")) {
  console.log(JSON.stringify({
    ok: true,
    manifest_tools: heros.manifest().tools.map((tool) => tool.name)
  }, null, 2));
} else {
  server.listen(port, "127.0.0.1", () => {
    console.log(JSON.stringify({
      ok: true,
      url: \`http://127.0.0.1:\${port}\`,
      manifest: \`http://127.0.0.1:\${port}/heros/manifest\`,
      actions: \`http://127.0.0.1:\${port}/heros/actions\`
    }, null, 2));
  });
}

async function readJson(req) {
  let body = "";
  for await (const chunk of req) {
    body += chunk;
    if (body.length > 32_000) {
      return { ok: false };
    }
  }
  try {
    return { ok: true, value: body ? JSON.parse(body) : {} };
  } catch {
    return { ok: false };
  }
}

function parseBearer(header) {
  const prefix = "Bearer ";
  return header.startsWith(prefix) ? header.slice(prefix.length) : "";
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function failure(errorCode, error) {
  return {
    ok: false,
    error_code: errorCode,
    error,
    retryable: false
  };
}

function sendJson(res, status, value) {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(value, null, 2));
}

function sendHtml(res, value) {
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  res.end(value);
}

function html() {
  return \`<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>HEROS Agentic Starter</title>
  </head>
  <body>
    <main>
      <h1>HEROS Agentic Starter</h1>
      <p>Manifest: <a href="/heros/manifest">/heros/manifest</a></p>
      <p>Action endpoint: <code>POST /heros/actions</code></p>
    </main>
  </body>
</html>\`;
}
`;
}

function readmeTemplate(name) {
  return `# ${name}

Starter website generated by \`@heros/agentic\`.

## Run

\`\`\`bash
npm install
cp .env.example .env
npm start
\`\`\`

Open <http://127.0.0.1:3000/heros/manifest>.

## Agent Action Call

\`\`\`bash
curl -s http://127.0.0.1:3000/heros/actions \\
  -H 'content-type: application/json' \\
  -H 'authorization: Bearer dev-agent-key' \\
  -d '{"name":"tasks.create","input":{"title":"Review launch checklist"},"idempotencyKey":"task-1"}'
\`\`\`

Change \`AGENT_API_KEY\` before using this outside local development.
`;
}

function envExample() {
  return `PORT=3000
AGENT_API_KEY=dev-agent-key
`;
}

function gitignoreTemplate() {
  return `node_modules/
.env
.heros/
`;
}

function safePackageName(value) {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "") || "heros-agentic-site";
}

function safeError(error) {
  const message = error instanceof Error ? error.message : String(error);
  return /^[\x20-\x7E]*$/.test(message) ? message.slice(0, 240) : "non-printable error message";
}

function jsonExit(value, status = 0) {
  console.log(JSON.stringify(value, null, 2));
  process.exit(status);
}
