# 🔐 BW-ENV: Bitwarden-Powered Environment Manager

**BW-ENV** is a production-grade, high-security utility designed to centralize and automate the management of environment variables using **Vaultwarden/Bitwarden** as the single source of truth. It implements advanced Unix system programming concepts to achieve a "Zero-Friction, Zero-Leak" environment.

---

## 🏛️ 1. Zero-Trust Architecture & Security Mandates

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

### 1. Shell Integration
Add the following function to your `~/.zshrc` (or `~/.kshrc` / `~/.bashrc`) to enable the `bw-env` command and automatic loading:

```bash
# === BW-ENV Management (Bitwarden) ===
bw-env() {
    bash $HOME/Work/sh/bw-env/main.sh "$@"
    local ret=$?
    # Refresh terminal environment after a successful unlock or sync
    if [[ $ret -eq 0 && "$1" != "status" && "$1" != "help" && "$1" != "lock" && "$1" != "purge" ]]; then
        source $HOME/Work/sh/bw-env/load.sh
    fi
    # Trigger local shell revocation on lock or purge
    if [[ "$1" == "lock" || "$1" == "purge" ]]; then
        kill -SIGUSR2 $$ 2>/dev/null
    fi
    return $ret
}
# Initial load on terminal startup (Non-blocking)
source $HOME/Work/sh/bw-env/load.sh
```

### 2. Configuration (`.env`)
The system is 100% flexible. All parameters are centralized in `~/Work/sh/bw-env/.env`:

```bash
# Bitwarden Item ID: The unique UUID of the secure note.
ITEM_ID="fc88b261-f2c7-4bfe-b861-8b0dc90a22ec"

# Cryptography
INTERNAL_SALT="BW_ENV_2026_PROD"
MAX_AUTH_ATTEMPTS=3

# Paths & Bridges
CACHE_GPG="$HOME/.bw/cache.env.gpg"
TEMP_ENV="/dev/shm/bw-$USER.env"
SESSION_FILE="/dev/shm/bw-session-$USER"
GPG_BRIDGE_FILE="/dev/shm/bw-gpg-$USER"
LOCK_FILE="/dev/shm/bw-env-$USER.lock"

# Daemon Control
DAEMON_PID_FILE="/dev/shm/bw-env-daemon-$USER.pid"
DAEMON_STATE_FILE="/dev/shm/bw-env-daemon-$USER.state"
LAST_SYNC_FILE="/dev/shm/bw-env-$USER.lastsync"
CHECK_INTERVAL=300
```

### 3. Background Sync & Auto-Lock (Systemd)
Install the user service for proactive security:

1.  **Create unit file**: `~/.config/systemd/user/bw-env-sync.service`
2.  **Configuration**:
    ```ini
    [Service]
    ExecStart=/bin/bash %h/Work/sh/bw-env/sync-daemon.sh
    Restart=on-failure
    ```
3.  **Enable**: `systemctl --user enable --now bw-env-sync.service`

---

## 🤖 3. Reactive Intelligence & Collective Security

BW-ENV is not just a script; it's a reactive ecosystem where every component communicates in real-time.

### 📡 Global Revocation (Pub-Sub Model)
- **Subscriber Registry**: Every active terminal registers its PID in a shared list.
- **Signal Broadcast**: Upon a `lock` or `purge`, the system broadcasts a **`SIGUSR2`** signal to all registered shells.
- **Instant Purge**: Each shell reacts to the signal by immediately unsetting all secrets from its memory, ensuring a system-wide security wipe in milliseconds.

### 🛡️ Proactive Auto-Lockdown
- **D-Bus Integration**: A supervised monitor listens for system-wide signals (`PrepareForSleep`, `LockedHint`).
- **Reactive Purge**: Secrets are instantly wiped from RAM when you close your laptop or lock your screen.

### 💤 Smart Daemon (Gentleman Mode)
- **Interruptible Sleep**: The daemon uses an interruptible `wait` loop, allowing it to react instantly to **`SIGUSR1`** (Resume) or **`SIGUSR2`** (Pause) signals.
- **Auto-Healing**: The CLI automatically detects if the daemon is stopped and restarts it upon a successful manual unlock.

---

## ⚙️ 3. Operational Excellence & Flexibility

### 🧩 Zero-Hardcoding Philosophy
Every constant, path, timeout, and security limit is centralized in the `.env` file. This allows for 100% flexibility and easy adaptation to different environments or security requirements.

### 🚦 Concurrency & Transparency
- **Atomic Locking**: Uses `flock` with **PID transparency**. You can always see exactly which process holds the lock via `bw-env status`.
- **Authoritative Security**: Security commands (`lock`, `purge`) are prioritized. They will break any existing lock to ensure immediate protection.

---

## 🛠️ 4. Usage & Command Center

| Command | Category | Description |
| :--- | :--- | :--- |
| `bw-env unlock` | **Primary** | Prompts for password, syncs vault, and establishes RAM bridges. |
| `bw-env sync` | **Refresh** | Force-synchronizes local data. Uses bridges for silent background updates. |
| `bw-env status` | **Audit** | Full visibility: Daemon state, RAM/Disk caches, Bridges, and Active Shells. |
| `bw-env lock` | **Security** | Purges RAM, closes bridges, and triggers **Global Revocation**. |
| `bw-env purge` | **Nuclear** | **Total Destruction**: Stops daemon, wipes RAM/Disk, and revokes all shells. |
| `bw-env logs` | **Journal** | Quick access to the last X system journal entries (`-n X`). |
| `bw-env restart`| **Control** | Restarts the background synchronization service. |
| `bw-env pause`  | **Control** | Puts the daemon into silent sleep mode (D-Bus remains active). |
| `bw-env resume` | **Control** | Wakes up the daemon and triggers an immediate sync cycle. |

---

## 🚦 5. Standardized Exit Codes

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
- **Bitwarden Status**: `bw status`.
- **Trace Execution**: `bash -x ~/Work/sh/bw-env/main.sh [command]`.

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
