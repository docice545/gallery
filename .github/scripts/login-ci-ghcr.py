#!/usr/bin/env python3
"""Authenticate disposable hosted CI; retry only transient registry transport."""

import os
import re
import subprocess
import time


TRANSIENT = re.compile(r"timeout|timed out|connection reset|connection refused|temporary failure|toomanyrequests|too many requests|(?:status|code|error)[^\n]{0,25}\b(?:429|500|502|503|504)\b", re.I)
DENIED = re.compile(r"unauthorized|forbidden|denied|incorrect username|invalid (?:token|password|credentials)", re.I)


def authenticate() -> int:
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
        raise ValueError("GHCR helper is restricted to disposable GitHub-hosted CI")
    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        raise ValueError("GitHub job token is required; no credentials are generated")
    for attempt in range(1, 4):
        try:
            result = subprocess.run(
                ["docker", "login", "ghcr.io", "-u", "github-actions", "--password-stdin"],
                input=token + "\n", text=True, capture_output=True, timeout=45, check=False,
            )
            code = result.returncode
            diagnostic = result.stdout + result.stderr
        except subprocess.TimeoutExpired:
            code, diagnostic = 124, "Registry login timed out before any smoke test started"
        diagnostic = diagnostic.replace(token, "[REDACTED]")
        # Treat captured output as data, never as additional workflow commands.
        diagnostic = diagnostic[-2400:].replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        if code == 0:
            print("PASS hosted GHCR authentication")
            return 0
        retry = attempt < 3 and not DENIED.search(diagnostic) and TRANSIENT.search(diagnostic)
        level = "warning" if retry else "error"
        print(f"::{level} title=Hosted GHCR authentication::{diagnostic}")
        if not retry:
            return code
        time.sleep(attempt * 2)
    raise AssertionError("Authentication loop must return")


if __name__ == "__main__":
    try:
        raise SystemExit(authenticate())
    except ValueError as error:
        raise SystemExit(str(error))
