#!/usr/bin/env python3
"""Read-only, owner-scoped library audit for a disposable or HP PostgreSQL.

The tool deliberately uses psql's ``:'owner'`` variable quoting in every
owner-scoped query.  Each query runs inside a READ ONLY transaction.  It only
emits a JSON report and never issues INSERT/UPDATE/DELETE/TRUNCATE/DDL.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any

UUID = re.compile(r"^[0-9a-fA-F-]{36}$")
REQUIRED_TABLES = ("users", "assets")
OPTIONAL_TABLES = ("libraries", "asset_stack", "albums", "albums_assets_assets", "memories")


def psql_args(dsn: str | None, owner: str | None, sql: str) -> list[str]:
    args = ["psql", "-X", "--no-align", "--tuples-only", "--quiet", "--set=ON_ERROR_STOP=1"]
    if dsn:
        args.extend([dsn])
    if owner is not None:
        args.extend(["--set", f"owner={owner}"])
    return args


def run_psql(dsn: str | None, sql: str, owner: str | None = None) -> list[str]:
    # psql does not expand :variables in the -c execution path on the pinned
    # client. Feed SQL on stdin instead; this still uses psql's :'owner'
    # literal quoting and avoids constructing SQL with string interpolation.
    result = subprocess.run(
        psql_args(dsn, owner, sql),
        input=sql,
        check=False,
        capture_output=True,
        text=True,
        env=os.environ.copy(),
    )
    if result.returncode:
        detail = result.stderr.strip().splitlines()[-1:] or ["psql failed"]
        raise RuntimeError(detail[0])
    return [line for line in result.stdout.splitlines() if line.strip()]


def read_only_query(dsn: str | None, sql: str, owner: str | None = None) -> list[str]:
    wrapped = "BEGIN; SET TRANSACTION READ ONLY;\n" + sql + "\nROLLBACK;"
    return run_psql(dsn, wrapped, owner)


def json_line(lines: list[str]) -> Any:
    if not lines:
        return None
    return json.loads(lines[-1])


def schema_report(dsn: str | None) -> dict[str, Any]:
    sql = """
SELECT json_build_object(
  'transactionReadOnly', current_setting('transaction_read_only'),
  'tables', json_build_object(
    'users', to_regclass('public.users') IS NOT NULL,
    'assets', to_regclass('public.assets') IS NOT NULL,
    'libraries', to_regclass('public.libraries') IS NOT NULL,
    'asset_stack', to_regclass('public.asset_stack') IS NOT NULL,
    'albums', to_regclass('public.albums') IS NOT NULL,
    'albums_assets_assets', to_regclass('public.albums_assets_assets') IS NOT NULL,
    'memories', to_regclass('public.memories') IS NOT NULL
  )
)::text;
"""
    report = json_line(read_only_query(dsn, sql))
    if report.get("transactionReadOnly") != "on":
        raise RuntimeError("PostgreSQL did not enter a read-only transaction")
    missing = [name for name in REQUIRED_TABLES if not report["tables"].get(name)]
    if missing:
        raise RuntimeError("required tables missing: " + ", ".join(missing))
    return report


def owners(dsn: str | None, owner: str | None) -> list[dict[str, str]]:
    if owner:
        if not UUID.fullmatch(owner):
            raise ValueError("--owner must be a UUID")
        sql = "SELECT json_build_object('id', id::text, 'email', email)::text FROM users WHERE id = :'owner'::uuid;"
        rows = read_only_query(dsn, sql, owner)
        if not rows:
            raise RuntimeError("owner was not found in users")
        return [json.loads(rows[-1])]
    rows = read_only_query(dsn, "SELECT json_build_object('id', id::text, 'email', email)::text FROM users ORDER BY id;")
    return [json.loads(row) for row in rows]


def owner_report(dsn: str | None, owner: str) -> dict[str, Any]:
    # The owner variable is deliberately referenced as :'owner' so psql quotes
    # it as a literal before PostgreSQL applies the UUID cast.
    sql = r"""
SELECT json_build_object(
  'assetCounts', json_build_object(
    'all', (SELECT count(*) FROM assets WHERE "ownerId" = :'owner'::uuid),
    'active', (SELECT count(*) FROM assets WHERE "ownerId" = :'owner'::uuid AND "deletedAt" IS NULL AND status = 'active'),
    'trashed', (SELECT count(*) FROM assets WHERE "ownerId" = :'owner'::uuid AND (status = 'trashed' OR "deletedAt" IS NOT NULL)),
    'deleted', (SELECT count(*) FROM assets WHERE "ownerId" = :'owner'::uuid AND status = 'deleted')
  ),
  'checksumDuplicateGroups', COALESCE((SELECT json_agg(group_row ORDER BY group_row->>'count' DESC)
    FROM (
      SELECT json_build_object(
        'checksum', encode("checksum", 'hex'),
        'algorithms', json_agg(DISTINCT COALESCE("checksumAlgorithm"::text, '') ORDER BY COALESCE("checksumAlgorithm"::text, '')),
        'count', count(*),
        'assets', json_agg(json_build_object(
          'id', id::text,
          'libraryId', "libraryId"::text,
          'isExternal', "isExternal",
          'originalPath', "originalPath",
          'stackId', "stackId"::text,
          'livePhotoVideoId', "livePhotoVideoId"::text,
          'status', status::text
        ) ORDER BY id)
      ) AS group_row
      FROM assets
      WHERE "ownerId" = :'owner'::uuid
        AND "checksum" IS NOT NULL
        AND "deletedAt" IS NULL
      GROUP BY "checksum"
      HAVING count(*) > 1
    ) duplicate_groups), '[]'::json),
  'duplicateIdGroups', COALESCE((SELECT json_agg(group_row ORDER BY group_row->>'count' DESC)
    FROM (
      SELECT json_build_object('duplicateId', "duplicateId"::text, 'count', count(*), 'assetIds', json_agg(id::text ORDER BY id)) AS group_row
      FROM assets
      WHERE "ownerId" = :'owner'::uuid AND "duplicateId" IS NOT NULL AND "deletedAt" IS NULL
      GROUP BY "duplicateId"
      HAVING count(*) > 1
    ) duplicate_groups), '[]'::json),
  'externalManagedCounts', json_build_object(
    'external', (SELECT count(*) FROM assets WHERE "ownerId" = :'owner'::uuid AND "isExternal" = true AND "deletedAt" IS NULL),
    'managed', (SELECT count(*) FROM assets WHERE "ownerId" = :'owner'::uuid AND "isExternal" = false AND "deletedAt" IS NULL)
  ),
  'stackedAssets', (SELECT count(*) FROM assets WHERE "ownerId" = :'owner'::uuid AND "stackId" IS NOT NULL AND "deletedAt" IS NULL),
  'livePhotoPairs', (SELECT count(*) FROM assets WHERE "ownerId" = :'owner'::uuid AND "livePhotoVideoId" IS NOT NULL AND "deletedAt" IS NULL),
  'albumLinks', CASE WHEN to_regclass('public.albums_assets_assets') IS NULL THEN NULL ELSE
    (SELECT count(*) FROM albums_assets_assets aa JOIN assets a ON a.id = aa."assetsId"
      WHERE a."ownerId" = :'owner'::uuid AND a."deletedAt" IS NULL) END,
  'memoryRows', CASE WHEN to_regclass('public.memories') IS NULL THEN NULL ELSE
    (SELECT count(*) FROM memories WHERE "ownerId" = :'owner'::uuid) END
)::text;
"""
    result = json_line(read_only_query(dsn, sql, owner))
    result["ownerId"] = owner
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dsn", help="psql DSN or libpq URI; credentials stay in the environment")
    parser.add_argument("--owner", help="optional owner UUID; omitted audits every row in users")
    parser.add_argument("--output", type=Path, help="JSON report path; stdout when omitted")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        schema = schema_report(args.dsn)
        owner_rows = owners(args.dsn, args.owner)
        report = {
            "schemaVersion": 1,
            "readOnly": True,
            "destructiveStatementsExecuted": False,
            "schema": schema,
            "owners": [owner_report(args.dsn, row["id"]) | {"email": row["email"]} for row in owner_rows],
            "visualSimilarity": "NOT_PROBED_CONTENT_HASH_OR_IMAGE_MODEL_REQUIRED",
            "physicalFileVerification": "NOT_PROBED_DATABASE_ONLY",
        }
        encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
        if args.output:
            args.output.write_text(encoded)
        else:
            sys.stdout.write(encoded)
        return 0
    except (RuntimeError, ValueError, OSError) as error:
        print(f"FAIL read-only audit: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
