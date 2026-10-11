# 2026-10-11 multicall validation

Primary CPH2747, Android 17. Isolated test data; no reboot requested.

- SMB: 15 Android unit tests, property creation/update/immediate match/deadline/argument checks passed.
- SMB integration: writable fixture explicitly sets READ_ONLY=0 (previous fixture retained read-only configuration). Guest round-trip, user authentication/rejection, singleton, crash recovery, config events, stop persistence passed. Five-second idle CPU ticks unchanged.
- Mount: four Android tests including private mount namespace transactions, rollback, source identity, foreign mount protection, and real bindfs through Rust symlink helper passed.
- Mount event tests: singleton, config content dedup, source recreation and ignored content writes passed. 30-second CPU runtime unchanged for both threads.
- New physical layout cold boot remains pending.
