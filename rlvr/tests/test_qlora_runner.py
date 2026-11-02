"""Tests for the QLoRA rollout runner and the dataset/schema bridge.

The runner tests use a fake policy and a real SQLite verifier, so they exercise
the orchestration without transformers, a GPU, or a model download. The
Hugging Face adapter is intentionally not covered here; it is exercised only by
a real run.
"""

from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from heros_rlvr.gpu_trainer import TORCH_AVAILABLE
from heros_rlvr.qlora_runner import (
    HFPolicy,
    QLoRARunner,
    RunRecorder,
    RunnerConfig,
    StepResult,
    build_prompt,
    build_rollout_batch,
    build_seed_sql,
    build_sqlite_ddl,
    dataset_row_to_task,
    load_dataset,
    parse_forge_schema,
)

if TORCH_AVAILABLE:  # pragma: no branch
    import torch


OLD_SCHEMA = """TABLE users
COLUMN id bigint NOT_NULL
COLUMN email text NOT_NULL
COLUMN created_at timestamp NOT_NULL
COLUMN legacy_note text NULLABLE"""

TARGET_SCHEMA = """TABLE users
COLUMN id bigint NOT_NULL
COLUMN email text NOT_NULL
COLUMN created_at timestamp NOT_NULL"""

ROW = {
    "id": "test-0001",
    "old_schema": OLD_SCHEMA,
    "target_schema": TARGET_SCHEMA,
    "hazard": "drop_column",
    "expected_tier": "CRITICAL",
    "data_loss": True,
    "requires_expand_contract": True,
}

SAFE_COMPLETION = (
    "<think>Add a nullable column; the seeded row is preserved.</think>"
    "<sql_migration>ALTER TABLE users ADD COLUMN bio TEXT;</sql_migration>"
    '<forge_manifest>{"risk_tier": "SAFE", "has_data_loss": false, '
    '"decision_required": false}</forge_manifest>'
)
MISSING_COMPLETION = "<think>incomplete</think>"


class RunnerConfigTests(unittest.TestCase):
    def test_defaults_are_valid(self) -> None:
        config = RunnerConfig()
        self.assertGreaterEqual(config.group_size, 2)
        self.assertIn("model_name", config.to_dict())

    def test_rejects_invalid_group_size(self) -> None:
        with self.assertRaises(ValueError):
            RunnerConfig(group_size=1)

    def test_rejects_invalid_clip_bounds(self) -> None:
        with self.assertRaises(ValueError):
            RunnerConfig(clip_eps_low=0.3, clip_eps_high=0.2)

    def test_rejects_invalid_top_p(self) -> None:
        with self.assertRaises(ValueError):
            RunnerConfig(top_p=0.0)


class SchemaBridgeTests(unittest.TestCase):
    def test_parse_schema_and_execute_seed(self) -> None:
        tables = parse_forge_schema(OLD_SCHEMA)
        self.assertEqual(len(tables), 1)
        self.assertEqual(tables[0].name, "users")
        self.assertEqual(tables[0].columns[0].sqlite_type, "INTEGER")
        self.assertTrue(tables[0].columns[1].not_null)
        self.assertFalse(tables[0].columns[3].not_null)

        ddl = build_sqlite_ddl(tables)
        seed = build_seed_sql(tables)
        connection = sqlite3.connect(":memory:")
        try:
            connection.executescript(ddl)
            connection.executescript(seed)
            count = connection.execute("SELECT COUNT(*) FROM users;").fetchone()[0]
            self.assertEqual(count, 2)
            created = connection.execute(
                "SELECT created_at FROM users ORDER BY id LIMIT 1;"
            ).fetchone()[0]
            self.assertEqual(created, "2026-01-01 00:00:00")
        finally:
            connection.close()

    def test_multiple_tables(self) -> None:
        text = "TABLE a\nCOLUMN id bigint NOT_NULL\n\nTABLE b\nCOLUMN id bigint NOT_NULL"
        tables = parse_forge_schema(text)
        self.assertEqual([table.name for table in tables], ["a", "b"])
        ddl = build_sqlite_ddl(tables)
        self.assertIn('CREATE TABLE "a"', ddl)
        self.assertIn('CREATE TABLE "b"', ddl)

    def test_unknown_type_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            parse_forge_schema("TABLE t\nCOLUMN x geography NULLABLE")

    def test_column_before_table_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            parse_forge_schema("COLUMN x text NULLABLE")

    def test_duplicate_table_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            parse_forge_schema(
                "TABLE t\nCOLUMN x text NULLABLE\nTABLE t\nCOLUMN y text NULLABLE"
            )

    def test_dataset_row_mapping(self) -> None:
        task = dataset_row_to_task(ROW)
        self.assertEqual(task.task_id, "test-0001")
        self.assertEqual(task.expected_risk_tier, "CRITICAL")
        self.assertTrue(task.expected_data_loss)
        self.assertTrue(task.decision_required)
        self.assertEqual(task.hazard, "drop_column")
        self.assertIn("CREATE TABLE", task.from_ddl)
        self.assertIn("INSERT INTO", task.seed_sql)

    def test_dataset_row_rejects_non_boolean(self) -> None:
        broken = dict(ROW)
        broken["data_loss"] = "sometimes"
        with self.assertRaises(ValueError):
            dataset_row_to_task(broken)

    def test_all_forge_tiers_are_accepted(self) -> None:
        for tier in ("SAFE", "NOTABLE", "MEDIUM", "HIGH", "CRITICAL"):
            row = dict(ROW, expected_tier=tier)
            self.assertEqual(dataset_row_to_task(row).expected_risk_tier, tier)

    def test_dataset_row_requires_expected_tier(self) -> None:
        broken = dict(ROW)
        broken.pop("expected_tier")
        with self.assertRaises(ValueError):
            dataset_row_to_task(broken)

    def test_unknown_tier_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            dataset_row_to_task(dict(ROW, expected_tier="EXTREME"))

    def test_prompt_excludes_expected_labels(self) -> None:
        prompt = build_prompt(dataset_row_to_task(ROW))
        self.assertIn("drop_column", prompt)
        self.assertIn("TARGET SCHEMA", prompt)
        self.assertIn("<sql_migration>", prompt)
        self.assertIn("<forge_manifest>", prompt)
        self.assertNotIn("Data-loss change", prompt)
        self.assertNotIn("expected_tier", prompt)

    def test_load_dataset_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rows.jsonl"
            path.write_text(json.dumps(ROW) + "\n", encoding="utf-8")
            rows = load_dataset(path)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["id"], "test-0001")

    def test_load_dataset_rejects_empty(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "empty.jsonl"
            path.write_text("\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                load_dataset(path)


class RolloutBatchTests(unittest.TestCase):
    def test_batch_scores_mixed_completions(self) -> None:
        task = dataset_row_to_task(ROW)
        prompt = build_prompt(task)
        from heros_rlvr.gpu_trainer import DeterministicForgeShadowVerifier

        batch = build_rollout_batch(
            task,
            prompt,
            [SAFE_COMPLETION, MISSING_COMPLETION, SAFE_COMPLETION, MISSING_COMPLETION],
            DeterministicForgeShadowVerifier(),
        )
        self.assertEqual(len(batch.receipts), 4)
        self.assertEqual(batch.rewards[0], 1.0)
        self.assertEqual(batch.rewards[1], -1.0)
        self.assertTrue(batch.informative)

    def test_uniform_group_is_not_informative(self) -> None:
        task = dataset_row_to_task(ROW)
        from heros_rlvr.gpu_trainer import DeterministicForgeShadowVerifier

        batch = build_rollout_batch(
            task,
            build_prompt(task),
            [SAFE_COMPLETION, SAFE_COMPLETION],
            DeterministicForgeShadowVerifier(),
        )
        self.assertFalse(batch.informative)


class RunRecorderTests(unittest.TestCase):
    def test_recorder_writes_and_truncates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            recorder = RunRecorder(directory)
            recorder.append_step(
                StepResult(step=99, task_id="stale", mean_reward=0.0, reward_std=0.0)
            )
            recorder.start(RunnerConfig(output_dir=directory))
            recorder.append_step(
                StepResult(step=1, task_id="t1", mean_reward=1.0, reward_std=0.5)
            )
            recorder.finish(
                [StepResult(step=1, task_id="t1", mean_reward=1.0, reward_std=0.5)]
            )

            run = json.loads((Path(directory) / "run.json").read_text(encoding="utf-8"))
            self.assertIn("config", run)
            self.assertIn("environment", run)
            lines = (Path(directory) / "steps.jsonl").read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(lines), 1)
            summary = json.loads(
                (Path(directory) / "summary.json").read_text(encoding="utf-8")
            )
            self.assertEqual(summary["steps"], 1)
            self.assertEqual(summary["completed_steps"], 1)



class FakePolicy:
    """A tiny differentiable policy for orchestration tests."""

    def __init__(self, completions: list[str], value: float = -1.0):
        self.completions = list(completions)
        self.parameter = torch.nn.Parameter(torch.tensor(value, dtype=torch.float32))
        self.generate_calls = 0
        self.logprob_calls = 0
        self.saved: list[str] = []

    def generate(self, prompts, *, max_new_tokens, temperature, top_p):
        self.generate_calls += 1
        return list(self.completions)

    def token_logprobs(self, prompts, completions):
        self.logprob_calls += 1
        group_size = len(completions)
        length = 4
        values = self.parameter * torch.ones((group_size, length), dtype=torch.float32)
        mask = torch.zeros((group_size, length), dtype=torch.float32)
        for index in range(group_size):
            # Different valid lengths make the advantages non-cancelling, so
            # the optimizer step is observable.
            visible = 1 if index % 2 == 0 else length
            mask[index, :visible] = 1.0
        return values, mask

    def save(self, output_dir: str) -> None:
        self.saved.append(output_dir)

@unittest.skipUnless(TORCH_AVAILABLE, "PyTorch is not installed")
class RunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.config = RunnerConfig(
            output_dir="unused",
            group_size=2,
            max_completion_tokens=4,
            gradient_accumulation=1,
            checkpoint_every=0,
            save_final=False,
            max_steps=1,
        )
        self.task = dataset_row_to_task(ROW)

    def _runner(self, completions, config=None):
        config = config or self.config
        policy = FakePolicy(completions)
        reference = FakePolicy(completions)
        optimizer = torch.optim.SGD([policy.parameter], lr=0.1)
        return (
            QLoRARunner(config, policy, reference, optimizer, recorder=_NullRecorder()),
            policy,
            optimizer,
        )

    def test_train_step_updates_parameter(self) -> None:
        runner, policy, _ = self._runner([SAFE_COMPLETION, MISSING_COMPLETION])
        before = float(policy.parameter.detach())
        result = runner.train_step(self.task, 1)
        after = float(policy.parameter.detach())
        self.assertFalse(result.skipped)
        self.assertIsNotNone(result.loss)
        self.assertTrue(result.loss == result.loss)  # finite
        self.assertNotEqual(before, after)

    def test_zero_variance_group_skips_optimizer(self) -> None:
        runner, policy, _ = self._runner([SAFE_COMPLETION, SAFE_COMPLETION])
        before = float(policy.parameter.detach())
        result = runner.train_step(self.task, 1)
        after = float(policy.parameter.detach())
        self.assertTrue(result.skipped)
        self.assertEqual(result.skip_reason, "zero_variance_group")
        self.assertEqual(before, after)
        self.assertEqual(policy.logprob_calls, 0)

    def test_gradient_accumulation_defers_step(self) -> None:
        config = RunnerConfig(
            output_dir="unused",
            group_size=2,
            max_completion_tokens=4,
            gradient_accumulation=2,
            checkpoint_every=0,
            save_final=False,
            max_steps=2,
        )
        runner, policy, _ = self._runner(
            [SAFE_COMPLETION, MISSING_COMPLETION], config=config
        )
        before = float(policy.parameter.detach())
        runner.train_step(self.task, 1)
        self.assertEqual(float(policy.parameter.detach()), before)
        runner.train_step(self.task, 2)
        self.assertNotEqual(float(policy.parameter.detach()), before)

    def test_gradient_accumulation_scales_loss(self) -> None:
        accumulated = RunnerConfig(
            output_dir="unused",
            group_size=2,
            max_completion_tokens=4,
            gradient_accumulation=2,
            checkpoint_every=0,
            save_final=False,
            max_steps=2,
        )
        single = RunnerConfig(
            output_dir="unused",
            group_size=2,
            max_completion_tokens=4,
            gradient_accumulation=1,
            checkpoint_every=0,
            save_final=False,
            max_steps=1,
        )
        runner_a, policy_a, _ = self._runner(
            [SAFE_COMPLETION, MISSING_COMPLETION], config=accumulated
        )
        runner_b, policy_b, _ = self._runner(
            [SAFE_COMPLETION, MISSING_COMPLETION], config=single
        )
        runner_a.train_step(self.task, 1)
        runner_a.train_step(self.task, 2)
        runner_b.train_step(self.task, 1)
        self.assertAlmostEqual(
            float(policy_a.parameter.detach()),
            float(policy_b.parameter.detach()),
            places=6,
        )

    def test_run_writes_artifacts_and_checkpoints(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = RunnerConfig(
                output_dir=directory,
                group_size=2,
                max_completion_tokens=4,
                gradient_accumulation=1,
                checkpoint_every=1,
                save_final=True,
                max_steps=2,
            )
            policy = FakePolicy([SAFE_COMPLETION, MISSING_COMPLETION])
            reference = FakePolicy([SAFE_COMPLETION, MISSING_COMPLETION])
            optimizer = torch.optim.SGD([policy.parameter], lr=0.1)
            runner = QLoRARunner(config, policy, reference, optimizer)
            results = runner.run([self.task, self.task], max_steps=2)
            self.assertEqual(len(results), 2)
            self.assertTrue((Path(directory) / "run.json").exists())
            self.assertTrue((Path(directory) / "summary.json").exists())
            self.assertEqual(
                len((Path(directory) / "steps.jsonl").read_text().splitlines()), 2
            )
            self.assertTrue(any("checkpoint-1" in path for path in policy.saved))
            self.assertTrue(any("final" in path for path in policy.saved))

    def test_run_rejects_empty_tasks(self) -> None:
        runner, _, _ = self._runner([SAFE_COMPLETION, MISSING_COMPLETION])
        with self.assertRaises(ValueError):
            runner.run([], max_steps=1)


class _NullRecorder(RunRecorder):
    """Recorder that writes nothing, for direct train_step tests."""

    def __init__(self) -> None:  # noqa: D401 - test helper
        pass

    def start(self, config, extra=None) -> None:
        pass

    def append_step(self, result) -> None:
        pass

    def record_checkpoint(self, step, path) -> None:
        pass

    def finish(self, results) -> None:
        pass


class HFPolicySurfaceTests(unittest.TestCase):
    def test_class_is_importable_without_transformers(self) -> None:
        self.assertTrue(callable(HFPolicy.load))


if __name__ == "__main__":
    unittest.main()
