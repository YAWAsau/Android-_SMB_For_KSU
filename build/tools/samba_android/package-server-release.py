"""Create the reproducible build kit only after exact server/client bytes pass."""
from pathlib import Path
import json, hashlib, os, zipfile, argparse

root = Path(__file__).resolve().parents[2]
out = root / 'dist/android-arm64'
parser = argparse.ArgumentParser()
parser.add_argument('--profile', choices=('standard', 'size'), default='size')
profile = parser.parse_args().profile
suffix = 'logfix3'
if profile == 'size':
    out = root / 'dist/android-arm64-size'
    suffix = 'logfix3-lto'
cache = Path(os.environ['USERPROFILE']) / 'SambaAndroidBuild'
version = (out / 'source-version.txt').read_text().strip()
names = ['smbclient', 'smbd', 'samba-dcerpcd', 'rpcd_classic', 'rpcd_lsad', 'rpcd_winreg']
hashes = {n: hashlib.sha256((out/n).read_bytes()).hexdigest() for n in names}
server = json.loads((out/'server-functional-test-report.json').read_text(encoding='utf-8'))
client = json.loads((out/'functional-test-report.json').read_text(encoding='utf-8'))
assert server['success'] and client['success']
assert client['binary_sha256'] == hashes['smbclient']
assert all(server['binary_sha256'][n] == hashes[n] for n in names[1:])
archives = [cache / f'samba-{version}.tar.gz']
for name in ('gmp-6.3.0.tar.xz', 'nettle-3.10.2.tar.gz', 'gnutls-3.8.13.tar.xz', 'Parse-Yapp-1.21.tar.gz'):
    matches = [cache/name, cache/'deps'/name]
    archives.append(next(p for p in matches if p.exists()))
manifest = {'samba_version': version, 'ndk': 'r29', 'android_api': 28, 'abi': 'arm64-v8a',
            'build_profile': profile,
            'linkage': 'fully static; no PT_INTERP or DT_NEEDED', 'binary_sha256': hashes,
            'sources': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in archives}}
(out/'source-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')
(out/'README.md').write_bytes((root/'tools/samba_android/SERVER-BUILD.md').read_bytes())
target = root / f'dist/samba-{version}-android-arm64-ndkr29-api28-{suffix}-build-kit.zip'
with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    z.write(root/'build.ps1', 'build.ps1')
    z.write(root/'tools/samba_android/SERVER-BUILD.md', 'README.md')
    comparison = root / 'dist/smbclient-size-comparison.md'
    if comparison.is_file(): z.write(comparison, 'SIZE-COMPARISON.md')
    module_only = {'package-server-module.py', 'module_fixes.py',
                   'test-module-bindings.py', 'test-installed-module.py',
                   'test-server-module.py', 'test-server-log-default.py'}
    for p in (root/'tools/samba_android').iterdir():
        if p.is_file() and p.name not in module_only:
            z.write(p, p.relative_to(root).as_posix())
    for p in out.iterdir():
        if p.is_file(): z.write(p, p.relative_to(root).as_posix())
    size_out = root / 'dist/android-arm64-size'
    if size_out != out and (size_out / 'functional-test-report.json').is_file():
        size_report = json.loads((size_out / 'functional-test-report.json').read_text(encoding='utf-8'))
        assert size_report['success'] and size_report['binary_sha256'] == hashlib.sha256((size_out / 'smbclient').read_bytes()).hexdigest()
        for p in size_out.iterdir():
            if p.is_file(): z.write(p, p.relative_to(root).as_posix())
    for p in archives:
        z.write(p, 'upstream-source/'+p.name)
    for p in (cache/f'samba-{version}.tar.asc', cache/'samba-pubkey.asc'):
        z.write(p, 'upstream-source/'+p.name)
with zipfile.ZipFile(target) as z:
    assert z.testzip() is None
    for name in names:
        assert hashlib.sha256(z.read((out/name).relative_to(root).as_posix())).hexdigest() == hashes[name]
target.with_suffix('.zip.sha256').write_text(hashlib.sha256(target.read_bytes()).hexdigest()+'  '+target.name+'\n')
print(target)
