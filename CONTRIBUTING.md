# Contributing to HEROS

HEROS uses a gstack-style virtual engineering team for development workflow.
Install [gstack](https://github.com/garrytan/gstack) to enable the full team.

## Development Workflow

### Before submitting a PR
```bash
# Security review (OWASP + STRIDE on your changes)
/cso

# Code review (independent check for production bugs)
/review

# QA (run eval harnesses)
bash zero-ecosystem/eval-harness/zeval.sh --binary forge/forge --cases forge/eval-cases.jsonl
bash zero-ecosystem/eval-harness/zeval.sh --binary ledger/ledger --cases ledger/eval-cases.jsonl
bash forge/eval-bridge.sh
bash ledger/eval-auth.sh
bash ledger/eval-bridge-auth.sh
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
forge/
  forge_mini.0        — Zero binary source (pure compute, no I/O)
  mcp-bridge.sh       — MCP stdio server (bash, owns I/O + auth + rate limit)
  mcp-manifest.json   — Self-describing API contract
  eval-cases.jsonl    — Binary behavioral eval (run via zeval.sh)
  eval-bridge.sh      — Bridge protocol eval (nonce, rate limit, auth)
  eval-auth.sh        — V44 auth eval

ledger/
  ledger_mini.0       — Zero binary source
  mcp-bridge.sh       — MCP stdio server
  mcp-manifest.json   — Self-describing API contract
  eval-cases.jsonl    — Binary behavioral eval
  eval-bridge-auth.sh — Bridge auth eval
  eval-auth.sh        — V44 key-gen + auth eval
  key-gen.sh          — API key generator (V44)

zero-ecosystem/
  eval-harness/zeval.sh   — Universal eval runner for Zero binaries

docs/
  threat-model.md     — Full threat model (OWASP Agentic Top 10 + custom)
  redteam-cycle1.md   — Red-team findings log
```

## Security reporting

See [SECURITY.md](SECURITY.md). Email soumyadebnath1619@gmail.com with subject `[HEROS SECURITY]`.
