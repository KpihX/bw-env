#!/bin/bash
# === BW-ENV SHARED UTILITIES ===
# Purpose: Shared logic for logging, configuration, and security.
# This file provides the "plumbing" for logging, security, and UI.
# It is designed to be compatible with both Bash (scripts) and Zsh (sourced by user).

# --- 1. Standardized Logging (Journald + Console) ---
# log_info: Logs an informational message to the system journal and prints it with an icon to the console.
# Includes the Process ID [$$] and prefix for transparent process tracking.
log_info() { logger -t "${LOG_TAG:-bw-env}" "[INFO] [$$] $1"; echo "ℹ️ [bw-env:$$] $1"; }

# log_warn: Logs a warning message to the system journal and the console.
log_warn() { logger -t "${LOG_TAG:-bw-env}" "[WARN] [$$] $1"; echo "⚠️ [bw-env:$$] $1"; }

# log_err:  Logs a critical error message to the system journal and the console.
log_err()  { logger -t "${LOG_TAG:-bw-env}" "[ERR] [$$] $1";  echo "❌ [bw-env:$$] $1"; }

# log_sys:  Silent logging reserved for background processes (Daemon) to avoid polluting the terminal.
log_sys()  { logger -t "${DAEMON_TAG:-bw-env-daemon}" "[DAEMON] [$$] $1"; }

# --- 2. Configuration Loader ---
# Dynamically locates the .env file relative to the script being executed.
# Implements universal path detection for both Bash (${BASH_SOURCE}) and Zsh (${(%):-%x}).
load_config() {
    local script_path
    if [ -n "$ZSH_VERSION" ]; then
        script_path="${(%):-%x}"
    else
        script_path="${BASH_SOURCE[1]:-$0}"
    fi
    local script_dir="$(cd "$(dirname "$script_path")" && pwd)"
    local env_file="$script_dir/.env"
    
    if [[ -f "$env_file" ]]; then
        source "$env_file"
    else
        # Using log_err ensures consistency even if the configuration file is missing.
        log_err "Critical configuration file missing at $env_file"
        exit 1
    fi
}

# --- 3. Session Management (Shared RAM Bridge) ---
# These functions manage the Bitwarden session key stored in /dev/shm (RAM).
# This architecture allows the background daemon and multiple terminals to share a single authentication.

# load_session: Reads the Bitwarden session key from the RAM bridge and exports it to the current environment.
# Uses a single atomic read to avoid a race condition where another process deletes the file
# between the existence check and the cat call.
load_session() {
    local session
    session=$(cat "$SESSION_FILE" 2>/dev/null)
    if [[ -n "$session" ]]; then
        export BW_SESSION="$session"
    fi
}

# save_session: Writes the session key to the RAM bridge with restricted permissions (chmod 600).
save_session() {
    if [[ -n "$1" ]]; then
        if echo -n "$1" > "$SESSION_FILE"; then
            chmod 600 "$SESSION_FILE"
            export BW_SESSION="$1"
        else
            log_err "Failed to write session key to RAM bridge at $SESSION_FILE"
            return 1
        fi
    fi
}

# --- 3.1. GPG Key Management (Shared RAM Bridge) ---
# These functions manage the derived GPG encryption key in RAM to allow background syncs.

# load_gpg_key: Reads the derived GPG key from the RAM bridge.
load_gpg_key() {
    local key
    key=$(cat "$GPG_BRIDGE_FILE" 2>/dev/null)
    if [[ -n "$key" ]]; then
        export GPG_KEY="$key"
    fi
}

# save_gpg_key: Writes the derived GPG key to the RAM bridge with restricted permissions.
save_gpg_key() {
    if [[ -n "$1" ]]; then
        if echo -n "$1" > "$GPG_BRIDGE_FILE"; then
            chmod 600 "$GPG_BRIDGE_FILE"
            export GPG_KEY="$1"
        else
            log_err "Failed to write GPG key to RAM bridge at $GPG_BRIDGE_FILE"
            return 1
        fi
    fi
}

# --- 3.2. Global Revocation Management (Pub-Sub) ---
# register_keys: Extracts variable names from the RAM cache and stores them in the registry.
register_keys() {
    if [[ -f "$TEMP_ENV" ]] && [[ -n "$KEYS_REGISTRY" ]]; then
        grep -E '^export [A-Z0-9_]+=' "$TEMP_ENV" | cut -d' ' -f2 | cut -d'=' -f1 > "$KEYS_REGISTRY"
        chmod 600 "$KEYS_REGISTRY"
        log_sys "Global keys registry updated (Source: $TEMP_ENV)."
    fi
}

# subscriber_registry_files: Returns all configured subscriber registry files.
subscriber_registry_files() {
    [[ -n "$SUBS_REGISTRY_INTERACTIVE" ]] && printf '%s\n' "$SUBS_REGISTRY_INTERACTIVE"
    [[ -n "$SUBS_REGISTRY_NON_INTERACTIVE" ]] && printf '%s\n' "$SUBS_REGISTRY_NON_INTERACTIVE"
}

# current_subscriber_registry: Chooses the registry for the current shell type.
current_subscriber_registry() {
    if [[ -t 0 && "$-" == *i* ]]; then
        printf '%s\n' "$SUBS_REGISTRY_INTERACTIVE"
    else
        printf '%s\n' "$SUBS_REGISTRY_NON_INTERACTIVE"
    fi
}

# prune_subscriber_registry: Keeps only live numeric PIDs in the target registry.
prune_subscriber_registry() {
    local registry="$1"
    [[ -n "$registry" ]] || return 0
    [[ -f "$registry" ]] || return 0

    local tmp_file
    tmp_file=$(mktemp "${registry}.tmp.XXXXXX") || return 1

    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        kill -0 "$pid" 2>/dev/null || continue
        grep -qx "$pid" "$tmp_file" 2>/dev/null || echo "$pid" >> "$tmp_file"
    done < "$registry"

    if [[ -s "$tmp_file" ]]; then
        chmod 600 "$tmp_file"
        mv -f "$tmp_file" "$registry"
    else
        rm -f "$tmp_file" "$registry"
    fi
}

# prune_subscribers: Prunes all subscriber registries.
prune_subscribers() {
    local registry
    while read -r registry; do
        [[ -n "$registry" ]] || continue
        prune_subscriber_registry "$registry"
    done < <(subscriber_registry_files)
}

# register_subscriber: Adds the current shell's PID to the appropriate registry.
register_subscriber() {
    local registry
    registry=$(current_subscriber_registry)
    [[ -n "$registry" ]] || return 0

    prune_subscribers
    if ! grep -q "^$$\$" "$registry" 2>/dev/null; then
        touch "$registry"
        chmod 600 "$registry"
        echo "$$" >> "$registry"
        log_sys "Process [PID $$] registered for global revocation in $(basename "$registry")."
    fi
}

# remove_subscriber: Removes the current shell's PID from both registries.
remove_subscriber() {
    local registry tmp_file
    while read -r registry; do
        [[ -f "$registry" ]] || continue
        tmp_file=$(mktemp "${registry}.tmp.XXXXXX") || continue
        grep -vx "^$$\$" "$registry" > "$tmp_file" 2>/dev/null || true
        if [[ -s "$tmp_file" ]]; then
            chmod 600 "$tmp_file"
            mv -f "$tmp_file" "$registry"
        else
            rm -f "$tmp_file" "$registry"
        fi
    done < <(subscriber_registry_files)
    log_sys "Process [PID $$] unregistered (Exit)."
}

# remove_subscriber_pid: Removes the target PID from all registries.
remove_subscriber_pid() {
    local target_pid="$1"
    local registry tmp_file found=1

    [[ "$target_pid" =~ ^[0-9]+$ ]] || return 1

    prune_subscribers
    while read -r registry; do
        [[ -f "$registry" ]] || continue
        if ! grep -qx "$target_pid" "$registry" 2>/dev/null; then
            continue
        fi
        found=0
        tmp_file=$(mktemp "${registry}.tmp.XXXXXX") || continue
        grep -vx "^${target_pid}\$" "$registry" > "$tmp_file" 2>/dev/null || true
        if [[ -s "$tmp_file" ]]; then
            chmod 600 "$tmp_file"
            mv -f "$tmp_file" "$registry"
        else
            rm -f "$tmp_file" "$registry"
        fi
    done < <(subscriber_registry_files)

    if [[ $found -eq 0 ]]; then
        log_sys "Process [PID $target_pid] manually unsubscribed."
        return 0
    fi

    return 1
}

# broadcast_purge: Sends SIGUSR2 to all registered process PIDs to trigger environment wiping.
broadcast_purge() {
    local registry pid
    prune_subscribers
    while read -r registry; do
        [[ -f "$registry" ]] || continue
        log_sys "Broadcasting environment revocation signal (SIGUSR2) to $(basename "$registry")..."
        while read -r pid; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -SIGUSR2 "$pid" 2>/dev/null
            fi
        done < "$registry"
        rm -f "$registry"
    done < <(subscriber_registry_files)
}

# broadcast_inject: Sends SIGUSR1 to all registered interactive subscribers to trigger env refresh.
# Only targets interactive shells — non-interactive processes (MCPs, scripts) cannot re-source their env.
broadcast_inject() {
    local pid
    prune_subscriber_registry "$SUBS_REGISTRY_INTERACTIVE"
    [[ -f "$SUBS_REGISTRY_INTERACTIVE" ]] || return 0
    log_sys "Broadcasting environment refresh signal (SIGUSR1) to interactive subscribers..."
    while read -r pid; do
        kill -0 "$pid" 2>/dev/null && kill -SIGUSR1 "$pid" 2>/dev/null
    done < "$SUBS_REGISTRY_INTERACTIVE"
}

# clear_session: Securely wipes the session key and GPG key from the RAM bridge.
clear_session() {
    # 1. Wipe Bitwarden session bridge.
    if [[ -f "$SESSION_FILE" ]]; then
        local len=$(wc -c < "$SESSION_FILE")
        [[ $len -gt 0 ]] && printf '0%.0s' $(seq 1 $len) > "$SESSION_FILE"
        rm -f "$SESSION_FILE"
    fi
    # 2. Wipe GPG key bridge.
    if [[ -f "$GPG_BRIDGE_FILE" ]]; then
        local len=$(wc -c < "$GPG_BRIDGE_FILE")
        [[ $len -gt 0 ]] && printf '0%.0s' $(seq 1 $len) > "$GPG_BRIDGE_FILE"
        rm -f "$GPG_BRIDGE_FILE"
    fi
    unset BW_SESSION
    unset GPG_KEY
}

# --- 4. Concurrency Control (Atomic Locking with PID Transparency) ---
# acquire_lock: Ensures exclusive access to the shared environment state using 'flock'.
# Writes the current Process ID (PID) into the lock file to allow transparent auditing.
acquire_lock() {
    if [[ -z "$LOCK_FILE" ]]; then
        log_err "LOCK_FILE constant is missing from configuration. Concurrency control disabled."
        return 1
    fi
    
    # Open the lock file on a specific file descriptor.
    if ! exec {lock_fd}>>"$LOCK_FILE"; then
        log_err "Could not open lock file $LOCK_FILE"
        exit 1
    fi

    # Attempt to acquire the lock. If held by someone else, wait with a timeout.
    if ! flock -n "$lock_fd"; then
        local holder_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        log_info "Waiting for process [${holder_pid:-UNKNOWN}] to release environment lock..."
        if ! flock -w "${LOCK_TIMEOUT:-15}" "$lock_fd"; then
            log_err "Timeout: Could not acquire lock after ${LOCK_TIMEOUT:-15}s. Process [${holder_pid:-UNKNOWN}] may be stuck. Use 'bw-env unlock --force' to break it."
            exec {lock_fd}>&-
            exit 1
        fi
    fi
    
    # Once the lock is acquired, write our PID into the file for transparency.
    # We use truncate (>) to ensure only the current PID is in the file.
    echo $$ > "$LOCK_FILE"
    log_sys "Atomic lock acquired by process [$$]."
}

# release_lock: Releases the shared semaphore and clears the PID from the lock file.
release_lock() {
    if [[ -n "$lock_fd" ]]; then
        # Check if the file descriptor is still open before attempting to unlock.
        if { true >&"$lock_fd"; } 2>/dev/null; then
            # Clear the PID from the file before releasing the lock.
            echo "" > "$LOCK_FILE"
            flock -u "$lock_fd"
            exec {lock_fd}>&-
            log_sys "Atomic lock released by process [$$]."
        fi
        # Clear the descriptor variable to make the function idempotent.
        unset lock_fd
    fi
}

# force_release_lock: Emergency function to break a stuck lock.
# WARNING: Use only if you are sure no other process is actually writing to the vault.
force_release_lock() {
    local holder_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    
    if [[ -n "$holder_pid" ]]; then
        # SECURITY: Never kill yourself.
        if [[ "$holder_pid" == "$$" ]]; then
            log_sys "Force release requested by lock holder. Skipping self-termination."
        elif kill -0 "$holder_pid" 2>/dev/null; then
            log_warn "EMERGENCY: Breaking environment lock held by process [$holder_pid]..."
            log_info "Terminating stuck process [$holder_pid]..."
            kill -15 "$holder_pid" 2>/dev/null || kill -9 "$holder_pid" 2>/dev/null
        else
            log_warn "EMERGENCY: Breaking environment lock (process [$holder_pid] is already dead)..."
        fi
    else
        log_warn "EMERGENCY: Breaking environment lock (no active PID found in lock file)..."
    fi
    
    # 2. Remove the lock file and reset the semaphore.
    rm -f "$LOCK_FILE"
    log_info "Lock file removed. Environment is now free."
}

# is_locked: Checks if the environment lock is currently held by another process.
# Returns 0 (True) if locked, 1 (False) if free. Logs the status to the system journal.
is_locked() {
    if [[ -z "$LOCK_FILE" ]]; then return 1; fi
    
    if ! flock -n "$LOCK_FILE" -c true 2>/dev/null; then
        local holder_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        log_sys "Lock status check: LOCKED (held by process [${holder_pid:-UNKNOWN}])."
        return 0
    else
        log_sys "Lock status check: FREE."
        return 1
    fi
}

# --- 5. Security: Memory & File Wiping ---
# wipe_file: Overwrites a file with zeros before deleting it.
wipe_file() {
    local target="$1"
    if [[ -f "$target" ]]; then
        local len=$(wc -c < "$target")
        if [[ $len -gt 0 ]]; then
            # Overwrite with zeros using printf (portable and fast for small files).
            printf '0%.0s' $(seq 1 $len) > "$target"
            sync # Force disk/RAM sync.
        fi
        rm -f "$target"
    fi
}

# wipe_var: Overwrites a shell variable's RAM location with junk data before unsetting it.
# This is a 'best-effort' implementation to prevent secret remanence in process memory.
# Avoids creating a local copy of the secret value to minimize RAM exposure.
# Uses 'eval' for portable indirect expansion across Bash and Ksh/Zsh.
wipe_var() {
    local var_name=$1
    # Derive length WITHOUT copying the value into a local variable.
    eval "local len=\${#$var_name}"
    if [[ $len -gt 0 ]]; then
        # Generate a junk string of zeros with matching length.
        local junk=$(printf '0%.0s' $(seq 1 $len))
        # Overwrite the original variable content with the junk data, then unset.
        eval "$var_name=\$junk"
        unset "$var_name"
    fi
}

# --- 6. Global Cleanup & Signal Management ---
# Standard signals that should trigger a cleanup or be masked during critical phases.
CONTROL_SIGNALS=(SIGINT SIGTERM SIGQUIT SIGTSTP)

# setup_signal_handlers: Attaches the cleanup function to all critical signals.
# Ensures that the lock is released and memory is wiped on interruption.
setup_signal_handlers() {
    for sig in "${CONTROL_SIGNALS[@]}"; do
        trap cleanup_secrets "$sig"
    done
    # Also ensure cleanup on normal exit.
    trap cleanup_secrets EXIT
}

# mask_control_signals: Temporarily ignores all control signals.
# Returns a string containing the commands to restore the original handlers.
mask_control_signals() {
    local restore_cmds=""
    for sig in "${CONTROL_SIGNALS[@]}"; do
        local current_trap=$(trap -p "$sig")
        restore_cmds+="${current_trap:-trap - $sig}; "
        trap '' "$sig"
    done
    echo "$restore_cmds"
}

# cleanup_secrets: This function is the 'Finally' block of the system.
cleanup_secrets() {
    # Prevent recursive calls if a signal is received during cleanup.
    trap - "${CONTROL_SIGNALS[@]}" EXIT
    
    wipe_var MASTER_PASS
    wipe_var GPG_KEY
    wipe_var ENV_DATA
    wipe_var ITEM_JSON
    wipe_var SESSION_KEY
    wipe_var BW_SESSION
    
    # Ensure the concurrency lock is released.
    release_lock
}

# --- 7. UI: Secure Password Prompt (Direct & Context-Aware) ---
# Switches between TTY (read -s) and Zenity (GUI) based on whether a terminal is attached.
# Note: The automated session check is performed in main.sh to allow forced syncs to still prompt.
# $1: Window Title | $2: Prompt Text | $3: Error Message (Optional for retries)
prompt_master_password() {
    local title="${1:-🔑 BW-ENV Master Unlock}"
    local text="${2:-Enter your Vaultwarden Master Password (empty to skip):}"
    local error_msg="$3"
    
    # Display previous error (if provided) via the log framework or desktop notifications.
    if [[ -n "$error_msg" ]]; then
        if [[ -t 0 ]]; then
            log_warn "$error_msg"
        else
            command -v notify-send >/dev/null 2>&1 && notify-send -u critical "🛡️ BW-ENV" "$error_msg"
        fi
    fi

    if [[ -t 0 ]]; then
        # Interactive shell session: Hidden terminal input (like sudo).
        # Flush stdin buffer to prevent "skipped" prompts from residual input.
        local discard
        while read -t 0.01 -n 10000 discard 2>/dev/null; do :; done
        
        printf "%s " "$text"
        read -rs MASTER_PASS
        printf "\n"
    else
        # Background/Daemon session: GUI popup using Zenity.
        if ! command -v zenity >/dev/null 2>&1; then
            log_err "Zenity is required for GUI prompts but not installed."
            exit 1
        fi
        local display_text="$text"
        [[ -n "$error_msg" ]] && display_text="❌ $error_msg\n\n$text"
        MASTER_PASS=$(zenity --password --title="$title" --text="$display_text")
    fi
    
    # Handle empty password as an intentional "Skip" action (returns exit code 2).
    if [[ -z "$MASTER_PASS" ]]; then
        log_info "Secrets loading skipped by user."
        return 2
    fi
    return 0
}

# --- 8. Cryptography: Salted Key Derivation (PBKDF2) ---
# Generates a high-entropy key from (Password + Internal Salt) using PBKDF2.
# Uses 100,000 iterations of HMAC-SHA256 to make brute-force attacks infeasible.
derive_key() {
    if [[ -z "$INTERNAL_SALT" ]]; then
        log_err "Cryptographic Salt missing from configuration. Check your .env file."
        exit 1
    fi
    
    # Check if openssl is available AND supports the 'kdf' command (OpenSSL >= 1.1.1).
    if ! openssl help kdf >/dev/null 2>&1; then
        log_warn "OpenSSL KDF support not found. Falling back to weak SHA256 derivation (NOT RECOMMENDED)."
        echo -n "$1${INTERNAL_SALT}" | sha256sum | awk '{print $1}'
        return 0
    fi

    # Derive the key using PBKDF2 with 100k iterations.
    openssl kdf -kdfopt digest:SHA256 -kdfopt pass:"$1" -kdfopt salt:"$INTERNAL_SALT" -kdfopt iter:100000 -keylen 32 PBKDF2 | tr -d ':' | tr '[:upper:]' '[:lower:]'
}
