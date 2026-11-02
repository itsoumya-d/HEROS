#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Supervised warm start for the HEROS migration policy.

Example:
  python rlvr/scripts/sft_warmstart.py \
    --dataset ../HEROS-RL/data/heros_migration_500.jsonl \
    --steps 500 --output-dir outputs/sft-warmstart

The script supervises deterministic target-satisfying SQL from
``heros_rlvr.sft_data``. It is a warm start, not an RL result: run
``evaluate_heldout.py`` afterward and keep a held-out slice out of training.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from heros_rlvr.qlora_runner import (  # noqa: E402
    HFPolicy,
    RunnerConfig,
    dataset_row_to_task,
    environment_snapshot,
    load_dataset,
)
from heros_rlvr.sft_data import build_sft_examples  # noqa: E402


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", required=True, help="JSONL migration dataset")
    parser.add_argument("--output-dir", default="outputs/sft-warmstart")
    parser.add_argument("--model", default="Qwen/Qwen2.5-Coder-1.5B-Instruct")
    parser.add_argument("--steps", type=int, default=500)
    parser.add_argument("--limit", type=int, default=450, help="training rows, before held-out slice")
    parser.add_argument("--max-length", type=int, default=1024)
    parser.add_argument("--learning-rate", type=float, default=2e-4)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--no-4bit", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args(argv)


def build_examples(dataset: str, limit: int):
    rows = load_dataset(dataset)
    if limit < 1 or limit > len(rows):
        raise ValueError(f"limit must be in [1, {len(rows)}]")
    tasks = [dataset_row_to_task(row) for row in rows[:limit]]
    examples = build_sft_examples(tasks)
    if not examples:
        raise ValueError("no target-satisfying examples were generated")
    return examples


def main(argv=None) -> int:
    args = parse_args(argv)
    try:
        examples = build_examples(args.dataset, args.limit)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2

    hazards = Counter(example.hazard for example in examples)
    if args.dry_run:
        print(
            json.dumps(
                {
                    "dataset": args.dataset,
                    "training_rows": args.limit,
                    "examples": len(examples),
                    "hazards": dict(sorted(hazards.items())),
                    "steps": args.steps,
                    "output_dir": args.output_dir,
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 0

    try:
        import torch
    except ImportError:
        print(
            "PyTorch is required. Install with:\n"
            '  python -m pip install -e "rlvr[train]"',
            file=sys.stderr,
        )
        return 2

    config = RunnerConfig(
        model_name=args.model,
        dataset_path=args.dataset,
        output_dir=args.output_dir,
        group_size=2,
        max_prompt_tokens=768,
        max_completion_tokens=256,
        learning_rate=args.learning_rate,
        seed=args.seed,
        max_steps=args.steps,
        load_in_4bit=not args.no_4bit,
        checkpoint_every=0,
        save_final=False,
    )
    output_dir = Path(config.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "run.json").write_text(
        json.dumps(
            {
                "config": config.to_dict(),
                "environment": environment_snapshot(),
                "git_commit": os.environ.get("GIT_COMMIT", "unknown"),
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    torch.manual_seed(config.seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(config.seed)
    policy = HFPolicy.load(config)
    tokenizer = policy.tokenizer
    model = policy.model
    optimizer = policy.optimizer()
    started = time.time()
    losses: list[float] = []
    for step in range(1, args.steps + 1):
        example = examples[(step - 1) % len(examples)]
        full_text = tokenizer.apply_chat_template(
            [
                {"role": "user", "content": example.prompt},
                {"role": "assistant", "content": example.completion},
            ],
            tokenize=False,
        )
        prefix_text = tokenizer.apply_chat_template(
            [{"role": "user", "content": example.prompt}],
            tokenize=False,
            add_generation_prompt=True,
        )
        full = tokenizer(
            full_text,
            return_tensors="pt",
            truncation=True,
            max_length=args.max_length,
        )
        prefix = tokenizer(
            prefix_text,
            return_tensors="pt",
            truncation=True,
            max_length=args.max_length,
        )
        input_ids = full["input_ids"].to(next(model.parameters()).device)
        attention = full["attention_mask"].to(input_ids.device)
        labels = input_ids.clone()
        labels[:, : prefix["input_ids"].shape[1]] = -100
        optimizer.zero_grad(set_to_none=True)
        model.train()
        output = model(input_ids=input_ids, attention_mask=attention, labels=labels)
        loss = output.loss
        if not bool(torch.isfinite(loss).item()):
            print(f"step {step}: non-finite loss, skipped", flush=True)
            continue
        loss.backward()
        torch.nn.utils.clip_grad_norm_(
            [parameter for parameter in model.parameters() if parameter.requires_grad], 1.0
        )
        optimizer.step()
        losses.append(float(loss.detach()))
        if step % 10 == 0:
            print(f"step {step}/{args.steps} loss={losses[-1]:.6f}", flush=True)

    adapter_dir = output_dir / "final"
    policy.save(str(adapter_dir))
    metrics = {
        "steps": args.steps,
        "examples": len(examples),
        "hazards": dict(sorted(hazards.items())),
        "loss_first": losses[0] if losses else None,
        "loss_last": losses[-1] if losses else None,
        "loss_mean": sum(losses) / len(losses) if losses else None,
        "elapsed_sec": round(time.time() - started, 2),
        "vram_mb": round(torch.cuda.max_memory_allocated() / 1024 / 1024, 1)
        if torch.cuda.is_available()
        else 0.0,
    }
    (output_dir / "sft_metrics.json").write_text(
        json.dumps(metrics, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(metrics, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
