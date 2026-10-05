#!/usr/bin/env python3
"""Require a real app + both extensions in the unsigned Flutter archive."""

from __future__ import annotations

import argparse
import json
import plistlib
from pathlib import Path


def verify_archive(
    archive: Path, *, bundle_id: str | None = None, app_group: str | None = None
) -> Path:
    if not archive.is_dir():
        raise ValueError("Expected Runner.xcarchive is missing")
    applications = list((archive / "Products/Applications").glob("*.app"))
    if len(applications) != 1:
        raise ValueError("Archive must contain exactly one Runner application")
    application = applications[0]
    expected = [(application, "15.0", None)]
    expected.extend(
        (application / "PlugIns" / f"{name}.appex", minimum, suffix)
        for name, minimum, suffix in (
            ("ShareExtension", "16.0", ".ShareExtension"),
            ("WidgetExtension", "17.0", ".Widget"),
        )
    )
    app_id = None
    for bundle, minimum, suffix in expected:
        with (bundle / "Info.plist").open("rb") as file:
            metadata = plistlib.load(file)
        identifier = metadata.get("CFBundleIdentifier")
        if not isinstance(identifier, str) or not identifier:
            raise ValueError("Compiled bundle identifier is missing")
        if suffix is None:
            app_id = identifier
            if bundle_id is not None and identifier != bundle_id:
                raise ValueError("Runner identity differs from existing fork branding")
        elif identifier != f"{app_id}{suffix}":
            raise ValueError("Extension identity is inconsistent with Runner")
        if app_group is not None and metadata.get("AppGroupId") != app_group:
            raise ValueError("Compiled App Group differs from existing fork branding")
        if metadata.get("MinimumOSVersion") != minimum:
            raise ValueError(
                "Compiled bundle deployment floor differs from product policy"
            )
        executable = metadata.get("CFBundleExecutable")
        if not isinstance(executable, str) or Path(executable).name != executable:
            raise ValueError("Compiled bundle executable name is invalid")
        binary = bundle / executable
        if not binary.is_file() or binary.stat().st_size == 0:
            raise ValueError("Compiled bundle executable is missing or empty")
    return application


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--branding-config", type=Path)
    args = parser.parse_args()
    try:
        branding = (
            json.loads(args.branding_config.read_text())["mobile"]
            if args.branding_config
            else {}
        )
        verify_archive(
            args.archive,
            bundle_id=branding.get("bundle_id"),
            app_group=branding.get("shared_group"),
        )
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"iOS archive verification failed: {error}\n")


if __name__ == "__main__":
    main()
