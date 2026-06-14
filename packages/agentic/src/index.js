import { createHash, randomBytes } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

const DEFAULT_PROTOCOL_VERSION = "2025-11-25";
const ACTION_NAME_RE = /^[A-Za-z0-9_.:-]{1,96}$/;
const IDEMPOTENCY_KEY_RE = /^[A-Za-z0-9_.:-]{1,160}$/;
const SAFE_TEXT_RE = /^[\x20-\x7E]*$/;

const ERROR = {
  UNKNOWN_ACTION: "UNKNOWN_ACTION",
  INVALID_INPUT: "INVALID_INPUT",
  UNAUTHORIZED: "UNAUTHORIZED",
  APPROVAL_REQUIRED: "APPROVAL_REQUIRED",
  INVALID_APPROVAL_TOKEN: "INVALID_APPROVAL_TOKEN",
  IDEMPOTENCY_CONFLICT: "IDEMPOTENCY_CONFLICT",
  ACTION_FAILED: "ACTION_FAILED"
};

export function createAgenticApp(options = {}) {
  return new AgenticApp(options);
}

export function createMemoryReceiptStore() {
  const receipts = [];
  const idempotency = new Map();

  return {
    async append(receipt) {
      const saved = cloneJson(receipt);
      receipts.push(saved);
      return cloneJson(saved);
    },
    async findByIdempotencyKey(key) {
      const entry = idempotency.get(key);
      return entry ? cloneJson(entry) : null;
    },
    async recordIdempotency(key, actionHash, response) {
      idempotency.set(key, {
        action_hash: actionHash,
        response: cloneJson(response)
      });
    },
    async list() {
      return cloneJson(receipts);
    }
  };
}

export function createFileReceiptStore({ path }) {
  if (!path || typeof path !== "string") {
    throw new Error("createFileReceiptStore requires a file path.");
  }

  let writeChain = Promise.resolve();

  async function readState() {
    try {
      const parsed = JSON.parse(await readFile(path, "utf8"));
      return {
        receipts: Array.isArray(parsed.receipts) ? parsed.receipts : [],
        idempotency: isObject(parsed.idempotency) ? parsed.idempotency : {}
      };
    } catch (error) {
      if (error && error.code === "ENOENT") {
        return { receipts: [], idempotency: {} };
      }
      throw error;
    }
  }

  async function writeState(state) {
    await mkdir(dirname(path), { recursive: true });
    const tempPath = `${path}.${process.pid}.${Date.now()}.${randomBytes(6).toString("hex")}.tmp`;
    await writeFile(tempPath, `${JSON.stringify(state, null, 2)}\n`);
    await rename(tempPath, path);
  }

  function enqueue(mutator) {
    const run = writeChain.catch(() => {}).then(async () => {
      const state = await readState();
      const result = await mutator(state);
      await writeState(state);
      return result;
    });
    writeChain = run.then(() => undefined, () => undefined);
    return run;
  }

  return {
    async append(receipt) {
      return enqueue((state) => {
        const saved = cloneJson(receipt);
        state.receipts.push(saved);
        return cloneJson(saved);
      });
    },
    async findByIdempotencyKey(key) {
      await writeChain;
      const state = await readState();
      const entry = state.idempotency[key];
      return entry ? cloneJson(entry) : null;
    },
    async recordIdempotency(key, actionHash, response) {
      await enqueue((state) => {
        state.idempotency[key] = {
          action_hash: actionHash,
          response: cloneJson(response)
        };
      });
    },
    async list() {
      await writeChain;
      const state = await readState();
      return cloneJson(state.receipts);
    }
  };
}

export function createMemoryApprovalStore({ ttlMs = 5 * 60 * 1000 } = {}) {
  const tokens = new Map();

  return {
    async issue({ action, inputHash, principal, now = new Date() }) {
      const token = `ha_${randomBytes(18).toString("hex")}`;
      const expiresAt = new Date(now.getTime() + ttlMs);
      tokens.set(token, {
        action,
        input_hash: inputHash,
        principal: principal || "human",
        expires_at: expiresAt.toISOString(),
        used_at: null
      });

      return {
        approval_token: token,
        action,
        expires_at: expiresAt.toISOString()
      };
    },
    async redeem({ approvalToken, action, inputHash, now = new Date() }) {
      const token = tokens.get(approvalToken);
      if (!token) {
        return { ok: false, reason: "missing" };
      }
      if (token.used_at) {
        return { ok: false, reason: "used" };
      }
      if (new Date(token.expires_at).getTime() <= now.getTime()) {
        return { ok: false, reason: "expired" };
      }
      if (token.action !== action || token.input_hash !== inputHash) {
        return { ok: false, reason: "mismatch" };
      }

      token.used_at = now.toISOString();
      return {
        ok: true,
        approved_by: token.principal,
        approved_at: token.used_at,
        token_hash: hashValue(approvalToken)
      };
    }
  };
}

export function createFileApprovalStore({ path, ttlMs = 5 * 60 * 1000 }) {
  if (!path || typeof path !== "string") {
    throw new Error("createFileApprovalStore requires a file path.");
  }

  let writeChain = Promise.resolve();

  async function readState() {
    try {
      const parsed = JSON.parse(await readFile(path, "utf8"));
      return {
        tokens: isObject(parsed.tokens) ? parsed.tokens : {}
      };
    } catch (error) {
      if (error && error.code === "ENOENT") {
        return { tokens: {} };
      }
      throw error;
    }
  }

  async function writeState(state) {
    await mkdir(dirname(path), { recursive: true });
    const tempPath = `${path}.${process.pid}.${Date.now()}.${randomBytes(6).toString("hex")}.tmp`;
    await writeFile(tempPath, `${JSON.stringify(state, null, 2)}\n`);
    await rename(tempPath, path);
  }

  function enqueue(mutator) {
    const run = writeChain.catch(() => {}).then(async () => {
      const state = await readState();
      const result = await mutator(state);
      await writeState(state);
      return result;
    });
    writeChain = run.then(() => undefined, () => undefined);
    return run;
  }

  return {
    async issue({ action, inputHash, principal, now = new Date() }) {
      return enqueue((state) => {
        const token = `ha_${randomBytes(18).toString("hex")}`;
        const expiresAt = new Date(now.getTime() + ttlMs);
        state.tokens[token] = {
          action,
          input_hash: inputHash,
          principal: principal || "human",
          expires_at: expiresAt.toISOString(),
          used_at: null
        };

        return {
          approval_token: token,
          action,
          expires_at: expiresAt.toISOString()
        };
      });
    },
    async redeem({ approvalToken, action, inputHash, now = new Date() }) {
      return enqueue((state) => {
        const token = state.tokens[approvalToken];
        if (!token) {
          return { ok: false, reason: "missing" };
        }
        if (token.used_at) {
          return { ok: false, reason: "used" };
        }
        if (new Date(token.expires_at).getTime() <= now.getTime()) {
          return { ok: false, reason: "expired" };
        }
        if (token.action !== action || token.input_hash !== inputHash) {
          return { ok: false, reason: "mismatch" };
        }

        token.used_at = now.toISOString();
        return {
          ok: true,
          approved_by: token.principal,
          approved_at: token.used_at,
          token_hash: hashValue(approvalToken)
        };
      });
    }
  };
}

export function canonicalStringify(value) {
  return JSON.stringify(canonicalize(value));
}

export class AgenticApp {
  constructor(options = {}) {
    this.name = assertSafeText(options.name || "heros-agentic-app", "app name", 80);
    this.version = assertSafeText(options.version || "0.1.0", "app version", 40);
    this.description = assertSafeText(options.description || "", "app description", 240);
    this.protocolVersion = options.protocolVersion || DEFAULT_PROTOCOL_VERSION;
    this.authorize = options.authorize || defaultAuthorize;
    this.receiptStore = options.receiptStore || createMemoryReceiptStore();
    this.approvalStore = options.approvalStore || createMemoryApprovalStore();
    this.clock = options.clock || (() => new Date());
    this.actions = new Map();
  }

  action(config = {}) {
    const action = normalizeAction(config);
    if (this.actions.has(action.name)) {
      throw new Error(`Action already registered: ${action.name}`);
    }
    this.actions.set(action.name, action);
    return this;
  }

  manifest() {
    const tools = [...this.actions.values()]
      .sort((left, right) => left.name.localeCompare(right.name))
      .map((action) => ({
        name: action.name,
        title: action.title,
        description: action.description,
        input_schema: cloneJson(action.inputSchema),
        annotations: cloneJson(action.annotations)
      }));

    return {
      schema_version: 1,
      mcp_protocol_version: this.protocolVersion,
      name: this.name,
      version: this.version,
      description: this.description,
      tools
    };
  }

  async execute(request = {}) {
    const actionName = request.name;
    const action = this.actions.get(actionName);
    if (!action) {
      return failure(ERROR.UNKNOWN_ACTION, "No registered action matches the request.", false);
    }

    const input = request.input ?? {};
    const validation = validateInput(action.inputSchema, input);
    if (!validation.ok) {
      return failure(ERROR.INVALID_INPUT, "Input does not match the action schema.", false, {
        issues: validation.issues
      });
    }

    const idempotencyKey = request.idempotencyKey;
    if (idempotencyKey !== undefined && !IDEMPOTENCY_KEY_RE.test(idempotencyKey)) {
      return failure(ERROR.INVALID_INPUT, "Idempotency key must be ASCII letters, digits, dot, colon, underscore, or dash.", false);
    }

    const context = request.context || {};
    const inputHash = hashValue(input);
    const actionHash = hashValue({ name: action.name, input });
    const now = this.clock();

    if (idempotencyKey) {
      const existing = await this.receiptStore.findByIdempotencyKey(idempotencyKey);
      if (existing) {
        if (existing.action_hash !== actionHash) {
          return failure(ERROR.IDEMPOTENCY_CONFLICT, "Idempotency key was already used for different action input.", false);
        }
        return {
          ...cloneJson(existing.response),
          _idempotent: true
        };
      }
    }

    const auth = await this.resolveAuthorization(action, input, context);
    if (!auth.ok) {
      return failure(ERROR.UNAUTHORIZED, "Action requires an authenticated and authorized caller.", false);
    }

    let approval = null;
    if (action.approvalRequired) {
      if (!request.approvalToken) {
        const issued = await this.approvalStore.issue({
          action: action.name,
          inputHash,
          principal: auth.principal,
          now
        });
        return failure(ERROR.APPROVAL_REQUIRED, "Human approval required before executing action.", true, {
          approval: issued
        });
      }

      approval = await this.approvalStore.redeem({
        approvalToken: request.approvalToken,
        action: action.name,
        inputHash,
        now
      });
      if (!approval.ok) {
        return failure(ERROR.INVALID_APPROVAL_TOKEN, "Approval token is missing, expired, reused, or bound to different input.", false, {
          reason: approval.reason
        });
      }
    }

    try {
      const result = await action.handler({
        input: cloneJson(input),
        context: cloneJson(context),
        auth: cloneJson(auth),
        approval: approval ? cloneJson(approval) : null,
        action: publicAction(action)
      });
      const safeResult = cloneJson(result ?? {});
      const receipt = {
        receipt_id: `hr_${randomBytes(16).toString("hex")}`,
        action: action.name,
        input_hash: inputHash,
        result_hash: hashValue(safeResult),
        principal: auth.principal,
        approval: action.approvalRequired
          ? {
              required: true,
              approved_by: approval.approved_by,
              approved_at: approval.approved_at,
              token_hash: approval.token_hash
            }
          : {
              required: false
            },
        idempotency_key: idempotencyKey || null,
        annotations: cloneJson(action.annotations),
        metadata: cloneJson(action.receiptMetadata),
        created_at: now.toISOString()
      };

      await this.receiptStore.append(receipt);

      const response = {
        ok: true,
        action: action.name,
        result: safeResult,
        receipt,
        _idempotent: false
      };

      if (idempotencyKey) {
        await this.receiptStore.recordIdempotency(idempotencyKey, actionHash, response);
      }

      return response;
    } catch (error) {
      return failure(ERROR.ACTION_FAILED, "Action handler failed.", false, {
        message: safeErrorMessage(error)
      });
    }
  }

  async resolveAuthorization(action, input, context) {
    if (!action.authRequired) {
      return {
        ok: true,
        principal: context.principal || context.user || "anonymous"
      };
    }

    const result = await this.authorize({
      action: publicAction(action),
      input: cloneJson(input),
      context: cloneJson(context)
    });

    if (result === true) {
      return {
        ok: true,
        principal: context.principal || context.user || "authenticated"
      };
    }
    if (result && result.ok !== false) {
      return {
        ok: true,
        principal: result.principal || context.principal || context.user || "authenticated",
        scopes: Array.isArray(result.scopes) ? [...result.scopes] : []
      };
    }
    return { ok: false };
  }
}

function normalizeAction(config) {
  if (!ACTION_NAME_RE.test(config.name || "")) {
    throw new Error("Action name must be 1-96 ASCII letters, digits, dot, colon, underscore, or dash.");
  }
  if (typeof config.handler !== "function") {
    throw new Error(`Action ${config.name} requires a handler function.`);
  }
  if (!config.inputSchema || config.inputSchema.type !== "object") {
    throw new Error(`Action ${config.name} requires an object inputSchema.`);
  }

  return {
    name: config.name,
    title: assertSafeText(config.title || config.name, "action title", 96),
    description: assertSafeText(config.description || "", "action description", 512),
    inputSchema: cloneJson(config.inputSchema),
    authRequired: config.authRequired === true,
    approvalRequired: config.approvalRequired === true,
    annotations: normalizeAnnotations(config.annotations || {}, config.approvalRequired === true),
    receiptMetadata: cloneJson(config.receiptMetadata || {}),
    handler: config.handler
  };
}

function normalizeAnnotations(annotations, approvalRequired) {
  return {
    readOnly: annotations.readOnly === true,
    destructive: annotations.destructive === true,
    idempotent: annotations.idempotent === true,
    decisionRequired: approvalRequired || annotations.decisionRequired === true
  };
}

function publicAction(action) {
  return {
    name: action.name,
    title: action.title,
    description: action.description,
    inputSchema: cloneJson(action.inputSchema),
    authRequired: action.authRequired,
    approvalRequired: action.approvalRequired,
    annotations: cloneJson(action.annotations)
  };
}

function defaultAuthorize({ context }) {
  if (context.principal || context.user || context.apiKey || context.authorization) {
    return {
      ok: true,
      principal: context.principal || context.user || "authenticated"
    };
  }
  return false;
}

function validateInput(schema, value) {
  const issues = [];
  validateAgainstSchema(schema, value, "$", issues);
  return {
    ok: issues.length === 0,
    issues
  };
}

function validateAgainstSchema(schema, value, path, issues) {
  const type = schema.type || "object";

  if (!matchesType(type, value)) {
    issues.push(`${path} must be ${type}.`);
    return;
  }

  if (type === "object") {
    const properties = schema.properties || {};
    const required = schema.required || [];

    for (const key of required) {
      if (!Object.hasOwn(value, key)) {
        issues.push(`${path}.${key} is required.`);
      }
    }

    for (const [key, childValue] of Object.entries(value)) {
      if (!Object.hasOwn(properties, key)) {
        if (schema.additionalProperties === false) {
          issues.push(`${path}.${key} is not allowed.`);
        }
        continue;
      }
      validateAgainstSchema(properties[key], childValue, `${path}.${key}`, issues);
    }
    return;
  }

  if (type === "array") {
    const items = schema.items || {};
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      issues.push(`${path} must contain at least ${schema.minItems} items.`);
    }
    if (schema.maxItems !== undefined && value.length > schema.maxItems) {
      issues.push(`${path} must contain at most ${schema.maxItems} items.`);
    }
    value.forEach((item, index) => validateAgainstSchema(items, item, `${path}[${index}]`, issues));
    return;
  }

  if (type === "string") {
    if (schema.minLength !== undefined && value.length < schema.minLength) {
      issues.push(`${path} must be at least ${schema.minLength} characters.`);
    }
    if (schema.maxLength !== undefined && value.length > schema.maxLength) {
      issues.push(`${path} must be at most ${schema.maxLength} characters.`);
    }
    if (schema.safeText === true && !SAFE_TEXT_RE.test(value)) {
      issues.push(`${path} must be printable ASCII with no control characters.`);
    }
    if (schema.pattern && !new RegExp(schema.pattern).test(value)) {
      issues.push(`${path} does not match required pattern.`);
    }
  }

  if (type === "number" || type === "integer") {
    if (schema.minimum !== undefined && value < schema.minimum) {
      issues.push(`${path} must be at least ${schema.minimum}.`);
    }
    if (schema.maximum !== undefined && value > schema.maximum) {
      issues.push(`${path} must be at most ${schema.maximum}.`);
    }
  }

  if (schema.enum && !schema.enum.includes(value)) {
    issues.push(`${path} must be one of ${schema.enum.join(", ")}.`);
  }
}

function matchesType(type, value) {
  if (type === "array") {
    return Array.isArray(value);
  }
  if (type === "object") {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  }
  if (type === "integer") {
    return Number.isInteger(value);
  }
  return typeof value === type;
}

function failure(errorCode, message, retryable, details = {}) {
  return {
    ok: false,
    error_code: errorCode,
    error: message,
    retryable,
    ...cloneJson(details)
  };
}

function assertSafeText(value, label, maxLength) {
  if (typeof value !== "string" || value.length < 1 && label !== "app description" && label !== "action description") {
    throw new Error(`${label} must be a string.`);
  }
  if (value.length > maxLength) {
    throw new Error(`${label} must be at most ${maxLength} characters.`);
  }
  if (!SAFE_TEXT_RE.test(value)) {
    throw new Error(`${label} must be printable ASCII with no control characters.`);
  }
  return value;
}

function hashValue(value) {
  return createHash("sha256").update(canonicalStringify(value)).digest("hex");
}

function canonicalize(value) {
  if (Array.isArray(value)) {
    return value.map(canonicalize);
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, item]) => [key, canonicalize(item)])
    );
  }
  return value;
}

function cloneJson(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function safeErrorMessage(error) {
  const message = error instanceof Error ? error.message : String(error);
  return SAFE_TEXT_RE.test(message) ? message.slice(0, 240) : "non-printable error message";
}
