import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('ci_github', Path(__file__).resolve().parents[2]/'scripts/ci_github.py')
github = importlib.util.module_from_spec(spec)
spec.loader.exec_module(github)


class GitHubReadTests(unittest.TestCase):
    def result(self, code, stdout='', stderr=''):
        return subprocess.CompletedProcess(['gh','run','view','1'], code, stdout, stderr)

    def test_transient_read_retries_query_and_requires_real_success(self):
        with patch.object(github.subprocess, 'run', side_effect=[self.result(1, stderr='HTTP 502: Server Error'),self.result(0,'{"jobs":[]}')]) as read, patch.object(github.time,'sleep') as sleep:
            self.assertEqual(github.read_json(['run','view','1']), {'jobs':[]})
            self.assertEqual(read.call_count,2)
            sleep.assert_called_once_with(3)

    def test_permission_failure_is_not_retried_or_accepted(self):
        with patch.object(github.subprocess,'run',return_value=self.result(1,stderr='HTTP 403: Forbidden')) as read:
            with self.assertRaises(subprocess.CalledProcessError):github.read_json(['run','view','1'])
            self.assertEqual(read.call_count,1)

    def test_continued_service_failure_stays_failed(self):
        with patch.object(github.subprocess,'run',return_value=self.result(1,stderr='HTTP 503: Service Unavailable')) as read, patch.object(github.time,'sleep'):
            with self.assertRaises(subprocess.CalledProcessError):github.read_json(['run','view','1'])
            self.assertEqual(read.call_count,3)
