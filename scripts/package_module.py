"""Repackage existing runtime bytes; no native compilation or private data."""
from pathlib import Path
import hashlib
import zipfile

root = Path(__file__).resolve().parents[1]
files = [root / name for name in (
    'module.prop', 'action.sh', 'control.sh', 'customize.sh', 'diagnose.sh',
    'network_watch.sh', 'notify.sh', 'service.sh', 'uninstall.sh', 'README.md', 'LICENSE'
)]
for folder in ('bin', 'META-INF', 'webroot'):
    files.extend(p for p in (root / folder).rglob('*') if p.is_file())
files.sort()
hashes = ''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' +
                 p.relative_to(root).as_posix() + '\n' for p in files)
(root / 'sha256sum.txt').write_text(hashes, encoding='ascii', newline='\n')
files.append(root / 'sha256sum.txt')
props = dict(line.split('=', 1) for line in (root / 'module.prop').read_text().splitlines() if '=' in line)
destination = root / 'dist'
destination.mkdir(exist_ok=True)
target = destination / ('smbdwebui-' + props['version'] + '.zip')
with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for p in files:
        name = p.relative_to(root).as_posix()
        info = zipfile.ZipInfo(name, (2026, 10, 9, 0, 0, 0))
        info.create_system = 3
        executable = p.suffix == '.sh' or name.startswith('bin/') or name.endswith('update-binary')
        info.external_attr = (0o100755 if executable else 0o100644) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, p.read_bytes(), compresslevel=9)
with zipfile.ZipFile(target) as archive:
    assert archive.testzip() is None
    for line in hashes.splitlines():
        digest, name = line.split(None, 1)
        assert hashlib.sha256(archive.read(name)).hexdigest() == digest, name
target.with_suffix('.zip.sha256').write_text(
    hashlib.sha256(target.read_bytes()).hexdigest() + '  ' + target.name + '\n', encoding='ascii')
print(target)
