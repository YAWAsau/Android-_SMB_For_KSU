mod config;
mod logs;
mod os;
mod password;
mod storage;
mod watch;
use config::Config;
use std::{
    fs,
    io::Write,
    os::fd::AsRawFd,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
struct App {
    module: PathBuf,
    data: PathBuf,
    rt: PathBuf,
}
impl App {
    fn new() -> Result<Self> {
        let module = std::env::current_exe()?
            .parent()
            .ok_or("bin parent")?
            .parent()
            .ok_or("module parent")?
            .to_path_buf();
        let data = std::env::var_os("SMBDWEBUI_DATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/data/adb/smbdwebui"));
        let rt = data.join("runtime");
        for d in [
            "log", "tmp", "lock", "state", "cache", "private", "run", "ncalrpc",
        ] {
            fs::create_dir_all(rt.join(d))?;
        }
        use std::os::unix::fs::PermissionsExt;
        for p in [&data, &rt, &rt.join("private")] {
            fs::set_permissions(p, fs::Permissions::from_mode(0o700))?
        }
        Ok(Self { module, data, rt })
    }
    fn prepare_logs(&self) -> Result<()> {
        let boot = logs::boot_id()?;
        if logs::changed(&self.rt, &boot) {
            if !self.pids()?.is_empty() {
                self.halt()?;
            }
            logs::prepare(&self.rt, &boot)?;
        }
        Ok(())
    }
    fn cfg(&self) -> PathBuf {
        self.data.join("config.conf")
    }
    fn load(&self) -> Result<Config> {
        config::load(&self.cfg())
    }
    fn lock(&self) -> Result<os::Lock> {
        os::Lock::new(&self.rt.join("control.lock"), false)
    }
    fn bin(&self, n: &str) -> PathBuf {
        self.module.join("bin").join(n)
    }
    fn pids(&self) -> Result<Vec<os::Process>> {
        os::processes(&[self.bin("smbd")])
    }
    fn password(&self) -> bool {
        fs::read_to_string(self.rt.join("private/smbpasswd"))
            .unwrap_or_default()
            .lines()
            .any(|s| s.starts_with("root:0:"))
    }
    fn log(&self, s: &str) {
        let p = self.rt.join("log/module.log");
        if fs::metadata(&p).map(|m| m.len() > 1048576).unwrap_or(false) {
            let _ = fs::rename(&p, self.rt.join("log/module.log.1"));
        }
        if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(p) {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            let _ = writeln!(
                f,
                "{now} component=smbctl pid={} {}",
                std::process::id(),
                s.replace(['\n', '\r'], " ")
            );
        }
    }
    fn notify(&self, kind: &str, msg: &str) {
        let _ = Command::new("/system/bin/sh")
            .arg(self.module.join("notify.sh"))
            .args(["event", kind, "SMB 伺服器", msg, msg])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
    fn effective(&self, c: &Config) -> String {
        let s = &c["SHARE_PATH"];
        for prefix in ["/sdcard", "/storage/emulated/0"] {
            if s == prefix || s.starts_with(&format!("{prefix}/")) {
                let p = format!("/data/media/0{}", &s[prefix.len()..]);
                if Path::new(&p).is_dir() {
                    return p;
                }
            }
        }
        s.clone()
    }
    fn ready_with(&self, c: &Config, n: &[(String, String)], ps: &[os::Process]) -> bool {
        if ps.is_empty() {
            return false;
        }
        let socks = os::sockets(ps);
        let port = c["PORT"].parse().unwrap_or(445);
        if c["BIND_INTERFACES"] == "0" && c["AUTO_START"] == "0" {
            return socks.contains(&("0.0.0.0".into(), port))
                || socks.contains(&("::".into(), port));
        }
        let interfaces = os::interfaces(c, n);
        interfaces.len() > 1
            && interfaces
                .iter()
                .all(|s| socks.contains(&(s.split('/').next().unwrap_or("").into(), port)))
    }
    fn ready(&self, c: &Config) -> Result<bool> {
        Ok(self.ready_with(c, &os::network()?, &self.pids()?))
    }
    fn version(&self, name: &str) -> String {
        let binary = self.bin(name);
        let stamp = fs::metadata(&binary)
            .ok()
            .and_then(|m| {
                Some(format!(
                    "{}:{}",
                    m.len(),
                    m.modified()
                        .ok()?
                        .duration_since(std::time::UNIX_EPOCH)
                        .ok()?
                        .as_nanos()
                ))
            })
            .unwrap_or_default();
        let cache = self.rt.join(format!("cache/{name}-rust-version"));
        if let Ok(s) = fs::read_to_string(&cache) {
            if let Some((key, v)) = s.split_once('\n') {
                if key == stamp {
                    return v.into();
                }
            }
        }
        let v = Command::new(binary)
            .arg("-V")
            .output()
            .ok()
            .map(|o| {
                String::from_utf8_lossy(&o.stdout)
                    .lines()
                    .next()
                    .unwrap_or("")
                    .to_string()
            })
            .unwrap_or_default();
        let _ = config::atomic(&cache, format!("{stamp}\n{v}").as_bytes(), 0o600);
        v
    }
    fn status(&self) -> Result<serde_json::Value> {
        let c = self.load()?;
        let n = os::network()?;
        let ps = self.pids()?;
        let running = self.ready_with(&c, &n, &ps);
        let waiting_storage = c["ENABLED"] == "1" && !storage::ready(&c["SHARE_PATH"]);
        let waiting = self.rt.join("waiting_network").exists() && c["ENABLED"] == "1";
        let addresses = n
            .iter()
            .map(|(_, a)| {
                format!(
                    "smb://{}/{}/",
                    a.split('/').next().unwrap_or(""),
                    c["SHARE_NAME"]
                )
            })
            .collect::<Vec<_>>()
            .join(" ");
        let mode = if c["AUTH_MODE"] == "guest" {
            "Guest / 匿名".into()
        } else {
            format!("帳號密碼 ({})", c["SMB_USERNAME"])
        };
        Ok(
            serde_json::json!({"running":running,"processRunning":!ps.is_empty(),"waitingNetwork":waiting,"waitingStorage":waiting_storage,"pid":ps.iter().map(|p|p.pid.to_string()).collect::<Vec<_>>().join(" "),"version":self.version("smbd"),"sharePath":c["SHARE_PATH"],"effectiveSharePath":self.effective(&c),"performanceProfile":"smb2-smb3","shareName":c["SHARE_NAME"],"readOnly":c["READ_ONLY"],"guest":c["AUTH_MODE"]=="guest","authMode":c["AUTH_MODE"],"authLabel":mode,"smbUsername":c["SMB_USERNAME"],"passwordSet":self.password(),"minProtocol":c["MIN_PROTOCOL"],"maxProtocol":c["MAX_PROTOCOL"],"effectiveMinProtocol":c["MIN_PROTOCOL"],"effectiveMaxProtocol":c["MAX_PROTOCOL"],"port":c["PORT"],"interfaces":os::interfaces(&c,&n).join(" "),"trustedLanInterfaces":os::key(&n),"lanGuard":true,"networkWatchMode":"rust-rtnetlink-inotify-pidfd","changeNotify":true,"kernelChangeNotify":true,"smb3DirectoryLeases":false,"netwatchVersion":concat!("smbctl ",env!("CARGO_PKG_VERSION")),"addresses":addresses,"configPath":self.cfg(),"confPath":self.rt.join("smb.conf")}),
        )
    }
    fn card(&self) -> Result<()> {
        let s = self.status()?;
        let p = self.module.join("module.prop");
        if !p.exists() {
            return Ok(());
        }
        let state = if s["running"] == true {
            "執行中"
        } else if s["waitingStorage"] == true {
            "等待使用者解鎖／儲存解密"
        } else if s["waitingNetwork"] == true {
            "等待區域網路"
        } else {
            "已停止"
        };
        let desc = format!(
            "description=狀態：{state}｜分享：{}｜位址：{}｜模式：{}",
            s["sharePath"].as_str().unwrap_or(""),
            s["addresses"].as_str().unwrap_or(""),
            s["authLabel"].as_str().unwrap_or("")
        );
        let old = fs::read_to_string(&p)?;
        let new = old
            .lines()
            .map(|l| {
                if l.starts_with("description=") {
                    desc.as_str()
                } else {
                    l
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
            + "\n";
        if new != old {
            config::atomic(&p, new.as_bytes(), 0o644)?
        }
        Ok(())
    }
    fn usermap(&self, c: &Config) -> Result<()> {
        config::atomic(
            &self.rt.join("private/username.map"),
            format!("!root = {}\n", c["SMB_USERNAME"]).as_bytes(),
            0o600,
        )
    }
    fn conf(&self, c: &Config) -> Result<()> {
        let iface = os::interfaces(c, &os::network()?);
        if iface.len() < 2 {
            return Err("沒有可綁定的可信任 LAN".into());
        }
        if c["AUTH_MODE"] == "user" && !self.password() {
            return Err("AUTH_PASSWORD_REQUIRED".into());
        }
        self.usermap(c)?;
        // Android's /sdcard alias may be dangling during early boot even while
        // the backing /data/media/0 directory is already available.
        let effective_share_path = self.effective(c);
        fs::create_dir_all(&effective_share_path)
            .map_err(|e| format!("prepare share path {effective_share_path}: {e}"))?;
        let values: Vec<(&str, String)> = vec![
            ("WORKGROUP", c["WORKGROUP"].clone()),
            ("NETBIOS_NAME", c["NETBIOS_NAME"].clone()),
            ("PORT", c["PORT"].clone()),
            ("iface", iface.join(" ")),
            (
                "bind",
                if c["BIND_INTERFACES"] == "1" || c["AUTO_START"] == "1" {
                    "yes"
                } else {
                    "no"
                }
                .into(),
            ),
            ("effective_min", c["MIN_PROTOCOL"].clone()),
            ("effective_max", c["MAX_PROTOCOL"].clone()),
            ("signing_mode", "auto".into()),
            ("encrypt_mode", "off".into()),
            ("ntlm_mode", "ntlmv2-only".into()),
            ("receivefile_size", "0".into()),
            (
                "PASSDB",
                self.rt.join("private/smbpasswd").display().to_string(),
            ),
            (
                "USERMAP",
                self.rt.join("private/username.map").display().to_string(),
            ),
            ("LOGDIR", self.rt.join("log").display().to_string()),
            ("LOCKDIR", self.rt.join("lock").display().to_string()),
            ("STATEDIR", self.rt.join("state").display().to_string()),
            ("CACHEDIR", self.rt.join("cache").display().to_string()),
            ("PRIVATEDIR", self.rt.join("private").display().to_string()),
            ("PIDDIR", self.rt.join("run").display().to_string()),
            ("RUNTIME", self.rt.display().to_string()),
            ("SHARE_NAME", c["SHARE_NAME"].clone()),
            ("effective_share_path", effective_share_path),
            (
                "readonly",
                if c["READ_ONLY"] == "1" { "yes" } else { "no" }.into(),
            ),
            (
                "writable",
                if c["READ_ONLY"] == "1" { "no" } else { "yes" }.into(),
            ),
        ];
        // Expand template tokens once, never re-interpret dollar signs in user data.
        let template = if c["AUTH_MODE"] == "user" {
            include_str!("user.conf")
        } else {
            include_str!("guest.conf")
        };
        let mut out = String::new();
        let mut chars = template.chars().peekable();
        while let Some(ch) = chars.next() {
            if ch != '$' {
                out.push(ch);
                continue;
            }
            let mut key = String::new();
            while chars
                .peek()
                .is_some_and(|c| c.is_ascii_alphanumeric() || *c == '_')
            {
                key.push(chars.next().unwrap());
            }
            out.push_str(
                &values
                    .iter()
                    .find(|(k, _)| *k == key)
                    .ok_or_else(|| format!("missing template token {key}"))?
                    .1,
            );
        }
        config::atomic(&self.rt.join("smb.conf"), out.as_bytes(), 0o600)?;
        config::atomic(&self.rt.join("auth_mode"), c["AUTH_MODE"].as_bytes(), 0o600)?;
        Ok(())
    }
    fn halt(&self) -> Result<()> {
        let names = [
            "smbd",
            "samba-dcerpcd",
            "rpcd_classic",
            "rpcd_lsad",
            "rpcd_winreg",
        ];
        let ps = os::processes(&names.iter().map(|s| self.bin(s)).collect::<Vec<_>>())?;
        os::terminate(&ps)?;
        self.log("STOP completed");
        Ok(())
    }
    fn start(&self, c: &mut Config) -> Result<()> {
        self.prepare_logs()?;
        use std::os::unix::fs::PermissionsExt;
        for name in [
            "smbd",
            "samba-dcerpcd",
            "rpcd_classic",
            "rpcd_lsad",
            "rpcd_winreg",
        ] {
            let m = fs::metadata(self.bin(name))?;
            if !m.is_file() || m.permissions().mode() & 0o111 == 0 {
                return Err(format!("missing executable server helper: {name}").into());
            }
        }
        if !storage::ready(&c["SHARE_PATH"]) {
            self.halt()?;
            c.insert("ENABLED".into(), "1".into());
            config::save(&self.cfg(), c)?;
            self.card()?;
            return Ok(());
        }
        if self.ready(c)? {
            return Ok(());
        }
        self.halt()?;
        self.conf(c)?;
        let events = os::inotify(&[&self.rt.join("run"), &self.rt.join("log")])?;
        let stdout = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.rt.join("log/smbd.stdout.log"))?;
        let stderr = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.rt.join("log/smbd.stderr.log"))?;
        let result = Command::new(self.bin("smbd"))
            .arg(format!("--log-basename={}", self.rt.join("log").display()))
            .args(["-D", "-s"])
            .arg(self.rt.join("smb.conf"))
            .env("TMPDIR", self.rt.join("tmp"))
            .stdout(stdout)
            .stderr(stderr)
            .status()?;
        if !result.success() {
            self.halt()?;
            return Err(format!("smbd launch failed: {result}").into());
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if self.ready(c)? {
                break;
            }
            if Instant::now() >= deadline {
                self.halt()?;
                return Err("smbd did not own all configured listening sockets".into());
            }
            let mut p = [libc::pollfd {
                fd: events.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            }];
            os::poll(
                &mut p,
                deadline
                    .saturating_duration_since(Instant::now())
                    .as_millis()
                    .max(1) as i32,
            )?;
            os::drain(&events);
        }
        c.insert("ENABLED".into(), "1".into());
        config::save(&self.cfg(), c)?;
        for f in ["waiting_network", "pending_auth_start"] {
            let _ = fs::remove_file(self.rt.join(f));
        }
        config::atomic(
            &self.rt.join("interface_key"),
            os::key(&os::network()?).as_bytes(),
            0o600,
        )?;
        config::atomic(
            &self.rt.join("applied_config.json"),
            serde_json::to_string(c)?.as_bytes(),
            0o600,
        )?;
        self.log("START ready: owned listeners verified");
        Ok(())
    }
    fn stop(&self, c: &mut Config, suspend: bool) -> Result<()> {
        self.halt()?;
        c.insert("ENABLED".into(), if suspend { "1" } else { "0" }.into());
        config::save(&self.cfg(), c)?;
        let _ = fs::remove_file(self.rt.join("interface_key"));
        if suspend {
            config::atomic(&self.rt.join("waiting_network"), b"1", 0o600)?
        } else {
            for f in ["waiting_network", "pending_auth_start"] {
                let _ = fs::remove_file(self.rt.join(f));
            }
        }
        Ok(())
    }
    fn selfcheck(&self) -> Result<()> {
        self.load()
            .map_err(|e| format!("configuration validation failed: {e}"))?;
        let _pid =
            os::fd(unsafe { libc::syscall(libc::SYS_pidfd_open, std::process::id(), 0) as i32 })
                .map_err(|e| {
                    format!("pidfd support is required (kernel/backport + root policy): {e}")
                })?;
        if unsafe {
            libc::syscall(
                libc::SYS_pidfd_send_signal,
                _pid.as_raw_fd(),
                0,
                std::ptr::null::<libc::siginfo_t>(),
                0,
            )
        } < 0
        {
            return Err(format!(
                "pidfd_send_signal unavailable: {}",
                std::io::Error::last_os_error()
            )
            .into());
        }
        let _net = os::netlink().map_err(|e| format!("rtnetlink check failed: {e}"))?;
        let _notify =
            os::inotify(&[&self.data]).map_err(|e| format!("inotify check failed: {e}"))?;
        Ok(())
    }
    fn retire_legacy(&self, module: &Path) -> Result<()> {
        let lock = self.rt.join("network_watch.lock");
        // Upgrade-only compatibility. Shell watcher and its netwatch ELF are no
        // longer shipped; wait on pidfds instead of the old sleep/recheck loop.
        for (record, argument) in [
            ("netwatch_pid", module.join("bin/netwatch")),
            ("pid", module.join("network_watch.sh")),
        ] {
            let pid = fs::read_to_string(lock.join(record))
                .unwrap_or_default()
                .trim()
                .parse::<i32>()
                .unwrap_or(0);
            if pid <= 1 {
                continue;
            }
            let cmd = fs::read(format!("/proc/{pid}/cmdline")).unwrap_or_default();
            if !cmd
                .split(|b| *b == 0)
                .any(|v| v == argument.as_os_str().as_encoded_bytes())
            {
                continue;
            }
            let Ok(exe) = fs::read_link(format!("/proc/{pid}/exe")) else {
                continue;
            };
            let ps: Vec<_> = os::processes(&[exe])?
                .into_iter()
                .filter(|p| {
                    p.pid == pid
                        && fs::read(format!("/proc/{pid}/cmdline")).ok().as_ref() == Some(&cmd)
                })
                .collect();
            os::terminate(&ps)?;
        }
        if lock.exists() {
            fs::remove_dir_all(lock)?;
        }
        Ok(())
    }
    fn wait_boot(&self) -> Result<()> {
        storage::wait_equals("sys.boot_completed", "1", Duration::from_secs(120))
    }
    fn dispatch(&self, cmd: &str, args: &[String]) -> Result<()> {
        match cmd {
            "retire-legacy" => {
                self.retire_legacy(Path::new(args.first().ok_or("missing old module path")?))?
            }
            "status" => println!("{}", self.status()?),
            "status_text" | "diagnose" => {
                println!("{}", serde_json::to_string_pretty(&self.status()?)?)
            }
            "get_config" => {
                let mut c = self.load()?;
                c.insert(
                    "PASSWORD_SET".into(),
                    if self.password() { "1" } else { "0" }.into(),
                );
                println!("{}", serde_json::to_string(&c)?);
            }
            "is_running" => {
                if !self.ready(&self.load()?)? {
                    return Err("SMB not ready".into());
                }
            }
            "interface_key" => println!("{}", os::key(&os::network()?)),
            "trusted_lan" => {
                for (i, a) in os::network()? {
                    println!("{i} {a}")
                }
            }
            "conf" => print!(
                "{}",
                fs::read_to_string(self.rt.join("smb.conf")).unwrap_or_default()
            ),
            "log" => {
                for n in ["module.log", "smbd.log", "log.smbd", "smbd.stderr.log"] {
                    println!("===== {n} =====");
                    let s = fs::read_to_string(self.rt.join("log").join(n)).unwrap_or_default();
                    let lines: Vec<_> = s.lines().collect();
                    for l in lines.iter().skip(lines.len().saturating_sub(250)) {
                        println!("{l}")
                    }
                }
            }
            "watch" => return watch::run(self),
            "watch-stop" => return watch::stop(self),
            "selfcheck" => {
                self.selfcheck()?;
                println!("OK pidfd/rtnetlink/inotify");
            }
            "logs-prepare" => {
                let _lock = self.lock()?;
                self.prepare_logs()?;
                println!("OK boot logs ready");
            }
            "boot" => {
                self.selfcheck()?;
                {
                    let _lock = self.lock()?;
                    self.prepare_logs()?;
                }
                self.wait_boot()?;
                let _lock = self.lock()?;
                let mut c = self.load()?;
                if c["AUTO_START"] == "1" {
                    c.insert("ENABLED".into(), "1".into());
                }
                config::save(&self.cfg(), &c)?;
            }
            "refresh_card" => {
                let _lock = self.lock()?;
                self.card()?
            }
            "start" | "stop" | "restart" | "suspend_network" | "set_config" | "save_restart"
            | "set_password_hex" => {
                let _lock = self.lock()?;
                let mut c = self.load()?;
                match cmd {
                    "start" => self.start(&mut c)?,
                    "stop" => self.stop(&mut c, false)?,
                    "suspend_network" => self.stop(&mut c, true)?,
                    "restart" => {
                        self.halt()?;
                        self.start(&mut c)?;
                    }
                    "set_config" | "save_restart" => {
                        config::update(&mut c, args)?;
                        config::save(&self.cfg(), &c)?;
                        self.usermap(&c)?;
                        if cmd == "save_restart" {
                            if c["AUTH_MODE"] == "user" && !self.password() {
                                self.halt()?;
                                config::atomic(&self.rt.join("pending_auth_start"), b"1", 0o600)?;
                                c.insert("ENABLED".into(), "1".into());
                                config::save(&self.cfg(), &c)?;
                                println!("AUTH_PASSWORD_REQUIRED");
                            } else {
                                self.halt()?;
                                self.start(&mut c)?;
                            }
                        }
                    }
                    "set_password_hex" => {
                        let hex = args.first().ok_or("missing password")?;
                        let hash = password::nt_hash(hex)?;
                        let now = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)?
                            .as_secs();
                        config::atomic(&self.rt.join("private/smbpasswd"),format!("root:0:XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX:{}:[U          ]:LCT-{:08X}:\n",hash.to_uppercase(),now).as_bytes(),0o600)?;
                        self.usermap(&c)?;
                        if c["AUTH_MODE"] == "user"
                            && (self.rt.join("pending_auth_start").exists()
                                || !self.pids()?.is_empty())
                        {
                            self.halt()?;
                            self.start(&mut c)?;
                        }
                    }
                    _ => unreachable!(),
                };
                self.card()?;
                println!("OK");
            }
            _ => return Err(format!("unknown command: {cmd}").into()),
        }
        Ok(())
    }
}
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|s| s == "--version") {
        println!("smbctl {} rust", env!("CARGO_PKG_VERSION"));
        return;
    }
    // Property waiting creates no module state or runtime files.
    let result = if args.first().is_some_and(|s| s == "propwait") {
        (|| -> Result<()> {
            if args.len() != 4 && args.len() != 5 {
                return Err("usage: smbctl propwait equals NAME VALUE [TIMEOUT_MS]".into());
            }
            if args[1] != "equals" {
                return Err("expected equals".into());
            }
            let timeout = args
                .get(4)
                .map(|s| s.parse::<u64>())
                .transpose()?
                .unwrap_or(120_000);
            storage::wait_equals(&args[2], &args[3], Duration::from_millis(timeout))
        })()
    } else {
        App::new().and_then(|a| {
            a.dispatch(
                args.first().map(String::as_str).unwrap_or("status"),
                args.get(1..).unwrap_or(&[]),
            )
        })
    };
    if let Err(e) = result {
        eprintln!("smbctl: {e}");
        std::process::exit(1)
    }
}
