import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "live_photo_ci", Path(__file__).resolve().parents[1] / "require_live_photo_ci.py"
)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
SHA = "a" * 40
REPO = "docice545/gallery"


class LivePhotoReleaseGateTests(unittest.TestCase):
    def run_row(self, **changes):
        return {
            "id": 12,
            "head_sha": SHA,
            "event": "push",
            "status": "completed",
            "conclusion": "success",
            "run_attempt": 2,
            "path": ".github/workflows/build-mobile.yml",
            **changes,
        }

    def jobs(self, workflow="build-mobile.yml"):
        return [
            {"name": name, "conclusion": "success"}
            for name in sorted(gate.REQUIRED_JOBS[workflow])
        ]

    def other_workflows(self):
        result = []
        for name in ("test.yml", "static_analysis.yml"):
            result.extend(
                [
                    {"workflow_runs": [self.run_row(path=f".github/workflows/{name}")]},
                    {"jobs": self.jobs(name)},
                ]
            )
        return result

    def test_exact_push_and_both_successful_jobs_are_required(self):
        with patch.object(
            gate,
            "api",
            side_effect=[
                {"workflow_runs": [self.run_row()]},
                {"jobs": self.jobs()},
                *self.other_workflows(),
            ],
        ) as api:
            self.assertEqual(gate.verify(REPO, SHA), 12)
        self.assertTrue(
            any("/attempts/2/jobs?" in call.args[1] for call in api.call_args_list)
        )

    def test_pr_wrong_sha_failed_cancelled_running_and_old_green_do_not_qualify(self):
        for changes in (
            {"event": "pull_request"},
            {"head_sha": "b" * 40},
            {"conclusion": "failure"},
            {"conclusion": "cancelled"},
            {"status": "in_progress"},
            {"path": "other.yml"},
        ):
            with self.subTest(changes=changes), patch.object(
                gate, "api", return_value={"workflow_runs": [self.run_row(**changes)]}
            ), self.assertRaises(ValueError):
                gate.verify(REPO, SHA)
        runs = [self.run_row(id=10), self.run_row(id=12, conclusion="failure")]
        with patch.object(
            gate, "api", return_value={"workflow_runs": runs}
        ), self.assertRaises(ValueError):
            gate.verify(REPO, SHA)

    def test_skipped_missing_failed_and_duplicate_required_jobs_block(self):
        for jobs in (
            self.jobs()[:1],
            self.jobs() + self.jobs(),
            [{"name": name, "conclusion": "skipped"} for name in gate.GATES],
            [{"name": name, "conclusion": "failure"} for name in gate.GATES],
        ):
            with self.subTest(jobs=jobs), patch.object(
                gate,
                "api",
                side_effect=[{"workflow_runs": [self.run_row()]}, {"jobs": jobs}],
            ), self.assertRaises(ValueError):
                gate.verify(REPO, SHA)

    def test_jobs_are_paginated_without_accepting_missing_second_gate(self):
        with patch.object(
            gate,
            "api",
            side_effect=[
                {"workflow_runs": [self.run_row()]},
                {
                    "jobs": [
                        {"name": f"other {i}", "conclusion": "success"}
                        for i in range(100)
                    ]
                },
                {"jobs": self.jobs()},
                *self.other_workflows(),
            ],
        ) as api:
            self.assertEqual(gate.verify(REPO, SHA), 12)
        self.assertTrue(
            any(call.args[1].endswith("page=2") for call in api.call_args_list)
        )

    def test_green_live_photo_cannot_conceal_failed_backend_or_analysis(self):
        for index in (0, 2):
            other = self.other_workflows()
            other[index]["workflow_runs"][0]["conclusion"] = "failure"
            with patch.object(
                gate,
                "api",
                side_effect=[
                    {"workflow_runs": [self.run_row()]},
                    {"jobs": self.jobs()},
                    *other,
                ],
            ), self.assertRaisesRegex(ValueError, "not successful"):
                gate.verify(REPO, SHA)

    def test_live_photo_success_cannot_hide_skipped_full_flutter(self):
        jobs = self.jobs()
        next(job for job in jobs if job["name"] == "Flutter tests and coverage")[
            "conclusion"
        ] = "skipped"
        with patch.object(
            gate,
            "api",
            side_effect=[{"workflow_runs": [self.run_row()]}, {"jobs": jobs}],
        ), self.assertRaisesRegex(ValueError, "Flutter tests and coverage"):
            gate.verify(REPO, SHA)

    def test_green_workflows_with_skipped_backend_or_analysis_block_release(self):
        for index in (1, 3):
            other = self.other_workflows()
            other[index]["jobs"][0]["conclusion"] = "skipped"
            with self.subTest(index=index), patch.object(
                gate,
                "api",
                side_effect=[
                    {"workflow_runs": [self.run_row()]},
                    {"jobs": self.jobs()},
                    *other,
                ],
            ), self.assertRaisesRegex(ValueError, "Required check"):
                gate.verify(REPO, SHA)


if __name__ == "__main__":
    unittest.main()
