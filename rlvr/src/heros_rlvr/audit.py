"""Audit helpers for verifier error dynamics and unfaithful reasoning.

Two distinct failures are tracked:

* a **miracle step**: the final answer passes the verifier even though an
  intermediate step was marked invalid. This is a heuristic flag for unfaithful
  chains of thought (arXiv:2510.07774), not proof of unfaithfulness.
* **verifier error**: the verifier disagrees with the ground-truth label, which
  measures false positives and false negatives in the reward oracle.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence


@dataclass(frozen=True)
class Step:
    index: int
    valid: bool
    note: str = ""


@dataclass(frozen=True)
class MiracleStepResult:
    flagged: bool
    invalid_indices: tuple[int, ...]
    reason: str


def detect_miracle_step(steps: Sequence[Step], final_correct: bool) -> MiracleStepResult:
    """Flag a correct final answer that contains at least one invalid step.

    The flag is intentionally conservative and explainable: it reports the
    invalid indices so a human or a second verifier can inspect them. It does
    not claim that the model used the invalid step to reach the answer.
    """
    if not final_correct:
        return MiracleStepResult(False, (), "final answer is not correct")

    invalid = tuple(step.index for step in steps if not step.valid)
    if not invalid:
        return MiracleStepResult(False, (), "all intermediate steps valid")

    return MiracleStepResult(
        True,
        invalid,
        "final answer verified despite invalid intermediate steps",
    )


@dataclass(frozen=True)
class AuditRecord:
    verifier_correct: bool
    ground_truth_correct: bool


def verifier_error_rates(records: Sequence[AuditRecord]) -> dict[str, float]:
    if not records:
        raise ValueError("records must be non-empty")

    positives = [record for record in records if record.ground_truth_correct]
    negatives = [record for record in records if not record.ground_truth_correct]

    false_positives = [record for record in negatives if record.verifier_correct]
    false_negatives = [record for record in positives if not record.verifier_correct]

    return {
        "false_positive_rate": len(false_positives) / len(negatives) if negatives else 0.0,
        "false_negative_rate": len(false_negatives) / len(positives) if positives else 0.0,
        "accuracy": sum(
            1 for record in records if record.verifier_correct == record.ground_truth_correct
        )
        / len(records),
    }
