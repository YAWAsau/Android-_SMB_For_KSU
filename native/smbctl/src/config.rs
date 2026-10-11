use crate::Result;
use std::{collections::BTreeMap, fs, io::Write, os::unix::fs::OpenOptionsExt, path::Path};
pub type Config = BTreeMap<String, String>;
pub const DEFAULTS: &[(&str, &str)] = &[
    ("AUTO_START", "0"),
    ("ENABLED", "0"),
    ("SHARE_PATH", "/sdcard/SpeedBackup"),
    ("SHARE_NAME", "SpeedBackup"),
    ("READ_ONLY", "0"),
    ("MIN_PROTOCOL", "SMB2_02"),
    ("MAX_PROTOCOL", "SMB3"),
    ("BIND_INTERFACES", "1"),
    ("INTERFACES_AUTO", "1"),
    ("EXTRA_INTERFACES", ""),
    ("PORT", "445"),
    ("NETBIOS_NAME", "ANDROIDSMB"),
    ("WORKGROUP", "WORKGROUP"),
    ("AUTH_MODE", "guest"),
    ("SMB_USERNAME", "speedbackup"),
];
pub fn parse(s: &str) -> Result<Config> {
    if s.len() > 65536 {
        return Err("config exceeds 64 KiB".into());
    }
    let mut c: Config = DEFAULTS
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    for line in s.lines() {
        let line = line.trim_end_matches('\r');
        if line.trim().is_empty() || line.trim_start().starts_with('#') {
            continue;
        }
        let (k, v) = line.split_once('=').ok_or("invalid config line")?;
        // Preserve this legacy metadata field during upgrades. It is not a
        // Samba parameter and must never be evaluated as shell input.
        if !c.contains_key(k) && k != "MT_COMPAT_MODE" {
            return Err(format!("unknown config key: {k}").into());
        }
        c.insert(k.into(), v.into());
    }
    validate(&c)?;
    Ok(c)
}
pub fn load(p: &Path) -> Result<Config> {
    match fs::read_to_string(p) {
        Ok(s) => parse(&s),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => parse(""),
        Err(e) => Err(e.into()),
    }
}
pub fn validate(c: &Config) -> Result<()> {
    if let Some(v) = c.get("MT_COMPAT_MODE") {
        if !matches!(v.as_str(), "0" | "1") {
            return Err("invalid boolean: MT_COMPAT_MODE".into());
        }
    }
    for (k, v) in c {
        if v.len() > 4096 || v.chars().any(char::is_control) {
            return Err(format!("invalid characters/length: {k}").into());
        }
    }
    for k in [
        "AUTO_START",
        "ENABLED",
        "READ_ONLY",
        "BIND_INTERFACES",
        "INTERFACES_AUTO",
    ] {
        if !matches!(c[k].as_str(), "0" | "1") {
            return Err(format!("invalid boolean: {k}").into());
        }
    }
    if c["PORT"].parse::<u16>().unwrap_or(0) == 0 {
        return Err("port must be 1..65535".into());
    }
    if !matches!(c["AUTH_MODE"].as_str(), "guest" | "user") {
        return Err("invalid auth mode".into());
    }
    let u = &c["SMB_USERNAME"];
    if u.is_empty()
        || u.len() > 32
        || !u
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
    {
        return Err("invalid username".into());
    }
    for k in ["SHARE_NAME", "NETBIOS_NAME", "WORKGROUP"] {
        let v = &c[k];
        if v.is_empty()
            || v.len() > 128
            || v.contains(['[', ']', '/', '\\', ':', '*', '?', '"', '<', '>', '|', '%'])
        {
            return Err(format!("invalid {k}").into());
        }
    }
    let path = &c["SHARE_PATH"];
    if !path.starts_with('/')
        || path.contains('%')
        || Path::new(path)
            .components()
            .any(|x| matches!(x, std::path::Component::ParentDir))
    {
        return Err("share path must be absolute, without .. or Samba substitutions (%)".into());
    }
    let protocols = [
        "NT1", "SMB2", "SMB2_02", "SMB2_10", "SMB3", "SMB3_00", "SMB3_02", "SMB3_10", "SMB3_11",
    ];
    for k in ["MIN_PROTOCOL", "MAX_PROTOCOL"] {
        if !protocols.contains(&c[k].as_str()) {
            return Err("invalid protocol".into());
        }
    }
    let rank = |s: &str| match s {
        "NT1" => 0,
        "SMB2" | "SMB2_02" => 1,
        "SMB2_10" => 2,
        "SMB3_00" => 3,
        "SMB3_02" => 4,
        "SMB3_10" => 5,
        _ => 6,
    };
    if !["SMB2", "SMB3"].contains(&c["MIN_PROTOCOL"].as_str())
        && !["SMB2", "SMB3"].contains(&c["MAX_PROTOCOL"].as_str())
        && rank(&c["MIN_PROTOCOL"]) > rank(&c["MAX_PROTOCOL"])
    {
        return Err("minimum protocol exceeds maximum".into());
    }
    Ok(())
}
pub fn update(c: &mut Config, args: &[String]) -> Result<()> {
    for arg in args {
        let (k, v) = arg.split_once('=').ok_or("expected KEY=value")?;
        if !c.contains_key(k) {
            return Err(format!("unknown key {k}").into());
        }
        c.insert(k.into(), v.into());
    }
    validate(c)
}
pub fn atomic(p: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    let parent = p.parent().ok_or("missing parent")?;
    fs::create_dir_all(parent)?;
    let tmp = parent.join(format!(
        ".smbctl-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_nanos()
    ));
    let result = (|| -> Result<()> {
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        fs::rename(&tmp, p)?;
        fs::File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}
pub fn save(p: &Path, c: &Config) -> Result<()> {
    validate(c)?;
    let mut s = DEFAULTS
        .iter()
        .map(|(k, _)| format!("{k}={}\n", c[*k]))
        .collect::<String>();
    if let Some(v) = c.get("MT_COMPAT_MODE") {
        s.push_str(&format!("MT_COMPAT_MODE={v}\n"));
    }
    if fs::read(p).ok().as_deref() == Some(s.as_bytes()) {
        return Ok(());
    }
    atomic(p, s.as_bytes(), 0o600)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legacy_metadata_is_preserved_without_changing_settings() {
        let baseline = parse("AUTH_MODE=user\nSHARE_PATH=/sdcard\n").unwrap();
        let dir = std::path::PathBuf::from(format!(
            "/data/local/tmp/smbctl-legacy-{}",
            std::process::id()
        ));
        let p = dir.join("config.conf");
        for value in ["0", "1"] {
            let mut c = parse(&format!(
                "AUTH_MODE=user\nSHARE_PATH=/sdcard\nMT_COMPAT_MODE={value}\n"
            ))
            .unwrap();
            save(&p, &c).unwrap();
            assert_eq!(load(&p).unwrap(), c);
            assert_eq!(c.remove("MT_COMPAT_MODE").unwrap(), value);
            assert_eq!(c, baseline);
        }
        assert!(parse("MT_COMPAT_MODE=$(touch evil)").is_err());
        assert!(parse("UNKNOWN_SETTING=0").is_err());
        std::fs::remove_file(p).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
    #[test]
    fn literal_paths() {
        let c = parse("SHARE_PATH=/data/Music $(touch evil) '中文'\n").unwrap();
        assert_eq!(c["SHARE_PATH"], "/data/Music $(touch evil) '中文'");
    }
    #[test]
    fn rejects_injection() {
        for s in [
            "PORT=0",
            "PORT=65536",
            "SHARE_NAME=x]\n[evil]",
            "SHARE_PATH=/data/../etc",
            "AUTO_START=yes",
            "EXTRA_INTERFACES=x\ty",
            "AUTH_MODE=other",
        ] {
            assert!(parse(s).is_err(), "{s}")
        }
    }
    #[test]
    fn atomic_roundtrip_and_validation() {
        let dir = std::path::PathBuf::from(format!(
            "/data/local/tmp/smbctl-unit-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("config.conf");
        let c = parse("SHARE_PATH=/data/中文 音樂 $HOME\n").unwrap();
        save(&p, &c).unwrap();
        assert_eq!(load(&p).unwrap(), c);
        let before = std::fs::read(&p).unwrap();
        let mut bad = c.clone();
        bad.insert("PORT".into(), "0".into());
        assert!(save(&p, &bad).is_err());
        assert_eq!(std::fs::read(&p).unwrap(), before);
        std::fs::remove_file(p).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
}
