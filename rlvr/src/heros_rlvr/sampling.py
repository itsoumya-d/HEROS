"""Dynamic sampling for zero-variance reward groups.

DAPO (arXiv:2503.14476) discards groups in which every completion receives the
same reward. Such a group has no learning signal after group-relative
advantage computation, so it wastes rollout tokens and, with std
normalization, produces numerically unstable ratios.
"""

from __future__ import annotations

from math import sqrt
from typing import Sequence


def group_std(rewards: Sequence[float]) -> float:
    if not rewards:
        raise ValueError("rewards must be non-empty")
    mean = sum(rewards) / len(rewards)
    return sqrt(sum((reward - mean) ** 2 for reward in rewards) / len(rewards))


def has_learning_signal(rewards: Sequence[float], min_std: float = 0.0) -> bool:
    """A group is usable when it has at least two distinct rewards and std > min_std."""
    if len(rewards) < 2:
        return False
    if len(set(rewards)) < 2:
        return False
    return group_std(rewards) > min_std


def dynamic_sample(
    groups: Sequence[Sequence[float]],
    min_std: float = 0.0,
) -> list[Sequence[float]]:
    return [group for group in groups if has_learning_signal(group, min_std)]


def rejection_rate(groups: Sequence[Sequence[float]], min_std: float = 0.0) -> float:
    if not groups:
        raise ValueError("groups must be non-empty")
    kept = len(dynamic_sample(groups, min_std))
    return 1.0 - kept / len(groups)
