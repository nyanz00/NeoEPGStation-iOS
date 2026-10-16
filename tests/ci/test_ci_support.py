"""Check CI skip decisions and summaries without macOS or GitHub credentials."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'ci_support', Path(__file__).resolve().parents[2] / 'scripts/ci-support.py')
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class CISupportTests(unittest.TestCase):
    def setUp(self):
        self.current = dict(id=200, head_sha='abc', head_branch='master',
                            display_title='iOS | source=build | mode=build', workflow_id=1, event='push')
        self.prior = dict(self.current, id=100, status='completed', conclusion='success',
                          html_url='https://github.com/example/app/actions/runs/100')

    def test_only_same_commit_and_scope_can_suppress_work(self):
        self.assertEqual(ci.find_equivalent(self.current, [self.prior]), [self.prior])
        for change in (dict(id=201), dict(head_sha='other'), dict(head_branch='other'),
                       dict(display_title='iOS | source=build | mode=ipad'),
                       dict(status='in_progress'), dict(conclusion='failure'),
                       dict(conclusion='cancelled')):
            with self.subTest(change=change):
                self.assertEqual(ci.find_equivalent(self.current, [dict(self.prior, **change)]), [])

    def run_guard(self, prior_job='success', attempt='1', runs=None):
        with tempfile.TemporaryDirectory() as temp:
            output, summary = Path(temp) / 'output', Path(temp) / 'summary'
            def response(path):
                if path.endswith('/runs/200'):
                    return self.current
                if '/workflows/' in path:
                    return {'workflow_runs': [self.prior] if runs is None else runs}
                return {'jobs': [{'name': 'build', 'conclusion': prior_job}]}
            with patch.dict(os.environ, GITHUB_REPOSITORY='example/app', GITHUB_RUN_ID='200',
                            GITHUB_RUN_ATTEMPT=attempt, GITHUB_OUTPUT=str(output),
                            GITHUB_STEP_SUMMARY=str(summary)), patch.object(ci, 'api', side_effect=response):
                ci.guard()
            return output.read_text(), summary.read_text()

    def test_skip_links_to_real_successful_artifact_run(self):
        output, summary = self.run_guard()
        self.assertEqual(output, 'proceed=false\n')
        self.assertIn(self.prior['html_url'], summary)
        self.assertIn('No new IPA', summary)

    def test_skipped_build_is_not_success_evidence(self):
        output, _ = self.run_guard(prior_job='skipped')
        self.assertEqual(output, 'proceed=true\n')

    def test_explicit_rerun_and_first_run_proceed(self):
        for options in (dict(attempt='2'), dict(runs=[])):
            with self.subTest(options=options):
                output, _ = self.run_guard(**options)
                self.assertEqual(output, 'proceed=true\n')

    def test_pr_merge_validation_is_not_suppressed_by_head_sha(self):
        self.current['event'] = 'pull_request'
        output, _ = self.run_guard()
        self.assertEqual(output, 'proceed=true\n')

    def test_summary_separates_steps_from_results_and_reused_build(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / 'reused-build-info.json').write_text(json.dumps({'build': '180', 'commit': 'old'}))
            (directory / 'pass.json').write_text('{"success": true}')
            (directory / 'failure.json').write_text('{"success": false}')
            (directory / 'not-a-result.json').write_text('{"frames": 100}')
            result = ci.render_summary(directory, {'reused-checks': {'outcome': 'failure'}},
                                       'iPhone UI', 'new', '123')
            self.assertIn('no new IPA', result)
            self.assertIn('source commit: `old`', result)
            self.assertIn('| `failure.json` | FAIL |', result)
            self.assertIn('| `pass.json` | PASS |', result)
            self.assertIn('| reused-checks | failure |', result)
            self.assertNotIn('`not-a-result.json`', result)
            self.assertIn('missing results are not treated as passes', result)

    def test_no_result_is_never_reported_as_pass(self):
        with tempfile.TemporaryDirectory() as temp:
            result = ci.render_summary(Path(temp), {}, 'build', 'abc')
            self.assertNotIn('PASS', result)
            self.assertIn('No test result', result)


if __name__ == '__main__':
    unittest.main()
