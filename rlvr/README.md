# HEROS-RLVR

Verifiable-reasoning post-training primitives for the HEROS agent runtime. The
package implements the algorithmic core of GRPO, Dr.GRPO and DAPO without
depending on a particular model framework, so the objective and its failure
modes can be tested on CPU. A PyTorch policy adapter can call these functions
with per-token log-probabilities.

This is the first layer of the `HEROS-RLVR` project. The core does **not** train
a model and no benchmark numbers are claimed. An opt-in PyTorch trainer layer
(`gpu_trainer.py`) now implements the deterministic SQLite shadow verifier and
the Dr.GRPO/DAPO token loss used by the QLoRA runner; it is tested on CPU and
requires the `gpu` extra.

---

## What is implemented

### Group-relative advantages

For a group of rewards `R = {r_1, ..., r_G}`:

```
mu = mean(R)
sigma = std(R)
A_i = (r_i - mu) / (sigma + 1e-6)     # vanilla GRPO
A_i = r_i - mu                         # Dr.GRPO
```

Vanilla GRPO rescales every group to unit variance. Dr.GRPO removes that
normalization, along with length normalization in the loss.

### Clipped token-level objective

```
r_t = exp(logpi_t - logpi_old_t)
surrogate_t = min(r_t * A, clip(r_t, 1 - eps_low, 1 + eps_high) * A)
```

Three reductions are available:

| Mode | Reduction | Used by |
| --- | --- | --- |
| `length` | mean over tokens per sequence, then mean over sequences | vanilla GRPO |
| `token` | sum over all tokens / total token count | DAPO |
| `none` | sum over all tokens / group size | Dr.GRPO reference; equal per-token weight, loss scale grows with tokens |

The PyTorch trainer uses the paper's **constant horizon** form,
`sum / (G * L_max)`, so the loss scale does not drift with completion length.
A parity test pins it to `grpo_loss(..., length_normalization="none") * L_max`
on a full mask.

DAPO also uses a decoupled clip range (`eps_low=0.2`, `eps_high=0.28`) and
filters zero-variance groups before the update.

### Dynamic sampling

`has_learning_signal` rejects groups where every completion receives the same
reward (all-correct or all-wrong), which is the DAPO dynamic-sampling rule.
`rejection_rate` reports how many groups were discarded.

### Verifier adapter

`CommandVerifier` sends a completion on stdin to a sandboxed command and expects
one JSON object with a boolean `ok` field. The HEROS `forge` binary is the
intended backend; the tests use a deterministic Python command. Format reward is
added separately for a `<think>...</think><answer>...</answer>` envelope.

### Audit

`detect_miracle_step` flags a correct final answer that contains an invalid
intermediate step. It is a heuristic, not proof of unfaithful reasoning: the
invalid indices are reported for inspection. `verifier_error_rates` tracks
false positives and false negatives against ground truth.

### GPU trainer slice (opt-in)

`gpu_trainer.py` adds two pieces used by the QLoRA/Dr.GRPO runner:

- `DeterministicForgeShadowVerifier` parses a completion's
  `<think>`, `<sql_migration>`, and `<forge_manifest>` blocks, executes the
  migration in an **in-memory SQLite** shadow database, and detects row loss by
  comparing table counts before and after. The connection denies `ATTACH`,
  `DETACH`, `PRAGMA writable_schema`, and `load_extension`, so model-authored
  SQL cannot escape the in-memory gate.
- `DapoDynamicSampler` delegates to the existing `sampling.has_learning_signal`
  and `advantages.dr_grpo_advantages` functions, so the CPU reference and the
  tensor path share one definition.
- `compute_dr_grpo_token_loss` implements Dr.GRPO's constant-horizon reduction
  (`sum / (G * L_max)`) with DAPO's asymmetric clipping
  (`eps_low=0.2`, `eps_high=0.28`) and the k3 KL estimator. A parity test pins
  it to the pure-Python `grpo_loss` reference.

Install the optional dependency and run the full suite:

```bash
python -m pip install -e "rlvr[gpu]"
PYTHONPATH=rlvr/src python -m unittest discover -s rlvr/tests -v
```

Without PyTorch, the loss tests are skipped and the dependency-free verifier
tests still run. The trainer is not yet wired to a model checkpoint; see
`BENCHMARKS.md` for the GPU-run gate.

#### Reward contract

| Term | Weight | Condition |
| --- | ---: | --- |
| Format | `+0.25` | all three blocks present; manifest is a JSON object |
| Shadow execution | `+0.75` | migration executes without a SQLite error |
| Risk tier | `+0.50` | predicted tier equals the task's expected tier |
| Data loss | `+0.25` | predicted flag equals `expected OR observed` row loss |
| Approval | `+0.25` | predicted `decision_required` equals the task |
| Miracle step | `-0.40` | destructive claim/SQL with fewer than 20 characters of reasoning |

Maximum `2.00`. Missing blocks return `-1.00`; invalid JSON or a SQL error
returns `-0.50`. Row loss is observed from table counts before and after the
migration, so a manifest cannot hide it. The verifier is deterministic and
stdlib-only; the reward is not a learned judge.

Known limits: row counts do not detect delete-and-reinsert with the same count,
a table rename is a false-positive loss, and a no-op migration can score `2.00`
on a safe task because requirement satisfaction is not checked yet. These are
documented rather than hidden; a requirement check is future work.

---

## Testing

```bash
PYTHONPATH=rlvr/src python -m unittest discover -s rlvr/tests -v
```

The suite is plain `unittest`. The core has no runtime dependencies; the
optional GPU-trainer tests require PyTorch and report `skipped` without it.

---

## Failure boundaries and negative results

These are properties of the implementation, not claims about model quality.

- **Std normalization is unstable on zero-variance groups.** Dividing by
  `sigma + 1e-6` turns a zero reward spread into either zeros or amplified
  noise. DAPO's dynamic sampling removes those groups; Dr.GRPO avoids the
  division entirely.
- **Removing length normalization changes the objective, not just the scale.**
  With ratios fixed at 1 and equal advantages, a three-token sequence
  contributes three times as much as a one-token sequence under `none`
  (`-2` vs `-1` in the loss sign convention used by the tests). That is the
  intended Dr.GRPO behavior, but it means long incorrect completions can
  dominate unless the verifier and max length are controlled.
- **The miracle-step detector is not a faithfulness proof.** A flagged chain
  may still be faithful; an unflagged chain may still contain an unobserved
  leap. The flag exists to route samples to a second verifier or a human.
- **`CommandVerifier` trusts the command's sandbox.** The adapter enforces a
  timeout and parses JSON, but it cannot make an unsafe verifier safe. Isolation
  belongs to the caller (container, seccomp, no network).
- **No model, no benchmark.** Training `DeepSeek-R1-Distill-Qwen-1.5B` and the
  MATH-500/AIME evaluations require GPU access that is not part of this
  repository's CI. No accuracy or length-improvement numbers are fabricated.

---

## Relation to `forge`

`forge` is the deterministic schema-migration oracle in the parent repository.
The reward path is:

```
completion -> CommandVerifier -> forge analyze --from ... --to ... -> {"ok": bool}
```

The verifier's JSON contract is intentionally small so a different oracle (SQL
execution, unit tests, a unit-test sandbox) can replace it without changing the
RL code.
