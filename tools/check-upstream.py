#!/usr/bin/env python3
"""Read-only review aid. Fetch upstream explicitly before supplying upstream/main."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.check_output(
        ['git', '-c', f'safe.directory={ROOT.as_posix()}', *args], cwd=ROOT, text=True,
    ).strip()


def main():
    base = (ROOT / 'UPSTREAM_COMMIT').read_text().strip()
    git('merge-base', '--is-ancestor', base, 'HEAD')
    print('Recorded upstream base:', git('rev-parse', base))
    print('Local HEAD:', git('rev-parse', 'HEAD'))
    print('Integration files: reinstall.sh, trans.sh')
    if len(sys.argv) > 1:
        target = git('rev-parse', '--verify', sys.argv[1] + '^{commit}')
        print('Candidate upstream:', target)
        print(git('diff', '--stat', base, target))
        print('\nCritical upstream changes:')
        print(git('diff', base, target, '--', 'reinstall.sh', 'trans.sh', 'get-xda.sh'))
        print('\nReview, merge, update UPSTREAM_COMMIT, test, then release. No files changed.')


if __name__ == '__main__':
    main()
