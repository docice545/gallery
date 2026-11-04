#!/usr/bin/env python3
"""Allow emulator bootstrap retries, but never retry a started smoke command."""

import argparse
import subprocess
from pathlib import Path


def run_once(marker: Path, command: list[str]) -> int:
    if not command:
        raise ValueError("A smoke command is required")
    try:
        # Exclusive creation also protects concurrent attempts. An interrupted
        # process retains this marker: an unknown test outcome cannot be PASS.
        with marker.open("x") as file:
            file.write("started\n")
    except FileExistsError:
        print("::error title=Smoke retry refused::This job already started its smoke test; preserve the first result.")
        return 1
    try:
        result = subprocess.run(command, check=False)
    except OSError:
        print("::error title=Smoke launch failed::The smoke command could not start; no second attempt is permitted.")
        return 127
    code = result.returncode if result.returncode >= 0 else 128 - result.returncode
    marker.write_text(f"completed exit={code}\n")
    return code


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("marker", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("A smoke command is required")
    raise SystemExit(run_once(args.marker, command))
