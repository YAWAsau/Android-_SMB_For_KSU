# SMB notification sender

Adapted from YAWAsau Mount `dex_notify/app/src/main/java/com/xayah/dex/NotificationUtil.java` (v1.4.69-yawasau-oneshot-notify-result-preserve-parsed), as included in the local Mount_plus source. Retains its one-shot system-context, BigText/auto-cancel/only-alert-once notification and white Canvas bitmap small-icon approach. SMB only needs root event notifications; mount progress, socket daemon, action and state-file machinery is not included.

Reference source SHA256: 65549cc70bbf1e1f63516779a4b151ff4a44039d3044eac0d7422764650efcec.

The package-UID channel registration follows the newer backup script's `NotificationUtil.sendNotifyEvent`; Android's system context belongs to android/1000 even when launched by root/0. SMB uses its own channel/tag/id and folder/network icon, avoiding collisions with Mount notifications.

Missing service, shutdown in progress, and Binder death yield `SMB_NOTIFY_SKIPPED`; unexpected exceptions retain stderr and a nonzero status. No sleep, retry, or polling. Failure-race tests inject a Backend in NotifyTest without stopping real Android services.

Build: `./build.ps1` with Android SDK platform 36/build-tools 36.0.0 and javac. Runtime minimum API 28. Production Dex is built separately from tests. All source required to rebuild this notification Dex is included.
