# Supply Chain Security Specification — `ledger` + `forge`

**Version:** 0.1
**Date:** 2026-05-18
**Status:** Required before any public binary distribution

Closes V6 (Supply Chain / Binary Integrity, P0). Severity upgraded from P1 to P0 following the LiteLLM PyPI compromise (March 2026) in which a fake MCP package harvested API keys from agents that auto-installed it.

---

## 1. Threat Model (V6 + V18 combined)

### 1.1 Unsigned binary distribution

An attacker who can place a file at the download URL (CDN compromise, DNS hijack, GitHub release tampering) can substitute a malicious binary. Agents auto-installing `ledger` or `forge` via package manager would run the malicious binary with full filesystem and network access for all subsequent calls.

### 1.2 Registry name squatting (V18)

Before `ledger` and `forge` are published to PyPI/npm/MCP registries, an attacker can claim the namespace. Name variants that must be pre-registered:
- `ledger-mcp`, `ledger_mcp`, `ledgermcp`, `ledger-agent`, `ledger-zero`
- `forge-mcp`, `forge_mcp`, `forgemcp`, `forge-agent`, `forge-zero`

### 1.3 Dependency confusion

If the build process pulls any internal or private package, a public package with the same name takes priority in most package managers. The build MUST use only explicitly pinned, verified external dependencies.

### 1.4 Reproducible build failure

Non-reproducible builds (different binary bytes from the same source) prevent independent verification. An attacker who can inject into the build process would produce a different binary — but without a known-good reference, the tamper is undetectable.

---

## 2. Signing Pipeline (required at first public release)

### 2.1 Tools

| Tool | Purpose | Version pin |
|------|---------|------------|
| `cosign` | Binary and manifest signing | ≥ 2.2.0 |
| `syft` | SBOM generation (SPDX 2.3) | ≥ 1.4.0 |
| `grype` | Vulnerability scan against SBOM | ≥ 0.78.0 |
| `sha256sum` | Checksum generation | system |

### 2.2 Release artifacts (every release)

```
ledger-v0.2.0-linux-x64.bin          # ELF64 binary
ledger-v0.2.0-linux-x64.bin.sha256   # SHA-256 checksum
ledger-v0.2.0-linux-x64.bin.sig      # cosign signature
ledger-v0.2.0.sbom.spdx.json         # SBOM (build inputs)
ledger-v0.2.0.manifest.json           # tool manifest (tool names, descriptions, inputSchema)
ledger-v0.2.0.manifest.json.sig       # cosign signature of manifest
```

Same pattern for `forge`.

### 2.3 Signing process (CI-enforced, not manual)

```bash
# 1. Build binary (must be reproducible — same input → same binary bytes)
zero build --target linux-musl-x64 --release ledger

# 2. Checksum
sha256sum ledger > ledger-v0.2.0-linux-x64.bin.sha256

# 3. Sign binary (keyless cosign — identity from OIDC token in CI)
cosign sign-blob --yes \
  --oidc-issuer https://token.actions.githubusercontent.com \
  --output-signature ledger-v0.2.0-linux-x64.bin.sig \
  ledger

# 4. Generate SBOM
syft ledger -o spdx-json > ledger-v0.2.0.sbom.spdx.json

# 5. Vulnerability scan — fail build if critical CVEs found
grype sbom:ledger-v0.2.0.sbom.spdx.json --fail-on critical

# 6. Sign manifest
cosign sign-blob --yes \
  --oidc-issuer https://token.actions.githubusercontent.com \
  --output-signature ledger-v0.2.0.manifest.json.sig \
  ledger-v0.2.0.manifest.json
```

### 2.4 Verification instructions (for agents installing ledger)

Every release README and package description MUST include:

```bash
# Download binary and signature
curl -LO https://releases.example.com/ledger-v0.2.0-linux-x64.bin
curl -LO https://releases.example.com/ledger-v0.2.0-linux-x64.bin.sha256
curl -LO https://releases.example.com/ledger-v0.2.0-linux-x64.bin.sig

# Verify checksum
sha256sum --check ledger-v0.2.0-linux-x64.bin.sha256

# Verify cosign signature against Sigstore transparency log
cosign verify-blob \
  --certificate-identity-regexp "https://github.com/OWNER/REPO" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --signature ledger-v0.2.0-linux-x64.bin.sig \
  ledger-v0.2.0-linux-x64.bin
```

Agent orchestrators that install `ledger` or `forge` MUST run verification before executing the binary. A failed verification MUST abort the install and return a structured error to the caller.

---

## 3. Package Name Reservation (V18 — pre-emptive)

### 3.1 Names to reserve before first publication

**PyPI:**
- `ledger-mcp`, `ledger-agent`, `ledger-zero`, `ledgermcp`, `zero-ledger`
- `forge-mcp`, `forge-agent`, `forge-zero`, `forgemcp`, `zero-forge`

**npm:**
- Same list with `@heros/` scope prefix (`@heros/ledger`, `@heros/forge`)
- Flat names without scope: `ledger-mcp-agent`, `forge-mcp-agent`

**Action required:** reserve all names (even as stub packages) before any public announcement. An announcement is a signal to squatters.

### 3.2 Package metadata requirements

Every package MUST include in its description:
```
WARNING: The only legitimate packages are published by [verified publisher].
Verify the cosign signature before using. See: https://[docs-url]/verify
```

Include `sigstore_bundle_url` in package metadata pointing to the release signature on GitHub.

---

## 4. Reproducible Builds

### 4.1 Definition

A build is reproducible if: given the same source commit and the same tool versions, the output binary is byte-identical on any machine.

### 4.2 Zero language reproducibility

Zero's ELF64 backend is deterministic by design (no timestamps embedded, no randomized section order). Reproducibility requirements:
- Pin Zero compiler version in `zero.toml` or equivalent lockfile
- Pin OS/container image used for builds (SHA-pinned Docker image)
- Remove build timestamps from any metadata embedded in the binary
- Build in a clean container, not a developer workstation

### 4.3 Verification

After each release, a second independent build must be triggered from the same commit. The SHA-256 of the two binaries MUST match. The CI pipeline MUST fail the release if they differ.

---

## 5. Build System Security

### 5.1 CI environment requirements

- Build runs in ephemeral containers (no persistent state between runs)
- No outbound network access during compilation (all deps must be vendored or checked-in)
- Signing credentials come from OIDC token (no long-lived secrets in CI environment)
- Release artifacts uploaded only after all checks pass (checksum, signature, vulnerability scan)
- Artifact upload step is separate job with write-only permissions; build jobs have read-only

### 5.2 Dependency policy

- Zero lang: use only the Zero stdlib. No external libraries currently used.
- Build tools: pinned by SHA (not version tag) in CI configuration
- If any external dependency is added in future: MUST have cosign-signed release; MUST be vendored into the repo

### 5.3 Secret management

- No API keys, tokens, or credentials in the repository (including git history)
- Signing uses ephemeral OIDC tokens from GitHub Actions — no long-lived keys stored anywhere
- Release process MUST be fully automated; no manual steps that require a developer's credentials

---

## 6. Binary Distribution Policy

### 6.1 Official distribution channels (exhaustive list)

When published, the ONLY official distribution channels are:
1. GitHub Releases (signed, with cosign)
2. The official package registry (once established — TBD)

Any other source is unofficial. Documentation MUST state this explicitly.

### 6.2 Install script policy

If an install script is provided (`install.sh` or similar):
- The script MUST verify the cosign signature before executing the binary
- The script MUST NOT accept `--skip-verify` or similar flags
- The script MUST fail loudly (non-zero exit, human-readable error) if verification fails
- The script MUST be signed itself (SHA-256 published in the release notes)

### 6.3 MCP package manager integration

When MCP registries mature and support package installation:
- The registry entry MUST include `verification_url` pointing to the cosign signature
- The entry MUST include `sbom_url` pointing to the SBOM
- The entry MUST NOT include install commands that bypass verification

---

## 7. Incident Response (supply chain compromise)

If a signed binary is found to be malicious (e.g., signing key compromised, build system breached):

1. **Immediately:** Revoke the signing identity via Sigstore (if supported) and post to Sigstore transparency log
2. **Within 1 hour:** Post a security advisory on the GitHub repo with SHA-256 of affected binaries
3. **Within 2 hours:** Publish new signed binaries from a clean environment with a new identity
4. **Communicate:** Alert any known operator integrations via email/webhook with affected version list

Machine-readable security advisories format (posted to `security-advisories.json` at stable URL):
```json
{
  "advisory_id": "HEROS-2026-001",
  "severity": "critical",
  "affected_versions": ["0.2.0"],
  "affected_binaries": [
    {
      "name": "ledger",
      "sha256": "<hex of compromised binary>"
    }
  ],
  "action_required": "replace_binary",
  "replacement_version": "0.2.1",
  "published_at": "<ISO8601>"
}
```

Agents that verify cosign signatures on each run will automatically detect the revoked signature and refuse to execute. This is the primary defense — verification at runtime, not just at install time.

---

## 8. Compliance Checklist (before first public binary release)

- [ ] Cosign signing pipeline implemented in CI
- [ ] Reproducible build verified (two independent builds produce byte-identical output)
- [ ] SBOM generated (SPDX 2.3) for every release
- [ ] Vulnerability scan (`grype`) gate in CI — blocks release on critical CVE
- [ ] SHA-256 checksums published alongside every binary
- [ ] Package names reserved in PyPI / npm (stub packages)
- [ ] Package metadata includes verification warning and `sigstore_bundle_url`
- [ ] Install script includes cosign verification (no skip flag)
- [ ] `security-advisories.json` endpoint established at stable URL
- [ ] Incident response process documented and tested with a dry run

---

*This document is the supply chain security contract. V6 remains P0 open until the CI signing pipeline is operational and all checklist items are complete. V18 (registry poisoning) is pre-empted by name reservation before first announcement.*
