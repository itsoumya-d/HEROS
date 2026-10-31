# HEROS — Binary Delivery Rules

This file defines pass/fail constraints for changes in this repository. It is
subordinate to `AGENTS.md` and `SECURITY.md`. A rule is either satisfied or the
change does not land. No "mostly", "temporary", or "follow-up" exceptions.

## 1. Required commands before every commit

Run from the repository root:

```bash
npm run test:agentic
npm run test:mcp
npm run test:agentic-site
npm run demo:agentic
npm pack --dry-run --workspace @soumyadebnath1619/agentic
npm pack --dry-run --workspace @soumyadebnath1619/mcp
```

Pass conditions:

- Every command exits 0.
- `test:mcp` includes `shadow.test.mjs`, `adversarial.test.mjs`, and `ui.test.mjs`.
- `npm pack` includes `packages/agentic/src/*.js`, including `canonical.js` and
  `merkle.js`; a package that omits a runtime import fails.
- No test is skipped except a documented SQLite-unavailable skip.

## 2. Receipt and Merkle invariants

- The unsigned receipt projection MUST exclude `merkle_root`, `inclusion_proof`,
  `prev_hash`, and `entry_hash`.
- Leaf domain prefix is `0x00`; parent domain prefix is `0x01`.
- Odd Merkle levels promote the final node unchanged.
- `verify()` MUST recompute leaves from stored receipts, check `entry_hash`,
  check the `prev_hash` chain, check `deliberation_hash` against the trace, and
  recompute the root.
- A tampered field MUST fail verification. A replayed inclusion proof against a
  different root MUST fail.
- `prev_hash` for the first receipt is 64 zero characters.

## 3. Reflection invariants

- Reflection is opt-in per action via `verification`.
- A reflector MUST NOT run when `score >= threshold` and no configured error
  code is present.
- `maxAttempts` is an integer from 0 to 3.
- Verifier failure returns `VERIFIER_FAILED`; reflector failure returns
  `REFLECTION_FAILED`. Both fail closed.
- `deliberation_hash` MUST equal SHA-256 of the canonical deliberation trace.
- No unconditional "always reflect" mode.

## 4. Shadow gate invariants

- The shadow sandbox MUST NOT mutate a caller database. It uses an ephemeral
  SQLite database or a temp file.
- `forge_analyze` may only upgrade `decision_required` from the static result.
  It MUST NOT downgrade a static CRITICAL result.
- A shadow `deny` recommendation MUST return `SHADOW_DENY`; an approval nonce
  MUST NOT override it.
- When SQLite is unavailable, `engine` MUST be `schema-only` and the response
  MUST label the analysis conservative.
- `forge_shadow_analyze` validates `sample_rows` to the integer range 1–5.
- The list-wise scorer MUST expose `kind`, candidate scores, ranking, and
  weights. A trained-model claim is forbidden unless weights and evaluation
  evidence exist in-repo.

## 5. MCP boundary invariants

- JSON-RPC output is a single JSON object; malformed input returns a JSON-RPC
  error, never a crash.
- Tool names match `[a-z][a-z0-9_]*`; unknown tools return `UNKNOWN_TOOL`.
- API keys fail closed; revoked keys return `API_KEY_REVOKED`; `ro` keys cannot
  perform `rw` tools.
- Approval nonces are single-use, schema-bound, and expire after 5 minutes.
- An explicitly supplied empty approval token is invalid, not absent.
- Every tool result is JSON-serializable and every success carries `_rate_limit`
  except protocol-level methods.

## 6. UI invariants (`packages/mcp/ui`)

- No `h-screen`; use `100dvh` or `min-block-size`.
- Interactive targets are at least 44 by 44 CSS pixels.
- Every form control has a visible `<label>`; every icon-only button has
  `aria-label`.
- No `tracking-*` utilities and no `letter-spacing` declarations.
- Headings use `text-wrap: balance`; body copy uses `text-wrap: pretty`.
- Numeric columns use `font-variant-numeric: tabular-nums`.
- Fixed/sticky surfaces use `env(safe-area-inset-*)`.
- No animated `blur()` or `backdrop-filter`; no `will-change`.
- `prefers-reduced-motion: reduce` disables transitions.
- The browser audit MUST pass at 1440×900, 768×1024, and 390×844, with no
  horizontal overflow and no console errors.
- Loading a tampered log MUST produce at least one visible integrity failure.

## 7. Public hygiene

Run the same scan as `.github/workflows/ci.yml` before committing docs. Do not
introduce the blocked process markers listed there. Do not claim a capability
that the tests do not exercise.

## 8. Definition of done for a v2 change

A change is done only when:

1. The implementation exists in the package that the runtime actually imports.
2. A unit test proves the positive path and the fail-closed path.
3. The adversarial corpus covers the new boundary or the change explains why it
   is unreachable.
4. The README/architecture contract matches the code.
5. The full required command list above is green.
6. The commit message names the layer and the test evidence.
