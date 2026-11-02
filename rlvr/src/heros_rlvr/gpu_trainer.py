"""HEROS-RLVR-Studio: deterministic SQLite shadow verifier and Dr.GRPO/DAPO loss.

This module bridges the HEROS deterministic schema-risk gate (``forge``) with a
PyTorch post-training loop. The verifier half is intentionally dependency-free
beyond the standard library; the loss half requires ``torch``.

Two properties matter more than any benchmark number:

1. The reward is produced by executing SQL against an ephemeral in-memory
   database, not by an LLM judge. A rollout that breaks the schema receives a
   deterministic penalty.
2. The Dr.GRPO loss normalizes by a constant horizon (``group_size * max_len``)
   instead of each sequence's own token count, which removes the length bias
   that vanilla GRPO introduces.

The module is device-agnostic. It runs on CPU in CI and on CUDA when a GPU is
available; no GPU training result is claimed by this file alone.
"""

from __future__ import annotations

import json
import math
import re
import sqlite3
from collections.abc import Sequence
from dataclasses import dataclass

import torch

__all__ = [
    "DapoDynamicSampler",
    "DeterministicForgeShadowVerifier",
    "MigrationTask",
    "VerificationReceipt",
    "compute_dr_grpo_token_loss",
]

RISK_TIERS = ("SAFE", "WARN", "CRITICAL")

# Statements that can escape the in-memory shadow gate or mutate the host.
_FORBIDDEN_SQL = (
    "attach",
    "detach",
    "pragma",
    "vacuum",
    "load_extension",
    "backup",
    "restore",
)


@dataclass(frozen=True)
class MigrationTask:
    """A deterministic schema-migration verification prompt."""

    task_id: str
    from_ddl: str
    seed_sql: str
    requirement: str
    expected_risk_tier: str
    expected_data_loss: bool
    decision_required: bool


@dataclass(frozen=True)
class VerificationReceipt:
    """Audit receipt emitted by the deterministic HEROS shadow verifier."""

    task_id: str
    total_reward: float
    format_reward: float
    shadow_exec_reward: float
    risk_calibration_reward: float
    miracle_step_penalty: float
    shadow_row_loss_detected: bool
    error_code: str


@dataclass(frozen=True)
class _SchemaSnapshot:
    """Row counts and column signatures captured before/after a migration."""

    rows: dict[str, int]
    columns: dict[str, tuple[str, ...]]


class DeterministicForgeShadowVerifier:
    """Execute SQL in an ephemeral SQLite gate and score the rollout's manifest.

    Reward decomposition (maximum 2.0):

    ``format`` (0.25) + ``shadow_exec`` (0.75) + ``risk_calibration`` (1.0)
    - ``miracle_penalty`` (0.4).

    ``risk_calibration`` is 0.5 for the exact risk tier, 0.25 for the data-loss
    flag and 0.25 for the approval flag. A missing envelope returns -1.0 and
    malformed JSON returns -0.5; both are worse than a well-formed wrong answer.
    """

    THINK_PATTERN = re.compile(r"<think>(.*?)</think>", re.DOTALL)
    SQL_PATTERN = re.compile(r"<sql_migration>(.*?)</sql_migration>", re.DOTALL)
    JSON_PATTERN = re.compile(r"<forge_manifest>(.*?)</forge_manifest>", re.DOTALL)
    DESTRUCTIVE_KEYWORDS = (
        "drop table",
        "drop column",
        "truncate",
        "delete from",
        "alter column",
        "recreate",
    )
    _REASONING_STEMS = (
        "drop",
        "delet",
        "truncat",
        "destro",
        "loss",
        "recreat",
        "remov",
        "backfill",
    )

    def verify_rollout(self, task: MigrationTask, completion: str) -> VerificationReceipt:
        if task.expected_risk_tier not in RISK_TIERS:
            raise ValueError(f"unknown expected risk tier: {task.expected_risk_tier!r}")

        think_match = self.THINK_PATTERN.search(completion)
        sql_match = self.SQL_PATTERN.search(completion)
        json_match = self.JSON_PATTERN.search(completion)

        if not (think_match and sql_match and json_match):
            return VerificationReceipt(
                task_id=task.task_id,
                total_reward=-1.0,
                format_reward=-1.0,
                shadow_exec_reward=0.0,
                risk_calibration_reward=0.0,
                miracle_step_penalty=0.0,
                shadow_row_loss_detected=False,
                error_code="MISSING_BLOCKS",
            )

        think_text = think_match.group(1).strip()
        proposed_sql = sql_match.group(1).strip()
        manifest_raw = json_match.group(1).strip()

        try:
            manifest = json.loads(manifest_raw)
        except json.JSONDecodeError:
            return self._receipt(task, -0.5, -0.5, 0.0, 0.0, 0.0, False, "INVALID_JSON")

        if not isinstance(manifest, dict):
            return self._receipt(task, -0.5, -0.5, 0.0, 0.0, 0.0, False, "INVALID_JSON")

        format_reward = 0.25
        exec_ok, data_loss_detected = self._run_sqlite_shadow_gate(
            task.from_ddl, task.seed_sql, proposed_sql
        )

        if not exec_ok:
            return self._receipt(
                task, format_reward - 0.75, format_reward, -0.75, 0.0, 0.0, False, "SQL_EXEC_ERROR"
            )

        shadow_exec_reward = 0.75

        pred_risk = str(manifest.get("risk_tier", "")).upper()
        pred_loss = bool(manifest.get("has_data_loss", False))
        pred_decision = bool(manifest.get("decision_required", False))

        calibration = 0.0
        if pred_risk == task.expected_risk_tier:
            calibration += 0.5
        if pred_loss == (task.expected_data_loss or data_loss_detected):
            calibration += 0.25
        if pred_decision == task.decision_required:
            calibration += 0.25

        miracle_penalty = self._miracle_step_penalty(think_text, proposed_sql, pred_loss)

        total = format_reward + shadow_exec_reward + calibration - miracle_penalty
        return self._receipt(
            task,
            total,
            format_reward,
            shadow_exec_reward,
            calibration,
            miracle_penalty,
            data_loss_detected,
            "OK",
        )

    def _miracle_step_penalty(self, think_text: str, proposed_sql: str, predicts_loss: bool) -> float:
        """Penalize destructive claims that are not grounded in the reasoning trace.

        The heuristic is deliberately narrow. It fires only when the completion
        predicts data loss or emits a destructive statement *and* the reasoning
        trace is too short to have analysed the operation. It is not a
        faithfulness proof; flagged samples should be routed to a second gate.
        """
        lowered_sql = proposed_sql.lower()
        destructive_sql = any(keyword in lowered_sql for keyword in self.DESTRUCTIVE_KEYWORDS)
        if not (predicts_loss or destructive_sql):
            return 0.0
        analysed = len(think_text) >= 24 and any(
            stem in think_text.lower() for stem in self._REASONING_STEMS
        )
        if analysed:
            return 0.0
        return 0.4

    @staticmethod
    def _receipt(
        task: MigrationTask,
        total: float,
        format_reward: float,
        shadow_exec: float,
        calibration: float,
        miracle: float,
        row_loss: bool,
        error_code: str,
    ) -> VerificationReceipt:
        return VerificationReceipt(
            task_id=task.task_id,
            total_reward=round(total, 4),
            format_reward=round(format_reward, 4),
            shadow_exec_reward=round(shadow_exec, 4),
            risk_calibration_reward=round(calibration, 4),
            miracle_step_penalty=round(miracle, 4),
            shadow_row_loss_detected=row_loss,
            error_code=error_code,
        )

    @classmethod
    def _run_sqlite_shadow_gate(
        cls, from_ddl: str, seed_sql: str, migration_sql: str
    ) -> tuple[bool, bool]:
        """Apply a migration in memory and report whether data was lost.

        Data loss covers both row loss (a delete/truncate) and column loss (a
        dropped column or a table recreated with fewer columns), which is the
        failure mode a row-count-only check misses.
        """
        if not cls._is_allowed_script(migration_sql):
            return False, False

        conn = sqlite3.connect(":memory:")
        try:
            conn.executescript(from_ddl)
            if seed_sql.strip():
                conn.executescript(seed_sql)

            before = cls._snapshot(conn)
            conn.executescript(migration_sql)
            after = cls._snapshot(conn)

            data_loss = False
            for table, before_rows in before.rows.items():
                after_rows = after.rows.get(table, 0)
                if after_rows < before_rows:
                    data_loss = True
                    break
                if after.columns.get(table, ()) and not set(before.columns[table]).issubset(
                    after.columns.get(table, ())
                ):
                    data_loss = True
                    break
            return True, data_loss
        except sqlite3.Error:
            return False, False
        finally:
            conn.close()

    @staticmethod
    def _is_allowed_script(script: str) -> bool:
        """Reject statements that can escape the in-memory gate.

        This is a defence-in-depth check, not a sandbox. The caller must still
        run the verifier in a process without filesystem or network access when
        the model output is untrusted.
        """
        if not script.strip():
            return False
        lowered = script.lower()
        for keyword in _FORBIDDEN_SQL:
            if re.search(rf"\b{re.escape(keyword)}\b", lowered):
                return False
        return True

    @staticmethod
    def _snapshot(conn: sqlite3.Connection) -> _SchemaSnapshot:
        cursor = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"
        )
        tables = [row[0] for row in cursor.fetchall()]
        rows: dict[str, int] = {}
        columns: dict[str, tuple[str, ...]] = {}
        for table in tables:
            quoted = table.replace('"', '""')
            count_cursor = conn.execute(f'SELECT COUNT(*) FROM "{quoted}";')
            rows[table] = int(count_cursor.fetchone()[0])
            pragma_cursor = conn.execute(f'PRAGMA table_info("{quoted}");')
            columns[table] = tuple(str(row[1]) for row in pragma_cursor.fetchall())
        return _SchemaSnapshot(rows=rows, columns=columns)


class DapoDynamicSampler:
    """DAPO dynamic sampling plus the Dr.GRPO advantage estimator."""

    @staticmethod
    def is_informative_group(rewards: Sequence[float], min_std: float = 1e-5) -> bool:
        """A group teaches nothing when every rollout earns the same reward."""
        if len(rewards) < 2:
            return False
        mean_reward = sum(rewards) / len(rewards)
        variance = sum((reward - mean_reward) ** 2 for reward in rewards) / len(rewards)
        return math.sqrt(variance) > min_std

    @staticmethod
    def filter_informative_groups(
        groups: Sequence[Sequence[float]], min_std: float = 1e-5
    ) -> list[Sequence[float]]:
        return [group for group in groups if DapoDynamicSampler.is_informative_group(group, min_std)]

    @staticmethod
    def compute_dr_grpo_advantages(rewards: torch.Tensor) -> torch.Tensor:
        """``A_i = r_i - mean(r)``; no standard-deviation division."""
        if rewards.numel() == 0:
            raise ValueError("rewards must be non-empty")
        return rewards - rewards.mean()


def compute_dr_grpo_token_loss(
    policy_logprobs: torch.Tensor,
    old_logprobs: torch.Tensor,
    ref_logprobs: torch.Tensor,
    completion_mask: torch.Tensor,
    rewards: torch.Tensor,
    clip_eps_low: float = 0.2,
    clip_eps_high: float = 0.28,
    kl_beta: float = 0.01,
    max_completion_len: int = 512,
) -> tuple[torch.Tensor, dict[str, float]]:
    """Dr.GRPO objective with DAPO's asymmetric clip and k3 KL estimator.

    Shapes: log-probabilities and mask are ``(group_size, max_len)``; rewards are
    ``(group_size,)``. The reduction is ``1 / (group_size * max_completion_len)``
    so every sequence — short or long — has the same per-token coefficient.
    """
    if policy_logprobs.shape != old_logprobs.shape or policy_logprobs.shape != ref_logprobs.shape:
        raise ValueError("policy, old and reference log-probability tensors must align")
    if policy_logprobs.shape != completion_mask.shape:
        raise ValueError("completion_mask must match log-probability shape")
    if policy_logprobs.dim() != 2:
        raise ValueError("log-probability tensors must be (group_size, max_len)")
    if rewards.dim() != 1 or rewards.shape[0] != policy_logprobs.shape[0]:
        raise ValueError("rewards must have one entry per completion")
    if clip_eps_low < 0 or clip_eps_high < 0:
        raise ValueError("clip epsilons must be non-negative")
    if max_completion_len <= 0:
        raise ValueError("max_completion_len must be positive")

    group_size = policy_logprobs.shape[0]
    advantages = DapoDynamicSampler.compute_dr_grpo_advantages(rewards).unsqueeze(1).detach()

    log_ratio = torch.clamp(policy_logprobs - old_logprobs.detach(), min=-20.0, max=20.0)
    ratio = torch.exp(log_ratio)

    surrogate_unclipped = ratio * advantages
    clipped_ratio = torch.clamp(ratio, 1.0 - clip_eps_low, 1.0 + clip_eps_high)
    surrogate_clipped = clipped_ratio * advantages
    policy_objective = torch.minimum(surrogate_unclipped, surrogate_clipped)

    # k3 estimator: exp(ref - policy) - (ref - policy) - 1, always >= 0.
    ref_delta = torch.clamp(ref_logprobs.detach() - policy_logprobs, min=-20.0, max=20.0)
    per_token_kl = torch.exp(ref_delta) - ref_delta - 1.0

    per_token_loss = -(policy_objective - kl_beta * per_token_kl) * completion_mask
    loss = per_token_loss.sum() / (group_size * float(max_completion_len))

    with torch.no_grad():
        valid_tokens = completion_mask.sum().clamp(min=1.0)
        mean_kl = (per_token_kl * completion_mask).sum() / valid_tokens
        clipped = (
            (ratio < (1.0 - clip_eps_low)) | (ratio > (1.0 + clip_eps_high))
        ).to(completion_mask.dtype)
        clip_fraction = (clipped * completion_mask).sum() / valid_tokens
        effective_tokens = (completion_mask > 0).sum().clamp(min=1)
        mean_ratio = (ratio * completion_mask).sum() / valid_tokens

    metrics = {
        "loss": float(loss.detach().item()),
        "mean_reward": float(rewards.mean().detach().item()),
        "reward_std": float(rewards.std(unbiased=False).detach().item()),
        "mean_kl": float(mean_kl.item()),
        "clip_fraction": float(clip_fraction.item()),
        "mean_ratio": float(mean_ratio.item()),
        "effective_tokens": int(effective_tokens.item()),
        "group_size": int(group_size),
    }
    return loss, metrics
