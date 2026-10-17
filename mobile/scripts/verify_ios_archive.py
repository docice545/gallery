#!/usr/bin/env python3
"""Require a real app + both extensions in the unsigned Flutter archive."""

from __future__ import annotations

import argparse
import json
import plistlib
import struct
from decimal import Decimal, InvalidOperation
from pathlib import Path


def verify_app_icon_catalog(catalog: Path) -> None:
    """Check the actual branded PNG pixels against every assigned catalog slot."""
    contents = json.loads((catalog / "Contents.json").read_text())
    slots = set()
    marketing_icon = False
    for image in contents["images"]:
        filename = image.get("filename")
        if not filename:
            if image.get("idiom") in {"iphone", "ipad", "ios-marketing"}:
                raise ValueError("An iOS app icon slot has no assigned image")
            continue
        if not isinstance(filename, str) or Path(filename).name != filename:
            raise ValueError("App icon filename must stay inside its owned catalog")
        slot = tuple(
            image.get(key) for key in ("idiom", "size", "scale", "role", "subtype")
        )
        if slot in slots:
            raise ValueError("App icon catalog has duplicate assigned slots")
        slots.add(slot)
        try:
            logical_width, logical_height = map(Decimal, image["size"].split("x"))
            scale = Decimal(image["scale"].removesuffix("x"))
        except (KeyError, ValueError, InvalidOperation) as error:
            raise ValueError("App icon catalog has invalid size/scale") from error
        raw = (catalog / filename).read_bytes()
        if (
            len(raw) < 33
            or raw[:8] != b"\x89PNG\r\n\x1a\n"
            or raw[8:16] != b"\x00\x00\x00\rIHDR"
        ):
            raise ValueError("App icon is not a valid PNG")
        width, height = struct.unpack(">II", raw[16:24])
        if (Decimal(width), Decimal(height)) != (
            logical_width * scale,
            logical_height * scale,
        ):
            raise ValueError(f"App icon pixels differ from catalog slot: {filename}")
        if image.get("idiom") == "ios-marketing":
            if (width, height) != (1024, 1024) or scale != 1:
                raise ValueError("iOS marketing icon must be 1024 x 1024 at 1x")
            if raw[25] in {4, 6}:
                raise ValueError("iOS marketing icon must have no alpha channel")
            marketing_icon = True
    if not marketing_icon:
        raise ValueError("iOS marketing app icon is missing")


def verify_compiled_app_icon(application: Path, metadata: dict) -> None:
    primary = metadata.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {})
    if primary.get("CFBundleIconName") != "AppIcon":
        raise ValueError("Compiled Runner app icon is missing or has another name")
    names = primary.get("CFBundleIconFiles", [])
    if not names or any(
        not isinstance(name, str) or Path(name).name != name for name in names
    ):
        raise ValueError("Compiled Runner app icon file names are missing or invalid")
    for name in names:
        if not any(
            icon.is_file() and icon.stat().st_size > 0
            for icon in application.glob(f"{name}*.png")
        ):
            raise ValueError("Compiled Runner app icon image is missing or empty")
    assets = application / "Assets.car"
    if not assets.is_file() or assets.stat().st_size == 0:
        raise ValueError("Compiled Runner asset catalog is missing or empty")


def verify_archive(
    archive: Path,
    *,
    bundle_id: str | None = None,
    app_group: str | None = None,
    expected_version: str | None = None,
    expected_build: str | None = None,
    app_icon_catalog: Path | None = None,
    expected_display_name: str | None = None,
    expected_russian_display_name: str | None = None,
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
        if expected_display_name is not None:
            # SideSign reads the raw plist, not localizedInfoDictionary. Apple
            # registration also prefixes extension names with the parent name.
            registration_name = metadata.get("CFBundleDisplayName")
            if not isinstance(registration_name, str):
                registration_name = metadata.get("CFBundleName")
            if (
                not isinstance(registration_name, str)
                or not registration_name
                or not registration_name.isascii()
            ):
                raise ValueError("Compiled App ID registration name must be nonempty ASCII")
            if suffix is None and registration_name != expected_display_name:
                raise ValueError("Compiled Runner base display name differs from expected registration name")
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
        if (
            expected_version is not None
            and metadata.get("CFBundleShortVersionString") != expected_version
        ):
            raise ValueError("Compiled bundle version differs from Flutter build name")
        if (
            expected_build is not None
            and metadata.get("CFBundleVersion") != expected_build
        ):
            raise ValueError("Compiled bundle build differs from Flutter build number")
        executable = metadata.get("CFBundleExecutable")
        if not isinstance(executable, str) or Path(executable).name != executable:
            raise ValueError("Compiled bundle executable name is invalid")
        binary = bundle / executable
        if not binary.is_file() or binary.stat().st_size == 0:
            raise ValueError("Compiled bundle executable is missing or empty")
        if suffix is None and app_icon_catalog is not None:
            verify_app_icon_catalog(app_icon_catalog)
            verify_compiled_app_icon(application, metadata)
    if expected_russian_display_name is not None:
        localized = plistlib.loads(
            (application / "ru.lproj/InfoPlist.strings").read_bytes()
        )
        if localized.get("CFBundleDisplayName") != expected_russian_display_name:
            raise ValueError("Compiled Russian display name differs from expected user-facing name")
    return application


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--branding-config", type=Path)
    parser.add_argument("--expected-version")
    parser.add_argument("--expected-build")
    parser.add_argument("--app-icon-catalog", type=Path)
    parser.add_argument("--expected-display-name")
    parser.add_argument("--expected-russian-display-name")
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
            expected_version=args.expected_version,
            expected_build=args.expected_build,
            app_icon_catalog=args.app_icon_catalog,
            expected_display_name=args.expected_display_name,
            expected_russian_display_name=args.expected_russian_display_name,
        )
        if args.expected_display_name is not None:
            print(
                "Verified ASCII App ID registration names; "
                f"Runner base={args.expected_display_name}; "
                f"Russian display={args.expected_russian_display_name}"
            )
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"iOS archive verification failed: {error}\n")


if __name__ == "__main__":
    main()
