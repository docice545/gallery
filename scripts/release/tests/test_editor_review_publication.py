"""Draft screenshot publication cannot overwrite moved sources or accept partial evidence."""

import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "editor_review",
    Path(__file__).resolve().parents[3] / ".github/scripts/publish-editor-review.py",
)
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)


class EditorReviewPublication(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        previous = Path.cwd()
        os.chdir(temp.name)
        self.addCleanup(os.chdir, previous)
        self.log = Path("render.jsonl")
        self.names = ["entry", "markup", "marker", "width", "color", "crop", "text"]
        for name in self.names:
            path = Path(review.PREFIX + name + ".png")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"\x89PNG\r\n\x1a\n")
        self.events = [
            {
                "type": "print",
                "message": f"EDITOR_VIEWPORT {name} photo=fixture dock=fixture",
            }
            for name in self.names
        ]
        self.events.append({"type": "done", "success": True})
        self.env = patch.dict(
            os.environ,
            {
                "REVIEW_SOURCE_SHA": "source",
                "REVIEW_HEAD_BRANCH": review.BRANCH,
                "GITHUB_REPOSITORY": review.REPOSITORY,
                "REVIEW_TEST_LOG": str(self.log),
            },
        )
        self.env.start()
        self.addCleanup(self.env.stop)
        self.head = patch.object(
            review.subprocess, "check_output", return_value="source\n"
        )
        self.head.start()
        self.addCleanup(self.head.stop)

    def assert_blocked(self, message, remote="source"):
        self.log.write_text("\n".join(map(json.dumps, self.events)))
        with patch.object(
            review, "api", return_value={"object": {"sha": remote}}
        ) as api:
            with patch.object(review.subprocess, "run") as mutate:
                with self.assertRaisesRegex(SystemExit, message):
                    review.main()
                self.assertTrue(
                    all(
                        call.args[0].startswith("git/ref/")
                        for call in api.call_args_list
                    )
                )
                mutate.assert_not_called()

    def test_moved_source_stops_before_uploading(self):
        self.assert_blocked("Branch moved", remote="new-source")

    def test_wrong_branch_is_rejected(self):
        with patch.dict(os.environ, {"REVIEW_HEAD_BRANCH": "main"}):
            self.assert_blocked("Only the existing")

    def test_incomplete_log_does_not_publish(self):
        self.events.pop()
        self.assert_blocked("Missing measurements")

    def test_failed_assertion_does_not_publish(self):
        self.events.insert(0, {"type": "testDone", "result": "failure"})
        self.assert_blocked("Missing measurements")

    def test_repeated_measurement_does_not_replace_missing_depth(self):
        self.events[0] = self.events[1]
        self.assert_blocked("Missing measurements")

    def test_symlink_is_rejected(self):
        path = Path(review.PREFIX + "entry.png")
        path.unlink()
        path.symlink_to(Path(review.PREFIX + "markup.png").name)
        self.assert_blocked("Invalid review PNG")

    def test_only_pngs_and_receipt_are_published_without_force(self):
        self.log.write_text("\n".join(map(json.dumps, self.events)))

        def api(path, payload=None):
            if path.startswith("git/ref/"):
                return {"object": {"sha": "source"}}
            if path == "git/blobs":
                return {"sha": "blob"}
            if path == "git/commits/source":
                return {"tree": {"sha": "parent-tree"}}
            if path == "git/trees":
                self.assertEqual(payload["base_tree"], "parent-tree")
                paths = {item["path"] for item in payload["tree"]}
                self.assertEqual(
                    paths,
                    {review.PREFIX + name + ".png" for name in self.names}
                    | {"specs/design/editor-dock-review/measurements.json"},
                )
                return {"sha": "review-tree"}
            self.assertEqual(path, "git/commits")
            self.assertEqual(payload["parents"], ["source"])
            return {"sha": "review-commit"}

        with patch.object(review, "api", side_effect=api):
            with patch.object(review.subprocess, "run") as update:
                with redirect_stdout(io.StringIO()):
                    review.main()
                update.assert_called_once()
                self.assertIn("PATCH", update.call_args.args[0])
                self.assertEqual(
                    json.loads(update.call_args.kwargs["input"]),
                    {"sha": "review-commit", "force": False},
                )


if __name__ == "__main__":
    unittest.main()
