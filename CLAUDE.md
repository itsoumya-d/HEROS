# HEROS — Agent-Native Infrastructure Toolkit

## Project Overview

HEROS is agent-native infrastructure: database migration safety (`forge`) and accounting (`ledger`). Both are Zero lang binaries + bash MCP bridges, MCP 2025-11-25 compliant.

- Primary language: Zero lang (`.0` files) + bash bridges
- Binary target: linux-musl-x64, sub-100 KiB
- Source: `forge/`, `ledger/`, `zero-ecosystem/`
- Docs: `docs/`
- CI: `.github/workflows/release.yml`

## Key Commands

```bash
# Run forge eval
bash zero-ecosystem/eval-harness/zeval.sh --binary forge/forge --cases forge/eval-cases.jsonl

# Run ledger eval
bash zero-ecosystem/eval-harness/zeval.sh --binary ledger/ledger --cases ledger/eval-cases.jsonl

# Run bridge evals
bash forge/eval-bridge.sh
bash ledger/eval-auth.sh
bash ledger/eval-bridge-auth.sh

# Shell lint (must pass before commit)
shellcheck -S warning forge/mcp-bridge.sh ledger/mcp-bridge.sh ledger/key-gen.sh

# MCP manifest lint
python3 - <<'EOF'
import json, sys
for path in ["ledger/mcp-manifest.json", "forge/mcp-manifest.json"]:
    with open(path) as f: m = json.load(f)
    for t in m.get("tools", []):
        d = t.get("description", "")
        if len(d) > 512: sys.exit(f"FAIL {path}: {t['name']} description {len(d)} chars")
    print(f"OK {path}")
EOF
```

## Architecture Rule

- **Zero binary**: pure compute, no file I/O, no network. Args in → JSON out.
- **Bash bridge**: owns I/O, auth, rate limiting, JSON-RPC session.
- Never add `eval` to any shell script. Never concatenate user input into JSON strings — use `jq --arg`.
- Every new error code must appear in `--describe` in the same commit.

## Security Standard

- Every new user-facing field: test for control chars, non-ASCII, length limit, charset enforcement
- All shell scripts: `shellcheck -S warning` before commit
- Auth changes: run `ledger/eval-auth.sh` + `ledger/eval-bridge-auth.sh`
- For threats: see `docs/threat-model.md`. For findings: see `docs/redteam-cycle1.md`.

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool.

Key routing rules:
- Product ideas/brainstorming → invoke /office-hours
- Strategy/scope → invoke /plan-ceo-review
- Architecture → invoke /plan-eng-review
- Design review → invoke /design-consultation or /plan-design-review
- Full review pipeline → invoke /autoplan
- Bugs/errors → invoke /investigate
- QA/testing site behavior → invoke /qa or /qa-only
- Code review/diff check → invoke /review
- Visual polish → invoke /design-review
- Ship/deploy/PR → invoke /ship or /land-and-deploy
- Save progress → invoke /context-save
- Resume context → invoke /context-restore
- Security, OWASP, vulnerabilities → invoke /cso
