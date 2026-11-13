#!/usr/bin/env python3
"""Build a local release archive without publishing or executing the installer."""
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
FILES = (
    'reinstall.sh', 'trans.sh', 'partition-layout.sh', 'partition-plan.sh',
    'UPSTREAM_COMMIT', 'CUSTOM-PARTITIONS.md', 'VPS-VALIDATION.md', 'LICENSE',
)


def build():
    revision = subprocess.check_output(
        ['git', '-c', f'safe.directory={ROOT.as_posix()}', 'rev-parse', 'HEAD'],
        cwd=ROOT, text=True,
    ).strip()
    dirty = bool(subprocess.check_output(
        ['git', '-c', f'safe.directory={ROOT.as_posix()}', 'status', '--porcelain'],
        cwd=ROOT, text=True,
    ).strip())
    contents = {name: (ROOT / name).read_bytes().replace(b'\r\n', b'\n') for name in FILES}
    manifest = {
        'upstream_commit': (ROOT / 'UPSTREAM_COMMIT').read_text().strip(),
        'source_commit': revision,
        'working_tree_modified': dirty,
        'partition_api': 1,
        'files': {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()},
    }
    contents['MANIFEST.json'] = (json.dumps(manifest, indent=2) + '\n').encode()
    out = ROOT / 'dist' / f'reinstall-custom-{revision[:12]}{"-dev" if dirty else ""}.tar.gz'
    out.parent.mkdir(exist_ok=True)
    with tarfile.open(out, 'w:gz') as archive:
        for name, data in contents.items():
            item = tarfile.TarInfo(f'reinstall-custom/{name}')
            item.size = len(data)
            item.mode = 0o755 if name.endswith('.sh') else 0o644
            item.mtime = 0
            archive.addfile(item, io.BytesIO(data))
    out.with_suffix(out.suffix + '.sha256').write_text(
        hashlib.sha256(out.read_bytes()).hexdigest() + '  ' + out.name + '\n', encoding='utf-8',
    )
    print(out)


if __name__ == '__main__':
    build()
