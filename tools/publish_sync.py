#!/usr/bin/env python3
"""Fast-forward only an exact, tested candidate. Do not execute candidate files."""
import argparse
import json
from pathlib import Path
import subprocess


def git(*args):
    return subprocess.check_output(['git', '-c', 'core.hooksPath=/dev/null', *args],
                                   text=True, encoding='utf-8').strip()


def publish(bundle, metadata, base, candidate, remote='origin'):
    meta = json.loads(metadata.read_text(encoding='utf-8'))
    if meta['base'] != base or meta['candidate'] != candidate or not meta['updated']:
        raise RuntimeError('Candidate identity does not match tested workflow outputs')
    git('fetch', str(bundle.resolve()), 'refs/heads/sync-candidate')
    if git('rev-parse', 'FETCH_HEAD') != candidate:
        raise RuntimeError('Bundle does not contain the tested candidate')
    git('merge-base', '--is-ancestor', base, candidate)
    git('merge-base', '--is-ancestor', meta['upstream'], candidate)
    if git('show', candidate + ':UPSTREAM_COMMIT') != meta['upstream']:
        raise RuntimeError('Pinned upstream does not match the merged revision')
    git('fetch', remote, 'main')
    if git('rev-parse', 'FETCH_HEAD') != base:
        raise RuntimeError('main changed during testing; rerun against the new main')
    # A concurrent update after the preceding check is rejected by the normal
    # fast-forward rule. Never force-push or merge untested commits at publish time.
    git('push', remote, candidate + ':refs/heads/main')
    print('Published tested candidate:', candidate)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--metadata', type=Path, required=True)
    parser.add_argument('--base', required=True)
    parser.add_argument('--candidate', required=True)
    args = parser.parse_args()
    publish(args.bundle, args.metadata, args.base, args.candidate)
