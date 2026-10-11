use crate::Result;
use std::{
    ffi::CString,
    fs,
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
    process::Command,
    sync::Arc,
};
unsafe extern "C" {
    fn __system_property_get(name: *const libc::c_char, value: *mut libc::c_char) -> libc::c_int;
    fn __system_property_find(name: *const libc::c_char) -> *const libc::c_void;
    fn __system_property_serial(pi: *const libc::c_void) -> u32;
    fn __system_property_area_serial() -> u32;
    fn __system_property_wait(
        pi: *const libc::c_void,
        old: u32,
        new: *mut u32,
        timeout: *const libc::timespec,
    ) -> bool;
}
pub fn property(name: &str) -> String {
    let name = CString::new(name).unwrap();
    let mut out = [0u8; 92];
    let n =
        unsafe { __system_property_get(name.as_ptr(), out.as_mut_ptr().cast()) }.max(0) as usize;
    String::from_utf8_lossy(&out[..n]).into_owned()
}
// Serial-before-value closes both update and first-creation races.
// Once present, wait on this property only. The deadline is not a periodic timer.
pub fn wait_equals(key: &str, expected: &str, timeout: std::time::Duration) -> Result<()> {
    let name = CString::new(key)?;
    if key.is_empty() {
        return Err("empty property name".into());
    }
    let deadline = std::time::Instant::now()
        .checked_add(timeout)
        .ok_or("timeout overflow")?;
    loop {
        let global = unsafe { __system_property_area_serial() };
        let pi = unsafe { __system_property_find(name.as_ptr()) };
        let serial = if pi.is_null() {
            global
        } else {
            unsafe { __system_property_serial(pi) }
        };
        if property(key) == expected {
            return Ok(());
        }
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            return Err("property wait timed out".into());
        }
        let ts = libc::timespec {
            tv_sec: remaining.as_secs().try_into()?,
            tv_nsec: remaining.subsec_nanos().into(),
        };
        let mut next = serial;
        unsafe {
            __system_property_wait(pi, serial, &mut next, &ts);
        }
    }
}
pub fn user(path: &str) -> Option<u32> {
    if path == "/sdcard"
        || path.starts_with("/sdcard/")
        || path == "/storage/self/primary"
        || path.starts_with("/storage/self/primary/")
    {
        return Some(0);
    }
    for prefix in ["/storage/emulated/", "/data/media/", "/data/user/"] {
        if let Some(tail) = path.strip_prefix(prefix) {
            return tail.split('/').next()?.parse().ok();
        }
    }
    None
}
pub fn directory_events(path: &str) -> Option<OwnedFd> {
    let uid = user(path)?;
    let roots = [
        "/data".to_string(),
        "/data/media".to_string(),
        format!("/data/media/{uid}"),
        "/data/user".to_string(),
        format!("/data/user/{uid}"),
    ];
    let paths: Vec<_> = roots
        .iter()
        .map(std::path::Path::new)
        .filter(|p| p.is_dir())
        .collect();
    crate::os::inotify(&paths).ok()
}
pub fn ready(path: &str) -> bool {
    let Some(uid) = user(path) else {
        return true;
    };
    let unlocked = match property(&format!("sys.user.{uid}.ce_available")).as_str() {
        "true" | "1" => true,
        "false" | "0" => false,
        _ => Command::new("/system/bin/am")
            .args(["get-started-user-state", &uid.to_string()])
            .output()
            .is_ok_and(|o| {
                o.status.success()
                    && String::from_utf8_lossy(&o.stdout).trim() == "RUNNING_UNLOCKED"
            }),
    };
    if !unlocked {
        return false;
    }
    let root = if path.starts_with("/data/user/") {
        format!("/data/user/{uid}")
    } else {
        format!("/data/media/{uid}")
    };
    fs::read_dir(root).is_ok_and(|mut entries| entries.next().is_none_or(|e| e.is_ok()))
}
// A property futex waiter feeds eventfd, which is part of the existing poll set.
// This thread lives exactly as long as the watcher process; it has no timer.
pub struct Events {
    pub fd: Arc<OwnedFd>,
    key: String,
}
impl Events {
    fn key_for(path: &str) -> String {
        user(path)
            .map(|u| format!("sys.user.{u}.ce_available"))
            .unwrap_or_default()
    }
    pub fn new(path: &str) -> Result<Self> {
        Self::for_key(Self::key_for(path))
    }
    fn for_key(key: String) -> Result<Self> {
        let raw = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) };
        if raw < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let fd = Arc::new(unsafe { OwnedFd::from_raw_fd(raw) });
        // Non-CE shares need no property waiter at all.
        if key.is_empty() {
            return Ok(Self { fd, key });
        }
        let writer = fd.clone();
        let selected = key.clone();
        std::thread::Builder::new()
            .name("smb-ce-events".into())
            .spawn(move || {
                let name = CString::new(selected.clone()).unwrap();
                let mut previous: Option<String> = None;
                loop {
                    // Reading the global serial before find closes the property
                    // creation race. Once present, wait only on this prop_info.
                    let global = unsafe { __system_property_area_serial() };
                    let pi = unsafe { __system_property_find(name.as_ptr()) };
                    let serial = if pi.is_null() {
                        global
                    } else {
                        unsafe { __system_property_serial(pi) }
                    };
                    let value = property(&selected);
                    if previous.as_ref() != Some(&value) || pi.is_null() {
                        let one = 1u64;
                        unsafe {
                            libc::write(writer.as_raw_fd(), (&one as *const u64).cast(), 8);
                        }
                        previous = Some(value);
                    }
                    let mut next = serial;
                    unsafe {
                        __system_property_wait(pi, serial, &mut next, std::ptr::null());
                    }
                }
            })?;
        Ok(Self { fd, key })
    }
    pub fn matches(&self, path: &str) -> bool {
        self.key == Self::key_for(path)
    }
    pub fn drain(&self) {
        let mut n = 0u64;
        unsafe {
            libc::read(self.fd.as_raw_fd(), (&mut n as *mut u64).cast(), 8);
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn path_user_scope() {
        assert_eq!(user("/sdcard/Music"), Some(0));
        assert_eq!(user("/data/media/10/Music"), Some(10));
        assert_eq!(user("/data/user/12/app"), Some(12));
        assert_eq!(user("/sdcard-other"), None);
        assert_eq!(user("/data/local/tmp"), None);
    }
    #[test]
    fn property_event_wakeup() {
        let key = format!("debug.smbce.{}", std::process::id());
        let events = Events::for_key(key.clone()).unwrap();
        assert!(Command::new("/system/bin/setprop")
            .args([&key, "before"])
            .status()
            .unwrap()
            .success());
        let mut p = [libc::pollfd {
            fd: events.fd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        }];
        crate::os::poll(&mut p, 3000).unwrap();
        events.drain();
        assert!(Command::new("/system/bin/setprop")
            .args([&key, "after"])
            .status()
            .unwrap()
            .success());
        crate::os::poll(&mut p, 3000).unwrap();
        assert_ne!(p[0].revents, 0);
        assert_eq!(property(&key), "after");
        events.drain();
        let other = format!("debug.smbother.{}", std::process::id());
        assert!(Command::new("/system/bin/setprop")
            .args([&other, "1"])
            .status()
            .unwrap()
            .success());
        crate::os::poll(&mut p, 200).unwrap();
        assert_eq!(
            p[0].revents, 0,
            "unrelated property must not signal watcher"
        );
        assert!(events.matches("/data/local/tmp") == false);
        Command::new("/system/bin/setprop")
            .args([&other, ""])
            .status()
            .unwrap();
        Command::new("/system/bin/setprop")
            .args([&key, ""])
            .status()
            .unwrap();
    }
}
