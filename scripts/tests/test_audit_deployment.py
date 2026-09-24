"""Offline Compose contract checks; no daemon, secrets or live services used."""
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]

class DeploymentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        env = {'PATH': os.environ['PATH'], 'HOME': '/tmp', 'LLAMACPP_MODEL_FILE': 'fixture.gguf', 'LITELLM_MASTER_KEY': 'test-only-not-a-real-key'}
        result = subprocess.run(['docker', 'compose', '--env-file', '/dev/null', '-f', str(ROOT / 'docker-compose.yml'), '--profile', '*', 'config', '--format', 'json'], env=env, capture_output=True, text=True)
        if result.returncode:
            raise AssertionError('Compose did not render with isolated defaults')
        cls.services = json.loads(result.stdout)['services']

    def test_raw_engines_default_to_loopback(self):
        for name in ('ollama', 'vllm', 'vllm2', 'vllm3', 'vllm-router', 'embeddings', 'infinity'):
            service = self.services.get(name)
            if service is None:
                continue
            for port in service.get('ports', []):
                self.assertEqual(port.get('host_ip'), '127.0.0.1', name)

    def test_ingress_uses_its_own_config_and_only_configured_listener(self):
        ingress = self.services['nginx']
        self.assertEqual([p['target'] for p in ingress['ports']], [80])
        mounts = [v['source'] for v in ingress['volumes']]
        self.assertTrue(any(p.endswith('/ingress.conf') for p in mounts))
        self.assertNotIn('grafana', ingress['depends_on'])

    def test_router_refreshes_dns(self):
        cfg = (ROOT / 'config/nginx/nginx.conf').read_text()
        self.assertIn('resolver 127.0.0.11', cfg)
        self.assertEqual(cfg.count(' resolve;'), 3)
        self.assertEqual(cfg.count('zone vllm_'), 3)

    def test_placeholder_keys_fail_without_echoing_secret(self):
        script = 'source scripts/preflight-checks.sh; check_credentials'
        for key, code in [('', 2), ('sk-1234567890abcdef', 2), ('change-me', 2), ('test-secret-with-sufficient-entropy', 0)]:
            result = subprocess.run(['bash', '-c', script], cwd=ROOT, env={**os.environ, 'LITELLM_MASTER_KEY': key}, capture_output=True, text=True)
            self.assertEqual(result.returncode, code)
            if key:
                self.assertNotIn(key, result.stdout + result.stderr)

if __name__ == '__main__':
    unittest.main()
