# Benchmarks — HEROS-RLVR GPU Trainer

**Status: no GPU benchmark has been run.** This file defines what must be
measured before a number may appear in the README, a model card, or a talk.

The only measured results in the repository today are CPU unit-test runs. They
validate the reward contract and the loss math; they say nothing about model
quality or training throughput.

---

## 1. Current measured results

| Measurement | Environment | Result | Kind |
|---|---|---|---|
| `rlvr` unit suite | Python 3.11.13, PyTorch 2.15.0+cpu, Windows | 78 tests, 0 failures | correctness |
| `rlvr` unit suite, no torch | Python 3.11.13, Windows | 78 tests, 65 pass, 13 skip | correctness |
| QLoRA runner | fake policy, real SQLite verifier | orchestration tested; HF adapter untested | correctness |
| 500-row dataset dry-run | Python 3.11.13, Windows | 500/500 rows mapped | correctness |
| Shadow verifier throughput | — | not measured | performance |
| Training throughput | — | not measured | performance |
| MATH-500 pass@1 | — | not measured | quality |

The skip count is the tensor-only tests; the verifier, schema-bridge, and
recorder tests always run. The 13 skips are 7 pre-existing tensor tests and 6
runner tests.

---

## 2. Ablation matrix

Four arms, identical data order, seed, tokenizer, and evaluation harness:

| Arm | Policy objective | Purpose |
|---|---|---|
| A0 Base | none | floor |
| A1 SFT | supervised tokens only | supervised baseline |
| A2 GRPO | std-normalized advantages, length-normalized loss | vanilla RLVR |
| A3 Dr.GRPO + DAPO | centered advantages, constant horizon, asymmetric clip, dynamic sampling | proposed method |

Required run metadata, written to `run.json`:

```json
{
  "arm": "A3",
  "seed": 42,
  "base_model": "Qwen/Qwen2.5-Coder-1.5B-Instruct",
  "quantization": "nf4",
  "compute_dtype": "fp16",
  "lora_r": 16,
  "lora_alpha": 32,
  "group_size": 4,
  "max_completion_len": 512,
  "learning_rate": 0.00001,
  "steps": 500,
  "batch_size": 1,
  "grad_accum": 8,
  "hardware": "RTX 2060 6GB",
  "torch": "2.x.y",
  "cuda": "12.x",
  "sqlite": "3.x.y",
  "peak_vram_gb": 0.0,
  "wall_clock_min": 0.0,
  "git_commit": "0000000"
}
```

A run without this file is an anecdote, not a result.

---

## 3. Metrics

### Training

- Reward mean and standard deviation per step.
- Reward by risk tier (`SAFE`, `NOTABLE`, `MEDIUM`, `HIGH`, `CRITICAL`) and by
  error code.
- KL to the reference model (k3 estimator).
- Clip fraction, separately for the low and high bounds.
- Gradient norm before clipping.
- Completion length distribution (mean, p50, p95).
- Zero-variance group rejection rate.
- Tokens/second and seconds/step.
- `torch.cuda.max_memory_allocated()`.

### Evaluation

- MATH-500 pass@1 with a 95% confidence interval, greedy decoding.
- Migration shadow pass rate on the held-out set.
- Row-loss detection precision and recall on the held-out set.
- No-op rate: migrations that execute but do not satisfy the requirement.
- Length on correct vs incorrect completions.

The held-out set must not overlap the 500 training prompts. If no held-out set
exists, the result is a training-set score and must be labeled as such.

---

## 4. Hardware matrix

| Hardware | Role | Limits |
|---|---|---|
| RTX 2060 6 GB | primary local run | 1.5B NF4, `G=4`, 512 tokens, fp16 |
| Kaggle 2×T4 16 GB | 3B run and the full ablation | session timeout; checkpoint every 50 steps |
| Colab T4 16 GB | reproduction only | not a deadline dependency |

Report the device, driver, CUDA, PyTorch, and browser versions for any WebGPU
number. For this project only the first three columns matter.

---

## 5. Acceptance thresholds

| Claim | Minimum evidence |
|---|---|
| "Training works" | 500 steps, finite loss, reward mean increases on a held-out eval |
| "Dr.GRPO helps" | A3 beats A2 on the same eval with non-overlapping 95% CIs, 3 seeds |
| "DAPO helps" | ablation A3 vs A3-without-dynamic-sampling, same compute budget |
| "Faster" | median and IQR over 100 steps after 10 warmup steps |
| "Fits 6 GB" | measured peak < 5.4 GB, not the budget table |
| "Parallel workers help" | serial vs 2/4/8 workers, same prompts, >1.8× at 4 |

If the confidence intervals overlap, the claim is "no measurable difference at
this sample size", not a win.

---

## 6. Anti-patterns

Do not:

- Report a single run as a result.
- Compare arms with different token budgets, decoding params, or eval sets.
- Report training reward as model quality.
- Report a speedup without a correctness check.
- Use the 500-case training set as the held-out evaluation.
- Put a number in a README before `run.json` exists.
- Call a CPU unit-test runtime a "benchmark".

---

## 7. Reproduction checklist

- [ ] Clean checkout at a recorded commit.
- [ ] `python -m pip install -e "rlvr[train]"` succeeds.
- [ ] `PYTHONPATH=rlvr/src python -m unittest discover -s rlvr/tests -v` passes.
- [ ] Dataset checksum matches the card.
- [ ] Seed and data order recorded.
- [ ] Baseline arm run on the same hardware.
- [ ] Eval script pinned and run once by a second person or CI.
- [ ] `run.json` committed next to the result table.
- [ ] Limitations section names the hardware and the sample size.
