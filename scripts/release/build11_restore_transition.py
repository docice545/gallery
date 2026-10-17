"""Exact isolated restored-copy migration gate; no API, worker or NAS access."""
from datetime import datetime, timezone
import json
import re

from candidate_restore import PROGRAM
from trash_predeploy import comparable, save, sha, summary_valid

MIGRATION = '1794050000000-OwnerStorageDeletion'
TABLES = ('asset', 'asset_exif', 'album', 'album_asset', 'person', 'user', 'library',
          'asset_deletion_tombstone', 'asset_deletion_policy')


def need(value, message):
    if not value:
        raise RuntimeError(message)


def fingerprint_sql():
    rows = []
    for table in TABLES:
        # Policy's sole new column is excluded; every existing field, timestamp,
        # path, receipt, metadata and association must stay identical. Private
        # row values never leave PostgreSQL, only counts and aggregate SHA-256.
        row = "to_jsonb(t)-'authorizationMode'" if table == 'asset_deletion_policy' else 'to_jsonb(t)'
        rows.append("'%s', (SELECT json_build_object('count', count(*), 'sha256', "
                    "encode(sha256(convert_to(coalesce(string_agg(hash, '' ORDER BY hash), ''), 'UTF8')), 'hex')) "
                    "FROM (SELECT encode(sha256(convert_to((%s)::text, 'UTF8')), 'hex') AS hash "
                    "FROM \"%s\" t) fingerprint_rows)" % (table, row, table))
    return 'SELECT json_build_object(' + ', '.join(rows) + ');'


def isolated_fixture(item, container):
    need(re.fullmatch(r'gallery-restore-check-[0-9a-f]{16}', container), 'ISOLATED_RESTORE_NAME_REQUIRED')
    host = item.get('HostConfig', {})
    need(item.get('State', {}).get('Running') is True and host.get('NetworkMode') == 'none' and
         not host.get('Binds') and not host.get('VolumesFrom') and not host.get('PortBindings') and
         not host.get('Privileged') and all(mount.get('Type') == 'volume' and
         re.fullmatch('[0-9a-f]{64}', mount.get('Name', '')) for mount in item.get('Mounts', [])),
         'ISOLATED_RESTORE_NO_PRODUCTION_NETWORK_OR_MOUNTS')


def read_query(query, sql):
    need(len(query) > 3 and query[0] == 'exec' and re.fullmatch(r'gallery-restore-check-[0-9a-f]{16}', query[1]) and
         'psql' in query and '-c' in query, 'ISOLATED_PSQL_QUERY_REQUIRED')
    return [*query[:query.index('-c')], '-c', 'BEGIN READ ONLY', '-c', "SET LOCAL statement_timeout='60s'",
            '-c', sql, '-c', 'COMMIT']


def build11_restore_transition(tool, docker, container, query, before, state, backup, candidate_image, rollback_image):
    """Called inside fresh restore_check BEFORE it removes its own disposable DB."""
    source = getattr(tool, 'BUILD11_SOURCE', '')
    need(re.fullmatch('[0-9a-f]{40}', source), 'IMMUTABLE_BUILD11_SOURCE_REQUIRED')
    for image in (candidate_image, rollback_image):
        need(re.fullmatch('sha256:[0-9a-f]{64}', image), 'IMMUTABLE_IMAGE_ID_REQUIRED')
    isolated_fixture(tool.inspect(container), container)
    summary_valid(before)
    need(MIGRATION not in before['migrationNames'], 'BUILD11_ALREADY_PRESENT_IN_BASE_BACKUP')
    candidate = json.loads(docker('image', 'inspect', candidate_image))[0]
    env = dict(value.split('=', 1) for value in candidate.get('Config', {}).get('Env', []) if '=' in value)
    need(candidate.get('Id') == candidate_image and env.get('IMMICH_SOURCE_COMMIT') == source,
         'BUILD11_IMAGE_SOURCE_MISMATCH')
    fingerprints = json.loads(docker(*read_query(query, fingerprint_sql())))
    need(set(fingerprints) == set(TABLES) and all(type(value.get('count')) is int and value['count'] >= 0 and
         re.fullmatch('[0-9a-f]{64}', value.get('sha256', '')) for value in fingerprints.values()),
         'PRIVATE_RESTORED_FINGERPRINT_INVALID')
    expected = {**comparable(before), 'migrationNames': sorted([*before['migrationNames'], MIGRATION])}
    for image, phase in ((candidate_image, 'upgrade'), (rollback_image, 'rollback-migration-startup')):
        # Network namespace belongs exclusively to the fresh network-none PG;
        # no bind mounts, ports, API processes, queue workers or media exist.
        isolated_fixture(tool.inspect(container), container)
        docker('run', '--rm', '--pull', 'never', '--network', 'container:' + container,
               '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
               '--cpus', '1', '--memory', '2g', '--pids-limit', '256',
               '--entrypoint', 'node', image, '--input-type=module', '-e', PROGRAM, timeout=900)
        summary = json.loads(docker(*query))
        summary_valid(summary)
        need(comparable(summary) == expected, 'ISOLATED_' + phase.upper().replace('-', '_') + '_CHANGED_DATABASE')
        after = json.loads(docker(*read_query(query, fingerprint_sql())))
        need(after == fingerprints, 'ISOLATED_' + phase.upper().replace('-', '_') + '_CHANGED_EXISTING_ROWS')
    modes = json.loads(docker(*read_query(query,
        'SELECT json_build_object(\'recovery\', count(*) FILTER (WHERE "authorizationMode"=\'recovery\'), '
        '\'storage\', count(*) FILTER (WHERE "authorizationMode"=\'storage\')) FROM asset_deletion_policy;')))
    need(modes == {'recovery': fingerprints['asset_deletion_policy']['count'], 'storage': 0},
         'LEGACY_DELETION_POLICIES_CHANGED_OR_IMPLICIT_STORAGE_GRANT')
    report = {'schemaVersion': 1, 'sourceCommit': source, 'imageId': candidate_image,
              'rollbackImageId': rollback_image, 'backupSHA256': sha(backup),
              'isolatedDatabase': True, 'productionChanged': False,
              'beforeAssetCount': before['assetCount'], 'afterAssetCount': expected['assetCount'],
              'baseMigrations': before['migrationNames'], 'targetMigrations': expected['migrationNames'],
              'rowFingerprints': fingerprints, 'policiesPreserved': True,
              'legacyPolicyCount': modes['recovery'], 'implicitStoragePolicies': 0,
              'rollbackMigrationsAccepted': True,
              # Migration acceptance alone cannot certify real API/worker
              # startup, legacy storage-policy rejection or Trash/Restore.
              'oldRuntimeStartsOnUpgradedSchema': False, 'storagePoliciesRejectedByRollback': False,
              'trashRestoreAfterRollback': False, 'mediaFilesMounted': False, 'destructiveTestsPerformed': False,
              'runtimeRollbackAcceptance': 'NOT TESTED',
              'validation': 'PASS_ISOLATED_BUILD11_MIGRATION_AND_EXISTING_ROW_PRESERVATION',
              'testedAt': datetime.now(timezone.utc).isoformat()}
    save(state / 'build11-restored-database-verified.json', report)
    print('PASS isolated Build11 migration, existing metadata/policies and rollback migration startup; full rollback API acceptance remains gated')
    return report
