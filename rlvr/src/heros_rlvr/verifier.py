"""Deterministic reward oracles for verifiable reasoning.

The verifier is the trust boundary: it turns a completion into a scalar reward.
``CommandVerifier`` is the adapter used for the HEROS ``forge`` binary. It sends
the completion to stdin and expects one JSON object on stdout with a boolean
``ok`` field. The command is responsible for sandboxing and time limits.
"""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass, field
from typing import Sequence


@dataclass(frozen=True)
class VerificationResult:
    correct: bool
    reward: float
    format_ok: bool
    detail: dict[str, object] = field(default_factory=dict)


def has_think_answer_format(text: str) -> bool:
    """Require a <think>...</think> block followed by a non-empty answer block."""
    lowered = text.lower()
    think_start = lowered.find("<think>")
    think_end = lowered.find("</think>")
    if think_start < 0 or think_end < think_start:
        return False

    answer_start = lowered.find("<answer>", think_end)
    answer_end = lowered.find("</answer>", answer_start + len("<answer>"))
    if answer_start < 0 or answer_end < answer_start:
        return False

    return bool(text[answer_start + len("<answer>") : answer_end].strip())


def compose_reward(correct: bool, format_ok: bool, format_weight: float = 0.1) -> float:
    if format_weight < 0:
        raise ValueError("format_weight must be non-negative")
    return (1.0 if correct else 0.0) + (format_weight if format_ok else 0.0)


def _parse_last_json(stdout: str) -> dict[str, object]:
    for line in reversed([line.strip() for line in stdout.splitlines() if line.strip()]):
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(value, dict):
            raise ValueError("verifier JSON must be an object")
        return value
    raise ValueError("verifier produced no JSON object")


class CommandVerifier:
    """Run a command with the completion on stdin and parse ``{"ok": bool}``."""

    def __init__(
        self,
        command: Sequence[str],
        timeout_seconds: float = 10.0,
        format_weight: float = 0.1,
        require_format: bool = True,
    ) -> None:
        if not command:
            raise ValueError("command must be non-empty")
        if timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be positive")
        self.command = tuple(command)
        self.timeout_seconds = timeout_seconds
        self.format_weight = format_weight
        self.require_format = require_format

    def verify(self, completion: str) -> VerificationResult:
        formatted = has_think_answer_format(completion)
        if self.require_format and not formatted:
            return VerificationResult(
                correct=False,
                reward=0.0,
                format_ok=False,
                detail={"error": "missing_think_answer_format"},
            )

        try:
            completed = subprocess.run(
                self.command,
                input=completion,
                capture_output=True,
                text=True,
                timeout=self.timeout_seconds,
                check=False,
            )
        except subprocess.TimeoutExpired:
            return VerificationResult(
                correct=False,
                reward=compose_reward(False, formatted, self.format_weight),
                format_ok=formatted,
                detail={"error": "verifier_timeout"},
            )

        if completed.returncode != 0:
            return VerificationResult(
                correct=False,
                reward=compose_reward(False, formatted, self.format_weight),
                format_ok=formatted,
                detail={
                    "error": "verifier_exit_nonzero",
                    "returncode": completed.returncode,
                    "stderr": completed.stderr[-500:],
                },
            )

        try:
            payload = _parse_last_json(completed.stdout)
        except ValueError as error:
            return VerificationResult(
                correct=False,
                reward=compose_reward(False, formatted, self.format_weight),
                format_ok=formatted,
                detail={"error": str(error), "stdout": completed.stdout[-500:]},
            )

        ok = payload.get("ok")
        if not isinstance(ok, bool):
            return VerificationResult(
                correct=False,
                reward=compose_reward(False, formatted, self.format_weight),
                format_ok=formatted,
                detail={"error": "verifier_missing_boolean_ok", "payload": payload},
            )

        return VerificationResult(
            correct=ok,
            reward=compose_reward(ok, formatted, self.format_weight),
            format_ok=formatted,
            detail=payload,
        )
