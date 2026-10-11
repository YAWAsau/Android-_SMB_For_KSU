# Rust backend validation

Device: spare Xiaomi 13 / fuxi, Android 17, KernelSU Next. Isolated module and data under `/data/local/tmp/smb-rust-test`, port 1445.

- Ten Android Rust unit tests: literal configuration data, validation, atomic roundtrip/failure preservation, LAN policy, restricted interface masks, owned listening sockets, pidfd process termination, NT hash known answer, malformed UTF-8/hex rejection and nine synthetic legacy-helper vectors.
- Guest SMB upload/download, user/password authentication, incorrect password rejection.
- Concurrent setting updates preserve both changes, singleton watcher, master crash recovery, inotify configuration application, explicit stop stays stopped.
- Watcher CPU ticks unchanged (41 -> 41) over a five-second idle sample; this is not a long-term battery benchmark.
- Isolated network namespace: LAN appearance starts service, duplicate address event does not restart, LAN loss stops service, changed address recovers binding. No physical Wi-Fi changes used.
- Seven status calls with service stopped: old Shell median 2.010389s; Rust median 0.047628s. Timed on device with `/system/bin/time`, excluding ADB transport. This measures management latency, not SMB throughput.
- Clippy warnings denied; JavaScript syntax checked.

Remaining scope: no broad ROM/kernel matrix, long-duration soak, or comparative network-throughput benchmark. API 28 build does not imply pidfd on every Android 9 kernel. Installation gates required kernel capabilities.

Reproduce: `native/test_android.py --serial SERIAL --output result.json` after staging binaries; `native/test_netns.sh` must be run inside a new network namespace on the spare device. Test driver waits may poll to observe completion; product code does not use periodic polling.

Live upgrade from the installed module succeeded through KernelSU Next. Original config.conf remained byte-for-byte identical; port 445 remained ready and old netwatch was removed. The backup tar preserves regular module/data files; live UNIX sockets are not archivable. Cold reboot has not been tested for this SMB candidate.

The independent ntlmhash executable was removed after comparison against nine synthetic legacy vectors (ASCII, Chinese, emoji, combining characters, whitespace and maximum input length). RustCrypto MD4 is used only for the existing NT hash/passdb compatibility. The authentication protocol remains NTLMv2; no Kerberos or NTLM deprecation migration is claimed. Final auth integration runs with both old helper ELFs absent.
