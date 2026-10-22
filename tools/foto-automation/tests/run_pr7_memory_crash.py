#!/usr/bin/env python3
"""Isolated CI fault injection: kill the Flutter writer after SQLite commit, then replay."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

command = ['flutter', 'test', '--no-pub', '--concurrency=1',
           'test/infrastructure/repositories/memory_v2_journal_test.dart']
with tempfile.TemporaryDirectory(prefix='foto-pr7-crash-') as directory:
    path = Path(directory) / 'synthetic.sqlite'
    env = dict(os.environ, FOTO_V2_CRASH_DB=str(path), FOTO_V2_CRASH_PHASE='writer')
    with (Path(directory) / 'writer.log').open('wb') as log:
        child = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + 180
            while not Path(str(path) + '.committed').exists():
                if child.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('Writer did not reach the committed crash boundary')
                time.sleep(0.1)
            os.killpg(child.pid, signal.SIGKILL)
            assert child.wait(timeout=30) == -signal.SIGKILL
            print('PASS actual SIGKILL after SQLite commit, before ACK; no graceful close', flush=True)
        except BaseException:
            log.flush()
            print((Path(directory) / 'writer.log').read_text(errors='replace')[-16000:], flush=True)
            raise
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=30)
    subprocess.run(command, env=dict(env, FOTO_V2_CRASH_PHASE='reader'), check=True)
    print('PASS reopened SQLite in new process; duplicate replay produced exactly one link', flush=True)
