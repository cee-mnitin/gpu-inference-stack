import contextlib
import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('versions', ROOT/'scripts/versions.py')
versions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(versions)

class VersionTests(unittest.TestCase):
    def test_mutable_tag_with_different_image_content_is_reported(self):
        def run(args, **kwargs):
            if 'image' in args:
                return SimpleNamespace(stdout='sha256:new\n')
            if '{{.Image}}' in args:
                return SimpleNamespace(stdout='sha256:old\n')
            return SimpleNamespace(stdout='engine:latest\n')
        out = io.StringIO()
        config = {'services': {'engine': {'image': 'engine:latest'}}}
        with patch.object(versions.subprocess, 'run', run), patch.object(versions.sys, 'stdin', io.StringIO(json.dumps(config))), contextlib.redirect_stdout(out):
            versions.main()
        self.assertIn('sha256:old', out.getvalue())
        self.assertIn('running a different image', out.getvalue())

if __name__ == '__main__': unittest.main()
