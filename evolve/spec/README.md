# evolve — Zero kernel spec

## Why a spec, not a compiled binary

`evolve` ships as a pure-bash MCP bridge (the same way `guardian`, `vault`, and
`audit` do), because the parts that make it useful — the skills registry, the
approval-nonce gate, the tamper-evident change log — are **I/O**, and the HEROS
architecture rule keeps all I/O in the bash bridge.

Exactly one piece of `evolve` is **pure compute**: turning a skill's
success/failure counts into a confidence score. That piece is the honest answer
to "rewrite the compute core in our language (Zero)": it is a deterministic
`(inputs) -> number` function with no I/O, no time, and no allocation — the
shape Zero is designed for.

`skill_score.0` is that kernel, written for Zero's primitive integer model
(fixed-point, scale `1e6`, integer Newton sqrt — Zero v0.1.x does not guarantee
floats). It is **spec-only today** because there is no Zero compiler in the
current build/CI image (`zero` is absent; the forge/ledger binaries are built
only in a Zero-equipped CI job).

## Source of truth

Until Zero builds in CI, the **tested** scorer is `_wilson_score` (awk) in
`../mcp-bridge.sh`, exercised by `../eval-bridge.sh` (the integration test
asserts a 2-success/1-failure skill scores in `(0,1)` — currently `0.208`).

## Parity contract (activates when Zero is in CI)

When the Zero toolchain is available, a CI step will:

1. `zero build --target linux-musl-x64 evolve/spec/skill_score.0`
2. For a fixed table of `(successes, failures)` pairs — e.g. `(0,0) (1,0)
   (1,1) (2,1) (10,2) (50,5) (3,7) (100,100)` — run both the compiled kernel and
   the awk reference.
3. Assert every pair agrees to within `0.001` (the JSON `score` field is rounded
   to 3 decimals, so this is exact at the published precision).

This makes the Zero kernel a drop-in replacement for the bash reference with a
provable equivalence, rather than an unverified rewrite.

## Algorithm

Wilson score interval, lower bound at 95% confidence (`z = 1.96`), of the
success proportion `p = successes / (successes + failures)`:

```
lb = ( p + z²/2n − z·√( (p(1−p) + z²/4n) / n ) ) / ( 1 + z²/n )
```

The lower bound is preferred over raw `p` because it penalises small samples: a
skill that has worked once (`1/1`) is *not* yet trusted as much as one that has
worked 50 times (`50/55`). This is what makes the self-improvement loop
conservative — new skills must earn confidence through repeated confirmed
outcomes before they rank highly.
