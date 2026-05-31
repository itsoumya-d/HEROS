#!/usr/bin/env bash
#
# litestream-replicate.sh — HEROS Litestream replication wrapper
#
# Wraps the Litestream binary (https://litestream.io,
# github.com/benbjohnson/litestream) to continuously replicate a SQLite
# database to object storage / remote backends. Designed for the HEROS
# v0.2 SQLite storage backend (see docs/storage-redesign-v2.md) and the
# deployment guide in docs/deployment-replication.md.
#
# Architecture rule (CLAUDE.md): this is a bash bridge. It owns I/O and
# input validation. It never uses `eval`, never string-concats user input,
# and degrades gracefully when litestream is not installed.
#
set -euo pipefail
export LC_ALL=C.UTF-8

TOOL="litestream-replicate"
VERSION="0.1.0"

# Supported replica URL schemes (Litestream backends).
SUPPORTED_SCHEMES=(s3 gcs abs sftp file)

# ---------------------------------------------------------------------------
# JSON helpers — always built with jq --arg / --argjson, never string concat.
# ---------------------------------------------------------------------------

# emit_error CODE RETRYABLE [key value]...
# Always exits 0 (control commands report errors in the error_code field).
# Extra key/value pairs are passed as values via jq --arg (never concatenated
# into the JSON); only the (hardcoded, literal) key names appear in the filter.
emit_error() {
  local code="$1" retryable="$2"
  shift 2
  local args=(--arg error_code "$code" --argjson retryable "$retryable")
  # Base object. Single quotes are intentional: $error_code etc. are jq
  # variables, not shell expansions.
  # shellcheck disable=SC2016
  local filter='{error_code:$error_code,retryable:$retryable,status:"error"}'
  local key val
  while [ "$#" -ge 2 ]; do
    key="$1"
    val="$2"
    args+=(--arg "k_${key}" "$val")
    # Append {(\"key\"):$k_key}. key is a literal field name from this file.
    filter="${filter} + {(\"${key}\"):\$k_${key}}"
    shift 2
  done
  jq -n "${args[@]}" "$filter"
  exit 0
}

# ---------------------------------------------------------------------------
# litestream detection
# ---------------------------------------------------------------------------

litestream_path() {
  command -v litestream 2>/dev/null || true
}

# Echo the litestream version string (best effort) or empty.
litestream_version() {
  local ls_bin="$1" out
  # `litestream version` prints e.g. "v0.3.13".
  out="$("$ls_bin" version 2>/dev/null | head -n1 || true)"
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Input validation (pure — no litestream required)
# ---------------------------------------------------------------------------

# Reject control characters and obvious shell/path-traversal abuse in a value.
# Returns 0 if clean, 1 otherwise.
value_is_clean() {
  local v="$1"
  # No empty values.
  [ -n "$v" ] || return 1
  # No control characters (incl. newline, tab, NUL handled by bash itself).
  case "$v" in
    *[$'\x01'-$'\x1f']*) return 1 ;;
  esac
  return 0
}

# scheme_supported SCHEME -> 0 if supported
scheme_supported() {
  local want="$1" s
  for s in "${SUPPORTED_SCHEMES[@]}"; do
    [ "$s" = "$want" ] && return 0
  done
  return 1
}

# Extract the scheme (text before "://") from a replica URL.
# Echoes the scheme, or empty if the URL has no "://".
url_scheme() {
  local url="$1"
  case "$url" in
    *"://"*) printf '%s' "${url%%://*}" ;;
    *) printf '' ;;
  esac
}

# validate_inputs DB REPLICA
# On success: prints nothing, returns 0.
# On failure: calls emit_error (which exits 0).
validate_inputs() {
  local db="$1" replica="$2"

  # Presence.
  if [ -z "$db" ]; then
    emit_error "MISSING_FLAG" false flag "--db"
  fi
  if [ -z "$replica" ]; then
    emit_error "MISSING_FLAG" false flag "--replica"
  fi

  # Cleanliness (control chars, path traversal, injection attempts).
  if ! value_is_clean "$db"; then
    emit_error "INVALID_INPUT" false reason "db path contains control characters or is empty" field "db"
  fi
  if ! value_is_clean "$replica"; then
    emit_error "INVALID_INPUT" false reason "replica url contains control characters or is empty" field "replica"
  fi
  case "$db" in
    *"../"* | *"/.."* | "..")
      emit_error "INVALID_INPUT" false reason "db path must not contain '..' traversal segments" field "db"
      ;;
  esac

  # Replica scheme.
  local scheme
  scheme="$(url_scheme "$replica")"
  if [ -z "$scheme" ]; then
    emit_error "INVALID_INPUT" false reason "replica url must be of the form <scheme>://..." field "replica"
  fi
  if ! scheme_supported "$scheme"; then
    emit_error "UNSUPPORTED_SCHEME" false reason "scheme not supported by litestream" scheme "$scheme" supported "$(IFS=,; printf '%s' "${SUPPORTED_SCHEMES[*]}")"
  fi

  # Parent directory of db must exist and be writable.
  local parent
  parent="$(dirname -- "$db")"
  if [ ! -d "$parent" ]; then
    emit_error "PARENT_DIR_MISSING" false reason "parent directory of db path does not exist" parent "$parent"
  fi
  if [ ! -w "$parent" ]; then
    emit_error "INVALID_INPUT" false reason "parent directory of db path is not writable" parent "$parent"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Argument parsing for --db / --replica
# ---------------------------------------------------------------------------

DB=""
REPLICA=""

parse_db_replica() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --db)
        [ "$#" -ge 2 ] || emit_error "MISSING_FLAG" false flag "--db"
        DB="$2"; shift 2 ;;
      --db=*)
        DB="${1#--db=}"; shift ;;
      --replica)
        [ "$#" -ge 2 ] || emit_error "MISSING_FLAG" false flag "--replica"
        REPLICA="$2"; shift 2 ;;
      --replica=*)
        REPLICA="${1#--replica=}"; shift ;;
      *)
        emit_error "INVALID_INPUT" false reason "unknown argument" arg "$1" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_describe() {
  jq -n \
    --arg tool "$TOOL" \
    --arg version "$VERSION" \
    --argjson commands '["--describe","check","validate","replicate","restore"]' \
    --argjson flags '["--db","--replica"]' \
    --argjson error_codes '["MISSING_FLAG","INVALID_INPUT","LITESTREAM_NOT_AVAILABLE","PARENT_DIR_MISSING","UNSUPPORTED_SCHEME"]' \
    --argjson schemes '["s3","gcs","abs","sftp","file"]' \
    '{
      tool:$tool,
      version:$version,
      description:"Wrapper around the Litestream binary to replicate/restore SQLite databases for HEROS. Degrades gracefully when litestream is absent.",
      commands:$commands,
      flags:$flags,
      error_codes:$error_codes,
      supported_replica_schemes:$schemes,
      status:"ok"
    }'
}

cmd_check() {
  local ls_bin
  ls_bin="$(litestream_path)"
  if [ -z "$ls_bin" ]; then
    emit_error "LITESTREAM_NOT_AVAILABLE" false available false
  fi
  local ver
  ver="$(litestream_version "$ls_bin")"
  jq -n \
    --arg version "$ver" \
    --arg path "$ls_bin" \
    '{available:true,version:$version,path:$path,status:"ok"}'
}

cmd_validate() {
  parse_db_replica "$@"
  validate_inputs "$DB" "$REPLICA"
  local scheme
  scheme="$(url_scheme "$REPLICA")"
  jq -n \
    --arg db "$DB" \
    --arg scheme "$scheme" \
    '{valid:true,db:$db,replica_scheme:$scheme,status:"ok"}'
}

cmd_replicate() {
  parse_db_replica "$@"
  # Validate first (emits error + exit 0 on failure).
  validate_inputs "$DB" "$REPLICA"

  local ls_bin
  ls_bin="$(litestream_path)"
  if [ -z "$ls_bin" ]; then
    emit_error "LITESTREAM_NOT_AVAILABLE" false available false
  fi

  # Long-running foreground command. Use an array — never a shell string.
  local cmd=("$ls_bin" replicate "$DB" "$REPLICA")
  exec "${cmd[@]}"
}

cmd_restore() {
  parse_db_replica "$@"
  validate_inputs "$DB" "$REPLICA"

  local ls_bin
  ls_bin="$(litestream_path)"
  if [ -z "$ls_bin" ]; then
    emit_error "LITESTREAM_NOT_AVAILABLE" false available false
  fi

  local cmd=("$ls_bin" restore -o "$DB" "$REPLICA")
  exec "${cmd[@]}"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

main() {
  local sub="${1:---describe}"
  shift || true
  case "$sub" in
    --describe) cmd_describe ;;
    check) cmd_check ;;
    validate) cmd_validate "$@" ;;
    replicate) cmd_replicate "$@" ;;
    restore) cmd_restore "$@" ;;
    *)
      emit_error "INVALID_INPUT" false reason "unknown command" command "$sub" ;;
  esac
}

main "$@"
