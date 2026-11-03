#!/usr/bin/env python3
"""Inspect a CI APK without signing it or claiming device/release acceptance."""

import argparse
import hashlib
import json
import re
import shlex
import subprocess
import zipfile
from pathlib import Path

ABIS = {"armeabi-v7a", "arm64-v8a", "x86_64"}


def inspect(apk: Path, badging: str, version: str, build: str) -> dict:
    if apk.is_symlink() or not apk.is_file():
        raise ValueError("APK must be a regular file")
    package = next(
        (line for line in badging.splitlines() if line.startswith("package:")), ""
    )
    fields = dict(
        item.split("=", 1) for item in shlex.split(package)[1:] if "=" in item
    )
    if (fields.get("name"), fields.get("versionName"), fields.get("versionCode")) != (
        "de.opennoodle.gallery",
        version,
        build,
    ):
        raise ValueError("Actual APK package/version differs from the reviewed source")
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or archive.testzip() is not None:
            raise ValueError("APK has duplicate or corrupt entries")
        if "AndroidManifest.xml" not in names:
            raise ValueError("APK manifest is missing")
        for name in names:
            upper = name.upper()
            if upper.startswith("META-INF/") and (
                upper.endswith((".SF", ".RSA", ".DSA", ".EC"))
                or upper.removeprefix("META-INF/").startswith("SIG-")
            ):
                raise ValueError(
                    "APK contains a v1 signature; expected unsigned output"
                )
        # Android's v2/v3 signing block ends immediately before the central
        # directory. Reject any such block, even an invalid/unknown signer.
        with apk.open("rb") as source:
            source.seek(max(0, archive.start_dir - 16))
            if source.read(16) == b"APK Sig Block 42":
                raise ValueError(
                    "APK contains a signing block; expected unsigned output"
                )
        actual_abis = {
            name.split("/")[1]
            for name in names
            if name.startswith("lib/") and name.endswith(".so")
        }
        if actual_abis != ABIS:
            raise ValueError("APK must contain all three universal Android ABIs")
        for abi in ABIS:
            for library in ("libflutter.so", "libapp.so", "libsqlite3.so"):
                name = f"lib/{abi}/{library}"
                if name not in names or archive.getinfo(name).file_size == 0:
                    raise ValueError(
                        f"APK is missing a required native library: {name}"
                    )
    with apk.open("rb") as source:
        checksum = hashlib.file_digest(source, "sha256").hexdigest()
    return {
        "applicationId": fields["name"],
        "versionName": version,
        "versionCode": int(build),
        "abis": sorted(ABIS),
        "sha256": checksum,
        "bytes": apk.stat().st_size,
        "signing": "UNSIGNED",
        "deviceAcceptance": "NOT_TESTED",
        "releaseReady": False,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--aapt", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.expected_commit):
        parser.error("Expected commit must be a full SHA")
    root = Path(__file__).resolve().parents[2]
    head = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True
    ).strip()
    if head != args.expected_commit:
        parser.error("Checkout differs from expected commit")
    badging = subprocess.check_output(
        [str(args.aapt), "dump", "badging", str(args.apk)], text=True
    )
    result = {
        **inspect(args.apk, badging, args.version, args.build),
        "sourceCommit": head,
    }
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    args.output.with_suffix(".sha256").write_text(
        f"{result['sha256']}  {args.apk.name}\n"
    )
    print(
        "PASS unsigned universal APK identity and checksum; signing and device acceptance remain pending"
    )


if __name__ == "__main__":
    main()
