# HEROS adversarial corpus (P02)

A standalone, deterministic dataset of **500 agent-security cases** for the
HEROS MCP / agentic runtime. The cases are generated from the same executable
tests that enforce the behavior, so the dataset cannot silently drift from the
code.

- `corpus.jsonl` — one JSON object per case (500 lines).
- `manifest.json` — counts, ASI coverage, source tests, and the corpus SHA-256.
- `recorder.mjs` — test-side recorder; a no-op unless `HEROS_CORPUS_DIR` is set.
- `build.mjs` — runs the two test files, validates the records, and writes the
  dataset.

## Generate and check

From the repository root:

```bash
npm run corpus:build   # regenerate corpus.jsonl + manifest.json
npm run corpus:check   # fail if the committed files are stale
npm run test:mcp       # includes corpus-package.test.mjs
```

`corpus:build` executes `packages/mcp/test/adversarial.test.mjs` and
`packages/mcp/test/corpus211.test.mjs` with `HEROS_CORPUS_DIR` set. Each case
appends one record. The build fails unless there are exactly 500 records, 13
group counts match, IDs are unique, and every verdict is known.

## Record schema

```json
{
  "case_id": "auth-base-001",
  "group": "auth-base",
  "surface": "auth",
  "asi": ["ASI03", "ASI10"],
  "source": "adversarial.test.mjs",
  "input": {
    "api_key": "heros_ro_...",
    "tool": "ledger_invoice_create"
  },
  "expected": "INVALID_API_KEY"
}
```

Some records add:

- `allowed_error_codes` — the bounded error set for `forge` and `shadow` cases.
- `setup` — a runtime step required before the input is meaningful.

The input encoder is JSON-safe but preserves values that JSON would lose:

| Marker | Meaning |
|---|---|
| `{"$undefined": true}` | the original value was `undefined` |
| `{"$number": "NaN"}` | the original number was `NaN` or `±Infinity` |
| `{"$runtime": "approval_nonce"}` | substitute a nonce issued by the server |

Approval-replay records use `$runtime` because the real nonce is random.
`setup.kind: "approval_replay"` identifies the schema pair to issue the nonce
for and whether it must be consumed before use. Without that setup step, the
record is a scenario description, not a byte-for-byte replay.

## Verdicts

| Verdict | Meaning |
|---|---|
| `bounded` | the server must not crash; it returns a JSON-RPC error or ignores a notification |
| `INVALID_INPUT` | schema or input validation rejects the request before execution |
| `UNKNOWN_ACTION` | no action matches the requested name |
| `OK` | the control case must execute successfully |
| `INVALID_API_KEY` | malformed, unknown, or non-hex key material |
| `API_KEY_REVOKED` | the key exists but is revoked |
| `NO_ORG_REGISTERED` | an empty key has no organization |
| `INSUFFICIENT_SCOPE` | a read-only key cannot run a write action |
| `bounded_or_error` | forge either returns a bounded result or one of `allowed_error_codes` |
| `rejected` | shadow parsing fails with one of `allowed_error_codes` |
| `INVALID_ACKNOWLEDGMENT_TOKEN` | approval token is missing, expired, reused, or bound to another schema pair |
| `DECISION_REQUIRED` | a destructive migration requires a fresh human approval nonce |

## Coverage

| Surface | Cases |
|---|---:|
| JSON-RPC | 100 |
| Agentic schema | 108 |
| Auth / scope | 56 |
| Forge payloads | 90 |
| Shadow schemas | 60 |
| Approval replay | 60 |
| Destructive approval gate | 26 |
| **Total** | **500** |

ASI coverage (a case can map to more than one vector):

| ASI | Cases |
|---|---:|
| ASI01 | 108 |
| ASI02 | 168 |
| ASI03 | 56 |
| ASI05 | 250 |
| ASI06 | 90 |
| ASI07 | 60 |
| ASI08 | 26 |
| ASI09 | 126 |
| ASI10 | 56 |

## Provenance and limits

- **Test-derived, not model-generated.** Every case is a deterministic input
  from the adversarial suites; no LLM output or user data is included.
- **No seed is required.** Inputs are fixed by construction. The only runtime
  value is the approval nonce, marked `$runtime`.
- **Synthetic credentials.** API keys in the auth cases are test vectors, not
  live keys.
- **Not a benchmark score.** The corpus proves the runtime's expected behavior;
  it does not rank models.
- **Tests remain authoritative.** `corpus:check` catches stale committed files,
  but the real enforcement is `npm run test:mcp`.
- **Hostile strings are inert data.** Do not concatenate them into SQL or shell
  commands outside the provided harness.

License: MIT, matching the repository.
