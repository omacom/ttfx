"""Check CI selection against real Git histories without building ttfx."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "ci/fx_required.py"


class FxCiPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "ci@example.invalid")
        self.git("config", "user.name", "CI tests")
        self.base = self.commit("src/main.rs", "fn main() {}\n")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, path, content="changed\n"):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        self.git("add", "-A")
        self.git("commit", "-qm", "test change")
        return self.git("rev-parse", "HEAD")

    def pr(self, draft=False):
        return {"pull_request": {"draft": draft, "base": {"sha": self.base},
                                 "head": {"sha": self.git("rev-parse", "HEAD")}}}

    def run_policy(self, event_name, event, expected):
        event_path = self.root / "event.json"
        output_path = self.root / "output"
        event_path.write_text(json.dumps(event))
        output_path.write_text("")
        env = {**os.environ, "GITHUB_EVENT_NAME": event_name,
               "GITHUB_EVENT_PATH": str(event_path), "GITHUB_OUTPUT": str(output_path)}
        result = subprocess.run(["python3", str(SCRIPT)], cwd=self.repo, env=env,
                                capture_output=True, text=True, timeout=10)
        if expected is None:
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output_path.read_text(), "")
        else:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output_path.read_text(), f"run-full={str(expected).lower()}\n")

    def test_docs_only_and_draft_prs_skip_full_suite(self):
        for path in ("README.md", "docs/effects/example.gif", "NOTICE"):
            self.commit(path)
        self.run_policy("pull_request", self.pr(), False)
        self.commit("src/main.rs", "fn main() { println!(\"new\"); }\n")
        self.run_policy("pull_request", self.pr(draft=True), False)
        # The same revision must get full coverage once ready for review.
        self.run_policy("pull_request", self.pr(), True)

    def test_docs_followup_does_not_hide_earlier_code(self):
        self.commit("src/main.rs", "fn main() { println!(\"new\"); }\n")
        self.commit("README.md")
        self.run_policy("pull_request", self.pr(), True)

    def test_dependencies_build_tests_and_unknown_paths_require_full_suite(self):
        for path in ("Cargo.lock", "Cargo.toml", "flake.nix", "build.rs",
                     ".cargo/config.toml", ".github/workflows/ci.yml",
                     "tools/fx/cases/burn.txt", "tests/input.md", "new-component"):
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                self.commit(path)
                self.run_policy("pull_request", self.pr(), True)

    def test_removing_or_renaming_code_into_docs_requires_full_suite(self):
        (self.repo / "src/main.rs").rename(self.repo / "moved.md")
        self.commit("README.md")
        self.run_policy("pull_request", self.pr(), True)
        self.git("reset", "--hard", self.base)
        (self.repo / "src/main.rs").unlink()
        self.commit("README.md")
        self.run_policy("pull_request", self.pr(), True)

    def test_pushes_check_whole_push_and_manual_runs_always_run(self):
        docs = self.commit("docs/notes.md")
        self.run_policy("push", {"before": self.base, "after": docs}, False)
        self.commit("src/main.rs", "fn main() { println!(\"new\"); }\n")
        head = self.commit("README.md")
        self.run_policy("push", {"before": docs, "after": head}, True)
        self.run_policy("push", {"before": "0" * 40, "after": head}, True)
        self.run_policy("workflow_dispatch", {}, True)

    def test_missing_history_or_unknown_events_fail_instead_of_skipping(self):
        event = self.pr()
        event["pull_request"]["base"]["sha"] = "f" * 40
        self.run_policy("pull_request", event, None)
        self.run_policy("unexpected", {}, None)


if __name__ == "__main__":
    unittest.main()
