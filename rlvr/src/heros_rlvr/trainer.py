"""Minimal rollout orchestrator for a verifier-driven training step.

This is deliberately framework-agnostic: a policy is any callable that returns a
``Completion``. A PyTorch policy adapter can wrap a model and return per-token
log-probabilities; the CPU tests use deterministic fakes.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Sequence

from .advantages import AdvantageConfig, group_advantages
from .sampling import has_learning_signal
from .verifier import VerificationResult


@dataclass(frozen=True)
class Completion:
    text: str
    token_logps: tuple[float, ...]


@dataclass(frozen=True)
class Rollout:
    prompt: str
    completions: tuple[Completion, ...]
    rewards: tuple[float, ...]
    advantages: tuple[float, ...]
    kept: bool


Policy = Callable[[str], Completion]
Verifier = Callable[[str], VerificationResult]


def build_rollout(
    prompt: str,
    policy: Policy,
    verifier: Verifier,
    group_size: int,
    *,
    use_dr_grpo: bool = True,
    min_std: float = 0.0,
) -> Rollout:
    """Sample a group, score it, and compute group-relative advantages.

    ``kept`` is False when every completion received the same reward. The
    advantages are still returned (all zeros after centering) so callers can
    log the rejected group without recomputing it.
    """
    if group_size < 2:
        raise ValueError("group_size must be at least 2")

    completions: list[Completion] = []
    rewards: list[float] = []

    for _ in range(group_size):
        completion = policy(prompt)
        if not completion.token_logps:
            raise ValueError("policy returned a completion with no token log-probabilities")
        result = verifier(completion.text)
        completions.append(completion)
        rewards.append(result.reward)

    kept = has_learning_signal(rewards, min_std)
    config = AdvantageConfig(normalize_std=not use_dr_grpo)
    advantages = group_advantages(rewards, config)

    return Rollout(
        prompt=prompt,
        completions=tuple(completions),
        rewards=tuple(rewards),
        advantages=tuple(advantages),
        kept=kept,
    )
