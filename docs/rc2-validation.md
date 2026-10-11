# RC2 validation — 2026-10-11

Samba 4.25.0 rebuilt locally with NDK r30 / API 28, size profile and ThinLTO. Four optional TDB mutex request sites now check runtime support. Existing file locking and failure diagnostics remain intact. Five server/RPC binaries changed; smbd SHA256 ea50423427665599605423e2bf545786d376f35bf30cbaede42cea9454813e8c.

Spare Xiaomi 13, Android 17: isolated port 1445 guest upload/download, password login, wrong-password rejection, config data/atomicity, concurrent updates, watcher singleton, master crash recovery and config events passed. Idle watcher CPU ticks stayed 34 -> 34 over five seconds. The measurement waits for event notification completion; notification work is not idle. Fresh test logs contained no `mutexes requested` diagnostic.

Notification injected tests passed for missing service, disappearance between check/send, Binder death and preservation of unexpected errors. Real system notification receipt verified via dumpsys. Tests never stop Android's real notification service. White transparent icon rendered on Android and inspected. A real shutdown race, cold reboot and long-duration/throughput benchmarks are not covered.

Notification adaptation/provenance/build details: native/notify/README.md. API 28 minimum; root app_process system-context sender. Source included; propwait remains an existing helper without its exact source.
