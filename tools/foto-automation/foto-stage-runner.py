#!/usr/bin/env python3
"""Serialized, resumable FOTO checks. No shell, production access or automatic retry."""
import argparse
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.parse import urlsplit

DEFAULT_STATE = Path('/mnt/hp-data/codex-work/foto-integration-state')


class Stop(Exception):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def output_identity(repo, stage):
    outputs = {
        'backend-build': ['server/dist/main.js', 'server/dist/bin/sync-open-api.js'],
        'sdk-build': ['packages/sdk/build/index.js', 'packages/sdk/build/index.d.ts'],
        'plugin-sdk-build': ['packages/plugin-sdk/dist/index.js', 'packages/plugin-sdk/dist/index.d.ts'],
        'android-apk': ['mobile/build/app/outputs/flutter-apk/app-release.apk'],
        'openapi-spec': ['open-api/immich-openapi-specs.json'],
        'openapi-typescript': ['packages/sdk/src/fetch-client.ts'],
        'openapi-dart': ['mobile/generated/openapi/lib/model/asset_media_response_dto.dart'],
    }.get(stage, [])
    return {p: file_digest(repo / p) for p in outputs}


def private_dir(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    s = path.lstat()
    if not stat.S_ISDIR(s.st_mode) or s.st_uid != os.getuid() or stat.S_IMODE(s.st_mode) != 0o700:
        raise Stop('STATE_DIRECTORY_NOT_PRIVATE')


def read_json(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'r') as f:
        s = os.fstat(f.fileno())
        if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid() or stat.S_IMODE(s.st_mode) != 0o600:
            raise Stop('STATE_FILE_NOT_PRIVATE')
        return json.load(f)


def atomic_json(path, value):
    fd, name = tempfile.mkstemp(prefix='.pending-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(value, f, sort_keys=True, indent=2)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def lock(path, legacy=False):
    fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_CREAT, 0o600)
    s = os.fstat(fd)
    safe_mode = not (s.st_mode & 0o022) if legacy else stat.S_IMODE(s.st_mode) == 0o600
    if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid() or not safe_mode:
        os.close(fd)
        raise Stop('UNSAFE_LOCK')
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        raise Stop('BUSY: another FOTO process holds this lock') from None
    return fd


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.DEVNULL)


def source_identity(repo, excludes=()):
    head = git(repo, 'rev-parse', 'HEAD').decode().strip()
    h = hashlib.sha256(git(repo, 'diff', 'HEAD', '--binary', '--', '.',
        *(f':(exclude){p}' for p in excludes)))
    for name in git(repo, 'ls-files', '--others', '--exclude-standard', '-z').split(b'\0'):
        if not name:
            continue
        if any(os.fsdecode(name) == p or os.fsdecode(name).startswith(p + '/') for p in excludes):
            continue
        p = repo / os.fsdecode(name)
        h.update(name)
        if p.is_symlink():
            h.update(os.fsencode(os.readlink(p)))
        elif p.is_file():
            with p.open('rb') as f:
                for block in iter(lambda: f.read(1024 * 1024), b''):
                    h.update(block)
        else:
            raise Stop('UNSUPPORTED_UNTRACKED_INPUT')
    return {'head': head, 'changesSHA256': h.hexdigest()}


def command(repo, stage, files):
    node = shutil.which('node')
    flutter = shutil.which('flutter')
    for name in files:
        p = repo / ('mobile' if stage == 'flutter-test' else 'server') / name
        if name.startswith('-') or not p.is_file() or not p.resolve().is_relative_to(repo):
            raise Stop('INVALID_TEST_TARGET')
        if stage in ('unit', 'medium') and not name.endswith('.spec.ts'):
            raise Stop('EXPLICIT_SPEC_REQUIRED')
        if stage == 'flutter-test' and not name.endswith('_test.dart'):
            raise Stop('EXPLICIT_TEST_REQUIRED')
    if stage in ('unit', 'medium'):
        if not files or not node:
            raise Stop('NODE_AND_EXPLICIT_SPECS_REQUIRED')
        return repo / 'server', [node, str(repo / 'server/node_modules/vitest/vitest.mjs'),
            '--config', 'test/vitest.config' + ('.medium' if stage == 'medium' else '') + '.mjs',
            'run', *files, '--maxWorkers=1', '--no-file-parallelism', '--maxConcurrency=1']
    if files:
        if stage != 'flutter-test':
            raise Stop('UNEXPECTED_ARGUMENTS')
    if stage == 'typecheck' and node:
        return repo / 'server', [str(repo / 'server/node_modules/.bin/tsc'), '--noEmit']
    if stage == 'backend-build':
        pnpm = shutil.which('pnpm')
        if pnpm:
            return repo / 'server', [pnpm, 'run', 'build']
    if stage == 'dependencies':
        pnpm = shutil.which('pnpm')
        if pnpm:
            return repo, [pnpm, 'install', '--filter', 'immich', '--frozen-lockfile', '--reporter=append-only']
    if stage in ('sdk-dependencies', 'workspace-link', 'sdk-build', 'plugin-sdk-build'):
        pnpm = shutil.which('pnpm')
        if pnpm and stage in ('sdk-dependencies', 'workspace-link'):
            return repo, [pnpm, '--filter', '@immich/sdk', '--filter', '@immich/plugin-sdk',
                '--filter', 'immich', 'install', '--frozen-lockfile', '--reporter=append-only']
        if pnpm:
            return repo, [pnpm, '--filter', '@immich/sdk' if stage == 'sdk-build' else '@immich/plugin-sdk', 'build']
    if stage == 'openapi-spec' and node:
        return repo / 'server', [node, str(repo / 'server/dist/bin/sync-open-api.js')]
    if stage == 'openapi-typescript' and shutil.which('oazapfts'):
        return repo, [shutil.which('oazapfts'), '--optimistic', '--argumentStyle=object', '--useEnumType',
            '--allSchemas', 'open-api/immich-openapi-specs.json', 'packages/sdk/src/fetch-client.ts']
    if stage == 'openapi-dart':
        return repo / 'open-api', ['/bin/bash', 'bin/generate-dart-sdk.sh']
    if stage == 'flutter-dependencies' and flutter:
        return repo / 'mobile', [flutter, 'pub', 'get', '--enforce-lockfile']
    if stage == 'flutter-codegen' and flutter:
        return repo / 'mobile', ['/bin/bash', str(Path(__file__).with_name('foto-mobile-codegen.sh'))]
    if stage == 'flutter-test' and flutter and files:
        return repo / 'mobile', [flutter, 'test', '--concurrency=1', *files]
    if stage == 'flutter-analyze' and flutter:
        return repo / 'mobile', [flutter, 'analyze', '--no-pub']
    if stage == 'android-apk' and flutter:
        compiler = Path(os.environ.get('JAVA_HOME', '/nonexistent')) / 'bin/javac'
        if not compiler.is_file() or not os.access(compiler, os.X_OK):
            raise Stop('FULL_JDK_REQUIRED: JAVA_HOME/bin/javac missing; no Gradle process started')
        return repo / 'mobile', [flutter, 'build', 'apk', '--release', '--no-pub']
    raise Stop('REQUIRED_TOOL_UNAVAILABLE')


def adopted_children():
    # /proc/PID/task/TID/children is optional in Linux builds. PPid is always
    # present in procfs; ProtectProc=invisible still permits our own descendants.
    children = []
    for entry in Path('/proc').iterdir():
        if entry.name.isdigit():
            try:
                if f'PPid:\t{os.getpid()}\n' in (entry / 'status').read_text():
                    children.append(int(entry.name))
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                pass
    return children


def terminate_group(proc):
    # Also terminate grandchildren left behind by a command that already exited.
    for sig, timeout in ((signal.SIGTERM, 2), (signal.SIGKILL, 2)):
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            break
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                os.killpg(proc.pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.02)
    proc.wait()
    # Daemons can create their own session. As a Linux subreaper we own those
    # orphans too; kill via pidfd, never by a possibly recycled unrelated PID.
    for sig in (signal.SIGTERM, signal.SIGKILL):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            children = adopted_children()
            if not children:
                return
            for child in children:
                child_fd = None
                try:
                    child_fd = os.pidfd_open(int(child))
                    status = Path(f'/proc/{child}/status').read_text()
                    if f'PPid:\t{os.getpid()}\n' in status:
                        signal.pidfd_send_signal(child_fd, sig)
                except (ProcessLookupError, FileNotFoundError):
                    pass
                finally:
                    if child_fd is not None:
                        os.close(child_fd)
            while True:
                try:
                    pid, _ = os.waitpid(-1, os.WNOHANG)
                    if pid == 0:
                        break
                except ChildProcessError:
                    break
            time.sleep(0.02)
    if adopted_children():
        raise Stop('DESCENDANT_CLEANUP_INCOMPLETE')


def supervise(cmd, cwd, log, lock_fd, env, interactive=False, additional_fds=()):
    if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
        raise Stop('LINUX_PIDFD_REQUIRED')
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise Stop('LINUX_SUBREAPER_REQUIRED')
    stopped = []

    def on_signal(signum, _):
        stopped.append(signum)

    old = {s: signal.signal(s, on_signal) for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
    proc = None
    def limit_cpu():
        allowed = sorted(os.sched_getaffinity(0))
        os.sched_setaffinity(0, allowed[:2])
    try:
        proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdin=None if interactive else subprocess.DEVNULL,
            stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
            pass_fds=(lock_fd, *additional_fds), preexec_fn=limit_cpu)
        while proc.poll() is None and not stopped:
            time.sleep(0.05)
        rc = 128 + stopped[0] if stopped else proc.returncode
        return rc
    finally:
        if proc:
            terminate_group(proc)
        for s, handler in old.items():
            signal.signal(s, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path('/mnt/hp-data/codex-work/foto-integration'))
    parser.add_argument('--state', type=Path, default=DEFAULT_STATE)
    parser.add_argument('--legacy-lock', type=Path,
        default=Path('/mnt/hp-data/codex-work/gallery-build15-auto/auto.lock'))
    parser.add_argument('--resume', action='store_true', help='reuse exact, integrity-checked successful stage only')
    parser.add_argument('--retry-failed', action='store_true', help='explicitly allow one new attempt, never an automatic retry')
    parser.add_argument('stage', choices=['unit', 'medium', 'typecheck', 'backend-build',
        'dependencies', 'sdk-dependencies', 'workspace-link', 'sdk-build', 'plugin-sdk-build',
        'openapi-spec', 'openapi-typescript', 'openapi-dart', 'flutter-dependencies',
        'flutter-codegen', 'flutter-test', 'flutter-analyze', 'android-apk', 'session'])
    parser.add_argument('files', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    private_dir(args.state)
    repo = args.repo.resolve(strict=True)
    if args.stage == 'session':
        if not args.files:
            raise Stop('SESSION_COMMAND_REQUIRED')
        fd = lock(args.state / 'codex-session.lock')
        legacy_fd = None
        try:
            env = dict(os.environ, FOTO_SESSION_ACTIVE='1')
            env.pop('FOTO_LEGACY_LOCK_HELD', None)
            if args.legacy_lock.is_symlink():
                raise Stop('UNSAFE_LEGACY_LOCK')
            args.legacy_lock.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            parent = args.legacy_lock.parent.lstat()
            if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o022:
                raise Stop('UNSAFE_LEGACY_LOCK_DIRECTORY')
            legacy_fd = lock(args.legacy_lock, legacy=True)
            env['FOTO_LEGACY_LOCK_HELD'] = '1'
            # Session output remains interactive; no Codex is launched by this module on import.
            entry = ['/bin/bash', '-c', 'export FOTO_SESSION_ENTRY_PID=$$; exec "$@"', 'foto-session', *args.files]
            return supervise(entry, repo, None, fd, env, interactive=True,
                additional_fds=() if legacy_fd is None else (legacy_fd,))
        finally:
            if legacy_fd is not None:
                os.close(legacy_fd)
            os.close(fd)
    stages = args.state / 'stages'
    private_dir(stages)
    fd = lock(args.state / 'heavy-stage.lock')
    try:
        cwd, cmd = command(repo, args.stage, args.files)
        source = source_identity(repo)
        generated_paths = {
            'openapi-spec': ['open-api/immich-openapi-specs.json'],
            'openapi-typescript': ['packages/sdk/src/fetch-client.ts'],
            'openapi-dart': ['mobile/generated/openapi'],
            'flutter-codegen': ['mobile/drift_schemas', 'mobile/lib/data/db/main/database.steps.dart'],
        }.get(args.stage, [])
        if args.stage == 'flutter-codegen':
            for pigeon in (repo / 'mobile/pigeon').glob('*.dart'):
                for name in re.findall(r"(?:dartOut|swiftOut|kotlinOut):\s*'([^']+)'", pigeon.read_text()):
                    p = Path(name)
                    if p.is_absolute() or '..' in p.parts:
                        raise Stop('UNSAFE_GENERATED_OUTPUT')
                    generated_paths.append('mobile/' + name)
        generation_inputs = source_identity(repo, generated_paths) if generated_paths else None
        request = {'source': source, 'repo': str(repo), 'stage': args.stage, 'argv': cmd,
            'runnerSHA256': digest(Path(__file__).read_bytes())}
        # Installing/upgrading the tools invalidates cached successes even at the same Git HEAD.
        request['tool'] = {'path': cmd[0], 'mtime': Path(cmd[0]).stat().st_mtime_ns,
            'size': Path(cmd[0]).stat().st_size}
        request['installedDependencies'] = {
            str(p.relative_to(repo)): digest(p.read_bytes())
            for p in (repo / 'node_modules/.modules.yaml',
                repo / 'server/node_modules/vitest/package.json',
                repo / 'server/node_modules/typescript/package.json',
                repo / 'mobile/.dart_tool/package_config.json') if p.is_file()
        }
        if args.stage in ('android-apk', 'openapi-dart'):
            java_home = Path(os.environ.get('JAVA_HOME', '/nonexistent'))
            release = java_home / 'release'
            request['java'] = {'home': str(java_home),
                'releaseSHA256': file_digest(release) if release.is_file() else None}
        key = digest(json.dumps(request, sort_keys=True).encode())
        receipt = stages / (key + '.json')
        if receipt.is_symlink():
            raise Stop('UNSAFE_CHECKPOINT_SYMLINK')
        previous = read_json(receipt) if receipt.exists() else None
        if previous:
            if previous.get('request') != request or previous.get('status') not in ('PASS', 'FAIL', 'RUNNING'):
                raise Stop('CORRUPT_CHECKPOINT')
            if previous['status'] == 'PASS' and args.resume:
                log = stages / previous['log']
                if log.parent != stages or log.is_symlink() or digest(log.read_bytes()) != previous.get('logSHA256'):
                    raise Stop('CHECKPOINT_LOG_MISMATCH')
                if previous.get('exitCode') != 0:
                    raise Stop('CORRUPT_CHECKPOINT')
                if output_identity(repo, args.stage) != previous.get('outputs', {}):
                    raise Stop('CHECKPOINT_OUTPUT_MISMATCH')
                print('PASS_REUSED', args.stage, key)
                return 0
            if previous['status'] != 'PASS' and not args.retry_failed:
                raise Stop('PREVIOUS_ATTEMPT_INCOMPLETE_OR_FAILED: explicit --retry-failed required')
        attempt = stages / (key + '-' + uuid.uuid4().hex)
        record = {'schema': 1, 'request': request, 'status': 'RUNNING', 'pid': os.getpid(),
            'startedAt': time.time(), 'log': attempt.name + '.log'}
        # Immutable attempts preserve history. Canonical success never rewrites HP's manifest.
        atomic_json(attempt.with_suffix('.json'), record)
        atomic_json(receipt, record)
        env = dict(os.environ, NODE_OPTIONS='--max-old-space-size=3072', CI='true',
            MAKEFLAGS='-j1', CMAKE_BUILD_PARALLEL_LEVEL='1', CARGO_BUILD_JOBS='1',
            GOMAXPROCS='2', RAYON_NUM_THREADS='2', UV_THREADPOOL_SIZE='2', VIPS_CONCURRENCY='2',
            GRADLE_OPTS='-Dorg.gradle.workers.max=1 -Dorg.gradle.parallel=false -Dorg.gradle.daemon=false '
                '-Dorg.gradle.jvmargs=-Xmx2048m -Dkotlin.compiler.execution.strategy=in-process '
                '-Dorg.gradle.project.kotlin.compiler.execution.strategy=in-process -Dkotlin.daemon.enabled=false',
            JAVA_TOOL_OPTIONS='-XX:ActiveProcessorCount=2 -Xmx2048m')
        trust = env.get('FOTO_JAVA_TRUSTSTORE')
        if trust:
            if re.search(r'\s', trust) or not Path(trust).is_file():
                raise Stop('INVALID_JAVA_TRUSTSTORE')
            env['JAVA_TOOL_OPTIONS'] += ' -Djavax.net.ssl.trustStore=' + trust
        proxy = urlsplit(env.get('HTTPS_PROXY', env.get('https_proxy', '')))
        if proxy.hostname:
            if not re.fullmatch(r'[A-Za-z0-9_.:-]+', proxy.hostname):
                raise Stop('UNSUPPORTED_PROXY_HOST')
            port = proxy.port or 80
            # Java/Gradle do not automatically honor HTTPS_PROXY. Only route to
            # the already configured proxy, without copying credentials to argv.
            env['GRADLE_OPTS'] += (f' -Dhttps.proxyHost={proxy.hostname} -Dhttps.proxyPort={port}'
                f' -Dhttp.proxyHost={proxy.hostname} -Dhttp.proxyPort={port}')
        with (stages / record['log']).open('xb') as log:
            os.chmod(log.name, 0o600)
            rc = supervise(cmd, cwd, log, fd, env)
            log.flush()
            os.fsync(log.fileno())
        record.update(status='PASS' if rc == 0 else 'FAIL', exitCode=rc, finishedAt=time.time(),
            logSHA256=digest((stages / record['log']).read_bytes()))
        if rc == 0:
            try:
                record['outputs'] = output_identity(repo, args.stage)
            except OSError:
                record.update(status='FAIL', reason='EXPECTED_BUILD_OUTPUT_MISSING', exitCode=1)
                rc = 1
        after = source_identity(repo)
        if after != source and generated_paths:
            if source_identity(repo, generated_paths) == generation_inputs:
                record['generatedSource'] = after
            else:
                record.update(status='FAIL', reason='UNEXPECTED_GENERATION_WRITE', exitCode=1)
                rc = 1
        elif after != source:
            record.update(status='FAIL', reason='SOURCE_CHANGED_DURING_STAGE')
            rc = rc or 1
            record['exitCode'] = rc
        atomic_json(attempt.with_suffix('.json'), record)
        atomic_json(receipt, record)
        print(record['status'], args.stage, 'exit=' + str(rc), 'log=' + str(stages / record['log']))
        return rc if 0 <= rc <= 255 else 1
    finally:
        os.close(fd)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Stop, ValueError, OSError, subprocess.SubprocessError) as error:
        # Do not dump child output, the environment, credential values or source contents.
        print('STOP', str(error), file=sys.stderr)
        sys.exit(2)
