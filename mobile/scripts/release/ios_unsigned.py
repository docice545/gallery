#!/usr/bin/env python3
"""Dispatch or fetch only the existing credentials-free iOS verification lane.

Requires GitHub CLI authentication for docice545/gallery. Never selects the paid
release path: workflow input version is always empty. Output is verified before
handoff; a failed run, wrong revision or missing artifact fails the operation.
"""

from __future__ import annotations

import argparse
import datetime
import json
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

from ios_artifact import extract_ipa, sha256, verify_ipa_archive

REPOSITORY = "docice545/gallery"
WORKFLOW = "gallery-build-mobile.yml"
WORKFLOW_PATH = f".github/workflows/{WORKFLOW}"
UNSIGNED_JOB = "Verify or explicitly release iOS"
ARTIFACT = "ios-unsigned-ipa"


def command(arguments: list[str], *, directory: Path | None = None) -> str:
    result = subprocess.run(
        arguments,
        cwd=directory,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        # Download failures may contain private, short-lived signed storage URLs.
        # Keep those out of operator output; gh auth status is a separate command.
        raise ValueError(
            f"Command failed ({result.returncode}): {arguments[0]} operation; credentials/storage URLs omitted"
        )
    return result.stdout


def api(endpoint: str) -> dict | list:
    return json.loads(command(["gh", "api", f"repos/{REPOSITORY}/{endpoint}"]))


def check_sha(value: str) -> None:
    if not re.fullmatch(r"[a-f0-9]{40}", value):
        raise ValueError("Expected commit must be the full lowercase 40-character SHA")


def preflight(expected: str) -> Path:
    check_sha(expected)
    root = Path(command(["git", "rev-parse", "--show-toplevel"]).strip())
    if command(["git", "branch", "--show-current"], directory=root).strip() != "work":
        raise ValueError("Release checkout must be on branch work")
    if command(["git", "rev-parse", "HEAD"], directory=root).strip() != expected:
        raise ValueError(
            "Local HEAD differs from the explicitly reviewed expected commit"
        )
    origin = command(["git", "remote", "get-url", "origin"], directory=root).strip()
    if origin.removesuffix(".git") not in {
        f"https://github.com/{REPOSITORY}",
        f"git@github.com:{REPOSITORY}",
    }:
        raise ValueError(
            "origin must identify docice545/gallery on GitHub; credentials are not printed"
        )
    if command(["git", "status", "--porcelain"], directory=root).strip():
        raise ValueError("Release checkout must be clean")
    remote = api("git/ref/heads/work")
    if remote["object"]["sha"] != expected:
        raise ValueError(
            "GitHub work differs from expected commit; do not build a moving/unreviewed revision"
        )
    if not (root / WORKFLOW_PATH).is_file():
        raise ValueError("Existing unsigned workflow is missing")
    return root


def dispatch(expected: str, *, wait: bool) -> int:
    preflight(expected)
    before = api(f"actions/workflows/{WORKFLOW}/runs?branch=work&per_page=30")[
        "workflow_runs"
    ]
    if any(run["status"] != "completed" for run in before):
        raise ValueError(
            "A mobile workflow is already active on work; wait to avoid cancelling Android/iOS validation"
        )
    previous = {run["id"] for run in before}
    command(
        [
            "gh",
            "workflow",
            "run",
            WORKFLOW,
            "--repo",
            REPOSITORY,
            "--ref",
            "work",
            "-f",
            "build_target=ios",
            "-f",
            "version=",
            "-f",
            "environment=development",
            "-f",
            "android_media_pilot=false",
            "-f",
            "refresh_ios_pods_lock=false",
        ]
    )
    for _ in range(12):
        runs = api(
            f"actions/workflows/{WORKFLOW}/runs?branch=work&event=workflow_dispatch&per_page=30"
        )["workflow_runs"]
        matches = [
            run
            for run in runs
            if run["id"] not in previous and run["head_sha"] == expected
        ]
        if len(matches) > 1:
            raise ValueError(
                "Concurrent matching dispatches found; specify --run explicitly rather than guessing"
            )
        if matches:
            run_id = matches[0]["id"]
            print(
                f"PASS: dispatched unsigned iOS run {run_id}; commit {expected}; artifact {ARTIFACT}",
                flush=True,
            )
            if wait:
                command(
                    [
                        "gh",
                        "run",
                        "watch",
                        str(run_id),
                        "--repo",
                        REPOSITORY,
                        "--exit-status",
                        "--interval",
                        "30",
                    ]
                )
            return run_id
        time.sleep(5)
    raise ValueError(
        "Dispatch accepted but no unique matching run observed; inspect GitHub Actions before dispatching again"
    )


def verify_run(run_id: int, expected: str) -> tuple[dict, dict, dict]:
    check_sha(expected)
    run = api(f"actions/runs/{run_id}")
    if (
        run["head_sha"] != expected
        or run["head_branch"] != "work"
        or run["path"].split("@")[0] != WORKFLOW_PATH
        or run["event"] != "workflow_dispatch"
        or run["status"] != "completed"
        or run["conclusion"] != "success"
    ):
        raise ValueError(
            "Run must be successful unsigned workflow_dispatch on work at the exact reviewed revision"
        )
    jobs = api(f"actions/runs/{run_id}/jobs?per_page=100")["jobs"]
    candidates = [
        job
        for job in jobs
        if job["name"] == UNSIGNED_JOB and job["conclusion"] == "success"
    ]
    if len(candidates) != 1:
        raise ValueError("Expected exactly one successful iOS verification job")
    job = candidates[0]
    steps = {step["name"]: step.get("conclusion") for step in job["steps"]}
    if steps.get("Build iOS (no upload)") != "success":
        raise ValueError("Unsigned native build did not succeed")
    for name in (
        "Create API Key",
        "Import Certificate",
        "Create keychain and import certificate",
        "Build and deploy to TestFlight",
    ):
        if steps.get(name) != "skipped":
            raise ValueError(
                "Paid signing/upload steps were not all skipped; refuse this release handoff"
            )
    artifacts = api(f"actions/runs/{run_id}/artifacts?per_page=100")["artifacts"]
    matching = [
        item for item in artifacts if item["name"] == ARTIFACT and not item["expired"]
    ]
    if len(matching) != 1:
        raise ValueError("Expected exactly one unexpired ios-unsigned-ipa artifact")
    return run, job, matching[0]


def fetch(run_id: int, expected: str, output: Path, version: str, build: str) -> dict:
    run, job, artifact = verify_run(run_id, expected)
    identity = {
        "repository": REPOSITORY,
        "commit": expected,
        "run_id": run_id,
        "artifact_name": ARTIFACT,
        "artifact_id": artifact["id"],
        "version": version,
        "build": build,
    }
    if output.is_symlink():
        raise ValueError("Release output directory must not be a symlink")
    if output.exists():
        manifest = output / "release-manifest.json"
        if not manifest.is_file() or manifest.is_symlink():
            raise ValueError(
                "Existing output is not an owned release directory; refusing to overwrite"
            )
        prior = json.loads(manifest.read_text())
        if any(prior.get(key) != value for key, value in identity.items()) or sha256(
            output / "Photos-unsigned.ipa"
        ) != prior.get("sha256"):
            raise ValueError(
                "Existing output identity/checksum differs; choose a new release directory"
            )
        return {**prior, "status": "PASS: matching verified download already exists"}
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=".gallery-ios-release-", dir=output.parent
    ) as temporary:
        staged = Path(temporary)
        download = staged / "download"
        command(
            [
                "gh",
                "run",
                "download",
                str(run_id),
                "--repo",
                REPOSITORY,
                "--name",
                ARTIFACT,
                "--dir",
                str(download),
            ]
        )
        ipas = list(download.glob("*.ipa"))
        if len(ipas) != 1 or ipas[0].name != "Photos-unsigned.ipa":
            raise ValueError("Artifact must contain exactly Photos-unsigned.ipa")
        archive = staged / "inspection/Runner.xcarchive"
        extract_ipa(ipas[0], archive)
        verify_ipa_archive(archive, version=version, build=build)
        result = {
            **identity,
            "sha256": sha256(ipas[0]),
            "verified_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "runner": job.get("runner_name"),
            "runner_labels": job.get("labels"),
            "artifact": str((output / "Photos-unsigned.ipa").absolute()),
            "status": "PASS: Runner + both extensions, identities/version, ASCII base and ru Фото verified; user-side signing required",
        }
        (download / "release-manifest.json").write_text(
            json.dumps(result, indent=2, ensure_ascii=False) + "\n"
        )
        (download / "Photos-unsigned.ipa.sha256").write_text(
            f"{result['sha256']}  Photos-unsigned.ipa\n"
        )
        download.rename(output)
        return result


def dispatch_or_reuse(
    expected: str,
    *,
    wait: bool,
    output: Path | None,
    version: str | None,
    build: str | None,
) -> dict:
    if output is not None and (output.exists() or output.is_symlink()):
        # Retry the one-command handoff without spending another CI run and
        # then rejecting a valid artifact's earlier run ID. Keep strict proof.
        preflight(expected)
        if output.is_symlink():
            raise ValueError("Release output directory must not be a symlink")
        manifest = output / "release-manifest.json"
        if not manifest.is_file() or manifest.is_symlink():
            raise ValueError(
                "Existing output has no owned release receipt; no new workflow dispatched"
            )
        prior = json.loads(manifest.read_text())
        if not isinstance(prior, dict) or any(
            prior.get(key) != value
            for key, value in {
                "repository": REPOSITORY,
                "commit": expected,
                "artifact_name": ARTIFACT,
                "version": version,
                "build": build,
            }.items()
        ):
            raise ValueError(
                "Existing output receipt identity differs; no new workflow dispatched"
            )
        run_id = prior.get("run_id")
        if (
            type(run_id) is not int
            or run_id <= 0
            or prior.get("sha256") != sha256(output / "Photos-unsigned.ipa")
        ):
            raise ValueError(
                "Existing output receipt/checksum is invalid; no new workflow dispatched"
            )
        return fetch(run_id, expected, output, version, build)
    run_id = dispatch(expected, wait=wait)
    return (
        fetch(run_id, expected, output, version, build)
        if output is not None
        else {"run_id": run_id, "artifact_name": ARTIFACT}
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    check = subparsers.add_parser(
        "preflight", help="Read-only checkout/GitHub readiness"
    )
    check.add_argument("--expected-commit", required=True)
    launch = subparsers.add_parser(
        "dispatch", help="Start only unsigned iOS CI, optionally wait and fetch"
    )
    launch.add_argument("--expected-commit", required=True)
    launch.add_argument("--wait", action="store_true")
    launch.add_argument("--output", type=Path)
    launch.add_argument("--version")
    launch.add_argument("--build")
    download = subparsers.add_parser(
        "fetch", help="Download and verify an exact successful run"
    )
    download.add_argument("--run", type=int, required=True)
    download.add_argument("--expected-commit", required=True)
    download.add_argument("--output", type=Path, required=True)
    download.add_argument("--version", required=True)
    download.add_argument("--build", required=True)
    inspect = subparsers.add_parser(
        "verify", help="Offline verification of an already downloaded unsigned IPA"
    )
    inspect.add_argument("--ipa", type=Path, required=True)
    inspect.add_argument("--input-sha256", required=True)
    inspect.add_argument("--version", required=True)
    inspect.add_argument("--build", required=True)
    args = parser.parse_args()
    if sys.version_info < (3, 11):
        parser.exit(1, "FAIL: Python 3.11 or newer is required\n")
    try:
        if args.operation == "preflight":
            preflight(args.expected_commit)
            result = {
                "status": "PASS: clean work checkout and GitHub revision verified",
                "commit": args.expected_commit,
            }
        elif args.operation == "dispatch":
            if args.output and (not args.wait or not args.version or not args.build):
                raise ValueError("dispatch --output requires --wait --version --build")
            result = dispatch_or_reuse(
                args.expected_commit,
                wait=args.wait,
                output=args.output,
                version=args.version,
                build=args.build,
            )
        elif args.operation == "fetch":
            result = fetch(
                args.run, args.expected_commit, args.output, args.version, args.build
            )
        else:
            if sha256(args.ipa) != args.input_sha256.lower():
                raise ValueError("IPA digest differs from expected input SHA-256")
            with tempfile.TemporaryDirectory(
                prefix="gallery-ios-inspect-"
            ) as temporary:
                archive = Path(temporary) / "Runner.xcarchive"
                extract_ipa(args.ipa, archive)
                verify_ipa_archive(archive, version=args.version, build=args.build)
            result = {
                "status": "PASS: unsigned IPA metadata/ownership/ASCII registration names/ru Фото verified",
                "sha256": args.input_sha256.lower(),
            }
    except (
        ValueError,
        OSError,
        zipfile.BadZipFile,
        plistlib.InvalidFileException,
    ) as error:
        parser.exit(1, f"FAIL: {error}\n")
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
