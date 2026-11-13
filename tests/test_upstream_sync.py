#!/usr/bin/env python3
"""Use disposable repositories to test merge/no-update/conflict decisions."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'tools/upstream_sync.py'
spec = importlib.util.spec_from_file_location('sync', SCRIPT)
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)
publish_spec = importlib.util.spec_from_file_location('publish', SCRIPT.with_name('publish_sync.py'))
promotion = importlib.util.module_from_spec(publish_spec)
publish_spec.loader.exec_module(promotion)


def git(*args):
    return subprocess.check_output(['git', *args], text=True, encoding='utf-8').strip()


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.cwd = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(os.chdir, self.cwd)
        git('init', '-b', 'main', 'official')
        os.chdir('official')
        git('config', 'user.name', 'Test')
        git('config', 'user.email', 'test@example.invalid')
        Path('file').write_text('base\n')
        git('add', 'file')
        git('commit', '-m', 'base')
        self.base = git('rev-parse', 'HEAD')
        os.chdir(self.root)
        git('clone', str(self.root / 'official'), 'fork')
        os.chdir('fork')
        git('config', 'user.name', 'Test')
        git('config', 'user.email', 'test@example.invalid')
        Path('UPSTREAM_COMMIT').write_text(self.base + '\n')
        git('add', 'UPSTREAM_COMMIT')
        git('commit', '-m', 'fork')
        self.fork_tip = git('rev-parse', 'HEAD')

    def update_official(self, conflict=False):
        os.chdir(self.root / 'official')
        Path('file' if conflict else 'new').write_text('official change\n')
        git('add', '.')
        git('commit', '-m', 'official update')
        latest = git('rev-parse', 'HEAD')
        os.chdir(self.root / 'fork')
        return latest

    def test_no_update_keeps_main(self):
        sync.prepare(str(self.root / 'official'), False, self.root / 'out')
        self.assertEqual(git('rev-parse', 'HEAD'), self.fork_tip)
        self.assertFalse((self.root / 'out/candidate.bundle').exists())

    def test_manual_verification_creates_unchanged_candidate(self):
        sync.prepare(str(self.root / 'official'), True, self.root / 'out')
        self.assertEqual(git('rev-parse', 'HEAD'), self.fork_tip)
        self.assertTrue((self.root / 'out/candidate.bundle').is_file())

    def test_clean_merge_updates_pinned_baseline_and_bundle(self):
        latest = self.update_official()
        sync.prepare(str(self.root / 'official'), False, self.root / 'out')
        self.assertEqual(Path('UPSTREAM_COMMIT').read_text().strip(), latest)
        git('merge-base', '--is-ancestor', self.fork_tip, 'HEAD')
        git('merge-base', '--is-ancestor', latest, 'HEAD')
        self.assertTrue((self.root / 'out/candidate.bundle').is_file())

    def test_conflict_does_not_change_main_or_baseline(self):
        Path('file').write_text('fork change\n')
        git('add', 'file')
        git('commit', '-m', 'local change')
        tip = git('rev-parse', 'HEAD')
        self.update_official(conflict=True)
        with self.assertRaisesRegex(RuntimeError, 'merge failed'):
            sync.prepare(str(self.root / 'official'), False, self.root / 'out')
        self.assertEqual(git('rev-parse', 'HEAD'), tip)
        self.assertEqual(Path('UPSTREAM_COMMIT').read_text().strip(), self.base)
        self.assertEqual(git('status', '--porcelain'), '')
        self.assertFalse((self.root / 'out/candidate.bundle').exists())

    def candidate_and_publisher(self):
        self.update_official()
        sync.prepare(str(self.root / 'official'), False, self.root / 'out')
        meta = json.loads((self.root / 'out/candidate.json').read_text())
        os.chdir(self.root)
        git('init', '--bare', '--initial-branch=main', 'remote.git')
        os.chdir(self.root / 'fork')
        git('push', str(self.root / 'remote.git'), self.fork_tip + ':refs/heads/main')
        os.chdir(self.root)
        git('clone', str(self.root / 'remote.git'), 'publisher')
        os.chdir(self.root / 'publisher')
        return meta

    def test_publish_exact_tested_candidate(self):
        meta = self.candidate_and_publisher()
        promotion.publish(self.root / 'out/candidate.bundle', self.root / 'out/candidate.json',
                          meta['base'], meta['candidate'])
        actual = git('ls-remote', 'origin', 'refs/heads/main').split()[0]
        self.assertEqual(actual, meta['candidate'])

    def test_publish_rejects_concurrent_main_change(self):
        meta = self.candidate_and_publisher()
        git('config', 'user.name', 'Test')
        git('config', 'user.email', 'test@example.invalid')
        Path('concurrent').write_text('another maintainer\n')
        git('add', 'concurrent')
        git('commit', '-m', 'concurrent main update')
        git('push', 'origin', 'main')
        concurrent = git('rev-parse', 'HEAD')
        with self.assertRaisesRegex(RuntimeError, 'main changed'):
            promotion.publish(self.root / 'out/candidate.bundle', self.root / 'out/candidate.json',
                              meta['base'], meta['candidate'])
        self.assertEqual(git('ls-remote', 'origin', 'refs/heads/main').split()[0], concurrent)

    def test_publish_rejects_wrong_tested_commit(self):
        meta = self.candidate_and_publisher()
        with self.assertRaisesRegex(RuntimeError, 'identity'):
            promotion.publish(self.root / 'out/candidate.bundle', self.root / 'out/candidate.json',
                              meta['base'], meta['base'])
        self.assertEqual(git('ls-remote', 'origin', 'refs/heads/main').split()[0], meta['base'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
