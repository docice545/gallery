import importlib.util
import io
import subprocess
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("ci_registry_login", ROOT / ".github/scripts/login-ci-ghcr.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
ENV = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "GITHUB_TOKEN": "synthetic-private-token"}


def outcome(code, text=""):
    return subprocess.CompletedProcess([], code, stdout="", stderr=text)


class RegistryLoginTests(unittest.TestCase):
    def run_fixture(self, results):
        output = io.StringIO()
        with patch.dict(MODULE.os.environ, ENV, clear=True), patch.object(MODULE.subprocess, "run", side_effect=results) as run, patch.object(MODULE.time, "sleep") as sleep, redirect_stdout(output):
            code = MODULE.authenticate()
        return code, output.getvalue(), run, sleep

    def test_transient_transport_retries_and_token_never_enters_argv_or_logs(self):
        code, output, run, sleep = self.run_fixture([outcome(1, "TLS handshake timeout synthetic-private-token\n::error::untrusted"), outcome(0)])
        self.assertEqual(code, 0)
        self.assertEqual(run.call_count, 2)
        sleep.assert_called_once_with(2)
        self.assertNotIn(ENV["GITHUB_TOKEN"], output)
        self.assertNotIn("\n::error::untrusted", output)
        for call in run.call_args_list:
            self.assertNotIn(ENV["GITHUB_TOKEN"], str(call.args))
            self.assertEqual(call.kwargs["input"], ENV["GITHUB_TOKEN"] + "\n")

    def test_denied_and_unknown_errors_fail_once_even_if_the_message_mentions_timeout(self):
        for text in ["unauthorized: timeout", "denied", "unknown failure"]:
            with self.subTest(text=text):
                code, _, run, sleep = self.run_fixture([outcome(7, text)])
                self.assertEqual(code, 7)
                run.assert_called_once()
                sleep.assert_not_called()

    def test_transport_timeout_stops_after_three_attempts(self):
        code, _, run, sleep = self.run_fixture([subprocess.TimeoutExpired("docker", 45)] * 3)
        self.assertEqual(code, 124)
        self.assertEqual(run.call_count, 3)
        self.assertEqual(sleep.call_count, 2)

    def test_non_hosted_environment_and_missing_token_do_not_run_docker(self):
        for env in [{}, {**ENV, "RUNNER_ENVIRONMENT": "self-hosted"}, {**ENV, "GITHUB_TOKEN": ""}]:
            with self.subTest(environment=env.get("RUNNER_ENVIRONMENT")), patch.dict(MODULE.os.environ, env, clear=True), patch.object(MODULE.subprocess, "run") as run:
                with self.assertRaises(ValueError):
                    MODULE.authenticate()
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
