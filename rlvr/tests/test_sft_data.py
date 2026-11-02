"""Tests for deterministic SFT migration targets."""

from __future__ import annotations

import unittest

from heros_rlvr.gpu_trainer import DeterministicForgeShadowVerifier, MigrationTask
from heros_rlvr.sft_data import build_sft_examples, target_completion, target_sql_for_task


def task(source: str, target: str, from_ddl: str, seed: str, hazard: str) -> MigrationTask:
    return MigrationTask(
        task_id="sft-test",
        from_ddl=from_ddl,
        seed_sql=seed,
        requirement="reach the target schema",
        expected_risk_tier="CRITICAL",
        expected_data_loss=True,
        decision_required=True,
        source_schema=source,
        target_schema=target,
        hazard=hazard,
    )


class SftTargetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.verifier = DeterministicForgeShadowVerifier()

    def test_drop_column_target_matches(self) -> None:
        item = task(
            "TABLE users\nCOLUMN id bigint NOT_NULL PRIMARY_KEY\nCOLUMN email text NOT_NULL\nCOLUMN legacy_note text NULLABLE",
            "TABLE users\nCOLUMN id bigint NOT_NULL PRIMARY_KEY\nCOLUMN email text NOT_NULL",
            "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL, legacy_note TEXT);",
            "INSERT INTO users (id, email, legacy_note) VALUES (1, 'a@b.com', 'x'), (2, 'c@d.com', 'y');",
            "drop_column",
        )
        sql = target_sql_for_task(item)
        self.assertIn("DROP COLUMN", sql)
        receipt = self.verifier.verify_rollout(item, target_completion(item))
        self.assertTrue(receipt.target_schema_matched)

    def test_add_not_null_default_column_matches(self) -> None:
        item = task(
            "TABLE users\nCOLUMN id bigint NOT_NULL PRIMARY_KEY\nCOLUMN email text NOT_NULL",
            "TABLE users\nCOLUMN id bigint NOT_NULL PRIMARY_KEY\nCOLUMN email text NOT_NULL\nCOLUMN status text NOT_NULL DEFAULT",
            "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL);",
            "INSERT INTO users (id, email) VALUES (1, 'a@b.com'), (2, 'c@d.com');",
            "add_default_column",
        )
        sql = target_sql_for_task(item)
        self.assertIn("DEFAULT", sql)
        receipt = self.verifier.verify_rollout(item, target_completion(item))
        self.assertTrue(receipt.target_schema_matched)

    def test_rename_column_matches(self) -> None:
        item = task(
            "TABLE users\nCOLUMN id bigint NOT_NULL PRIMARY_KEY\nCOLUMN name text NULLABLE",
            "TABLE users\nCOLUMN id bigint NOT_NULL PRIMARY_KEY\nCOLUMN full_name text NULLABLE",
            "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);",
            "INSERT INTO users (id, name) VALUES (1, 'a'), (2, 'b');",
            "rename_column",
        )
        sql = target_sql_for_task(item)
        self.assertIn("RENAME COLUMN", sql)
        receipt = self.verifier.verify_rollout(item, target_completion(item))
        self.assertTrue(receipt.target_schema_matched)

    def test_not_null_rebuild_matches(self) -> None:
        item = task(
            "TABLE users\nCOLUMN id bigint NOT_NULL PRIMARY_KEY\nCOLUMN note text NULLABLE",
            "TABLE users\nCOLUMN id bigint NOT_NULL PRIMARY_KEY\nCOLUMN note text NOT_NULL",
            "CREATE TABLE users (id INTEGER PRIMARY KEY, note TEXT);",
            "INSERT INTO users (id, note) VALUES (1, 'a'), (2, 'b');",
            "set_not_null",
        )
        sql = target_sql_for_task(item)
        self.assertIn("CREATE TABLE", sql)
        self.assertIn("INSERT INTO", sql)
        receipt = self.verifier.verify_rollout(item, target_completion(item))
        self.assertTrue(receipt.target_schema_matched)

    def test_unrepresentable_type_change_returns_empty(self) -> None:
        item = task(
            "TABLE users\nCOLUMN id bigint NOT_NULL",
            "TABLE users\nCOLUMN id int NOT_NULL",
            "CREATE TABLE users (id INTEGER NOT NULL);",
            "INSERT INTO users (id) VALUES (1);",
            "type_narrowing",
        )
        self.assertEqual(target_sql_for_task(item), "")

    def test_build_sft_examples_skips_unrepresentable_tasks(self) -> None:
        good = task(
            "TABLE users\nCOLUMN id bigint NOT_NULL",
            "TABLE users\nCOLUMN id bigint NOT_NULL\nCOLUMN email text NULLABLE",
            "CREATE TABLE users (id INTEGER NOT NULL);",
            "INSERT INTO users (id) VALUES (1);",
            "add_nullable_column",
        )
        bad = task(
            "TABLE users\nCOLUMN id bigint NOT_NULL",
            "TABLE users\nCOLUMN id int NOT_NULL",
            "CREATE TABLE users (id INTEGER NOT NULL);",
            "INSERT INTO users (id) VALUES (1);",
            "type_narrowing",
        )
        examples = build_sft_examples([good, bad])
        self.assertEqual(len(examples), 1)
        self.assertEqual(examples[0].task_id, "sft-test")
        self.assertIn("<think>", examples[0].completion)
        self.assertIn("<forge_manifest>", examples[0].completion)

    def test_completion_has_required_tags(self) -> None:
        item = task(
            "TABLE users\nCOLUMN id bigint NOT_NULL",
            "TABLE users\nCOLUMN id bigint NOT_NULL\nCOLUMN email text NULLABLE",
            "CREATE TABLE users (id INTEGER NOT NULL);",
            "INSERT INTO users (id) VALUES (1);",
            "add_nullable_column",
        )
        completion = target_completion(item)
        self.assertIn("<think>", completion)
        self.assertIn("<sql_migration>", completion)
        self.assertIn("<forge_manifest>", completion)


if __name__ == "__main__":
    unittest.main()
