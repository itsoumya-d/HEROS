from __future__ import annotations

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "src"))

from heros_rlvr import (  # noqa: E402
    AuditRecord,
    CommandVerifier,
    Step,
    compose_reward,
    detect_miracle_step,
    has_think_answer_format,
    verifier_error_rates,
)

GOOD_TEXT = "<think>check the schema</think><answer>SAFE</answer>"


class FormatTests(unittest.TestCase):
    def test_complete_format(self) -> None:
        self.assertTrue(has_think_answer_format(GOOD_TEXT))

    def test_missing_think_block(self) -> None:
        self.assertFalse(has_think_answer_format("<answer>SAFE</answer>"))

    def test_empty_answer(self) -> None:
        self.assertFalse(has_think_answer_format("<think>x</think><answer>   </answer>"))

    def test_reward_composition(self) -> None:
        self.assertEqual(compose_reward(True, True, 0.1), 1.1)
        self.assertEqual(compose_reward(False, True, 0.1), 0.1)
        self.assertEqual(compose_reward(True, False, 0.1), 1.0)


class CommandVerifierTests(unittest.TestCase):
    def _verifier(self, expression: str, timeout: float = 2.0) -> CommandVerifier:
        return CommandVerifier([sys.executable, "-c", expression], timeout_seconds=timeout)

    def test_true_payload(self) -> None:
        verifier = self._verifier(
            "import sys,json; text=sys.stdin.read(); "
            "print(json.dumps({'ok': '<answer>SAFE</answer>' in text}))"
        )
        result = verifier.verify(GOOD_TEXT)
        self.assertTrue(result.correct)
        self.assertTrue(result.format_ok)
        self.assertEqual(result.reward, 1.1)

    def test_false_payload(self) -> None:
        verifier = self._verifier(
            "import sys,json; text=sys.stdin.read(); "
            "print(json.dumps({'ok': '<answer>SAFE</answer>' in text}))"
        )
        result = verifier.verify("<think>x</think><answer>UNSAFE</answer>")
        self.assertFalse(result.correct)
        self.assertEqual(result.reward, 0.1)

    def test_missing_format_short_circuits(self) -> None:
        verifier = self._verifier("raise SystemExit(9)")
        result = verifier.verify("plain answer")
        self.assertFalse(result.correct)
        self.assertFalse(result.format_ok)
        self.assertEqual(result.detail["error"], "missing_think_answer_format")

    def test_nonzero_exit(self) -> None:
        verifier = self._verifier("import sys; sys.exit(3)")
        result = verifier.verify(GOOD_TEXT)
        self.assertFalse(result.correct)
        self.assertEqual(result.detail["error"], "verifier_exit_nonzero")

    def test_timeout(self) -> None:
        verifier = self._verifier("import time; time.sleep(0.2)", timeout=0.05)
        result = verifier.verify(GOOD_TEXT)
        self.assertFalse(result.correct)
        self.assertEqual(result.detail["error"], "verifier_timeout")

    def test_no_json(self) -> None:
        verifier = self._verifier("print('not json')")
        result = verifier.verify(GOOD_TEXT)
        self.assertFalse(result.correct)
        self.assertEqual(result.detail["error"], "verifier produced no JSON object")

    def test_missing_boolean_ok(self) -> None:
        verifier = self._verifier("import json; print(json.dumps({'ok': 1}))")
        result = verifier.verify(GOOD_TEXT)
        self.assertFalse(result.correct)
        self.assertEqual(result.detail["error"], "verifier_missing_boolean_ok")


class AuditTests(unittest.TestCase):
    def test_miracle_step_is_flagged(self) -> None:
        result = detect_miracle_step([Step(0, True), Step(1, False), Step(2, True)], True)
        self.assertTrue(result.flagged)
        self.assertEqual(result.invalid_indices, (1,))

    def test_correct_chain_is_not_flagged(self) -> None:
        result = detect_miracle_step([Step(0, True), Step(1, True)], True)
        self.assertFalse(result.flagged)

    def test_incorrect_final_answer_is_not_a_miracle(self) -> None:
        result = detect_miracle_step([Step(0, False)], False)
        self.assertFalse(result.flagged)

    def test_verifier_error_rates(self) -> None:
        rates = verifier_error_rates(
            [
                AuditRecord(True, True),
                AuditRecord(True, False),
                AuditRecord(False, True),
                AuditRecord(False, False),
            ]
        )
        self.assertEqual(rates["false_positive_rate"], 0.5)
        self.assertEqual(rates["false_negative_rate"], 0.5)
        self.assertEqual(rates["accuracy"], 0.5)


if __name__ == "__main__":
    unittest.main()
