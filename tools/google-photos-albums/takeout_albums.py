#!/usr/bin/env python3
"""Prepare an owner-scoped, offline Google Takeout album mapping. No apply mode."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tempfile
from datetime import datetime
from typing import Any
from uuid import UUID


SCHEMA_VERSION = 1
MAX_JSON_BYTES = 16 * 1024 * 1024
IMAGE_SUFFIXES = {
    ".3fr",
    ".ari",
    ".arw",
    ".cap",
    ".cin",
    ".cr2",
    ".cr3",
    ".crw",
    ".dcr",
    ".erf",
    ".fff",
    ".iiq",
    ".k25",
    ".kdc",
    ".mrw",
    ".nef",
    ".nrw",
    ".orf",
    ".ori",
    ".pef",
    ".psd",
    ".raf",
    ".raw",
    ".rw2",
    ".rwl",
    ".sr2",
    ".srf",
    ".srw",
    ".x3f",
    ".hif",
    ".insp",
    ".jp2",
    ".jpe",
    ".jxl",
    ".mpo",
    ".svg",
    ".jpg",
    ".jpeg",
    ".heic",
    ".heif",
    ".png",
    ".webp",
    ".gif",
    ".avif",
    ".tif",
    ".tiff",
    ".dng",
    ".bmp",
}
VIDEO_SUFFIXES = {
    ".3gpp",
    ".flv",
    ".insv",
    ".m2t",
    ".mpe",
    ".mxf",
    ".ts",
    ".vob",
    ".wmv",
    ".mp4",
    ".mov",
    ".m4v",
    ".avi",
    ".mkv",
    ".webm",
    ".3gp",
    ".mts",
    ".m2ts",
    ".mpg",
    ".mpeg",
}
SERVICE_NAMES = {
    "takeout",
    "google photos",
    "photos",
    "albums",
    "archive",
    "trash",
    "favorites",
    "фото google",
    "корзина",
    "архив",
}
PHOTOS_ROOT_NAMES = {
    "google photos",
    "фото google",
    "google fotos",
    "google foto",
    "google fotografie",
    "google 照片",
    "google 相簿",
}
YEAR_DIRECTORY = re.compile(
    r"^(?:photos from |фотографии за |фото за )?\d{4}$", re.IGNORECASE
)


class MappingError(ValueError):
    """Invalid scope, inventory, or unsafe output; stop without writing."""


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def stable_key(kind: str, value: Any) -> str:
    digest = hashlib.sha256(canonical_json(value).encode()).hexdigest()
    return f"{kind}:{digest}"


def owner_uuid(value: Any) -> str:
    try:
        return str(UUID(value))
    except (ValueError, TypeError, AttributeError) as error:
        raise MappingError("An explicit, valid owner UUID is required") from error


def load_json(path: Path, max_bytes: int = MAX_JSON_BYTES) -> Any:
    if path.stat().st_size > max_bytes:
        raise MappingError(f"JSON exceeds {max_bytes} bytes: {path.name}")
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def timestamp(value: Any) -> float | None:
    if isinstance(value, dict):
        value = value.get("timestamp")
    if isinstance(value, bool) or value is None:
        return None
    try:
        result = float(value)
    except (TypeError, ValueError):
        try:
            parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                return None
            result = parsed.timestamp()
        except (ValueError, TypeError, OverflowError):
            return None
    return result if math.isfinite(result) else None


def positive_integer(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    try:
        number = int(value)
        return number if number > 0 else None
    except (TypeError, ValueError, OverflowError):
        return None


def duration_milliseconds(value: Any) -> int | None:
    """Only explicit integer milliseconds; do not guess seconds or timecodes."""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, str):
        if not re.fullmatch(r"[0-9]{1,10}", value):
            return None
        value = int(value)
    if isinstance(value, int) and 0 <= value <= 2_147_483_647:
        return value
    return None


def content_checksum(value: Any) -> tuple[str, str] | None:
    """Only explicitly identified content hashes are trustworthy for external assets."""
    if not isinstance(value, dict):
        return None
    algorithm = str(value.get("algorithm", "")).lower()
    length = {"sha1": 20, "sha256": 32}.get(algorithm)
    raw = value.get("value")
    if length is None or not isinstance(raw, str):
        return None
    try:
        digest = (
            bytes.fromhex(raw)
            if len(raw) == length * 2
            else base64.b64decode(raw, validate=True)
        )
    except (ValueError, TypeError):
        return None
    return (algorithm, digest.hex()) if len(digest) == length else None


def media_type(name: str) -> str | None:
    suffix = PurePosixPath(name).suffix.lower()
    if suffix in IMAGE_SUFFIXES:
        return "IMAGE"
    if suffix in VIDEO_SUFFIXES:
        return "VIDEO"
    return None


def is_service_directory(name: str) -> bool:
    return name.casefold() in SERVICE_NAMES or bool(YEAR_DIRECTORY.fullmatch(name))


def is_album_metadata(data: dict[str, Any], filename: str) -> bool:
    # A title alone (or the directory name) cannot establish a user-created album.
    if any(
        key in data
        for key in ("photoTakenTime", "creationTime", "googlePhotosOrigin", "url")
    ):
        return False
    access = data.get("access") if isinstance(data.get("access"), str) else None
    return (
        isinstance(data.get("title"), str)
        and bool(data["title"].strip())
        and ("description" not in data or isinstance(data["description"], str))
        and (
            access in {"private", "protected", "public"}
            or isinstance(data.get("date"), dict)
            and timestamp(data["date"]) is not None
            # Newer exports can contain only a title in the known album metadata file.
            # These candidates require human confirmation rather than future auto-apply.
            or filename.casefold() == "metadata.json"
        )
    )


def normalize_path_maps(path_maps: list[dict[str, Any]]) -> list[tuple[str, str]]:
    result = []
    for mapping in path_maps:
        if not isinstance(mapping, dict):
            raise MappingError(
                "Every path map must be a metadataPrefix/assetPrefix object"
            )
        if not isinstance(mapping.get("metadataPrefix"), str) or not isinstance(
            mapping.get("assetPrefix"), str
        ):
            raise MappingError("Path map prefixes must be explicit strings")
        source = str(mapping.get("metadataPrefix", "")).replace("\\", "/").strip("/")
        target = str(mapping.get("assetPrefix", ""))
        if (
            ".." in PurePosixPath(source).parts
            or not target.startswith("/")
            or ".." in PurePosixPath(target).parts
        ):
            raise MappingError(
                "Path maps need a safe relative metadataPrefix and absolute assetPrefix"
            )
        pair = (source, str(PurePosixPath(target)))
        if pair in result:
            continue
        if any(previous[0] == source for previous in result):
            raise MappingError("Conflicting path maps for the same metadataPrefix")
        result.append(pair)
    return sorted(result, key=lambda entry: (-len(entry[0]), entry))


def mapped_path(relative: str, root: Path, path_maps: list[tuple[str, str]]) -> str:
    mapping = source_path_mapping(relative, path_maps)
    if mapping:
        source, target = mapping["metadataPrefix"], mapping["assetPrefix"]
        suffix = relative[len(source) :].lstrip("/") if source else relative
        return str(PurePosixPath(target) / suffix)
    return str(root / relative)


def source_path_mapping(
    relative: str, path_maps: list[tuple[str, str]]
) -> dict[str, str] | None:
    """Record the operator-verified mapping; a metadata staging path is not one."""
    for source, target in path_maps:
        if not source or relative == source or relative.startswith(source + "/"):
            return {"metadataPrefix": source, "assetPrefix": target}
    return None


def read_media_evidence(path: Path, hash_media: bool) -> dict[str, Any]:
    # Media is opened only with an explicit flag, read-only, and streamed in chunks.
    if not hash_media or not path.is_file() or path.is_symlink():
        return {}
    digest = hashlib.sha1()
    total = 0
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
            total += len(chunk)
    return {
        "fileSize": total,
        "contentChecksum": {"algorithm": "sha1", "value": digest.hexdigest()},
    }


def sidecar_media_name(
    filename: str, title: str, directory: Path
) -> tuple[str, str, bool]:
    for suffix in (".supplemental-metadata.json", ".json"):
        if filename.lower().endswith(suffix):
            stem = filename[: -len(suffix)]
            break
    else:
        return title, "Google metadata title", False
    if media_type(stem) is not None:
        candidate = directory / stem
        if candidate.is_file() and not candidate.is_symlink():
            return stem, "existing sidecar-named media file", False
        if re.search(r"(?:^|[-_ ])edited(?:[._ -]|$)", stem, re.IGNORECASE):
            return (
                stem,
                "explicit edited sidecar filename (not the unedited title)",
                False,
            )
    indexed = re.search(
        r"\(\d+\)(?=(?:\.[^.]+)?\.json$)|\.supplemental[^/]*\(\d+\)\.json$",
        filename,
        re.IGNORECASE,
    )
    if indexed and stem != title:
        return (
            title,
            "indexed sidecar filename has unresolved media association; never assume the unindexed original",
            True,
        )
    return (
        title,
        "Google metadata title; sidecar filename may be truncated or transformed",
        False,
    )


def photos_metadata_roots(root: Path, confirmed: bool) -> list[Path]:
    if root.name.casefold() in PHOTOS_ROOT_NAMES or confirmed:
        return [root]
    # Accept a full export only by selecting its known Google Photos subtree,
    # ignoring Gmail/Drive/etc. Do not treat arbitrary directories as photo albums.
    direct = [
        path
        for path in root.iterdir()
        if path.is_dir()
        and not path.is_symlink()
        and path.name.casefold() in PHOTOS_ROOT_NAMES
    ]
    nested = []
    takeout = root / "Takeout"
    if takeout.is_dir() and not takeout.is_symlink():
        nested = [
            path
            for path in takeout.iterdir()
            if path.is_dir()
            and not path.is_symlink()
            and path.name.casefold() in PHOTOS_ROOT_NAMES
        ]
    roots = sorted(direct + nested)
    if not roots:
        raise MappingError(
            "No recognizable Google Photos subtree; use --photos-root-confirmed only for a verified, isolated Photos metadata root"
        )
    return roots


def unreadable_directory(error: OSError) -> None:
    raise MappingError(
        "Cannot read a Takeout directory; refusing an incomplete scan"
    ) from error


def parse_takeout(
    root: Path,
    owner: str,
    path_maps: list[tuple[str, str]],
    hash_media: bool = False,
    photos_root_confirmed: bool = False,
) -> dict[str, Any]:
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise MappingError("Takeout root must be a directory")
    photos_roots = photos_metadata_roots(root, photos_root_confirmed)
    albums: dict[str, dict[str, Any]] = {}
    rows = []
    diagnostics = []
    fingerprints: dict[str, list[str]] = {}
    for directory, dirnames, filenames in os.walk(
        root, followlinks=False, onerror=unreadable_directory
    ):
        dirnames[:] = sorted(
            name for name in dirnames if not (Path(directory) / name).is_symlink()
        )
        current = Path(directory)
        dirnames[:] = [
            name
            for name in dirnames
            if any(
                (current / name) == allowed
                or (current / name).is_relative_to(allowed)
                or allowed.is_relative_to(current / name)
                for allowed in photos_roots
            )
        ]
        if not any(
            current == allowed or current.is_relative_to(allowed)
            for allowed in photos_roots
        ):
            continue
        for filename in sorted(filenames):
            if not filename.lower().endswith(".json"):
                continue
            path = Path(directory) / filename
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                diagnostics.append(
                    {
                        "sourceJson": relative,
                        "kind": "UNKNOWN",
                        "reason": "symlink skipped",
                    }
                )
                continue
            try:
                data = load_json(path)
            except (MappingError, OSError, UnicodeError, json.JSONDecodeError) as error:
                diagnostics.append(
                    {
                        "sourceJson": relative,
                        "kind": "UNKNOWN",
                        "reason": type(error).__name__,
                    }
                )
                continue
            if not isinstance(data, dict):
                diagnostics.append(
                    {
                        "sourceJson": relative,
                        "kind": "UNKNOWN",
                        "reason": "not a JSON object",
                    }
                )
                continue
            parent = path.parent.relative_to(root).as_posix()
            fingerprint = stable_key("metadata", data)
            fingerprints.setdefault(fingerprint, []).append(relative)
            album_data = (
                data.get("albumData")
                if isinstance(data.get("albumData"), dict)
                else data
            )
            if is_album_metadata(album_data, filename):
                if parent == "." or is_service_directory(path.parent.name):
                    diagnostics.append(
                        {
                            "sourceJson": relative,
                            "kind": "SERVICE_DIRECTORY",
                            "reason": "service/year/root directory is not a user album",
                        }
                    )
                    continue
                key = stable_key("google-takeout-album", [owner, parent])
                existing = albums.get(parent)
                if existing and existing["metadata"] != album_data:
                    raise MappingError(
                        f"Conflicting album metadata in {parent}; review before continuing"
                    )
                if existing:
                    existing["sourceJsons"].append(relative)
                else:
                    confirmed_shape = (
                        "albumData" in data
                        or isinstance(album_data.get("access"), str)
                        and album_data["access"] in {"private", "protected", "public"}
                        or timestamp(album_data.get("date")) is not None
                    )
                    albums[parent] = {
                        "key": key,
                        "sourceDirectory": parent,
                        "title": album_data["title"],
                        "description": album_data.get("description"),
                        "metadata": album_data,
                        "sourceJsons": [relative],
                        "albumEvidence": "EXPLICIT_ALBUM_METADATA"
                        if confirmed_shape
                        else "KNOWN_FILENAME_TITLE_ONLY",
                        "requiresAlbumConfirmation": not confirmed_shape,
                    }
                continue
            title = data.get("title")
            if (
                not isinstance(title, str)
                or not title
                or not any(
                    key in data
                    for key in ("photoTakenTime", "creationTime", "googlePhotosOrigin")
                )
            ):
                diagnostics.append(
                    {
                        "sourceJson": relative,
                        "kind": "UNKNOWN",
                        "reason": "unrecognized metadata shape",
                    }
                )
                continue
            if "/" in title or "\\" in title or title in {".", ".."}:
                diagnostics.append(
                    {
                        "sourceJson": relative,
                        "kind": "UNKNOWN",
                        "reason": "unsafe media title path",
                    }
                )
                continue
            media_name, association, association_uncertain = sidecar_media_name(
                filename, title, path.parent
            )
            kind = media_type(media_name)
            if kind is None:
                diagnostics.append(
                    {
                        "sourceJson": relative,
                        "kind": "UNSUPPORTED",
                        "reason": "unsupported media extension",
                        "title": title,
                    }
                )
                continue
            media_relative = (PurePosixPath(parent) / media_name).as_posix()
            source_media = mapped_path(media_relative, root, path_maps)
            # Hash independent source bytes, never the mapped Gallery target.
            # Otherwise a wrong path map could self-confirm against its own target.
            extra = read_media_evidence(root / media_relative, hash_media)
            rows.append(
                {
                    "sourceJson": relative,
                    "sourceMedia": source_media,
                    "sourcePathMapping": source_path_mapping(media_relative, path_maps),
                    "sourceRelativePath": media_relative,
                    "directory": parent,
                    "googleMetadata": data,
                    "title": media_name,
                    "type": kind,
                    "sourceAssociationEvidence": association,
                    "associationUncertain": association_uncertain,
                    "captureTimestamp": timestamp(data.get("photoTakenTime")),
                    "captureTimestampProvenance": "Google photoTakenTime.timestamp",
                    "fileSize": positive_integer(
                        extra.get("fileSize", data.get("fileSize"))
                    ),
                    "width": positive_integer(data.get("width")),
                    "height": positive_integer(data.get("height")),
                    # Standard Google sidecars may omit this. Never guess units
                    # for an arbitrary numeric duration/creationTime/mtime field.
                    "durationMilliseconds": duration_milliseconds(
                        data.get("durationMilliseconds")
                    )
                    if kind == "VIDEO"
                    else None,
                    "fileSizeProvenance": "independent source media bytes"
                    if "fileSize" in extra
                    else "Google sidecar fileSize",
                    "contentChecksumProvenance": "independent source media bytes"
                    if "contentChecksum" in extra
                    else "explicit typed sidecar contentChecksum",
                    "contentChecksum": content_checksum(
                        extra.get("contentChecksum", data.get("contentChecksum"))
                    ),
                    "isEdited": bool(data.get("isEdited"))
                    or bool(
                        re.search(
                            r"(?:^|[-_ ])edited(?:[._ -]|$)", media_name, re.IGNORECASE
                        )
                    ),
                }
            )
    # Direct sidecars establish album membership; do not infer recursively into unrelated subdirectories.
    for row in rows:
        row["albumKeys"] = (
            [albums[row["directory"]]["key"]] if row["directory"] in albums else []
        )
        row["key"] = stable_key(
            "takeout-item",
            [
                owner,
                row["sourceRelativePath"],
                row["googleMetadata"],
                row["sourceJson"] if row["associationUncertain"] else None,
            ],
        )
    duplicate_jsons = [paths for paths in fingerprints.values() if len(paths) > 1]
    return {
        "root": str(root),
        "albums": list(albums.values()),
        "items": rows,
        "diagnostics": diagnostics,
        "duplicateJsons": sorted(duplicate_jsons),
    }


def scoped_inventory(
    snapshot: Any, owner: str
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if not isinstance(snapshot, dict) or owner_uuid(snapshot.get("ownerId")) != owner:
        raise MappingError("Inventory ownerId must exactly equal --owner")
    assets, albums = snapshot.get("assets"), snapshot.get("albums", [])
    if not isinstance(assets, list) or not isinstance(albums, list):
        raise MappingError("Inventory assets/albums must be arrays")
    ids = {}
    scoped = []
    for row in assets:
        if (
            not isinstance(row, dict)
            or not isinstance(row.get("id"), str)
            or not row["id"]
        ):
            raise MappingError(
                "Every inventory asset needs a stable id and explicit ownerId"
            )
        asset_owner = owner_uuid(row.get("ownerId"))
        if asset_owner != owner:
            continue
        for field in (
            "type",
            "originalPath",
            "originalFileName",
            "visibility",
            "livePhotoVideoId",
        ):
            if row.get(field) is not None and not isinstance(row[field], str):
                raise MappingError(f"Inventory asset {field} must be a string or null")
        if row["id"] in ids:
            if ids[row["id"]] != row:
                raise MappingError("Contradictory duplicate asset IDs in inventory")
            continue
        ids[row["id"]] = row
        scoped.append(row)
    owned_albums = []
    album_ids = {}
    for album in albums:
        if (
            not isinstance(album, dict)
            or not isinstance(album.get("id"), str)
            or not album["id"]
            or not isinstance(album.get("assetIds", []), list)
            or any(
                not isinstance(asset_id, str) or not asset_id
                for asset_id in album.get("assetIds", [])
            )
        ):
            raise MappingError(
                "Every inventory album needs an id, ownerId, and assetIds array"
            )
        if owner_uuid(album.get("ownerId")) == owner:
            if album["id"] in album_ids:
                if album_ids[album["id"]] != album:
                    raise MappingError("Contradictory duplicate album IDs in inventory")
                continue
            album_ids[album["id"]] = album
            owned_albums.append(album)
    return scoped, owned_albums


def asset_evidence(row: dict[str, Any]) -> dict[str, Any]:
    exif = row.get("exifInfo") if isinstance(row.get("exifInfo"), dict) else {}
    checksum = content_checksum(row.get("contentChecksum"))
    if checksum is None and (
        row.get("isExternal") is False or row.get("checksumAlgorithm") == "sha1"
    ):
        checksum = content_checksum({"algorithm": "sha1", "value": row.get("checksum")})
    return {
        "id": row["id"],
        "type": str(row.get("type", "")).upper(),
        "path": row.get("originalPath"),
        "name": row.get("originalFileName"),
        "timestamp": timestamp(row.get("fileCreatedAt")),
        "timestampProvenance": "Gallery fileCreatedAt; repair history unavailable",
        "size": positive_integer(row.get("fileSize", exif.get("fileSizeInByte"))),
        "width": positive_integer(row.get("width", exif.get("exifImageWidth"))),
        "height": positive_integer(row.get("height", exif.get("exifImageHeight"))),
        "durationMilliseconds": duration_milliseconds(
            row.get("durationMilliseconds", row.get("duration"))
        )
        if str(row.get("type", "")).upper() == "VIDEO"
        else None,
        "checksum": checksum,
    }


class AssetIndex:
    """Index inventory metadata once; do not scan the entire library for each JSON."""

    def __init__(self, assets: list[dict[str, Any]]) -> None:
        self.rows = {row["id"]: row for row in assets}
        self.paths: dict[tuple[str, str], set[str]] = {}
        self.names: dict[tuple[str, str], set[str]] = {}
        self.hashes: dict[tuple[str, tuple[str, str]], set[str]] = {}
        self.parents: dict[str, set[str]] = {}
        for row in assets:
            evidence = asset_evidence(row)
            if evidence["path"]:
                self.paths.setdefault((evidence["type"], evidence["path"]), set()).add(
                    row["id"]
                )
            if isinstance(evidence["name"], str):
                self.names.setdefault(
                    (evidence["type"], evidence["name"].casefold()), set()
                ).add(row["id"])
            if evidence["checksum"]:
                self.hashes.setdefault(
                    (evidence["type"], evidence["checksum"]), set()
                ).add(row["id"])
            if row.get("livePhotoVideoId"):
                self.parents.setdefault(row["livePhotoVideoId"], set()).add(row["id"])

    def candidates(self, item: dict[str, Any]) -> list[dict[str, Any]]:
        ids = set(self.paths.get((item["type"], item["sourceMedia"]), set()))
        ids.update(self.names.get((item["type"], item["title"].casefold()), set()))
        if item["contentChecksum"]:
            ids.update(self.hashes.get((item["type"], item["contentChecksum"]), set()))
        parents = set()
        for asset_id in ids:
            parents.update(self.parents.get(asset_id, set()))
        return [self.rows[asset_id] for asset_id in sorted(ids | parents)]


def match_item(item: dict[str, Any], assets: list[dict[str, Any]]) -> dict[str, Any]:
    candidates = []
    rejected = []
    insufficient = []
    motion_parents: dict[str, list[dict[str, Any]]] = {}
    for row in assets:
        if (
            row.get("livePhotoVideoId")
            and row.get("type") == "IMAGE"
            and not row.get("isTrashed")
            and not row.get("isOffline")
            and str(row.get("visibility", "timeline")).lower()
            not in {"hidden", "locked"}
        ):
            motion_parents.setdefault(row["livePhotoVideoId"], []).append(row)
    for row in assets:
        related_parents = motion_parents.get(row["id"], [])
        if (
            row.get("isOffline") is True
            or row.get("isTrashed") is True
            or str(row.get("visibility", "timeline")).lower() == "locked"
            or (
                str(row.get("visibility", "timeline")).lower() == "hidden"
                and not related_parents
            )
        ):
            continue
        evidence = asset_evidence(row)
        if evidence["type"] != item["type"]:
            continue
        path_matches = evidence["path"] == item["sourceMedia"]
        name_matches = (
            isinstance(evidence["name"], str)
            and evidence["name"].casefold() == item["title"].casefold()
        )
        hash_matches = (
            item["contentChecksum"] is not None
            and item["contentChecksum"] == evidence["checksum"]
        )
        if not (path_matches or name_matches or hash_matches):
            continue
        reasons = ["owner scope", "media type"]
        contradictions = []
        differences = []
        for label, field, source, target, source_provenance, target_provenance in (
            (
                "size",
                "fileSize",
                item["fileSize"],
                evidence["size"],
                item["fileSizeProvenance"],
                "Gallery fileSize/exifInfo.fileSizeInByte",
            ),
            (
                "content checksum",
                "contentChecksum",
                item["contentChecksum"],
                evidence["checksum"],
                item["contentChecksumProvenance"],
                "explicit typed inventory content checksum",
            ),
        ):
            if (
                source is not None
                and target is not None
                and (label != "content checksum" or source[0] == target[0])
            ):
                if source != target:
                    differences.append(
                        {
                            "field": field,
                            "sourceValue": source,
                            "assetValue": target,
                            "sourceProvenance": source_provenance,
                            "assetProvenance": target_provenance,
                        }
                    )
                else:
                    reasons.append(label)
        if (
            item["width"]
            and item["height"]
            and evidence["width"]
            and evidence["height"]
        ):
            if sorted((item["width"], item["height"])) != sorted(
                (evidence["width"], evidence["height"])
            ):
                contradictions.append("dimensions differ")
            else:
                reasons.append("dimensions (orientation independent)")
        if (
            item["durationMilliseconds"] is not None
            and evidence["durationMilliseconds"] is not None
        ):
            if item["durationMilliseconds"] != evidence["durationMilliseconds"]:
                contradictions.append("duration milliseconds differ")
            else:
                reasons.append("duration milliseconds")
        time_matches = (
            item["captureTimestamp"] is not None
            and evidence["timestamp"] is not None
            and abs(item["captureTimestamp"] - evidence["timestamp"]) <= 1
        )
        if (
            item["captureTimestamp"] is not None
            and evidence["timestamp"] is not None
            and not time_matches
        ):
            differences.append(
                {
                    "field": "captureTimestamp",
                    "sourceValue": item["captureTimestamp"],
                    "assetValue": evidence["timestamp"],
                    "sourceProvenance": item["captureTimestampProvenance"],
                    "assetProvenance": evidence["timestampProvenance"],
                }
            )
        if time_matches:
            reasons.append("capture timestamp within one second")
        if item["isEdited"] and not path_matches and not name_matches:
            contradictions.append("edited variant needs its own path/name")
        if contradictions:
            rejected.append(
                {
                    "assetId": evidence["id"],
                    "reasons": contradictions,
                    "assetEvidence": evidence,
                    "metadataDifferences": differences,
                }
            )
            continue
        if path_matches:
            reasons.append(
                "verified mapped source path"
                if item["sourcePathMapping"]
                else "original source location path (no explicit mapping)"
            )
        if name_matches:
            reasons.append("original filename")
        mapped_identity = bool(
            path_matches and item["sourcePathMapping"] and name_matches
        )
        reasons.extend(
            difference["field"]
            + " differs; possible metadata repair, not identity proof"
            for difference in differences
        )
        if hash_matches:
            identity_basis = "CONTENT_HASH"
            # Identical comparable bytes prove identity even when database dates
            # changed. A reported size inconsistency is conservatively reviewed.
            classification = (
                "HIGH_CONFIDENCE"
                if any(d["field"] == "fileSize" for d in differences)
                else "EXACT"
            )
        elif mapped_identity:
            identity_basis = "VERIFIED_MAPPED_PATH"
            classification = (
                "EXACT"
                if not differences and (time_matches or "size" in reasons)
                else "HIGH_CONFIDENCE"
            )
        elif path_matches and not differences:
            identity_basis = "SOURCE_PATH"
            classification = (
                "EXACT" if time_matches or "size" in reasons else "HIGH_CONFIDENCE"
            )
        elif name_matches and time_matches and not differences:
            identity_basis = "FILENAME_CAPTURE_TIME"
            classification = "HIGH_CONFIDENCE"
        else:
            # Mutable differences cannot disprove logical identity, but do not
            # supply missing proof. Dimensions/duration/size alone cannot do so.
            insufficient.append(
                {
                    "assetId": evidence["id"],
                    "evidence": reasons
                    + ["insufficient independent identity evidence"],
                    "assetEvidence": evidence,
                    "metadataDifferences": differences,
                }
            )
            continue
        details = {
            "identityBasis": identity_basis,
            "assetEvidence": evidence,
            "metadataDifferences": differences,
        }
        if related_parents:
            for parent in related_parents:
                candidates.append(
                    {
                        "assetId": parent["id"],
                        "matchedComponentAssetId": row["id"],
                        "relatedMotionComponent": True,
                        "confidence": classification,
                        "evidence": reasons
                        + [
                            "server-linked motion component; logical still asset membership"
                        ],
                        "livePhotoVideoId": row["id"],
                        **details,
                    }
                )
        else:
            candidates.append(
                {
                    "assetId": evidence["id"],
                    "confidence": classification,
                    "evidence": reasons,
                    "livePhotoVideoId": row.get("livePhotoVideoId"),
                    **details,
                }
            )
    candidates.sort(key=lambda row: row["assetId"])
    if item["associationUncertain"] and not any(
        row["identityBasis"] == "CONTENT_HASH" for row in candidates
    ):
        return {
            "assetId": None,
            "confidence": "AMBIGUOUS",
            "evidence": [],
            "candidates": candidates + insufficient,
            "rejectedCandidates": rejected,
            "metadataDifferences": [],
            "ambiguityReason": item["sourceAssociationEvidence"],
        }
    # Identity proofs outrank mutable filename+time evidence, not each other.
    # A repaired same-name candidate must not be eliminated to let another
    # candidate win on its date alone. No numeric scores or wider time window.
    strongest = [
        row for row in candidates if row["identityBasis"] != "FILENAME_CAPTURE_TIME"
    ]
    if not strongest and not insufficient:
        strongest = candidates
    if len(strongest) == 1:
        weaker = [row["assetId"] for row in candidates if row not in strongest]
        return {
            **strongest[0],
            "candidates": candidates + insufficient,
            "weakerCandidateIds": weaker,
            "rejectedCandidates": rejected,
        }
    if strongest or candidates:
        return {
            "assetId": None,
            "confidence": "AMBIGUOUS",
            "evidence": [],
            "candidates": candidates + insufficient,
            "rejectedCandidates": rejected,
            "metadataDifferences": [],
            "ambiguityReason": "Multiple identity proofs or unresolved same-name candidates; mutable date/hash differences cannot choose between them",
        }
    if insufficient:
        return {
            "assetId": None,
            "confidence": "AMBIGUOUS",
            "evidence": [],
            "candidates": sorted(insufficient, key=lambda row: row["assetId"]),
            "rejectedCandidates": rejected,
            "metadataDifferences": [],
            "ambiguityReason": "Filename candidates exist, but none has sufficient identity evidence",
        }
    return {
        "assetId": None,
        "confidence": "MISSING",
        "evidence": [],
        "candidates": [],
        "rejectedCandidates": rejected,
        "metadataDifferences": [],
        "missingReason": "No eligible owner-scoped asset has enough consistent evidence; no upload is proposed",
    }


def build_mapping(
    root: Path,
    snapshot: Any,
    owner: str,
    path_maps: list[dict[str, Any]] | None = None,
    hash_media: bool = False,
    ledger: Any = None,
    photos_root_confirmed: bool = False,
) -> dict[str, Any]:
    owner = owner_uuid(owner)
    assets, existing_albums = scoped_inventory(snapshot, owner)
    normalized_maps = normalize_path_maps(path_maps or [])
    parsed = parse_takeout(
        root, owner, normalized_maps, hash_media, photos_root_confirmed
    )
    index = AssetIndex(assets)
    owned_albums = {row["id"]: row for row in existing_albums}
    if ledger is None:
        ledger = {"ownerId": owner, "albumMappings": []}
    if (
        not isinstance(ledger, dict)
        or owner_uuid(ledger.get("ownerId")) != owner
        or not isinstance(ledger.get("albumMappings"), list)
    ):
        raise MappingError(
            "Migration ledger must have the same explicit ownerId and albumMappings array"
        )
    links = {}
    for link in ledger["albumMappings"]:
        if (
            not isinstance(link, dict)
            or owner_uuid(link.get("ownerId")) != owner
            or not isinstance(link.get("migrationKey"), str)
        ):
            raise MappingError("Every ledger entry must explicitly belong to --owner")
        if link.get("albumId") not in owned_albums:
            raise MappingError("Ledger refers to an absent or foreign-owner album")
        if (
            link["migrationKey"] in links
            and links[link["migrationKey"]] != link["albumId"]
        ):
            raise MappingError("Conflicting album IDs in migration ledger")
        links[link["migrationKey"]] = link["albumId"]
    items = []
    item_keys: dict[str, dict[str, Any]] = {}
    duplicate_records = []
    for source in parsed["items"]:
        match = match_item(source, index.candidates(source))
        item = {
            "key": source["key"],
            "ownerId": owner,
            "sourceJsons": [source["sourceJson"]],
            "sourceMedia": source["sourceMedia"],
            "sourceRelativePath": source["sourceRelativePath"],
            "sourceAssociationEvidence": source["sourceAssociationEvidence"],
            "sourcePathMapping": source["sourcePathMapping"],
            "sourceEvidence": {
                name: source[name]
                for name in (
                    "captureTimestamp",
                    "captureTimestampProvenance",
                    "fileSize",
                    "fileSizeProvenance",
                    "width",
                    "height",
                    "durationMilliseconds",
                    "contentChecksum",
                    "contentChecksumProvenance",
                )
            },
            "googleMetadata": source["googleMetadata"],
            "targetAlbumKeys": source["albumKeys"],
            **match,
        }
        item["requiresMetadataReview"] = bool(item["metadataDifferences"])
        if item["key"] in item_keys:
            item_keys[item["key"]]["sourceJsons"].append(source["sourceJson"])
            duplicate_records.append(source["sourceJson"])
        else:
            item_keys[item["key"]] = item
            items.append(item)
    items.sort(key=lambda row: row["key"])
    albums = []
    for album in sorted(parsed["albums"], key=lambda row: row["key"]):
        members = [row for row in items if album["key"] in row["targetAlbumKeys"]]
        matching_album = owned_albums.get(links.get(album["key"], ""))
        matched_ids = sorted(
            {row["assetId"] for row in members if row["assetId"] is not None}
        )
        existing_ids = (
            set(matching_album.get("assetIds", [])) if matching_album else set()
        )
        counts = {
            kind: sum(row["confidence"] == kind for row in members)
            for kind in ("EXACT", "HIGH_CONFIDENCE", "AMBIGUOUS", "MISSING")
        }
        title_collisions = sorted(
            row["id"]
            for row in existing_albums
            if row.get("albumName", row.get("name")) == album["title"]
            and row is not matching_album
        )
        logical_memberships = len({row["assetId"] or row["key"] for row in members})
        status = (
            "ALREADY_MAPPED"
            if matching_album
            else "REQUIRES_ALBUM_CONFIRMATION"
            if album["requiresAlbumConfirmation"]
            else "PROPOSED_NEW"
        )
        album_diagnostics = [
            row
            for row in parsed["diagnostics"]
            if PurePosixPath(row["sourceJson"]).parent.as_posix()
            == album["sourceDirectory"]
        ]
        albums.append(
            {
                **album,
                "ownerId": owner,
                "targetAlbumId": matching_album["id"] if matching_album else None,
                "status": status,
                "items": len(members),
                "logicalMemberships": logical_memberships,
                "matches": counts,
                "diagnosticRecords": album_diagnostics,
                "proposedAssetIds": matched_ids,
                "proposedMissingMembershipIds": []
                if status == "REQUIRES_ALBUM_CONFIRMATION"
                else sorted(set(matched_ids) - existing_ids),
                "sameTitleAlbumIdsRequireReview": title_collisions,
                "order": None,
                "coverAssetId": None,
                "reviewRequired": bool(
                    album["requiresAlbumConfirmation"]
                    or counts["AMBIGUOUS"]
                    or counts["MISSING"]
                    or title_collisions
                    or album_diagnostics
                    or any(member["requiresMetadataReview"] for member in members)
                ),
            }
        )
    counts = {
        kind: sum(row["confidence"] == kind for row in items)
        for kind in ("EXACT", "HIGH_CONFIDENCE", "AMBIGUOUS", "MISSING")
    }
    return {
        "schemaVersion": SCHEMA_VERSION,
        "mode": "DRY_RUN_ONLY",
        "ownerId": owner,
        "takeoutRoot": parsed["root"],
        "pathMaps": [
            {"metadataPrefix": source, "assetPrefix": target}
            for source, target in normalized_maps
        ],
        "readOnlyMediaDirectories": sorted(
            {
                str(PurePosixPath(row["originalPath"]).parent)
                for row in assets
                if isinstance(row.get("originalPath"), str)
                and row["originalPath"].startswith("/")
            }
        ),
        "summary": {
            "googleAlbumsFound": sum(
                row["status"] != "REQUIRES_ALBUM_CONFIRMATION" for row in albums
            ),
            "albumCandidatesRequiringConfirmation": sum(
                row["status"] == "REQUIRES_ALBUM_CONFIRMATION" for row in albums
            ),
            "albumsToCreate": sum(row["status"] == "PROPOSED_NEW" for row in albums),
            "albumsAlreadyMatched": sum(
                row["status"] == "ALREADY_MAPPED" for row in albums
            ),
            "totalAlbumMemberships": sum(
                row["logicalMemberships"]
                for row in albums
                if row["status"] != "REQUIRES_ALBUM_CONFIRMATION"
            ),
            "totalMetadataItems": len(items),
            "uniqueMatchedAssets": len(
                {row["assetId"] for row in items if row["assetId"] is not None}
            ),
            "matchCountsUnit": "deduplicated metadata records, not unique assets",
            "matches": counts,
            "potentialDuplicates": len(parsed["duplicateJsons"]),
            "duplicateRecords": len(duplicate_records),
            "unsupportedRecords": sum(
                row["kind"] == "UNSUPPORTED" for row in parsed["diagnostics"]
            ),
            "unknownRecords": sum(
                row["kind"] == "UNKNOWN" for row in parsed["diagnostics"]
            ),
        },
        "albums": albums,
        "items": items,
        "duplicateJsons": parsed["duplicateJsons"],
        "duplicateRecords": sorted(duplicate_records),
        "diagnostics": parsed["diagnostics"],
        "safety": {
            "productionRead": False,
            "productionWrite": False,
            "mediaUpload": False,
            "sourceWrite": False,
            "applyImplemented": False,
            "albumMatchingRequiresLedger": True,
            "externalChecksumIsNotContentHash": True,
            "orderAndCoverNotInferred": True,
        },
    }


def write_mapping(
    mapping: dict[str, Any],
    output: str,
    snapshot_path: Path | None,
    ledger_path: Path | None = None,
    path_map_path: Path | None = None,
) -> None:
    if output == "-":
        print(json.dumps(mapping, ensure_ascii=False, sort_keys=True, indent=2))
        return
    target = Path(output)
    resolved = target.resolve()
    forbidden_roots = (
        [Path(mapping["takeoutRoot"]).resolve()]
        + [Path(row["assetPrefix"]).resolve() for row in mapping["pathMaps"]]
        + [Path(path).resolve() for path in mapping["readOnlyMediaDirectories"]]
    )
    input_files = [
        path.resolve()
        for path in (snapshot_path, ledger_path, path_map_path)
        if path is not None
    ]
    if (
        any(
            resolved == root or resolved.is_relative_to(root)
            for root in forbidden_roots
        )
        or resolved in input_files
    ):
        raise MappingError(
            "Output must be outside Takeout/media trees and must not overwrite an input"
        )
    if target.exists() or target.is_symlink():
        raise MappingError("Output already exists; use a new audit filename or stdout")
    # No overwrite, including when another process races with this one.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=target.parent,
            prefix=".takeout-audit-",
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            json.dump(mapping, handle, ensure_ascii=False, sort_keys=True, indent=2)
            handle.write("\n")
        os.link(temporary, target)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--owner",
        required=True,
        help="Explicit Gallery owner UUID; must equal inventory and ledger ownerId",
    )
    parser.add_argument(
        "--takeout",
        type=Path,
        required=True,
        help="Read-only root containing restored metadata",
    )
    parser.add_argument(
        "--photos-root-confirmed",
        action="store_true",
        help="Explicitly confirm an isolated Google Photos metadata root with a nonstandard directory name; never use for a mixed export",
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument(
        "--inventory",
        type=Path,
        help="Offline owner-scoped Gallery assets/albums JSON snapshot",
    )
    source.add_argument(
        "--server",
        help="HTTPS Gallery URL; fetch read-only metadata inventory, never media",
    )
    parser.add_argument(
        "--api-key-env",
        default="GALLERY_TAKEOUT_API_KEY",
        help="Environment variable name containing the owner's API key; never put the value in argv",
    )
    parser.add_argument(
        "--path-map",
        type=Path,
        help="JSON array of metadataPrefix/assetPrefix pairs; no guessed Synology paths",
    )
    parser.add_argument(
        "--ledger",
        type=Path,
        help="Read-only existing migration ledger; never modified by dry-run",
    )
    parser.add_argument(
        "--hash-media",
        action="store_true",
        help="Optionally stream readable originals for SHA1 evidence; can be slow, never uploads",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="New audit JSON outside source/media trees, or '-' for stdout",
    )
    args = parser.parse_args(argv)
    try:
        maps = load_json(args.path_map) if args.path_map else []
        if not isinstance(maps, list):
            raise MappingError("Path map must be a JSON array")
        owner = owner_uuid(args.owner)
        if args.inventory:
            snapshot = load_json(args.inventory, max_bytes=128 * 1024 * 1024)
        else:
            from gallery_inventory import fetch_inventory

            snapshot = fetch_inventory(args.server, owner, args.api_key_env)
        result = build_mapping(
            args.takeout,
            snapshot,
            owner,
            maps,
            args.hash_media,
            load_json(args.ledger) if args.ledger else None,
            args.photos_root_confirmed,
        )
        result["safety"]["productionRead"] = args.server is not None
        write_mapping(result, args.output, args.inventory, args.ledger, args.path_map)
    except (ValueError, OSError, UnicodeError) as error:
        print(f"Dry-run stopped safely: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
