# 📜 BW-ENV Changelog

All notable changes to this project will be documented in this file.

## [1.0.0] - 2026-03-05
### Added
- **Initial Implementation**: Centralized Bitwarden environment management.
- **Shared Session Bridge**: RAM-based `/dev/shm` bridge for cross-process authentication.
- **Memory Hardening**: Best-effort variable wiping (`wipe_var`) and `trap` cleanup.
- **Auto-Lock**: D-Bus listener for system Sleep and screen Lock events.
- **Modular Architecture**: Shared logic moved to `utils.sh`.
- **Identity Protection**: Mandatory check for `AUTHORIZED_USER`.
- **Context-Aware UI**: Support for `read -s` (TTY) and `Zenity` (GUI).
- **Categorized Exit Codes**: Precise error reporting for daemon consumption.
- **English Standard**: Full code and comment translation.

### Changed
- Refactored `main.sh` to follow an "Authentication-First" logical flow.
- Optimized `load.sh` for non-blocking shell initialization.
- Switched from symmetric GPG to Salted-Hash symmetric GPG for better compartmentalization.

### Fixed
- Fixed `bad substitution` error in `load.sh` for Ksh compatibility.
- Fixed redundant Zenity popups when multiple terminals are opened simultaneously.
- Fixed vault synchronization lag by adding mandatory `bw sync` before retrieval.

## [0.1.0] - 2026-03-04
### Added
- Project inception: Concept of using Bitwarden as a central .env store.
- Basic GPG symmetric encryption for local backup.
- Initial systemd user service for background sync.
