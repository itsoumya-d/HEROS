# HEROS Launch Checklist

Use this checklist before tagging a release or announcing the repo as launch-ready.

## 1. Web SDK Proof

```bash
npm run test:agentic
npm run test:agentic-site
npm run demo:agentic
npm run pack:agentic
node packages/agentic/bin/heros-agentic.mjs doctor
npm publish --dry-run --provenance --workspace @heros/agentic --access public
```

Expected result:

- SDK unit tests pass.
- Demo route tests pass.
- Agent demo returns `ok: true`.
- Package dry-run includes only the SDK source, type declarations, and README.
- CLI doctor returns `ok: true`.
- Publish dry-run succeeds without creating a release.

## 2. Binary And Bridge Proof

These require Linux x86-64, Bash 4+, `jq`, `shellcheck`, and the Zero compiler.

```bash
bash zero-ecosystem/eval-harness/zeval.sh --binary forge/forge --cases forge/eval-cases.jsonl
bash zero-ecosystem/eval-harness/zeval.sh --binary ledger/ledger --cases ledger/eval-cases.jsonl
bash forge/eval-bridge.sh
bash ledger/eval-bridge.sh
bash forge/eval-auth.sh
bash ledger/eval-auth.sh
bash ledger/eval-bridge-auth.sh
shellcheck -S warning forge/mcp-bridge.sh ledger/mcp-bridge.sh ledger/key-gen.sh
```

For GitHub release automation, configure repository variables:

- `ZERO_RELEASE_URL`
- `ZERO_COMPILER_SHA256`

The release workflow must build, evaluate, size-check, reproduce, sign, scan, and upload the `forge` and `ledger` artifacts.

## Linux Installer Proof

```bash
shellcheck -S warning scripts/install-heros.sh
```

On a Linux x86-64 machine after a release exists:

```bash
HEROS_VERSION=v0.1.11 bash scripts/install-heros.sh
heros-forge --describe
heros-ledger --describe
```

## 3. Security And Hygiene

```bash
git diff --check
```

Also verify:

- No executable shell script uses `eval`.
- MCP manifest descriptions stay under 512 characters.
- State-changing SDK actions require auth.
- Destructive or high-value SDK actions require approval.
- SDK schemas use `additionalProperties: false`, length limits, charset limits, and `safeText: true` for user-facing strings.

## 4. Production SDK Stores

The SDK ships with:

- memory receipt and approval stores for tests and demos
- file-backed receipt and approval stores for dependency-free persistence
- store interfaces for database-backed production adapters

Use a database-backed store for multi-process or horizontally scaled deployments. File stores are useful for single-process apps, local deployments, and smoke tests.

## 5. Launch Boundary

Ready claim:

HEROS lets developers make websites agent-ready by declaring explicit, authenticated, auditable actions with schemas, approval gates, idempotency, manifests, and receipts.

Do not claim:

- arbitrary websites become safely agentic without developer-declared actions
- hosted SaaS features exist before they are built
- `forge` and `ledger` binaries are release-ready before the Linux release workflow passes with configured Zero compiler variables
