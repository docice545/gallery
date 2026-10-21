"""Exercise the real workflow guards without building, signing or dispatching CI."""
import ast
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
BRANCHES = ('codex/foto-build17-editor', 'codex/foto-build17-dedup-acceptance',
            'codex/foto-build17-editor-compact')


def allows(workflow, job, branch, event='pull_request'):
    text = (ROOT / '.github/workflows' / workflow).read_text()
    blocks = dict(re.findall(r'^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)', text, re.M | re.S))
    condition = re.search(r'^    if: \$\{\{ (.+) \}\}$', blocks[job], re.M).group(1)
    substitutions = {
        'github.event_name': repr(event), 'github.head_ref': repr(branch),
        'github.actor': repr('fixture-user'), 'github.event.pull_request.head.repo.fork': 'False',
        'inputs.android_media_pilot': 'False', 'inputs.refresh_ios_pods_lock': 'False',
        'inputs.build_target': repr(''),
    }
    for key, value in substitutions.items():
        condition = condition.replace(key, value)
    condition = re.sub(r'fromJSON\(needs.pre-job.outputs.should_run\)\.[\w-]+', 'True', condition)
    condition = condition.replace('&&', ' and ').replace('||', ' or ')
    condition = re.sub(r'!(?!=)', ' not ', condition).replace('true', 'True').strip()
    tree = ast.parse(condition, mode='eval')
    allowed = (ast.Expression, ast.BoolOp, ast.And, ast.Or, ast.UnaryOp, ast.Not,
               ast.Compare, ast.Eq, ast.NotEq, ast.Constant)
    if not all(isinstance(n, allowed) for n in ast.walk(tree)):
        raise AssertionError('Unexpected workflow expression; review explicitly')
    return eval(compile(tree, str(ROOT), 'eval'), {'__builtins__': {}})


class DedupSourceScopeTests(unittest.TestCase):
    def test_source_reviews_do_not_build_sign_or_publish(self):
        jobs = [('build-mobile.yml', 'build-sign-android'), ('build-mobile.yml', 'build-sign-ios'),
                ('gallery-build-mobile.yml', 'build-sign-android'), ('gallery-build-mobile.yml', 'build-sign-ios'),
                ('docker.yml', 'pre-job'), ('test.yml', 'e2e-tests-server-cli'), ('test.yml', 'e2e-tests-web')]
        for workflow, job in jobs:
            for branch in BRANCHES:
                with self.subTest(workflow=workflow, job=job, branch=branch):
                    self.assertFalse(allows(workflow, job, branch))
            self.assertTrue(allows(workflow, job, 'fixture-normal-pr'))
            self.assertTrue(allows(workflow, job, '', 'workflow_dispatch'))

    def test_docker_builds_remain_dependent_on_guarded_pre_job(self):
        text = (ROOT / '.github/workflows/docker.yml').read_text()
        blocks = dict(re.findall(r'^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)', text, re.M | re.S))
        for job in ['server', 'machine-learning', 'retag_server', 'retag_ml']:
            self.assertIn('    needs: pre-job', blocks[job])
            self.assertNotIn('always()', blocks[job])
