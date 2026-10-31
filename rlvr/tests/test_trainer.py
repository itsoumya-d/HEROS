from __future__ import annotations

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "src"))

from heros_rlvr import Completion, VerificationResult, build_rollout  # noqa: E402

CORRECT = "<think>x</think><answer>1</answer>"
INCORRECT = "<think>x</think><answer>0</answer>"


def score(text: str) -> VerificationResult:
    correct = "<answer>1</answer>" in text
    return VerificationResult(correct=correct, reward=1.0 if correct else 0.0, format_ok=True)


class TrainerTests(unittest.TestCase):
    def test_mixed_group_keeps_signal_and_advantages_sum_to_zero(self) -> None:
        calls = 0

        def policy(_prompt: str) -> Completion:
            nonlocal calls
            calls += 1
            text = CORRECT if calls == 1 else INCORRECT
            return Completion(text=text, token_logps=(0.0,))

        rollout = build_rollout("prompt", policy, score, group_size=4)
        self.assertTrue(rollout.kept)
        self.assertEqual(rollout.rewards, (1.0, 0.0, 0.0, 0.0))
        self.assertAlmostEqual(sum(rollout.advantages), 0.0)
        self.assertAlmostEqual(rollout.advantages[0], 0.75)

    def test_uniform_group_is_rejected(self) -> None:
        def policy(_prompt: str) -> Completion:
            return Completion(text=INCORRECT, token_logps=(0.0,))

        rollout = build_rollout("prompt", policy, score, group_size=3)
        self.assertFalse(rollout.kept)
        self.assertEqual(rollout.advantages, (0.0, 0.0, 0.0))

    def test_group_size_must_be_at_least_two(self) -> None:
        with self.assertRaises(ValueError):
            build_rollout(
                "prompt",
                lambda _p: Completion(CORRECT, (0.0,)),
                score,
                group_size=1,
            )

    def test_empty_logprob_sequence_rejects(self) -> None:
        with self.assertRaises(ValueError):
            build_rollout(
                "prompt",
                lambda _p: Completion(CORRECT, ()),
                score,
                group_size=2,
            )


if __name__ == "__main__":
    unittest.main()
