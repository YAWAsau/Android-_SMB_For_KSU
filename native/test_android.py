"""Run against a staged module on an explicitly selected spare device (port 1445).
Never install over the active module. Test files stay under /data/local/tmp/smb-rust-test.
"""
import argparse, concurrent.futures, json, shlex, subprocess, time
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('--serial', required=True)
parser.add_argument('--output', required=True)
args=parser.parse_args()
base='/data/local/tmp/smb-rust-test'
ctl=f'SMBDWEBUI_DATA={base}/data {base}/module/bin/smbctl'
results={}
def shell(cmd, ok=True):
    p=subprocess.run(['adb','-s',args.serial,'shell','su -c '+shlex.quote(cmd)],capture_output=True,text=True,encoding='utf-8',timeout=45)
    if ok and p.returncode: raise RuntimeError(p.stdout+p.stderr)
    return p
def call(*words,ok=True):return shell(ctl+' '+shlex.join(words),ok)
def status():return json.loads(call('status').stdout)
def settle(predicate,timeout=15):
    # Test driver only: product code has no periodic timer.
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        value=predicate()
        if value:return value
        time.sleep(.2)
    raise AssertionError('event did not settle')
try:
    call('watch-stop');call('stop')
    call('selfcheck');call('set_config',f'SHARE_PATH={base}/share','SHARE_NAME=RustTest','PORT=1445','AUTH_MODE=guest','READ_ONLY=0')
    previous=call('get_config').stdout
    assert call('set_config','PORT=0',ok=False).returncode
    assert call('get_config').stdout==previous
    literal=base+"/share 空格 ' $(touch SHOULD_NOT_EXIST)"
    call('set_config','SHARE_PATH='+literal)
    assert json.loads(call('get_config').stdout)['SHARE_PATH']==literal
    call('set_config',f'SHARE_PATH={base}/share')
    results['config_literal_and_failed_update']=True
    with concurrent.futures.ThreadPoolExecutor() as pool:
        list(pool.map(lambda v:call('set_config',v),['WORKGROUP=RUSTTEST','NETBIOS_NAME=RUSTSMB']))
    c=json.loads(call('get_config').stdout);assert c['WORKGROUP']=='RUSTTEST' and c['NETBIOS_NAME']=='RUSTSMB'
    results['serialized_concurrent_updates']=True
    call('start');assert status()['running']
    shell(f'echo rust-smb-roundtrip > {base}/payload')
    shell(f'/data/backup_tools/smbclient //127.0.0.1/RustTest -p 1445 -N -c '+shlex.quote(f'put {base}/payload test.bin; get test.bin {base}/received; del test.bin'))
    assert shell(f'cat {base}/received').stdout.strip()=='rust-smb-roundtrip'
    results['guest_upload_download']=True
    shell(f'nohup env {ctl} watch > {base}/watch.log 2>&1 </dev/null &')
    settle(lambda:shell(f'cat {base}/data/runtime/watch.pid',ok=False).returncode==0)
    before=status()['pid'];call('watch');assert status()['pid']==before
    results['watch_singleton']=True
    master=min(map(int,status()['pid'].split()))
    shell(f'kill -9 {master}')
    settle(lambda:status()['running'] and str(master) not in status()['pid'].split())
    results['pidfd_crash_recovery']=True
    call('set_config','SHARE_NAME=RustChanged')
    settle(lambda:'[RustChanged]' in call('conf').stdout and status()['running'])
    results['inotify_config_reconcile']=True
    time.sleep(1)
    pid=int(shell(f'cat {base}/data/runtime/watch.pid').stdout.strip())
    def ticks():
        tail=shell(f'cat /proc/{pid}/stat').stdout.rsplit(') ',1)[1].split()
        return int(tail[11])+int(tail[12])
    # Wait for the event's synchronous notification to finish before measuring idle.
    settle(lambda:'poll' in shell(f'cat /proc/{pid}/wchan').stdout)
    a=ticks();time.sleep(5);b=ticks();results['idle_cpu_ticks_5s']=[a,b];assert a==b
    call('set_password_hex','rust-test-pass'.encode().hex())
    call('save_restart','AUTH_MODE=user','SMB_USERNAME=rusttest')
    shell(f'/data/backup_tools/smbclient //127.0.0.1/RustChanged -p 1445 -U rusttest%rust-test-pass -c ls')
    denied=shell(f'/data/backup_tools/smbclient //127.0.0.1/RustChanged -p 1445 -U rusttest%wrong -c ls',ok=False)
    assert denied.returncode
    results['user_auth_and_reject_wrong_password']=True
    call('stop');time.sleep(.5);assert not status()['processRunning']
    results['stop_not_restarted_by_watcher']=True
finally:
    call('watch-stop',ok=False);call('stop',ok=False)
    Path(args.output).write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(results,ensure_ascii=False,indent=2))
