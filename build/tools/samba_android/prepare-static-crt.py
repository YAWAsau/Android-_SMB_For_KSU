"""Brand a private r30 static CRT copy with the configured target metadata.

This changes identification only, not the static runtime's API compatibility.
The installed NDK is never modified.
"""
from pathlib import Path
import os
import struct
import subprocess
import tempfile

ndk = Path(os.environ['SAMBA_NDK'])
toolchain = ndk / 'toolchains/llvm/prebuilt/windows-x86_64'
lib = toolchain / 'sysroot/usr/lib/aarch64-linux-android'
output = Path(os.environ['SAMBA_STATIC_CRT'])
output.mkdir(parents=True, exist_ok=True)
props = (ndk / 'source.properties').read_text()
if '30.0.16248370' not in props:
    raise SystemExit('Static CRT branding requires pinned NDK r30 (30.0.16248370).')

def native(path):
    return subprocess.check_output(['cygpath', '-m', str(path)], text=True).strip()

objcopy = str(toolchain / 'bin/llvm-objcopy.exe')
with tempfile.TemporaryDirectory(dir=output) as temp:
    temp = Path(temp)
    note = temp / 'android.note'
    # Reuse the official API 28 note only; never link the dynamic CRT code.
    subprocess.run([objcopy, '--dump-section',
                    '.note.android.ident=' + native(note),
                    native(lib / '28/crtbegin_dynamic.o'),
                    native(temp / 'dynamic-copy.o')], check=True)
    data = note.read_bytes()
    expected = (struct.pack('<III', 8, 132, 1) + b'Android\0'
                + struct.pack('<I', 28) + b'r30'.ljust(64, b'\0')
                + b'16248370'.ljust(64, b'\0'))
    if data != expected:
        raise SystemExit('Unexpected API 28/r30 Android identification note.')
    result = temp / 'crtbegin_static.o'
    subprocess.run([objcopy, '--update-section',
                    '.note.android.ident=' + native(note),
                    native(lib / 'crtbegin_static.o'), native(result)], check=True)
    destination = output / 'crtbegin_static.o'
    if not destination.exists() or destination.read_bytes() != result.read_bytes():
        result.replace(destination)
print('Static CRT identification: Android target 28, NDK r30 (16248370); runtime unchanged.')
