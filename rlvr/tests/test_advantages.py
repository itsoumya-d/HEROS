from __future__ import annotations

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "src"))

from heros_rlvr import AdvantageConfig, dr_grpo_advantages, group_advantages  # noqa: E402


class AdvantageTests(unittest.TestCase):
    def test_vanilla_grpo_normalizes_by_std(self) -> None:
        advantages = group_advantages(
            [1.0, 0.0, 0.0, 1.0],
            AdvantageConfig(eps=0.0),
        )
        self.assertEqual(advantages, [1.0, -1.0, -1.0, 1.0])

    def test_dr_grpo_keeps_centering_and_drops_std(self) -> None:
        advantages = dr_grpo_advantages([1.0, 0.0, 0.0, 1.0])
        self.assertEqual(advantages, [0.5, -0.5, -0.5, 0.5])

    def test_constant_group_has_zero_advantages(self) -> None:
        self.assertEqual(group_advantages([1.0, 1.0, 1.0]), [0.0, 0.0, 0.0])
        self.assertEqual(dr_grpo_advantages([0.0, 0.0]), [0.0, 0.0])

    def test_empty_group_rejects(self) -> None:
        with self.assertRaises(ValueError):
            group_advantages([])


if __name__ == "__main__":
    unittest.main()
