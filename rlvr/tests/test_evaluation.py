"""Tests for held-out evaluation aggregation."""

from __future__ import annotations

import unittest

from heros_rlvr.evaluation import EvalItem, select_eval_tasks, summarize_evaluations


class EvaluationSummaryTests(unittest.TestCase):
    def test_mixed_items_are_aggregated(self) -> None:
        items = [
            EvalItem("a", "drop_column", "CRITICAL", 1.5, 0.5, False, "OK"),
            EvalItem("b", "drop_column", "CRITICAL", -1.0, 0.0, False, "MISSING_BLOCKS"),
            EvalItem("c", "create_table", "SAFE", 2.0, 0.5, False, "OK"),
            EvalItem("d", "drop_table", "CRITICAL", 0.5, 0.0, True, "OK"),
        ]
        summary = summarize_evaluations(items, elapsed_sec=12.345, vram_mb=4100.55)
        self.assertEqual(summary["tasks"], 4)
        self.assertEqual(summary["mean_reward"], 0.75)
        self.assertEqual(summary["ok_rate"], 0.75)
        self.assertEqual(summary["risk_accuracy"], 0.5)
        self.assertEqual(summary["row_loss_rate"], 0.25)
        self.assertEqual(summary["error_codes"], {"MISSING_BLOCKS": 1, "OK": 3})
        self.assertEqual(summary["elapsed_sec"], 12.35)
        self.assertEqual(summary["vram_mb"], 4100.6)

    def test_mapping_input_round_trip(self) -> None:
        item = EvalItem("x", "widen_type", "SAFE", 2.0, 0.5, False, "OK")
        summary = summarize_evaluations([item.to_dict()])
        self.assertEqual(summary["tasks"], 1)
        self.assertEqual(summary["mean_reward"], 2.0)

    def test_empty_summary_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            summarize_evaluations([])

    def test_select_eval_tasks_is_deterministic(self) -> None:
        tasks = list(range(500))
        selected = select_eval_tasks(tasks, 450, 50)
        self.assertEqual(selected, list(range(450, 500)))

    def test_select_eval_tasks_rejects_out_of_range(self) -> None:
        with self.assertRaises(ValueError):
            select_eval_tasks(list(range(10)), 5, 10)

    def test_select_eval_tasks_rejects_invalid_start(self) -> None:
        with self.assertRaises(ValueError):
            select_eval_tasks(list(range(10)), -1, 5)


if __name__ == "__main__":
    unittest.main()
