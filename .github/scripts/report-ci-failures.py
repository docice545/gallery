"""Expose bounded failure evidence in check annotations; never change test status."""

import argparse
import json
import subprocess
from pathlib import Path

ANNOTATION_LIMIT = 3000  # Runner annotations truncate messages at 4096 characters.


def escape(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def report(title: str, message: str, *, level: str = "error") -> None:
    # Keep each annotation bounded, and prevent test output becoming workflow commands.
    title = escape(title).replace(",", "%2C").replace(":", "%3A")
    print(f"::{level} title={title}::{escape(message[:ANNOTATION_LIMIT])}")


def flutter(path: Path) -> None:
    names = {}
    output = {}
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
        elif event.get("type") == "print":
            test_id = event.get("testID")
            # Flutter widget failures put the assertion and source location in
            # print events; their error event only says "See exception logs above".
            output[test_id] = (
                output.get(test_id, "") + "\n" + str(event.get("message", ""))
            )[-12000:]
        elif event.get("type") == "error":
            test_id = event.get("testID")
            title = names.get(test_id, "Flutter test failure")
            evidence = (
                str(event.get("error", ""))
                + "\n"
                + str(event.get("stackTrace", ""))
                + output.get(test_id, "")
            )
            for index, offset in enumerate(
                range(0, len(evidence), ANNOTATION_LIMIT), 1
            ):
                report(
                    f"{title} (part {index})",
                    evidence[offset : offset + ANNOTATION_LIMIT],
                )
        elif event.get("type") == "testDone":
            output.pop(event.get("testID"), None)


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
    paths = list(filter(None, paths))
    # GitHub retains at most ten error annotations per step. Large patches can
    # consume that budget before later files; preserve the inventory separately.
    report("Dart formatter changed files", "\n".join(paths), level="notice")
    for path in paths:
        patch = subprocess.check_output(["git", "diff", "--", path], text=True)
        for index, offset in enumerate(range(0, len(patch), ANNOTATION_LIMIT), 1):
            report(
                f"Dart formatting: {path} (part {index})",
                patch[offset : offset + ANNOTATION_LIMIT],
            )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("flutter", "format", "build", "android-build"))
    parser.add_argument("path", nargs="?", type=Path)
    args = parser.parse_args()
    if args.mode == "format":
        formatting()
    elif args.mode == "flutter":
        flutter(args.path)
    else:
        report(
            "Unsigned Android build failed" if args.mode == "android-build" else "Disposable CI Docker build failed",
            args.path.read_text(errors="replace")[-ANNOTATION_LIMIT:],
        )


if __name__ == "__main__":
    main()
