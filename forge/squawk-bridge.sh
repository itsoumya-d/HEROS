#!/usr/bin/env bash
#
# squawk-bridge.sh — adapter that runs squawk (a PostgreSQL migration SQL
# linter) and maps its findings into forge's risk-tier JSON format.
#
# forge analyzes schema *diffs*; squawk lints raw migration *SQL*. They are
# complementary. This bridge runs `squawk --reporter json <file>` when squawk
# is available on PATH, then translates each squawk rule into a forge risk
# tier and reports the highest tier among all findings.
#
# Contract:
#   - Pure bash, no `eval`.
#   - All external/user data flows through `jq --arg` or bash arrays.
#   - Always exits 0; failures are reported in the JSON `error_code` field.
#   - Graceful degradation when squawk is not installed.
#
set -euo pipefail
export LC_ALL=C.UTF-8

SCHEMA_VERSION=1

# ---------------------------------------------------------------------------
# Emit a JSON error object and exit 0 (errors are data, not crashes).
#   $1 = error_code   $2 = retryable (true|false)   $3 = human message
#   $4 = available (true|false, default true)
# ---------------------------------------------------------------------------
emit_error() {
  local code="$1" retryable="$2" message="$3" available="${4:-true}"
  jq -cn \
    --argjson schema_version "$SCHEMA_VERSION" \
    --arg source "squawk" \
    --argjson squawk_available "$available" \
    --arg error_code "$code" \
    --argjson retryable "$retryable" \
    --arg message "$message" \
    '{schema_version:$schema_version, source:$source,
      squawk_available:$squawk_available, error_code:$error_code,
      retryable:$retryable, message:$message, status:"error"}'
  exit 0
}

# ---------------------------------------------------------------------------
# Map a squawk rule_name to a forge risk tier.
#   $1 = rule_name   $2 = squawk level (e.g. Warning)
# Echoes one of: SAFE NOTABLE MEDIUM HIGH CRITICAL
# ---------------------------------------------------------------------------
map_rule_to_tier() {
  local rule="$1" level="$2"
  case "$rule" in
    ban-drop-column|ban-drop-table|ban-drop-database|ban-drop-not-null)
      printf 'CRITICAL'
      ;;
    require-concurrent-index-creation|require-concurrent-index-deletion|\
adding-serial-primary-key-field|adding-not-nullable-field|\
adding-field-with-default|changing-column-type|\
disallowed-unique-constraint|constraint-missing-not-valid)
      printf 'HIGH'
      ;;
    prefer-big-int|prefer-bigint-over-int|prefer-identity|\
prefer-robust-stmts|prefer-text-field)
      printf 'MEDIUM'
      ;;
    "")
      # No rule name at all: classify by squawk level.
      case "$level" in
        Warning|warning) printf 'NOTABLE' ;;
        *)               printf 'MEDIUM'  ;;
      esac
      ;;
    *)
      # Unknown/other named rule: conservative default.
      printf 'MEDIUM'
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Rank a forge tier (higher number == higher risk).
# ---------------------------------------------------------------------------
tier_rank() {
  case "$1" in
    SAFE)     printf '0' ;;
    NOTABLE)  printf '1' ;;
    MEDIUM)   printf '2' ;;
    HIGH)     printf '3' ;;
    CRITICAL) printf '4' ;;
    *)        printf '0' ;;
  esac
}

tier_from_rank() {
  case "$1" in
    0) printf 'SAFE' ;;
    1) printf 'NOTABLE' ;;
    2) printf 'MEDIUM' ;;
    3) printf 'HIGH' ;;
    4) printf 'CRITICAL' ;;
    *) printf 'SAFE' ;;
  esac
}

# ---------------------------------------------------------------------------
# --describe : machine-readable self-description.
# ---------------------------------------------------------------------------
describe() {
  jq -cn \
    --argjson schema_version "$SCHEMA_VERSION" \
    '{
      schema_version: $schema_version,
      name: "squawk-bridge",
      source: "squawk",
      summary: "Runs squawk to lint PostgreSQL migration SQL for lock hazards and data-loss patterns, then maps findings into forge risk-tier JSON. Complements forge schema-diff analysis.",
      flags: [
        {flag:"--describe", description:"Emit this self-description JSON and exit."},
        {flag:"--sql-file <path>", description:"Path to a SQL migration file to lint with squawk."}
      ],
      error_codes: [
        {code:"MISSING_FLAG", retryable:false, description:"Required --sql-file flag (with value) was not provided."},
        {code:"FILE_NOT_FOUND", retryable:false, description:"The given --sql-file path does not exist or is not a readable regular file."},
        {code:"INVALID_INPUT", retryable:false, description:"The --sql-file path failed validation (path traversal, empty, or not a regular readable file)."},
        {code:"SQUAWK_NOT_AVAILABLE", retryable:false, description:"The squawk binary is not on PATH. Install squawk to enable SQL linting."},
        {code:"SQUAWK_FAILED", retryable:true, description:"squawk executed but failed or produced output that is not valid JSON."}
      ],
      risk_tiers: ["SAFE","NOTABLE","MEDIUM","HIGH","CRITICAL"],
      rule_mapping: {
        CRITICAL: ["ban-drop-column","ban-drop-table","ban-drop-database","ban-drop-not-null"],
        HIGH: ["require-concurrent-index-creation","require-concurrent-index-deletion","adding-serial-primary-key-field","adding-not-nullable-field","adding-field-with-default","changing-column-type","disallowed-unique-constraint","constraint-missing-not-valid"],
        MEDIUM: ["prefer-big-int","prefer-bigint-over-int","prefer-identity","prefer-robust-stmts","prefer-text-field","<any-unknown-named-rule>"],
        NOTABLE: ["<warning-level-with-no-rule-name>"]
      }
    }'
  exit 0
}

# ---------------------------------------------------------------------------
# Validate the --sql-file path.
#   - non-empty
#   - no `..` path segments (defense against traversal)
#   - is a regular, readable file
# Emits an error and exits if validation fails.
# ---------------------------------------------------------------------------
validate_sql_file() {
  local path="$1"

  if [ -z "$path" ]; then
    emit_error "MISSING_FLAG" false "--sql-file requires a non-empty path argument."
  fi

  # Reject any `..` path segment.
  case "/$path/" in
    */../*)
      emit_error "INVALID_INPUT" false "Path contains a '..' segment, which is not allowed."
      ;;
  esac

  if [ ! -e "$path" ]; then
    emit_error "FILE_NOT_FOUND" false "No such file: $path"
  fi

  if [ ! -f "$path" ]; then
    emit_error "INVALID_INPUT" false "Path is not a regular file: $path"
  fi

  if [ ! -r "$path" ]; then
    emit_error "INVALID_INPUT" false "File is not readable: $path"
  fi
}

# ---------------------------------------------------------------------------
# Run squawk against a validated SQL file and emit forge-style JSON.
# ---------------------------------------------------------------------------
run_squawk() {
  local sql_file="$1"

  if ! command -v squawk >/dev/null 2>&1; then
    jq -cn \
      --argjson schema_version "$SCHEMA_VERSION" \
      --arg source "squawk" \
      --arg error_code "SQUAWK_NOT_AVAILABLE" \
      --arg message "The squawk binary is not on PATH. Install squawk (github.com/sbdchd/squawk) to enable SQL linting." \
      '{schema_version:$schema_version, source:$source,
        squawk_available:false, error_code:$error_code,
        retryable:false, available:false, message:$message,
        status:"error"}'
    exit 0
  fi

  # Run squawk with the path passed via an array (never interpolated).
  local -a cmd=(squawk --reporter json "$sql_file")
  local raw rc
  set +e
  raw="$("${cmd[@]}" 2>/dev/null)"
  rc=$?
  set -e

  # squawk exits non-zero when it finds lint issues, which is normal and
  # expected. We only treat the run as failed if the output is not valid
  # JSON. (A clean run with no findings emits `[]`.)
  if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    emit_error "SQUAWK_FAILED" true \
      "squawk exited with status $rc and did not produce valid JSON output."
  fi

  # Normalize: squawk emits a JSON array of findings.
  # Extract rule_name + level pairs robustly. If the top-level value is not
  # an array, treat that as a failure.
  if ! printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    emit_error "SQUAWK_FAILED" true \
      "squawk output was valid JSON but not the expected array of findings."
  fi

  # Build the findings array and compute the highest tier.
  local findings_json="[]"
  local max_rank=0
  local count
  count="$(printf '%s' "$raw" | jq 'length')"

  local i rule level line message tier rank elem
  for (( i = 0; i < count; i++ )); do
    elem="$(printf '%s' "$raw" | jq -c --argjson i "$i" '.[$i]')"
    rule="$(printf '%s'  "$elem" | jq -r '.rule_name // "" | tostring')"
    level="$(printf '%s' "$elem" | jq -r '.level // "" | tostring')"
    line="$(printf '%s'  "$elem" | jq -r '.line // 0 | tostring')"
    # squawk puts human text inside messages[].Note (and similar keys).
    message="$(printf '%s' "$elem" | jq -r '
      if (.messages? | type) == "array" then
        [ .messages[] | (.Note? // .Help? // .Hint? // empty) ] | join(" ")
      else "" end')"

    tier="$(map_rule_to_tier "$rule" "$level")"
    rank="$(tier_rank "$tier")"
    if [ "$rank" -gt "$max_rank" ]; then
      max_rank="$rank"
    fi

    findings_json="$(
      printf '%s' "$findings_json" | jq -c \
        --arg rule "$rule" \
        --arg severity "$level" \
        --arg forge_tier "$tier" \
        --arg message "$message" \
        --argjson line "${line:-0}" \
        '. + [{rule:$rule, severity:$severity, forge_tier:$forge_tier,
               message:$message, line:$line}]'
    )"
  done

  local risk_tier
  risk_tier="$(tier_from_rank "$max_rank")"

  jq -cn \
    --argjson schema_version "$SCHEMA_VERSION" \
    --arg source "squawk" \
    --arg risk_tier "$risk_tier" \
    --argjson findings "$findings_json" \
    --argjson finding_count "$count" \
    '{schema_version:$schema_version, source:$source,
      squawk_available:true, risk_tier:$risk_tier, findings:$findings,
      finding_count:$finding_count, status:"ok"}'
  exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
main() {
  if [ "$#" -eq 0 ]; then
    emit_error "MISSING_FLAG" false "No flags given. Use --describe or --sql-file <path>."
  fi

  local sql_file=""
  local have_sql_flag=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --describe)
        describe
        ;;
      --sql-file)
        have_sql_flag=1
        if [ "$#" -lt 2 ]; then
          emit_error "MISSING_FLAG" false "--sql-file requires a path argument."
        fi
        sql_file="$2"
        shift 2
        ;;
      --sql-file=*)
        have_sql_flag=1
        sql_file="${1#--sql-file=}"
        shift
        ;;
      *)
        emit_error "INVALID_INPUT" false "Unknown argument: $1"
        ;;
    esac
  done

  if [ "$have_sql_flag" -eq 0 ]; then
    emit_error "MISSING_FLAG" false "Missing required flag --sql-file <path>."
  fi

  validate_sql_file "$sql_file"
  run_squawk "$sql_file"
}

main "$@"
