# HEROS-RLVR

Verifiable-reasoning post-training primitives for the HEROS agent runtime. The
package implements the algorithmic core of GRPO, Dr.GRPO and DAPO without
depending on a particular model framework, so the objective and its failure
modes can be tested on CPU. A PyTorch policy adapter can call these functions
with per-token log-probabilities.

This is the first layer of the `HEROS-RLVR` project. It does **not** yet train a
model, and no benchmark numbers are claimed.

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
| `none` | sum over all tokens / group size | Dr.GRPO |

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

### Deterministic shadow gate and PyTorch objective

`heros_rlvr.gpu_trainer` adds the bridge between a proposed migration and the
`forge` risk contract:

- `DeterministicForgeShadowVerifier` extracts a `<think>`, a `<sql_migration>`
  and a `<forge_manifest>` block, applies the SQL to an ephemeral
  `sqlite3.connect(":memory:")` database, and scores format (0.25), execution
  (0.75), risk calibration (1.0) and a miracle-step penalty (0.4). Data loss is
  detected for both row loss and column loss (a dropped column with unchanged
  row counts).
- The shadow gate rejects `ATTACH`, `DETACH`, `PRAGMA`, `VACUUM`,
  `load_extension`, `BACKUP` and `RESTORE` so a rollout cannot write outside the
  in-memory database. This is defence in depth, not a process sandbox.
- `DapoDynamicSampler` implements the DAPO zero-variance group filter and the
  Dr.GRPO advantage (`r_i - mean(r)`, no std division).
- `compute_dr_grpo_token_loss` implements the asymmetric-clipped objective with
  the unbiased k3 KL estimator and divides by `group_size * max_completion_len`,
  which is the constant-horizon normalization that removes the length bias.

The new module needs PyTorch:

```bash
pip install -e "rlvr[train]"
PYTHONPATH=rlvr/src python -m unittest discover -s rlvr/tests -v
```

Without PyTorch the 20 GPU-module tests skip and the original 34 dependency-free
tests still pass. The PyTorch objective is verified on CPU; no GPU training run
or model-quality claim is made here.

---

## Testing

```bash
PYTHONPATH=rlvr/src python -m unittest discover -s rlvr/tests -v
```

The suite is plain `unittest`. The 34 core tests have no runtime dependencies;
the 20 `gpu_trainer` tests require `torch` and skip when it is absent.

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
