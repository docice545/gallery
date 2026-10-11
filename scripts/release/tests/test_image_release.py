"""Mocked image-only operator regressions; no Docker, API or production access."""
from contextlib import ExitStack, contextmanager, redirect_stderr, redirect_stdout
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('image_release_tests', ROOT / 'scripts/release/image_release.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
PREVIOUS = 'sha256:' + 'a' * 64
CANDIDATE = 'sha256:' + 'b' * 64
FOREIGN = 'sha256:' + 'c' * 64
PREVIOUS_SOURCE = 'a' * 40
CANDIDATE_SOURCE = 'b' * 40
PREVIOUS_HASH = 'd' * 64
CANDIDATE_HASH = 'e' * 64
LOCAL_DOCKER = ['docker', '--host=unix:///var/run/docker.sock']
MIGRATIONS = [{'name': '1793600000000-AddAuthorizedAssetDeletion', 'sha256': 'a' * 64},
              {'name': release.BOUND_MIGRATION, 'sha256': 'b' * 64}]


def proof(source, version):
    return {'capability': release.CAPABILITY, 'sourceCommit': source,
            'serverVersion': '.'.join(map(str, version)), 'migrations': copy.deepcopy(MIGRATIONS),
            'guardFiles': {file: 'c' * 64 for file in ('utils/authorized-deletion.js', 'utils/deletion-recovery.js',
                                                     'repositories/asset.repository.js', 'repositories/storage.repository.js',
                                                     'services/asset.service.js', 'services/library.service.js')}}


class LocalDockerExecution(unittest.TestCase):
    def test_inherited_endpoint_selectors_cannot_redirect_local_socket_calls(self):
        selectors = {'DOCKER_HOST': 'tcp://must-not-use.invalid:1234', 'DOCKER_CONTEXT': 'foreign',
                     'DOCKER_TLS': '1', 'DOCKER_TLS_VERIFY': '1', 'DOCKER_CERT_PATH': '/synthetic/tls'}
        with patch.dict(os.environ, {**selectors, 'SYNTHETIC_USER_SETTING': 'preserved'}), \
                patch.object(release.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='ok')) as run:
            self.assertEqual(release.run([*LOCAL_DOCKER, 'version']), 'ok')
        env = run.call_args.kwargs['env']
        self.assertTrue(all(key not in env for key in selectors))
        self.assertEqual(env['SYNTHETIC_USER_SETTING'], 'preserved')
        self.assertEqual(run.call_args.args[0], [*LOCAL_DOCKER, 'version'])


class ActualImageProof(unittest.TestCase):
    def test_upstream_double_extension_identity_is_accepted_in_packaged_and_live_inventory(self):
        valid = proof(CANDIDATE_SOURCE, (5, 7, 3))
        valid['migrations'].append({'name': release.LEGACY_CHECKSUM_MIGRATION, 'sha256': 'd' * 64})
        with patch.object(release, 'image', return_value={'Config': {'Env': ['IMMICH_SOURCE_COMMIT=' + CANDIDATE_SOURCE]}}), \
                patch.object(release, 'run', return_value=json.dumps(valid)):
            self.assertEqual(release.probe_image(CANDIDATE, CANDIDATE_SOURCE, (5, 7, 3)), valid)
        names = [row['name'] for row in valid['migrations']]
        with patch.object(release, 'postgres', return_value=('database', 'postgres', 'immich')), \
                patch.object(release, 'run', return_value=json.dumps(names)):
            self.assertEqual(release.live_migrations(), set(names))

    def test_arbitrary_dotted_or_path_names_still_fail_closed_in_both_inventories(self):
        for name in ('1774548649115-Other.ts', '1774548649115-AddChecksumAlgorithm.ts.ts',
                     '../1774548649115-AddChecksumAlgorithm.ts', '1800000000000-Other.js'):
            invalid = proof(CANDIDATE_SOURCE, (5, 7, 3))
            invalid['migrations'].append({'name': name, 'sha256': 'd' * 64})
            with self.subTest(name=name), \
                    patch.object(release, 'image', return_value={'Config': {'Env': ['IMMICH_SOURCE_COMMIT=' + CANDIDATE_SOURCE]}}), \
                    patch.object(release, 'run', return_value=json.dumps(invalid)), \
                    self.assertRaisesRegex(release.Stop, 'PACKAGED_MIGRATION_PROOF_REQUIRED'):
                release.probe_image(CANDIDATE, CANDIDATE_SOURCE, (5, 7, 3))
            with self.subTest(live_name=name), \
                    patch.object(release, 'postgres', return_value=('database', 'postgres', 'immich')), \
                    patch.object(release, 'run', return_value=json.dumps([release.BOUND_MIGRATION, name])), \
                    self.assertRaisesRegex(release.Stop, 'LIVE_MIGRATION_INVENTORY_REQUIRED'):
                release.live_migrations()

    def test_probe_reads_actual_compiled_guard_and_migrations_without_application_startup(self):
        valid = proof(CANDIDATE_SOURCE, (5, 7, 2))
        with patch.object(release, 'image', return_value={'Config': {'Env': ['IMMICH_SOURCE_COMMIT=' + CANDIDATE_SOURCE]}}), \
                patch.object(release, 'run', return_value=json.dumps(valid)) as run:
            self.assertEqual(release.probe_image(CANDIDATE, CANDIDATE_SOURCE, (5, 7, 2)), valid)
        command = run.call_args.args[0]
        self.assertEqual(command[:3], [*LOCAL_DOCKER, 'run'])
        for flag in ('--rm', '--read-only', '--cap-drop', '--security-opt', '--pids-limit', '--memory', '--cpus'):
            self.assertIn(flag, command)
        self.assertEqual(command[command.index('--pull') + 1], 'never')
        self.assertEqual(command[command.index('--network') + 1], 'none')
        self.assertEqual(command[command.index('--entrypoint') + 1], 'node')
        self.assertIn(CANDIDATE, command)
        self.assertNotIn('start.sh', command)
        self.assertNotIn('--volume', command)
        self.assertIn('AUTHORIZED_DELETION_CAPABILITY', command[-1])
        self.assertIn('createHash', command[-1])

    def test_version_or_source_labels_alone_do_not_authorize_an_unhardened_image(self):
        for change in ('capability', 'sourceCommit', 'serverVersion', 'missing_migration', 'missing_guard'):
            invalid = proof(CANDIDATE_SOURCE, (5, 7, 2))
            if change == 'missing_migration':
                invalid['migrations'].pop()
            elif change == 'missing_guard':
                invalid['guardFiles'].pop('utils/deletion-recovery.js')
            else:
                invalid[change] = 'unverified'
            with self.subTest(change=change), \
                    patch.object(release, 'image', return_value={'Config': {'Env': ['IMMICH_SOURCE_COMMIT=' + CANDIDATE_SOURCE]}}), \
                    patch.object(release, 'run', return_value=json.dumps(invalid)):
                with self.assertRaises(release.Stop):
                    release.probe_image(CANDIDATE, CANDIDATE_SOURCE, (5, 7, 2))

    def test_missing_or_incomplete_live_inventory_never_becomes_an_empty_schema(self):
        for rows in ([], ['duplicate', 'duplicate'], ['bad'], {}, {'error': 'database-unavailable'}):
            with self.subTest(rows=rows), patch.object(release, 'postgres', return_value=('database', 'postgres', 'immich')), \
                    patch.object(release, 'run', return_value=json.dumps(rows)):
                with self.assertRaises(release.Stop):
                    release.live_migrations()
        with patch.object(release, 'postgres', return_value=('database', 'postgres', 'immich')), \
                patch.object(release, 'run', return_value=json.dumps([row['name'] for row in MIGRATIONS])) as run:
            self.assertEqual(release.live_migrations(), {row['name'] for row in MIGRATIONS})
        command = run.call_args.args[0]
        self.assertEqual(command[:3], [*LOCAL_DOCKER, 'exec'])
        self.assertIn('PGOPTIONS=-c default_transaction_read_only=on -c statement_timeout=3000', command)
        self.assertEqual(command[command.index('-h') + 1], '/var/run/postgresql')
        self.assertEqual(command[command.index('-p') + 1], '5432')
        self.assertEqual(command[command.index('-U') + 1], 'postgres')
        self.assertEqual(command[command.index('-d') + 1], 'immich')
        self.assertEqual(command[-1], release.LIVE_MIGRATIONS)
        self.assertNotIn(release.SERVER, command)


class DatabaseEvidence(unittest.TestCase):
    def postgres(self, env=None):
        return {'Name': '/' + release.POSTGRES, 'State': {'Running': True}, 'Config': {
            'Labels': {'com.docker.compose.project': release.PROJECT, 'com.docker.compose.service': 'database'},
            'Env': [key + '=' + value for key, value in (env or {'POSTGRES_USER': 'postgres', 'POSTGRES_DB': 'immich'}).items()]}}

    def bind(self, env):
        config = {'services': {release.SERVICE: {'environment': env}}}
        with patch.object(release, 'postgres', return_value=('database', 'postgres', 'immich')):
            return release.database_binding(config, {'Config': {'Env': []}})

    def test_local_database_defaults_and_url_bind_to_existing_postgres(self):
        for env in ({}, {'DB_HOSTNAME': release.POSTGRES, 'DB_PORT': '5432'},
                    {'DB_URL': 'postgresql://postgres:synthetic-secret@database:5432/immich'}):
            with self.subTest(env=env):
                self.bind(env)

    def test_remote_or_mismatched_database_cannot_supply_migration_evidence(self):
        for env in ({'DB_HOSTNAME': 'remote'}, {'DB_PORT': '5433'}, {'DB_USERNAME': 'other'},
                    {'DB_DATABASE_NAME': 'other'}, {'DB_URL': 'postgres://postgres@remote/immich'},
                    {'DB_URL': 'postgres://other@database/immich'}, {'DB_URL': 'postgres://postgres@database/other'},
                    {'DB_URL': 'postgres://postgres@database/immich?host=remote'}):
            with self.subTest(env=env), self.assertRaisesRegex(release.Stop, 'LOCAL_POSTGRES_BINDING_REQUIRED'):
                self.bind(env)

    def test_unresolved_database_secret_files_fail_closed(self):
        for key in ('CREDENTIALS_DIRECTORY', 'DB_URL_FILE', 'DB_HOSTNAME_FILE', 'DB_PASSWORD_FILE'):
            with self.subTest(key=key), self.assertRaisesRegex(release.Stop, 'SECRET_FILE_DATABASE_BINDING_UNSUPPORTED'):
                self.bind({key: '/synthetic/secret'})

    def test_postgres_identity_running_state_and_secret_file_inputs_are_required(self):
        valid = self.postgres()
        with patch.object(release, 'inspect', return_value=valid):
            self.assertEqual(release.postgres(), ('database', 'postgres', 'immich'))
        changes = [lambda item: item.update(Name='/foreign'),
                   lambda item: item['State'].update(Running=False),
                   lambda item: item['Config']['Labels'].update({'com.docker.compose.project': 'foreign'}),
                   lambda item: item['Config']['Labels'].pop('com.docker.compose.service')]
        for mutate in changes:
            invalid = copy.deepcopy(valid)
            mutate(invalid)
            with patch.object(release, 'inspect', return_value=invalid), \
                    self.assertRaisesRegex(release.Stop, 'EXISTING_LOCAL_POSTGRES_REQUIRED'):
                release.postgres()
        for key in ('POSTGRES_USER_FILE', 'POSTGRES_DB_FILE'):
            with self.subTest(key=key), patch.object(release, 'inspect', return_value=self.postgres({key: '/synthetic/secret'})), \
                    self.assertRaisesRegex(release.Stop, 'SECRET_FILE_POSTGRES_BINDING_UNSUPPORTED'):
                release.postgres()


class WorkerConfiguration(unittest.TestCase):
    def test_empty_include_uses_both_default_workers(self):
        for include in (None, '', ' , \n\t, '):
            with self.subTest(include=include):
                release.workers({'IMMICH_WORKERS_INCLUDE': include})

    def test_whitespace_duplicates_and_valid_extra_workers_match_server_parsing(self):
        release.workers({'IMMICH_WORKERS_INCLUDE': ' api, micro\tservices,api, maintenance ',
                         'IMMICH_WORKERS_EXCLUDE': ' mainte\nnance,unknown '})

    def test_api_only_exclusions_and_invalid_active_workers_are_rejected(self):
        for env in ({'IMMICH_WORKERS_INCLUDE': 'api'},
                    {'IMMICH_WORKERS_INCLUDE': 'microservices'},
                    {'IMMICH_WORKERS_EXCLUDE': ' microservices'},
                    {'IMMICH_WORKERS_EXCLUDE': 'a\tp\ni'},
                    {'IMMICH_WORKERS_INCLUDE': 'api,microservices,unknown'},
                    {'IMMICH_WORKERS_INCLUDE': 'maintenance'}):
            with self.subTest(env=env):
                with self.assertRaisesRegex(release.Stop, 'API_AND_MICROSERVICES_REQUIRED'):
                    release.workers(env)

    def test_unknown_worker_excluded_from_include_is_accepted_like_server(self):
        release.workers({'IMMICH_WORKERS_INCLUDE': 'api,microservices,unknown',
                         'IMMICH_WORKERS_EXCLUDE': 'unknown'})

    def test_image_defaults_can_hide_api_only_worker_configuration(self):
        target = {'Config': {'Env': ['IMMICH_WORKERS_INCLUDE=api', 'IMMICH_SOURCE_COMMIT=' + CANDIDATE_SOURCE]}}
        config = {'services': {release.SERVICE: {'environment': {'UNRELATED': 'value'}}}}
        merged = release.merged_environment(config, target)
        self.assertEqual(merged['IMMICH_WORKERS_INCLUDE'], 'api')
        with self.assertRaisesRegex(release.Stop, 'API_AND_MICROSERVICES_REQUIRED'):
            release.workers(merged)

    def test_compose_empty_and_unset_values_override_image_defaults(self):
        target = {'Config': {'Env': ['IMMICH_WORKERS_INCLUDE=api', 'IMMICH_WORKERS_EXCLUDE=microservices']}}
        for value in ('', None):
            with self.subTest(value=value):
                config = {'services': {release.SERVICE: {'environment': {
                    'IMMICH_WORKERS_INCLUDE': value, 'IMMICH_WORKERS_EXCLUDE': value}}}}
                merged = release.merged_environment(config, target)
                release.workers(merged)
                if value is None:
                    self.assertNotIn('IMMICH_WORKERS_INCLUDE', merged)
                    self.assertNotIn('IMMICH_WORKERS_EXCLUDE', merged)
                else:
                    self.assertEqual(merged['IMMICH_WORKERS_INCLUDE'], '')


class ResolvedComposeHash(unittest.TestCase):
    def setUp(self):
        self.base = [*LOCAL_DOCKER, 'compose', '--project-directory', '/synthetic/immich',
                     '-p', 'immich', '-f', '/synthetic/compose.yml', '-f', '/synthetic/recovery.json']
        self.resolved = {'name': 'immich', 'services': {release.SERVICE: {
            'image': PREVIOUS, 'environment': {'PRIVATE': 'synthetic-$$literal-$$$$', 'EMPTY': ''},
            'volumes': [{'type': 'bind', 'source': '/synthetic/evidence',
                         'target': '/run/recovery', 'read_only': True}]}},
            'networks': {'default': {'name': 'immich_default'}}}

    def test_hashes_full_compose_escaped_resolved_model_using_private_stdin(self):
        with patch.object(release, 'effective', return_value=self.resolved) as effective, \
                patch.object(release, 'run', return_value=release.SERVICE + ' ' + PREVIOUS_HASH + '\n') as run:
            self.assertEqual(release.config_hash(self.base), PREVIOUS_HASH)
        effective.assert_called_once_with(self.base, None)
        command = run.call_args.args[0]
        self.assertEqual(command, [*self.base[:self.base.index('-f')], '-f', '-', 'config', '--hash', release.SERVICE])
        self.assertEqual(json.loads(run.call_args.kwargs['input']), self.resolved)
        self.assertNotIn(self.resolved['services'][release.SERVICE]['environment']['PRIVATE'], command)

    def test_candidate_and_rollback_overrides_are_resolved_before_hashing(self):
        for name, target in (('image-only.override.json', CANDIDATE), ('rollback-image-only.override.json', PREVIOUS)):
            override = Path('/synthetic/' + name)
            resolved = copy.deepcopy(self.resolved)
            resolved['services'][release.SERVICE]['image'] = target
            with self.subTest(override=name), patch.object(release, 'effective', return_value=resolved) as effective, \
                    patch.object(release, 'run', return_value=release.SERVICE + ' ' + CANDIDATE_HASH) as run:
                release.config_hash(self.base, override)
            effective.assert_called_once_with(self.base, override)
            self.assertEqual(json.loads(run.call_args.kwargs['input']), resolved)

    def test_invalid_hash_output_and_unavailable_environment_resolution_fail_closed(self):
        for output in ('', PREVIOUS_HASH, 'foreign ' + PREVIOUS_HASH,
                       release.SERVICE + ' invalid', release.SERVICE + ' ' + PREVIOUS_HASH + ' extra'):
            with self.subTest(output=output), patch.object(release, 'effective', return_value=self.resolved), \
                    patch.object(release, 'run', return_value=output), \
                    self.assertRaisesRegex(release.Stop, 'COMPOSE_CONFIG_HASH_UNAVAILABLE'):
                release.config_hash(self.base)
        with patch.object(release, 'effective', side_effect=release.Stop('ENV_RESOLUTION_FAILED')), \
                patch.object(release, 'run') as run, self.assertRaisesRegex(release.Stop, 'ENV_RESOLUTION_FAILED'):
            release.config_hash(self.base)
        run.assert_not_called()


class DeletionQueueEvidence(unittest.TestCase):
    def valid(self):
        counts = {name: 0 for name in ('active', 'wait', 'paused', 'delayed', 'prioritized', 'waiting-children', 'failed')}
        return {'atomic': True, 'inventoryComplete': True, 'before': counts.copy(), 'counts': counts.copy(),
                'unresolvedDeletionHashes': 0, 'deletionNames': {'AssetDelete': 0, 'FileDelete': 0}}

    def test_reuses_atomic_counts_and_bounded_orphan_inventory_readonly(self):
        with patch.object(release, 'run', return_value=json.dumps(self.valid())) as run:
            self.assertEqual(release.queue_safety(), self.valid())
        self.assertEqual(run.call_args.args[0], [*LOCAL_DOCKER, 'exec', '-i', release.SERVER, 'node', '--input-type=module'])
        program = run.call_args.kwargs['input']
        for required in ('LLEN', 'ZCARD', 'inventoryComplete', 'AssetDelete', 'FileDelete'):
            self.assertIn(required, program)
        for forbidden in ('.del(', '.lpop(', '.rpop(', '.pause(', '.resume(', '.retry(', '.clean(', '.remove('):
            self.assertNotIn(forbidden, program)

    def test_scan_empty_but_atomic_state_nonempty_legacy_hash_or_incomplete_inventory_stops(self):
        for field in ('atomic', 'inventoryComplete', 'unresolvedDeletionHashes', 'AssetDelete', 'FileDelete',
                      'before.active', 'counts.wait', 'counts.failed', 'missing-state', 'boolean-count', 'error'):
            row = self.valid()
            if field in ('atomic', 'inventoryComplete'):
                row[field] = False
            elif field == 'unresolvedDeletionHashes':
                row[field] = 1
            elif field in ('AssetDelete', 'FileDelete'):
                row['deletionNames'][field] = 1
            elif '.' in field:
                group, state = field.split('.')
                row[group][state] = 1
            elif field == 'missing-state':
                row['counts'].pop('delayed')
            elif field == 'boolean-count':
                row['counts']['wait'] = False
            else:
                row['error'] = 'QUEUE_READ_FAILED'
            with self.subTest(field=field), patch.object(release, 'run', return_value=json.dumps(row)), \
                    self.assertRaisesRegex(release.Stop, 'DELETION_QUEUES_NONEMPTY_OR_INCOMPLETE_NO_JOBS_CHANGED'):
                release.queue_safety()


class OperatorFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / 'immich'
        self.directory.mkdir()
        self.state = self.root / 'state'
        self.state.mkdir(mode=0o700)
        self.files = [self.directory / 'docker-compose.yml', self.directory / 'local.override.json']
        for file in self.files:
            file.write_text('synthetic compose input\n')
        (self.directory / '.env').write_text('DB_PASSWORD=synthetic-private-value\n')
        directory_patch = patch.object(release, 'DIRECTORY', self.directory)
        directory_patch.start()
        self.addCleanup(directory_patch.stop)
        docker_patch = patch.object(release, 'DOCKER', LOCAL_DOCKER.copy())
        docker_patch.start()
        self.addCleanup(docker_patch.stop)
        self.base = [*LOCAL_DOCKER, 'compose', '--project-directory', str(self.directory), '-p', release.PROJECT,
                     *[part for file in self.files for part in ('-f', str(file))]]
        self.before = {'name': release.PROJECT, 'services': {
            release.SERVICE: {'image': 'gallery-server:local', 'container_name': release.SERVER,
                             'environment': {'DB_PASSWORD': 'synthetic-private-value',
                                             'IMMICH_WORKERS_INCLUDE': 'api, microservices',
                                             'IMMICH_WORKERS_EXCLUDE': ''},
                             'command': ['start.sh'], 'labels': {'kept': 'yes'},
                             'volumes': [{'type': 'bind', 'source': '/synthetic/media', 'target': '/data'}],
                             'ports': [{'target': 2283, 'published': '2283'}],
                             'depends_on': {'redis': {'condition': 'service_started'}},
                             'networks': {'default': {}}},
            'redis': {'image': 'redis:local', 'networks': {'default': {}}}},
            'networks': {'default': {'name': 'immich_default'}},
            'volumes': {'database': {'name': 'immich_database'}},
            'configs': {'app': {'file': '/synthetic/app.conf'}},
            'secrets': {'db': {'file': '/synthetic/db-password'}}}
        self.after = self.config_for(CANDIDATE)
        self.previous_image = {'Id': PREVIOUS, 'Architecture': 'amd64', 'Os': 'linux', 'Config': {'Env': [
            'IMMICH_SOURCE_COMMIT=' + PREVIOUS_SOURCE, 'IMMICH_WORKERS_INCLUDE=api,microservices']}}
        self.candidate_image = {'Id': CANDIDATE, 'Architecture': 'amd64', 'Os': 'linux', 'Config': {'Env': [
            'IMMICH_SOURCE_COMMIT=' + CANDIDATE_SOURCE]}}
        self.old = self.container(PREVIOUS, 'previous-container', PREVIOUS_HASH, PREVIOUS_SOURCE)
        self.other = {'/immich_redis': {'id': 'redis-container', 'image': 'redis-image', 'running': True},
                      '/unrelated_container': {'id': 'unrelated-container', 'image': 'other-image', 'running': False}}
        self.args = SimpleNamespace(state=self.state, image=CANDIDATE, expected_current_image=PREVIOUS,
                                    source_commit=CANDIDATE_SOURCE, server_version=(5, 7, 2),
                                    api='http://127.0.0.1:2283/api', execute_approved=True)

    def config_for(self, selected):
        config = copy.deepcopy(self.before)
        config['services'][release.SERVICE]['image'] = selected
        return config

    def container(self, selected, container_id, config_hash, source):
        return {'Name': '/' + release.SERVER, 'Id': container_id, 'Image': selected,
                'State': {'Running': True, 'Health': {'Status': 'healthy'}},
                'Config': {'Env': ['IMMICH_SOURCE_COMMIT=' + source,
                                   'IMMICH_WORKERS_INCLUDE=api, microservices', 'IMMICH_WORKERS_EXCLUDE='],
                           'Labels': {'com.docker.compose.project': release.PROJECT,
                                      'com.docker.compose.service': release.SERVICE,
                                      'com.docker.compose.project.working_dir': str(self.directory),
                                      'com.docker.compose.project.config_files': ','.join(map(str, self.files)),
                                      'com.docker.compose.config-hash': config_hash}}}

    def seed_plan(self):
        release.save(self.state / 'base-config.json', self.before)
        release.save(self.state / 'planned-config.json', self.after)
        release.save(self.state / 'image-only.override.json', {'services': {release.SERVICE: {'image': CANDIDATE}}})
        self.receipt = {'schemaVersion': 1, 'configHashMode': release.CONFIG_HASH_MODE,
                        'base': self.base, 'previousImage': PREVIOUS,
                        'candidateImage': CANDIDATE, 'previousContainer': self.old['Id'],
                        'previousSource': PREVIOUS_SOURCE, 'sourceCommit': CANDIDATE_SOURCE,
                        'rollbackImage': PREVIOUS, 'rollbackSource': PREVIOUS_SOURCE,
                        'rollbackVersion': {'major': 5, 'minor': 7, 'patch': 1, 'prerelease': None},
                        'candidateProof': proof(CANDIDATE_SOURCE, (5, 7, 2)),
                        'rollbackProof': proof(PREVIOUS_SOURCE, (5, 7, 1)),
                        'liveMigrations': [row['name'] for row in MIGRATIONS], 'migrationsAdded': [],
                        'previousVersion': {'major': 5, 'minor': 7, 'patch': 1, 'prerelease': None},
                        'serverVersion': {'major': 5, 'minor': 7, 'patch': 2, 'prerelease': None},
                        'api': self.args.api, 'otherContainers': copy.deepcopy(self.other),
                        'previousConfigHash': PREVIOUS_HASH, 'candidateConfigHash': CANDIDATE_HASH,
                        'fileHashes': {str(path): release.sha(path) for path in [*self.files, self.directory / '.env']},
                        'baseConfigSHA256': release.sha(self.state / 'base-config.json'),
                        'plannedConfigSHA256': release.sha(self.state / 'planned-config.json'),
                        'overrideSHA256': release.sha(self.state / 'image-only.override.json')}
        release.save(self.state / 'image-plan.json', self.receipt)

    @contextmanager
    def runtime(self, current=None):
        current = copy.deepcopy(current or self.old)
        def effective(base, override=None):
            if override is None:
                return copy.deepcopy(self.before)
            selected = release.private_json(override)['services'][release.SERVICE]['image']
            return self.config_for(selected)
        def image(selected):
            if selected == PREVIOUS:
                return copy.deepcopy(self.previous_image)
            if selected == CANDIDATE:
                return copy.deepcopy(self.candidate_image)
            raise release.Stop('LOCAL_IMAGE_ID_OR_PLATFORM_MISMATCH')
        def healthy(api, selected, source, version, **kwargs):
            expected_hash = PREVIOUS_HASH if selected == PREVIOUS else CANDIDATE_HASH
            return self.container(selected, 'healthy-container', expected_hash, source)
        def config_hash(base, override=None):
            return PREVIOUS_HASH if override is None or override.name.startswith('rollback-') else CANDIDATE_HASH
        with ExitStack() as stack:
            mocks = {}
            for name, kwargs in {
                'inspect': {'return_value': current}, 'effective': {'side_effect': effective},
                'image': {'side_effect': image}, 'inventory': {'return_value': copy.deepcopy(self.other)},
                'health': {'side_effect': healthy}, 'config_hash': {'side_effect': config_hash},
                'queue_safety': {'return_value': {}},
                'docker': {'return_value': json.dumps([self.previous_image])},
                'database_binding': {'return_value': None},
                'ping': {'return_value': {'major': 5, 'minor': 7, 'patch': 1, 'prerelease': None}},
                'run': {'return_value': ''}}.items():
                mocks[name] = stack.enter_context(patch.object(release, name, **kwargs))
            mocks['probe_image'] = stack.enter_context(patch.object(release, 'probe_image',
                side_effect=lambda selected, source, version: proof(source, version)))
            mocks['live_migrations'] = stack.enter_context(patch.object(release, 'live_migrations',
                return_value={row['name'] for row in MIGRATIONS}))
            stack.enter_context(patch.dict(os.environ, {'GALLERY_DEPLOYMENT_APPROVED': 'YES'}))
            stack.enter_context(redirect_stdout(io.StringIO()))
            yield mocks


class ComposeAndPlanning(OperatorFixture):
    def test_unmodified_build9_rollback_guard_refuses_plan_before_state_write(self):
        with self.runtime() as mocks:
            mocks['probe_image'].side_effect = [proof(CANDIDATE_SOURCE, (5, 7, 2)),
                                                release.Stop('HARDENED_IMAGE_CAPABILITY_SOURCE_VERSION_REQUIRED')]
            with self.assertRaisesRegex(release.Stop, 'HARDENED_IMAGE_CAPABILITY'):
                release.plan(self.args)
            mocks['run'].assert_not_called()
        self.assertEqual(list(self.state.iterdir()), [])

    def test_recognition_only_migration_or_changed_migration_bytes_cannot_authorize_rollback(self):
        for change in ('missing', 'modified'):
            unsafe = proof(PREVIOUS_SOURCE, (5, 7, 1))
            if change == 'missing':
                unsafe['migrations'].pop()
            else:
                unsafe['migrations'][-1]['sha256'] = 'f' * 64
            with self.subTest(change=change), self.runtime() as mocks:
                mocks['probe_image'].side_effect = [proof(CANDIDATE_SOURCE, (5, 7, 2)), unsafe]
                with self.assertRaisesRegex(release.Stop, 'HARDENED_ROLLBACK_MIGRATIONS_MUST_MATCH'):
                    release.plan(self.args)
            self.assertEqual(list(self.state.iterdir()), [])

    def test_candidate_cannot_remove_an_applied_migration(self):
        with self.runtime() as mocks:
            mocks['live_migrations'].return_value = {'1700000000000-AppliedButAbsent'}
            with self.assertRaisesRegex(release.Stop, 'CANDIDATE_MISSING_APPLIED_MIGRATION'):
                release.plan(self.args)
        self.assertEqual(list(self.state.iterdir()), [])

    def test_copied_capability_and_migrations_do_not_authorize_different_rollback_guards(self):
        for file in proof(PREVIOUS_SOURCE, (5, 7, 1))['guardFiles']:
            unsafe = proof(PREVIOUS_SOURCE, (5, 7, 1))
            unsafe['guardFiles'][file] = 'f' * 64
            with self.subTest(file=file), self.runtime() as mocks:
                mocks['probe_image'].side_effect = [proof(CANDIDATE_SOURCE, (5, 7, 2)), unsafe]
                with self.assertRaisesRegex(release.Stop, 'HARDENED_ROLLBACK_GUARD_FILES_MUST_MATCH'):
                    release.plan(self.args)
                mocks['run'].assert_not_called()
            self.assertEqual(list(self.state.iterdir()), [])

    def test_explicit_reviewed_hardened_rollback_image_replaces_unsafe_original_target(self):
        self.args.rollback_image = FOREIGN
        self.args.rollback_source_commit = 'c' * 40
        self.args.rollback_server_version = (5, 7, 1)
        alternate = copy.deepcopy(self.previous_image)
        alternate['Id'] = FOREIGN
        alternate['Config']['Env'] = ['IMMICH_SOURCE_COMMIT=' + 'c' * 40]
        with self.runtime() as mocks:
            original = mocks['image'].side_effect
            mocks['image'].side_effect = lambda selected: alternate if selected == FOREIGN else original(selected)
            release.plan(self.args)
            self.assertEqual([call.args[0] for call in mocks['probe_image'].call_args_list], [CANDIDATE, FOREIGN])
        receipt = release.private_json(self.state / 'image-plan.json')
        self.assertEqual(receipt['previousImage'], PREVIOUS)
        self.assertEqual(receipt['rollbackImage'], FOREIGN)

    def test_whole_effective_compose_allows_exactly_server_image_change(self):
        untouched = copy.deepcopy(self.before)
        release.image_only(self.before, self.after, CANDIDATE)
        self.assertEqual(self.before, untouched)

    def test_any_other_effective_compose_change_is_rejected(self):
        changes = {
            'server_environment': lambda config: config['services'][release.SERVICE]['environment'].update({'NEW': 'value'}),
            'server_command': lambda config: config['services'][release.SERVICE].update(command=['changed']),
            'server_mount': lambda config: config['services'][release.SERVICE]['volumes'][0].update(source='/other'),
            'server_port': lambda config: config['services'][release.SERVICE]['ports'][0].update(published='9999'),
            'server_label': lambda config: config['services'][release.SERVICE]['labels'].update(kept='no'),
            'other_service': lambda config: config['services']['redis'].update(image='other'),
            'removed_service': lambda config: config['services'].pop('redis'),
            'added_service': lambda config: config['services'].update(other={'image': 'other'}),
            'network': lambda config: config['networks']['default'].update(internal=True),
            'volume': lambda config: config['volumes']['database'].update(external=True),
            'config': lambda config: config['configs']['app'].update(file='/changed'),
            'secret': lambda config: config['secrets']['db'].update(file='/changed'),
            'project': lambda config: config.update(name='other'),
        }
        for name, mutate in changes.items():
            with self.subTest(change=name):
                changed = copy.deepcopy(self.after)
                mutate(changed)
                with self.assertRaisesRegex(release.Stop, 'COMPOSE_CHANGED_BEYOND_SELECTED_IMAGE'):
                    release.image_only(self.before, changed, CANDIDATE)

    def test_compose_invocation_keeps_all_original_files_in_order(self):
        base, files = release.compose_base(self.old)
        self.assertEqual(base, self.base)
        self.assertEqual(files, self.files)

    def test_foreign_project_service_directory_and_container_are_rejected(self):
        for key, value in (('com.docker.compose.project', 'foreign'),
                           ('com.docker.compose.service', 'foreign'),
                           ('com.docker.compose.project.working_dir', '/foreign')):
            changed = copy.deepcopy(self.old)
            changed['Config']['Labels'][key] = value
            with self.subTest(label=key), self.assertRaisesRegex(release.Stop, 'EXISTING_HP_COMPOSE_SERVER_REQUIRED'):
                release.compose_base(changed)
        changed = copy.deepcopy(self.old)
        changed['Name'] = '/other-server'
        with self.assertRaisesRegex(release.Stop, 'EXISTING_HP_COMPOSE_SERVER_REQUIRED'):
            release.compose_base(changed)

    def test_mutable_image_references_rejected_before_docker(self):
        for reference in ('gallery-server:release', CANDIDATE[:20], 'repository@' + CANDIDATE):
            with self.subTest(reference=reference), patch.object(release, 'docker') as docker:
                with self.assertRaisesRegex(release.Stop, 'IMMUTABLE_LOCAL_IMAGE_ID_REQUIRED'):
                    release.image(reference)
                docker.assert_not_called()

    def test_loaded_image_id_and_platform_must_match(self):
        for field, value in (('Id', FOREIGN), ('Architecture', 'arm64'), ('Os', 'windows')):
            changed = copy.deepcopy(self.candidate_image)
            changed[field] = value
            with self.subTest(field=field), patch.object(release, 'docker', return_value=json.dumps([changed])):
                with self.assertRaisesRegex(release.Stop, 'LOCAL_IMAGE_ID_OR_PLATFORM_MISMATCH'):
                    release.image(CANDIDATE)

    def test_plan_saves_private_complete_receipt_without_executing_commands(self):
        with self.runtime() as mocks:
            release.plan(self.args)
            mocks['run'].assert_not_called()
            mocks['docker'].assert_called_once_with('image', 'inspect', self.before['services'][release.SERVICE]['image'])
        receipt = release.private_json(self.state / 'image-plan.json')
        self.assertEqual(receipt['base'], self.base)
        self.assertEqual(receipt['previousImage'], PREVIOUS)
        self.assertEqual(receipt['candidateImage'], CANDIDATE)
        self.assertEqual(receipt['otherContainers'], self.other)
        for file in self.state.iterdir():
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)

    def test_plan_rejects_baseline_config_hash_drift_before_writing_state(self):
        with self.runtime() as mocks:
            mocks['config_hash'].return_value = 'f' * 64
            mocks['config_hash'].side_effect = None
            with self.assertRaisesRegex(release.Stop, 'COMPOSE_DIFFERS_FROM_RUNNING_SERVER'):
                release.plan(self.args)
            mocks['run'].assert_not_called()
        self.assertEqual(list(self.state.iterdir()), [])

    def test_plan_rejects_baked_api_only_candidate_defaults(self):
        self.before['services'][release.SERVICE]['environment'].pop('IMMICH_WORKERS_INCLUDE')
        self.candidate_image['Config']['Env'].append('IMMICH_WORKERS_INCLUDE=api')
        with self.runtime() as mocks:
            with self.assertRaisesRegex(release.Stop, 'API_AND_MICROSERVICES_REQUIRED'):
                release.plan(self.args)
            mocks['run'].assert_not_called()
        self.assertEqual(list(self.state.iterdir()), [])

    def test_changed_candidate_image_volume_defaults_cannot_create_anonymous_storage(self):
        self.candidate_image['Config']['Volumes'] = {'/unexpected-data': {}}
        with self.runtime() as mocks, self.assertRaisesRegex(release.Stop, 'IMAGE_VOLUME_DEFAULTS_CHANGED'):
            release.plan(self.args)
        mocks['run'].assert_not_called()
        self.assertEqual(list(self.state.iterdir()), [])

    def test_plan_changed_other_container_does_not_issue_receipt(self):
        with self.runtime() as mocks:
            mocks['inventory'].side_effect = [self.other, {}]
            with self.assertRaisesRegex(release.Stop, 'CONTAINERS_CHANGED_DURING_PLAN'):
                release.plan(self.args)
            mocks['run'].assert_not_called()
        self.assertFalse((self.state / 'image-plan.json').exists())


class PrerequisiteFailures(OperatorFixture):
    def setUp(self):
        super().setUp()
        self.seed_plan()

    def test_legacy_or_unknown_hash_mode_requires_a_new_plan_without_any_execution(self):
        for mode in (None, 'raw-env-file-omitting-hash', 'unknown'):
            changed = copy.deepcopy(self.receipt)
            changed['configHashMode'] = mode
            (self.state / 'image-plan.json').write_text(json.dumps(changed))
            with self.subTest(mode=mode), self.runtime() as mocks, \
                    self.assertRaisesRegex(release.Stop, 'NEW_RESOLVED_COMPOSE_PLAN_REQUIRED'):
                release.prerequisites(self.state)
            mocks['inspect'].assert_not_called()
            mocks['run'].assert_not_called()

    def test_original_compose_and_dotenv_mutations_rejected_before_docker(self):
        for path in [*self.files, self.directory / '.env']:
            with self.subTest(path=path):
                original = path.read_bytes()
                path.write_bytes(b'changed private input')
                with self.runtime() as mocks:
                    with self.assertRaisesRegex(release.Stop, 'COMPOSE_FILES_CHANGED'):
                        release.prerequisites(self.state)
                    mocks['inspect'].assert_not_called()
                    mocks['run'].assert_not_called()
                path.write_bytes(original)

    def test_changed_private_config_receipt_is_rejected(self):
        path = self.state / 'base-config.json'
        path.write_text('{"changed":true}')
        with self.runtime() as mocks:
            with self.assertRaisesRegex(release.Stop, 'PLAN_FILE_CHANGED'):
                release.prerequisites(self.state)
            mocks['inspect'].assert_not_called()

    def test_effective_config_drift_detects_interpolation_or_env_file_changes(self):
        changed = copy.deepcopy(self.before)
        changed['services'][release.SERVICE]['environment']['DB_PASSWORD'] = 'different-synthetic-private-value'
        with self.runtime() as mocks:
            mocks['effective'].side_effect = None
            mocks['effective'].return_value = changed
            with self.assertRaisesRegex(release.Stop, 'EFFECTIVE_COMPOSE_CHANGED'):
                release.prerequisites(self.state)
            mocks['inspect'].assert_not_called()

    def test_foreign_live_image_and_recreated_previous_container_are_rejected(self):
        for field, value, code in (('Image', FOREIGN, 'LIVE_IMAGE_CHANGED_EXTERNALLY'),
                                   ('Id', 'foreign-container', 'SERVER_CHANGED_SINCE_PLAN')):
            changed = copy.deepcopy(self.old)
            changed[field] = value
            with self.subTest(field=field), self.runtime(changed) as mocks:
                with self.assertRaisesRegex(release.Stop, code):
                    release.prerequisites(self.state)
                mocks['run'].assert_not_called()

    def test_live_compose_hash_drift_rejected(self):
        changed = copy.deepcopy(self.old)
        changed['Config']['Labels']['com.docker.compose.config-hash'] = 'f' * 64
        with self.runtime(changed) as mocks:
            with self.assertRaisesRegex(release.Stop, 'LIVE_COMPOSE_CHANGED_EXTERNALLY'):
                release.prerequisites(self.state)
            mocks['run'].assert_not_called()

    def test_other_container_identity_image_and_running_state_drift_rejected(self):
        for field, value in (('id', 'replacement'), ('image', 'replacement'), ('running', False)):
            changed = copy.deepcopy(self.other)
            changed['/immich_redis'][field] = value
            with self.subTest(field=field), self.runtime() as mocks:
                mocks['inventory'].return_value = changed
                with self.assertRaisesRegex(release.Stop, 'UNRELATED_CONTAINERS_CHANGED'):
                    release.prerequisites(self.state)
                mocks['run'].assert_not_called()

    def test_missing_previous_image_stops_rollback_without_loading_or_pulling(self):
        candidate = self.container(CANDIDATE, 'candidate-container', CANDIDATE_HASH, CANDIDATE_SOURCE)
        with self.runtime(candidate) as mocks:
            mocks['image'].side_effect = release.Stop('LOCAL_IMAGE_NOT_AVAILABLE')
            with self.assertRaisesRegex(release.Stop, 'LOCAL_IMAGE_NOT_AVAILABLE'):
                release.prerequisites(self.state, rollback=True)
            mocks['run'].assert_not_called()
            mocks['docker'].assert_not_called()

    def test_changed_actual_guard_proof_and_external_migrations_block_preflight(self):
        with self.runtime() as mocks:
            changed = proof(CANDIDATE_SOURCE, (5, 7, 2))
            changed['guardFiles']['utils/authorized-deletion.js'] = 'f' * 64
            mocks['probe_image'].return_value = changed
            mocks['probe_image'].side_effect = None
            with self.assertRaisesRegex(release.Stop, 'PACKAGED_IMAGE_PROOF_CHANGED'):
                release.prerequisites(self.state)
        with self.runtime() as mocks:
            mocks['live_migrations'].return_value = {'1700000000000-UnapprovedMigration'}
            with self.assertRaisesRegex(release.Stop, 'LIVE_MIGRATIONS_CHANGED_EXTERNALLY'):
                release.prerequisites(self.state, rollback=True)


class ServerHealth(OperatorFixture):
    def test_health_requires_running_immutable_image_workers_source_and_api_version(self):
        version = {'major': 5, 'minor': 7, 'patch': 2, 'prerelease': None}
        healthy = self.container(CANDIDATE, 'candidate-container', CANDIDATE_HASH, CANDIDATE_SOURCE)
        changes = {
            'wrong_image': lambda item: item.update(Image=FOREIGN),
            'unhealthy': lambda item: item['State']['Health'].update(Status='unhealthy'),
            'stopped': lambda item: item['State'].update(Running=False),
            'api_only': lambda item: item['Config'].update(Env=['IMMICH_SOURCE_COMMIT=' + CANDIDATE_SOURCE,
                                                            'IMMICH_WORKERS_INCLUDE=api']),
            'wrong_source': lambda item: item['Config'].update(Env=['IMMICH_SOURCE_COMMIT=' + PREVIOUS_SOURCE]),
        }
        for name, mutate in changes.items():
            changed = copy.deepcopy(healthy)
            mutate(changed)
            with self.subTest(change=name), patch.object(release, 'inspect', return_value=changed), \
                    patch.object(release, 'ping') as ping, patch.object(release.time, 'sleep') as sleep:
                with self.assertRaisesRegex(release.Stop, 'SERVER_HEALTH_FAILED_REVIEW_PLAN_FOR_ROLLBACK'):
                    release.health(self.args.api, CANDIDATE, CANDIDATE_SOURCE, version, timeout=0)
                ping.assert_not_called()
                sleep.assert_not_called()
        for responses in ([{'res': 'bad'}], [{'res': 'pong'}, {**version, 'patch': 1}]):
            with self.subTest(responses=responses), patch.object(release, 'inspect', return_value=healthy), \
                    patch.object(release, 'ping', side_effect=responses), patch.object(release.time, 'sleep') as sleep:
                with self.assertRaisesRegex(release.Stop, 'SERVER_HEALTH_FAILED_REVIEW_PLAN_FOR_ROLLBACK'):
                    release.health(self.args.api, CANDIDATE, CANDIDATE_SOURCE, version, timeout=0)
                sleep.assert_not_called()

    def test_health_accepts_actual_configuration_and_both_expected_api_responses(self):
        version = {'major': 5, 'minor': 7, 'patch': 2, 'prerelease': None}
        healthy = self.container(CANDIDATE, 'candidate-container', CANDIDATE_HASH, CANDIDATE_SOURCE)
        with patch.object(release, 'inspect', return_value=healthy), \
                patch.object(release, 'ping', side_effect=[{'res': 'pong'}, version]) as ping:
            self.assertEqual(release.health(self.args.api, CANDIDATE, CANDIDATE_SOURCE, version, timeout=0), healthy)
        self.assertEqual([call.args for call in ping.call_args_list],
                         [(self.args.api, '/server/ping'), (self.args.api, '/server/version')])


class ExecutionFailures(OperatorFixture):
    def setUp(self):
        super().setUp()
        self.seed_plan()

    def assert_no_completion(self, rollback=False):
        self.assertTrue((self.state / ('rollback-attempt.json' if rollback else 'apply-attempt.json')).is_file())
        self.assertFalse((self.state / ('rolled-back.json' if rollback else 'applied.json')).exists())

    def test_incomplete_or_nonempty_queue_stops_before_attempt_and_up(self):
        with self.runtime() as mocks:
            mocks['queue_safety'].side_effect = release.Stop('DELETION_QUEUES_NONEMPTY_OR_INCOMPLETE_NO_JOBS_CHANGED')
            with self.assertRaisesRegex(release.Stop, 'DELETION_QUEUES_NONEMPTY_OR_INCOMPLETE'):
                release.execute(self.args)
            mocks['run'].assert_not_called()
        self.assertFalse((self.state / 'apply-attempt.json').exists())

    def test_emergency_rollback_does_not_require_exec_in_a_stopped_api_container(self):
        release.save(self.state / 'apply-attempt.json', {'targetImage': CANDIDATE})
        current = self.container(CANDIDATE, 'failed-candidate', CANDIDATE_HASH, CANDIDATE_SOURCE)
        current['State']['Running'] = False
        with self.runtime(current) as mocks:
            mocks['queue_safety'].side_effect = AssertionError('stopped API must not be execed')
            release.execute(self.args, rollback=True)
            mocks['queue_safety'].assert_not_called()
        self.assertTrue((self.state / 'rolled-back.json').exists())

    def test_additive_migration_requires_separate_approval_before_attempt_or_up(self):
        baseline = {MIGRATIONS[0]['name']}
        self.receipt['liveMigrations'] = sorted(baseline)
        self.receipt['migrationsAdded'] = [release.BOUND_MIGRATION]
        (self.state / 'image-plan.json').write_text(json.dumps(self.receipt))
        with self.runtime() as mocks, patch.dict(os.environ, {'GALLERY_ADDITIVE_MIGRATION_APPROVED': ''}):
            mocks['live_migrations'].return_value = baseline
            with self.assertRaisesRegex(release.Stop, 'SEPARATE_ADDITIVE_MIGRATION_APPROVAL_REQUIRED'):
                release.execute(self.args)
            mocks['run'].assert_not_called()
        self.assertFalse((self.state / 'apply-attempt.json').exists())

    def test_exact_pending_migration_approval_is_recorded_before_up_and_checked_after(self):
        baseline = {MIGRATIONS[0]['name']}
        self.receipt['liveMigrations'] = sorted(baseline)
        self.receipt['migrationsAdded'] = [release.BOUND_MIGRATION]
        (self.state / 'image-plan.json').write_text(json.dumps(self.receipt))
        self.args.approve_migration = True
        with self.runtime() as mocks, patch.dict(os.environ, {'GALLERY_ADDITIVE_MIGRATION_APPROVED': 'YES'}):
            mocks['live_migrations'].return_value = baseline
            def up(*args, **kwargs):
                attempt = release.private_json(self.state / 'apply-attempt.json')
                self.assertEqual(attempt['migrationsApproved'], [release.BOUND_MIGRATION])
                mocks['live_migrations'].return_value = {row['name'] for row in MIGRATIONS}
                return ''
            mocks['run'].side_effect = up
            release.execute(self.args)
        self.assertTrue((self.state / 'applied.json').exists())

    def test_hardened_guard_marker_without_applied_binding_migration_fails_postcheck(self):
        with self.runtime() as mocks:
            def up(*args, **kwargs):
                mocks['live_migrations'].return_value = {MIGRATIONS[0]['name']}
                return ''
            mocks['run'].side_effect = up
            with self.assertRaisesRegex(release.Stop, 'APPLIED_MIGRATION_INVENTORY_MISMATCH'):
                release.execute(self.args)
        self.assert_no_completion()

    def test_bound_migration_alone_does_not_excuse_skipped_other_compiled_migrations(self):
        extra = {'name': '1793800000000-AdditionalRequiredMigration', 'sha256': 'f' * 64}
        for field in ('candidateProof', 'rollbackProof'):
            self.receipt[field]['migrations'].append(extra)
        self.receipt['migrationsAdded'] = [extra['name']]
        (self.state / 'image-plan.json').write_text(json.dumps(self.receipt))
        self.args.approve_migration = True
        with self.runtime() as mocks, patch.dict(os.environ, {'GALLERY_ADDITIVE_MIGRATION_APPROVED': 'YES'}):
            def reviewed(selected, source, version):
                actual = proof(source, version)
                actual['migrations'].append(extra)
                return actual
            mocks['probe_image'].side_effect = reviewed
            with self.assertRaisesRegex(release.Stop, 'APPLIED_MIGRATION_INVENTORY_MISMATCH'):
                release.execute(self.args)
            self.assertEqual(mocks['run'].call_count, 1)
        self.assert_no_completion()

    def test_apply_writes_journal_before_exact_single_service_compose_up(self):
        with self.runtime() as mocks:
            def up(command, timeout):
                self.assertEqual(command, [*self.base, '-f', str(self.state / 'image-only.override.json'),
                                           'up', '-d', '--no-deps', '--no-build', '--pull', 'never', release.SERVICE])
                self.assertEqual(timeout, 180)
                attempt = release.private_json(self.state / 'apply-attempt.json')
                self.assertEqual(attempt['targetImage'], CANDIDATE)
                self.assertFalse((self.state / 'applied.json').exists())
                return ''
            mocks['run'].side_effect = up
            release.execute(self.args)
            self.assertEqual(mocks['run'].call_count, 1)
            mocks['health'].assert_called_once_with(self.args.api, CANDIDATE, CANDIDATE_SOURCE, self.receipt['serverVersion'])
            mocks['docker'].assert_not_called()
        self.assertEqual(release.private_json(self.state / 'applied.json')['image'], CANDIDATE)

    def test_dry_run_apply_never_writes_attempt_or_executes_up(self):
        self.args.execute_approved = False
        with self.runtime() as mocks:
            release.execute(self.args)
            mocks['run'].assert_not_called()
            mocks['health'].assert_not_called()
        self.assertFalse((self.state / 'apply-attempt.json').exists())
        self.assertFalse((self.state / '.execution.lock').exists())

    def test_up_failure_and_timeout_keep_attempt_without_retry_or_completion(self):
        for error in (release.Stop('COMMAND_FAILED_PRIVATE_OUTPUT_OMITTED'), subprocess.TimeoutExpired('synthetic-up', 180)):
            with self.subTest(error=type(error).__name__):
                attempt = self.state / 'apply-attempt.json'
                if attempt.exists():
                    attempt.unlink()
                with self.runtime() as mocks:
                    mocks['run'].side_effect = error
                    with self.assertRaises(type(error)):
                        release.execute(self.args)
                    self.assertEqual(mocks['run'].call_count, 1)
                    mocks['health'].assert_not_called()
                self.assert_no_completion()
                with self.runtime() as mocks:
                    with self.assertRaisesRegex(release.Stop, 'EXISTING_ATTEMPT_RETAINED_DO_NOT_REPEAT'):
                        release.execute(self.args)
                    mocks['inspect'].assert_not_called()
                    mocks['run'].assert_not_called()

    def test_health_failure_keeps_attempt_and_does_not_automatically_rollback(self):
        with self.runtime() as mocks:
            mocks['health'].side_effect = release.Stop('SERVER_HEALTH_FAILED_REVIEW_PLAN_FOR_ROLLBACK')
            with self.assertRaisesRegex(release.Stop, 'SERVER_HEALTH_FAILED'):
                release.execute(self.args)
            self.assertEqual(mocks['run'].call_count, 1)
        self.assert_no_completion()
        self.assertFalse((self.state / 'rollback-attempt.json').exists())

    def test_second_preflight_under_lock_catches_drift_before_attempt(self):
        with self.runtime() as mocks, patch.object(release, 'prerequisites', side_effect=[
                (self.receipt, self.old), release.Stop('EFFECTIVE_COMPOSE_CHANGED')]) as preflight:
            with self.assertRaisesRegex(release.Stop, 'EFFECTIVE_COMPOSE_CHANGED'):
                release.execute(self.args)
            self.assertEqual(preflight.call_count, 2)
            mocks['run'].assert_not_called()
        self.assertFalse((self.state / 'apply-attempt.json').exists())

    def test_lock_contention_does_not_write_attempt_or_execute_up(self):
        with self.runtime() as mocks, patch.object(release.fcntl, 'flock', side_effect=BlockingIOError):
            with self.assertRaises(BlockingIOError):
                release.execute(self.args)
            mocks['run'].assert_not_called()
        self.assertFalse((self.state / 'apply-attempt.json').exists())

    def test_post_update_config_hash_mismatch_keeps_failed_attempt(self):
        with self.runtime() as mocks:
            mocks['health'].side_effect = None
            mocks['health'].return_value = self.container(CANDIDATE, 'new-container', 'f' * 64, CANDIDATE_SOURCE)
            with self.assertRaisesRegex(release.Stop, 'RECREATED_SERVER_CONFIG_MISMATCH'):
                release.execute(self.args)
            self.assertEqual(mocks['run'].call_count, 1)
        self.assert_no_completion()

    def test_post_update_other_container_change_keeps_failed_attempt(self):
        with self.runtime() as mocks:
            mocks['inventory'].side_effect = [self.other, self.other, {}]
            with self.assertRaisesRegex(release.Stop, 'UNRELATED_CONTAINERS_CHANGED'):
                release.execute(self.args)
            self.assertEqual(mocks['run'].call_count, 1)
        self.assert_no_completion()

    def test_post_update_compose_file_change_keeps_failed_attempt(self):
        with self.runtime() as mocks:
            def up(*args, **kwargs):
                self.files[0].write_text('changed during update')
                return ''
            mocks['run'].side_effect = up
            with self.assertRaisesRegex(release.Stop, 'COMPOSE_CHANGED_DURING_UPDATE'):
                release.execute(self.args)
        self.assert_no_completion()

    def test_rollback_uses_previous_immutable_image_and_image_only_override(self):
        release.save(self.state / 'apply-attempt.json', {'targetImage': CANDIDATE})
        candidate = self.container(CANDIDATE, 'candidate-container', CANDIDATE_HASH, CANDIDATE_SOURCE)
        with self.runtime(candidate) as mocks:
            def up(command, timeout):
                self.assertEqual(command, [*self.base, '-f', str(self.state / 'rollback-image-only.override.json'),
                                           'up', '-d', '--no-deps', '--no-build', '--pull', 'never', release.SERVICE])
                self.assertEqual(release.private_json(self.state / 'rollback-attempt.json')['targetImage'], PREVIOUS)
                return ''
            mocks['run'].side_effect = up
            release.execute(self.args, rollback=True)
            self.assertEqual(mocks['run'].call_count, 1)
            mocks['health'].assert_called_once_with(self.args.api, PREVIOUS, PREVIOUS_SOURCE, self.receipt['previousVersion'])
            mocks['docker'].assert_not_called()
        self.assertEqual(release.private_json(self.state / 'rollback-image-only.override.json'),
                         {'services': {release.SERVICE: {'image': PREVIOUS}}})
        self.assertEqual(release.private_json(self.state / 'rolled-back.json')['image'], PREVIOUS)

    def test_stopped_candidate_rolls_back_using_existing_postgres_evidence_without_api_exec(self):
        release.save(self.state / 'apply-attempt.json', {'targetImage': CANDIDATE})
        candidate = self.container(CANDIDATE, 'candidate-container', CANDIDATE_HASH, CANDIDATE_SOURCE)
        candidate['State']['Running'] = False
        with self.runtime(candidate) as mocks:
            release.execute(self.args, rollback=True)
            self.assertEqual(mocks['run'].call_count, 1)
            mocks['health'].assert_called_once_with(self.args.api, PREVIOUS, PREVIOUS_SOURCE, self.receipt['rollbackVersion'])
            mocks['ping'].assert_not_called()
            mocks['docker'].assert_not_called()
            self.assertGreaterEqual(mocks['live_migrations'].call_count, 3)
        self.assertTrue((self.state / 'rolled-back.json').exists())

    def test_stopped_previous_image_is_started_when_failed_apply_stopped_it_before_recreation(self):
        release.save(self.state / 'apply-attempt.json', {'targetImage': CANDIDATE})
        stopped = copy.deepcopy(self.old)
        stopped['State']['Running'] = False
        with self.runtime(stopped) as mocks:
            release.execute(self.args, rollback=True)
            self.assertEqual(mocks['run'].call_count, 1)
            self.assertIn('--no-deps', mocks['run'].call_args.args[0])
            mocks['health'].assert_called_once_with(self.args.api, PREVIOUS, PREVIOUS_SOURCE, self.receipt['rollbackVersion'])
        self.assertTrue((self.state / 'rolled-back.json').exists())

    def test_distinct_reviewed_hardened_rollback_image_is_used_instead_of_unsafe_original(self):
        release.save(self.state / 'apply-attempt.json', {'targetImage': CANDIDATE})
        source, rollback_hash = 'c' * 40, 'f' * 64
        self.receipt.update(rollbackImage=FOREIGN, rollbackSource=source,
                            rollbackProof=proof(source, (5, 7, 1)))
        (self.state / 'image-plan.json').write_text(json.dumps(self.receipt))
        candidate = self.container(CANDIDATE, 'candidate-container', CANDIDATE_HASH, CANDIDATE_SOURCE)
        alternate = copy.deepcopy(self.previous_image)
        alternate['Id'] = FOREIGN
        alternate['Config']['Env'] = ['IMMICH_SOURCE_COMMIT=' + source]
        with self.runtime(candidate) as mocks:
            original = mocks['image'].side_effect
            mocks['image'].side_effect = lambda selected: alternate if selected == FOREIGN else original(selected)
            mocks['health'].side_effect = None
            mocks['health'].return_value = self.container(FOREIGN, 'hardened-rollback-container', rollback_hash, source)
            original_hash = mocks['config_hash'].side_effect
            mocks['config_hash'].side_effect = lambda base, override=None: rollback_hash if override and override.name.startswith('rollback-') else original_hash(base, override)
            release.execute(self.args, rollback=True)
            self.assertEqual(mocks['run'].call_count, 1)
            mocks['health'].assert_called_once_with(self.args.api, FOREIGN, source, self.receipt['rollbackVersion'])
        self.assertEqual(release.private_json(self.state / 'rolled-back.json')['image'], FOREIGN)
        self.assertEqual(release.private_json(self.state / 'rollback-image-only.override.json'),
                         {'services': {release.SERVICE: {'image': FOREIGN}}})

    def test_rollback_requires_an_update_attempt_before_mutation(self):
        with self.runtime() as mocks:
            with self.assertRaisesRegex(release.Stop, 'UPDATE_ATTEMPT_REQUIRED_FOR_ROLLBACK'):
                release.execute(self.args, rollback=True)
            mocks['run'].assert_not_called()
        self.assertFalse((self.state / 'rollback-attempt.json').exists())

    def test_failed_apply_before_recreation_rolls_back_without_recreating_previous_image(self):
        release.save(self.state / 'apply-attempt.json', {'targetImage': CANDIDATE})
        with self.runtime() as mocks:
            release.execute(self.args, rollback=True)
            mocks['run'].assert_not_called()
            mocks['health'].assert_called_once_with(self.args.api, PREVIOUS, PREVIOUS_SOURCE, self.receipt['previousVersion'])
        self.assertTrue((self.state / 'rolled-back.json').is_file())

    def test_rollback_up_failure_preserves_attempt_and_blocks_repeat(self):
        release.save(self.state / 'apply-attempt.json', {'targetImage': CANDIDATE})
        candidate = self.container(CANDIDATE, 'candidate-container', CANDIDATE_HASH, CANDIDATE_SOURCE)
        with self.runtime(candidate) as mocks:
            mocks['run'].side_effect = release.Stop('COMMAND_FAILED_PRIVATE_OUTPUT_OMITTED')
            with self.assertRaisesRegex(release.Stop, 'COMMAND_FAILED'):
                release.execute(self.args, rollback=True)
        self.assert_no_completion(rollback=True)
        with self.runtime(candidate) as mocks:
            with self.assertRaisesRegex(release.Stop, 'EXISTING_ATTEMPT_RETAINED_DO_NOT_REPEAT'):
                release.execute(self.args, rollback=True)
            mocks['run'].assert_not_called()

    def test_main_missing_approval_blocks_before_execution_or_private_probe(self):
        with patch.dict(os.environ, {'GALLERY_DEPLOYMENT_APPROVED': ''}), \
                patch.object(release, 'execute') as execute, patch.object(release, 'docker') as docker, \
                redirect_stderr(io.StringIO()):
            result = release.main(['apply', '--state', str(self.state), '--execute-approved'])
        self.assertEqual(result, 1)
        execute.assert_not_called()
        docker.assert_not_called()

    def test_main_plan_never_accepts_execution_flag(self):
        with patch.dict(os.environ, {'GALLERY_DEPLOYMENT_APPROVED': 'YES'}), \
                patch.object(release, 'plan') as plan, redirect_stderr(io.StringIO()):
            result = release.main(['plan', '--state', str(self.state), '--execute-approved'])
        self.assertEqual(result, 1)
        plan.assert_not_called()

    def test_main_command_failure_does_not_print_private_output(self):
        output = io.StringIO()
        with patch.object(release, 'execute', side_effect=subprocess.TimeoutExpired(
                'synthetic-command', 180, output='synthetic-private-value', stderr='private-config')), \
                redirect_stderr(output):
            result = release.main(['apply', '--state', str(self.state)])
        self.assertEqual(result, 1)
        self.assertEqual(output.getvalue(), 'STOP OPERATION_FAILED_PRIVATE_DETAILS_OMITTED\n')


if __name__ == '__main__':
    unittest.main()
