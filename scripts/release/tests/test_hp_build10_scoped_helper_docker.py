"""Real Docker profile/early-STOP recovery; synthetic files, no HP or application bootstrap."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('helper_docker', ROOT/'scripts/release/hp_build10_queued_delete.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


@unittest.skipUnless(os.environ.get('GALLERY_SCOPED_HELPER_DOCKER') == 'YES', 'explicit disposable local Docker opt-in')
class DockerHelper(unittest.TestCase):
    def test_actual_cap_serialization_kernel_sandbox_and_unsealed_helper_recovery(self):
        # Reuse cached redis image; mount existing Node/glibc RO only in this lab.
        # No image pull/build, production services, sockets, databases or network egress.
        env = dict(os.environ)
        for k in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH'): env.pop(k, None)
        command = ['docker', '--host=unix:///var/run/docker.sock']
        def docker(*args):
            return subprocess.run([*command, *args], env=env, capture_output=True, text=True,
                                  check=True, timeout=30).stdout.strip()
        image = docker('image', 'inspect', 'redis:7-alpine', '--format', '{{.Id}}')
        containers = []
        label = 'gallery.scoped-helper.fixture=' + uuid.uuid4().hex
        def cleanup():
            owned = list(dict.fromkeys([*containers, *docker('ps', '-aq', '--no-trunc', '--filter', 'label='+label).split()]))
            for identifier in reversed(owned):
                item = json.loads(docker('inspect', identifier))[0]
                self.assertEqual(item['Config']['Labels'].get('gallery.scoped-helper.fixture'), label.split('=', 1)[1])
                docker('rm', '-f', identifier)  # Only these explicitly labelled, disposable IDs.
        self.addCleanup(cleanup)
        tmp = tempfile.TemporaryDirectory(prefix='gallery-helper-docker-')
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name); root.chmod(0o755)
        media = root/'media'; media.mkdir(mode=0o755); media.chmod(0o755)
        selected = media/'thumbs'; selected.mkdir(mode=0o755); selected.chmod(0o755)
        runroot = root/'private-run'; runroot.mkdir(mode=0o700)
        node = root/'fixture-node'
        shutil.copyfile(Path(shutil.which('node')).resolve(), node)
        node.chmod(0o755)  # The cached host executable is owner-only; never chmod the toolchain itself.
        r = m.Runner(runroot); r.phase.mkdir(mode=0o700)
        r.core.DOCKER = command
        r.core.SERVER = 'gallery-helper-base-'+uuid.uuid4().hex[:12]
        r.hp.CURRENT = image; r.hp.TARGET = image
        mounts = ['--mount', f'type=bind,src={media},dst=/data', '--mount',
                  f'type=bind,src={node},dst=/usr/local/bin/node,readonly',
                  '--mount', 'type=bind,src=/lib/x86_64-linux-gnu,dst=/lib/x86_64-linux-gnu,readonly',
                  '--mount', f'type=bind,src={Path("/lib64/ld-linux-x86-64.so.2").resolve()},dst=/lib64/ld-linux-x86-64.so.2,readonly']
        base = docker('run', '-d', '--pull', 'never', '--name', r.core.SERVER, '--label', label,
                      '--network', 'none', '--read-only', *mounts, '--entrypoint', 'node', image,
                      '-e', 'setInterval(()=>{},10000)'); containers.append(base)
        current = json.loads(docker('inspect', base))[0]
        # Only the selected synthetic directory is writable. Existing RO binds stay RO.
        helper = docker('run', '-d', '--pull', 'never', '--name', r.helper, '--label', label,
                        '--label', 'gallery.confirmed-files.run='+str(runroot), '--network', 'container:'+r.core.SERVER,
                        '--volumes-from', r.core.SERVER+':ro', '--mount', f'type=bind,src={selected},dst=/data/thumbs',
                        '--read-only', '--cap-drop', 'ALL', '--cap-add', 'FOWNER', '--security-opt', 'no-new-privileges',
                        '--pids-limit', '128', '--memory', '512m', '--cpus', '0.5', '--entrypoint', 'node', image,
                        '-e', 'setInterval(()=>{},10000)'); containers.append(helper)
        item = json.loads(docker('inspect', helper))[0]
        self.assertIn(item['HostConfig']['CapAdd'], (['FOWNER'], ['CAP_FOWNER']))
        m.security_profile(r.core, item, current)
        kernel = json.loads(docker('exec', helper, 'node', '--input-type=module', '-e', m.KERNEL_PROFILE_PROBE))
        self.assertEqual(kernel['NoNewPrivs'], '1'); self.assertEqual(kernel['Seccomp'], '2')
        self.assertEqual(int(kernel['CapBnd'], 16), 8)
        st = selected.stat()
        physical = [{'path': '/data/thumbs', 'device': str(st.st_dev), 'inode': str(st.st_ino),
                     'uid': str(st.st_uid), 'gid': str(st.st_gid)}]
        intent = {'rootPhysical': physical, 'files': [{'root': '/data/thumbs'}]}
        r.values = lambda: {'snapshot': {'mediaRoot': '/data'}, 'snapshotSeal': 'fixture-seal'}
        r.intent_values = lambda: {'intent': intent, 'intentSeal': 'fixture-intent-seal'}
        r.node = Mock(return_value=intent)  # SQL/queue native guards covered by the separate PG/Redis lab.
        r.handlers = Mock()  # Frozen application module hashes covered by operator checks; not present in redis image.
        r.core.save(r.phase/'stop-fixture.json', {'code': 'SCOPED_HELPER_SECURITY_PROFILE_REQUIRED'})
        (r.phase/'native-handler.env').write_text('\n'.join(current['Config']['Env'])+'\n')
        (r.phase/'native-handler.env').chmod(0o600)
        # Only the realpath read uses a local unprivileged adapter; Docker stays on the verified local socket.
        run = r.core.run
        r.core.run = lambda args, **kw: str(Path(args[-1]).resolve(strict=True))+'\n' if args[:3] == ['sudo','-n','realpath'] else run(args, **kw)
        r.core.inventory = lambda: {'/'+r.helper: {'id': helper}, '/fixture-preserved': {'id': base}}
        observed = []
        r.core.prerequisites = lambda state: observed.append(r.core.inventory())
        with redirect_stdout(io.StringIO()): r.preparation_prerequisites(runroot)
        r.helper_binding(item)
        self.assertFalse((r.phase/'file-proofs.json').exists())
        self.assertTrue(list(r.phase.glob('helper-recovery-*.json')))
        self.assertEqual(observed, [{'/fixture-preserved': {'id': base}}])
        r.start_helper()  # Verified reuse: no new container or namespace after early-STOP recovery.
        self.assertEqual(json.loads(docker('inspect', helper))[0]['Id'], helper)


if __name__ == '__main__': unittest.main()
