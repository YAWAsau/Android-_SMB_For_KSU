use crate::Result;
use std::{
    collections::BTreeSet,
    ffi::{CStr, CString},
    fs,
    net::Ipv4Addr,
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
pub fn fd(n: i32) -> Result<OwnedFd> {
    if n < 0 {
        Err(std::io::Error::last_os_error().into())
    } else {
        Ok(unsafe { OwnedFd::from_raw_fd(n) })
    }
}
pub struct Lock(pub fs::File);
impl Lock {
    pub fn new(p: &Path, nonblock: bool) -> Result<Self> {
        use std::os::unix::fs::OpenOptionsExt;
        let f = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(p)?;
        if unsafe {
            libc::flock(
                f.as_raw_fd(),
                libc::LOCK_EX | if nonblock { libc::LOCK_NB } else { 0 },
            )
        } < 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(Self(f))
    }
}
impl Drop for Lock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}
pub fn trusted(name: &str) -> bool {
    let deny = [
        "lo",
        "rmnet",
        "r_rmnet",
        "ccmni",
        "pdp",
        "wwan",
        "cell",
        "tun",
        "tap",
        "wg",
        "wireguard",
        "tailscale",
        "zt",
        "clat",
        "v4-",
        "dummy",
        "ifb",
        "ip6tnl",
        "sit",
        "gre",
        "gretap",
        "wifi-aware",
        "aware",
        "p2p",
    ];
    if deny.iter().any(|p| name.starts_with(p)) {
        return false;
    }
    [
        "wlan", "wifi", "mlan", "eth", "en", "ap", "swlan", "softap", "rndis", "usb", "bnep",
        "bt-pan", "br", "bond",
    ]
    .iter()
    .any(|p| name.starts_with(p))
        || Path::new(&format!("/sys/class/net/{name}/wireless")).is_dir()
}
pub fn network() -> Result<Vec<(String, String)>> {
    let mut head = std::ptr::null_mut();
    if unsafe { libc::getifaddrs(&mut head) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    // getifaddrs owns the entire linked list until freeifaddrs; no pointers escape.
    let mut out = BTreeSet::new();
    let mut p = head;
    unsafe {
        while !p.is_null() {
            let a = &*p;
            if !a.ifa_addr.is_null()
                && !a.ifa_netmask.is_null()
                && (*a.ifa_addr).sa_family as i32 == libc::AF_INET
            {
                let name = CStr::from_ptr(a.ifa_name).to_string_lossy().into_owned();
                let v = &*(a.ifa_addr as *const libc::sockaddr_in);
                let m = &*(a.ifa_netmask as *const libc::sockaddr_in);
                let ip = Ipv4Addr::from(v.sin_addr.s_addr.to_ne_bytes());
                let mask = u32::from_be(m.sin_addr.s_addr);
                let bits = mask.count_ones();
                if trusted(&name)
                    && ip.is_private()
                    && bits > 0
                    && mask == u32::MAX.checked_shl(32 - bits).unwrap_or(0)
                    && a.ifa_flags & libc::IFF_UP as u32 != 0
                {
                    out.insert((name, format!("{ip}/{bits}")));
                }
            }
            p = a.ifa_next;
        }
        libc::freeifaddrs(head);
    }
    Ok(out.into_iter().collect())
}
pub fn key(n: &[(String, String)]) -> String {
    n.iter()
        .map(|(i, a)| format!("{i} {a}"))
        .collect::<Vec<_>>()
        .join(" ")
}
pub fn interfaces(c: &crate::config::Config, n: &[(String, String)]) -> Vec<String> {
    let mut out = vec!["127.0.0.1/8".into()];
    for (name, cidr) in n {
        let ip = cidr.split('/').next().unwrap_or("");
        if (c["INTERFACES_AUTO"] == "1"
            || c["EXTRA_INTERFACES"]
                .split_whitespace()
                .any(|s| s == name || s.split('/').next() == Some(ip)))
            && !out.contains(cidr)
        {
            out.push(cidr.clone())
        }
    }
    out
}
#[derive(Debug)]
pub struct Process {
    pub pid: i32,
    pub start: String,
    pub exe: PathBuf,
    pub handle: OwnedFd,
}
fn start(pid: i32) -> Option<String> {
    let s = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let tail = s.rsplit_once(") ")?.1;
    let a: Vec<_> = tail.split_whitespace().collect();
    if a.first() == Some(&"Z") {
        return None;
    }
    Some(a.get(19)?.to_string())
}
pub fn processes(exes: &[PathBuf]) -> Result<Vec<Process>> {
    let mut out = vec![];
    for e in fs::read_dir("/proc")?.flatten() {
        let Some(pid) = e.file_name().to_str().and_then(|s| s.parse::<i32>().ok()) else {
            continue;
        };
        let Some(before) = start(pid) else { continue };
        let Ok(exe) = fs::read_link(e.path().join("exe")) else {
            continue;
        };
        if !exes.contains(&exe) {
            continue;
        }
        let handle = match fd(unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) as i32 }) {
            Ok(h) => h,
            Err(e) => {
                if start(pid).is_none() {
                    continue;
                }
                return Err(e);
            }
        };
        if start(pid).as_ref() != Some(&before)
            || fs::read_link(e.path().join("exe")).ok().as_ref() != Some(&exe)
        {
            continue;
        }
        out.push(Process {
            pid,
            start: before,
            exe,
            handle,
        });
    }
    Ok(out)
}
pub fn terminate(ps: &[Process]) -> Result<()> {
    for p in ps {
        if unsafe {
            libc::syscall(
                libc::SYS_pidfd_send_signal,
                p.handle.as_raw_fd(),
                libc::SIGTERM,
                std::ptr::null::<libc::siginfo_t>(),
                0,
            )
        } < 0
            && std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
        {
            return Err(std::io::Error::last_os_error().into());
        }
    }
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut polls: Vec<_> = ps
        .iter()
        .map(|p| libc::pollfd {
            fd: p.handle.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        })
        .collect();
    while polls.iter().any(|p| p.fd >= 0) && Instant::now() < deadline {
        poll(
            &mut polls,
            deadline
                .saturating_duration_since(Instant::now())
                .as_millis() as i32,
        )?;
        for p in &mut polls {
            if p.revents != 0 {
                p.fd = -1
            }
        }
    }
    for (p, wait) in ps.iter().zip(&polls) {
        if wait.fd >= 0 {
            unsafe {
                libc::syscall(
                    libc::SYS_pidfd_send_signal,
                    p.handle.as_raw_fd(),
                    libc::SIGKILL,
                    std::ptr::null::<libc::siginfo_t>(),
                    0,
                );
            }
        }
    }
    // SIGKILL is asynchronous too: never report a successful stop while a listener
    // may still be owned by the old process. This is an exit event wait, not polling.
    let deadline = Instant::now() + Duration::from_secs(2);
    while polls.iter().any(|p| p.fd >= 0) && Instant::now() < deadline {
        poll(
            &mut polls,
            deadline
                .saturating_duration_since(Instant::now())
                .as_millis()
                .max(1) as i32,
        )?;
        for p in &mut polls {
            if p.revents != 0 {
                p.fd = -1;
            }
        }
    }
    if polls.iter().any(|p| p.fd >= 0) {
        return Err("process did not exit after SIGKILL".into());
    }
    Ok(())
}
pub fn poll(fds: &mut [libc::pollfd], timeout: i32) -> Result<i32> {
    let r = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as _, timeout) };
    if r < 0 {
        let e = std::io::Error::last_os_error();
        if e.kind() == std::io::ErrorKind::Interrupted {
            Ok(0)
        } else {
            Err(e.into())
        }
    } else {
        Ok(r)
    }
}
pub fn sockets(ps: &[Process]) -> BTreeSet<(String, u16)> {
    let mut inodes = BTreeSet::new();
    for p in ps {
        if start(p.pid).as_ref() != Some(&p.start)
            || fs::read_link(format!("/proc/{}/exe", p.pid)).ok().as_ref() != Some(&p.exe)
        {
            continue;
        }
        if let Ok(entries) = fs::read_dir(format!("/proc/{}/fd", p.pid)) {
            for e in entries.flatten() {
                if let Ok(link) = fs::read_link(e.path()) {
                    if let Some(i) = link
                        .to_str()
                        .and_then(|s| s.strip_prefix("socket:["))
                        .and_then(|s| s.strip_suffix(']'))
                    {
                        inodes.insert(i.to_string());
                    }
                }
            }
        }
    }
    let mut out = BTreeSet::new();
    for name in ["tcp", "tcp6"] {
        let Ok(s) = fs::read_to_string(format!("/proc/net/{name}")) else {
            continue;
        };
        for line in s.lines().skip(1) {
            let a: Vec<_> = line.split_whitespace().collect();
            if a.len() < 10 || a[3] != "0A" || !inodes.contains(a[9]) {
                continue;
            }
            let Some((host, port)) = a[1].split_once(':') else {
                continue;
            };
            let Ok(port) = u16::from_str_radix(port, 16) else {
                continue;
            };
            if name == "tcp" {
                if let Ok(v) = u32::from_str_radix(host, 16) {
                    out.insert((Ipv4Addr::from(v.to_le_bytes()).to_string(), port));
                }
            } else if host == "00000000000000000000000000000000" {
                out.insert(("::".into(), port));
            }
        }
    }
    out
}
pub fn inotify(paths: &[&Path]) -> Result<OwnedFd> {
    let f = fd(unsafe { libc::inotify_init1(libc::IN_CLOEXEC | libc::IN_NONBLOCK) })?;
    for p in paths {
        let c = CString::new(p.as_os_str().as_encoded_bytes())?;
        if unsafe {
            libc::inotify_add_watch(
                f.as_raw_fd(),
                c.as_ptr(),
                libc::IN_CLOSE_WRITE
                    | libc::IN_MOVED_TO
                    | libc::IN_CREATE
                    | libc::IN_DELETE
                    | libc::IN_DELETE_SELF
                    | libc::IN_MOVE_SELF,
            )
        } < 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
    }
    Ok(f)
}
pub fn drain(f: &OwnedFd) {
    let mut b = [0u8; 65536];
    for _ in 0..32 {
        if unsafe { libc::read(f.as_raw_fd(), b.as_mut_ptr().cast(), b.len()) } <= 0 {
            break;
        }
    }
}
pub fn netlink() -> Result<OwnedFd> {
    let f = fd(unsafe {
        libc::socket(
            libc::AF_NETLINK,
            libc::SOCK_RAW | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
            libc::NETLINK_ROUTE,
        )
    })?;
    let mut a: libc::sockaddr_nl = unsafe { std::mem::zeroed() };
    a.nl_family = libc::AF_NETLINK as _;
    a.nl_groups=0x1 | 0x10 /* RTMGRP_LINK | RTMGRP_IPV4_IFADDR, Linux UAPI */;
    if unsafe {
        libc::bind(
            f.as_raw_fd(),
            (&a as *const libc::sockaddr_nl).cast(),
            std::mem::size_of_val(&a) as _,
        )
    } < 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(f)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_virtual() {
        assert!(!trusted("rmnet0"));
        assert!(!trusted("tun0"));
        assert!(trusted("wlan0"));
    }
    #[test]
    fn bind_restricted() {
        let mut c = crate::config::parse("").unwrap();
        c.insert("INTERFACES_AUTO".into(), "0".into());
        c.insert("EXTRA_INTERFACES".into(), "192.168.1.2/0 8.8.8.8".into());
        assert_eq!(
            interfaces(&c, &[("wlan0".into(), "192.168.1.2/24".into())]),
            vec!["127.0.0.1/8", "192.168.1.2/24"]
        );
    }
    #[test]
    fn listener_requires_owned_inode() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        assert!(!sockets(&[]).contains(&("127.0.0.1".into(), port)));
        let ps = processes(&[std::env::current_exe().unwrap()]).unwrap();
        assert!(sockets(&ps).contains(&("127.0.0.1".into(), port)));
    }
    #[test]
    fn pidfd_stop_only_selected_process() {
        let mut child = std::process::Command::new("/system/bin/sleep")
            .arg("60")
            .spawn()
            .unwrap();
        let exe = std::fs::read_link(format!("/proc/{}/exe", child.id())).unwrap();
        let ps: Vec<_> = processes(&[exe])
            .unwrap()
            .into_iter()
            .filter(|p| p.pid == child.id() as i32)
            .collect();
        assert_eq!(ps.len(), 1);
        terminate(&ps).unwrap();
        assert!(!child.wait().unwrap().success());
        assert!(std::path::Path::new(&format!("/proc/{}", std::process::id())).exists());
    }
}
