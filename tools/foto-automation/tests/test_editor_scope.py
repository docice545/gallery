"""Exercise the actual workflow conditions; no GitHub jobs, signing or builds."""
import ast
from pathlib import Path
import re
import runpy
from unittest import TestCase, mock

ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / '.github/workflows/build-mobile.yml'


def allows(job, *, event='pull_request', branch='codex/foto-build17-editor',
           actor='fixture-user', fork=False, mobile=True, workflow=WORKFLOW):
    blocks = dict(re.findall(r'^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)', workflow.read_text(), re.M | re.S))
    condition = re.search(r'^    if: \$\{\{ (.+) \}\}$', blocks[job], re.M).group(1)
    replacements = {
        'github.event_name': repr(event), 'github.head_ref': repr(branch),
        'github.actor': repr(actor), 'github.event.pull_request.head.repo.fork': repr(fork),
        'fromJSON(needs.pre-job.outputs.should_run).mobile': repr(mobile),
        'inputs.android_media_pilot': 'False', 'inputs.refresh_ios_pods_lock': 'False', 'inputs.build_target': repr(''),
    }
    for key, value in replacements.items():
        condition = condition.replace(key, value)
    condition = condition.replace('&&', ' and ').replace('||', ' or ')
    condition = re.sub(r'!(?!=)', ' not ', condition).replace('true', 'True').strip()
    expression = ast.parse(condition, mode='eval')
    allowed = (ast.Expression, ast.BoolOp, ast.And, ast.Or, ast.UnaryOp, ast.Not,
               ast.Compare, ast.Eq, ast.NotEq, ast.Constant)
    if not all(isinstance(node, allowed) for node in ast.walk(expression)):
        raise AssertionError('Unexpected workflow expression; review the guard explicitly')
    return eval(compile(expression, str(WORKFLOW), 'eval'), {'__builtins__': {}})


class EditorScopeTests(TestCase):
    def test_editor_pull_request_cannot_start_android_or_ios_build_and_sign_jobs(self):
        for job in ['build-sign-android', 'build-sign-ios']:
            self.assertFalse(allows(job))

    def test_other_pull_requests_keep_the_existing_behavior(self):
        for job in ['build-sign-android', 'build-sign-ios']:
            self.assertTrue(allows(job, branch='fixture-normal-pr'))

    def test_main_and_explicit_invocations_remain_available(self):
        for event in ['push', 'workflow_dispatch', 'workflow_call']:
            for job in ['build-sign-android', 'build-sign-ios']:
                self.assertTrue(allows(job, event=event, branch=''))

    def test_existing_actor_fork_and_changed_file_guards_are_preserved(self):
        self.assertFalse(allows('build-sign-android', branch='normal', actor='dependabot[bot]'))
        self.assertFalse(allows('build-sign-ios', branch='normal', fork=True))
        for job in ['build-sign-android', 'build-sign-ios']:
            self.assertFalse(allows(job, branch='normal', mobile=False))

    def test_gallery_mobile_build_and_sign_jobs_obey_the_same_editor_scope(self):
        workflow = ROOT / '.github/workflows/gallery-build-mobile.yml'
        for job in ['build-sign-android', 'build-sign-ios']:
            self.assertFalse(allows(job, workflow=workflow))
            self.assertTrue(allows(job, workflow=workflow, branch='normal'))
            self.assertTrue(allows(job, workflow=workflow, event='workflow_dispatch', branch=''))

    def test_docker_build_publish_and_retag_graph_cannot_start_for_editor_pr(self):
        workflow = ROOT / '.github/workflows/docker.yml'
        self.assertFalse(allows('pre-job', workflow=workflow))
        self.assertTrue(allows('pre-job', workflow=workflow, branch='normal'))
        self.assertTrue(allows('pre-job', workflow=workflow, event='push', branch=''))
        blocks = dict(re.findall(r'^  ([\w-]+):\n(.*?)(?=^  [\w-]+:\n|\Z)', workflow.read_text(), re.M | re.S))
        for job in ['server', 'machine-learning', 'retag_server', 'retag_ml']:
            self.assertIn('    needs: pre-job', blocks[job])
            self.assertNotIn('always()', blocks[job])

    def test_editor_codegen_targets_only_the_freezed_document(self):
        runtime = runpy.run_path(str(ROOT / 'tools/foto-automation/foto-stage-runner.py'))
        with mock.patch('shutil.which', side_effect=lambda name: '/fixture/bin/' + name):
            cwd, args = runtime['command'](ROOT, 'editor-codegen', [])
        self.assertEqual(cwd, ROOT / 'mobile')
        self.assertEqual(args[-2:], ['--build-filter', 'lib/presentation/pages/edit/editor.provider.freezed.dart'])
        self.assertNotIn('--delete-conflicting-outputs', args)
