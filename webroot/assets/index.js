(function() {
    let It = null, rr = 0;
    const scriptTool = "/data/adb/modules/smbdwebui/control.sh";

    if (typeof ksu < "u" && typeof ksu.exec == "function") { It = ksu; }
    else if (typeof ap < "u" && typeof ap.exec == "function") { It = ap; }

    const I18N={
      "zh-Hant":{detecting:"檢測中...",waitingLan:"等待區域網路",running:"執行中",stopped:"已停止",btnStart:"啟動服務",btnStop:"停止服務",btnRestart:"重啟 SMB 服務",tabStatus:"目前狀態",tabSettings:"基本設定",tabLogs:"查看日誌",tabTools:"維護中心",statusTitle:"SMB 分享狀態",sharePath:"分享路徑",shareName:"分享名稱",address:"連線位址",access:"讀寫權限",protocol:"SMB 協議",interfaces:"綁定介面",authMode:"認證模式",guestMode:"Guest / 匿名",appearanceTitle:"外觀",themeTitle:"主題",themeAuto:"跟隨系統",themeLight:"白色",themeDark:"黑色",themeOled:"OLED 黑",languageTitle:"語言",shareSettings:"分享設定",readOnly:"唯讀分享",readOnlyDesc:"開啟後客戶端只能讀取，不能寫入或刪除。",autoStart:"開機自動啟動",autoStartDesc:"開機後自動啟動 smbd。",protocolInterface:"協議與介面",minProtocol:"最低 SMB 協議",maxProtocol:"最高 SMB 協議",autoInterfaces:"自動加入目前 IPv4",autoInterfacesDesc:"自動偵測 Wi‑Fi / 行動網路 IP 並加入 interfaces。",bindInterfaces:"只綁定指定介面",bindInterfacesDesc:"通常建議開啟；若連線異常可關閉。",extraInterfaces:"額外 interfaces / CIDR",guestWarning:"本版固定 Guest / 匿名模式。帳密登入需要 Samba passdb，不在此版提供。",save:"保存設定",saveRestart:"保存並重啟",logsConf:"日誌 / 設定檔",readLog:"讀取日誌",viewConf:"查看 smb.conf",waiting:"等待操作...",toolsTitle:"維護中心",textStatus:"文字狀態",refreshCard:"刷新模組卡片",forceStop:"強制停止 smbd",cacheHint:"若模組卡片沒有立刻更新，返回模組列表再進入通常會刷新。",readWrite:"可讀寫",readOnlyValue:"唯讀",starting:"正在啟動...",stopping:"正在停止...",restarting:"正在重啟...",saving:"保存配置...",saveRestarting:"保存並重啟...",reading:"讀取中...",cardRefreshed:"模組卡片已刷新",parseStatusFail:"狀態解析失敗：",parseConfigFail:"設定解析失敗：",initFail:"WebUI 初始化失敗：",liveApplyTitle:"即時套用",liveApplyDesc:"所有設定會自動保存；服務執行中時，必要設定會自動重啟套用。",applying:"正在套用...",applied:"設定已套用",appliedRestarted:"設定已套用並重啟服務",applyFailed:"設定套用失敗",authPasswordRequired:"已切換帳號密碼模式，請設定密碼；完成後服務會自動啟動",authSettings:"認證設定",authGuest:"Guest / 匿名",authUser:"使用者名稱 / 密碼",username:"SMB 使用者名稱",usernameHint:"僅限英數字、點、底線與連字號，最長 32 字元。",password:"SMB 密碼",passwordPlaceholder:"輸入新密碼後離開欄位即時套用",passwordSet:"已設定（••••••••）",passwordStatusLabel:"密碼狀態",passwordMaskHint:"已設定時顯示固定遮罩；模組只保存 NT 雜湊，無法讀回原始密碼。",passwordNotSet:"尚未設定密碼",passwordEmpty:"密碼不能為空",passwordApplying:"正在設定密碼...",passwordApplied:"密碼已設定",passwordFailed:"密碼設定失敗",authHint:"帳密模式會停用 Guest，適合其他手機或 Windows 連線；密碼只保存 NT 雜湊，不寫入 config.conf。",protocolHint:"帳密模式建議使用 SMB2_02～SMB3_11；若舊客戶端不相容，可降低最高協議。"},
      "zh-Hans":{detecting:"检测中...",waitingLan:"等待局域网",running:"运行中",stopped:"已停止",btnStart:"启动服务",btnStop:"停止服务",btnRestart:"重启 SMB 服务",tabStatus:"当前状态",tabSettings:"基本设置",tabLogs:"查看日志",tabTools:"维护中心",statusTitle:"SMB 共享状态",sharePath:"共享路径",shareName:"共享名称",address:"连接地址",access:"读写权限",protocol:"SMB 协议",interfaces:"绑定接口",authMode:"认证模式",guestMode:"Guest / 匿名",appearanceTitle:"外观",themeTitle:"主题",themeAuto:"跟随系统",themeLight:"浅色",themeDark:"深色",themeOled:"OLED 黑",languageTitle:"语言",shareSettings:"共享设置",readOnly:"只读共享",readOnlyDesc:"开启后客户端只能读取，不能写入或删除。",autoStart:"开机自动启动",autoStartDesc:"开机后自动启动 smbd。",protocolInterface:"协议与接口",minProtocol:"最低 SMB 协议",maxProtocol:"最高 SMB 协议",autoInterfaces:"自动加入当前 IPv4",autoInterfacesDesc:"自动检测 Wi‑Fi / 移动网络 IP 并加入 interfaces。",bindInterfaces:"只绑定指定接口",bindInterfacesDesc:"通常建议开启；如果连接异常可以关闭。",extraInterfaces:"额外 interfaces / CIDR",guestWarning:"本版固定 Guest / 匿名模式。账号密码登录需要 Samba passdb，本版不提供。",save:"保存设置",saveRestart:"保存并重启",logsConf:"日志 / 配置文件",readLog:"读取日志",viewConf:"查看 smb.conf",waiting:"等待操作...",toolsTitle:"维护中心",textStatus:"文字状态",refreshCard:"刷新模块卡片",forceStop:"强制停止 smbd",cacheHint:"如果模块卡片没有立刻更新，返回模块列表再进入通常会刷新。",readWrite:"可读写",readOnlyValue:"只读",starting:"正在启动...",stopping:"正在停止...",restarting:"正在重启...",saving:"保存配置...",saveRestarting:"保存并重启...",reading:"读取中...",cardRefreshed:"模块卡片已刷新",parseStatusFail:"状态解析失败：",parseConfigFail:"设置解析失败：",initFail:"WebUI 初始化失败：",liveApplyTitle:"即时应用",liveApplyDesc:"所有设置会自动保存；服务运行中时，必要设置会自动重启应用。",applying:"正在应用...",applied:"设置已应用",appliedRestarted:"设置已应用并重启服务",applyFailed:"设置应用失败",authPasswordRequired:"已切换账号密码模式，请设置密码；完成后服务会自动启动",authSettings:"认证设置",authGuest:"Guest / 匿名",authUser:"用户名 / 密码",username:"SMB 用户名",usernameHint:"仅限字母、数字、点、下划线和连字符，最长 32 个字符。",password:"SMB 密码",passwordPlaceholder:"输入新密码后离开输入框立即应用",passwordSet:"已设置（••••••••）",passwordStatusLabel:"密码状态",passwordMaskHint:"已设置时显示固定遮罩；模块只保存 NT 哈希，无法读回原始密码。",passwordNotSet:"尚未设置密码",passwordEmpty:"密码不能为空",passwordApplying:"正在设置密码...",passwordApplied:"密码已设置",passwordFailed:"密码设置失败",authHint:"账号密码模式会停用 Guest，适合其他手机或 Windows 连接；密码只保存 NT 哈希，不写入 config.conf。",protocolHint:"账号密码模式建议使用 SMB2_02～SMB3_11；旧客户端不兼容时可降低最高协议。"},
      "en":{detecting:"Checking...",waitingLan:"Waiting for LAN",running:"Running",stopped:"Stopped",btnStart:"Start service",btnStop:"Stop service",btnRestart:"Restart SMB service",tabStatus:"Status",tabSettings:"Settings",tabLogs:"Logs",tabTools:"Tools",statusTitle:"SMB share status",sharePath:"Share path",shareName:"Share name",address:"Address",access:"Access",protocol:"SMB protocol",interfaces:"Interfaces",authMode:"Auth mode",guestMode:"Guest / Anonymous",appearanceTitle:"Appearance",themeTitle:"Theme",themeAuto:"System",themeLight:"Light",themeDark:"Dark",themeOled:"OLED Black",languageTitle:"Language",shareSettings:"Share settings",readOnly:"Read-only share",readOnlyDesc:"Clients can read only; writing and deletion are disabled.",autoStart:"Start on boot",autoStartDesc:"Start smbd automatically after boot.",protocolInterface:"Protocol and interfaces",minProtocol:"Minimum SMB protocol",maxProtocol:"Maximum SMB protocol",autoInterfaces:"Auto-add current IPv4",autoInterfacesDesc:"Detect Wi‑Fi / mobile IPv4 addresses and add them to interfaces.",bindInterfaces:"Bind only listed interfaces",bindInterfacesDesc:"Usually recommended; disable it if clients cannot connect.",extraInterfaces:"Extra interfaces / CIDR",guestWarning:"This build is fixed to Guest / anonymous mode. Username/password login requires Samba passdb and is not included.",save:"Save settings",saveRestart:"Save and restart",logsConf:"Logs / config",readLog:"Read log",viewConf:"View smb.conf",waiting:"Waiting...",toolsTitle:"Maintenance",textStatus:"Text status",refreshCard:"Refresh module card",forceStop:"Force stop smbd",cacheHint:"If the module card does not update immediately, leave and re-enter the module list.",readWrite:"Read/write",readOnlyValue:"Read-only",starting:"Starting...",stopping:"Stopping...",restarting:"Restarting...",saving:"Saving...",saveRestarting:"Saving and restarting...",reading:"Reading...",cardRefreshed:"Module card refreshed",parseStatusFail:"Status parse failed: ",parseConfigFail:"Config parse failed: ",initFail:"WebUI initialization failed: ",liveApplyTitle:"Live apply",liveApplyDesc:"All settings are saved automatically. When the service is running, settings that require it are applied by an automatic restart.",applying:"Applying...",applied:"Settings applied",appliedRestarted:"Settings applied and service restarted",applyFailed:"Failed to apply settings",authPasswordRequired:"User/password mode selected. Set a password and the service will start automatically",authSettings:"Authentication",authGuest:"Guest / Anonymous",authUser:"Username / Password",username:"SMB username",usernameHint:"Letters, numbers, dot, underscore and hyphen only; maximum 32 characters.",password:"SMB password",passwordPlaceholder:"Enter a new password, then leave the field to apply",passwordSet:"Set (••••••••)",passwordStatusLabel:"Password status",passwordMaskHint:"A fixed mask is shown when set. Only the NT hash is stored, so the original password cannot be recovered.",passwordNotSet:"Password is not set",passwordEmpty:"Password cannot be empty",passwordApplying:"Setting password...",passwordApplied:"Password set",passwordFailed:"Failed to set password",authHint:"Username/password mode disables Guest access and is recommended for other phones or Windows. Only the NT hash is stored; plaintext is not written to config.conf.",protocolHint:"SMB2_02 through SMB3_11 is recommended for password mode. Lower the maximum protocol for older clients."}
    };
    let lang=localStorage.getItem("smbdwebui_lang")||"zh-Hant"; if(!I18N[lang]) lang="zh-Hant"; let lastStatus=null;
    function t(k){return (I18N[lang]&&I18N[lang][k])||I18N["zh-Hant"][k]||k;}
    function applyLang(l){
        if(l && I18N[l]){
            lang=l;
            localStorage.setItem("smbdwebui_lang",lang);
        }
        document.documentElement.lang=(lang==="en"?"en":lang);
        document.querySelectorAll("[data-i18n]").forEach(e=>{
            e.textContent=t(e.dataset.i18n);
        });
        document.querySelectorAll("[data-i18n-placeholder]").forEach(e=>{
            e.setAttribute("placeholder", t(e.dataset.i18nPlaceholder));
        });
        const langSelect=document.getElementById("language-select");
        if(langSelect && langSelect.value!==lang) langSelect.value=lang;
        if(lastStatus) renderStatus(lastStatus);
        else if(elements && elements.statusText) elements.statusText.textContent=t("detecting");
    }

    function exec(cmd) {
        return new Promise((resolve) => {
            if (!It) { resolve({ e: -1, s: "", err: "No WebUI API" }); return; }
            const cb = "_mc" + rr++;
            window[cb] = (code, out, err) => {
                delete window[cb];
                resolve({ e: code || 0, s: (out || "").replace(/\r/g, ""), err: err || "" });
            };
            try { It.exec(cmd, "{}", cb); }
            catch (e) { resolve({ e: -2, s: "", err: String(e) }); }
        });
    }

    const $ = id => document.getElementById(id);
    const elements = {
        statusText: $('status-text'),
        pidBadge: $('pid-badge'),
        version: $('smb-version'),
        logContent: $('log-content'),
        st: {
            sharePath: $('st-share-path'),
            shareName: $('st-share-name'),
            addresses: $('st-addresses'),
            access: $('st-access'),
            protocol: $('st-protocol'),
            interfaces: $('st-interfaces'),
            auth: $('st-auth-mode'),
            usernameRow: $('st-username-row'),
            username: $('st-smb-username'),
            passwordRow: $('st-password-row'),
            password: $('st-password-status')
        },
        fields: {
            AUTO_START: $('conf-AUTO_START'),
            SHARE_PATH: $('conf-SHARE_PATH'),
            SHARE_NAME: $('conf-SHARE_NAME'),
            READ_ONLY: $('conf-READ_ONLY'),
            MIN_PROTOCOL: $('conf-MIN_PROTOCOL'),
            MAX_PROTOCOL: $('conf-MAX_PROTOCOL'),
            BIND_INTERFACES: $('conf-BIND_INTERFACES'),
            INTERFACES_AUTO: $('conf-INTERFACES_AUTO'),
            EXTRA_INTERFACES: $('conf-EXTRA_INTERFACES'),
            PORT: $('conf-PORT'),
            NETBIOS_NAME: $('conf-NETBIOS_NAME'),
            WORKGROUP: $('conf-WORKGROUP'),
            AUTH_MODE: $('conf-AUTH_MODE'),
            SMB_USERNAME: $('conf-SMB_USERNAME')
        }
    };

    function showToast(msg) {
        const t = document.createElement('div');
        t.className = 'toast';
        t.textContent = msg;
        $('toast-container').appendChild(t);
        setTimeout(() => t.remove(), 3000);
    }

    function setTheme(mode) {
        if (!mode || mode === "auto") {
            document.documentElement.removeAttribute("data-theme");
            localStorage.setItem("smbdwebui_theme", "auto");
        } else {
            document.documentElement.setAttribute("data-theme", mode);
            localStorage.setItem("smbdwebui_theme", mode);
        }
        document.querySelectorAll('[data-theme-btn]').forEach(b => {
            b.classList.toggle('btn-primary', b.dataset.themeBtn === (mode || "auto"));
            b.classList.toggle('btn-secondary', b.dataset.themeBtn !== (mode || "auto"));
        });
    }

    setTheme(localStorage.getItem("smbdwebui_theme") || "auto");

    function shQuote(s) {
        s = String(s ?? "");
        return "'" + s.replace(/'/g, "'\\''") + "'";
    }

    function kvArg(k, v) {
        return shQuote(k + "=" + String(v ?? ""));
    }

    function setLog(s) {
        elements.logContent.textContent = s || "";
    }

    function fieldValue(el) {
        return el.type === "checkbox" ? (el.checked ? "1" : "0") : el.value;
    }

    function buildArgs(keys) {
        const args = [];
        const list = keys || Object.keys(elements.fields);
        for (const key of list) {
            const el = elements.fields[key];
            if (!el) continue;
            args.push(kvArg(key, fieldValue(el)));
        }
        return args.join(" ");
    }

    const restartRequiredKeys = new Set([
        "SHARE_PATH", "SHARE_NAME", "READ_ONLY",
        "MIN_PROTOCOL", "MAX_PROTOCOL", "BIND_INTERFACES",
        "INTERFACES_AUTO", "EXTRA_INTERFACES", "PORT",
        "NETBIOS_NAME", "WORKGROUP", "AUTH_MODE", "SMB_USERNAME"
    ]);

    const pendingKeys = new Set();
    const PASSWORD_MASK = "••••••••";
    let passwordConfigured = false;
    let applyTimer = null;
    let applyQueue = Promise.resolve();
    let applyInProgress = false;
    let statusRefreshInProgress = false;

    function setLiveApplyState(message, type) {
        const el = document.getElementById("live-apply-state");
        if (!el) return;
        el.textContent = message || "";
        el.className = "small" + (type ? (" " + type) : "");
    }

    async function applyFieldsNow(keys) {
        if (!keys.length) return;

        const running = !!(lastStatus && lastStatus.running);
        const mustRestart = running && keys.some(key => restartRequiredKeys.has(key));
        applyInProgress = true;
        setLiveApplyState(t("applying"), "warn");

        try {
            const command = `sh ${scriptTool} ${mustRestart ? "save_restart" : "set_config"} ${buildArgs(keys)}`;
            const res = await exec(command);

            if (res.e === 0) {
                if ((res.s || "").includes("AUTH_PASSWORD_REQUIRED")) {
                    setLiveApplyState(t("authPasswordRequired"), "warn");
                    showToast(t("authPasswordRequired"));
                } else {
                    setLiveApplyState(mustRestart ? t("appliedRestarted") : t("applied"), "ok");
                    showToast(mustRestart ? t("appliedRestarted") : t("applied"));
                }
                await refreshAll();
            } else {
                setLiveApplyState(t("applyFailed"), "warn");
                setLog((res.s || "") + (res.err ? ("\nERR:\n" + res.err) : ""));
                await refreshConfig();
            }
        } finally {
            applyInProgress = false;
            if (pendingKeys.size) scheduleFlush(250);
        }
    }

    function flushPendingFields() {
        clearTimeout(applyTimer);
        applyTimer = null;

        if (!pendingKeys.size) return applyQueue;

        const keys = Array.from(pendingKeys);
        pendingKeys.clear();

        applyQueue = applyQueue
            .then(() => applyFieldsNow(keys))
            .catch(err => {
                applyInProgress = false;
                setLiveApplyState(t("applyFailed"), "warn");
                setLog(String(err));
            });

        return applyQueue;
    }

    function scheduleFlush(delay) {
        clearTimeout(applyTimer);
        applyTimer = setTimeout(flushPendingFields, delay);
    }

    function queueFieldApply(key, delay) {
        pendingKeys.add(key);
        scheduleFlush(delay);
    }

    function renderStatus(j) {
        lastStatus=j;
        const isRunning = !!j.running;
        const waitingLan = !!j.waitingNetwork;
        document.body.className = isRunning ? "running" : "stopped";
        elements.statusText.textContent = isRunning ? t("running") : (waitingLan ? t("waitingLan") : t("stopped"));
        if (isRunning && j.pid) {
            elements.pidBadge.textContent = "PID: " + j.pid;
            elements.pidBadge.classList.remove('hidden');
        } else {
            elements.pidBadge.classList.add('hidden');
        }
        elements.version.textContent = j.version || "...";
        elements.st.sharePath.textContent = j.sharePath || "-";
        elements.st.shareName.textContent = j.shareName || "-";
        elements.st.addresses.textContent = (j.addresses || "").split(/\s+/).filter(Boolean).join("\n") || "-";
        elements.st.access.textContent = j.readOnly === "1" ? t("readOnlyValue") : t("readWrite");
        elements.st.protocol.textContent = (j.minProtocol || "-") + " ~ " + (j.maxProtocol || "-") + " / port " + (j.port || "445");
        elements.st.interfaces.textContent = j.interfaces || "-";
        const userMode = j.authMode === "user";
        elements.st.auth.textContent = userMode ? t("authUser") : t("authGuest");
        if (elements.st.usernameRow) elements.st.usernameRow.style.display = userMode ? "" : "none";
        if (elements.st.passwordRow) elements.st.passwordRow.style.display = userMode ? "" : "none";
        if (elements.st.username) elements.st.username.textContent = userMode ? (j.smbUsername || "-") : "-";
        if (elements.st.password) {
            elements.st.password.textContent = userMode
                ? (j.passwordSet ? t("passwordSet") : t("passwordNotSet"))
                : "-";
            elements.st.password.className = j.passwordSet ? "ok" : "warn";
        }
    }

    async function refreshStatus() {
        const res = await exec(`sh ${scriptTool} status`);
        let j = {};
        try { j = JSON.parse(res.s || "{}"); }
        catch (e) { setLog(t("parseStatusFail") + "\n" + res.s + "\n" + (res.err || "")); return; }
        renderStatus(j);
    }

    async function refreshConfig() {
        const res = await exec(`sh ${scriptTool} get_config`);
        let conf = {};
        try { conf = JSON.parse(res.s || "{}"); }
        catch (e) { setLog(t("parseConfigFail") + "\n" + res.s + "\n" + (res.err || "")); return; }

        for (let k in elements.fields) {
            const el = elements.fields[k];
            if (!el) continue;
            if (el.type === "checkbox") el.checked = conf[k] === "1";
            else el.value = conf[k] || "";
        }
        passwordConfigured = conf.PASSWORD_SET === "1";
        const passwordStatus = $('password-status');
        const passwordInput = $('auth-password');
        if (passwordStatus) {
            passwordStatus.textContent = passwordConfigured ? t("passwordSet") : t("passwordNotSet");
            passwordStatus.className = "small " + (passwordConfigured ? "ok" : "warn");
        }
        if (passwordInput && document.activeElement !== passwordInput) {
            if (passwordConfigured) {
                passwordInput.value = PASSWORD_MASK;
                passwordInput.dataset.masked = "1";
            } else {
                passwordInput.value = "";
                passwordInput.dataset.masked = "0";
            }
        }
    }

    async function refreshAll() {
        await refreshStatus();
        await refreshConfig();
    }

    function utf8Hex(value) {
        const bytes = typeof TextEncoder !== "undefined"
            ? new TextEncoder().encode(value)
            : Uint8Array.from(unescape(encodeURIComponent(value)), c => c.charCodeAt(0));
        return Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("");
    }

    function restorePasswordMask() {
        const input = $('auth-password');
        if (!input) return;
        if (passwordConfigured) {
            input.value = PASSWORD_MASK;
            input.dataset.masked = "1";
        } else {
            input.value = "";
            input.dataset.masked = "0";
        }
    }

    async function applyPassword() {
        const input = $('auth-password');
        if (!input) return;
        const value = input.value;
        if (input.dataset.masked === "1" || value === PASSWORD_MASK) return;
        if (!value) {
            if (passwordConfigured) {
                restorePasswordMask();
                return;
            }
            setLiveApplyState(t("passwordEmpty"), "warn");
            return;
        }
        setLiveApplyState(t("passwordApplying"), "warn");
        await flushPendingFields();
        await applyQueue;
        const res = await exec(`sh ${scriptTool} set_password_hex ${utf8Hex(value)}`);
        if (res.e === 0) {
            passwordConfigured = true;
            restorePasswordMask();
            setLiveApplyState(t("passwordApplied"), "ok");
            showToast(t("passwordApplied"));
            await refreshAll();
        } else {
            setLiveApplyState(t("passwordFailed"), "warn");
            setLog((res.s || "") + (res.err ? ("\nERR:\n" + res.err) : ""));
        }
    }

    async function action(cmd, toast) {
        showToast(toast);
        const res = await exec(`sh ${scriptTool} ${cmd}`);
        if (res.s || res.err) setLog((res.s || "") + (res.err ? ("\nERR:\n" + res.err) : ""));
        await refreshAll();
    }


    $('btn-start').onclick = () => action("start", t("starting"));
    $('btn-stop').onclick = () => action("stop", t("stopping"));
    $('btn-restart').onclick = () => action("restart", t("restarting"));
    $('btn-log').onclick = async () => {
        setLog(t("reading"));
        const res = await exec(`sh ${scriptTool} log`);
        setLog((res.s || "") + (res.err ? ("\nERR:\n" + res.err) : ""));
    };
    $('btn-conf').onclick = async () => {
        setLog(t("reading"));
        const res = await exec(`sh ${scriptTool} conf`);
        setLog((res.s || "") + (res.err ? ("\nERR:\n" + res.err) : ""));
    };
    $('btn-status-text').onclick = async () => {
        const res = await exec(`sh ${scriptTool} status_text`);
        setLog((res.s || "") + (res.err ? ("\nERR:\n" + res.err) : ""));
    };
    $('btn-refresh-card').onclick = async () => {
        await exec(`sh ${scriptTool} refresh_card`);
        showToast(t("cardRefreshed"));
    };
    $('btn-force-stop').onclick = () => action("stop", t("stopping"));

    document.querySelectorAll('[data-tab]').forEach(b => {
        b.onclick = () => {
            document.querySelectorAll('.tab-btn, .tab-content').forEach(el => el.classList.remove('active'));
            b.classList.add('active');
            $('tab-' + b.dataset.tab).classList.add('active');
            if (b.dataset.tab === 'logs') $('btn-log').click();
        };
    });

    document.querySelectorAll('[data-theme-btn]').forEach(b => {
        b.onclick = () => setTheme(b.dataset.themeBtn);
    });

    Object.keys(elements.fields).forEach(key => {
        const el = elements.fields[key];
        if (!el) return;

        if (el.type === "checkbox" || el.tagName === "SELECT") {
            // Android 11 WebView 上連續 WebUI exec 容易卡；合併切換後再套用。
            el.addEventListener("change", () => queueFieldApply(key, 500));
        } else {
            // 文字欄位不在每次輸入時保存/重啟，避免輸入路徑/名稱時反覆 fork shell 與重啟 smbd。
            el.addEventListener("change", () => queueFieldApply(key, 300));
            el.addEventListener("keydown", event => {
                if (event.key === "Enter") {
                    event.preventDefault();
                    queueFieldApply(key, 0);
                    el.blur();
                }
            });
        }
    });

    const passwordInput=$('auth-password');
    if(passwordInput){
        passwordInput.addEventListener("focus", () => {
            if (passwordInput.dataset.masked === "1") {
                passwordInput.value = "";
                passwordInput.dataset.masked = "0";
            }
        });
        passwordInput.addEventListener("blur", () => {
            if (passwordInput.value) applyPassword();
            else restorePasswordMask();
        });
        passwordInput.addEventListener("keydown", event => {
            if(event.key === "Enter"){
                event.preventDefault();
                if (passwordInput.value) applyPassword();
                else restorePasswordMask();
                passwordInput.blur();
            }
            if(event.key === "Escape"){
                event.preventDefault();
                restorePasswordMask();
                passwordInput.blur();
            }
        });
    }

    const languageSelect=$('language-select');
    if(languageSelect){
        languageSelect.value=lang;
        languageSelect.onchange=()=>{
            applyLang(languageSelect.value);
            showToast(languageSelect.options[languageSelect.selectedIndex].text);
        };
    }

    applyLang(lang);
    refreshAll().catch(e => setLog(t("initFail") + "\n" + e));
    setInterval(() => {
        if (document.visibilityState === "hidden") return;
        if (!applyInProgress && pendingKeys.size === 0) refreshStatus();
    }, 12000);
})();
