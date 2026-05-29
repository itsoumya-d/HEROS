# Security Policy

## Supported Versions

| Version | Supported |
|---|---|
| forge v0.1.4 | ✓ |
| ledger v0.1.11 | ✓ |
| All prior versions | ✗ |

## Reporting a Vulnerability

**Do not file a public GitHub issue for security vulnerabilities.**

Email: [soumyadebnath1619@gmail.com](mailto:soumyadebnath1619@gmail.com)

Subject line: `[HEROS SECURITY] <brief description>`

Include:
- Tool and version affected
- Description of the vulnerability
- Steps to reproduce
- Impact assessment (what can an attacker do?)

**Response SLA:**
- Acknowledgement: within 48 hours
- Severity assessment: within 5 business days
- Patch timeline: P1 (critical/high) within 7 days; P2 (medium) within 30 days

## Security Model

HEROS tools are designed with the following trust boundaries:

- **Untrusted input:** All fields provided by agents (`org_name`, `to`, `memo`, `idempotency_key`, `from_schema`, `to_schema`, `request_id`) are treated as untrusted and validated at both binary and bridge layers.
- **Trusted:** `HEROS_DATA_DIR`, `HEROS_API_KEY`, `HEROS_HMAC_SEED`, `HEROS_FORGE_*` rate limit env vars — operator-controlled, not agent-controlled.
- **Binary isolation:** Zero lang's capability model means the compiled binary (`forge`, `ledger`) has no network access and no file I/O. All I/O flows through the bridge.

## Security Hardening Summary

- OWASP Agentic AI Top 10 (ASI01-ASI10) audited; see `docs/threat-model.md`
- Documented red-team review process; P0–P2 findings resolved (CRIT-1, CRIT-2, HIGH-2, HIGH-3, MED-1, MED-2 fixed 2026-05-25)
- No `eval` anywhere in shell code (RT-33)
- All shell argument construction uses bash arrays (no string concatenation)
- All user input extracted via `jq --arg` (never concatenated into shell commands) — including all eval harness error messages (CRIT-2 fix)
- HMAC seed never passed via CLI argument — python3 env-based computation in all code paths including key-gen.sh (CRIT-1 fix)
- `LC_ALL=C.UTF-8` set in key-gen.sh to prevent locale-dependent HMAC output (HIGH-3 fix)
- forge bridge now enforces HMAC seed minimum length (≥32 chars) at startup matching ledger bridge (MED-1 fix)
- ORG_EXISTS fast-path responses strip internal `_new_data` field before returning to agent (MED-2 fix)
- `stored_revoked` strip uses `%%[[:space:]]*` pattern (not `//[[:space:]]/`) consistently across both bridges (HIGH-2 fix)
- File locking (flock) on all concurrent-write paths
- Atomic writes (mktemp + mv) for critical state files
- HMAC-SHA256 API key verification in constant time (single python3 invocation)
- Input validation at binary level: control chars, non-ASCII, length limits, charset enforcement for all user fields (`--org-name`, `--to`, `--idempotency-key`, `--memo`)

## Known Limitations

- Rate limiting is per bridge process instance (resets on restart) — not persistent across restarts
- `world.in` (stdin) not available in Zero v0.1.x — bash bridge is a required component
- Binary compilation requires Linux x86-64 toolchain — pre-compiled binaries in GitHub releases
