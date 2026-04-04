# 🔐 BW-ENV: Production-Grade Zero-Trust Environment Manager

**BW-ENV** is a high-security utility designed to manage sensitive environment variables using **Bitwarden (Vaultwarden)** as the source of truth. It implements a **Zero-Trust** architecture where secrets reside exclusively in RAM and are protected by atomic locking and reactive global revocation.

---

## 📁 Project Standards Snapshot

This repository follows the KπX `.agents/` standard for agent context.

### Core Project Documents
- `README.md`: architecture, setup, operations.
- `CHANGELOG.md`: released and historical changes.
- `TODO.md`: pending backlog only (open work), intentionally separated from delivered work.
- `.agents/AGENTS.md`: project-level agent context (git-ignored). Root `AGENTS.md` is a symlink to it.

---

## 🏗️ 1. Directive-Sequential Architecture

The system is built on a strict separation of powers to ensure 100% reliability and predictability:

1.  **`main.sh` (The Pure Executor):** Handles the heavy lifting (Bitwarden API, GPG encryption, RAM deployment). It is **idempotent** and only notifies the daemon during manual operations to prevent signal loops.
2.  **`sync-daemon.sh` (The Authoritative Orchestrator):** Manages the system lifecycle. It listens for D-Bus signals (Sleep/Wake, Lock/Unlock) and coordinates state transitions (`ACTIVE` <-> `PAUSED`).
3.  **`utils.sh` (The Security Plumbing):** Provides atomic locking (`flock`), high-entropy key derivation (PBKDF2 100k), and surgical memory wiping.

---

## 🏛️ 2. Zero-Trust Architecture & Security Mandates

The system is built on the principle that **nothing is trusted by default**, and secrets must never touch the physical disk in plain text.

### 🛡️ Cryptographic Hardening
- **PBKDF2 Derivation**: Local backups are protected by GPG symmetric encryption using **PBKDF2 with 100,000 iterations** (HMAC-SHA256). This makes offline brute-force attacks computationally infeasible.
- **Salted Security**: An `INTERNAL_SALT` is used to ensure that the derived keys are unique to this tool, preventing cross-tool key leakage.

### 🧠 Volatile Memory Management (RAM-Only)
- **Shared RAM Bridges**: Once unlocked, session keys reside exclusively in `/dev/shm` (Shared Memory) with `600` permissions. This allows multiple processes (terminals, daemons) to share authentication without re-prompting.
- **Zero-Disk Plaintext**: Secrets are never written to the hard drive. They transit from Bitwarden directly to RAM.
- **Surgical Wiping**: All sensitive variables (`MASTER_PASS`, `GPG_KEY`) are overwritten with zeros in RAM before being unset, preventing memory remanence.

### ⚛️ Atomic Operations
- **Atomic Swap Pattern**: RAM cache updates use the `mv` operation. This ensures that shell readers never source a partially written file, guaranteeing data integrity during concurrent access.

---

## 🚀 2. Installation & Setup Guide

### 1. Binary Installation
Create a global wrapper to access `bw-env` from any script or terminal:

```bash
# Create the binary wrapper
cat <<EOF > ~/.local/bin/bw-env
#!/bin/bash
exec bash \$HOME/Work/sh/bw-env/main.sh "\$@"
EOF

# Make it executable
chmod +x ~/.local/bin/bw-env
```

### 2. Shell Integration
`bw-env` now ships a dedicated shell bootstrap bundle:

- `shell.sh`: the `bw-env` shell wrapper plus shell-side commands (`get`, `drop`)
- `load.sh`: non-blocking RAM injection and local revocation hooks
- `profile.sh`: reusable top-of-shell snippet for `~/.kshrc`

Recommended integration:

```bash
[ -f "$HOME/Work/sh/bw-env/profile.sh" ] && source "$HOME/Work/sh/bw-env/profile.sh"
```

### 3. Configuration (`.env`)
The system is 100% flexible. All user-facing runtime settings are centralized in `~/Work/sh/bw-env/.env`. A template is provided in `.env.example`.

The recommended read/write interface is now the CLI itself:

```bash
bw-env config list
bw-env config list --json
bw-env config get CHECK_INTERVAL
bw-env config set CHECK_INTERVAL 120
```

Relevant GUI-facing settings include:

- `ITEM_ID`
- `CHECK_INTERVAL`
- `MAX_AUTH_ATTEMPTS`
- `WAKE_DEBOUNCE_DELAY`
- `GRAPHICAL_WAIT_DELAY`
- `GRAPHICAL_WAIT_MAX`
- `AUTO_START_ON_BOOT`
- `AUTO_START_ON_WAKE`
- `LOCK_TIMEOUT`
- `LOAD_WAIT_MAX`
- `LOAD_WAIT_STEP`

### 4. Background Sync & Auto-Lock (Systemd)
Install the user service for proactive security:

1.  **Create unit file**: `~/.config/systemd/user/bw-env-sync.service`
2.  **Configuration**:
    ```ini
    [Service]
    ExecStart=/bin/bash %h/Work/sh/bw-env/sync-daemon.sh
    Restart=on-failure
    ```
3.  **Enable**: `systemctl --user enable --now bw-env-sync.service`

### 5. Tray & Control Center
BW-ENV now includes:

- `bw-env gui`: opens the graphical control center
- `bw-env tray start`: starts the persistent tray icon
- `bw-env tray open`: opens the control center from CLI
- `bw-env tray install`: installs and enables the user service automatically

The tray is intentionally thin:

- the icon color reflects the current state
- the AppIndicator menu exposes direct actions (`unlock`, `sync`, `lock`, `pause`, `resume`, `start`, `stop`, `restart`)
- the control center exposes the full status, subscriber lists, relevant settings, and a live Activity tab backed by `bw-env logs`

Required graphical stack:

- `python3-gi`
- `gir1.2-gtk-3.0`
- `gir1.2-ayatanaappindicator3-0.1`
- `/usr/bin/python3` with `gi` available for both the tray and the control-center window

The shipped user-service template is:

- `gui/bw-env-tray.service`

Typical installation:

```bash
mkdir -p ~/.config/systemd/user
cp ~/Work/sh/bw-env/gui/bw-env-tray.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now bw-env-tray.service
```

---

## 🤖 3. Reactive Intelligence & Collective Security

BW-ENV is not just a script; it's a reactive ecosystem where every component communicates in real-time.

### 📡 Global Revocation (Pub-Sub Model)
- **Split Subscriber Registries**: Interactive shells and non-interactive processes are tracked separately.
- **Signal Broadcast**: Upon a `lock` or `purge`, the system broadcasts a **`SIGUSR2`** signal to all registered shells.
- **Instant Purge**: Each shell reacts to the signal by immediately unsetting all secrets from its memory, ensuring a system-wide security wipe in milliseconds.

### 🛡️ Proactive Auto-Lockdown
- **D-Bus Integration**: A supervised monitor listens for system-wide signals (`PrepareForSleep`, `LockedHint`).
- **Reactive Purge**: Secrets are instantly wiped from RAM when you close your laptop or lock your screen.

### 💤 Smart Daemon (Gentleman Mode)
- **Interruptible Sleep**: The daemon uses an interruptible `wait` loop, allowing it to react instantly to **`SIGUSR1`** (Resume) or **`SIGUSR2`** (Pause) signals.
- **Auto-Healing**: The CLI automatically detects if the daemon is stopped and restarts it upon a successful manual unlock.
- **Boot / Wake Policy**: `AUTO_START_ON_BOOT` and `AUTO_START_ON_WAKE` control whether the daemon auto-activates after startup or wake. When disabled, the daemon stays in `PAUSED` instead of opening a prompt.

---

## ⚙️ 4. Operational Excellence & Flexibility

### 🧩 Configuration (`.env`)
The system is 100% flexible. Key parameters include:
- `WAKE_DEBOUNCE_DELAY`: Time to wait after a wake signal before acting.
- `GRAPHICAL_WAIT_DELAY`: Safety buffer for Zenity display.
- `CHECK_INTERVAL`: Background sync frequency.
- `AUTO_START_ON_BOOT`: Whether the daemon performs an initial sync at startup.
- `AUTO_START_ON_WAKE`: Whether the daemon auto-resumes after wake events.

### 🚦 Concurrency & Transparency
- **Atomic Locking**: Uses `flock` with **PID transparency**. You can always see exactly which process holds the lock via `bw-env status`.
- **Post-Release Notification**: To prevent race conditions, the daemon is notified **after** the lock is released, ensuring a smooth transition.

---

## 🛠️ 5. Usage & Command Center

| Command | Category | Description |
| :--- | :--- | :--- |
| `bw-env unlock` | **Primary** | Prompts for password, syncs vault, and establishes RAM bridges. |
| `bw-env sync` | **Refresh** | Force-synchronizes local data. Uses bridges for silent background updates. |
| `bw-env status` | **Audit** | Full visibility: Daemon state, RAM/Disk caches, Bridges, and active subscribers. |
| `bw-env status --json` | **Audit / API** | Structured machine-readable status for GUIs and local integrations. |
| `bw-env config list` | **Settings** | Lists the relevant user-facing configuration surface. |
| `bw-env config set KEY VALUE` | **Settings** | Updates one relevant runtime setting inside `.env`. |
| `bw-env gui` | **GUI** | Opens the native GTK control center (Overview / Subscribers / Settings / Activity) with per-subscriber unsubscribe actions. |
| `bw-env tray start` | **GUI / Tray** | Starts the persistent AppIndicator tray with direct menu actions. |
| `bw-env tray open` | **GUI / Tray** | Opens the control center directly. |
| `bw-env tray install` | **GUI / Tray** | Installs the tray user service and enables it automatically when the user systemd bus is reachable. |
| `bw-env unsubscribe <pid>` | **Admin / Subscribers** | Removes one PID from the revocation registries without stopping the process. |
| `bw-env lock` | **Security** | Purges RAM, closes bridges, and triggers **Global Revocation**. |
| `bw-env purge` | **Nuclear** | **Total Destruction**: Stops daemon, wipes RAM/Disk, and revokes all shells. |
| `bw-env decrypt`| **Offline** | Restores environment from encrypted disk cache (No network required). |
| `bw-env logs` | **Journal** | Quick access to the last X system journal entries (`-n X`). |
| `bw-env restart`| **Control** | Restarts the background synchronization service. |
| `bw-env pause`  | **Control** | Puts the daemon into silent sleep mode (D-Bus remains active). |
| `bw-env resume` | **Control** | Wakes up the daemon and triggers an immediate sync cycle. |

---

## 🚦 6. Standardized Exit Codes

| Code | Label | Meaning |
| :--- | :--- | :--- |
| **0** | **SUCCESS** | Operation completed successfully. |
| **2** | **CANCEL** | User intentionally skipped or closed the prompt. |
| **3** | **AUTH** | Bitwarden Master Password verification failed. |
| **5** | **CRYPTO** | GPG or PBKDF2 key derivation failure. |
| **6** | **MAX_TRY** | Maximum authentication attempts reached (prevents spam). |

---

## 🩺 6. Diagnostics & Debugging

BW-ENV uses **Journald** for maximum transparency.

### Monitoring Logs
- **Integrated Command**: `bw-env logs -n 50` (Fastest way).
- **Daemon Follow**: `journalctl -f --user-unit bw-env-sync.service`.
- **Global Audit**: `journalctl -t bw-env -t bw-env-daemon -n 100`.

### Service & Sync Health
- **Systemd Status**: `systemctl --user status bw-env-sync.service`.
- **Tray Status**: `ps -fp "$(cat /dev/shm/bw-env-tray-$USER.pid 2>/dev/null)"`.
- **Bitwarden CLI Status**: `bw status`.
- **Trace Execution**: `bash -x ~/Work/sh/bw-env/main.sh [command]`.

### 🔴 Recovery Runbook

#### "Authentication failed: Incorrect Master Password" (but password is correct)

The `bw` CLI maintains its own session separately from the Bitwarden desktop app.
If the bw CLI session is lost (restart, RAM wipe, first install), re-authenticate:

```bash
# 1. Point the CLI to your self-hosted Vaultwarden (only needed once)
bw config server https://your-vaultwarden-url

# 2. Log in with your Bitwarden credentials
bw login

# 3. Unlock bw-env as normal
bw-env unlock
```

> **Why this happens:** `bw-env unlock` calls `bw unlock --raw`, which requires
> the bw CLI to already have a logged-in user with local vault data cached.
> The desktop app and the CLI are independent processes with separate sessions.

#### Cold-start recovery (offline / no live Bitwarden connection)

If you have an encrypted local backup (`~/.bw/env/cache.env.gpg`) and the vault
is temporarily unreachable, restore secrets from the local cache without a network:

```bash
bw-env decrypt
```

This re-derives the GPG key from your master password and restores `TEMP_ENV`
into RAM. Note: the daemon will stay in PAUSED state until a live `bw login` + `bw-env unlock` is done.

#### Tray icon stuck red after session recovery

The tray polls every 30s. A stuck red state after a bw-env recovery is resolved by restarting:

```bash
bw-env tray restart
# or
systemctl --user restart bw-env-tray.service
```

---

## 🛡️ 7. Security Implementation Details

### 1. Memory Safety
- **Wiping**: All sensitive variables (`MASTER_PASS`, `GPG_KEY`) are overwritten with zeros in RAM before being unset.
- **Trap**: A `trap cleanup_secrets EXIT` ensures that memory is wiped even if the script crashes.

### 2. Injection Protection
- **Sanitization**: Environment variable names are sanitized via `jq` using regex: `gsub("[^a-zA-Z0-9_]"; "_")`. This prevents malicious field names from executing shell commands.

### 3. Daemon Resilience
- **Supervision**: The D-Bus monitor is a child process supervised by the main daemon loop. If it dies, it is automatically restarted.
- **Auto-Healing**: The CLI automatically restarts the daemon upon a successful manual unlock if it was stopped.

---

## 💡 8. Universal Engineering Principles

The concepts used in BW-ENV can be applied to any robust system:
1.  **Isolate the Sourcing**: Keep shell initialization non-blocking to prevent terminal breakage.
2.  **Use the Right IPC**: Signals for state changes, Shared Memory for data sharing, Files for persistence.
3.  **Trap Everything**: Always provide a "Finally" block to clean up resources.
4.  **Be Transparent**: Log every state change with PIDs for easy auditing.

---
*Developed with rigor for the KpihX Infrastructure.*
