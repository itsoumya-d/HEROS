"""QLoRA rollout runner for the HEROS-RLVR shadow verifier.

The runner is the orchestration layer between a policy and the deterministic
reward:

    prompt -> G completions -> shadow verifier -> informative-group filter
           -> token log-probs -> Dr.GRPO/DAPO loss -> optimizer step

It is deliberately split from the model adapter. ``QLoRARunner`` depends only on
the small ``Policy`` protocol below, so the rollout, filtering, loss, and
checkpoint logic can be unit-tested on CPU with a fake policy. ``HFPolicy`` is
the Hugging Face/PEFT adapter used for a real run and is not exercised by the
default test suite.

No GPU result is claimed by this module. A run is real only when the recorder
has written ``run.json`` and ``steps.jsonl`` and the adapter has been saved.
"""

from __future__ import annotations

import json
import os
import platform
import re
import sqlite3
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, Protocol, Sequence, Tuple

from .gpu_trainer import (
    TORCH_AVAILABLE,
    DapoDynamicSampler,
    DeterministicForgeShadowVerifier,
    MigrationTask,
    VerificationReceipt,
    compute_dr_grpo_token_loss,
)

if TORCH_AVAILABLE:  # pragma: no branch
    import torch


DEFAULT_MODEL = "Qwen/Qwen2.5-Coder-1.5B-Instruct"
IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def _torch():
    if not TORCH_AVAILABLE:
        raise RuntimeError(
            "PyTorch is required for the QLoRA runner. "
            "Install it with: pip install 'heros-rlvr[train]'"
        )
    return torch


# ---------------------------------------------------------------------------
# Dataset and schema bridge
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ColumnSpec:
    name: str
    source_type: str
    sqlite_type: str
    not_null: bool
    primary_key: bool = False


@dataclass(frozen=True)
class TableSpec:
    name: str
    columns: Tuple[ColumnSpec, ...]


_TYPE_MAP = {
    "BIGINT": "INTEGER",
    "BIGSERIAL": "INTEGER",
    "INT": "INTEGER",
    "INTEGER": "INTEGER",
    "SERIAL": "INTEGER",
    "SMALLINT": "INTEGER",
    "TEXT": "TEXT",
    "VARCHAR": "TEXT",
    "CHAR": "TEXT",
    "CHARACTER": "TEXT",
    "UUID": "TEXT",
    "JSON": "TEXT",
    "JSONB": "TEXT",
    "TIMESTAMP": "TEXT",
    "TIMESTAMPTZ": "TEXT",
    "DATE": "TEXT",
    "TIME": "TEXT",
    "BOOLEAN": "INTEGER",
    "BOOL": "INTEGER",
    "NUMERIC": "REAL",
    "DECIMAL": "REAL",
    "REAL": "REAL",
    "DOUBLE": "REAL",
    "FLOAT": "REAL",
    "BYTEA": "BLOB",
    "BLOB": "BLOB",
}


def _identifier(value: str, kind: str) -> str:
    value = value.strip()
    if not IDENTIFIER.match(value):
        raise ValueError(f"{kind} must be a simple SQL identifier, got {value!r}")
    return value


def _as_bool(value: Any, field_name: str) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)) and value in (0, 1):
        return bool(value)
    if isinstance(value, str) and value.lower() in {"true", "false"}:
        return value.lower() == "true"
    raise ValueError(f"{field_name} must be a boolean, got {value!r}")


def parse_forge_schema(text: str) -> Tuple[TableSpec, ...]:
    """Parse HEROS' ``TABLE``/``COLUMN`` schema format into table specs.

    The parser is intentionally strict. A silent fallback to ``TEXT`` would make
    the shadow gate execute a schema the dataset did not describe.
    """
    if not isinstance(text, str) or not text.strip():
        raise ValueError("schema text must be a non-empty string")

    tables: list[TableSpec] = []
    current_name: str | None = None
    current_columns: list[ColumnSpec] = []
    seen_tables: set[str] = set()

    def flush() -> None:
        nonlocal current_name, current_columns
        if current_name is None:
            return
        if not current_columns:
            raise ValueError(f"table {current_name!r} has no columns")
        tables.append(TableSpec(current_name, tuple(current_columns)))
        current_name = None
        current_columns = []

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        upper = line.upper()
        if upper.startswith("TABLE "):
            flush()
            name = _identifier(line[6:], "table name")
            if name in seen_tables:
                raise ValueError(f"duplicate table {name!r}")
            seen_tables.add(name)
            current_name = name
            current_columns = []
            continue
        if upper.startswith("COLUMN "):
            if current_name is None:
                raise ValueError("COLUMN line before any TABLE line")
            parts = line[7:].split()
            if len(parts) < 2:
                raise ValueError(f"malformed COLUMN line: {line!r}")
            name = _identifier(parts[0], "column name")
            source_type = re.sub(r"\(.*\)$", "", parts[1].upper())
            if source_type not in _TYPE_MAP:
                raise ValueError(f"unsupported column type {parts[1]!r} for {name!r}")
            remainder = " ".join(parts[2:]).upper().replace("_", " ")
            not_null = "NOT NULL" in remainder
            primary_key = "PRIMARY KEY" in remainder
            if any(column.name == name for column in current_columns):
                raise ValueError(f"duplicate column {name!r} in table {current_name!r}")
            current_columns.append(
                ColumnSpec(
                    name=name,
                    source_type=source_type,
                    sqlite_type=_TYPE_MAP[source_type],
                    not_null=not_null,
                    primary_key=primary_key,
                )
            )
            continue
        raise ValueError(f"unsupported schema line: {line!r}")

    flush()
    if not tables:
        raise ValueError("schema contains no TABLE definitions")
    return tuple(tables)


def build_sqlite_ddl(tables: Sequence[TableSpec]) -> str:
    """Emit SQLite DDL for the parsed schema."""
    statements: list[str] = []
    for table in tables:
        if not table.columns:
            raise ValueError(f"table {table.name!r} has no columns")
        pieces: list[str] = []
        for column in table.columns:
            piece = f'"{column.name}" {column.sqlite_type}'
            if column.primary_key:
                piece += " PRIMARY KEY"
            if column.not_null:
                piece += " NOT NULL"
            pieces.append(piece)
        statements.append(f'CREATE TABLE "{table.name}" ({", ".join(pieces)});')
    return "\n".join(statements)


def _seed_value(column: ColumnSpec, index: int) -> str:
    if column.sqlite_type == "INTEGER":
        if column.source_type in {"BOOLEAN", "BOOL"}:
            return "1" if index == 0 else "0"
        if column.name.lower() in {"id", "pk"} or column.name.lower().endswith("_id"):
            return str(index + 1)
        return str((index + 1) * 10)
    if column.sqlite_type == "REAL":
        return f"{index + 1}.5"
    if column.sqlite_type == "BLOB":
        return "X'00'"
    if column.source_type in {"TIMESTAMP", "TIMESTAMPTZ"}:
        return f"'2026-01-{index + 1:02d} 00:00:00'"
    if column.source_type == "DATE":
        return f"'2026-01-{index + 1:02d}'"
    if column.source_type == "TIME":
        return f"'{index + 1:02d}:00:00'"
    if column.source_type == "UUID":
        return f"'00000000-0000-0000-0000-00000000000{index + 1}'"
    if column.source_type in {"JSON", "JSONB"}:
        return "'{}'"
    return f"'seed-{index + 1}'"


def build_seed_sql(tables: Sequence[TableSpec], rows_per_table: int = 2) -> str:
    """Build deterministic seed rows for every table.

    The values are synthetic and are not meant to model production data. They
    exist so a destructive migration has rows to lose.
    """
    if rows_per_table < 1:
        raise ValueError("rows_per_table must be at least 1")
    statements: list[str] = []
    for table in tables:
        column_list = ", ".join(f'"{column.name}"' for column in table.columns)
        values: list[str] = []
        for index in range(rows_per_table):
            row = ", ".join(_seed_value(column, index) for column in table.columns)
            values.append(f"({row})")
        statements.append(
            f'INSERT INTO "{table.name}" ({column_list}) VALUES {", ".join(values)};'
        )
    return "\n".join(statements)


def dataset_row_to_task(row: Dict[str, Any]) -> MigrationTask:
    """Convert one ``heros_migration_500`` row into a verifier task."""
    required = ("id", "old_schema", "target_schema", "hazard", "expected_tier")
    missing = [key for key in required if not str(row.get(key, "")).strip()]
    if missing:
        raise ValueError(f"dataset row is missing required fields: {missing}")

    expected_tier = str(row["expected_tier"]).upper()
    if expected_tier not in {"SAFE", "NOTABLE", "MEDIUM", "HIGH", "CRITICAL"}:
        raise ValueError(f"invalid expected_tier {expected_tier!r}")

    old_tables = parse_forge_schema(str(row["old_schema"]))
    # Validate the target too; a malformed target is a dataset bug, not a model
    # failure, and should fail before the first GPU step.
    parse_forge_schema(str(row["target_schema"]))

    hazard = str(row["hazard"]).strip()
    return MigrationTask(
        task_id=str(row["id"]),
        from_ddl=build_sqlite_ddl(old_tables),
        seed_sql=build_seed_sql(old_tables),
        requirement=f"Apply the requested {hazard} change without losing existing rows.",
        expected_risk_tier=expected_tier,
        expected_data_loss=_as_bool(row.get("data_loss", False), "data_loss"),
        decision_required=_as_bool(
            row.get("requires_expand_contract", False), "requires_expand_contract"
        ),
        source_schema=str(row["old_schema"]),
        target_schema=str(row["target_schema"]),
        hazard=hazard,
    )


def load_dataset(path: str | os.PathLike[str]) -> list[Dict[str, Any]]:
    """Load a JSONL migration dataset; fail on an empty file."""
    rows: list[Dict[str, Any]] = []
    with open(path, "r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"invalid JSON on line {line_number}: {error}") from error
            if not isinstance(value, dict):
                raise ValueError(f"line {line_number} is not a JSON object")
            rows.append(value)
    if not rows:
        raise ValueError(f"dataset {path!s} contains no rows")
    return rows


def build_prompt(task: MigrationTask) -> str:
    """Build the three-block prompt consumed by the shadow verifier.

    Expected labels are deliberately excluded. The model sees the hazard class
    and the schema change, but must infer the risk tier and the data-loss flag.
    """
    source = task.source_schema or task.from_ddl
    target = task.target_schema or "(no target schema supplied)"
    return (
        "You are a database migration safety engineer. Rewrite the requested "
        "schema change as a zero-downtime expand-and-contract migration.\n\n"
        "Respond in exactly this shape:\n"
        "<think>brief reasoning about the risk and the plan</think>\n"
        "<sql_migration>SQLite-compatible DDL/DML statements</sql_migration>\n"
        '<forge_manifest>{"risk_tier": "SAFE", "has_data_loss": false, '
        '"decision_required": false}</forge_manifest>\n\n'
        "Rules:\n"
        "- The shadow gate executes your SQL against seeded rows in SQLite.\n"
        "- Preserve existing rows; do not put a destructive statement first.\n"
        "- risk_tier must be one of: SAFE, NOTABLE, MEDIUM, HIGH, CRITICAL.\n"
        "- has_data_loss describes the requested change, not only your SQL.\n"
        "- decision_required is true when a human must approve the change.\n"
        f"- Hazard class: {task.hazard or 'unspecified'}\n\n"
        f"CURRENT SCHEMA:\n{source}\n\n"
        f"TARGET SCHEMA:\n{target}\n"
    )


# ---------------------------------------------------------------------------
# Rollouts and records
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class RolloutBatch:
    task_id: str
    prompt: str
    completions: Tuple[str, ...]
    receipts: Tuple[VerificationReceipt, ...]
    rewards: Tuple[float, ...]

    @property
    def informative(self) -> bool:
        return DapoDynamicSampler.is_informative_group(self.rewards)


def build_rollout_batch(
    task: MigrationTask,
    prompt: str,
    completions: Sequence[str],
    verifier: DeterministicForgeShadowVerifier,
) -> RolloutBatch:
    if not completions:
        raise ValueError("completions must be non-empty")
    receipts = tuple(verifier.verify_rollout(task, completion) for completion in completions)
    return RolloutBatch(
        task_id=task.task_id,
        prompt=prompt,
        completions=tuple(completions),
        receipts=receipts,
        rewards=tuple(receipt.total_reward for receipt in receipts),
    )


@dataclass(frozen=True)
class StepResult:
    step: int
    task_id: str
    mean_reward: float
    reward_std: float
    loss: float | None = None
    mean_kl: float | None = None
    clip_fraction: float | None = None
    skipped: bool = False
    skip_reason: str | None = None
    error_codes: Dict[str, int] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


def environment_snapshot() -> Dict[str, Any]:
    snapshot: Dict[str, Any] = {
        "python": platform.python_version(),
        "platform": platform.platform(),
        "sqlite": sqlite3.sqlite_version,
    }
    if TORCH_AVAILABLE:
        snapshot["torch"] = torch.__version__
        snapshot["cuda_available"] = torch.cuda.is_available()
        if torch.cuda.is_available():
            snapshot["cuda_device"] = torch.cuda.get_device_name(0)
    return snapshot


class RunRecorder:
    """Write ``run.json``, ``steps.jsonl``, and ``summary.json``.

    The recorder is intentionally dependency-free so a run can be audited even
    if W&B is unavailable. A W&B report is an optional export, not the source of
    truth.
    """

    def __init__(self, output_dir: str | os.PathLike[str]):
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self._steps_path = self.output_dir / "steps.jsonl"
        self._checkpoints_path = self.output_dir / "checkpoints.jsonl"

    def start(self, config: "RunnerConfig", extra: Dict[str, Any] | None = None) -> None:
        # A new start means a new run; never append to a previous run's logs.
        self._steps_path.unlink(missing_ok=True)
        self._checkpoints_path.unlink(missing_ok=True)
        payload: Dict[str, Any] = {
            "config": config.to_dict(),
            "environment": environment_snapshot(),
            "git_commit": os.environ.get("GIT_COMMIT", "unknown"),
            "started_at": datetime.now(timezone.utc).isoformat(),
        }
        if extra:
            payload["extra"] = extra
        self._write_json(self.output_dir / "run.json", payload)

    def append_step(self, result: StepResult) -> None:
        with open(self._steps_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(result.to_dict(), sort_keys=True) + "\n")

    def record_checkpoint(self, step: int, path: str) -> None:
        with open(self._checkpoints_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"step": step, "path": path}, sort_keys=True) + "\n")

    def finish(self, results: Sequence[StepResult]) -> None:
        completed = [result for result in results if not result.skipped]
        summary = {
            "steps": len(results),
            "completed_steps": len(completed),
            "skipped_steps": len(results) - len(completed),
            "mean_reward": (
                sum(result.mean_reward for result in completed) / len(completed)
                if completed
                else 0.0
            ),
            "finished_at": datetime.now(timezone.utc).isoformat(),
        }
        self._write_json(self.output_dir / "summary.json", summary)

    @staticmethod
    def _write_json(path: Path, payload: Dict[str, Any]) -> None:
        temporary = path.with_suffix(path.suffix + ".tmp")
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
        temporary.replace(path)


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class RunnerConfig:
    model_name: str = DEFAULT_MODEL
    dataset_path: str = ""
    output_dir: str = "outputs/project-01"
    group_size: int = 4
    max_prompt_tokens: int = 1024
    max_completion_tokens: int = 512
    learning_rate: float = 1e-5
    temperature: float = 1.0
    top_p: float = 0.95
    kl_beta: float = 0.01
    clip_eps_low: float = 0.2
    clip_eps_high: float = 0.28
    lora_r: int = 16
    lora_alpha: int = 32
    load_in_4bit: bool = True
    seed: int = 42
    max_steps: int = 500
    gradient_accumulation: int = 8
    max_grad_norm: float = 1.0
    checkpoint_every: int = 50
    save_final: bool = True

    def __post_init__(self) -> None:
        if self.group_size < 2:
            raise ValueError("group_size must be at least 2")
        if self.max_prompt_tokens < 1 or self.max_completion_tokens < 1:
            raise ValueError("token limits must be positive")
        if self.learning_rate <= 0:
            raise ValueError("learning_rate must be positive")
        if not 0 < self.top_p <= 1:
            raise ValueError("top_p must be in (0, 1]")
        if self.temperature <= 0:
            raise ValueError("temperature must be positive")
        if self.kl_beta < 0:
            raise ValueError("kl_beta must be non-negative")
        if self.clip_eps_low <= 0 or self.clip_eps_high < self.clip_eps_low:
            raise ValueError("clip bounds must satisfy 0 < low <= high")
        if self.lora_r < 1 or self.lora_alpha < 1:
            raise ValueError("LoRA rank and alpha must be positive")
        if self.max_steps < 1:
            raise ValueError("max_steps must be positive")
        if self.gradient_accumulation < 1:
            raise ValueError("gradient_accumulation must be at least 1")
        if self.max_grad_norm <= 0:
            raise ValueError("max_grad_norm must be positive")
        if self.checkpoint_every < 0:
            raise ValueError("checkpoint_every must be non-negative")

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


class Policy(Protocol):
    """The minimal policy interface used by the runner."""

    def generate(
        self,
        prompts: Sequence[str],
        *,
        max_new_tokens: int,
        temperature: float,
        top_p: float,
    ) -> list[str]:
        ...

    def token_logprobs(
        self, prompts: Sequence[str], completions: Sequence[str]
    ) -> Tuple[Any, Any]:
        ...

    def save(self, output_dir: str) -> None:
        ...


class QLoRARunner:
    """Orchestrate rollouts, verifier rewards, and one optimizer step per task."""

    def __init__(
        self,
        config: RunnerConfig,
        policy: Policy,
        reference_policy: Policy,
        optimizer: Any,
        verifier: DeterministicForgeShadowVerifier | None = None,
        recorder: RunRecorder | None = None,
    ):
        if not TORCH_AVAILABLE:
            raise RuntimeError(
                "PyTorch is required for QLoRARunner. "
                "Install it with: pip install 'heros-rlvr[train]'"
            )
        if optimizer is None:
            raise ValueError("optimizer is required")
        self.config = config
        self.policy = policy
        self.reference_policy = reference_policy
        self.optimizer = optimizer
        self.verifier = verifier or DeterministicForgeShadowVerifier()
        self.recorder = recorder or RunRecorder(config.output_dir)
        self._pending_steps = 0
        self.optimizer.zero_grad(set_to_none=True)

    def train_step(self, task: MigrationTask, step: int) -> StepResult:
        torch = _torch()
        prompt = build_prompt(task)
        completions = self.policy.generate(
            [prompt] * self.config.group_size,
            max_new_tokens=self.config.max_completion_tokens,
            temperature=self.config.temperature,
            top_p=self.config.top_p,
        )
        if len(completions) != self.config.group_size:
            raise ValueError(
                f"policy returned {len(completions)} completions for "
                f"group_size={self.config.group_size}"
            )
        if any(not isinstance(completion, str) for completion in completions):
            raise TypeError("policy completions must be strings")

        batch = build_rollout_batch(task, prompt, completions, self.verifier)
        error_codes: Dict[str, int] = {}
        for receipt in batch.receipts:
            error_codes[receipt.error_code] = error_codes.get(receipt.error_code, 0) + 1

        if not batch.informative:
            return StepResult(
                step=step,
                task_id=task.task_id,
                mean_reward=sum(batch.rewards) / len(batch.rewards),
                reward_std=0.0,
                skipped=True,
                skip_reason="zero_variance_group",
                error_codes=error_codes,
            )

        policy_logprobs, completion_mask = self.policy.token_logprobs(
            [prompt] * self.config.group_size, list(batch.completions)
        )
        reference_logprobs, _ = self.reference_policy.token_logprobs(
            [prompt] * self.config.group_size, list(batch.completions)
        )
        self._validate_logprobs(policy_logprobs, completion_mask)

        old_logprobs = policy_logprobs.detach()
        reference_logprobs = reference_logprobs.detach().to(
            device=policy_logprobs.device, dtype=policy_logprobs.dtype
        )
        rewards = torch.tensor(
            batch.rewards, dtype=policy_logprobs.dtype, device=policy_logprobs.device
        )

        loss, metrics = compute_dr_grpo_token_loss(
            policy_logprobs=policy_logprobs,
            old_logprobs=old_logprobs,
            ref_logprobs=reference_logprobs,
            completion_mask=completion_mask,
            rewards=rewards,
            clip_eps_low=self.config.clip_eps_low,
            clip_eps_high=self.config.clip_eps_high,
            kl_beta=self.config.kl_beta,
            max_completion_len=self.config.max_completion_tokens,
        )

        if not bool(torch.isfinite(loss).item()):
            self.optimizer.zero_grad(set_to_none=True)
            self._pending_steps = 0
            return StepResult(
                step=step,
                task_id=task.task_id,
                mean_reward=metrics["mean_reward"],
                reward_std=metrics["reward_std"],
                skipped=True,
                skip_reason="non_finite_loss",
                error_codes=error_codes,
            )

        # Scale by the accumulation count so eight micro-batches produce the
        # same effective gradient magnitude as one batch of eight.
        (loss / self.config.gradient_accumulation).backward()
        self._pending_steps += 1
        if self._pending_steps >= self.config.gradient_accumulation:
            self._flush_gradients()

        return StepResult(
            step=step,
            task_id=task.task_id,
            mean_reward=float(metrics["mean_reward"]),
            reward_std=float(metrics["reward_std"]),
            loss=float(metrics["loss"]),
            mean_kl=float(metrics["mean_kl"]),
            clip_fraction=float(metrics["clip_fraction"]),
            error_codes=error_codes,
        )

    def _flush_gradients(self) -> None:
        torch = _torch()
        parameters = [
            parameter
            for group in self.optimizer.param_groups
            for parameter in group["params"]
        ]
        if parameters:
            torch.nn.utils.clip_grad_norm_(parameters, self.config.max_grad_norm)
        self.optimizer.step()
        self.optimizer.zero_grad(set_to_none=True)
        self._pending_steps = 0

    def _validate_logprobs(self, logprobs: Any, mask: Any) -> None:
        torch = _torch()
        if not torch.is_tensor(logprobs) or not torch.is_tensor(mask):
            raise TypeError("policy.token_logprobs must return tensors")
        if logprobs.ndim != 2:
            raise ValueError("policy log-probs must be 2-D (group_size, seq_len)")
        if logprobs.shape[0] != self.config.group_size:
            raise ValueError("policy log-probs must have one row per rollout")
        if mask.shape != logprobs.shape:
            raise ValueError("completion mask must match policy log-probs")
        if not bool(torch.isfinite(logprobs).all().item()):
            raise ValueError("policy log-probs contain non-finite values")

    def run(self, tasks: Iterable[MigrationTask], max_steps: int | None = None) -> list[StepResult]:
        limit = self.config.max_steps if max_steps is None else max_steps
        if limit < 1:
            raise ValueError("max_steps must be positive")
        task_list = list(tasks)
        if not task_list:
            raise ValueError("tasks must be non-empty")

        self.recorder.start(self.config)
        results: list[StepResult] = []
        for step, task in enumerate(task_list[:limit], start=1):
            result = self.train_step(task, step)
            self.recorder.append_step(result)
            results.append(result)
            if self.config.checkpoint_every and step % self.config.checkpoint_every == 0:
                checkpoint_dir = str(Path(self.config.output_dir) / f"checkpoint-{step}")
                self.policy.save(checkpoint_dir)
                self.recorder.record_checkpoint(step, checkpoint_dir)

        if self._pending_steps:
            self._flush_gradients()

        if self.config.save_final:
            final_dir = str(Path(self.config.output_dir) / "final")
            self.policy.save(final_dir)
            self.recorder.record_checkpoint(len(results), final_dir)
        self.recorder.finish(results)
        return results


# ---------------------------------------------------------------------------
# Hugging Face adapter (not exercised by the default test suite)
# ---------------------------------------------------------------------------


class HFPolicy:
    """Hugging Face + PEFT adapter for ``QLoRARunner``.

    Construction is lazy: importing this module does not import transformers,
    peft, or bitsandbytes. The adapter is intentionally thin because it cannot be
    validated in the CPU-only test environment; the runner and the verifier are
    the tested parts.
    """

    def __init__(self, model: Any, tokenizer: Any, config: RunnerConfig, reference: bool = False):
        self.model = model
        self.tokenizer = tokenizer
        self.config = config
        self.reference = reference

    @classmethod
    def load(cls, config: RunnerConfig, reference: bool = False) -> "HFPolicy":
        try:
            import torch
            from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
            from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig
        except ImportError as error:  # pragma: no cover - requires the train extra
            raise RuntimeError(
                "HFPolicy requires transformers, peft, and bitsandbytes. "
                "Install with: pip install 'heros-rlvr[train]'"
            ) from error

        cuda = torch.cuda.is_available()
        dtype = torch.float16 if cuda else torch.float32
        tokenizer = AutoTokenizer.from_pretrained(config.model_name)
        if tokenizer.pad_token is None:
            tokenizer.pad_token = tokenizer.eos_token
        # Decoder-only generation requires left padding so ``output[:, input_len:]``
        # is the generated continuation for every prompt in the batch.
        tokenizer.padding_side = "left"

        model_kwargs: Dict[str, Any] = {"torch_dtype": dtype}
        if cuda:
            model_kwargs["device_map"] = "auto"
        if config.load_in_4bit and cuda:
            model_kwargs["quantization_config"] = BitsAndBytesConfig(
                load_in_4bit=True,
                bnb_4bit_quant_type="nf4",
                bnb_4bit_compute_dtype=torch.float16,
                bnb_4bit_use_double_quant=True,
            )
        model = AutoModelForCausalLM.from_pretrained(config.model_name, **model_kwargs)
        model.config.use_cache = False

        if not reference:
            if config.load_in_4bit and cuda:
                model = prepare_model_for_kbit_training(model)
            lora = LoraConfig(
                r=config.lora_r,
                lora_alpha=config.lora_alpha,
                lora_dropout=0.05,
                bias="none",
                task_type="CAUSAL_LM",
                target_modules=[
                    "q_proj",
                    "k_proj",
                    "v_proj",
                    "o_proj",
                    "gate_proj",
                    "up_proj",
                    "down_proj",
                ],
            )
            model = get_peft_model(model, lora)
            model.gradient_checkpointing_enable()
        model.eval()
        return cls(model, tokenizer, config, reference=reference)

    @property
    def device(self) -> Any:
        return next(self.model.parameters()).device

    def _format_prompt(self, prompt: str) -> str:
        apply_chat_template = getattr(self.tokenizer, "apply_chat_template", None)
        if apply_chat_template is None:
            return prompt
        return apply_chat_template(
            [{"role": "user", "content": prompt}],
            tokenize=False,
            add_generation_prompt=True,
        )

    def optimizer(self) -> Any:
        torch = _torch()
        parameters = [parameter for parameter in self.model.parameters() if parameter.requires_grad]
        if not parameters:
            raise RuntimeError("HFPolicy has no trainable parameters")
        return torch.optim.AdamW(parameters, lr=self.config.learning_rate)

    def generate(
        self,
        prompts: Sequence[str],
        *,
        max_new_tokens: int,
        temperature: float,
        top_p: float,
    ) -> list[str]:
        torch = _torch()
        self.model.eval()
        encoded = self.tokenizer(
            [self._format_prompt(prompt) for prompt in prompts],
            return_tensors="pt",
            padding=True,
            truncation=True,
            max_length=self.config.max_prompt_tokens,
        )
        encoded = {key: value.to(self.device) for key, value in encoded.items()}
        with torch.no_grad():
            output = self.model.generate(
                **encoded,
                max_new_tokens=max_new_tokens,
                do_sample=True,
                temperature=temperature,
                top_p=top_p,
                pad_token_id=self.tokenizer.pad_token_id,
            )
        generated = output[:, encoded["input_ids"].shape[1] :]
        return self.tokenizer.batch_decode(generated, skip_special_tokens=True)

    def token_logprobs(
        self, prompts: Sequence[str], completions: Sequence[str]
    ) -> Tuple[Any, Any]:
        torch = _torch()
        if len(prompts) != len(completions):
            raise ValueError("prompts and completions must have equal length")
        if not prompts:
            raise ValueError("prompts must be non-empty")

        self.model.train(not self.reference)
        rows: list[Any] = []
        masks: list[Any] = []
        with torch.set_grad_enabled(not self.reference):
            for prompt, completion in zip(prompts, completions):
                prompt_ids = self.tokenizer(
                    self._format_prompt(prompt),
                    return_tensors="pt",
                    truncation=True,
                    max_length=self.config.max_prompt_tokens,
                ).input_ids
                completion_ids = self.tokenizer(
                    completion,
                    return_tensors="pt",
                    add_special_tokens=False,
                    truncation=True,
                    max_length=self.config.max_completion_tokens,
                ).input_ids
                prompt_length = prompt_ids.shape[1]
                full_ids = torch.cat([prompt_ids, completion_ids], dim=1).to(self.device)
                if full_ids.shape[1] <= prompt_length:
                    rows.append(torch.zeros(1, device=self.device))
                    masks.append(torch.zeros(1, device=self.device))
                    continue

                logits = self.model(input_ids=full_ids).logits[:, :-1, :]
                targets = full_ids[:, 1:]
                token_logprobs = torch.log_softmax(logits, dim=-1).gather(
                    2, targets.unsqueeze(-1)
                ).squeeze(-1)
                start = max(prompt_length - 1, 0)
                sequence = token_logprobs[:, start:]
                rows.append(sequence.squeeze(0))
                masks.append(torch.ones_like(sequence).squeeze(0))

        max_length = max(row.shape[0] for row in rows)
        padded_rows = []
        padded_masks = []
        for row, mask in zip(rows, masks):
            padding = max_length - row.shape[0]
            padded_rows.append(torch.nn.functional.pad(row, (0, padding)))
            padded_masks.append(torch.nn.functional.pad(mask, (0, padding)))
        return torch.stack(padded_rows), torch.stack(padded_masks)

    def save(self, output_dir: str) -> None:
        Path(output_dir).mkdir(parents=True, exist_ok=True)
        self.model.save_pretrained(output_dir)
        self.tokenizer.save_pretrained(output_dir)
