#!/usr/bin/env python3
"""Seal or validate the fixed backup format without trusting checksum paths or tar links."""
import hashlib
from pathlib import Path, PurePosixPath
import sys
import tarfile

FILES = ('postgres.dump', 'quasar.tar.gz', 'state.tar.gz', 'manifest.env')
action, directory = sys.argv[1:]
root = Path(directory)
for name in FILES:
    p = root / name
    if p.is_symlink() or not p.is_file() or p.stat().st_size == 0:
        raise SystemExit(f'backup is missing a nonempty regular {name}')
checksums = []
for name in FILES:
    with (root / name).open('rb') as stream:
        checksums.append(hashlib.file_digest(stream, 'sha256').hexdigest() + '  ' + name + '\n')
sums = ''.join(checksums)
if action == 'seal':
    (root / 'SHA256SUMS').write_text(sums)
elif action == 'verify':
    if (root / 'SHA256SUMS').is_symlink() or (root / 'SHA256SUMS').read_text() != sums:
        raise SystemExit('backup checksums do not match the fixed manifest')
else:
    raise SystemExit('expected seal or verify')
# Reject links, devices and traversal before any container extracts the archive.
for name in ('quasar.tar.gz', 'state.tar.gz'):
    with tarfile.open(root / name, 'r:gz') as archive:
        seen = set()
        for member in archive:
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or not (member.isfile() or member.isdir()):
                raise SystemExit('backup contains an unsafe archive entry')
            if path in seen:
                raise SystemExit('backup contains duplicate archive paths')
            seen.add(path)
