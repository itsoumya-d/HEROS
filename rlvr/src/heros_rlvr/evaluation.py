"""Pure aggregation helpers for held-out migration evaluations."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any, Iterable, Mapping, Sequence


@dataclass(frozen=True)
class EvalItem:
    task_id: str
    hazard: str
    expected_tier: str
    total_reward: float
    risk_calibration_reward: float
    shadow_row_loss_detected: bool
    error_code: str
    risk_match: bool | None = None
    loss_match: bool | None = None
    decision_match: bool | None = None

    @classmethod
    def from_mapping(cls, value: Mapping[str, Any]) -> "EvalItem":
        return cls(
            task_id=str(value["task_id"]),
            hazard=str(value.get("hazard", "unspecified")),
            expected_tier=str(value.get("expected_tier", "")),
            total_reward=float(value["total_reward"]),
            risk_calibration_reward=float(value.get("risk_calibration_reward", 0.0)),
            shadow_row_loss_detected=bool(value.get("shadow_row_loss_detected", False)),
            error_code=str(value.get("error_code", "")),
            risk_match=value.get("risk_match"),
            loss_match=value.get("loss_match"),
            decision_match=value.get("decision_match"),
        )

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def select_eval_tasks(tasks: Sequence[Any], start: int, limit: int) -> list[Any]:
    """Select a deterministic slice; fail loudly on an invalid range."""
    if start < 0:
        raise ValueError("start must be non-negative")
    if limit < 1:
        raise ValueError("limit must be positive")
    selected = list(tasks[start : start + limit])
    if len(selected) != limit:
        raise ValueError(
            f"requested {limit} tasks from index {start}, dataset has {len(tasks)}"
        )
    return selected


def summarize_evaluations(
    items: Iterable[Mapping[str, Any] | EvalItem],
    *,
    elapsed_sec: float = 0.0,
    vram_mb: float = 0.0,
) -> dict[str, Any]:
    """Aggregate per-task results without hiding missing or failed tasks."""
    parsed = [
        item if isinstance(item, EvalItem) else EvalItem.from_mapping(item)
        for item in items
    ]
    if not parsed:
        raise ValueError("cannot summarize an empty evaluation")

    rewards = [item.total_reward for item in parsed]
    error_codes: dict[str, int] = {}
    hazards: dict[str, int] = {}
    for item in parsed:
        error_codes[item.error_code] = error_codes.get(item.error_code, 0) + 1
        hazards[item.hazard] = hazards.get(item.hazard, 0) + 1

    risk_matches = [item.risk_match for item in parsed if item.risk_match is not None]
    loss_matches = [item.loss_match for item in parsed if item.loss_match is not None]
    decision_matches = [
        item.decision_match for item in parsed if item.decision_match is not None
    ]

    return {
        "tasks": len(parsed),
        "mean_reward": round(sum(rewards) / len(rewards), 4),
        "ok_rate": round(
            sum(1 for item in parsed if item.error_code == "OK") / len(parsed), 4
        ),
        "risk_accuracy": (
            round(sum(1 for value in risk_matches if value) / len(risk_matches), 4)
            if risk_matches
            else None
        ),
        "loss_accuracy": (
            round(sum(1 for value in loss_matches if value) / len(loss_matches), 4)
            if loss_matches
            else None
        ),
        "decision_accuracy": (
            round(
                sum(1 for value in decision_matches if value)
                / len(decision_matches),
                4,
            )
            if decision_matches
            else None
        ),
        "calibration_mean": round(
            sum(item.risk_calibration_reward for item in parsed) / len(parsed), 4
        ),
        "calibration_full_rate": round(
            sum(1 for item in parsed if item.risk_calibration_reward == 1.0) / len(parsed),
            4,
        ),
        "row_loss_rate": round(
            sum(1 for item in parsed if item.shadow_row_loss_detected) / len(parsed), 4
        ),
        "error_codes": dict(sorted(error_codes.items())),
        "hazards": dict(sorted(hazards.items())),
        "elapsed_sec": round(elapsed_sec, 2),
        "vram_mb": round(vram_mb, 1),
    }
