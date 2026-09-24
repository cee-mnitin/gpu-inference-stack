"""Offline safety regressions; Docker and HTTP are always fakes."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('healthprobe', ROOT/'scripts/healthprobe.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

class Readiness(unittest.TestCase):
    def check(self, body, expect='data'):
        response = io.BytesIO(json.dumps(body).encode())
        response.status = 200
        with patch.object(probe.urllib.request, 'urlopen', return_value=response):
            return probe._probe('http://fake', {'model': 'BAAI/bge-m3', 'input': ['x']}, 1, expect)[0]

    def test_empty_embedding_fails(self):
        self.assertFalse(self.check({'data': [{'embedding': []}]}))

    def test_wrong_dimension_fails(self):
        self.assertFalse(self.check({'data': [{'embedding': [1.0]}]}))

    def test_nonfinite_embedding_fails(self):
        self.assertFalse(self.check({'data': [{'embedding': [float('nan')]*1024}]}))

    def test_valid_embedding_passes(self):
        self.assertTrue(self.check({'data': [{'embedding': [0.1]*1024}]}))

    def test_empty_chat_fails(self):
        self.assertFalse(self.check({'choices': [{'message': {'content': None}}]}, 'choices'))

    def test_content_chat_passes(self):
        self.assertTrue(self.check({'choices': [{'message': {'content': 'OK'}}]}, 'choices'))

class Watchdog(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.p = Path(self.tmp.name)
        binary = self.p/'docker'
        binary.write_text('#!/bin/sh\nif [ "$1" = ps ]; then [ ! -f "$FIX/fail" ] || exit 1; cat "$FIX/unhealthy"; else echo "$*" >> "$FIX/actions"; fi\n')
        binary.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(self.p)+':'+os.environ['PATH'], 'FIX': str(self.p), 'WATCHDOG_STATE_DIR': str(self.p/'state'), 'WATCHDOG_THRESHOLD': '3'}

    def run_poll(self, names, *args):
        (self.p/'unhealthy').write_text(names)
        return subprocess.run(['bash', str(ROOT/'scripts/watchdog.sh'), *args], env=self.env, capture_output=True, text=True)

    def test_recovered_container_streak_is_cleared(self):
        for names in ['a A\nb B\n', 'b B\n', 'a A\nb B\n', 'a A\nb B\n']:
            self.assertEqual(self.run_poll(names).returncode, 0)
        actions = (self.p/'actions').read_text() if (self.p/'actions').exists() else ''
        self.assertNotIn('restart a', actions.lower())

    def test_failed_inventory_is_an_error(self):
        (self.p/'fail').touch()
        self.assertNotEqual(self.run_poll('').returncode, 0)

    def test_dry_run_does_not_advance_streak(self):
        self.run_poll('a A\n')
        before = {p.name:p.read_text() for p in (self.p/'state').glob('streak.*')}
        self.run_poll('a A\n', '--dry-run')
        self.assertEqual(before, {p.name:p.read_text() for p in (self.p/'state').glob('streak.*')})

if __name__ == '__main__': unittest.main()
