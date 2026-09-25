"""Run real Android SMB I/O against an isolated PC server and the phone module.

Dependencies live in .build/smb-functional-deps (impacket==0.13.0).
All remote writes are restricted to a unique directory created by this run.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import secrets
import shlex
import socket
import struct
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / '.build' / 'smb-functional-deps'))


def serve(state):
    from impacket.smbserver import SimpleSMBServer
    from impacket.ntlm import compute_lmhash, compute_nthash
    cfg = json.loads((state / 'server.json').read_text())
    server = SimpleSMBServer(listenAddress='127.0.0.1', listenPort=cfg['port'])
    server.addShare('STATIC_TEST', str(state / 'share'), readOnly='no')
    server.setSMB2Support(True)
    server.addCredential(cfg['username'], 1000,
                         compute_lmhash(cfg['password']).hex(),
                         compute_nthash(cfg['password']).hex())
    server.start()


def main(args):
    run_id = uuid.uuid4().hex[:12]
    state = ROOT / '.build' / ('smb-static-functional-' + run_id)
    state.mkdir(parents=True)
    (state / 'share').mkdir()
    binary = args.binary or ROOT / 'dist' / 'android-arm64' / 'smbclient'
    out = binary.parent
    data = binary.read_bytes()
    assert data[:6] == b'\x7fELF\x02\x01', 'Expected little-endian ELF64'
    assert struct.unpack_from('<H', data, 18)[0] == 183, 'Expected AArch64'
    phoff = struct.unpack_from('<Q', data, 32)[0]
    phsize, phnum = struct.unpack_from('<HH', data, 54)
    for n in range(phnum):
        ptype, _, offset, _, _, size, _, _ = struct.unpack_from('<IIQQQQQQ', data, phoff+n*phsize)
        assert ptype != 3, 'PT_INTERP is forbidden'
        if ptype == 2:
            for pos in range(offset, offset+size, 16):
                tag, _ = struct.unpack_from('<qQ', data, pos)
                assert tag != 1, 'DT_NEEDED is forbidden'
                if tag == 0:
                    break
    results = [{'name': 'ELF64 AArch64; no PT_INTERP or DT_NEEDED', 'passed': True}]
    report = {'binary_sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data),
              'serial': args.serial, 'run_id': run_id, 'tests': results, 'success': False}
    remote = '/data/local/tmp/codex-smb-static-' + run_id
    remote_dir = '.codex_smb_static_' + run_id
    transcript = (state / 'client.log').open('w', encoding='utf-8')
    server_proc = None
    reverse_port = None
    credentials = state / 'server.json'
    pc_auth = state / 'auth.txt'
    pc_bad_auth = state / 'bad-auth.txt'

    def adb(*cmd, checked=True, timeout=90):
        result = subprocess.run([args.adb, '-s', args.serial, *cmd], capture_output=True,
                                text=True, encoding='utf-8', errors='replace', timeout=timeout)
        if checked and result.returncode:
            raise RuntimeError(f'ADB failed: {result.stdout}\n{result.stderr}')
        return result

    def shell(*cmd, checked=True):
        return adb('shell', shlex.join(cmd), checked=checked)

    def passed(name):
        results.append({'name': name, 'passed': True})
        print('PASS ' + name, flush=True)

    def smb(label, endpoint, command=None, bad=False, checked=True, listing=False):
        host, share, port, auth, protocol = endpoint
        cmd = [remote+'/smbclient', '-s', remote+'/smb.conf', '-p', str(port),
               '--option=client min protocol='+protocol,
               '--option=client max protocol='+protocol, '-d', '3']
        cmd += ['-L', host] if listing else ['//'+host+'/'+share]
        cmd += ['-A', remote+('/bad-auth.txt' if bad else '/auth.txt')] if auth else ['-N']
        if command is not None:
            cmd += ['-c', command]
        result = shell(*cmd, checked=False)
        text = result.stdout + result.stderr
        transcript.write(f'\n=== {label} rc={result.returncode} ===\n{text}\n')
        transcript.flush()
        if checked and result.returncode:
            raise RuntimeError(f'{label}: rc={result.returncode}\n{text[-4000:]}')
        return result, text

    payload = secrets.token_bytes(4*1024*1024+137)
    (state / 'payload.bin').write_bytes(payload)
    (state / 'empty.bin').write_bytes(b'')
    (state / 'smb.conf').write_text('[global]\nworkgroup = WORKGROUP\nclient min protocol = SMB2\n', encoding='ascii')
    endpoints = []
    try:
        shell('mkdir', '-p', remote)
        for filename, local in [('smbclient', binary), ('smb.conf', state/'smb.conf'),
                                ('payload.bin', state/'payload.bin'), ('empty.bin', state/'empty.bin')]:
            adb('push', str(local), remote+'/'+filename)
        shell('chmod', '700', remote+'/smbclient')
        version = shell(remote+'/smbclient', '--version').stdout.strip()
        report['version'] = version
        passed('Android executes fully static binary: '+version)

        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            host_port = probe.getsockname()[1]
        password = secrets.token_urlsafe(24)
        credentials.write_text(json.dumps({'username': 'codex_static', 'password': password, 'port': host_port}))
        pc_auth.write_text('username = codex_static\npassword = '+password+'\ndomain = WORKGROUP\n')
        pc_bad_auth.write_text('username = codex_static\npassword = incorrect-'+run_id+'\ndomain = WORKGROUP\n')
        for p in (pc_auth, pc_bad_auth):
            adb('push', str(p), remote+'/'+p.name)
            shell('chmod', '600', remote+'/'+p.name)
        with (state/'server.log').open('w', encoding='utf-8') as server_log:
            server_proc = subprocess.Popen([sys.executable, str(Path(__file__)), '--server', str(state)],
                                           stdout=server_log, stderr=server_log,
                                           creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        deadline = time.monotonic()+30
        while True:
            try:
                with socket.create_connection(('127.0.0.1', host_port), timeout=1):
                    break
            except OSError:
                if server_proc.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('Local SMB test server did not start; see '+str(state/'server.log'))
                time.sleep(0.2)
        used = adb('reverse', '--list').stdout
        reverse_port = next(p for p in range(18445, 18545) if f'tcp:{p} ' not in used)
        adb('reverse', f'tcp:{reverse_port}', f'tcp:{host_port}')
        pc = ('127.0.0.1', 'STATIC_TEST', reverse_port, True, 'SMB2_02')
        _, listing = smb('authenticated share listing', pc, listing=True)
        assert 'STATIC_TEST' in listing, listing
        passed('SMB2 authenticated share listing')
        bad, bad_text = smb('wrong password rejected', pc, command='ls', bad=True, checked=False)
        assert bad.returncode != 0 and 'LOGON_FAILURE' in bad_text, bad_text
        passed('SMB2 rejects incorrect password')
        endpoints.append(('SMB2 authenticated PC', pc))
        if args.module_share:
            module = ('127.0.0.1', args.module_share, 445, False, 'SMB3_11')
            # Some minimal smbd modules omit srvsvc share enumeration. Connect to
            # the configured share directly, without listing existing user files.
            smb('Android module share connection', module, command='pwd')
            endpoints.append(('SMB3.11 Android module', module))

        for name, endpoint in endpoints:
            smb(name+' mkdir', endpoint, 'mkdir '+remote_dir)
            try:
                path = '"'+remote_dir+'/中文 payload.bin"'
                smb(name+' upload', endpoint, 'put '+remote+'/payload.bin '+path)
                _, listing = smb(name+' ls', endpoint, 'ls '+remote_dir+'/*')
                assert '中文 payload.bin' in listing, listing
                passed(name+' mkdir, upload and Unicode/spaced filename listing')
                smb(name+' download', endpoint, 'get '+path+' '+remote+'/download.bin')
                downloaded = state / ('download-'+str(len(results))+'.bin')
                adb('pull', remote+'/download.bin', str(downloaded))
                assert hashlib.sha256(downloaded.read_bytes()).digest() == hashlib.sha256(payload).digest()
                passed(name+' 4 MiB binary round-trip SHA256 matches')
                if endpoint is pc:
                    assert (state/'share'/remote_dir/'中文 payload.bin').read_bytes() == payload
                    passed('PC server-side uploaded bytes match')
                delete_path = path
                if endpoint is not pc:
                    smb(name+' rename', endpoint, 'rename '+path+' '+remote_dir+'/renamed.bin')
                    delete_path = remote_dir+'/renamed.bin'
                    passed(name+' rename')
                smb(name+' empty upload', endpoint, 'put '+remote+'/empty.bin '+remote_dir+'/empty.bin')
                smb(name+' empty download', endpoint, 'get '+remote_dir+'/empty.bin '+remote+'/empty-down.bin')
                empty = state / 'empty-down.bin'
                adb('pull', remote+'/empty-down.bin', str(empty))
                assert empty.stat().st_size == 0
                passed(name+' empty file round-trip')
                smb(name+' delete', endpoint, 'del '+delete_path)
                missing, text = smb(name+' deleted file inaccessible', endpoint,
                                    'get '+delete_path+' '+remote+'/missing.bin', checked=False)
                assert missing.returncode != 0 and ('NOT_FOUND' in text or 'NO_SUCH_FILE' in text), text
                passed(name+' deletion confirmed by failed subsequent read')
            finally:
                smb(name+' cleanup files', endpoint, 'del '+remote_dir+'/*', checked=False)
                cleanup, text = smb(name+' cleanup directory', endpoint, 'rmdir '+remote_dir, checked=False)
                if cleanup.returncode:
                    raise RuntimeError('Could not remove test directory '+remote_dir+'\n'+text[-2000:])
                passed(name+' test directory removed')
        report['success'] = True
        report['scope_notes'] = [
            'Rename verified against the real Android Samba server; Windows Impacket backend denies rename of its open file.',
            'SMB2 NTLM authentication and wrong-password rejection verified against isolated Impacket 0.13.0.',
            'SMB3.11 operations verified against the existing Android module using its guest share.',
        ]
    except Exception as exc:
        report['error'] = str(exc)
        print('FAIL '+str(exc), flush=True)
        raise
    finally:
        if reverse_port is not None:
            adb('reverse', '--remove', f'tcp:{reverse_port}', checked=False)
        if server_proc is not None:
            server_proc.terminate()
            server_proc.wait(timeout=10)
        # Only the unique directory created above is removed from the phone.
        shell('rm', '-rf', remote, checked=False)
        for p in (credentials, pc_auth, pc_bad_auth):
            p.unlink(missing_ok=True)
        transcript.close()
        (state/'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        if report['success']:
            (out/'functional-test-report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        print('Report: '+str(state/'report.json'), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--serial', default='50f5b2d8')
    parser.add_argument('--adb', default=r'C:\platform-tools\adb.exe')
    parser.add_argument('--module-share', default='SpeedBackup')
    parser.add_argument('--server', type=Path)
    parser.add_argument('--binary', type=Path)
    args = parser.parse_args()
    if args.server:
        serve(args.server)
    else:
        main(args)
