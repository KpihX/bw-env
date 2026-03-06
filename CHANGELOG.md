# 📜 BW-ENV: Engineering Changelog & Evolution

This document chronicles the development of `bw-env`, a journey from a simple script to a production-grade, zero-trust infrastructure. It highlights the failures, regressions, and breakthroughs that shaped the final architecture.

## [v1.0.0] - 2026-03-06 (The "Swiss Watch" Release)
### 🚀 Final Breakthroughs
- **Directive-Sequential Flow**: Finalized the separation of powers. `main.sh` is now a pure executor, and `sync-daemon.sh` is the sole orchestrator.
- **Stabilization Delays**: Implemented `WAKE_DEBOUNCE_DELAY` and `GRAPHICAL_WAIT_DELAY` to solve the "Zenity at Wake-up" race condition.
- **Zero-Hardcoding**: Centralized all delays and paths in `.env`.
- **Indestructible Loop**: Hardened the daemon's main loop with `wait $! || true` and removed fragile subshell pipes.

## [v0.9.0] - 2026-03-05 (The "Signal War" Phase)
### ⚠️ Regressions & Lessons
- **The Signal Loop Bug**: Discovered that `main.sh` was signaling the daemon even when called by the daemon, causing infinite recursion.
- **The Zenity Spam**: Identified that rapid D-Bus signals at wake-up caused multiple Zenity prompts.
- **The Invisible Daemon**: Fixed a bug where the daemon wrote an empty PID file, making it invisible to the `status` command.
### ✨ Progress
- **Smart Notification**: Implemented state-aware signaling (`notify_daemon`) to prevent redundant notifications.
- **Post-Release Notification**: Moved daemon signaling after the lock release to prevent process conflicts.

## [v0.8.0] - 2026-03-04 (The "Reactive" Foundation)
### 🚀 Breakthroughs
- **Global Revocation**: Implemented the Pub-Sub model using `SIGUSR2` to wipe secrets from all active shells instantly.
- **D-Bus Integration**: Added the system monitor to detect Sleep/Wake and Screen Lock events.
- **Shared RAM Bridges**: Established the `/dev/shm` bridges for Bitwarden sessions and GPG keys.

## [v0.5.0] - 2026-03-03 (The "Security" Hardening)
### ✨ Progress
- **PBKDF2 100k**: Implemented high-entropy key derivation for local backups.
- **Atomic Swap**: Introduced the `mv` pattern for RAM cache updates to prevent partial reads.
- **Surgical Wiping**: Added zero-overwriting for sensitive variables in RAM.

## [v0.1.0] - 2026-03-02 (The "Genesis")
### 🐣 Initial Concept
- Basic script to fetch Bitwarden custom fields and export them as environment variables.
- Initial realization that a background daemon was necessary for a seamless developer experience.

---
*Every failure was a lesson, every regression a step toward a more robust system.*
