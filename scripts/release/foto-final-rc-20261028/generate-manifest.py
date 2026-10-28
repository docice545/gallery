#!/usr/bin/env python3
"""Generate a local release manifest from a clean checkout.

The output contains the exact source SHA and SHA-256 values of the reviewed
source/document files. It never contacts HP or writes outside the requested
output path.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    if subprocess.check_output(["git", "-C", str(root), "status", "--porcelain"], text=True):
        raise SystemExit("BLOCKED dirty checkout")
    source = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    files = [
        "mobile/pubspec.yaml",
        "server/src/services/asset.service.ts",
        "server/src/repositories/asset.repository.ts",
        "scripts/external-upload-dedup/hp-readonly-audit.py",
        "docs/foto-final/RELEASE_GATES.md",
    ]
    checksums = {}
    for relative in files:
        path = root / relative
        checksums[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    payload = {
        "schemaVersion": 1,
        "repository": "docice545/gallery",
        "branch": subprocess.check_output(["git", "-C", str(root), "branch", "--show-current"], text=True).strip(),
        "sourceSha": source,
        "checksums": checksums,
        "productionChanged": False,
        "hpOperationsExecuted": False,
        "apkBuildExecuted": False,
        "releaseGates": json.loads((root / "release-manifest-20261028.json").read_text())["releaseGates"],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"sourceSha": source, "output": str(args.output), "productionChanged": False}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
