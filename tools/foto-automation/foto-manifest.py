#!/usr/bin/env python3
"""Advance both existing HP manifests without losing history; explicit crash recovery."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import runpy
import sys

runtime = runpy.run_path(str(Path(__file__).with_name('foto-stage-runner.py')))
read_json = runtime['read_json']
atomic_json = runtime['atomic_json']
Stop = runtime['Stop']


def checksum(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def finish(transaction):
    t = read_json(transaction)
    before, after = t['before'], t['after']
    if t['schema'] != 1 or checksum(before) != t['beforeSHA256'] or checksum(after) != t['afterSHA256']:
        raise Stop('MANIFEST_TRANSACTION_CORRUPT')
    if after.get('history', [])[:-1] != before.get('history', []):
        raise Stop('MANIFEST_HISTORY_MISMATCH')
    for name in ('canonical', 'mirror'):
        path = Path(t[name])
        if read_json(path) not in (before, after):
            raise Stop('MANIFEST_DIVERGED: preserve files; no automatic overwrite')
    for name in ('canonical', 'mirror'):
        atomic_json(Path(t[name]), after)
    t['state'] = 'COMMITTED'
    atomic_json(transaction, t)


def advance(canonical, mirror, head, branch, run):
    before = read_json(canonical)
    if before != read_json(mirror):
        raise Stop('MANIFEST_MIRROR_DIFFERS: recover the existing transaction first')
    if not isinstance(before.get('history', []), list):
        raise Stop('INVALID_MANIFEST_HISTORY')
    if len(head) != 40 or any(c not in '0123456789abcdef' for c in head):
        raise Stop('INVALID_HEAD')
    after = dict(before)
    history = list(before.get('history', []))
    now = datetime.now(timezone.utc).isoformat()
    history.append({'recorded_at': now, 'previous_head': before.get('expected_head'),
        'verified_head': head, 'branch': branch, 'run_directory': str(run)})
    after.update(expected_head=head, checked_head=head, checked_at=now, history=history)
    transaction = run / ('manifest-transaction-' + head + '.json')
    if transaction.exists() or transaction.is_symlink():
        raise Stop('MANIFEST_TRANSACTION_ALREADY_EXISTS')
    atomic_json(transaction, {'schema': 1, 'state': 'PREPARED',
        'canonical': str(canonical), 'mirror': str(mirror), 'before': before, 'after': after,
        'beforeSHA256': checksum(before), 'afterSHA256': checksum(after)})
    finish(transaction)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--recover', type=Path)
    p.add_argument('--check', action='store_true')
    p.add_argument('args', nargs='*')
    a = p.parse_args()
    if a.check and not a.recover and len(a.args) == 2:
        if read_json(Path(a.args[0])) != read_json(Path(a.args[1])):
            raise Stop('MANIFEST_MIRROR_DIFFERS: recover the existing transaction first')
    elif a.recover and not a.check and not a.args:
        finish(a.recover)
    elif not a.recover and not a.check and len(a.args) == 5:
        canonical, mirror, head, branch, run = a.args
        advance(Path(canonical), Path(mirror), head, branch, Path(run))
    else:
        p.error('provide canonical mirror head branch run, or --recover transaction')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, Stop) as e:
        print('STOP', str(e), file=sys.stderr)
        sys.exit(2)
