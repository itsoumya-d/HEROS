"""Group-relative advantage estimators for RLVR.

The two biases isolated by Dr.GRPO (arXiv:2503.20783) are explicit here:

* standard-deviation normalization rescales every group to unit variance, so a
  group with a tiny reward spread produces the same gradient magnitude as a
  group with a large one;
* length normalization (in the loss, not here) gives each token in a long
  completion less weight.

This module implements the advantage half. The loss half lives in
``heros_rlvr.losses``.
"""

from __future__ import annotations

from dataclasses import dataclass
from math import sqrt
from typing import Sequence


@dataclass(frozen=True)
class AdvantageConfig:
    """Controls centering and variance normalization of a reward group."""

    center: bool = True
    normalize_std: bool = True
    eps: float = 1e-6


def group_advantages(
    rewards: Sequence[float],
    config: AdvantageConfig = AdvantageConfig(),
) -> list[float]:
    """Return one advantage per reward in a group.

    ``normalize_std=True`` is vanilla GRPO. ``normalize_std=False`` is the
    Dr.GRPO advantage: centering stays, variance normalization is removed.
    """
    if not rewards:
        raise ValueError("rewards must be non-empty")

    count = len(rewards)
    mean = sum(rewards) / count
    centered = [reward - mean for reward in rewards] if config.center else list(rewards)

    if not config.normalize_std:
        return centered

    variance = sum((reward - mean) ** 2 for reward in rewards) / count
    std = sqrt(variance)
    return [value / (std + config.eps) for value in centered]


def dr_grpo_advantages(rewards: Sequence[float]) -> list[float]:
    """Dr.GRPO advantage: center the group, do not divide by its std."""
    return group_advantages(rewards, AdvantageConfig(normalize_std=False))
