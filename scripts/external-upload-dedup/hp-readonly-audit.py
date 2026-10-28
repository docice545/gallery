#!/usr/bin/env python3
"""Read-only per-owner External/Managed duplicate audit for HP.

The script asks psql for catalog rows and hashes only regular files referenced by
those rows. It never writes to PostgreSQL/NAS and has no apply or delete mode.
Keep the JSON report on HP; it contains private paths and identifiers.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
import subprocess
import sys


def sha256(path: Path) -> tuple[str | None, int | None, str | None]:
    try:
        if not path.is_file() or path.is_symlink():
            return None, None, "not-a-regular-file"
        digest = hashlib.sha256()
        size = 0
        with path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
                size += len(chunk)
        return digest.hexdigest(), size, None
    except OSError as error:
        return None, None, type(error).__name__


def rows_from_psql(owner_id: str, psql_url: str) -> list[dict]:
    query = r"""
select a.id::text,
       a."ownerId"::text,
       coalesce(a."libraryId"::text, ''),
       coalesce(l."ownerId"::text, ''),
       coalesce(l."importPaths"::text, '[]'),
       a."originalPath",
       a."checksum"::text,
       coalesce(a."contentChecksum"::text, ''),
       a."status"::text,
       coalesce(a."livePhotoVideoId"::text, ''),
       coalesce(a."stackId"::text, ''),
       a.type::text,
       (select count(*) from album_asset aa where aa."assetId" = a.id)::text,
       (select count(*) from asset_face af where af."assetId" = a.id)::text,
       (select count(*) from memory_asset ma where ma."assetId" = a.id)::text
  from asset a
  left join library l on l.id = a."libraryId"
 where a."ownerId" = :'owner'
 order by a.id
"""
    result = subprocess.run(
        ["psql", "--no-psqlrc", "--tuples-only", "--no-align", "--field-separator=\t", "--set", f"owner={owner_id}", psql_url, "-c", query],
        check=True,
        capture_output=True,
        text=True,
    )
    rows = []
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) != 15:
            raise RuntimeError(f"unexpected psql row width: {len(fields)}")
        rows.append({
            "id": fields[0], "ownerId": fields[1], "libraryId": fields[2] or None,
            "libraryOwnerId": fields[3] or None, "importPaths": fields[4],
            "path": fields[5], "checksum": fields[6], "contentChecksum": fields[7] or None,
            "status": fields[8], "livePhotoVideoId": fields[9] or None, "stackId": fields[10] or None,
            "type": fields[11], "albumCount": int(fields[12]), "faceCount": int(fields[13]),
            "memoryCount": int(fields[14]),
        })
    return rows


def audit(owner_id: str, rows: list[dict], owner_label: str | None) -> dict:
    by_fingerprint: dict[tuple[str, int], list[dict]] = defaultdict(list)
    managed = external = 0
    ambiguous: list[dict] = []
    for row in rows:
        # External assets have a library row; managed assets have no libraryId.
        row["source"] = "external" if row["libraryId"] else "managed"
        managed += row["source"] == "managed"
        external += row["source"] == "external"
        digest, size, error = sha256(Path(row["path"]))
        row["file"] = {"sha256": digest, "size": size, "error": error}
        if digest is not None and size is not None:
            by_fingerprint[(digest, size)].append(row)
        if row["livePhotoVideoId"] or row["stackId"] or row["albumCount"] or row["faceCount"] or row["memoryCount"]:
            row["protectedRelations"] = {
                "livePhotoVideoId": row["livePhotoVideoId"], "stackId": row["stackId"],
                "albumCount": row["albumCount"], "faceCount": row["faceCount"], "memoryCount": row["memoryCount"],
            }
        if row["file"]["error"]:
            ambiguous.append({"assetId": row["id"], "reason": row["file"]["error"], "path": row["path"]})

    groups = [group for group in by_fingerprint.values() if len(group) > 1]
    duplicate_groups = []
    reclaimable = 0
    for group in groups:
        paths = {item["path"] for item in group}
        reclaimable += sum(item["file"]["size"] or 0 for item in group[1:])
        duplicate_groups.append({
            "sha256": group[0]["file"]["sha256"], "size": group[0]["file"]["size"],
            "assets": [{"id": item["id"], "source": item["source"], "path": item["path"],
                        "libraryId": item["libraryId"], "stackId": item["stackId"],
                        "albumCount": item["albumCount"], "faceCount": item["faceCount"],
                        "memoryCount": item["memoryCount"]} for item in group],
            "samePhysicalPath": len(paths) == 1,
            "decision": "REVIEW_REQUIRED",
        })
    return {
        "schemaVersion": 1,
        "ownerId": owner_id,
        "ownerLabel": owner_label,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "readOnly": True,
        "assetCount": len(rows),
        "physicalFileCount": sum(row["file"]["sha256"] is not None for row in rows),
        "sourceCounts": {"managed": managed, "external": external},
        "exactByteDuplicateGroups": duplicate_groups,
        "exactByteDuplicateGroupCount": len(duplicate_groups),
        "estimatedReclaimBytes": reclaimable,
        "ambiguousCases": ambiguous,
        "stackExcludedOwnerCheck": {
            "requiredForChudoAnna": owner_label == "chudo_anna",
            "configuredValue": os.environ.get("STACK_EXCLUDED_OWNERS", "UNSET"),
            "status": "VERIFY_ON_HP" if owner_label == "chudo_anna" else "NOT_APPLICABLE",
        },
        "decision": "REVIEW_REQUIRED_NO_APPLY",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("owner_id")
    parser.add_argument("output", type=Path)
    parser.add_argument("--owner-label")
    parser.add_argument("--psql-url", default=os.environ.get("FOTO_PSQL_URL"))
    args = parser.parse_args()
    if not args.psql_url:
        parser.error("set FOTO_PSQL_URL or pass --psql-url; credentials are never printed")
    report = audit(args.owner_id, rows_from_psql(args.owner_id, args.psql_url), args.owner_label)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"output": str(args.output), "assets": report["assetCount"],
                      "exactDuplicateGroups": report["exactByteDuplicateGroupCount"],
                      "readOnly": True}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
