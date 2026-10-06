#!/usr/bin/env python3
"""Package a verified unsigned archive for user-side Personal Team signing."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import shutil
import stat
import tempfile
import zipfile
from pathlib import Path

from verify_ios_archive import verify_archive

ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)


def _owned_application(archive: Path) -> tuple[Path, Path]:
    if archive.is_symlink() or not archive.is_dir():
        raise ValueError("Unsigned archive must be a real directory")
    archive = archive.resolve(strict=True)
    directory = archive
    for part in ("Products", "Applications"):
        directory /= part
        if directory.is_symlink() or not directory.is_dir():
            raise ValueError("Archive application roots must be real directories")
    applications = list(directory.glob("*.app"))
    if len(applications) != 1:
        raise ValueError("Archive must contain exactly one Runner application")
    application = applications[0]
    if application.is_symlink() or not application.is_dir():
        raise ValueError("Runner application root must be a real directory")
    if not application.resolve(strict=True).is_relative_to(archive):
        raise ValueError("Runner application must stay inside its archive")
    return archive, application


def _bundle_entries(application: Path) -> list[tuple[Path, os.stat_result]]:
    """Do not follow framework links; preserve only valid bundle-owned links."""
    entries = [(application, application.lstat())]

    def visit(directory: Path) -> None:
        for child in sorted(directory.iterdir(), key=lambda entry: entry.name):
            if "\\" in child.name or any(ord(letter) < 32 for letter in child.name):
                raise ValueError("Bundle contains an unsafe ZIP entry name")
            status = child.lstat()
            if stat.S_ISLNK(status.st_mode):
                target = os.readlink(child)
                if os.path.isabs(target) or "\\" in target:
                    raise ValueError("Bundle links must use relative owned targets")
                try:
                    resolved = child.resolve(strict=True)
                except (OSError, RuntimeError) as error:
                    raise ValueError("Bundle contains an invalid link") from error
                if not resolved.is_relative_to(application):
                    raise ValueError("Bundle link escapes its application")
            elif not (stat.S_ISDIR(status.st_mode) or stat.S_ISREG(status.st_mode)):
                raise ValueError("Bundle contains an unsupported filesystem entry")
            entries.append((child, status))
            if stat.S_ISDIR(status.st_mode):
                visit(child)

    visit(application)
    return sorted(
        entries,
        key=lambda entry: entry[0].relative_to(application.parent).as_posix(),
    )


def _zip_info(name: str, mode: int) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, date_time=ZIP_TIMESTAMP)
    info.create_system = 3
    info.external_attr = mode << 16
    if stat.S_ISDIR(mode):
        info.external_attr |= 0x10
    info.compress_type = zipfile.ZIP_DEFLATED
    return info


def package_unsigned_archive(
    archive: Path,
    output: Path,
    *,
    bundle_id: str | None = None,
    app_group: str | None = None,
    expected_version: str | None = None,
    expected_build: str | None = None,
    app_icon_catalog: Path | None = None,
) -> Path:
    archive, application = _owned_application(archive)
    # Validate ownership before the verifier reads plists/executables through
    # any links, and before opening output. The original archive stays intact.
    entries = _bundle_entries(application)
    verified = verify_archive(
        archive,
        bundle_id=bundle_id,
        app_group=app_group,
        expected_version=expected_version,
        expected_build=expected_build,
        app_icon_catalog=app_icon_catalog,
    )
    if verified != application:
        raise ValueError("Verified application differs from package source")
    if output.suffix.lower() != ".ipa" or "unsigned" not in output.stem.lower():
        raise ValueError("Output must be explicitly named as an unsigned IPA")
    if output.is_symlink():
        raise ValueError("Unsigned IPA output must not be a symlink")
    output = output.absolute()
    if output.resolve().is_relative_to(archive):
        raise ValueError("Unsigned IPA output must stay outside its source archive")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            prefix=".unsigned-ios-", suffix=".ipa", dir=output.parent, delete=False
        ) as file:
            temporary = Path(file.name)
        with zipfile.ZipFile(
            temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6
        ) as package:
            package.writestr(_zip_info("Payload/", stat.S_IFDIR | 0o755), b"")
            for source, status in entries:
                name = "Payload/" + source.relative_to(application.parent).as_posix()
                if stat.S_ISDIR(status.st_mode):
                    package.writestr(_zip_info(name + "/", stat.S_IFDIR | 0o755), b"")
                elif stat.S_ISLNK(status.st_mode):
                    package.writestr(
                        _zip_info(name, stat.S_IFLNK | 0o777),
                        os.fsencode(os.readlink(source)),
                    )
                else:
                    mode = 0o755 if status.st_mode & 0o111 else 0o644
                    info = _zip_info(name, stat.S_IFREG | mode)
                    info.file_size = status.st_size
                    with (
                        source.open("rb") as original,
                        package.open(
                            info,
                            "w",
                            force_zip64=status.st_size >= zipfile.ZIP64_LIMIT,
                        ) as copied,
                    ):
                        shutil.copyfileobj(original, copied, length=1024 * 1024)
        with zipfile.ZipFile(temporary) as package:
            if package.testzip() is not None:
                raise ValueError("Unsigned IPA ZIP integrity verification failed")
        if not temporary.is_file() or temporary.stat().st_size == 0:
            raise ValueError("Unsigned IPA output is missing or empty")
        temporary.replace(output)
        return output
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--branding-config", type=Path)
    parser.add_argument("--expected-version")
    parser.add_argument("--expected-build")
    parser.add_argument("--app-icon-catalog", type=Path)
    args = parser.parse_args()
    try:
        branding = (
            json.loads(args.branding_config.read_text())["mobile"]
            if args.branding_config
            else {}
        )
        output = package_unsigned_archive(
            args.archive,
            args.output,
            bundle_id=branding.get("bundle_id"),
            app_group=branding.get("shared_group"),
            expected_version=args.expected_version,
            expected_build=args.expected_build,
            app_icon_catalog=args.app_icon_catalog,
        )
        with output.open("rb") as file:
            digest = hashlib.file_digest(file, "sha256").hexdigest()
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"Unsigned iOS packaging failed: {error}\n")
    print(f"Unsigned IPA package: {output}")
    print(f"SHA-256: {digest}")
    print("Requires user-side Personal Team signing; this IPA is not installable yet.")
    print(
        "::notice title=iOS unsigned IPA packaged::"
        f"SHA-256 {digest}; requires user-side signing before installation."
    )


if __name__ == "__main__":
    main()
