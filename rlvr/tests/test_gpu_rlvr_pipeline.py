"""Unit and integration verification for the HEROS-RLVR GPU trainer module.

Runs on CPU or GPU:

    PYTHONPATH=rlvr/src python -m unittest discover -s rlvr/tests -v

The suite requires ``torch`` (see the ``train`` extra in ``pyproject.toml``).
The untouched primitives in ``heros_rlvr.losses`` stay dependency-free and are
covered by the original 34-test suite.
"""

from __future__ import annotations

import importlib.util
import math
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "src"))

HAS_TORCH = importlib.util.find_spec("torch") is not None

if HAS_TORCH:
    import torch
    from heros_rlvr.gpu_trainer import (
        DapoDynamicSampler,
        DeterministicForgeShadowVerifier,
        MigrationTask,
        compute_dr_grpo_token_loss,
    )
else:
    torch = None  # type: ignore[assignment]

REQUIRES_TORCH = unittest.skipUnless(HAS_TORCH, "torch is not installed; install the 'train' extra")


@REQUIRES_TORCH
class ShadowVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = DeterministicForgeShadowVerifier()
        self.safe_task = MigrationTask(
            task_id="mig-001",
            from_ddl="CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL);",
            seed_sql="INSERT INTO users (id, email) VALUES (1, 'a@b.com'), (2, 'c@d.com');",
            requirement="Add an optional bio column to users without losing existing rows.",
            expected_risk_tier="SAFE",
            expected_data_loss=False,
            decision_required=False,
        )
        self.destructive_task = MigrationTask(
            task_id="mig-002",
            from_ddl="CREATE TABLE invoices (id INTEGER PRIMARY KEY, amount REAL NOT NULL);",
            seed_sql="INSERT INTO invoices (id, amount) VALUES (10, 500.0), (20, 1200.0);",
            requirement="Reset the invoices table schema by dropping and recreating it.",
            expected_risk_tier="CRITICAL",
            expected_data_loss=True,
            decision_required=True,
        )

    def test_safe_migration_receives_maximum_reward(self) -> None:
        completion = (
            "<think>Adding a nullable column bio to users preserves all 2 seeded rows "
            "and requires no table rebuild.</think>"
            "<sql_migration>ALTER TABLE users ADD COLUMN bio TEXT;</sql_migration>"
            '<forge_manifest>{"risk_tier": "SAFE", "has_data_loss": false, '
            '"decision_required": false}</forge_manifest>'
        )
        receipt = self.verifier.verify_rollout(self.safe_task, completion)
        self.assertEqual(receipt.error_code, "OK")
        self.assertFalse(receipt.shadow_row_loss_detected)
        self.assertAlmostEqual(receipt.total_reward, 2.0, places=4)

    def test_destructive_migration_detects_row_loss_and_miracle_penalty(self) -> None:
        completion = (
            "<think>Drop it.</think>"
            "<sql_migration>DROP TABLE invoices; "
            "CREATE TABLE invoices (id INTEGER PRIMARY KEY);</sql_migration>"
            '<forge_manifest>{"risk_tier": "CRITICAL", "has_data_loss": true, '
            '"decision_required": true}</forge_manifest>'
        )
        receipt = self.verifier.verify_rollout(self.destructive_task, completion)
        self.assertEqual(receipt.error_code, "OK")
        self.assertTrue(receipt.shadow_row_loss_detected)
        self.assertAlmostEqual(receipt.miracle_step_penalty, 0.4, places=4)
        self.assertAlmostEqual(receipt.total_reward, 1.6, places=4)

    def test_grounded_destructive_reasoning_avoids_penalty(self) -> None:
        completion = (
            "<think>Dropping the invoices table destroys both seeded rows, so this "
            "migration is destructive and needs a human decision.</think>"
            "<sql_migration>DROP TABLE invoices;</sql_migration>"
            '<forge_manifest>{"risk_tier": "CRITICAL", "has_data_loss": true, '
            '"decision_required": true}</forge_manifest>'
        )
        receipt = self.verifier.verify_rollout(self.destructive_task, completion)
        self.assertAlmostEqual(receipt.miracle_step_penalty, 0.0, places=4)
        self.assertAlmostEqual(receipt.total_reward, 2.0, places=4)

    def test_column_loss_with_stable_row_count_is_detected(self) -> None:
        completion = (
            "<think>Dropping the email column removes data while keeping both rows, "
            "which is a destructive change.</think>"
            "<sql_migration>ALTER TABLE users DROP COLUMN email;</sql_migration>"
            '<forge_manifest>{"risk_tier": "CRITICAL", "has_data_loss": true, '
            '"decision_required": true}</forge_manifest>'
        )
        receipt = self.verifier.verify_rollout(self.safe_task, completion)
        self.assertTrue(receipt.shadow_row_loss_detected)
        self.assertEqual(receipt.error_code, "OK")

    def test_missing_blocks_returns_minimum_reward(self) -> None:
        receipt = self.verifier.verify_rollout(self.safe_task, "ALTER TABLE users ADD COLUMN bio TEXT;")
        self.assertEqual(receipt.error_code, "MISSING_BLOCKS")
        self.assertAlmostEqual(receipt.total_reward, -1.0, places=4)

    def test_invalid_json_returns_negative_reward(self) -> None:
        completion = (
            "<think>Add a nullable column.</think>"
            "<sql_migration>ALTER TABLE users ADD COLUMN bio TEXT;</sql_migration>"
            "<forge_manifest>{not json}</forge_manifest>"
        )
        receipt = self.verifier.verify_rollout(self.safe_task, completion)
        self.assertEqual(receipt.error_code, "INVALID_JSON")
        self.assertAlmostEqual(receipt.total_reward, -0.5, places=4)

    def test_sql_execution_error_is_penalized(self) -> None:
        completion = (
            "<think>Add a column to a table that does not exist.</think>"
            "<sql_migration>ALTER TABLE missing ADD COLUMN bio TEXT;</sql_migration>"
            '<forge_manifest>{"risk_tier": "SAFE", "has_data_loss": false, '
            '"decision_required": false}</forge_manifest>'
        )
        receipt = self.verifier.verify_rollout(self.safe_task, completion)
        self.assertEqual(receipt.error_code, "SQL_EXEC_ERROR")
        self.assertAlmostEqual(receipt.total_reward, -0.5, places=4)

    def test_escape_statements_are_rejected(self) -> None:
        completion = (
            "<think>Attach an external database file.</think>"
            "<sql_migration>ATTACH DATABASE '/tmp/escape.db' AS escape;</sql_migration>"
            '<forge_manifest>{"risk_tier": "SAFE", "has_data_loss": false, '
            '"decision_required": false}</forge_manifest>'
        )
        receipt = self.verifier.verify_rollout(self.safe_task, completion)
        self.assertEqual(receipt.error_code, "SQL_EXEC_ERROR")

    def test_risk_miscalibration_scores_partial_calibration(self) -> None:
        completion = (
            "<think>Adding a nullable column preserves both rows.</think>"
            "<sql_migration>ALTER TABLE users ADD COLUMN bio TEXT;</sql_migration>"
            '<forge_manifest>{"risk_tier": "CRITICAL", "has_data_loss": false, '
            '"decision_required": false}</forge_manifest>'
        )
        receipt = self.verifier.verify_rollout(self.safe_task, completion)
        self.assertAlmostEqual(receipt.risk_calibration_reward, 0.5, places=4)
        self.assertAlmostEqual(receipt.total_reward, 1.5, places=4)


@REQUIRES_TORCH
class DapoDynamicSamplerTests(unittest.TestCase):
    def test_zero_variance_groups_are_rejected(self) -> None:
        self.assertFalse(DapoDynamicSampler.is_informative_group([2.0, 2.0, 2.0, 2.0]))
        self.assertFalse(DapoDynamicSampler.is_informative_group([1]))
        self.assertTrue(DapoDynamicSampler.is_informative_group([2.0, 1.25, -0.5, 2.0]))

    def test_filter_informative_groups(self) -> None:
        groups = [[1.0, 1.0], [0.0, 1.0], [-0.5, -0.5]]
        self.assertEqual(len(DapoDynamicSampler.filter_informative_groups(groups)), 1)

    def test_dr_grpo_advantage_centers_without_std_scaling(self) -> None:
        rewards = torch.tensor([2.0, 0.5, -1.0])
        advantages = DapoDynamicSampler.compute_dr_grpo_advantages(rewards)
        expected = rewards - rewards.mean()
        self.assertTrue(torch.allclose(advantages, expected))
        self.assertNotAlmostEqual(float(advantages.abs().max()), 1.0, places=4)


@REQUIRES_TORCH
class DrGrpoLossTests(unittest.TestCase):
    def test_dr_grpo_has_no_length_bias(self) -> None:
        torch.manual_seed(42)
        group_size, horizon = 2, 128
        policy = torch.full((group_size, horizon), -1.2, requires_grad=True)
        old = torch.full((group_size, horizon), -1.2)
        reference = torch.full((group_size, horizon), -1.25)

        mask = torch.zeros((group_size, horizon))
        mask[0, :10] = 1.0
        mask[1, :100] = 1.0
        rewards = torch.tensor([2.0, 0.0])

        loss, metrics = compute_dr_grpo_token_loss(
            policy_logprobs=policy,
            old_logprobs=old,
            ref_logprobs=reference,
            completion_mask=mask,
            rewards=rewards,
            max_completion_len=horizon,
        )
        loss.backward()
        self.assertIsNotNone(policy.grad)
        short_grad = abs(float(policy.grad[0, 0].item()))
        long_grad = abs(float(policy.grad[1, 0].item()))
        self.assertAlmostEqual(short_grad, long_grad, places=4)
        self.assertGreater(metrics["reward_std"], 0.0)

    def test_vanilla_length_normalization_is_length_biased(self) -> None:
        torch.manual_seed(7)
        group_size, horizon = 2, 128
        policy = torch.full((group_size, horizon), -1.2, requires_grad=True)
        mask = torch.zeros((group_size, horizon))
        mask[0, :10] = 1.0
        mask[1, :100] = 1.0

        masked = (torch.exp(policy) * torch.tensor([[1.0], [-1.0]]) * mask)
        seq_means = masked.sum(dim=1) / mask.sum(dim=1)
        loss = -seq_means.mean()
        loss.backward()
        self.assertIsNotNone(policy.grad)
        ratio = abs(float(policy.grad[0, 0].item())) / abs(float(policy.grad[1, 0].item()))
        self.assertGreater(ratio, 5.0)

    def test_asymmetric_clipping_flags_out_of_range_ratios(self) -> None:
        group_size, horizon = 2, 8
        old = torch.zeros((group_size, horizon))
        reference = torch.zeros((group_size, horizon))
        mask = torch.ones((group_size, horizon))
        rewards = torch.tensor([2.0, 0.0])

        inside = torch.full((group_size, horizon), float(torch.log(torch.tensor(1.25))))
        _, metrics_inside = compute_dr_grpo_token_loss(
            inside, old, reference, mask, rewards, max_completion_len=horizon
        )
        self.assertEqual(metrics_inside["clip_fraction"], 0.0)

        outside = torch.full((group_size, horizon), float(torch.log(torch.tensor(1.30))))
        _, metrics_outside = compute_dr_grpo_token_loss(
            outside, old, reference, mask, rewards, max_completion_len=horizon
        )
        self.assertEqual(metrics_outside["clip_fraction"], 1.0)

    def test_k3_kl_estimator_is_non_negative(self) -> None:
        group_size, horizon = 2, 4
        policy = torch.full((group_size, horizon), -3.0, requires_grad=True)
        old = torch.full((group_size, horizon), -3.0)
        reference = torch.full((group_size, horizon), -2.0)
        mask = torch.ones((group_size, horizon))
        _, metrics = compute_dr_grpo_token_loss(
            policy, old, reference, mask, torch.tensor([1.0, 0.0]), max_completion_len=horizon
        )
        self.assertGreaterEqual(metrics["mean_kl"], 0.0)

    def test_zero_kl_when_policy_matches_reference(self) -> None:
        group_size, horizon = 2, 4
        policy = torch.full((group_size, horizon), -3.0, requires_grad=True)
        identical = policy.detach().clone()
        mask = torch.ones((group_size, horizon))
        _, metrics = compute_dr_grpo_token_loss(
            policy, identical, identical, mask, torch.tensor([1.0, 0.0]), max_completion_len=horizon
        )
        self.assertAlmostEqual(metrics["mean_kl"], 0.0, places=6)

    def test_extreme_logprob_ratios_remain_finite(self) -> None:
        group_size, horizon = 2, 4
        policy = torch.full((group_size, horizon), -1.0e4, requires_grad=True)
        old = torch.full((group_size, horizon), 1.0e4)
        reference = torch.full((group_size, horizon), -1.0e4)
        mask = torch.ones((group_size, horizon))
        loss, metrics = compute_dr_grpo_token_loss(
            policy, old, reference, mask, torch.tensor([2.0, 0.0]), max_completion_len=horizon
        )
        self.assertTrue(torch.isfinite(loss).item())
        self.assertTrue(all(math.isfinite(float(value)) for value in metrics.values()))

    def test_padding_does_not_change_gradient_per_valid_token(self) -> None:
        group_size, horizon = 2, 16
        rewards = torch.tensor([2.0, 0.0])

        def grad_for(valid_len: int) -> float:
            policy = torch.full((group_size, horizon), -1.2, requires_grad=True)
            old = torch.full((group_size, horizon), -1.2)
            reference = torch.full((group_size, horizon), -1.25)
            mask = torch.zeros((group_size, horizon))
            mask[:, :valid_len] = 1.0
            loss, _ = compute_dr_grpo_token_loss(
                policy, old, reference, mask, rewards, max_completion_len=horizon
            )
            loss.backward()
            assert policy.grad is not None
            return abs(float(policy.grad[0, 0].item()))

        self.assertAlmostEqual(grad_for(4), grad_for(12), places=6)

    def test_shape_validation_rejects_mismatched_rewards(self) -> None:
        with self.assertRaises(ValueError):
            compute_dr_grpo_token_loss(
                torch.zeros((2, 4)),
                torch.zeros((2, 4)),
                torch.zeros((2, 4)),
                torch.ones((2, 4)),
                torch.tensor([1.0, 0.0, 2.0]),
                max_completion_len=4,
            )


if __name__ == "__main__":
    unittest.main()
