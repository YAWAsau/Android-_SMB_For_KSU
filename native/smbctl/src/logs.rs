use crate::{config, Result};
use std::{
    fs,
    io::Write,
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};
const MAX_ARCHIVES: usize = 3;
const MAX_ARCHIVE_BYTES: u64 = 16 * 1024 * 1024;
pub fn boot_id() -> Result<String> {
    let id = fs::read_to_string("/proc/sys/kernel/random/boot_id")?
        .trim()
        .to_string();
    if id.is_empty() || !id.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-') {
        return Err("invalid kernel boot_id".into());
    }
    Ok(id)
}
pub fn changed(rt: &Path, boot: &str) -> bool {
    fs::read_to_string(rt.join("log/.boot-id"))
        .map(|s| s.trim() != boot)
        .unwrap_or(true)
}
fn bytes(path: &Path) -> Result<u64> {
    let m = fs::symlink_metadata(path)?;
    if m.is_symlink() {
        return Ok(0);
    }
    if m.is_file() {
        return Ok(m.len());
    }
    let mut total = 0u64;
    if m.is_dir() {
        for e in fs::read_dir(path)? {
            total = total.saturating_add(bytes(&e?.path())?);
        }
    }
    Ok(total)
}
fn prune(history: &Path) -> Result<()> {
    let mut entries = Vec::new();
    for e in fs::read_dir(history)? {
        let e = e?;
        if e.file_name().to_string_lossy().starts_with("boot-") && e.file_type()?.is_dir() {
            entries.push((e.file_name(), e.path(), bytes(&e.path())?));
        }
    }
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    let mut total: u64 = entries.iter().map(|e| e.2).sum();
    let mut count = entries.len();
    for (_, p, n) in entries {
        if count <= MAX_ARCHIVES && total <= MAX_ARCHIVE_BYTES {
            break;
        }
        fs::remove_dir_all(p)?;
        total = total.saturating_sub(n);
        count -= 1;
    }
    Ok(())
}
// Caller holds control.lock and stops module writers before a boot transition.
// The marker belongs to the current directory, so a crash after rename cannot
// label old files as belonging to the new boot or archive the same files twice.
pub fn prepare(rt: &Path, boot: &str) -> Result<bool> {
    use std::os::unix::fs::PermissionsExt;
    if !changed(rt, boot) {
        return Ok(false);
    }
    let log = rt.join("log");
    let history = rt.join("log-history");
    for path in [&log, &history] {
        if let Ok(meta) = fs::symlink_metadata(path) {
            if !meta.is_dir() || meta.is_symlink() {
                return Err(
                    format!("log directory must be a real directory: {}", path.display()).into(),
                );
            }
        }
    }
    fs::create_dir_all(&history)?;
    fs::set_permissions(&history, fs::Permissions::from_mode(0o700))?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
    let previous = fs::read_to_string(log.join(".boot-id")).unwrap_or_else(|_| "legacy".into());
    let previous = previous.trim();
    let label = if !previous.is_empty()
        && previous
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-')
    {
        previous
    } else {
        "unknown"
    };
    let archive = history.join(format!("boot-{now:030}-{label}"));
    if log.is_dir() && fs::read_dir(&log)?.next().is_some() {
        fs::rename(&log, &archive)?;
        let stamp = rt.join("auto_diagnostic.stamp");
        if stamp.exists() {
            fs::rename(stamp, archive.join("auto_diagnostic.stamp"))?;
        }
    }
    fs::create_dir_all(&log)?;
    fs::set_permissions(&log, fs::Permissions::from_mode(0o700))?;
    let mut f = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log.join("module.log"))?;
    writeln!(
        f,
        "{} component=smbctl BOOT_LOG_BEGIN boot_id={boot} previous={label}",
        now / 1_000_000_000
    )?;
    f.sync_all()?;
    prune(&history)?;
    config::atomic(&log.join(".boot-id"), format!("{boot}\n").as_bytes(), 0o600)?;
    Ok(true)
}
#[cfg(test)]
mod tests {
    use super::*;
    fn dir(name: &str) -> std::path::PathBuf {
        let p = std::path::PathBuf::from(format!(
            "/data/local/tmp/smb-log-test-{}-{name}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(p.join("log")).unwrap();
        p
    }
    #[test]
    fn boot_rotation_preserves_same_boot_and_stderr() {
        let p = dir("rotation");
        fs::write(p.join("log/notify_stderr.log"), "old failure").unwrap();
        fs::write(p.join("auto_diagnostic.stamp"), "old").unwrap();
        assert!(prepare(&p, "a").unwrap());
        assert!(!p.join("log/notify_stderr.log").exists());
        let archives: Vec<_> = fs::read_dir(p.join("log-history"))
            .unwrap()
            .map(|e| e.unwrap().path())
            .collect();
        assert_eq!(
            fs::read_to_string(archives[0].join("notify_stderr.log")).unwrap(),
            "old failure"
        );
        assert!(archives[0].join("auto_diagnostic.stamp").exists());
        fs::write(p.join("log/notify_stderr.log"), "current").unwrap();
        assert!(!prepare(&p, "a").unwrap());
        assert_eq!(
            fs::read_to_string(p.join("log/notify_stderr.log")).unwrap(),
            "current"
        );
        assert!(prepare(&p, "b").unwrap());
        assert!(!p.join("log/notify_stderr.log").exists());
        fs::remove_dir_all(p).unwrap();
    }
    #[test]
    fn archive_limits_and_symlink_safety() {
        let p = dir("limits");
        let outside = p.join("outside");
        fs::write(&outside, "keep").unwrap();
        std::os::unix::fs::symlink(&outside, p.join("log/link")).unwrap();
        for n in 0..6 {
            prepare(&p, &format!("b{n}")).unwrap();
        }
        assert_eq!(fs::read_dir(p.join("log-history")).unwrap().count(), 3);
        assert_eq!(fs::read_to_string(&outside).unwrap(), "keep");
        fs::File::create(p.join("log/huge"))
            .unwrap()
            .set_len(MAX_ARCHIVE_BYTES + 1)
            .unwrap();
        prepare(&p, "last").unwrap();
        assert!(bytes(&p.join("log-history")).unwrap() <= MAX_ARCHIVE_BYTES);
        assert_eq!(fs::read_to_string(outside).unwrap(), "keep");
        fs::remove_dir_all(p).unwrap();
    }
    #[test]
    fn recovery_after_archive_rename() {
        let p = dir("recovery");
        prepare(&p, "old").unwrap();
        fs::rename(
            p.join("log"),
            p.join("log-history/boot-000000000000000000000000000001-old"),
        )
        .unwrap();
        assert!(prepare(&p, "new").unwrap());
        assert!(!prepare(&p, "new").unwrap());
        assert_eq!(fs::read_dir(p.join("log-history")).unwrap().count(), 1);
        fs::remove_dir_all(p).unwrap();
    }
}
