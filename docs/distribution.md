# HEROS Distribution Guide

HEROS ships through two install paths:

- `@soumyadebnath1619/agentic` for web apps on Node.js 20+
- Linux x86-64 release binaries for `forge` and `ledger`

> Scope note (2026-10-31): the original `@heros` npm scope is not owned by the
> publishing account, so the public packages use the owner's npm scope:
> `@soumyadebnath1619/agentic` and `@soumyadebnath1619/mcp`. The GitHub project
> remains HEROS. A future transfer to `@heros` only changes the package names,
> not the API.

## NPM

```bash
npm install @soumyadebnath1619/agentic
npx @soumyadebnath1619/agentic doctor
npx @soumyadebnath1619/agentic init my-agentic-site
```

The generated starter exposes:

- `GET /`
- `GET /heros/manifest`
- `POST /heros/actions`

## PNPM

```bash
pnpm add @soumyadebnath1619/agentic
pnpm dlx @soumyadebnath1619/agentic doctor
pnpm dlx @soumyadebnath1619/agentic init my-agentic-site
```

## Yarn

```bash
yarn add @soumyadebnath1619/agentic
yarn dlx @soumyadebnath1619/agentic doctor
yarn dlx @soumyadebnath1619/agentic init my-agentic-site
```

## Bun

```bash
bun add @soumyadebnath1619/agentic
bunx @soumyadebnath1619/agentic doctor
bunx @soumyadebnath1619/agentic init my-agentic-site
```

## Local Workspace

For repository development or local package testing:

```bash
npm install file:packages/agentic
node packages/agentic/bin/heros-agentic.mjs doctor
node packages/agentic/bin/heros-agentic.mjs init my-agentic-site
```

## Linux Installer

For `forge` and `ledger` on Linux x86-64:

```bash
curl -fsSL https://raw.githubusercontent.com/itsoumya-d/HEROS/main/scripts/install-heros.sh | bash
```

Optional environment variables:

```bash
HEROS_VERSION=v0.1.11
HEROS_INSTALL_DIR="$HOME/.local/bin"
HEROS_DATA_DIR="$HOME/.local/share/heros"
HEROS_REPO="itsoumya-d/HEROS"
```

Example:

```bash
HEROS_VERSION=v0.1.11 \
HEROS_INSTALL_DIR="$HOME/.local/bin" \
HEROS_DATA_DIR="$HOME/.local/share/heros" \
bash scripts/install-heros.sh
```

The installer writes:

- `heros-forge`
- `heros-ledger`
- `heros-forge-bridge`
- `heros-ledger-bridge`
- MCP manifests under `HEROS_DATA_DIR`

## macOS And Windows

Use `@soumyadebnath1619/agentic` through npm-compatible package managers on macOS and Windows.

`forge` and `ledger` release binaries currently target Linux x86-64. Use Linux, WSL, or a Linux CI runner for binary and MCP bridge workflows.

## Release Gates

Before publishing:

```bash
npm test
npm run pack:agentic
npm publish --dry-run --workspace @soumyadebnath1619/agentic --access public
```

Manual first publish, after logging in with `npm login --auth-type=web`:

```bash
npm whoami
npm publish --workspace @soumyadebnath1619/agentic --access public
```

Recommended provenance publish path:

1. In npm, configure `@soumyadebnath1619/agentic` for GitHub Actions trusted publishing from `itsoumya-d/HEROS` and `.github/workflows/npm-publish.yml`.
2. Push a tag like `agentic-v0.1.0`, or run the `Publish Agentic SDK` workflow manually.
3. The workflow runs tests, packs the package, and publishes with `--provenance`.

For `forge` and `ledger`, GitHub release automation must run with:

- `ZERO_RELEASE_URL`
- `ZERO_COMPILER_SHA256`

The release workflow builds, evaluates, size-checks, reproducibility-checks, signs, scans, and uploads Linux artifacts.
