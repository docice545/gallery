"""Pinned build-9 guards. No real keys, media or production services."""
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts/release'))
import release_candidate as c
import rollback_bridge as bridge


def profile():
    source = 'a' * 40
    return dict(schemaVersion=2, productionBase=c.BASE, sourceCommit=source, serverVersion='5.7.2',
                mobileVersion='5.7.2', mobileBuild=9, backendRun=1, backendArtifactId=4,
                backend=dict(sourceCommit=source, serverVersion='5.7.2', mobileVersion='5.7.2', mobileBuild=9,
                             schemaDelta='ADDITIVE_AUTHORIZED_DELETION', migrationsAdded=[c.MIGRATION], platform='linux/amd64',
                             imageTag='gallery-server:trash-' + source[:12], imageId='sha256:' + 'b'*64,
                             archiveSHA256='c'*64,
                             isolatedSmoke='PASS: fresh PG migrations + HTTP Trash/Restore/permanent deletion + read-only audit'),
                android=dict(sourceCommit=source, run=2, artifactId=5, sha256='d'*64, certificateSHA256='e'*64),
                ios=dict(sourceCommit=source, run=3, artifactId=6, sha256='f'*64))


class CandidateGuards(unittest.TestCase):
    def test_exact_build9_contract(self):
        self.assertEqual(c.validate(profile())['mobileBuild'], 9)

    def test_old_other_or_partial_contract_rejected(self):
        for fields in ({'mobileBuild': 8}, {'productionBase': 'b'*40}, {'sourceCommit': 'abcd'}, {'serverVersion': '5.7.1'}):
            value = profile(); value.update(fields)
            with self.assertRaises(ValueError): c.validate(value)

    def test_cross_source_or_extra_migration_or_unverified_smoke_rejected(self):
        for target, change in [('ios', {'sourceCommit': 'b'*40}), ('android', {'run': 0}),
                              ('backend', {'migrationsAdded': [c.MIGRATION, 'other']}), ('backend', {'isolatedSmoke': 'not run'})]:
            value = profile(); value[target].update(change)
            with self.assertRaises(ValueError): c.validate(value)

    def test_profile_requires_independently_pinned_hash_and_no_symlink(self):
        with tempfile.TemporaryDirectory() as d:
            file = Path(d)/'profile.json'; file.write_text(json.dumps(profile()))
            digest = c.digest(file)
            self.assertEqual(c.load(file, digest), profile())
            for expected in (None, 'a'*64):
                with self.assertRaises(ValueError): c.load(file, expected)
            link = Path(d)/'link'; link.symlink_to(file)
            with self.assertRaises(ValueError): c.load(link, digest)
            file.write_text(json.dumps({**profile(), 'mobileBuild': 10}))
            with self.assertRaises(ValueError): c.load(file, digest)

    def test_migration_transition_is_exactly_one_addition(self):
        from types import SimpleNamespace
        p = profile(); target = ['base', c.MIGRATION]
        tool = SimpleNamespace(health=Mock(), docker=Mock(side_effect=[json.dumps(['base']), json.dumps(target)]),
                               SERVER='fixture', NODE_MIGRATIONS='fixture')
        c.configure(tool, p)
        self.assertEqual(tool.migrations_match(tool.IMAGE), sorted(target))
        tool.docker.side_effect = [json.dumps(['base']), json.dumps([*target, 'unapproved'])]
        with self.assertRaisesRegex(ValueError, 'EXACT_ADDITIVE'): tool.migrations_match(tool.IMAGE)

    def test_manifest_changed_or_archive_tampered_rejected(self):
        from types import SimpleNamespace
        p = profile()
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); (root/'gallery-server-linux-amd64.tar.gz').write_bytes(b'fixture')
            p['backend']['archiveSHA256'] = c.digest(root/'gallery-server-linux-amd64.tar.gz')
            (root/'manifest.json').write_text(json.dumps(p['backend']))
            tool = SimpleNamespace(health=Mock()); c.configure(tool, p)
            self.assertEqual(tool.verify_artifact(root).name, 'gallery-server-linux-amd64.tar.gz')
            (root/'gallery-server-linux-amd64.tar.gz').write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError, 'ARCHIVE_CHANGED'): tool.verify_artifact(root)

    def test_rollback_marker_never_applies_or_reverts_migration(self):
        # Real node evaluates shipped bytes, not a test reimplementation.
        with tempfile.TemporaryDirectory() as d:
            # .js must inherit type=module exactly as the actual server package.
            file = Path(d)/(c.MIGRATION+'.js'); file.write_bytes(bridge.MARKER)
            (Path(d)/'package.json').write_text('{"type":"module"}')
            code = "import(process.argv[1]).then(m=>Promise.allSettled([m.up(),m.down()])).then(r=>{if(r.some(v=>v.status!=='rejected'))process.exit(1)});"
            subprocess.run(['node', '-e', code, str(file)], check=True, capture_output=True)

    def test_rollback_wrong_parent_or_modified_config_rejected(self):
        from types import SimpleNamespace
        before = dict(Id='sha256:'+'a'*64, RootFS={'Layers': ['base']}, Config={'Env': ['fixture']}, Architecture='amd64', Os='linux')
        for changes in ({'RootFS': {'Layers': ['other', 'new']}}, {'Config': {'Env': ['modified']}}, {'Id': 'sha256:'+'c'*64}):
            after = {**copy.deepcopy(before), 'Id': 'sha256:'+'b'*64, 'RootFS': {'Layers': ['base', 'new']}, **changes}
            tool = SimpleNamespace(docker=Mock(return_value=json.dumps([before,after])))
            with self.assertRaises(ValueError): bridge.verify(tool, before['Id'], 'sha256:'+'b'*64)

    def test_isolated_migration_rejects_production_namespace_or_mounts(self):
        from types import SimpleNamespace
        import candidate_restore
        tool = SimpleNamespace(CANDIDATE_PROFILE=profile(), inspect=Mock())
        with self.assertRaisesRegex(ValueError, 'RESTORE_NAME_REQUIRED'):
            candidate_restore.transition(tool, Mock(), 'immich_postgres', [], {}, Path('/unused'), Path('/unused'))
        tool.inspect.assert_not_called()
        for fields in ({'NetworkMode': 'host'}, {'Binds': ['/production:/data']},
                       {'VolumesFrom': ['production']}, {'PortBindings': {'5432': [{}]}}):
            tool.inspect.return_value = {'HostConfig': {'NetworkMode': 'none', **fields}}
            with self.assertRaisesRegex(ValueError, 'NO_PRODUCTION_NETWORK_OR_MOUNTS'):
                candidate_restore.transition(tool, Mock(), 'gallery-restore-check-'+'a'*16,
                                             [], {}, Path('/unused'), Path('/unused'))

    def test_library_opt_in_requires_separate_approval_before_access(self):
        from types import SimpleNamespace
        from unittest.mock import patch
        import authorize_library
        import trash_predeploy
        args=SimpleNamespace(approve_library=False)
        with patch.dict(os.environ,{'GALLERY_LIBRARY_DELETION_APPROVED':'YES'}), \
             patch.object(c,'load') as read:
            with self.assertRaisesRegex(trash_predeploy.Stop,'SEPARATE_OWNER_LIBRARY'):
                authorize_library.authorize(args)
            read.assert_not_called()
        args.approve_library=True; args.api='https://external.invalid/api'
        with patch.dict(os.environ,{'GALLERY_LIBRARY_DELETION_APPROVED':'YES'}), patch.object(c,'load') as read:
            with self.assertRaisesRegex(trash_predeploy.Stop,'LOCAL_GALLERY_API'):
                authorize_library.authorize(args)
            read.assert_not_called()

    def test_isolated_transition_requires_unchanged_counts_and_default_off(self):
        from types import SimpleNamespace
        from unittest.mock import patch
        import candidate_restore
        import trash_predeploy
        before = dict(assetCount=3, libraryCount=1, statusCounts={'active':3}, migrationNames=['base'], orphans=0)
        after = {**before, 'migrationNames':sorted(['base',c.MIGRATION])}
        tool = SimpleNamespace(CANDIDATE_PROFILE=profile(), IMAGE='candidate',
                               inspect=Mock(return_value={'HostConfig': {'NetworkMode':'none'}}))
        with tempfile.TemporaryDirectory() as d:
            state=Path(d); backup=state/'fresh.sql.gz'; backup.write_bytes(b'private fixture')
            for results, expected in (([json.dumps({**after,'assetCount':4,'statusCounts':{'active':4}})], 'CHANGED_ASSETS'),
                                      ([json.dumps(after),json.dumps(after),'[0,1]'], 'START_DISABLED')):
                def fixture(*args, **kwargs):
                    return '' if args[0] == 'run' else results.pop(0)
                with patch.object(trash_predeploy,'private_json',return_value={'imageId':'bridge'}), \
                     patch.object(bridge,'ensure'), self.assertRaisesRegex(ValueError,expected):
                    candidate_restore.transition(tool, fixture, 'gallery-restore-check-'+'a'*16,
                                                 ['exec','fixture','psql'],before,state,backup)
            values=[json.dumps(after),json.dumps(after),'[0,0]']; calls=[]
            def fixture(*args, **kwargs):
                calls.append(args)
                return '' if args[0] == 'run' else values.pop(0)
            with patch.object(trash_predeploy,'private_json',return_value={'imageId':'bridge'}), patch.object(bridge,'ensure'):
                candidate_restore.transition(tool,fixture,'gallery-restore-check-'+'a'*16,
                                             ['exec','fixture','psql'],before,state,backup)
            receipt=json.loads((state/'candidate-migration-verified.json').read_text())
            self.assertEqual(receipt['validation'],'PASS_ISOLATED_ADDITIVE_UPGRADE_AND_ROLLBACK_STARTUP')
            runs=[row for row in calls if row[0]=='run']
            self.assertEqual([row[-4] for row in runs],['candidate','bridge'])
            self.assertTrue(all('container:gallery-restore-check-'+'a'*16 in row and '--read-only' in row for row in runs))


@unittest.skipUnless(os.environ.get('GALLERY_DISPOSABLE_RELEASE_TESTS') == '1', 'isolated Docker fixture opt-in')
class RealRollbackBridge(unittest.TestCase):
    def test_actual_single_layer_overlay_and_tamper_guard(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); state = root/'private'; state.mkdir(mode=0o700)
            (root/'sentinel').write_text('immutable synthetic previous application')
            (root/'Dockerfile').write_text('FROM scratch\nCOPY sentinel /sentinel\n')
            def docker(*args, **kwargs):
                return subprocess.run(['docker','--host=unix:///var/run/docker.sock',*args], text=True,
                                      input=kwargs.get('input'), capture_output=True, check=True,
                                      timeout=kwargs.get('timeout',120)).stdout.strip()
            idfile = root/'parent-id'
            docker('build','--network','none','--iidfile',str(idfile),str(root))
            parent = idfile.read_text().strip()
            tool = SimpleNamespace(SERVER='synthetic-never-production', DOCKER=['docker','--host=unix:///var/run/docker.sock'],
                                   inspect=Mock(return_value={'Image':parent}), docker=docker)
            child = None
            try:
                bridge.prepare(tool,state,root)
                proof = json.loads((state/'rollback-bridge.json').read_text()); child = proof['imageId']
                self.assertEqual(bridge.verify(tool,parent,child),{k:v for k,v in proof.items() if k != 'archiveSHA256'})
                bridge.prepare(tool,state,root)  # idempotent, checks actual immutable child again.
                docker('image','rm',child)
                bridge.prepare(tool,state,root)  # exact saved archive, no pull/tag substitution.
                archive=state/'rollback-bridge-image.tar'
                with archive.open('ab') as file: file.write(b'tampered')
                with self.assertRaisesRegex(ValueError,'ARCHIVE_CHANGED'): bridge.prepare(tool,state,root)
                with archive.open('r+b') as file: file.truncate(archive.stat().st_size-len(b'tampered'))
                proof['markerSHA256']='0'*64
                (state/'rollback-bridge.json').write_text(json.dumps(proof))
                with self.assertRaisesRegex(ValueError,'RECEIPT_CHANGED'): bridge.prepare(tool,state,root)
            finally:
                for image in (child,parent):
                    if image: docker('image','rm',image)


if __name__ == '__main__': unittest.main()
