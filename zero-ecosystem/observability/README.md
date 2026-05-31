# HEROS Observability — OpenTelemetry tracing helper

`otel-trace.sh` is a pure-bash helper that emits OpenTelemetry spans for MCP
bridge tool calls. It wraps [`otel-cli`](https://github.com/equinix-labs/otel-cli)
(a single Go binary, bash-native) and is built to be **sourced by any HEROS
bridge** without ever risking the JSON-RPC stdout stream.

## What it does

When tracing is configured, each MCP tool call can be wrapped in a span that is
exported to any OTLP-compatible backend. When tracing is **not** configured, every
function is a silent no-op that returns `0` — so the bridge behaves identically
whether or not a tracing backend exists.

Key guarantees:

- **Never writes to stdout.** stdout carries JSON-RPC; all span data goes to the
  OTLP endpoint over the network, and any `otel-cli` stdout/stderr is sent to
  `/dev/null`.
- **No `eval`.** Attribute pairs are validated and assembled from a bash array;
  caller-supplied pairs containing commas or control characters are dropped.
- **Never fails the caller.** Every public function returns `0`, even on error.
- **Safe under `set -euo pipefail`.** The file does not run `set` at top level;
  it only defines functions.

## Environment variables

| Variable | Purpose |
| --- | --- |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP endpoint, e.g. `https://api.honeycomb.io:443`. **Tracing is enabled only when this is set** (and `otel-cli` is on `PATH`). |
| `OTEL_SERVICE_NAME` | Default service name. Also honored natively by `otel-cli`. |

Standard `otel-cli` env vars (`OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_EXPORTER_OTLP_PROTOCOL`,
etc.) are passed through to `otel-cli` unchanged.

## Enabled / disabled

`otel_trace_enabled` returns `0` (true) **only if both** are true:

1. `OTEL_EXPORTER_OTLP_ENDPOINT` is set and non-empty, **and**
2. `otel-cli` is on `PATH`.

Otherwise tracing is disabled and `otel_emit_span` is a no-op. It is therefore
safe to `source` this file unconditionally at the top of any bridge.

## How to use it from a bridge

```bash
source "$(dirname "$0")/../zero-ecosystem/observability/otel-trace.sh"

start_ns=$(otel_timer_start)
result=$(run_tool "$tool_name" "$tool_args")   # your tool call
otel_emit_span "ledger" "$tool_name" ok "$(otel_timer_ms "$start_ns")" \
	"mcp.session.id=$session_id"
printf '%s\n' "$result"                          # JSON-RPC stdout, untouched
```

On the error path, pass `error` as the status:

```bash
otel_emit_span "ledger" "$tool_name" error "$(otel_timer_ms "$start_ns")"
```

## Functions

| Function | Description |
| --- | --- |
| `otel_trace_enabled` | Returns `0` if tracing is fully configured, else `1`. |
| `otel_emit_span <service> <span> <status> <duration_ms> [k=v ...]` | Emits one span. No-op when disabled. `status` is `unset`\|`ok`\|`error`. |
| `otel_timer_start` | Echoes current time in nanoseconds (or `0` if unavailable). |
| `otel_timer_ms <start_ns>` | Echoes elapsed milliseconds since `start_ns`. |

## MCP semantic-convention attributes

Every span sets these attributes following the MCP / GenAI OpenTelemetry
semantic conventions:

| Attribute | Value |
| --- | --- |
| `mcp.tool.name` | the span name (the MCP tool being called) |
| `mcp.server.name` | the service name (the bridge, e.g. `ledger`, `forge`) |
| `gen_ai.operation.name` | the span name |
| `mcp.tool.duration_ms` | the measured duration in milliseconds |

Additional `key=value` pairs you pass are added as span attributes, provided the
key matches `[[:alnum:]._-]+` and the value contains no commas or control
characters (unsafe pairs are dropped rather than corrupt the span).

## Compatible backends

`otel-cli` speaks OTLP, so this helper works with **any OTLP endpoint**,
including:

- Honeycomb
- Grafana Tempo
- Jaeger (OTLP receiver)
- Datadog (OTLP intake)
- Any OpenTelemetry Collector

## Installing `otel-cli`

Tracing stays disabled until `otel-cli` is installed and the endpoint is set:

```bash
go install github.com/equinix-labs/otel-cli@latest
export OTEL_EXPORTER_OTLP_ENDPOINT=https://api.honeycomb.io:443
export OTEL_EXPORTER_OTLP_HEADERS="x-honeycomb-team=$HONEYCOMB_API_KEY"
```

## Tests

```bash
bash zero-ecosystem/observability/eval-otel.sh
```
