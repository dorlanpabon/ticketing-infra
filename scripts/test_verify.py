"""Regression tests for commit enumeration, exact snapshots and policy boundaries."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("verify", Path(__file__).with_name("verify.py"))
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class AuditTests(unittest.TestCase):
    def setUp(self):
        work = Path(__file__).resolve().parents[1] / ".work"
        work.mkdir(exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=work)
        self.root = Path(self.directory.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Test Fixture")
        self.git("config", "user.email", "fixture@example.invalid")

    def tearDown(self):
        self.directory.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo).decode().strip()

    def commit(self, content):
        (self.repo / "sample.txt").write_text(content, encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-m", "test fixture")
        return self.git("rev-parse", "HEAD")

    def test_all_intermediate_commits_are_audited(self):
        first = self.commit("one")
        second = self.commit("two")
        third = self.commit("three")
        self.assertEqual([second, third], VERIFY.introduced(self.repo, first, third))

    def test_new_branch_has_no_unproven_history_exclusion(self):
        first = self.commit("one")
        second = self.commit("two")
        self.assertEqual([first, second], VERIFY.introduced(self.repo, "0" * 40, second))

    def test_snapshot_ignores_working_tree_edits(self):
        sha = self.commit("committed")
        (self.repo / "sample.txt").write_text("not committed", encoding="utf-8")
        output = self.root / "snapshot"
        VERIFY.snapshot(self.repo, sha, output)
        self.assertEqual("committed", (output / "sample.txt").read_text())

    def test_export_ignore_cannot_hide_files(self):
        (self.repo / ".gitattributes").write_text("sample.txt export-ignore\n")
        sha = self.commit("visible")
        output = self.root / "snapshot"
        VERIFY.snapshot(self.repo, sha, output)
        self.assertTrue((output / "sample.txt").exists())

    def test_suppression_changes_require_policy_review(self):
        path = self.repo / "main.tf"
        path.write_text('resource "test" "x" {}\n')
        before = VERIFY.policy_hash(self.repo)
        path.write_text('#checkov:skip=TEST:unreviewed\nresource "test" "x" {}\n')
        self.assertNotEqual(before, VERIFY.policy_hash(self.repo))

    def test_business_configuration_is_not_a_policy_override(self):
        path = self.repo / "main.tf"
        path.write_text('variable "value" { default = 1 }\n')
        before = VERIFY.policy_hash(self.repo)
        path.write_text('variable "value" { default = 2 }\n')
        self.assertEqual(before, VERIFY.policy_hash(self.repo))

    def test_policy_fingerprint_is_portable_across_git_line_endings(self):
        path = self.repo / ".checkov.yml"
        path.write_bytes(b"framework:\n  - terraform\n")
        expected = VERIFY.policy_hash(self.repo)
        path.write_bytes(b"framework:\r\n  - terraform\r\n")
        self.assertEqual(expected, VERIFY.policy_hash(self.repo))
        path.write_bytes(b"framework:\r\n  - github_actions\r\n")
        self.assertNotEqual(expected, VERIFY.policy_hash(self.repo))


if __name__ == "__main__":
    unittest.main()
