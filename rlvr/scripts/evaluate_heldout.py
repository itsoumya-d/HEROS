#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Evaluate a saved HEROS-RLVR adapter on a held-out migration slice.

Example:
  python rlvr/scripts/evaluate_heldout.py \
    --run-dir ../runs/2026-11-02-a3-500-qwen1.5b \
    --checkpoint checkpoint-450 --start 450 --limit 50

The script evaluates the base model and the adapter with identical prompts and
greedy decoding. It is deliberately explicit that rows 451-500 are held out only
with respect to the chosen checkpoint; the final adapter may have trained on
them later.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from heros_rlvr.evaluation import select_eval_tasks, summarize_evaluations  # noqa: E402
from heros_rlvr.gpu_trainer import DeterministicForgeShadowVerifier  # noqa: E402
from heros_rlvr.qlora_runner import (  # noqa: E402
    build_prompt,
    dataset_row_to_task,
    load_dataset,
)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--checkpoint", default="checkpoint-450")
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--start", type=int, default=450)
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--output-dir", default=None)
    parser.add_argument("--max-new-tokens", type=int, default=128)
    parser.add_argument("--no-4bit", action="store_true")
    return parser.parse_args(argv)


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def generate_one(model, tokenizer, prompt: str, max_new_tokens: int, max_prompt_tokens: int) -> str:
    import torch

    text = tokenizer.apply_chat_template(
        [{"role": "user", "content": prompt}],
        tokenize=False,
        add_generation_prompt=True,
    )
    device = next(model.parameters()).device
    encoded = tokenizer(
        text,
        return_tensors="pt",
        truncation=True,
        max_length=max_prompt_tokens,
    ).to(device)
    with torch.no_grad():
        output = model.generate(
            **encoded,
            max_new_tokens=max_new_tokens,
            do_sample=False,
            pad_token_id=tokenizer.pad_token_id,
        )
    return tokenizer.decode(output[0, encoded["input_ids"].shape[1] :], skip_special_tokens=True)


def manifest_matches(task, completion: str) -> tuple[bool | None, bool | None, bool | None]:
    match = re.search(r"<forge_manifest>(.*?)</forge_manifest>", completion, re.S)
    if not match:
        return None, None, None
    try:
        manifest = json.loads(match.group(1))
    except json.JSONDecodeError:
        return None, None, None
    return (
        str(manifest.get("risk_tier", "")).upper() == task.expected_risk_tier,
        bool(manifest.get("has_data_loss")) == task.expected_data_loss,
        bool(manifest.get("decision_required")) == task.decision_required,
    )


def evaluate(model, tokenizer, tasks, path: Path, max_new_tokens: int, max_prompt_tokens: int) -> list[dict]:
    done = {item["task_id"]: item for item in read_jsonl(path)}
    verifier = DeterministicForgeShadowVerifier()
    with path.open("a", encoding="utf-8") as handle:
        for index, task in enumerate(tasks, start=1):
            if task.task_id in done:
                continue
            completion = generate_one(
                model, tokenizer, build_prompt(task), max_new_tokens, max_prompt_tokens
            )
            receipt = verifier.verify_rollout(task, completion)
            risk_match, loss_match, decision_match = manifest_matches(task, completion)
            item = {
                "task_id": task.task_id,
                "hazard": task.hazard,
                "expected_tier": task.expected_risk_tier,
                "total_reward": receipt.total_reward,
                "format_reward": receipt.format_reward,
                "shadow_exec_reward": receipt.shadow_exec_reward,
                "risk_calibration_reward": receipt.risk_calibration_reward,
                "shadow_row_loss_detected": receipt.shadow_row_loss_detected,
                "error_code": receipt.error_code,
                "risk_match": risk_match,
                "loss_match": loss_match,
                "decision_match": decision_match,
                "completion": completion,
            }
            handle.write(json.dumps(item, sort_keys=True) + "\n")
            handle.flush()
            print(f"  {index}/{len(tasks)} {task.task_id} reward={receipt.total_reward}", flush=True)
    return read_jsonl(path)


def main(argv=None) -> int:
    args = parse_args(argv)
    try:
        import torch
        from peft import PeftModel
        from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig
    except ImportError as error:
        print(
            "Evaluation dependencies are missing. Install with:\n"
            '  python -m pip install -e "rlvr[train]"',
            file=sys.stderr,
        )
        print(f"Import error: {error}", file=sys.stderr)
        return 2

    run_dir = Path(args.run_dir)
    checkpoint = run_dir / args.checkpoint
    if not checkpoint.is_dir():
        print(f"checkpoint not found: {checkpoint}", file=sys.stderr)
        return 2
    output_dir = Path(args.output_dir) if args.output_dir else run_dir / "eval_450"
    output_dir.mkdir(parents=True, exist_ok=True)
    run = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
    model_name = run["config"]["model_name"]
    max_prompt_tokens = int(run["config"].get("max_prompt_tokens", 768))

    rows = load_dataset(args.dataset)
    try:
        tasks = select_eval_tasks(
            [dataset_row_to_task(row) for row in rows], args.start, args.limit
        )
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2

    tokenizer = AutoTokenizer.from_pretrained(checkpoint)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    tokenizer.padding_side = "left"

    model_kwargs = {"device_map": "auto", "torch_dtype": torch.float16}
    if not args.no_4bit:
        model_kwargs["quantization_config"] = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_quant_type="nf4",
            bnb_4bit_compute_dtype=torch.float16,
            bnb_4bit_use_double_quant=True,
        )
    base = AutoModelForCausalLM.from_pretrained(model_name, **model_kwargs)
    base.eval()

    started = time.time()
    base_items = evaluate(
        base, tokenizer, tasks, output_dir / "base.jsonl", args.max_new_tokens, max_prompt_tokens
    )
    base_summary = summarize_evaluations(
        base_items,
        elapsed_sec=time.time() - started,
        vram_mb=torch.cuda.max_memory_allocated() / 1024 / 1024 if torch.cuda.is_available() else 0,
    )
    base_summary["label"] = "base"
    (output_dir / "base_summary.json").write_text(
        json.dumps(base_summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(base_summary, indent=2, sort_keys=True), flush=True)

    adapter = PeftModel.from_pretrained(base, checkpoint)
    adapter.eval()
    started = time.time()
    adapter_items = evaluate(
        adapter, tokenizer, tasks, output_dir / "adapter.jsonl", args.max_new_tokens, max_prompt_tokens
    )
    adapter_summary = summarize_evaluations(
        adapter_items,
        elapsed_sec=time.time() - started,
        vram_mb=torch.cuda.max_memory_allocated() / 1024 / 1024 if torch.cuda.is_available() else 0,
    )
    adapter_summary["label"] = f"adapter:{args.checkpoint}"
    (output_dir / "adapter_summary.json").write_text(
        json.dumps(adapter_summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(adapter_summary, indent=2, sort_keys=True), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
