# 📜 BW-ENV: Engineering Changelog & Evolution

This document chronicles the development of `bw-env`, a journey from a simple script to a production-grade, zero-trust infrastructure. It highlights the failures, regressions, and breakthroughs that shaped the final architecture.

## [v1.2.0] - 2026-03-20 (The "Control Surface" Release)
### 🚀 Additions
- **GUI-Ready Status API**: Added `bw-env status --json` as the structured state surface for the future tray/control-center.
- **Config Control Surface**: Added `bw-env config list`, `bw-env config list --json`, `bw-env config get KEY`, and `bw-env config set KEY VALUE`.
- **Shell Bootstrap Bundle**: Added `profile.sh` so `~/.kshrc` can source a single reusable bootstrap entrypoint.
- **First Control Center**: Added a native GTK dark-themed control center and an AppIndicator tray integration with direct actions.
- **Activity Surface**: Added an `Activity` tab to the GTK control center, backed directly by `bw-env logs` with adjustable line count and live refresh.
- **Tray Lifecycle Command**: Added `bw-env tray install` to deploy and activate the user service automatically when possible.
### 🛠️ Operational Refinements
- **Boot / Wake Policy Flags**: Added `AUTO_START_ON_BOOT` and `AUTO_START_ON_WAKE` to decouple daemon activation policy from the service lifecycle.
- **Subscriber Audit Split**: `status` now distinguishes interactive shells from non-interactive processes with clearer indentation and process detail.
- **Tray Service Template**: Added `gui/bw-env-tray.service` for user-session startup.

## [v1.1.1] - 2026-03-06 (The "Data Freshness" Release)
### 🚀 Refinements
- **Restored Server Sync**: Re-integrated `bw sync` into the authentication loop. This ensures that the `sync` command always fetches the latest data from the cloud while serving as a non-interactive session validator.
- **Optimized Funnel**: Refined the "Quality Funnel" to perform a single server sync followed by a local item retrieval, maximizing both speed and data integrity.
- **Cleanup & Standardisation**: Removed all temporary analysis files and standardized internal variable scopes for absolute memory safety.

## [v1.1.0] - 2026-03-06 (The "Performance & Resilience" Release)
### 🚀 Breakthroughs & Fixes
- **Inter-Process Resilience**: Implemented a "Quality Funnel" in `unlock_unified` to detect and self-heal from session invalidations caused by other Bitwarden-related processes.
- **Performance Optimization**: Eliminated redundant `bw sync` calls and merged validation with data retrieval, saving 5-8 seconds per cycle.
- **Zsh Compatibility**: Fixed a critical regression where the `EXIT` trap in `load.sh` was local to the `bw-env` function, causing immediate unregistration of the shell. Switched to `zshexit_functions` for Zsh.
- **GPG Robustness**: Fixed an invalid `--pbkdf2-iter` flag in GPG and added explicit error capturing for disk backups.
- **Memory Safety**: Standardized variable casing and ensured sensitive variables (`ITEM_JSON`, `SESSION_KEY`) are global to be accessible by the `cleanup_secrets` trap.
- **Path Independence**: Hardened `load_config` to use absolute project paths, preventing failures when called from different working directories.

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
