#!/usr/bin/env python3
"""Prepare a separate ad-hoc seed IPA for the documented free SideStore pilot.

The output still needs SideStore/Apple Personal Team device signing. No paid
credentials, profiles or certificates are read. Original IPA and normal iOS
configuration remain unchanged. macOS codesign is required for preparation.
"""

from __future__ import annotations

import argparse
import json
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

from ios_artifact import (
    APP_GROUP,
    BUNDLE_ID,
    bundles,
    extract_ipa,
    sha256,
    verify_ipa_archive,
)

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from package_unsigned_ios import package_unsigned_archive  # noqa: E402

STOCK_TEAMS = {"77MWNP37MV", "2W7AC6T8T5"}
SEED_ENTITLEMENTS = {"com.apple.security.application-groups": [APP_GROUP]}


def validate_team(team: str) -> None:
    if (
        not re.fullmatch(r"[A-Z0-9]{10}", team)
        or team in STOCK_TEAMS
        or team in {"TEAMID0000", "ABCDEFGHIJ"}
    ):
        raise ValueError(
            "Use the actual selected Apple Personal Team ID, not a placeholder or Gallery stock Team"
        )


def patch_seed(application: Path, team: str) -> None:
    """Only custom consumer metadata changes; SideStore maps native identities."""
    validate_team(team)
    for bundle in bundles(application):
        metadata_file = bundle / "Info.plist"
        raw = metadata_file.read_bytes()
        metadata = plistlib.loads(raw)
        if metadata.get("AppGroupId") != APP_GROUP:
            raise ValueError(
                "Input IPA has already been prepared or uses another App Group"
            )
        metadata["AppGroupId"] = f"{APP_GROUP}.{team}"
        if bundle == application:
            scheme = f"ShareMedia-{BUNDLE_ID}.{team}"
            entries = metadata.setdefault("CFBundleURLTypes", [])
            if not isinstance(entries, list) or any(
                not isinstance(entry, dict) for entry in entries
            ):
                raise ValueError(
                    "Runner URL scheme metadata has an unexpected structure"
                )
            if not any(
                scheme in entry.get("CFBundleURLSchemes", []) for entry in entries
            ):
                entries.append(
                    {
                        "CFBundleURLName": "Gallery SideStore handoff",
                        "CFBundleURLSchemes": [scheme],
                    }
                )
        metadata_file.write_bytes(
            plistlib.dumps(
                metadata,
                fmt=plistlib.FMT_BINARY
                if raw.startswith(b"bplist")
                else plistlib.FMT_XML,
            )
        )


def sign_seed(application: Path, workspace: Path) -> None:
    entitlement_file = workspace / "seed-entitlements.plist"
    entitlement_file.write_bytes(plistlib.dumps(SEED_ENTITLEMENTS))
    nested = {
        path.resolve(strict=True)
        for path in application.rglob("*")
        if not path.is_symlink()
        and (path.suffix == ".framework" or path.suffix == ".dylib")
    }
    for path in sorted(nested, key=lambda item: (-len(item.parts), str(item))):
        subprocess.run(
            ["codesign", "--force", "--sign", "-", "--timestamp=none", str(path)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    # Nested code first. Unsuffixed seed entitlement is intentional: SideStore
    # appends the selected Team once, while Gallery's custom plist is pre-mapped.
    for bundle in [*bundles(application)[1:], application]:
        subprocess.run(
            [
                "codesign",
                "--force",
                "--sign",
                "-",
                "--timestamp=none",
                "--generate-entitlement-der",
                "--entitlements",
                str(entitlement_file),
                str(bundle),
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        result = subprocess.run(
            ["codesign", "-d", "--entitlements", ":-", str(bundle)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if plistlib.loads(result.stdout) != SEED_ENTITLEMENTS:
            raise ValueError("Ad-hoc seed signature has unexpected entitlements")
    subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(application)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def prepare(args: argparse.Namespace) -> dict:
    validate_team(args.team_id)
    if not re.fullmatch(r"[a-fA-F0-9]{64}", args.input_sha256):
        raise ValueError(
            "Expected input SHA-256 must be the actual 64-character IPA digest"
        )
    digest = sha256(args.ipa)
    if digest != args.input_sha256.lower():
        raise ValueError("Original IPA SHA-256 does not match; no output created")
    if args.ipa.resolve() == args.output.resolve() or args.output.is_symlink():
        raise ValueError(
            "Prepared output must be a separate file, never the original IPA"
        )
    manifest_file = args.output.with_suffix(".manifest.json")
    identity = {
        "input_sha256": digest,
        "team_id": args.team_id,
        "version": args.version,
        "build": args.build,
    }
    if args.output.exists() and not args.check_only:
        if not manifest_file.is_file() or manifest_file.is_symlink():
            raise ValueError(
                "Existing output lacks a trusted preparation manifest; choose another output"
            )
        previous = json.loads(manifest_file.read_text())
        if any(
            previous.get(key) != value for key, value in identity.items()
        ) or previous.get("sha256") != sha256(args.output):
            raise ValueError(
                "Existing prepared output differs from requested identity; refusing to overwrite"
            )
        return {**previous, "status": "PASS: matching prepared output already exists"}
    with tempfile.TemporaryDirectory(prefix="gallery-sidestore-") as temporary:
        workspace = Path(temporary)
        archive = workspace / "Runner.xcarchive"
        application = extract_ipa(args.ipa, archive)
        verify_ipa_archive(archive, version=args.version, build=args.build)
        original = {
            bundle: plistlib.loads((bundle / "Info.plist").read_bytes())
            for bundle in bundles(application)
        }
        patch_seed(application, args.team_id)
        verify_ipa_archive(
            archive,
            version=args.version,
            build=args.build,
            group=f"{APP_GROUP}.{args.team_id}",
        )
        for bundle, old in original.items():
            current = plistlib.loads((bundle / "Info.plist").read_bytes())
            for key in (
                "CFBundleIdentifier",
                "BGTaskSchedulerPermittedIdentifiers",
                "CFBundleDisplayName",
                "CFBundleName",
            ):
                if old.get(key) != current.get(key):
                    raise ValueError(
                        "Preparation changed a protected identity/name/background identifier"
                    )
        if args.check_only:
            return {
                **identity,
                "status": "PASS: input/metadata/seed mapping; PREPARED BUT NEEDS MACOS CODESIGN VALIDATION",
            }
        if platform.system() != "Darwin" or shutil.which("codesign") is None:
            raise ValueError(
                "PREPARED BUT NEEDS MACOS VALIDATION: macOS codesign is required; no output created"
            )
        if (
            args.output.suffix.lower() != ".ipa"
            or "sidestore-seed-unsigned" not in args.output.stem.lower()
        ):
            raise ValueError("Output must be named *-SideStore-seed-unsigned.ipa")
        if manifest_file.exists() or manifest_file.is_symlink():
            raise ValueError(
                "Output manifest already exists; refusing to replace another release"
            )
        sign_seed(application, workspace)
        package_unsigned_archive(
            archive,
            args.output,
            bundle_id=BUNDLE_ID,
            app_group=f"{APP_GROUP}.{args.team_id}",
            expected_version=args.version,
            expected_build=args.build,
        )
        prepared = {
            **identity,
            "sha256": sha256(args.output),
            "artifact": str(args.output.absolute()),
            "status": "PASS: ad-hoc seed verified; SideStore Personal Team signing still required",
            "app_group": f"{APP_GROUP}.{args.team_id}",
            "extension_option": "Keep App Extensions (Register App ID for Each Extension)",
        }
        with manifest_file.open("x") as output:
            json.dump(prepared, output, indent=2, ensure_ascii=False)
            output.write("\n")
        return prepared


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--input-sha256", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Offline validation only; creates no output or signature",
    )
    args = parser.parse_args()
    if sys.version_info < (3, 11):
        parser.exit(1, "FAIL: Python 3.11 or newer is required\n")
    try:
        result = prepare(args)
    except (
        ValueError,
        OSError,
        zipfile.BadZipFile,
        plistlib.InvalidFileException,
        subprocess.CalledProcessError,
    ) as error:
        # Do not dump codesign stderr/profile/private paths into release logs.
        message = (
            str(error)
            if not isinstance(error, subprocess.CalledProcessError)
            else "macOS codesign failed; no successful seed handoff"
        )
        parser.exit(1, f"FAIL: {message}\n")
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
