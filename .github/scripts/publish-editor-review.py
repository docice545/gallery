"""Publish only generated editor review PNGs and measurements to the requested draft branch.

Invoked by the explicit PR review label, never by an ordinary source push.
A moved branch is rejected; no force update, release, signing or deployment.
"""

import base64
import json
import os
from pathlib import Path
import subprocess

REPOSITORY = "docice545/gallery"
BRANCH = "codex/issue17-smart-timeline"
PREFIX = "mobile/test/pages/edit/goldens/fixed_dock_"


def api(path, payload=None):
    command = ["gh", "api", f"repos/{REPOSITORY}/{path}"]
    if payload is not None:
        command += ["--method", "POST", "--input", "-"]
    result = subprocess.run(
        command,
        input=None if payload is None else json.dumps(payload),
        text=True,
        capture_output=True,
        check=True,
    )
    return json.loads(result.stdout)


def main():
    expected = os.environ["REVIEW_SOURCE_SHA"]
    if (
        os.environ["REVIEW_HEAD_BRANCH"] != BRANCH
        or os.environ["GITHUB_REPOSITORY"] != REPOSITORY
    ):
        raise SystemExit("Only the existing Build 37 draft branch is allowed")
    if (
        subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        != expected
    ):
        raise SystemExit("Rendered checkout SHA differs from the requested source")
    current = api(f"git/ref/heads/{BRANCH}")
    if current["object"]["sha"] != expected:
        raise SystemExit(
            "Branch moved while rendering; rerun the explicit review request"
        )
    names = ["entry", "markup", "marker", "width", "color", "crop", "text"]
    paths = [Path(PREFIX + name + ".png") for name in names]
    for path in paths:
        if path.is_symlink() or not path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
            raise SystemExit(f"Invalid review PNG: {path}")
    log = Path(os.environ["REVIEW_TEST_LOG"])
    measurements = []
    failures = 0
    for line in log.read_text(errors="replace").splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "print" and str(event.get("message", "")).startswith(
            "EDITOR_VIEWPORT "
        ):
            measurements.append(event["message"])
        if event.get("type") == "testDone" and event.get("result") in (
            "error",
            "failure",
        ):
            failures += 1
    if failures or len(measurements) != len(names):
        raise SystemExit("Missing measurements or failed structural editor tests")
    receipt = Path("specs/design/editor-dock-review/measurements.json")
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(
        json.dumps(
            {
                "sourceSha": expected,
                "kind": "Synthetic Flutter widget render; not Samsung screenshots",
                "iconDesignApproval": "PENDING",
                "hardwareAcceptance": "PENDING",
                "beforeSourceSha": "b61867889c0a47a06ff19d7be1f0ca00c72c1945",
                "measurements": measurements,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n"
    )
    paths.append(receipt)
    tree = []
    for path in paths:
        blob = api(
            "git/blobs",
            {
                "content": base64.b64encode(path.read_bytes()).decode(),
                "encoding": "base64",
            },
        )
        tree.append(
            {"path": str(path), "mode": "100644", "type": "blob", "sha": blob["sha"]}
        )
    parent = api(f"git/commits/{expected}")
    new_tree = api("git/trees", {"base_tree": parent["tree"]["sha"], "tree": tree})
    if new_tree["sha"] == parent["tree"]["sha"]:
        print("Review artifacts already match")
        return
    commit = api(
        "git/commits",
        {
            "message": "test(mobile): record fixed dock review screenshots",
            "tree": new_tree["sha"],
            "parents": [expected],
        },
    )
    # PATCH is explicit and non-forcing. A concurrent push makes this fail.
    subprocess.run(
        [
            "gh",
            "api",
            "--method",
            "PATCH",
            f"repos/{REPOSITORY}/git/refs/heads/{BRANCH}",
            "--input",
            "-",
        ],
        input=json.dumps({"sha": commit["sha"], "force": False}),
        text=True,
        check=True,
        stdout=subprocess.DEVNULL,
    )
    print("Editor review artifacts committed: " + commit["sha"])


if __name__ == "__main__":
    main()
