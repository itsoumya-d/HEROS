# Hermes → HEROS: an honest mapping

**Date:** 2026-06-03
**Status:** Founder's working analysis — what we adapted, what we did not, and why.

This document records how [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
informed HEROS, and is deliberately explicit about the parts of "rewrite all of
Hermes in Zero and ship it on every platform" that are **not feasible as stated**
— so the repo never over-claims.

## What Hermes is

A large, mature **self-improving agent framework** (~85% Python, ~12% TypeScript):
40+ tools, multi-backend execution (Docker/SSH/Modal/Daytona), messaging gateways
(Telegram/Discord/Slack/WhatsApp/Signal), 300+ model providers, a **skills /
procedural-memory** system that "creates skills from experience and improves them
during use," persistent cross-session memory, and web + TUI UIs.

## What HEROS is — and why that determines the mapping

HEROS is **not an agent**. It is the **operations/safety layer an agent calls**:
pre-execution risk gating (`guardian`, `forge`), credentials (`vault`), accounting
(`ledger`), and a tamper-evident audit (`audit`). The HEROS architecture rule is
hard: **the Zero binary is pure compute (args in → JSON out, no I/O); the bash
bridge owns all I/O, auth, and state.**

That rule is the lens for every row below.

## Component-by-component

| Hermes component | Disposition in HEROS | Why |
|---|---|---|
| **Skills / procedural memory / "improve during use"** | **Ported** as the new `evolve` tool. | This is the valuable core *and* it fits HEROS: a skill registry + an outcome-driven confidence score. We add what Hermes lacks — every behaviour-changing self-modification is approval-nonce gated and chain-hash logged. |
| **Self-improvement loop** | **Ported, but bounded.** `evolve` makes promote/retire gated + audited. | "Maximized/unbounded self-improvement" is the ASI-class risk HEROS exists to contain. Bounded + audited is both safer and the actual differentiator. |
| **Persistent cross-session memory ("a model of who you are")** | **Ported** as `evolve_memory_note` (data only, never auto-executed, audited). | Memory as inert, inspectable, tamper-evident data — not as silent behaviour. |
| **40+ tools (file/shell/network/infra/code/data ops)** | **Already covered** by `guardian` — it risk-classifies exactly these categories before execution. | No need to re-implement tools; HEROS gates whatever tools the agent already has. |
| **300+ model providers (OpenRouter/OpenAI/Anthropic/…)** | **Out of scope.** Documented integration point: the agent calls its own model; it calls HEROS for safety. | Provider calls are network I/O — categorically not expressible in a Zero pure-compute binary. |
| **Messaging gateways (Telegram/Discord/Slack/WhatsApp/Signal)** | **Out of scope.** | Long-lived async network services. Belong to the agent runtime, not the ops layer; not Zero-expressible. |
| **Execution backends (Docker/SSH/Modal/Daytona)** | **Out of scope** (gate them via `guardian` `code_execution`/`infrastructure`). | Orchestration I/O. HEROS gates the *decision* to run; it does not run the sandbox. |
| **Web + TUI UIs** | **Shipped** as the `app/` HEROS Console (cross-platform Go desktop app driving the bridges). | A real local UI; cross-compiles to Linux/macOS/Windows (see below). |

## "Rewrite the whole codebase in Zero" — the honest answer

A literal full rewrite is a **category error**, not a scope estimate. Zero v0.1.x
is pure compute: **no stdin, no networking, no async, no file I/O in most targets,
sub-100 KiB binaries.** Hermes is ~85% network/async/orchestration — the exact
things Zero cannot express. What *is* Zero-portable is the small pure-compute
**kernels**: scoring, ranking, validation, templating. We ported one
representative kernel — the skill confidence score — as `evolve/spec/skill_score.0`
(fixed-point Wilson lower bound), with the bash bridge as the tested reference and
a parity contract that activates when a Zero compiler is available in CI. The rest
stays bridge-side **by design**, exactly as `forge` and `ledger` are structured.

## "Native apps for iOS / Android / macOS / Windows / Linux"

**Desktop is shipped; mobile is a separate track.**

`app/` is the **HEROS Console** — a real, dependency-free **Go** desktop app
(stdlib only) that drives the MCP bridges from a local UI. Because it is pure Go,
it **cross-compiles to Linux, macOS, and Windows from this Linux box — no Mac
required for the macOS build.** All three desktop OSes are delivered as actual
binaries (built + verified in the `desktop-app` CI job; the Linux build is also
run-tested end-to-end against guardian + evolve). See `app/README.md`.

| Target | Status |
|---|---|
| Linux (amd64/arm64) | ✅ built + run-tested |
| macOS (amd64/arm64) | ✅ cross-compiled (Mach-O) |
| Windows (amd64) | ✅ cross-compiled (PE32+); bridges need Git Bash/WSL |
| Android | Designed (`docs/aosp-zero-integration.md`, Zero-as-WASM-in-app); not built here |
| iOS | Requires a Mac + Xcode; genuinely cannot be produced in a Linux container |

The app owns no risk logic — it is a thin client that spawns the bash bridges and
renders their JSON, so every safety gate still lives in the bridges. Its runtime
caveat is honest: the bridges are bash + jq, so Windows needs Git Bash/WSL until
native bridge ports exist. iOS is the one target that is not deliverable here at
all (Apple's toolchain requires a Mac); Android has a documented design but is a
separate build track.

## What actually landed in this change

- `evolve/` — 6th HEROS MCP tool (8 tools), pure bash, 38/38 evals passing,
  shellcheck clean, manifest lint clean.
- `evolve/spec/skill_score.0` (+ README) — the Zero-portable kernel, specced with
  a parity contract.
- `app/` — **HEROS Console**, a cross-platform Go desktop app driving the bridges;
  cross-compiles to Linux/macOS/Windows; Linux build run-tested end-to-end.
- CI: an `evolve-eval` job and a `desktop-app` job (vet + 5-target cross-compile);
  evolve scripts added to shellcheck; manifest added to the lint set.
- This document.
