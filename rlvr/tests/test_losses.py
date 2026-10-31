from __future__ import annotations

import math
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "src"))

from heros_rlvr import (  # noqa: E402
    LossConfig,
    dapo_config,
    dr_grpo_config,
    grpo_config,
    grpo_loss,
)


class LossTests(unittest.TestCase):
    def test_uniform_ratio_returns_negative_mean_advantage(self) -> None:
        result = grpo_loss(
            policy_logps=[[0.0], [0.0]],
            old_logps=[[0.0], [0.0]],
            advantages=[1.0, 1.0],
            config=grpo_config(),
        )
        self.assertAlmostEqual(result.loss, -1.0)
        self.assertEqual(result.mean_ratio, 1.0)
        self.assertEqual(result.clip_fraction, 0.0)
        self.assertEqual(result.token_count, 2)

    def test_length_normalization_changes_long_sequence_weight(self) -> None:
        policy = [[0.0], [0.0, 0.0, 0.0]]
        old = [[0.0], [0.0, 0.0, 0.0]]
        advantages = [1.0, 1.0]

        length = grpo_loss(policy, old, advantages, config=grpo_config())
        token = grpo_loss(policy, old, advantages, config=dapo_config())
        none = grpo_loss(policy, old, advantages, config=dr_grpo_config())

        self.assertAlmostEqual(length.loss, -1.0)
        self.assertAlmostEqual(token.loss, -1.0)
        self.assertAlmostEqual(none.loss, -2.0)
        self.assertEqual(token.token_count, 4)

    def test_large_ratio_is_clipped(self) -> None:
        result = grpo_loss(
            policy_logps=[[1.0]],
            old_logps=[[0.0]],
            advantages=[1.0],
            config=LossConfig(clip_low=0.2, clip_high=0.2, length_normalization="length"),
        )
        self.assertAlmostEqual(result.loss, -1.2)
        self.assertGreater(result.mean_ratio, 2.0)

    def test_zero_advantage_produces_zero_loss_and_no_clipping(self) -> None:
        result = grpo_loss([[0.5, -0.5]], [[0.0, 0.0]], [0.0])
        self.assertAlmostEqual(result.loss, 0.0)
        self.assertEqual(result.clip_fraction, 0.0)

    def test_kl_is_zero_when_reference_matches_policy(self) -> None:
        result = grpo_loss(
            [[0.0, 0.0]],
            [[0.0, 0.0]],
            [1.0],
            reference_logps=[[0.0, 0.0]],
            config=LossConfig(kl_coef=0.1),
        )
        self.assertAlmostEqual(result.mean_kl, 0.0)
        self.assertAlmostEqual(result.loss, -1.0)

    def test_kl_k3_is_non_negative(self) -> None:
        result = grpo_loss(
            [[-2.0]],
            [[-2.0]],
            [1.0],
            reference_logps=[[-1.0]],
            config=LossConfig(kl_coef=0.5),
        )
        self.assertGreater(result.mean_kl, 0.0)
        self.assertAlmostEqual(result.mean_kl, math.e - 1.0 - 1.0, places=6)

    def test_config_validation(self) -> None:
        with self.assertRaises(ValueError):
            grpo_loss([[0.0]], [[0.0]], [1.0], config=LossConfig(length_normalization="mean"))
        with self.assertRaises(ValueError):
            grpo_loss([[0.0]], [[0.0]], [1.0], config=LossConfig(kl_estimator="k1"))
        with self.assertRaises(ValueError):
            grpo_loss([], [], [])
        with self.assertRaises(ValueError):
            grpo_loss([[0.0]], [[0.0, 1.0]], [1.0])
        with self.assertRaises(ValueError):
            grpo_loss([[]], [[]], [1.0])


if __name__ == "__main__":
    unittest.main()
