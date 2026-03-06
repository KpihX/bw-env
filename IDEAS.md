# 💡 BW-ENV: Future Ideas & Roadmap

This document serves as a strategic backlog for the `bw-env` project. It captures architectural enhancements and feature ideas to push the system toward v2.0.

## 🏗️ Architectural Enhancements

- [ ] **Multi-Item Aggregation**: Support fetching secrets from multiple Bitwarden items (e.g., `GLOBAL_VARS` + `PROJECT_A_VARS`) and merging them into the RAM cache.
- [ ] **Dynamic Project Scoping**: Integrate with `direnv` or a custom hook to automatically load project-specific secrets when entering a directory.
- [ ] **Encrypted Audit Trail**: Periodically export `journalctl` logs related to `bw-env` into a GPG-encrypted file for long-term, tamper-proof auditing.
- [ ] **Hardware Token Integration**: Support YubiKey or other FIDO2 tokens as a second factor for the initial `unlock` sequence.

## 🤖 Daemon & Intelligence

- [ ] **Predictive Sync**: Adjust `CHECK_INTERVAL` dynamically based on system activity or network stability.
- [ ] **Advanced D-Bus Triggers**: React to specific network changes (e.g., locking secrets when leaving a "Trusted WiFi" zone).
- [ ] **Self-Healing Bridge**: Automatically detect and repair corrupted RAM bridge files without requiring a full `restart`.

## 🖥️ User Experience (UX)

- [ ] **System Tray Interface**: A lightweight Python/GTK tray icon to visualize the daemon state (`ACTIVE`/`PAUSED`) and trigger manual locks/unlocks.
- [ ] **Interactive Status Dashboard**: A `Rich`-based terminal dashboard for `bw-env status` with real-time updates.
- [ ] **Zsh/Bash Completion**: Full tab-completion for all `bw-env` commands and options.

## 🛡️ Security Hardening

- [ ] **Memory Pressure Monitoring**: Automatically purge secrets if the system is under heavy swap usage to prevent secrets from being written to the swap partition.
- [ ] **Process Whitelisting**: Restrict access to the `/dev/shm` bridge files to a specific list of authorized PIDs or groups.
- [ ] **Kernel-Level Wiping**: Explore `memfd_create` or other Linux-specific primitives for even more secure volatile storage.

---
*Ideas are the seeds of future resilience.*
