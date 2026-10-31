# HEROS v2 — Measured Evidence

Environment: macOS arm64, Node v26.3.0, npm 11.16.0, SQLite via `node:sqlite`.
Date: 2026-10-31. All numbers below were produced locally by the commands
shown; nothing is estimated.

## Test suite

```bash
npm test
```

| Suite | Tests | Result |
|---|---:|---|
| `@soumyadebnath1619/agentic` (unit, CLI, Merkle, reflection) | 33 | 33 pass |
| `examples/agentic-site` routes | 5 | 5 pass |
| `@soumyadebnath1619/mcp` (protocol, auth, shadow, UI source, adversarial) | 46 | 46 pass |
| Adversarial cases inside `adversarial.test.mjs` | 289 | 0 failures |

Adversarial distribution:

| Category | Cases |
|---|---:|
| Malformed JSON-RPC | 60 |
| Agentic schema/input validation | 78 |
| Invalid/over-scoped API keys | 31 |
| Hostile forge schema payloads | 60 |
| Malformed shadow schemas | 30 |
| Approval replay/rebinding | 30 |

## Shadow gate behavior (executed SQL, not estimates)

| Migration | Observed result |
|---|---|
| Add nullable column | `allow`; 3 rows copied |
| Drop populated `email` column | `require_approval`; 3 non-null values at risk |
| Drop populated table | `require_approval`; 3 rows at risk |
| Add NOT NULL column without default | `deny`; `ADD_NOT_NULL_WITHOUT_DEFAULT` |
| Set NOT NULL over seeded NULL | `deny`; `NOT_NULL_VIOLATION`; 1 row |
| `text` -> `integer` on non-numeric values | `require_approval`; 2 values changed |
| Add table | `allow` |

## Browser audit

```bash
node packages/mcp/ui/audit-browser.mjs
```

- Viewports: 1440×900, 768×1024, 390×844.
- No console errors, no horizontal overflow.
- All interactive targets >= 44 px.
- Sample log: 3 receipts, integrity verified, 0 failures.
- Tampered log: integrity failed, 4 detected failures.
- Screenshots: `packages/mcp/ui/artifacts/*.png`.

## Package dry-runs

```bash
npm run pack:agentic
npm run pack:mcp
```

| Package | Version | Tarball | Unpacked | Files |
|---|---|---:|---:|---:|
| `@soumyadebnath1619/agentic` | 0.2.0 | 15.9 kB | 61.7 kB | 7 |
| `@soumyadebnath1619/mcp` | 0.3.0 | 27.4 kB | 104.2 kB | 14 |

The agentic tarball includes `src/canonical.js` and `src/merkle.js`; the MCP
tarball excludes `__pycache__` and includes `src/shadow.js` plus the shadow tool.

## Not executed in this environment (explicit blockers)

| Item | Blocker |
|---|---|
| Rebuild `forge` / `ledger` static binaries | Zero compiler not installed |
| OCI Ampere A1 shadow/coturn | No authenticated OCI session |
| Hugging Face Space publication | `hf` CLI absent and no token |
| GPU GRPO/QLoRA training | No CUDA device |

## Published packages (2026-10-31)

- `@soumyadebnath1619/agentic@0.2.0` —
  https://www.npmjs.com/package/@soumyadebnath1619/agentic/v/0.2.0
- `@soumyadebnath1619/mcp@0.3.0` —
  https://www.npmjs.com/package/@soumyadebnath1619/mcp/v/0.3.0

Clean-room verification: installed both packages from the public registry into a
fresh temp project, executed an action through the Merkle store, verified the
inclusion proof and root, and imported the MCP server. All passed.

The `@heros` npm organization name is already taken and the publishing account
is not a member, so the packages use the owned scope. A granular bypass-2FA
publish token was created in the browser, used once, and deleted; the CLI auth
token was removed from `~/.npmrc`.

No accuracy, throughput, or customer/ARR claims are made for the unexecuted
paths.

## npm scope note

The `@heros` npm organization name is already taken and the publishing account
(`soumyadebnath1619`) is not a member, so the package names were moved to the
owned scope: `@soumyadebnath1619/agentic` and `@soumyadebnath1619/mcp`. The API,
source, tests, and GitHub project name are unchanged.
