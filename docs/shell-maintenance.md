# Shell-script maintenance

Status: living document, 2026-11-03.
Scope: the 11 Bash scripts that ship with HEROS. The Node packages are the
cross-platform surface; these scripts are Linux/WSL bridges and evaluation
harnesses.

## 1. Inventory

| Script | Lines | Role | CI |
|---|---:|---|---|
| `forge/mcp-bridge.sh` | 661 | MCP stdio session loop for the forge binary | shellcheck |
| `ledger/mcp-bridge.sh` | 1001 | MCP stdio session loop for the ledger binary | shellcheck |
| `forge/eval-bridge.sh` | 298 | V39 approval-nonce protocol evaluation | shellcheck |
| `forge/eval-auth.sh` | 141 | Forge auth/scope evaluation | shellcheck |
| `ledger/eval-bridge.sh` | 227 | Ledger bridge evaluation | shellcheck |
| `ledger/eval-bridge-auth.sh` | 217 | Ledger bridge auth evaluation | shellcheck |
| `ledger/eval-auth.sh` | 149 | Ledger auth/scope evaluation | shellcheck |
| `ledger/key-gen.sh` | 103 | API-key generation and hashing | shellcheck |
| `scripts/install-heros.sh` | 75 | Linux x86-64 installer/bootstrap | shellcheck |
| `zero-ecosystem/json-schema/eval-runner.sh` | 95 | JSON-schema evaluation runner | shellcheck |
| `zero-ecosystem/eval-harness/zeval.sh` | 208 | JSONL binary evaluation harness | shellcheck |

All 11 pass `shellcheck -S warning` locally and in the public-hygiene CI job.
The scripts use `set -euo pipefail`, Bash arrays for command construction, and
no `eval`.

## 2. Why they exist

Zero v0.1.x lacks world-in (stdin) support, so the Node/Bash bridges own the
JSON-RPC session loop while the compiled `forge`/`ledger` binaries own the
domain logic. The Node MCP package (`@soumyadebnath1619/mcp`) is the supported
path on macOS and Windows; `scripts/install-heros.sh` deliberately rejects
non-Linux hosts and points them at npm.

## 3. Controls

- **CI:** shellcheck warning-level on all 11 scripts, public-process-marker scan,
  manifest-description limits, executable-`eval` scan, and `git diff --check`.
- **Runtime:** `set -euo pipefail`, explicit `LANG`/`LC_ALL`, bounded message
  sizes in the bridges, and no shell `eval`.
- **Tests:** the Node MCP suite exercises the protocol behavior the bridges
  mirror; the Bash eval scripts remain the integration harness for the compiled
  binaries.
- **Review:** a PR that touches a shell script must run shellcheck and include
  the relevant eval output or explain why it cannot run.

## 4. Known gaps

1. **No unit tests inside the bridges.** The JSON-RPC loop is tested end-to-end,
   not with Bash-level function tests.
2. **Duplicated auth/eval logic.** Forge and ledger kept separate scripts for
   historical reasons; shared behavior is duplicated.
3. **Comment encoding.** Several older scripts contain mojibake in comments.
   This is cosmetic but makes review noisy.
4. **Linux/WSL only.** The installer and binaries do not target macOS or native
   Windows; the Node package is the fallback.
5. **Dependencies.** Bash 4+, jq 1.6+, and the compiled binaries must be present;
   missing tools fail closed in the eval scripts.

## 5. Change policy

- Keep new logic out of Bash when it can live in the Node packages.
- Do not add `eval`, string-built command lines, or unquoted expansions.
- Add a script to the CI shellcheck list in the same PR that adds it.
- Keep bridge output valid JSON-RPC on stdout; diagnostics go to stderr.
- If a bridge exceeds roughly 1,000 lines, split it or justify why not.
- Do not claim a script is tested unless the eval output is attached.

## 6. Migration order

1. Keep the bridges until Zero exposes stdin or the Node MCP bridge covers the
   same tool surface on Linux.
2. Extract shared auth/eval assertions only if a third consumer appears;
   premature Bash libraries are harder to test than duplicated scripts.
3. Port `zeval` and the JSON-schema runner to Node if they start changing more
   than once per quarter.
4. Delete a shell script only after the corresponding Node path has an
   integration test and the documentation stops linking to it.

## 7. Validation

```bash
shellcheck -S warning forge/*.sh ledger/*.sh scripts/*.sh zero-ecosystem/**/*.sh
npm run test:mcp
```

The shellcheck list in `.github/workflows/ci.yml` is authoritative; add new
scripts there.
