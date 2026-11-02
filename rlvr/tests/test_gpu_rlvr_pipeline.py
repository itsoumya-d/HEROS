"""Verification suite for the HEROS-RLVR shadow verifier and GPU loss engine.

Run with::

    PYTHONPATH=rlvr/src python -m unittest discover -s rlvr/tests -v

The shadow-verifier tests are dependency-free. The Dr.GRPO/DAPO tests are
skipped when PyTorch is absent so the default RLVR CI job stays lightweight.
"""

from __future__ import annotations

import unittest

from heros_rlvr import dr_grpo_advantages, dr_grpo_config, grpo_loss
from heros_rlvr.gpu_trainer import (
    TORCH_AVAILABLE,
    DapoDynamicSampler,
    DeterministicForgeShadowVerifier,
    MigrationTask,
    compute_dr_grpo_token_loss,
)

if TORCH_AVAILABLE:  # pragma: no branch
    import torch


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

    def test_destructive_migration_detects_shadow_row_loss_and_miracle_penalty(self) -> None:
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

    def test_missing_blocks_fails_closed(self) -> None:
        receipt = self.verifier.verify_rollout(self.safe_task, "<think>only a trace</think>")
        self.assertEqual(receipt.error_code, "MISSING_BLOCKS")
        self.assertAlmostEqual(receipt.total_reward, -1.0, places=4)

    def test_invalid_json_manifest_is_rejected_before_execution(self) -> None:
        completion = (
            "<think>Add a nullable column without touching existing rows.</think>"
            "<sql_migration>ALTER TABLE users ADD COLUMN bio TEXT;</sql_migration>"
            "<forge_manifest>{not-json}</forge_manifest>"
        )
        receipt = self.verifier.verify_rollout(self.safe_task, completion)
        self.assertEqual(receipt.error_code, "INVALID_JSON")
        self.assertAlmostEqual(receipt.total_reward, -0.5, places=4)

    def test_non_object_manifest_is_rejected(self) -> None:
        completion = (
            "<think>Add a nullable column without touching existing rows.</think>"
            "<sql_migration>ALTER TABLE users ADD COLUMN bio TEXT;</sql_migration>"
            "<forge_manifest>[1, 2, 3]</forge_manifest>"
        )
        receipt = self.verifier.verify_rollout(self.safe_task, completion)
        self.assertEqual(receipt.error_code, "INVALID_JSON")

    def test_broken_sql_is_rejected(self) -> None:
        completion = (
            "<think>Attempt an invalid statement to test the shadow gate.</think>"
            "<sql_migration>ALTER TABLE users ADD COLUMN;</sql_migration>"
            '<forge_manifest>{"risk_tier": "SAFE", "has_data_loss": false, '
            '"decision_required": false}</forge_manifest>'
        )
        receipt = self.verifier.verify_rollout(self.safe_task, completion)
        self.assertEqual(receipt.error_code, "SQL_EXEC_ERROR")
        self.assertAlmostEqual(receipt.total_reward, -0.5, places=4)

    def test_attach_database_is_denied_by_authorizer(self) -> None:
        completion = (
            "<think>Try to escape the in-memory shadow database via ATTACH.</think>"
            "<sql_migration>ATTACH DATABASE 'escape.db' AS escape;</sql_migration>"
            '<forge_manifest>{"risk_tier": "SAFE", "has_data_loss": false, '
            '"decision_required": false}</forge_manifest>'
        )
        receipt = self.verifier.verify_rollout(self.safe_task, completion)
        self.assertEqual(receipt.error_code, "SQL_EXEC_ERROR")

    def test_row_loss_detected_even_when_manifest_understates_it(self) -> None:
        completion = (
            "<think>Deleting all invoices is destructive and loses two rows.</think>"
            "<sql_migration>DELETE FROM invoices;</sql_migration>"
            '<forge_manifest>{"risk_tier": "CRITICAL", "has_data_loss": true, '
            '"decision_required": true}</forge_manifest>'
        )
        receipt = self.verifier.verify_rollout(self.destructive_task, completion)
        self.assertEqual(receipt.error_code, "OK")
        self.assertTrue(receipt.shadow_row_loss_detected)
        self.assertAlmostEqual(receipt.total_reward, 2.0, places=4)


class DapoDynamicSamplerTests(unittest.TestCase):
    def test_zero_variance_group_is_not_informative(self) -> None:
        self.assertFalse(DapoDynamicSampler.is_informative_group([2.0, 2.0, 2.0, 2.0]))
        self.assertFalse(DapoDynamicSampler.is_informative_group([0.0, 0.0]))
        self.assertFalse(DapoDynamicSampler.is_informative_group([1.0]))

    def test_mixed_group_is_informative(self) -> None:
        self.assertTrue(DapoDynamicSampler.is_informative_group([2.0, 1.25, -0.5, 2.0]))

    @unittest.skipUnless(TORCH_AVAILABLE, "PyTorch is not installed")
    def test_dr_grpo_advantages_are_zero_mean(self) -> None:
        rewards = torch.tensor([2.0, -1.0, 0.5, 0.5])
        advantages = DapoDynamicSampler.compute_dr_grpo_advantages(rewards)
        self.assertAlmostEqual(float(advantages.mean().item()), 0.0, places=6)
        self.assertAlmostEqual(float(advantages[0].item()), 1.5, places=6)

    @unittest.skipUnless(TORCH_AVAILABLE, "PyTorch is not installed")
    def test_torch_advantages_match_python_reference(self) -> None:
        rewards = [2.0, -1.0, 0.5, 0.5]
        expected = dr_grpo_advantages(rewards)
        actual = DapoDynamicSampler.compute_dr_grpo_advantages(torch.tensor(rewards))
        for got, want in zip(actual.tolist(), expected):
            self.assertAlmostEqual(got, want, places=6)


@unittest.skipUnless(TORCH_AVAILABLE, "PyTorch is not installed")
class DrGrpoLossTests(unittest.TestCase):
    def test_dr_grpo_eliminates_length_bias_on_negative_advantages(self) -> None:
        torch.manual_seed(42)
        group_size, t_max = 2, 128
        policy_lp = torch.full((group_size, t_max), -1.2, requires_grad=True, dtype=torch.float64)
        old_lp = torch.full((group_size, t_max), -1.2, dtype=torch.float64)
        ref_lp = torch.full((group_size, t_max), -1.25, dtype=torch.float64)

        mask = torch.zeros((group_size, t_max), dtype=torch.float64)
        mask[0, :10] = 1.0
        mask[1, :100] = 1.0
        rewards = torch.tensor([2.0, -1.0])

        # Isolate the policy-gradient term: the KL gradient is advantage-
        # independent and would otherwise mask the length-normalization check.
        loss, metrics = compute_dr_grpo_token_loss(
            policy_logprobs=policy_lp,
            old_logprobs=old_lp,
            ref_logprobs=ref_lp,
            completion_mask=mask,
            rewards=rewards,
            kl_beta=0.0,
            max_completion_len=t_max,
        )
        loss.backward()

        self.assertIsNotNone(policy_lp.grad)
        grad_token_short = abs(float(policy_lp.grad[0, 0].item()))
        grad_token_long = abs(float(policy_lp.grad[1, 0].item()))
        self.assertAlmostEqual(grad_token_short, grad_token_long, places=6)
        self.assertGreater(metrics["reward_std"], 0.0)
        self.assertEqual(metrics["valid_tokens"], 110.0)

    def test_constant_horizon_makes_loss_scale_inversely_with_lmax(self) -> None:
        group_size, t_max = 2, 64
        policy_lp = torch.full((group_size, t_max), -1.2)
        old_lp = torch.full((group_size, t_max), -1.2)
        ref_lp = torch.full((group_size, t_max), -1.25)
        mask = torch.ones((group_size, t_max))
        rewards = torch.tensor([2.0, -1.0])

        loss_128, _ = compute_dr_grpo_token_loss(
            policy_lp, old_lp, ref_lp, mask, rewards, max_completion_len=128
        )
        loss_256, _ = compute_dr_grpo_token_loss(
            policy_lp, old_lp, ref_lp, mask, rewards, max_completion_len=256
        )
        self.assertAlmostEqual(float(loss_128.item()) / float(loss_256.item()), 2.0, places=4)

    def test_tensor_loss_matches_python_reference_at_full_mask(self) -> None:
        rewards = [2.0, -1.0]
        seq_len = 8
        policy_lp = torch.full((2, seq_len), -1.2)
        old_lp = torch.full((2, seq_len), -1.2)
        ref_lp = torch.full((2, seq_len), -1.25)
        mask = torch.ones((2, seq_len))

        torch_loss, _ = compute_dr_grpo_token_loss(
            policy_lp,
            old_lp,
            ref_lp,
            mask,
            torch.tensor(rewards),
            kl_beta=0.0,
            max_completion_len=seq_len,
        )
        python_result = grpo_loss(
            policy_lp.tolist(),
            old_lp.tolist(),
            dr_grpo_advantages(rewards),
            reference_logps=ref_lp.tolist(),
            config=dr_grpo_config(kl_coef=0.0),
        )
        # The pure-Python "none" reduction divides by G; the tensor loss uses
        # the Dr.GRPO constant horizon G * L_max.
        self.assertAlmostEqual(
            float(torch_loss.item()) * seq_len, python_result.loss, places=5
        )

    def test_shape_mismatch_raises(self) -> None:
        policy_lp = torch.zeros((2, 8))
        old_lp = torch.zeros((2, 8))
        ref_lp = torch.zeros((2, 8))
        mask = torch.ones((2, 8))
        with self.assertRaises(ValueError):
            compute_dr_grpo_token_loss(
                policy_lp, old_lp, ref_lp, mask, torch.tensor([1.0, 0.0, 1.0])
            )

    def test_invalid_horizon_raises(self) -> None:
        policy_lp = torch.zeros((2, 8))
        with self.assertRaises(ValueError):
            compute_dr_grpo_token_loss(
                policy_lp,
                policy_lp,
                policy_lp,
                torch.ones((2, 8)),
                torch.tensor([1.0, 0.0]),
                max_completion_len=0,
            )


if __name__ == "__main__":
    unittest.main()
