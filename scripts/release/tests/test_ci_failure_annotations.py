"""Failure diagnostics retain test identity and cannot inject workflow commands."""

import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "ci_failure_annotations",
    Path(__file__).resolve().parents[3] / ".github/scripts/report-ci-failures.py",
)
reporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reporter)


class FailureAnnotations(unittest.TestCase):
    def test_json_errors_retain_test_name_and_stack_without_emitting_commands(self):
        events = [
            {"type": "testStart", "test": {"id": 1, "name": "cold start, lifecycle"}},
            {"type": "testStart", "test": {"id": 2, "name": "passing test"}},
            {"type": "testDone", "testID": 2, "result": "success"},
            {
                "type": "error",
                "testID": 1,
                "error": "expected 1%\n::notice::injected",
                "stackTrace": "test/foo.dart:42",
            },
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tests.jsonl"
            path.write_text(
                "Flutter tool progress\nnull\n" + "\n".join(map(json.dumps, events))
            )
            output = io.StringIO()
            with redirect_stdout(output):
                reporter.flutter(path)
        lines = output.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertIn("cold start%2C lifecycle", lines[0])
        self.assertIn("expected 1%25%0A::notice::injected", lines[0])
        self.assertIn("test/foo.dart:42", lines[0])
        self.assertNotIn("passing test", lines[0])

    def test_large_failure_is_bounded(self):
        output = io.StringIO()
        with redirect_stdout(output):
            reporter.report("fixture", "a" * 20000)
        self.assertEqual(output.getvalue().count("a"), reporter.ANNOTATION_LIMIT)

    def test_format_diff_survives_runner_annotation_limit(self):
        diff = (
            "diff --git a/mobile/lib/example.dart b/mobile/lib/example.dart\n"
            + "line\n" * 1800
        )
        output = io.StringIO()
        with patch.object(
            reporter.subprocess,
            "check_output",
            side_effect=["mobile/lib/example.dart\0", diff],
        ):
            with redirect_stdout(output):
                reporter.formatting()
        messages = [line.split("::", 2)[2] for line in output.getvalue().splitlines()]
        decoded = [
            message.replace("%0A", "\n").replace("%0D", "\r").replace("%25", "%")
            for message in messages
        ]
        self.assertTrue(
            all(len(message) <= reporter.ANNOTATION_LIMIT for message in decoded)
        )
        self.assertEqual("".join(decoded), diff)


if __name__ == "__main__":
    unittest.main()
