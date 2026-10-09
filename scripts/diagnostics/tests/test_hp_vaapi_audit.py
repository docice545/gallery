import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'hp_vaapi_audit.sh'


class AuditSafetyTest(unittest.TestCase):
    def run_audit(self, report, **kwargs):
        return subprocess.run(
            ['/bin/bash', str(SCRIPT), str(report)],
            text=True, capture_output=True, timeout=30, **kwargs,
        )

    def test_existing_report_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as root:
            report = Path(root) / 'audit.txt'
            report.write_text('keep existing audit')
            result = self.run_audit(report)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(report.read_text(), 'keep existing audit')

    def test_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            target = Path(root) / 'target'
            target.write_text('untouched')
            report = Path(root) / 'audit.txt'
            report.symlink_to(target)
            self.assertNotEqual(self.run_audit(report).returncode, 0)
            self.assertEqual(target.read_text(), 'untouched')

    def test_missing_tools_does_not_create_report(self):
        with tempfile.TemporaryDirectory() as root:
            report = Path(root) / 'audit.txt'
            result = self.run_audit(report, env={**os.environ, 'PATH': root})
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(report.exists())

    def test_help_does_not_probe_or_create_files(self):
        result = subprocess.run(['/bin/bash', str(SCRIPT), '--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('Read-only', result.stdout)

    def test_inventory_bounds_container_scope_redaction_and_read_only_sql(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            calls = root / 'docker-calls.jsonl'
            docker = root / 'docker'
            docker.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['AUDIT_TEST_CALLS'], 'a') as stream:
    stream.write(json.dumps(args) + '\\n')
if args[0] == 'info':
    print('root=/var/lib/docker server=fixture')
elif args[0] == 'ps':
    print('immich_server\\nimmich_postgres\\nimmich_machine_learning\\nvpn_prod')
elif args[0] == 'inspect':
    if '.Config.Env' in args[2]: print('SECRET_SENTINEL')
    else: print('image=fixture devices=/dev/dri health=healthy')
elif args[0] == 'exec':
    print('fixture inventory; no media or production database accessed')
else:
    sys.exit(99)
''')
            docker.chmod(0o755)
            # Keep inventory fast and isolated. Only Docker command construction
            # is exercised; these are not real HP/driver/container results.
            for tool in ('lscpu', 'lspci', 'lsmod', 'vainfo', 'intel_gpu_top', 'dpkg-query',
                         'free', 'swapon', 'uptime', 'vmstat', 'ps', 'lsblk', 'findmnt', 'df',
                         'systemctl', 'curl'):
                fixture = root / tool
                fixture.write_text('#!/bin/sh\nexit 1\n')
                fixture.chmod(0o755)
            report = root / 'audit.txt'
            result = self.run_audit(report, env={
                **os.environ, 'PATH': f'{root}:/usr/bin:/bin', 'AUDIT_TEST_CALLS': str(calls),
            })
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(stat.S_IMODE(report.stat().st_mode), 0o600)
            text = report.read_text()
            self.assertIn('UNVERIFIED:', text)
            self.assertNotIn('SECRET_SENTINEL', text)
            commands = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertTrue(any(command[0] == 'inspect' for command in commands))
            self.assertFalse(any('vpn_prod' in command for command in commands))
            self.assertTrue(all(command[0] in ('info', 'ps', 'inspect', 'exec') for command in commands))
            inspect_formats = [command[2] for command in commands if command[0] == 'inspect']
            self.assertTrue(all('.Config.Env' not in value and '.Config.Cmd' not in value for value in inspect_formats))
            sql = next(command for command in commands if command[:2] == ['exec', 'immich_postgres'])
            self.assertIn('default_transaction_read_only=on', sql[4])
            self.assertIn('statement_timeout=5000', sql[4])
            self.assertIn("WHERE key='system-config'", sql[-1])
            self.assertNotIn('SELECT *', sql[-1])
            self.assertFalse(any(word in sql[-1].upper() for word in ('UPDATE ', 'DELETE ', 'INSERT ', 'ALTER ')))


if __name__ == '__main__':
    unittest.main()
