#!/usr/bin/env bash
# otel-trace.sh — OpenTelemetry tracing helper for HEROS MCP bridges.
#
# Wraps otel-cli (github.com/equinix-labs/otel-cli) to emit spans for MCP
# bridge tool calls. Designed to be SOURCED by a bridge that runs under
# `set -euo pipefail`. It is a guaranteed silent no-op when tracing is not
# configured, so it can be sourced unconditionally without ever touching the
# JSON-RPC stdout stream.
#
# Contract:
#   - Never writes to stdout (stdout carries JSON-RPC).
#   - Never calls `set` at top level (inherits caller's shell options).
#   - Never uses `eval`. Attributes are assembled with jq --arg, never by
#     string-concatenating user input into JSON/CSV.
#   - Never fails the caller: every public function returns 0.
#
# Enabled only when BOTH are true:
#   - OTEL_EXPORTER_OTLP_ENDPOINT is set and non-empty
#   - otel-cli is on PATH
#
# Env vars:
#   OTEL_EXPORTER_OTLP_ENDPOINT  OTLP endpoint, e.g. https://api.honeycomb.io:443
#   OTEL_SERVICE_NAME            Default service name (otel-cli also honors this)

# Returns 0 (success/true) only if tracing is fully configured, else 1.
otel_trace_enabled() {
	[ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ] || return 1
	command -v otel-cli >/dev/null 2>&1 || return 1
	return 0
}

# otel_timer_start
#   Echoes current time in nanoseconds, or 0 if the platform date(1) cannot
#   produce nanoseconds. Always returns 0.
otel_timer_start() {
	local now
	now=$(date +%s%N 2>/dev/null) || now=""
	# On platforms without %N, date echoes a literal trailing 'N'.
	case "$now" in
		'' | *[!0-9]*) printf '%s\n' 0 ;;
		*) printf '%s\n' "$now" ;;
	esac
	return 0
}

# otel_timer_ms <start_ns>
#   Echoes elapsed milliseconds since start_ns. Echoes 0 if start_ns is not a
#   positive integer or the clock is unavailable. Always returns 0.
otel_timer_ms() {
	local start_ns="${1:-0}"
	case "$start_ns" in
		'' | *[!0-9]*) printf '%s\n' 0; return 0 ;;
	esac
	local now_ns
	now_ns=$(otel_timer_start)
	if [ "$now_ns" = "0" ] || [ "$start_ns" = "0" ]; then
		printf '%s\n' 0
		return 0
	fi
	local diff_ms=$(( (now_ns - start_ns) / 1000000 ))
	if [ "$diff_ms" -lt 0 ]; then
		diff_ms=0
	fi
	printf '%s\n' "$diff_ms"
	return 0
}

# otel_emit_span <service_name> <span_name> <status> <duration_ms> [k=v ...]
#   Emits a single span via otel-cli. No-op (return 0) when tracing disabled.
#   Never writes to stdout; otel-cli stdout+stderr are sent to /dev/null.
#   Never fails the caller.
#
#   <status> is an OTel span status code: one of unset|ok|error (otel-cli
#   accepts these). Unknown values are passed through to otel-cli, which
#   defaults safely.
#
#   Extra args are attribute key=value pairs. The span name is also recorded
#   as mcp.tool.name / gen_ai.operation.name and the service as
#   mcp.server.name, following MCP OpenTelemetry semantic conventions.
otel_emit_span() {
	otel_trace_enabled || return 0

	local service_name="${1:-heros}"
	local span_name="${2:-mcp.tool.call}"
	local status="${3:-unset}"
	local duration_ms="${4:-0}"
	shift 4 2>/dev/null || true

	# Sanitize duration: must be a non-negative integer (milliseconds).
	case "$duration_ms" in
		'' | *[!0-9]*) duration_ms=0 ;;
	esac

	# otel-cli --attrs takes a "key=value,key=value" CSV. We never blindly
	# string-concatenate caller input into it: each pair is collected in a
	# bash array and validated (see the loop below) so that no comma or control
	# character can break the encoding or inject extra attributes. The CSV is
	# then joined from the already-validated array.

	# Start with semantic-convention attributes we set ourselves. These keys
	# are constants; their values are the validated arguments.
	local -a attr_pairs=()
	attr_pairs+=("mcp.tool.name=${span_name}")
	attr_pairs+=("mcp.server.name=${service_name}")
	attr_pairs+=("gen_ai.operation.name=${span_name}")
	attr_pairs+=("mcp.tool.duration_ms=${duration_ms}")

	# Append caller-supplied k=v pairs. Reject any pair containing characters
	# that would corrupt the CSV/JSON attribute encoding (comma, control
	# chars) — such pairs are silently dropped rather than risk a malformed
	# span or, worse, an injection. The key must look like an attribute key.
	local kv key val
	for kv in "$@"; do
		case "$kv" in
			*=*) ;;
			*) continue ;;  # not a key=value pair
		esac
		key=${kv%%=*}
		val=${kv#*=}
		# Drop pairs whose key or value contains comma, newline, or other
		# control characters (printf %q-unsafe content). LC_ALL=C keeps the
		# byte-class check locale-independent.
		case "$key" in
			'' | *[![:alnum:]._-]*) continue ;;
		esac
		if LC_ALL=C printf '%s' "$val" | LC_ALL=C grep -q '[[:cntrl:],]'; then
			continue
		fi
		attr_pairs+=("${key}=${val}")
	done

	# Assemble the CSV --attrs value safely from the validated array. Values
	# are guaranteed comma-free and control-char-free by the checks above, so
	# joining with commas cannot break the encoding.
	local attrs_csv=""
	local pair
	for pair in "${attr_pairs[@]}"; do
		if [ -z "$attrs_csv" ]; then
			attrs_csv="$pair"
		else
			attrs_csv="${attrs_csv},${pair}"
		fi
	done

	# Emit the span. All output to /dev/null; never fail the caller.
	otel-cli span \
		--service "$service_name" \
		--name "$span_name" \
		--status-code "$status" \
		--attrs "$attrs_csv" \
		>/dev/null 2>&1 || true

	return 0
}
