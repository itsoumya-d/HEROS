#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Run the HEROS-RLVR QLoRA trainer on the 500-case migration dataset.

Examples:
  # Validate the dataset and print the run plan without importing torch.
  python rlvr/scripts/train_qlora.py \
    --dataset ../HEROS-RL/data/heros_migration_500.jsonl --dry-run

  # Real run on a CUDA GPU. The reference policy is a second 4-bit base model.
  python rlvr/scripts/train_qlora.py \
    --dataset ../HEROS-RL/data/heros_migration_500.jsonl \
    --max-steps 500 --output-dir outputs/project-01

The script is intentionally thin: the orchestration is in
``heros_rlvr.qlora_runner`` and is unit-tested with a fake policy. A real run
requires the ``train`` extra and a GPU; no result is claimed without
``run.json`` and ``steps.jsonl`` in the output directory.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from heros_rlvr.qlora_runner import (  # noqa: E402
    HFPolicy,
    QLoRARunner,
    RunnerConfig,
    dataset_row_to_task,
    load_dataset,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", required=True, help="JSONL migration dataset")
    parser.add_argument("--output-dir", default="outputs/project-01")
    parser.add_argument("--model", default=None, help="override the default base model")
    parser.add_argument("--max-steps", type=int, default=500)
    parser.add_argument("--group-size", type=int, default=4)
    parser.add_argument("--limit", type=int, default=None, help="cap the number of tasks loaded")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--no-4bit", action="store_true", help="disable NF4 quantization")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="load and validate the dataset, print the plan, and exit",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    rows = load_dataset(args.dataset)
    if args.limit is not None:
        if args.limit < 1:
            raise SystemExit("--limit must be positive")
        rows = rows[: args.limit]

    tasks = [dataset_row_to_task(row) for row in rows]
    hazards = Counter(task.hazard for task in tasks)
    config_kwargs = {
        "dataset_path": str(Path(args.dataset)),
        "output_dir": args.output_dir,
        "group_size": args.group_size,
        "max_steps": args.max_steps,
        "seed": args.seed,
        "load_in_4bit": not args.no_4bit,
    }
    if args.model:
        config_kwargs["model_name"] = args.model
    config = RunnerConfig(**config_kwargs)

    if args.dry_run:
        print(
            json.dumps(
                {
                    "dataset": str(Path(args.dataset)),
                    "model": config.model_name,
                    "rows": len(tasks),
                    "planned_steps": min(len(tasks), config.max_steps),
                    "group_size": config.group_size,
                    "hazards": dict(sorted(hazards.items())),
                    "output_dir": config.output_dir,
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
            "PyTorch is required for a real run. Install with:\n"
            "  python -m pip install -e \"rlvr[train]\"",
            file=sys.stderr,
        )
        return 2

    torch.manual_seed(config.seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(config.seed)
    policy = HFPolicy.load(config)
    reference = HFPolicy.load(config, reference=True)
    optimizer = policy.optimizer()
    runner = QLoRARunner(config, policy, reference, optimizer)
    results = runner.run(tasks, max_steps=config.max_steps)
    completed = sum(1 for result in results if not result.skipped)
    print(
        f"completed {completed}/{len(results)} steps; "
        f"artifacts in {config.output_dir}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
