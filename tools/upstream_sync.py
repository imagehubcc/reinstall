#!/usr/bin/env python3
"""Prepare an immutable merge candidate. Never push or execute merged code."""
import argparse
import json
import os
from pathlib import Path
import subprocess


def git(*args, check=True):
    return subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', *args],
                          check=check, text=True, encoding='utf-8', capture_output=True)


def prepare(upstream, verify, out):
    out = out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if git('status', '--porcelain').stdout.strip():
        raise RuntimeError('Candidate preparation requires a clean checkout')
    base = git('rev-parse', 'HEAD').stdout.strip()
    recorded = Path('UPSTREAM_COMMIT').read_text().strip()
    git('merge-base', '--is-ancestor', recorded, base)
    git('fetch', '--no-tags', upstream, 'main')
    latest = git('rev-parse', 'FETCH_HEAD').stdout.strip()
    git('merge-base', '--is-ancestor', recorded, latest)
    updated = latest != recorded
    meta = {'base': base, 'upstream': latest, 'updated': updated,
            'test_required': updated or verify, 'candidate': base}
    if updated:
        git('config', 'user.name', 'github-actions[bot]')
        git('config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com')
        merge = git('merge', '--no-ff', '--no-commit', latest, check=False)
        if merge.returncode:
            conflicts = git('diff', '--name-only', '--diff-filter=U').stdout
            git('merge', '--abort', check=False)
            raise RuntimeError('Upstream merge failed; main is unchanged.\n' + conflicts + merge.stderr)
        Path('UPSTREAM_COMMIT').write_text(latest + '\n', encoding='utf-8')
        git('add', '--', 'UPSTREAM_COMMIT')
        git('commit', '-m', 'chore: merge verified upstream ' + latest[:12])
        meta['candidate'] = git('rev-parse', 'HEAD').stdout.strip()
    if meta['test_required']:
        git('branch', '-f', 'sync-candidate', meta['candidate'])
        git('bundle', 'create', str(out / 'candidate.bundle'), 'refs/heads/sync-candidate')
    (out / 'candidate.json').write_text(json.dumps(meta, indent=2) + '\n', encoding='utf-8')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as handle:
            for key, value in meta.items():
                handle.write(f'{key}={str(value).lower() if isinstance(value, bool) else value}\n')
    print(json.dumps(meta, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--upstream', default='https://github.com/bin456789/reinstall.git')
    parser.add_argument('--verify', action='store_true', help='Test even when upstream has no updates')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.upstream, args.verify, args.out)
