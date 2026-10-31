"""Clipped policy-gradient losses for GRPO, Dr.GRPO and DAPO.

All functions are pure Python so the objective can be tested without a GPU or
PyTorch. The trainer passes per-token log-probabilities produced by whatever
policy implementation it uses.

Notation follows DeepSeekMath (arXiv:2402.03300) and DAPO (arXiv:2503.14476):

    r_t = exp(logpi_t - logpi_old_t)
    surrogate_t = min(r_t * A, clip(r_t, 1 - eps_low, 1 + eps_high) * A)

The ``length_normalization`` field selects the reduction:

* ``"length"``: mean over tokens per sequence, then mean over sequences
  (vanilla GRPO's ``1/|o_i|`` factor).
* ``"token"``: sum over every token divided by the total token count
  (DAPO token-level loss).
* ``"none"``: sum over every token divided by the group size. No length
  normalization, so long sequences contribute more (Dr.GRPO).
"""

from __future__ import annotations

from dataclasses import dataclass
from math import exp
from typing import Sequence


@dataclass(frozen=True)
class LossConfig:
    clip_low: float = 0.2
    clip_high: float = 0.2
    kl_coef: float = 0.0
    length_normalization: str = "length"
    kl_estimator: str = "k3"


@dataclass(frozen=True)
class LossResult:
    loss: float
    mean_ratio: float
    clip_fraction: float
    mean_kl: float
    token_count: int


def grpo_config() -> LossConfig:
    return LossConfig(clip_low=0.2, clip_high=0.2, length_normalization="length")


def dr_grpo_config(kl_coef: float = 0.0) -> LossConfig:
    return LossConfig(clip_low=0.2, clip_high=0.2, kl_coef=kl_coef, length_normalization="none")


def dapo_config(kl_coef: float = 0.0) -> LossConfig:
    return LossConfig(clip_low=0.2, clip_high=0.28, kl_coef=kl_coef, length_normalization="token")


def _validate(
    policy_logps: Sequence[Sequence[float]],
    old_logps: Sequence[Sequence[float]],
    advantages: Sequence[float],
    reference_logps: Sequence[Sequence[float]] | None,
) -> None:
    if not policy_logps:
        raise ValueError("policy_logps must be non-empty")
    if len(policy_logps) != len(old_logps) or len(policy_logps) != len(advantages):
        raise ValueError("policy_logps, old_logps and advantages must have equal length")
    for index, (policy, old) in enumerate(zip(policy_logps, old_logps)):
        if len(policy) != len(old):
            raise ValueError(f"sequence {index}: policy/old token lengths differ")
        if not policy:
            raise ValueError(f"sequence {index}: empty token sequence")
    if reference_logps is not None:
        if len(reference_logps) != len(policy_logps):
            raise ValueError("reference_logps must match the number of sequences")
        for index, (policy, reference) in enumerate(zip(policy_logps, reference_logps)):
            if len(policy) != len(reference):
                raise ValueError(f"sequence {index}: policy/reference token lengths differ")


def grpo_loss(
    policy_logps: Sequence[Sequence[float]],
    old_logps: Sequence[Sequence[float]],
    advantages: Sequence[float],
    reference_logps: Sequence[Sequence[float]] | None = None,
    config: LossConfig = LossConfig(),
) -> LossResult:
    """Return the clipped objective plus diagnostics.

    ``kl_coef`` scales a per-token KL penalty. ``kl_estimator="k3"`` uses the
    unbiased estimator ``exp(ref - policy) - (ref - policy) - 1``; ``"simple"``
    uses ``policy - ref``.
    """
    _validate(policy_logps, old_logps, advantages, reference_logps)

    if config.length_normalization not in {"length", "token", "none"}:
        raise ValueError("length_normalization must be 'length', 'token' or 'none'")
    if config.kl_estimator not in {"k3", "simple"}:
        raise ValueError("kl_estimator must be 'k3' or 'simple'")

    ratios: list[float] = []
    clipped: list[float] = []
    kl_terms: list[float] = []
    per_sequence_sums: list[float] = []
    per_sequence_tokens: list[int] = []

    for index, (policy, old) in enumerate(zip(policy_logps, old_logps)):
        advantage = advantages[index]
        sequence_sum = 0.0

        for token_index, (policy_token, old_token) in enumerate(zip(policy, old)):
            ratio = exp(policy_token - old_token)
            unclipped = ratio * advantage
            clipped_ratio = min(max(ratio, 1.0 - config.clip_low), 1.0 + config.clip_high)
            surrogate = min(unclipped, clipped_ratio * advantage)

            sequence_sum += surrogate
            ratios.append(ratio)
            clipped.append(1.0 if surrogate != unclipped else 0.0)

            if reference_logps is not None:
                reference_token = reference_logps[index][token_index]
                if config.kl_estimator == "k3":
                    delta = reference_token - policy_token
                    kl_terms.append(exp(delta) - delta - 1.0)
                else:
                    kl_terms.append(policy_token - reference_token)

        per_sequence_sums.append(sequence_sum)
        per_sequence_tokens.append(len(policy))

    total_tokens = sum(per_sequence_tokens)
    if config.length_normalization == "length":
        policy_objective = sum(
            sequence_sum / token_count
            for sequence_sum, token_count in zip(per_sequence_sums, per_sequence_tokens)
        ) / len(per_sequence_sums)
    elif config.length_normalization == "token":
        policy_objective = sum(per_sequence_sums) / total_tokens
    else:
        policy_objective = sum(per_sequence_sums) / len(per_sequence_sums)

    mean_kl = sum(kl_terms) / len(kl_terms) if kl_terms else 0.0
    loss = -policy_objective + config.kl_coef * mean_kl

    return LossResult(
        loss=loss,
        mean_ratio=sum(ratios) / len(ratios),
        clip_fraction=sum(clipped) / len(clipped),
        mean_kl=mean_kl,
        token_count=total_tokens,
    )
