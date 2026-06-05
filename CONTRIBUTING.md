# Contributing to HEROS

**Repository:** https://github.com/itsoumya-d/HEROS

Fork the repo, create a branch off `main`, and submit a pull request. Clone: `git clone https://github.com/itsoumya-d/HEROS.git`

HEROS uses a gstack-style virtual engineering team for development workflow.
Install [gstack](https://github.com/garrytan/gstack) to enable the full team.

## Development Workflow

### Before submitting a PR
```bash
# Security review (OWASP + STRIDE on your changes)
/cso

# Code review (independent check for production bugs)
/review

# QA — pure-bash tools (run without a compiled binary)
bash guardian/eval-bridge.sh
bash vault/eval-bridge.sh
bash audit/eval-bridge.sh
bash evolve/eval-bridge.sh
bash herd/eval-herd.sh
bash remix/eval-bridge.sh
bash forge/eval-squawk.sh
bash zero-ecosystem/observability/eval-otel.sh
bash ledger/eval-litestream.sh
bash ledger/eval-auth.sh
bash ledger/eval-bridge-auth.sh   # requires xxd in PATH
bash forge/eval-auth.sh

# QA — binary evals (requires compiled forge/ledger binaries from CI)
bash zero-ecosystem/eval-harness/zeval.sh --binary forge/forge --cases forge/eval-cases.jsonl
bash zero-ecosystem/eval-harness/zeval.sh --binary ledger/ledger --cases ledger/eval-cases.jsonl
bash forge/eval-bridge.sh    # requires forge binary at forge/forge

# Shellcheck all scripts
shellcheck -S warning forge/mcp-bridge.sh forge/eval-bridge.sh forge/eval-auth.sh \
  forge/squawk-bridge.sh forge/eval-squawk.sh \
  ledger/mcp-bridge.sh ledger/key-gen.sh ledger/eval-auth.sh ledger/eval-bridge-auth.sh \
  ledger/litestream-replicate.sh ledger/eval-litestream.sh \
  guardian/mcp-bridge.sh guardian/eval-bridge.sh \
  vault/mcp-bridge.sh vault/eval-bridge.sh \
  audit/mcp-bridge.sh audit/eval-bridge.sh \
  evolve/mcp-bridge.sh evolve/eval-bridge.sh \
  herd/herd.sh herd/eval-herd.sh \
  remix/mcp-bridge.sh remix/eval-bridge.sh \
  zero-ecosystem/observability/otel-trace.sh zero-ecosystem/observability/eval-otel.sh
```

### Autoresearch-style eval loop
HEROS uses a metric-driven improvement loop inspired by [Karpathy's autoresearch](https://github.com/karpathy/autoresearch).
The metric: **eval_pass_rate** = passing eval cases / total eval cases.

**Loop:**
1. Identify a gap (security audit finding, coverage gap, or new feature)
2. Write a failing eval case first (`eval-cases.jsonl` or `eval-bridge.sh`)
3. Fix the binary or bridge so the eval passes
4. Verify no regressions: all prior cases must still pass
5. Increment version, update `eval_log.md`, document in `docs/redteam-cycle1.md`

### Security standard
- Every new input field must have a test case for: control chars, non-ASCII, length limit, charset enforcement
- Every new error code must appear in `--describe` in the same commit
- New shell code: run `shellcheck -S warning` before committing
- No `eval` anywhere. No string-concatenated JSON. Use `jq --arg`.

## Architecture

```
forge/             — DB migration risk engine (Zero binary + bash bridge)
  forge_mini.0     — Zero binary source (pure compute, no I/O)
  mcp-bridge.sh    — MCP stdio server (bash, owns I/O + auth + rate limit)
  squawk-bridge.sh — Squawk Postgres lock-hazard integration
  mcp-manifest.json, eval-cases.jsonl, eval-bridge.sh, eval-auth.sh, eval-squawk.sh

ledger/            — Agent accounting (Zero binary + bash bridge)
  ledger_mini.0, mcp-bridge.sh, key-gen.sh, litestream-replicate.sh
  mcp-manifest.json, eval-cases.jsonl, eval-bridge-auth.sh, eval-auth.sh, eval-litestream.sh

guardian/          — Universal operation safety oracle (pure bash, no binary)
  mcp-bridge.sh, mcp-manifest.json, eval-cases.jsonl, eval-bridge.sh

vault/             — Agent-native credential storage (pure bash, no binary)
  mcp-bridge.sh, mcp-manifest.json, eval-cases.jsonl, eval-bridge.sh

audit/             — Tamper-evident append-only log (pure bash, no binary)
  mcp-bridge.sh, mcp-manifest.json, eval-cases.jsonl, eval-bridge.sh

evolve/            — Safe, audited agent self-improvement (pure bash + Zero kernel spec)
  mcp-bridge.sh, mcp-manifest.json, eval-cases.jsonl, eval-bridge.sh
  spec/skill_score.0 — pure-compute confidence-score kernel (Zero, spec-only)

herd/              — GNAP-style multi-agent coordination (pure bash)
  herd.sh, eval-herd.sh

remix/             — Agent-generated, user-tweakable companion UIs (pure bash, no binary)
  mcp-bridge.sh    — heros.ui/v1 validator/normalizer (pure jq: closed catalog,
                     string sanitization, token validation, action whitelist)
  mcp-manifest.json, eval-cases.jsonl, eval-bridge.sh
  (spec: docs/remix-spec.md)

zero-ecosystem/
  eval-harness/zeval.sh           — Universal eval runner for Zero binaries
  observability/otel-trace.sh     — Sourceable OpenTelemetry helper
  json-schema/jsonschema_mini.0   — JSON Schema validator in Zero

docs/
  threat-model.md     — Threat model (OWASP Agentic Top 10 + custom); currently scoped to forge/ledger
  redteam-cycle1.md   — Red-team findings log
  yc-application.md   — Canonical YC application (single source of truth)
```

## Security reporting

See [SECURITY.md](SECURITY.md). Email soumyadebnath1619@gmail.com with subject `[HEROS SECURITY]`.
