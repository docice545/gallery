"""Validate the exact additive upgrade and rollback startup on ONE isolated restore."""
import json
import re

from release_candidate import MIGRATION, need

PROGRAM = r'''
import {createRequire} from 'node:module';
const require=createRequire('/usr/src/app/server/package.json');
require('reflect-metadata');
const {Kysely}=require('kysely');
const {getKyselyConfig}=await import('file:///usr/src/app/server/dist/utils/database.js');
const {DatabaseRepository}=await import('file:///usr/src/app/server/dist/repositories/database.repository.js');
const {ConfigRepository}=await import('file:///usr/src/app/server/dist/repositories/config.repository.js');
const {LoggingRepository}=await import('file:///usr/src/app/server/dist/repositories/logging.repository.js');
const db=new Kysely(getKyselyConfig({connectionType:'url',url:'postgres://postgres:disposable-restore-only@127.0.0.1:5432/immich'}));
try { await new DatabaseRepository(db,LoggingRepository.create(),new ConfigRepository()).runMigrations(); }
catch { process.exitCode=1; }
finally { await db.destroy(); }
'''


def transition(tool, docker, fixture, query, before, state, backup):
    from trash_predeploy import comparable, private_json, save, sha, summary_valid
    import rollback_bridge
    profile = tool.CANDIDATE_PROFILE
    need(re.fullmatch('gallery-restore-check-[0-9a-f]{16}', fixture), 'ISOLATED_RESTORE_NAME_REQUIRED')
    item = tool.inspect(fixture)
    need(item['HostConfig']['NetworkMode'] == 'none' and not item['HostConfig'].get('Binds') and
         not item['HostConfig'].get('VolumesFrom') and not item['HostConfig'].get('PortBindings'),
         'ISOLATED_RESTORE_NO_PRODUCTION_NETWORK_OR_MOUNTS')
    rollback = private_json(state / 'rollback-bridge.json')
    rollback_bridge.ensure(tool, state, rollback)
    expected = {**comparable(before), 'migrationNames': sorted([*before['migrationNames'], MIGRATION])}
    need(MIGRATION not in before['migrationNames'], 'MIGRATION_ALREADY_PRESENT_IN_BASE_BACKUP')
    for image, phase in ((tool.IMAGE, 'upgrade'), (rollback['imageId'], 'rollback-startup')):
        # The shared network namespace belongs only to the new --network none PG.
        # No bind/volume, no ports, no API/workers and no production credentials.
        docker('run', '--rm', '--pull', 'never', '--network', 'container:' + fixture,
               '--read-only', '--cpus', '1', '--memory', '2g', '--pids-limit', '256',
               '--entrypoint', 'node', image, '--input-type=module', '-e', PROGRAM, timeout=900)
        result = json.loads(docker(*query))
        summary_valid(result)
        need(comparable(result) == expected, 'ISOLATED_' + phase.upper().replace('-', '_') + '_CHANGED_ASSETS_OR_MIGRATIONS')
    tables = json.loads(docker('exec', fixture, 'psql', '-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=on',
                              '-U', 'postgres', '-d', 'immich', '-c',
                              "SELECT json_build_array((SELECT count(*) FROM asset_deletion_tombstone),(SELECT count(*) FROM asset_deletion_policy));"))
    need(tables == [0, 0], 'NEW_DELETION_AUTHORIZATION_MUST_START_DISABLED')
    receipt = {'backupSHA256': sha(backup), 'sourceCommit': profile['sourceCommit'],
               'imageId': tool.IMAGE, 'rollbackImageId': rollback['imageId'],
               'baseMigrations': before['migrationNames'], 'targetMigrations': expected['migrationNames'],
               'validation': 'PASS_ISOLATED_ADDITIVE_UPGRADE_AND_ROLLBACK_STARTUP', 'productionChanged': False}
    save(state / 'candidate-migration-verified.json', receipt)
    print('PASS isolated exact additive upgrade + previous API rollback startup; counts unchanged, policies default off')
