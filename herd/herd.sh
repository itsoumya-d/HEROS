#!/usr/bin/env bash
#
# herd.sh — GNAP-style (Git-Native Agent Protocol) agent coordination tool
# for the HEROS project.
#
# Coordinates multiple agents (e.g. a forge agent and a ledger agent) via plain
# JSON files in a git repository — no daemon, no server, no large runtime.
# herd.sh itself only reads/writes the JSON files under HERD_DIR; it does NOT
# run git. The operator (or a wrapping script) commits/pushes/pulls those files.
#
# Architecture rule (CLAUDE.md): never use `eval`; never string-concat user
# input into JSON — all data flows through `jq --arg` / `jq --argjson`.
# All outputs exit 0; errors are reported in the JSON `error_code` field.

set -euo pipefail
export LC_ALL=C.UTF-8

VERSION="0.1.0"
TOOL_NAME="herd"

HERD_DIR="${HERD_DIR:-.herd}"
AGENTS_FILE="${HERD_DIR}/agents.json"
TASKS_DIR="${HERD_DIR}/tasks"
LOCK_FILE="${HERD_DIR}/.herd-lock"

ID_RE='^[a-zA-Z0-9_.-]{1,64}$'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

# emit_error <error_code> <message> — print a JSON error object, exit 0.
emit_error() {
  local code="$1" msg="$2"
  jq -n --arg error_code "$code" --arg message "$msg" \
    '{error_code: $error_code, message: $message}'
  exit 0
}

# emit_json <jq-program> [jq-args...] — print compact JSON from a jq program.
emit_json() {
  local program="$1"
  shift
  jq -c -n "$@" "$program"
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

# validate_id <value> <field-name> — reject empty / over-long / bad-charset
# identifiers. Catches path traversal (no `/`, no `..`) because those chars
# are outside the allowed class.
validate_id() {
  local value="$1" field="$2"
  if [[ -z "$value" ]]; then
    emit_error "MISSING_FLAG" "missing required flag: ${field}"
  fi
  if [[ ! "$value" =~ $ID_RE ]]; then
    emit_error "INVALID_INPUT" "${field} must match ${ID_RE} (1-64 chars, [a-zA-Z0-9_.-], no path separators)"
  fi
}

# require_nonempty <value> <field-name> — for free-text fields (e.g. title).
require_nonempty() {
  local value="$1" field="$2"
  if [[ -z "$value" ]]; then
    emit_error "MISSING_FLAG" "missing required flag: ${field}"
  fi
}

# Reject control characters and over-long values in free-text fields.
validate_text() {
  local value="$1" field="$2"
  if [[ "$value" == *$'\n'* || "$value" == *$'\t'* || "$value" == *$'\r'* ]]; then
    emit_error "INVALID_INPUT" "${field} must not contain control characters"
  fi
  if [[ "${#value}" -gt 256 ]]; then
    emit_error "INVALID_INPUT" "${field} must be at most 256 characters"
  fi
}

require_initialized() {
  if [[ ! -d "$HERD_DIR" || ! -f "$AGENTS_FILE" || ! -d "$TASKS_DIR" ]]; then
    emit_error "NOT_INITIALIZED" "herd store not initialized at ${HERD_DIR}; run: herd.sh init"
  fi
}

# task_path <task_id> — resolve the on-disk path. The id is validated before
# this is ever called, so it cannot contain `/` or `..`.
task_path() {
  printf '%s/%s.json' "$TASKS_DIR" "$1"
}

# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------

# with_lock <fn> [args...] — run a function while holding an exclusive flock on
# LOCK_FILE. This is what makes claim/complete/release atomic across processes:
# two agents can never both claim the same open task.
LOCK_FD=""
with_lock() {
  exec {LOCK_FD}>>"$LOCK_FILE" || emit_error "STORE_WRITE_FAILED" "cannot open lock file: ${LOCK_FILE}"
  if ! flock -w 10 "$LOCK_FD"; then
    emit_error "STORE_WRITE_FAILED" "could not acquire lock within 10s: ${LOCK_FILE}"
  fi
  "$@"
  local rc=$?
  flock -u "$LOCK_FD" || true
  exec {LOCK_FD}>&- || true
  return "$rc"
}

# atomic_write <dest> — read JSON from stdin into a temp file, then rename it
# over <dest>. rename(2) within the same dir is atomic.
atomic_write() {
  local dest="$1" dir tmp
  dir="$(dirname "$dest")"
  tmp="$(mktemp "${dir}/.herd.tmp.XXXXXX")" || emit_error "STORE_WRITE_FAILED" "cannot create temp file in ${dir}"
  if ! cat >"$tmp"; then
    rm -f "$tmp"
    emit_error "STORE_WRITE_FAILED" "failed writing temp file for ${dest}"
  fi
  if ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    emit_error "STORE_WRITE_FAILED" "failed renaming temp file to ${dest}"
  fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_init() {
  mkdir -p "$TASKS_DIR" || emit_error "STORE_WRITE_FAILED" "cannot create ${TASKS_DIR}"
  if [[ ! -f "$AGENTS_FILE" ]]; then
    printf '{}\n' | atomic_write "$AGENTS_FILE"
  fi
  emit_json '{herd_dir: $d, status: "ok"}' --arg d "$HERD_DIR"
}

_do_register_agent() {
  local agent_id="$1" name="$2" ts="$3"
  local updated
  if ! updated="$(jq \
    --arg id "$agent_id" \
    --arg name "$name" \
    --arg ts "$ts" \
    '
      .[$id] = (
        (.[$id] // {registered_at: $ts})
        + {name: $name, last_heartbeat: $ts, status: "active"}
        | {name, registered_at: (.registered_at // $ts), last_heartbeat, status}
      )
    ' "$AGENTS_FILE")"; then
    emit_error "STORE_WRITE_FAILED" "failed to update agents store"
  fi
  printf '%s\n' "$updated" | atomic_write "$AGENTS_FILE"
}

cmd_register_agent() {
  local agent_id="$1" name="$2"
  validate_id "$agent_id" "--agent-id"
  require_nonempty "$name" "--name"
  validate_text "$name" "--name"
  require_initialized
  local ts
  ts="$(now_utc)"
  with_lock _do_register_agent "$agent_id" "$name" "$ts"
  emit_json '{agent_id: $id, status: "ok"}' --arg id "$agent_id"
}

_do_heartbeat() {
  local agent_id="$1" ts="$2"
  if [[ "$(jq -r --arg id "$agent_id" 'has($id)' "$AGENTS_FILE")" != "true" ]]; then
    emit_error "AGENT_NOT_FOUND" "no such agent: ${agent_id}"
  fi
  local updated
  if ! updated="$(jq --arg id "$agent_id" --arg ts "$ts" \
    '.[$id].last_heartbeat = $ts' "$AGENTS_FILE")"; then
    emit_error "STORE_WRITE_FAILED" "failed to update agents store"
  fi
  printf '%s\n' "$updated" | atomic_write "$AGENTS_FILE"
  emit_json '{agent_id: $id, last_heartbeat: $ts, status: "ok"}' \
    --arg id "$agent_id" --arg ts "$ts"
}

cmd_heartbeat() {
  local agent_id="$1"
  validate_id "$agent_id" "--agent-id"
  require_initialized
  local ts
  ts="$(now_utc)"
  with_lock _do_heartbeat "$agent_id" "$ts"
}

_do_create_task() {
  local task_id="$1" title="$2" ts="$3" path
  path="$(task_path "$task_id")"
  if [[ -e "$path" ]]; then
    emit_error "TASK_EXISTS" "task already exists: ${task_id}"
  fi
  local obj
  if ! obj="$(jq -n \
    --arg task_id "$task_id" \
    --arg title "$title" \
    --arg ts "$ts" \
    '{task_id: $task_id, title: $title, status: "open", claimed_by: null, created_at: $ts, updated_at: $ts}')"; then
    emit_error "STORE_WRITE_FAILED" "failed to build task object"
  fi
  printf '%s\n' "$obj" | atomic_write "$path"
  printf '%s\n' "$obj" | jq -c '.'
}

cmd_create_task() {
  local task_id="$1" title="$2"
  validate_id "$task_id" "--task-id"
  require_nonempty "$title" "--title"
  validate_text "$title" "--title"
  require_initialized
  local ts
  ts="$(now_utc)"
  with_lock _do_create_task "$task_id" "$title" "$ts"
}

_do_claim_task() {
  local task_id="$1" agent_id="$2" ts="$3" path
  path="$(task_path "$task_id")"
  if [[ ! -f "$path" ]]; then
    emit_error "TASK_NOT_FOUND" "no such task: ${task_id}"
  fi
  local status
  status="$(jq -r '.status' "$path")"
  if [[ "$status" != "open" ]]; then
    emit_error "TASK_ALREADY_CLAIMED" "task ${task_id} is not open (status=${status})"
  fi
  local obj
  if ! obj="$(jq --arg agent "$agent_id" --arg ts "$ts" \
    '.status = "claimed" | .claimed_by = $agent | .updated_at = $ts' "$path")"; then
    emit_error "STORE_WRITE_FAILED" "failed to update task ${task_id}"
  fi
  printf '%s\n' "$obj" | atomic_write "$path"
  printf '%s\n' "$obj" | jq -c '.'
}

cmd_claim_task() {
  local task_id="$1" agent_id="$2"
  validate_id "$task_id" "--task-id"
  validate_id "$agent_id" "--agent-id"
  require_initialized
  local ts
  ts="$(now_utc)"
  with_lock _do_claim_task "$task_id" "$agent_id" "$ts"
}

_do_release_task() {
  local task_id="$1" ts="$2" path
  path="$(task_path "$task_id")"
  if [[ ! -f "$path" ]]; then
    emit_error "TASK_NOT_FOUND" "no such task: ${task_id}"
  fi
  local obj
  if ! obj="$(jq --arg ts "$ts" \
    '.status = "open" | .claimed_by = null | .updated_at = $ts' "$path")"; then
    emit_error "STORE_WRITE_FAILED" "failed to update task ${task_id}"
  fi
  printf '%s\n' "$obj" | atomic_write "$path"
  printf '%s\n' "$obj" | jq -c '.'
}

cmd_release_task() {
  local task_id="$1"
  validate_id "$task_id" "--task-id"
  require_initialized
  local ts
  ts="$(now_utc)"
  with_lock _do_release_task "$task_id" "$ts"
}

_do_complete_task() {
  local task_id="$1" agent_id="$2" ts="$3" path
  path="$(task_path "$task_id")"
  if [[ ! -f "$path" ]]; then
    emit_error "TASK_NOT_FOUND" "no such task: ${task_id}"
  fi
  local claimed_by
  claimed_by="$(jq -r '.claimed_by // ""' "$path")"
  if [[ "$claimed_by" != "$agent_id" ]]; then
    emit_error "WRONG_CLAIMER" "task ${task_id} is claimed by '${claimed_by}', not '${agent_id}'"
  fi
  local obj
  if ! obj="$(jq --arg ts "$ts" \
    '.status = "done" | .updated_at = $ts' "$path")"; then
    emit_error "STORE_WRITE_FAILED" "failed to update task ${task_id}"
  fi
  printf '%s\n' "$obj" | atomic_write "$path"
  printf '%s\n' "$obj" | jq -c '.'
}

cmd_complete_task() {
  local task_id="$1" agent_id="$2"
  validate_id "$task_id" "--task-id"
  validate_id "$agent_id" "--agent-id"
  require_initialized
  local ts
  ts="$(now_utc)"
  with_lock _do_complete_task "$task_id" "$agent_id" "$ts"
}

cmd_list_tasks() {
  local filter="$1"
  require_initialized
  if [[ -n "$filter" ]]; then
    case "$filter" in
      open | claimed | done) ;;
      *) emit_error "INVALID_INPUT" "--status must be one of: open, claimed, done" ;;
    esac
  fi
  local f
  shopt -s nullglob
  local files=("$TASKS_DIR"/*.json)
  shopt -u nullglob
  for f in "${files[@]}"; do
    if [[ -n "$filter" ]]; then
      jq -c --arg s "$filter" 'select(.status == $s)' "$f"
    else
      jq -c '.' "$f"
    fi
  done
}

cmd_describe() {
  jq -n \
    --arg name "$TOOL_NAME" \
    --arg version "$VERSION" \
    '{
      name: $name,
      version: $version,
      summary: "GNAP-style (Git-Native Agent Protocol) agent coordination tool. Coordinates multiple agents via JSON files in a git repo — no daemon, no server. herd.sh only reads/writes JSON under HERD_DIR; the operator commits/pushes/pulls those files with git.",
      git_native: "This tool does NOT run git. JSON files under HERD_DIR are intended to be committed and pushed by the operator (or a wrapping script). Pull before reading, push after writing.",
      env: {
        HERD_DIR: "Directory holding the herd store (default: .herd)"
      },
      data_model: {
        "agents.json": "JSON object mapping agent_id -> {name, registered_at, last_heartbeat, status}",
        "tasks/<task_id>.json": "{task_id, title, status: open|claimed|done, claimed_by, created_at, updated_at}",
        ".herd-lock": "flock lock file guarding all read-modify-write operations"
      },
      identifier_rule: "agent_id and task_id must match ^[a-zA-Z0-9_.-]{1,64}$ (no path separators, no traversal)",
      commands: [
        {name: "--describe", flags: [], desc: "Print this descriptor as JSON"},
        {name: "init", flags: [], desc: "Create HERD_DIR, empty agents.json ({}) and tasks/. Idempotent."},
        {name: "register-agent", flags: ["--agent-id <id>", "--name <name>"], desc: "Add/refresh agent in agents.json. Idempotent; updates last_heartbeat. Returns {agent_id, status}."},
        {name: "heartbeat", flags: ["--agent-id <id>"], desc: "Update last_heartbeat. Returns {agent_id, last_heartbeat, status} or AGENT_NOT_FOUND."},
        {name: "create-task", flags: ["--task-id <id>", "--title <title>"], desc: "Create tasks/<id>.json with status open. TASK_EXISTS if present. Returns task."},
        {name: "claim-task", flags: ["--task-id <id>", "--agent-id <id>"], desc: "Atomically set status=claimed, claimed_by=agent IF currently open. TASK_ALREADY_CLAIMED otherwise. Returns task."},
        {name: "release-task", flags: ["--task-id <id>"], desc: "Set status back to open, clear claimed_by. Returns task."},
        {name: "complete-task", flags: ["--task-id <id>", "--agent-id <id>"], desc: "Set status=done. Only the claimer may complete (else WRONG_CLAIMER). Returns task."},
        {name: "list-tasks", flags: ["--status open|claimed|done"], desc: "Print one task object per line (JSONL); empty if none."}
      ],
      error_codes: [
        {code: "MISSING_FLAG", desc: "A required flag was not supplied."},
        {code: "INVALID_INPUT", desc: "An identifier or field failed validation (charset, length, control chars, path traversal, bad --status)."},
        {code: "NOT_INITIALIZED", desc: "HERD_DIR or agents.json missing; run init first."},
        {code: "AGENT_NOT_FOUND", desc: "Referenced agent_id is not registered."},
        {code: "TASK_NOT_FOUND", desc: "Referenced task_id does not exist."},
        {code: "TASK_EXISTS", desc: "create-task for a task_id that already exists."},
        {code: "TASK_ALREADY_CLAIMED", desc: "claim-task on a task whose status is not open."},
        {code: "WRONG_CLAIMER", desc: "complete-task by an agent that is not the current claimer."},
        {code: "STORE_WRITE_FAILED", desc: "A file/lock operation against the herd store failed."}
      ]
    }'
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
  emit_error "INVALID_INPUT" "unknown or missing command; run: herd.sh --describe"
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
  fi

  local cmd="$1"
  shift

  local agent_id="" name="" task_id="" title="" status=""

  # Parse flags generically (no eval; explicit cases only).
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent-id)
        [[ $# -ge 2 ]] || emit_error "MISSING_FLAG" "--agent-id requires a value"
        agent_id="$2"
        shift 2
        ;;
      --name)
        [[ $# -ge 2 ]] || emit_error "MISSING_FLAG" "--name requires a value"
        name="$2"
        shift 2
        ;;
      --task-id)
        [[ $# -ge 2 ]] || emit_error "MISSING_FLAG" "--task-id requires a value"
        task_id="$2"
        shift 2
        ;;
      --title)
        [[ $# -ge 2 ]] || emit_error "MISSING_FLAG" "--title requires a value"
        title="$2"
        shift 2
        ;;
      --status)
        [[ $# -ge 2 ]] || emit_error "MISSING_FLAG" "--status requires a value"
        status="$2"
        shift 2
        ;;
      *)
        emit_error "INVALID_INPUT" "unknown flag: $1"
        ;;
    esac
  done

  case "$cmd" in
    --describe | describe) cmd_describe ;;
    init) cmd_init ;;
    register-agent) cmd_register_agent "$agent_id" "$name" ;;
    heartbeat) cmd_heartbeat "$agent_id" ;;
    create-task) cmd_create_task "$task_id" "$title" ;;
    claim-task) cmd_claim_task "$task_id" "$agent_id" ;;
    release-task) cmd_release_task "$task_id" ;;
    complete-task) cmd_complete_task "$task_id" "$agent_id" ;;
    list-tasks) cmd_list_tasks "$status" ;;
    *) usage ;;
  esac
}

main "$@"
