"""Expose bounded failure evidence in check annotations; never change test status."""

import argparse
import json
import subprocess
from pathlib import Path


def escape(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def report(title: str, message: str) -> None:
    # Keep each annotation bounded, and prevent test output becoming workflow commands.
    title = escape(title).replace(",", "%2C").replace(":", "%3A")
    print(f"::error title={title}::{escape(message[:12000])}")


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
        ["git", "diff", "--name-only", "-z", "--", "mobile/lib"], text=True
    ).split("\0")
    for path in filter(None, paths):
        patch = subprocess.check_output(["git", "diff", "--", path], text=True)
        report("Dart formatting: " + path, patch)


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
            args.path.read_text(errors="replace")[-12000:],
        )


if __name__ == "__main__":
    main()
