#!/usr/bin/env python3
"""Require exact-source automated evidence before a manually requested release.

This read-only gate never substitutes for Samsung acceptance. Only push runs
qualify: PR runs test a synthetic merge checkout, not the released source SHA.
"""

import argparse
import json
import re
import subprocess

GATES = {"Live Photo timeline non-regression", "Live Photo native decoded motion"}


def api(repository: str, path: str) -> dict:
    result = subprocess.run(
        ["gh", "api", f"repos/{repository}/{path}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise ValueError("Cannot retrieve required CI evidence; release blocked")
    return json.loads(result.stdout)


def successful_run(repository: str, commit: str, workflow: str) -> dict:
    runs = api(
        repository,
        f"actions/workflows/{workflow}/runs?head_sha={commit}&event=push&per_page=100",
    )
    candidates = [
        run
        for run in runs["workflow_runs"]
        if run["head_sha"] == commit and run["event"] == "push"
    ]
    if not candidates:
        raise ValueError(
            "No exact-source push CI run; PR checks cannot certify release bytes"
        )
    # A failed/running newer run must never be hidden by an older green result.
    run = max(candidates, key=lambda row: row["id"])
    if run["status"] != "completed" or run["conclusion"] != "success":
        raise ValueError(f"Latest exact-source {workflow} run is not successful")
    if run["path"].split("@")[0] != f".github/workflows/{workflow}":
        raise ValueError("Wrong source workflow")
    return run


def verify(repository: str, commit: str) -> int:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid repository")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected commit must be a full SHA")
    run = successful_run(repository, commit, "build-mobile.yml")
    attempt = run["run_attempt"]
    jobs = []
    page = 1
    while True:
        batch = api(
            repository,
            f"actions/runs/{run['id']}/attempts/{attempt}/jobs?per_page=100&page={page}",
        )["jobs"]
        jobs.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    for name in GATES:
        matches = [job for job in jobs if job["name"] == name]
        if len(matches) != 1 or matches[0]["conclusion"] != "success":
            raise ValueError(
                f"Required check missing, ambiguous or unsuccessful: {name}"
            )
    # Live Photo PASS cannot conceal a failed backend/Web/Flutter/SDK baseline.
    for workflow in ("test.yml", "static_analysis.yml"):
        successful_run(repository, commit, workflow)
    return run["id"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--expected-commit", required=True)
    args = parser.parse_args()
    try:
        run = verify(args.repository, args.expected_commit)
    except (ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"FAIL: {error}\n")
    print(
        f"PASS exact-source Live Photo CI run {run}; physical Samsung acceptance remains mandatory"
    )


if __name__ == "__main__":
    main()
