use crate::{config, os, storage, App, Result};
use std::{
    fs,
    os::fd::AsRawFd,
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};
static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn signal(_: i32) {
    STOP.store(true, Ordering::Relaxed);
}
pub fn stop(a: &App) -> Result<()> {
    let pid = fs::read_to_string(a.rt.join("watch.pid"))
        .unwrap_or_default()
        .trim()
        .parse::<i32>()
        .unwrap_or(0);
    let ps = os::processes(&[std::env::current_exe()?])?;
    let ps: Vec<_> = ps
        .into_iter()
        .filter(|p| {
            p.pid == pid
                && fs::read(format!("/proc/{}/cmdline", p.pid))
                    .map(|b| b.split(|b| *b == 0).any(|arg| arg == b"watch"))
                    .unwrap_or(false)
        })
        .collect();
    os::terminate(&ps)
}
fn reconcile(a: &App) -> Result<()> {
    let _lock = a.lock()?;
    let mut c = a.load()?;
    let n = os::network()?;
    if c["ENABLED"] != "1" {
        if !a.pids()?.is_empty() {
            a.halt()?;
        }
        a.card()?;
        return Ok(());
    }
    if a.rt.join("pending_auth_start").exists() && c["AUTH_MODE"] == "user" && !a.password() {
        return Ok(());
    }
    if !storage::ready(&c["SHARE_PATH"]) {
        if !a.pids()?.is_empty() {
            a.halt()?;
        }
        a.card()?;
        return Ok(());
    }
    if n.is_empty() {
        if !a.pids()?.is_empty() {
            a.stop(&mut c, true)?;
            a.notify("event", "已離開區域網路，SMB 已暫停");
        } else if !a.rt.join("waiting_network").exists() {
            config::atomic(&a.rt.join("waiting_network"), b"1", 0o600)?;
        }
        a.card()?;
        return Ok(());
    }
    let key = os::key(&n);
    let old = fs::read_to_string(a.rt.join("interface_key")).unwrap_or_default();
    if old != key
        || fs::read_to_string(a.rt.join("applied_config.json")).unwrap_or_default()
            != serde_json::to_string(&c)?
        || !a.ready(&c)?
    {
        a.halt()?;
        a.start(&mut c)?;
        a.notify("success", "可信任區域網路已就緒，SMB 已啟動");
    }
    a.card()?;
    Ok(())
}
pub fn run(a: &App) -> Result<()> {
    let _singleton = match os::Lock::new(&a.rt.join("watch.lock"), true) {
        Ok(l) => l,
        Err(e) => {
            if e.downcast_ref::<std::io::Error>()
                .and_then(|e| e.raw_os_error())
                == Some(libc::EWOULDBLOCK)
            {
                return Ok(());
            }
            return Err(e);
        }
    };
    {
        let _lock = a.lock()?;
        a.prepare_logs()?;
    }
    let ce = storage::Events::new(&a.load()?["SHARE_PATH"])?;
    let net = os::netlink()?;
    let changes = os::inotify(&[&a.data])?;
    // Signal handlers only set an atomic flag; poll is interrupted without SA_RESTART.
    unsafe {
        let mut act: libc::sigaction = std::mem::zeroed();
        act.sa_sigaction = signal as *const () as usize;
        libc::sigemptyset(&mut act.sa_mask);
        libc::sigaction(libc::SIGTERM, &act, std::ptr::null_mut());
        libc::sigaction(libc::SIGINT, &act, std::ptr::null_mut());
    }
    config::atomic(
        &a.rt.join("watch.pid"),
        std::process::id().to_string().as_bytes(),
        0o600,
    )?;
    a.log("WATCH start: rtnetlink + inotify + pidfd + CE property events; no periodic timer");
    let mut signature = String::new();
    let mut failures = 0u32;
    let mut retry: Option<Instant> = None;
    let mut children = Vec::new();
    let mut force = true;
    let mut crashes = std::collections::VecDeque::new();
    while !STOP.load(Ordering::Relaxed) {
        if let Ok(c) = a.load() {
            if !ce.matches(&c["SHARE_PATH"]) {
                // A blocking Bionic property wait is not a cancellable fd.
                // Re-exec this watcher on a user-scope change, disposing its
                // old thread atomically; server processes remain untouched.
                use std::os::unix::process::CommandExt;
                a.log("WATCH property scope changed; re-exec event listener");
                return Err(std::process::Command::new(std::env::current_exe()?)
                    .arg("watch")
                    .exec()
                    .into());
            }
        }
        let snapshot = (|| -> Result<String> {
            Ok(format!(
                "{}\n{}\n{}",
                serde_json::to_string(&a.load()?)?,
                os::key(&os::network()?),
                storage::ready(&a.load()?["SHARE_PATH"])
            ))
        })();
        match snapshot {
            Ok(now) => {
                let changed = now != signature;
                if changed {
                    failures = 0;
                    retry = None;
                }
                if changed || force || retry.is_some_and(|t| t <= Instant::now()) {
                    match reconcile(a) {
                        Ok(()) => {
                            failures = 0;
                            retry = None
                        }
                        Err(e) => {
                            a.log(&format!("WATCH reconcile error: {e}"));
                            failures += 1;
                            retry = if failures <= 3 {
                                Some(Instant::now() + Duration::from_secs(1 << failures))
                            } else {
                                None
                            };
                        }
                    }
                    signature = now;
                    children = a.pids()?;
                    force = false;
                }
            }
            Err(e) => {
                a.log(&format!("WATCH invalid config: {e}"));
                retry = None;
                force = false;
            }
        }
        let mut p = vec![
            libc::pollfd {
                fd: net.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: changes.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        p.push(libc::pollfd {
            fd: ce.fd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        });
        let storage_dirs = a.load().ok().and_then(|c| {
            if storage::ready(&c["SHARE_PATH"]) {
                None
            } else {
                storage::directory_events(&c["SHARE_PATH"])
            }
        });
        p.push(libc::pollfd {
            fd: storage_dirs.as_ref().map(|f| f.as_raw_fd()).unwrap_or(-1),
            events: libc::POLLIN,
            revents: 0,
        });
        // Recheck after arming directory events to close the create/watch race.
        if storage_dirs.is_some() && a.load().is_ok_and(|c| storage::ready(&c["SHARE_PATH"])) {
            force = true;
            continue;
        }
        // Only the oldest server process is the master; client exits must not restart service.
        if let Some(master) = children
            .iter()
            .min_by_key(|p| (p.start.parse::<u64>().unwrap_or(u64::MAX), p.pid))
        {
            p.push(libc::pollfd {
                fd: master.handle.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            });
        }
        let timeout = retry
            .map(|t| {
                t.saturating_duration_since(Instant::now())
                    .as_millis()
                    .min(i32::MAX as u128)
                    .max(1) as i32
            })
            .unwrap_or(-1);
        os::poll(&mut p, timeout)?;
        if STOP.load(Ordering::Relaxed) {
            break;
        }
        if p[2].revents != 0 {
            ce.drain();
            force = true;
        }
        if p[3].revents != 0 {
            force = true;
        }
        if p.get(4).is_some_and(|p| p.revents != 0) {
            children.clear();
            let now = Instant::now();
            while crashes
                .front()
                .is_some_and(|t| now.duration_since(*t) >= Duration::from_secs(30))
            {
                crashes.pop_front();
            }
            crashes.push_back(now);
            if crashes.len() > 3 {
                retry = Some(now + Duration::from_secs(30));
                force = false;
                a.log("WATCH crash burst: one-shot 30s backoff");
            } else {
                force = true;
            }
        }
        if p[0].revents != 0 || p[1].revents != 0 {
            // One bounded coalescing window per burst. It cannot be extended by event storms.
            let until = Instant::now() + Duration::from_millis(120);
            os::drain(&net);
            os::drain(&changes);
            while Instant::now() < until && !STOP.load(Ordering::Relaxed) {
                let mut q = [
                    libc::pollfd {
                        fd: net.as_raw_fd(),
                        events: libc::POLLIN,
                        revents: 0,
                    },
                    libc::pollfd {
                        fd: changes.as_raw_fd(),
                        events: libc::POLLIN,
                        revents: 0,
                    },
                ];
                os::poll(
                    &mut q,
                    until
                        .saturating_duration_since(Instant::now())
                        .as_millis()
                        .max(1) as i32,
                )?;
                os::drain(&net);
                os::drain(&changes);
            }
        }
    }
    let _ = fs::remove_file(a.rt.join("watch.pid"));
    a.log("WATCH stopped");
    Ok(())
}
