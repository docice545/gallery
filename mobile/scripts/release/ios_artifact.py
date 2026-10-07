"""Owned, bounded IPA inspection shared by release and SideStore preparation.

This module does not sign, install or modify the source IPA.
"""

from __future__ import annotations

import hashlib
import os
import plistlib
import shutil
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from package_unsigned_ios import _bundle_entries  # noqa: E402
from verify_ios_archive import verify_archive  # noqa: E402

BUNDLE_ID = "de.opennoodle.gallery"
APP_GROUP = "group.de.opennoodle.gallery.share"
MAX_UNPACKED_BYTES = 8 * 1024**3
MAX_ENTRIES = 100_000


def sha256(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise ValueError("IPA must be a real regular file")
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def extract_ipa(ipa: Path, archive: Path) -> Path:
    """Extract only Payload into an empty synthetic archive, links last.

    No ZIP member is ever written through a symlink. Framework links may be
    relative and owned, but cannot escape, be dangling, or form a cycle.
    """
    sha256(ipa)
    if archive.exists() or archive.is_symlink():
        raise ValueError("IPA staging archive must not already exist")
    application_root = archive / "Products/Applications"
    with zipfile.ZipFile(ipa) as package:
        entries = package.infolist()
        if not entries or len(entries) > MAX_ENTRIES:
            raise ValueError("IPA entry count exceeds the bounded policy")
        if sum(entry.file_size for entry in entries) > MAX_UNPACKED_BYTES:
            raise ValueError("IPA unpacked size exceeds the bounded policy")
        normalized = {}
        links = set()
        applications = set()
        for entry in entries:
            name = entry.filename.rstrip("/")
            parts = PurePosixPath(name).parts
            if (
                not parts
                or parts[0] != "Payload"
                or name.startswith("/")
                or "\\" in name
                or any(part in {".", "..", ""} for part in name.split("/"))
                or any(ord(letter) < 32 for letter in name)
                or entry.flag_bits & 1
                or name in normalized
            ):
                raise ValueError("IPA contains an unsafe, duplicate or encrypted entry")
            if len(parts) > 1:
                if not parts[1].endswith(".app"):
                    raise ValueError(
                        "IPA Payload must contain only the Runner application"
                    )
                applications.add(parts[1])
            mode = entry.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if kind not in {0, stat.S_IFDIR, stat.S_IFREG, stat.S_IFLNK}:
                raise ValueError("IPA contains an unsupported filesystem entry")
            if stat.S_ISLNK(mode):
                if entry.file_size > 4096:
                    raise ValueError("IPA link target is too large")
                links.add(name)
            normalized[name] = (entry, mode, parts)
        if len(applications) != 1:
            raise ValueError("IPA must contain exactly one Runner application")
        for name, (_, _, parts) in normalized.items():
            if any("/".join(parts[:end]) in links for end in range(1, len(parts))):
                raise ValueError("IPA entry cannot be a child of a symlink")
            if name in links:
                target = os.fsdecode(package.read(normalized[name][0]))
                if (
                    not target
                    or os.path.isabs(target)
                    or "\\" in target
                    or "\x00" in target
                ):
                    raise ValueError(
                        "IPA framework link must have an owned relative target"
                    )
        application_root.mkdir(parents=True)
        for name, (entry, mode, parts) in sorted(normalized.items()):
            if name == "Payload" or name in links:
                continue
            destination = application_root.joinpath(*parts[1:])
            if entry.is_dir() or stat.S_ISDIR(mode):
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                with package.open(entry) as source, destination.open("xb") as output:
                    shutil.copyfileobj(source, output, length=1024 * 1024)
                destination.chmod(0o755 if mode & 0o111 else 0o644)
        for name in sorted(links):
            entry, _, parts = normalized[name]
            destination = application_root.joinpath(*parts[1:])
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.symlink_to(os.fsdecode(package.read(entry)))
    application = application_root / next(iter(applications))
    if application.is_symlink() or not application.is_dir():
        raise ValueError("Runner application root must be an owned real directory")
    _bundle_entries(application)
    return application


def bundles(application: Path) -> list[Path]:
    extensions = application / "PlugIns"
    expected = [
        extensions / "ShareExtension.appex",
        extensions / "WidgetExtension.appex",
    ]
    if set(extensions.glob("*.appex")) != set(expected):
        raise ValueError("IPA must preserve exactly ShareExtension and WidgetExtension")
    return [application, *expected]


def verify_ipa_archive(
    archive: Path, *, version: str, build: str, group: str = APP_GROUP
) -> Path:
    application = verify_archive(
        archive,
        bundle_id=BUNDLE_ID,
        app_group=group,
        expected_version=version,
        expected_build=build,
        expected_display_name="Foto",
        expected_russian_display_name="Фото",
    )
    _bundle_entries(application)
    for bundle in bundles(application):
        metadata = plistlib.loads((bundle / "Info.plist").read_bytes())
        for key in ("CFBundleDisplayName", "CFBundleName"):
            value = metadata.get(key)
            if value is not None and (
                not isinstance(value, str)
                or not value
                or not value.isascii()
                or any(ord(letter) < 32 for letter in value)
            ):
                raise ValueError(
                    "Registration-facing base names must be nonempty printable ASCII"
                )
    if any(application.rglob("embedded.mobileprovision")):
        raise ValueError(
            "Expected unsigned IPA; embedded Apple profiles are not permitted"
        )
    return application
