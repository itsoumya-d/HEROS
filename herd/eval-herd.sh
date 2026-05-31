#!/usr/bin/env bash
#
# eval-herd.sh — test harness for herd.sh.
# Uses a throwaway HERD_DIR, prints PASS/FAIL per case, exits 1 on any failure.

set -uo pipefail
export LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERD="${SCRIPT_DIR}/herd.sh"

TMP_ROOT="$(mktemp -d)"
export HERD_DIR="${TMP_ROOT}/.herd"

cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

FAILS=0
CASE=0

# pass/fail reporters
pass() { CASE=$((CASE + 1)); printf 'PASS %2d: %s\n' "$CASE" "$1"; }
fail() {
  CASE=$((CASE + 1))
  FAILS=$((FAILS + 1))
  printf 'FAIL %2d: %s\n' "$CASE" "$1"
  if [[ $# -ge 2 ]]; then printf '         detail: %s\n' "$2"; fi
}

# run <args...> — execute herd.sh, capture stdout into $OUT.
run() { OUT="$(bash "$HERD" "$@")"; }

# jget <jq-filter> — read a field from $OUT.
jget() { printf '%s' "$OUT" | jq -r "$1"; }

# err_is <expected_code> — true if $OUT.error_code == expected.
err_is() { [[ "$(printf '%s' "$OUT" | jq -r '.error_code // ""')" == "$1" ]]; }

# --- Case 9 (run first, before init): commands before init -> NOT_INITIALIZED
run heartbeat --agent-id forge
if err_is "NOT_INITIALIZED"; then
  pass "command before init -> NOT_INITIALIZED"
else
  fail "command before init -> NOT_INITIALIZED" "$OUT"
fi

# --- Case 1: init creates agents.json and tasks/
run init
if [[ -f "${HERD_DIR}/agents.json" && -d "${HERD_DIR}/tasks" \
  && "$(cat "${HERD_DIR}/agents.json")" == "{}" \
  && "$(jget '.status')" == "ok" ]]; then
  pass "init creates agents.json ({}) and tasks/"
else
  fail "init creates agents.json ({}) and tasks/" "$OUT"
fi

# init is idempotent
run init
[[ "$(jget '.status')" == "ok" ]] && pass "init is idempotent" || fail "init is idempotent" "$OUT"

# --- Case 2: register-agent + heartbeat; heartbeat unknown -> AGENT_NOT_FOUND
run register-agent --agent-id forge --name "Forge Agent"
if [[ "$(jget '.agent_id')" == "forge" && "$(jget '.status')" == "ok" \
  && "$(jq -r '.forge.name' "${HERD_DIR}/agents.json")" == "Forge Agent" ]]; then
  pass "register-agent adds agent"
else
  fail "register-agent adds agent" "$OUT"
fi

run heartbeat --agent-id forge
if [[ "$(jget '.agent_id')" == "forge" && "$(jget '.status')" == "ok" \
  && "$(jget '.last_heartbeat')" != "null" ]]; then
  pass "heartbeat on known agent works"
else
  fail "heartbeat on known agent works" "$OUT"
fi

run heartbeat --agent-id ghost
err_is "AGENT_NOT_FOUND" \
  && pass "heartbeat on unknown agent -> AGENT_NOT_FOUND" \
  || fail "heartbeat on unknown agent -> AGENT_NOT_FOUND" "$OUT"

# register a second agent for later
run register-agent --agent-id ledger --name "Ledger Agent"
[[ "$(jget '.status')" == "ok" ]] && pass "register second agent (ledger)" || fail "register second agent (ledger)" "$OUT"

# --- Case 3: create-task; duplicate -> TASK_EXISTS
run create-task --task-id deploy-window --title "Agree deploy window"
if [[ "$(jget '.task_id')" == "deploy-window" && "$(jget '.status')" == "open" \
  && "$(jget '.claimed_by')" == "null" ]]; then
  pass "create-task creates open task"
else
  fail "create-task creates open task" "$OUT"
fi

run create-task --task-id deploy-window --title "dup"
err_is "TASK_EXISTS" \
  && pass "duplicate create-task -> TASK_EXISTS" \
  || fail "duplicate create-task -> TASK_EXISTS" "$OUT"

# --- Case 4: claim-task on open task succeeds
run claim-task --task-id deploy-window --agent-id forge
if [[ "$(jget '.status')" == "claimed" && "$(jget '.claimed_by')" == "forge" ]]; then
  pass "claim-task on open task -> claimed by forge"
else
  fail "claim-task on open task -> claimed by forge" "$OUT"
fi

# --- Case 5 (concurrency-critical): different agent claims same task -> TASK_ALREADY_CLAIMED
run claim-task --task-id deploy-window --agent-id ledger
err_is "TASK_ALREADY_CLAIMED" \
  && pass "second claim by different agent -> TASK_ALREADY_CLAIMED" \
  || fail "second claim by different agent -> TASK_ALREADY_CLAIMED" "$OUT"

# verify the original claimer is unchanged on disk
[[ "$(jq -r '.claimed_by' "${HERD_DIR}/tasks/deploy-window.json")" == "forge" ]] \
  && pass "rejected claim did not overwrite claimed_by" \
  || fail "rejected claim did not overwrite claimed_by" "$(cat "${HERD_DIR}/tasks/deploy-window.json")"

# --- Case 6: complete by non-claimer -> WRONG_CLAIMER; by claimer -> done
run complete-task --task-id deploy-window --agent-id ledger
err_is "WRONG_CLAIMER" \
  && pass "complete-task by non-claimer -> WRONG_CLAIMER" \
  || fail "complete-task by non-claimer -> WRONG_CLAIMER" "$OUT"

run complete-task --task-id deploy-window --agent-id forge
[[ "$(jget '.status')" == "done" ]] \
  && pass "complete-task by claimer -> done" \
  || fail "complete-task by claimer -> done" "$OUT"

# --- Case 7: release-task returns to open and can be re-claimed
run create-task --task-id migrate-db --title "Run migration"
[[ "$(jget '.status')" == "open" ]] && pass "create second task (migrate-db)" || fail "create second task (migrate-db)" "$OUT"

run claim-task --task-id migrate-db --agent-id forge
[[ "$(jget '.claimed_by')" == "forge" ]] && pass "forge claims migrate-db" || fail "forge claims migrate-db" "$OUT"

run release-task --task-id migrate-db
if [[ "$(jget '.status')" == "open" && "$(jget '.claimed_by')" == "null" ]]; then
  pass "release-task returns task to open"
else
  fail "release-task returns task to open" "$OUT"
fi

run claim-task --task-id migrate-db --agent-id ledger
[[ "$(jget '.status')" == "claimed" && "$(jget '.claimed_by')" == "ledger" ]] \
  && pass "released task can be re-claimed by another agent" \
  || fail "released task can be re-claimed by another agent" "$OUT"

# --- Case 8: list-tasks --status open filters correctly
# State now: deploy-window=done, migrate-db=claimed. Add one open task.
run create-task --task-id audit --title "Audit ledger"
[[ "$(jget '.status')" == "open" ]] && pass "create open task (audit)" || fail "create open task (audit)" "$OUT"

run list-tasks --status open
OPEN_IDS="$(printf '%s' "$OUT" | jq -r '.task_id' | sort | tr '\n' ',')"
if [[ "$OPEN_IDS" == "audit," ]]; then
  pass "list-tasks --status open returns only open tasks"
else
  fail "list-tasks --status open returns only open tasks" "got: ${OPEN_IDS}"
fi

# list all returns 3 lines
run list-tasks
ALL_COUNT="$(printf '%s' "$OUT" | grep -c '^{' || true)"
[[ "$ALL_COUNT" -eq 3 ]] && pass "list-tasks (no filter) returns all tasks" || fail "list-tasks (no filter) returns all tasks" "count=${ALL_COUNT}"

# invalid --status
run list-tasks --status bogus
err_is "INVALID_INPUT" && pass "list-tasks invalid --status -> INVALID_INPUT" || fail "list-tasks invalid --status -> INVALID_INPUT" "$OUT"

# --- Case 10: path-traversal task-id -> INVALID_INPUT
run create-task --task-id "../etc" --title "evil"
err_is "INVALID_INPUT" \
  && pass "path-traversal task-id (../etc) -> INVALID_INPUT" \
  || fail "path-traversal task-id (../etc) -> INVALID_INPUT" "$OUT"

run claim-task --task-id "a/b" --agent-id forge
err_is "INVALID_INPUT" \
  && pass "slash in task-id (a/b) -> INVALID_INPUT" \
  || fail "slash in task-id (a/b) -> INVALID_INPUT" "$OUT"

# bad agent-id charset
run register-agent --agent-id "bad id!" --name "x"
err_is "INVALID_INPUT" \
  && pass "invalid agent-id charset -> INVALID_INPUT" \
  || fail "invalid agent-id charset -> INVALID_INPUT" "$OUT"

# missing flag
run register-agent --agent-id forge
err_is "MISSING_FLAG" \
  && pass "missing --name -> MISSING_FLAG" \
  || fail "missing --name -> MISSING_FLAG" "$OUT"

# control char in title
run create-task --task-id ctrltest --title "$(printf 'a\tb')"
err_is "INVALID_INPUT" \
  && pass "control char in --title -> INVALID_INPUT" \
  || fail "control char in --title -> INVALID_INPUT" "$OUT"

# claim non-existent task
run claim-task --task-id nope --agent-id forge
err_is "TASK_NOT_FOUND" \
  && pass "claim non-existent task -> TASK_NOT_FOUND" \
  || fail "claim non-existent task -> TASK_NOT_FOUND" "$OUT"

# --describe is valid JSON with required keys
run --describe
if printf '%s' "$OUT" | jq -e '.name and .version and .commands and .error_codes and .data_model' >/dev/null 2>&1; then
  pass "--describe emits valid descriptor JSON"
else
  fail "--describe emits valid descriptor JSON" "$OUT"
fi

# every error code referenced by the tool appears in --describe
DESCRIBED="$(printf '%s' "$OUT" | jq -r '.error_codes[].code' | sort -u | tr '\n' ',')"
EXPECTED="AGENT_NOT_FOUND,INVALID_INPUT,MISSING_FLAG,NOT_INITIALIZED,STORE_WRITE_FAILED,TASK_ALREADY_CLAIMED,TASK_EXISTS,TASK_NOT_FOUND,WRONG_CLAIMER,"
[[ "$DESCRIBED" == "$EXPECTED" ]] \
  && pass "--describe lists all error codes" \
  || fail "--describe lists all error codes" "got: ${DESCRIBED}"

# ---------------------------------------------------------------------------
printf '\n%d case(s) run, %d failure(s)\n' "$CASE" "$FAILS"
if [[ "$FAILS" -gt 0 ]]; then
  exit 1
fi
exit 0
