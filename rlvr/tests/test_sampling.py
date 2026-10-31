from __future__ import annotations

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "src"))

from heros_rlvr import dynamic_sample, has_learning_signal, rejection_rate  # noqa: E402


class SamplingTests(unittest.TestCase):
    def test_mixed_group_is_kept(self) -> None:
        self.assertTrue(has_learning_signal([1.0, 0.0, 0.0, 1.0]))

    def test_all_correct_and_all_wrong_groups_are_rejected(self) -> None:
        self.assertFalse(has_learning_signal([1.0, 1.0, 1.0]))
        self.assertFalse(has_learning_signal([0.0, 0.0]))
        self.assertFalse(has_learning_signal([1.0]))

    def test_min_std_rejects_nearly_uniform_groups(self) -> None:
        self.assertFalse(has_learning_signal([1.0, 0.999], min_std=0.1))

    def test_dynamic_sample_and_rejection_rate(self) -> None:
        groups = [[1.0, 0.0], [1.0, 1.0], [0.0, 0.0, 1.0]]
        self.assertEqual(dynamic_sample(groups), [[1.0, 0.0], [0.0, 0.0, 1.0]])
        self.assertAlmostEqual(rejection_rate(groups), 1.0 / 3.0)


if __name__ == "__main__":
    unittest.main()
