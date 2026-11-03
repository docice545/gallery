"""Expose bounded failure evidence in check annotations; never change test status."""

import argparse
import json
import subprocess
from pathlib import Path

ANNOTATION_LIMIT = 3000  # Runner annotations truncate messages at 4096 characters.


def escape(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def report(title: str, message: str) -> None:
    # Keep each annotation bounded, and prevent test output becoming workflow commands.
    title = escape(title).replace(",", "%2C").replace(":", "%3A")
    print(f"::error title={title}::{escape(message[:ANNOTATION_LIMIT])}")


def flutter(path: Path) -> None:
    names = {}
    for line in path.read_text(errors="replace").splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue  # Flutter can emit tool progress before the JSON test stream.
        if not isinstance(event, dict):
            continue
        if event.get("type") == "testStart":
            test = event["test"]
            names[test["id"]] = test["name"]
        elif event.get("type") == "error":
            report(
                names.get(event.get("testID"), "Flutter test failure"),
                str(event.get("error", "")) + "\n" + str(event.get("stackTrace", "")),
            )


def formatting() -> None:
    paths = subprocess.check_output(
        [
            "git",
            "diff",
            "--name-only",
            "-z",
            "--",
            "mobile/lib",
            "mobile/test",
            "mobile/integration_test",
        ],
        text=True,
    ).split("\0")
    for path in filter(None, paths):
        patch = subprocess.check_output(["git", "diff", "--", path], text=True)
        for index, offset in enumerate(range(0, len(patch), ANNOTATION_LIMIT), 1):
            report(
                f"Dart formatting: {path} (part {index})",
                patch[offset : offset + ANNOTATION_LIMIT],
            )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("flutter", "format", "build"))
    parser.add_argument("path", nargs="?", type=Path)
    args = parser.parse_args()
    if args.mode == "format":
        formatting()
    elif args.mode == "flutter":
        flutter(args.path)
    else:
        report(
            "Disposable CI Docker build failed",
            args.path.read_text(errors="replace")[-ANNOTATION_LIMIT:],
        )


if __name__ == "__main__":
    main()
