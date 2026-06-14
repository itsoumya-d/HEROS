export type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonValue[] | { [key: string]: JsonValue };
export type JsonObject = { [key: string]: JsonValue };

export interface JsonSchema {
  type?: "object" | "array" | "string" | "number" | "integer" | "boolean";
  required?: string[];
  additionalProperties?: boolean;
  properties?: Record<string, JsonSchema>;
  items?: JsonSchema;
  minItems?: number;
  maxItems?: number;
  minLength?: number;
  maxLength?: number;
  minimum?: number;
  maximum?: number;
  pattern?: string;
  enum?: JsonValue[];
  safeText?: boolean;
}

export interface ActionAnnotations {
  readOnly?: boolean;
  destructive?: boolean;
  idempotent?: boolean;
  decisionRequired?: boolean;
}

export interface PublicAction {
  name: string;
  title: string;
  description: string;
  inputSchema: JsonSchema;
  authRequired: boolean;
  approvalRequired: boolean;
  annotations: Required<ActionAnnotations>;
}

export interface AuthorizationResult {
  ok?: boolean;
  principal?: string;
  scopes?: string[];
}

export interface AuthorizationRequest {
  action: PublicAction;
  input: JsonObject;
  context: JsonObject;
}

export type AuthorizeCallback =
  (request: AuthorizationRequest) => boolean | AuthorizationResult | Promise<boolean | AuthorizationResult>;

export interface Receipt {
  receipt_id: string;
  action: string;
  input_hash: string;
  result_hash: string;
  principal: string;
  approval: {
    required: boolean;
    approved_by?: string;
    approved_at?: string;
    token_hash?: string;
  };
  idempotency_key: string | null;
  annotations: Required<ActionAnnotations>;
  metadata: JsonObject;
  created_at: string;
}

export interface SuccessResponse {
  ok: true;
  action: string;
  result: JsonValue;
  receipt: Receipt;
  _idempotent: boolean;
}

export interface FailureResponse {
  ok: false;
  error_code: string;
  error: string;
  retryable: boolean;
  issues?: string[];
  approval?: {
    approval_token: string;
    action: string;
    expires_at: string;
  };
  reason?: string;
  message?: string;
}

export type ExecuteResponse = SuccessResponse | FailureResponse;

export interface ReceiptStore {
  append(receipt: Receipt): Promise<Receipt>;
  findByIdempotencyKey(key: string): Promise<{ action_hash: string; response: ExecuteResponse } | null>;
  recordIdempotency(key: string, actionHash: string, response: ExecuteResponse): Promise<void>;
  list(): Promise<Receipt[]>;
}

export interface ApprovalStore {
  issue(request: {
    action: string;
    inputHash: string;
    principal?: string;
    now?: Date;
  }): Promise<{
    approval_token: string;
    action: string;
    expires_at: string;
  }>;
  redeem(request: {
    approvalToken: string;
    action: string;
    inputHash: string;
    now?: Date;
  }): Promise<{
    ok: boolean;
    reason?: string;
    approved_by?: string;
    approved_at?: string;
    token_hash?: string;
  }>;
}

export interface AgenticAppOptions {
  name?: string;
  version?: string;
  description?: string;
  protocolVersion?: string;
  authorize?: AuthorizeCallback;
  receiptStore?: ReceiptStore;
  approvalStore?: ApprovalStore;
  clock?: () => Date;
}

export interface ActionHandlerRequest {
  input: JsonObject;
  context: JsonObject;
  auth: AuthorizationResult & { ok: true; principal: string };
  approval: null | {
    ok: true;
    approved_by: string;
    approved_at: string;
    token_hash: string;
  };
  action: PublicAction;
}

export type ActionHandler = (request: ActionHandlerRequest) => JsonValue | Promise<JsonValue>;

export interface ActionConfig {
  name: string;
  title?: string;
  description?: string;
  inputSchema: JsonSchema & { type: "object" };
  authRequired?: boolean;
  approvalRequired?: boolean;
  annotations?: ActionAnnotations;
  receiptMetadata?: JsonObject;
  handler: ActionHandler;
}

export interface AgenticManifest {
  schema_version: 1;
  mcp_protocol_version: string;
  name: string;
  version: string;
  description: string;
  tools: Array<{
    name: string;
    title: string;
    description: string;
    input_schema: JsonSchema;
    annotations: Required<ActionAnnotations>;
  }>;
}

export class AgenticApp {
  constructor(options?: AgenticAppOptions);
  action(config: ActionConfig): this;
  manifest(): AgenticManifest;
  execute(request?: {
    name?: string;
    input?: JsonObject;
    context?: JsonObject;
    idempotencyKey?: string;
    approvalToken?: string;
  }): Promise<ExecuteResponse>;
}

export function createAgenticApp(options?: AgenticAppOptions): AgenticApp;
export function createMemoryReceiptStore(): ReceiptStore;
export function createFileReceiptStore(options: { path: string }): ReceiptStore;
export function createMemoryApprovalStore(options?: { ttlMs?: number }): ApprovalStore;
export function createFileApprovalStore(options: { path: string; ttlMs?: number }): ApprovalStore;
export function canonicalStringify(value: JsonValue): string;
