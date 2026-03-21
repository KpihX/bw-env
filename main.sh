#!/bin/bash
# === BW-ENV CORE MANAGER ===
# Logic: Centralized Management with Shared Session Bridge and Atomic Locking.
# SECURITY: Implements a "Finally" block via 'trap' for automated memory wiping.
# Exit Codes: 0=Success, 1=Config Error, 2=User Cancel, 3=Auth Error, 4=Retrieval Error, 5=Crypto Error

# --- 1. Robust Bootstrap ---
# Ensures shared utilities are available before starting any sensitive work.
UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$UTILS_DIR/utils.sh" ]]; then
    source "$UTILS_DIR/utils.sh"
    load_config # Loads constants like ITEM_ID, SESSION_FILE, LOCK_FILE, etc.
    
    # Check for mandatory dependencies.
    command -v jq >/dev/null 2>&1 || { log_err "jq is required but not installed."; exit 1; }
    command -v bw >/dev/null 2>&1 || { log_err "Bitwarden CLI (bw) is required but not installed."; exit 1; }
    command -v gpg >/dev/null 2>&1 || { log_err "GPG is required but not installed."; exit 1; }
else
    # Ultimate fallback logging if shared functions are missing.
    logger -t "bw-env-main" "[ERR] [$$] Critical failure: utils.sh missing at $UTILS_DIR"
    echo "❌ Critical failure: Shared utilities missing."
    exit 1
fi

# Store the command for idempotency checks.
COMMAND="$1"

# Load an existing shared session from RAM if available (Bridge).
load_session
load_gpg_key
prune_subscribers

# --- 2. Security: The Automated Cleanup ---
# Initialize centralized signal handling to ensure memory wiping and lock release.
setup_signal_handlers

# --- 3. Documentation: Help Interface ---
function show_help() {
  cat <<EOF
🔐 BW-ENV: Bitwarden-Powered Environment Manager (High-Security)
Usage: bw-env [command] [options]

  COMMANDS:
    unlock   Primary: Prompts for password, syncs vault, and updates caches (RAM & GPG).
             Use '--force' to break a stuck lock.
    sync     Refresh: Force-synchronizes local data with the Vaultwarden server.
             Uses RAM bridges (Session & GPG) for silent background updates.
    config   Settings: Read or update user-facing configuration values.
             Use 'bw-env config list', 'bw-env config list --json', 'bw-env config get KEY',
             or 'bw-env config set KEY VALUE'.
    gui      Control Center: Opens the graphical control center window.
             Includes Overview, Subscribers, Settings, and Activity/Logs tabs.
    tray     Tray: Starts, stops, restarts, or opens the tray/control-center integration.
             Use 'bw-env tray start|stop|restart|open|install'.
    lock     Security: Immediately purges secrets from RAM and closes all bridges.
             Triggers Global Revocation (SIGUSR2) to all active shells.
    purge    Nuclear: Destroys ALL traces (RAM, Disk, Bridges, Daemon) of secrets.
    decrypt  Cold Start: Restores the environment to RAM from the encrypted disk backup.
        status   Audit: Displays current visibility of secrets, bridges, and lock state.
                Use '--json' for machine-readable output (GUI / integrations).
    logs     Journal: Displays the last N log entries (default: 20). Use '-n X'.
    restart  Daemon: Restarts the background synchronization service.
    start    Daemon: Starts the background synchronization service.
    stop     Daemon: Stops the background synchronization service.
    pause    Daemon: Puts the daemon into PAUSED state (silent mode).
    resume   Daemon: Wakes up the daemon from PAUSED state.
    help     Manual: Displays this detailed help message.

    SHELL-SIDE COMMANDS (must run via the bw-env shell function, not as a subprocess):
    get      Subscribe: Injects secrets into the current terminal and registers it as a
            subscriber. Use when the vault was locked at shell startup.
    drop     Unsubscribe: Wipes secrets from the current terminal and removes it from
            the subscriber list (does not affect other shells or the global vault).

    SYSTEMD DAEMON (Background Sync & Auto-Lock):
    Status:  systemctl --user status bw-env-sync.service
    Logs:    journalctl -f --user-unit bw-env-sync.service
    Restart: systemctl --user restart bw-env-sync.service (or 'bw-env restart')
    Note:    If the daemon's prompt is cancelled or fails 3 times, it enters a PAUSED state.
            It automatically resumes upon a manual 'unlock' or system wake/reboot.

    DIAGNOSTICS & DEBUGGING:
    Action          System Command (Long)                bw-env Command (Fast)
    ------          ---------------------                ---------------------
    Check Status    systemctl --user status ...          bw-env status
    View Logs       journalctl -t bw-env ...             bw-env logs [-n X]
    Restart Daemon  systemctl --user restart ...         bw-env restart
    Pause Daemon    kill -SIGUSR2 [PID]                  bw-env pause
    Resume Daemon   kill -SIGUSR1 [PID]                  bw-env resume
    Trace Code      bash -x main.sh [command]            (Debug mode)
    Vault Health    bw status                            (Bitwarden CLI)

    CORE PRINCIPLES & GUARANTEES:
    1. Zero-Disk Plaintext: Secrets reside ONLY in /dev/shm (RAM) with 600 permissions.
    2. Atomic Updates: RAM cache updates use 'Atomic Swap' (mv) to prevent partial reads.
    3. Strong Crypto: Local backup is AES-encrypted via PBKDF2 (100,000 iterations).
    4. Auto-Lockdown: Instant RAM purge on System Sleep or Screen Lock (via D-Bus).
    5. Global Revocation: SIGUSR2 broadcast to all shells for immediate memory wipe.
    6. Concurrency: Atomic locking with PID transparency and post-release notification.
    7. Anti-Spam: Intelligent notifications triggered only on actual state changes.
    8. Resilience: Authoritative lock breaking on system wake-up events.

    EXIT CODES:
    0  SUCCESS: Operation completed successfully.
    1  CONFIG/DEP ERROR: Missing .env, utils.sh, or mandatory tools (jq, bw, gpg, openssl).
    2  USER CANCEL: User intentionally skipped or closed the password prompt.
    3  AUTH ERROR: Bitwarden Master Password verification failed.
    4  RETRIEVAL ERROR: Could not fetch item data or item is empty (prevents cache corruption).
    5  CRYPTO ERROR: GPG Encryption/Decryption or PBKDF2 key derivation failed.
    6  MAX ATTEMPTS: Maximum authentication attempts reached (prevents infinite loops).
EOF
}

config_flag_enabled() {
    local value="${1:-false}"
    case "${value,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

relevant_config_keys() {
    printf '%s\n' \
        AUTHORIZED_USER \
        ITEM_ID \
        CACHE_GPG \
        CHECK_INTERVAL \
        MAX_AUTH_ATTEMPTS \
        WAKE_DEBOUNCE_DELAY \
        GRAPHICAL_WAIT_DELAY \
        GRAPHICAL_WAIT_MAX \
        AUTO_START_ON_BOOT \
        AUTO_START_ON_WAKE \
        LOCK_TIMEOUT \
        LOAD_WAIT_MAX \
        LOAD_WAIT_STEP \
        DAEMON_TAG \
        LOG_TAG
}

config_value() {
    local key="$1"
    eval "printf '%s' \"\${$key}\""
}

emit_config_json() {
    local args=()
    local key value
    while read -r key; do
        [[ -n "$key" ]] || continue
        value=$(config_value "$key")
        args+=(--arg "$key" "$value")
    done < <(relevant_config_keys)

    jq -n "${args[@]}" '{
        authorized_user: $AUTHORIZED_USER,
        item_id: $ITEM_ID,
        cache_gpg: $CACHE_GPG,
        daemon: {
            check_interval: ($CHECK_INTERVAL | tonumber? // $CHECK_INTERVAL),
            max_auth_attempts: ($MAX_AUTH_ATTEMPTS | tonumber? // $MAX_AUTH_ATTEMPTS),
            auto_start_on_boot: ($AUTO_START_ON_BOOT | test("^(?i:true|1|yes|on)$")),
            auto_start_on_wake: ($AUTO_START_ON_WAKE | test("^(?i:true|1|yes|on)$")),
            wake_debounce_delay: ($WAKE_DEBOUNCE_DELAY | tonumber? // $WAKE_DEBOUNCE_DELAY),
            graphical_wait_delay: ($GRAPHICAL_WAIT_DELAY | tonumber? // $GRAPHICAL_WAIT_DELAY),
            graphical_wait_max: ($GRAPHICAL_WAIT_MAX | tonumber? // $GRAPHICAL_WAIT_MAX),
            lock_timeout: ($LOCK_TIMEOUT | tonumber? // $LOCK_TIMEOUT),
            load_wait_max: ($LOAD_WAIT_MAX | tonumber? // $LOAD_WAIT_MAX),
            load_wait_step: ($LOAD_WAIT_STEP | tonumber? // $LOAD_WAIT_STEP)
        },
        logging: {
            daemon_tag: $DAEMON_TAG,
            log_tag: $LOG_TAG
        }
    }'
}

set_config_value() {
    local key="$1"
    local value="$2"
    local env_file="$UTILS_DIR/.env"
    local tmp_file

    if ! grep -qx "$key" < <(relevant_config_keys); then
        log_err "Unsupported config key: $key"
        exit 1
    fi

    tmp_file=$(mktemp "${env_file}.tmp.XXXXXX") || {
        log_err "Failed to allocate temporary config file."
        exit 1
    }

    awk -v key="$key" -v value="$value" '
        BEGIN { updated = 0 }
        $0 ~ "^" key "=" {
            print key "=\"" value "\""
            updated = 1
            next
        }
        { print }
        END {
            if (!updated) {
                print key "=\"" value "\""
            }
        }
    ' "$env_file" > "$tmp_file"

    chmod 600 "$tmp_file"
    mv -f "$tmp_file" "$env_file"
    load_config
    log_info "Configuration updated: $key=$value"
}

emit_status_json() {
    prune_subscribers

    local daemon_running=false
    local daemon_pid=""
    local daemon_state="STOPPED"
    local daemon_label="STOPPED"
    if [[ -f "$DAEMON_PID_FILE" ]]; then
        daemon_pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
        if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
            daemon_running=true
            daemon_state="ACTIVE"
            [[ -f "$DAEMON_STATE_FILE" ]] && daemon_state=$(cat "$DAEMON_STATE_FILE")
            daemon_label="$daemon_state"
        fi
    fi

    local last_sync="NEVER"
    [[ -f "$LAST_SYNC_FILE" ]] && last_sync=$(cat "$LAST_SYNC_FILE")

    local ram_cache_active=false
    local disk_cache_active=false
    local vault_unlocked=false
    local shared_bridge_active=false
    local gpg_bridge_active=false
    [[ -f "$TEMP_ENV" ]] && ram_cache_active=true
    [[ -f "$CACHE_GPG" ]] && disk_cache_active=true
    bw status | grep -q '"status":"unlocked"' && vault_unlocked=true
    [[ -f "$SESSION_FILE" ]] && shared_bridge_active=true
    [[ -f "$GPG_BRIDGE_FILE" ]] && gpg_bridge_active=true

    local concurrency_state="LOCK_FREE"
    local concurrency_message="LOCK FREE"
    local lock_holder_pid=""
    if [[ -z "$LOCK_FILE" ]]; then
        concurrency_state="UNPROTECTED"
        concurrency_message="LOCK_FILE not configured"
    elif flock -n "$LOCK_FILE" -c true 2>/dev/null; then
        concurrency_state="LOCK_FREE"
        concurrency_message="LOCK FREE"
    else
        lock_holder_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$lock_holder_pid" ]] && ! kill -0 "$lock_holder_pid" 2>/dev/null; then
            concurrency_state="STALE_LOCK"
            concurrency_message="Process [$lock_holder_pid] is dead"
        else
            concurrency_state="LOCKED"
            concurrency_message="Held by process [${lock_holder_pid:-UNKNOWN}]"
        fi
    fi

    local interactive_json='[]'
    if [[ -f "$SUBS_REGISTRY_INTERACTIVE" ]]; then
        interactive_json=$(jq -Rn '[inputs | select(length > 0) | tonumber]' < "$SUBS_REGISTRY_INTERACTIVE")
    fi

    local non_interactive_json='[]'
    if [[ -f "$SUBS_REGISTRY_NON_INTERACTIVE" ]]; then
        non_interactive_json=$(
            while read -r pid; do
                [[ -n "$pid" ]] || continue
                ps -p "$pid" -o pid=,tty=,comm=,args= 2>/dev/null
            done < "$SUBS_REGISTRY_NON_INTERACTIVE" | \
            jq -R -s '
                split("\n")
                | map(select(length > 0))
                | map(capture("^(?<pid>\\S+)\\s+(?<tty>\\S+)\\s+(?<comm>\\S+)\\s+(?<args>.*)$"))
                | map({
                    pid: (.pid | tonumber),
                    tty: .tty,
                    comm: .comm,
                    args: .args
                })
            '
        )
    fi

    local keys_json='[]'
    if [[ -f "$KEYS_REGISTRY" ]]; then
        keys_json=$(jq -Rn '[inputs | select(length > 0)]' < "$KEYS_REGISTRY")
    fi

    jq -n \
        --arg daemon_pid "$daemon_pid" \
        --arg daemon_state "$daemon_state" \
        --arg daemon_label "$daemon_label" \
        --arg last_sync "$last_sync" \
        --arg check_interval "$CHECK_INTERVAL" \
        --arg auto_start_on_boot "$AUTO_START_ON_BOOT" \
        --arg auto_start_on_wake "$AUTO_START_ON_WAKE" \
        --arg temp_env "$TEMP_ENV" \
        --arg cache_gpg "$CACHE_GPG" \
        --arg session_file "$SESSION_FILE" \
        --arg gpg_bridge_file "$GPG_BRIDGE_FILE" \
        --arg concurrency_state "$concurrency_state" \
        --arg concurrency_message "$concurrency_message" \
        --arg lock_holder_pid "$lock_holder_pid" \
        --argjson daemon_running "$daemon_running" \
        --argjson ram_cache_active "$ram_cache_active" \
        --argjson disk_cache_active "$disk_cache_active" \
        --argjson vault_unlocked "$vault_unlocked" \
        --argjson shared_bridge_active "$shared_bridge_active" \
        --argjson gpg_bridge_active "$gpg_bridge_active" \
        --argjson interactive "$interactive_json" \
        --argjson non_interactive "$non_interactive_json" \
        --argjson keys "$keys_json" \
        '{
            daemon: {
                running: $daemon_running,
                pid: (if $daemon_pid == "" then null else ($daemon_pid | tonumber?) end),
                state: $daemon_state,
                label: $daemon_label,
                last_sync: $last_sync,
                check_interval: ($check_interval | tonumber?),
                auto_start_on_boot: ($auto_start_on_boot | test("^(?i:true|1|yes|on)$")),
                auto_start_on_wake: ($auto_start_on_wake | test("^(?i:true|1|yes|on)$"))
            },
            storage: {
                ram_cache: { active: $ram_cache_active, path: $temp_env },
                disk_cache: { active: $disk_cache_active, path: $cache_gpg },
                shared_bridge: { active: $shared_bridge_active, path: $session_file },
                gpg_bridge: { active: $gpg_bridge_active, path: $gpg_bridge_file }
            },
            vault: {
                unlocked: $vault_unlocked
            },
            concurrency: {
                state: $concurrency_state,
                message: $concurrency_message,
                holder_pid: (if $lock_holder_pid == "" then null else ($lock_holder_pid | tonumber?) end)
            },
            subscribers: {
                interactive: $interactive,
                non_interactive: $non_interactive
            },
            keys: {
                count: ($keys | length),
                names: $keys,
                active_in_ram: $ram_cache_active
            }
        }'
}

# notify_daemon: Internal helper to signal the background service.
# $1: Signal (SIGUSR1 for Wake, SIGUSR2 for Pause) | $2: Action Name
function notify_daemon() {
    local sig="$1"
    local action="$2"
    if [[ -f "$DAEMON_PID_FILE" ]]; then
        local daemon_pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
        if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
            # Check current daemon state to avoid redundant signaling.
            local current_state="UNKNOWN"
            [[ -f "$DAEMON_STATE_FILE" ]] && current_state=$(cat "$DAEMON_STATE_FILE")

            if [[ "$sig" == "SIGUSR1" && "$current_state" == "ACTIVE" ]]; then
                log_sys "Daemon is already ACTIVE. Skipping redundant wake-up signal."
                return 0
            fi
            if [[ "$sig" == "SIGUSR2" && "$current_state" == "PAUSED" ]]; then
                log_sys "Daemon is already PAUSED. Skipping redundant pause signal."
                return 0
            fi

            kill -"$sig" "$daemon_pid" 2>/dev/null
            log_info "Background daemon [PID $daemon_pid] notified: $action."
        elif [[ "$sig" == "SIGUSR1" ]]; then
            log_info "Background daemon is not running. Starting synchronization service..."
            systemctl --user start bw-env-sync.service 2>/dev/null
        else
            log_warn "Background daemon is not running. Signal $sig ($action) skipped."
        fi
    elif [[ "$sig" == "SIGUSR1" ]]; then
        log_info "Background daemon is not running. Starting synchronization service..."
        systemctl --user start bw-env-sync.service 2>/dev/null
    else
        log_warn "Background daemon is not running. Signal $sig ($action) skipped."
    fi
}

# $1: Mode (Optional '--daemon' to prevent infinite retry loops in background)
function unlock_unified() {
    local run_mode="$1"
    local attempts=0
    local max_attempts="${MAX_AUTH_ATTEMPTS:-3}"

    # --- 4.1. Idempotency Check ---
    # If 'unlock' is requested but environment is already active, skip to avoid redundant prompts.
    # CRITICAL: 'sync' must ALWAYS proceed to refresh the environment and register the shell.
    if [[ "$COMMAND" == "unlock" ]] && [[ -f "$TEMP_ENV" ]] && bw status | grep -q '"status":"unlocked"'; then
        log_info "Environment is already active. Use 'sync' to force an update."
        [[ "$run_mode" != "--daemon" ]] && notify_daemon "SIGUSR1" "Resume Sync"
        return 0
    fi

    # --- 4.2. Concurrency Control ---
    acquire_lock

    log_info "Initiating Unified Salted Unlock sequence..."

    local error=""
    # Note: ITEM_JSON and SESSION_KEY are global for security wiping via trap.
    ITEM_JSON=""
    SESSION_KEY=""

    while true; do
        # --- 4.3. Validation & Retrieval (The Quality Funnel) ---
        # If we have a session, try to refresh and get the data immediately.
        if [[ -n "$BW_SESSION" ]] && [[ -n "$GPG_KEY" ]]; then
            log_info "Active session detected. Synchronizing with server..."
            
            # 1. Force server synchronization to ensure data freshness.
            # This also serves as a non-interactive session validation.
            if bw sync >/dev/null 2>&1; then
                log_info "Vault successfully synchronized. Retrieving data..."
                
                # 2. Retrieve the item from the freshly updated local database.
                ITEM_JSON=$(bw get item "$ITEM_ID" 2>/dev/null)
                if [[ $? -eq 0 ]] && [[ -n "$ITEM_JSON" ]]; then
                    log_info "Vault item data successfully retrieved."
                    break # SUCCESS: We have fresh data and a valid session.
                else
                    log_warn "Retrieval failed. Vault might be locked. Clearing bridge..."
                fi
            else
                log_warn "Session token rejected by server. Clearing bridge..."
            fi
            
            clear_session
            error="Session expired or invalidated by another process."
        fi

        # --- 4.4. Authentication (Fallback) ---
        ((attempts++))
        if [[ $attempts -gt $max_attempts ]]; then
            log_err "Maximum authentication attempts ($max_attempts) reached. Aborting."
            release_lock
            exit "$EXIT_MAX_ATTEMPTS"
        fi

        prompt_master_password "🔑 BW-ENV Master Unlock" "Enter your Vaultwarden Master Password (empty to skip):" "$error"
        if [[ $? -eq "$EXIT_USER_CANCEL" ]]; then
            log_info "Authentication cancelled by user."
            release_lock
            exit "$EXIT_USER_CANCEL"
        fi

        log_info "Verifying credentials with Bitwarden server (Attempt $attempts/$max_attempts)..."
        SESSION_KEY=$(bw unlock --raw <<< "$MASTER_PASS")
        if [[ $? -eq 0 ]]; then
            save_session "$SESSION_KEY"
            log_info "Bitwarden session established and shared via RAM bridge."
            
            log_info "Generating salted cryptographic key for local storage..."
            GPG_KEY=$(derive_key "$MASTER_PASS")
            if [[ -n "$GPG_KEY" ]]; then
                save_gpg_key "$GPG_KEY"
                log_info "Encryption key successfully derived and shared via RAM bridge."
            else
                log_err "Key derivation critical failure."
                exit "$EXIT_CRYPTO_ERR"
            fi
            # We don't break here; the next iteration will perform the 'bw get item'.
        else
            error="Authentication failed: Incorrect Master Password provided."
            wipe_var MASTER_PASS
        fi
    done

    # --- 4.8. Data Transformation (JSON to Shell) ---
    log_info "Processing custom fields into shell environment variables..."
    ENV_DATA=$(echo "$ITEM_JSON" | jq -r '.fields[] | select(.value != null) | 
        .name as $raw_name | 
        ($raw_name | gsub("[^a-zA-Z0-9_]"; "_") | sub("^[0-9]"; "_\(.)")) as $safe_name | 
        "export \($safe_name)=\(.value | @sh)"')
    
    if [[ -z "$ENV_DATA" ]]; then
        log_err "No environment variables found in Bitwarden item $ITEM_ID. Aborting to prevent cache corruption."
        exit "$EXIT_RETRIEVAL_ERR"
    fi

    # --- 4.9. RAM Deployment (Volatile Cache) ---
    local temp_file="${TEMP_ENV}.tmp"
    if echo "$ENV_DATA" > "$temp_file" && chmod 600 "$temp_file"; then
        mv -f "$temp_file" "$TEMP_ENV"
        log_info "Volatile environment cache updated successfully at $TEMP_ENV"
        register_keys
    else
        log_err "Failed to deploy RAM cache."
        rm -f "$temp_file"
        exit "$EXIT_CONFIG_ERR"
    fi

    # --- 4.10. Persistent Backup (Encrypted Disk Cache) ---
    log_info "Updating persistent encrypted disk cache backup..."
    if [[ -z "$GPG_KEY" ]]; then
        log_warn "GPG key missing from memory. Skipping disk backup."
    else
        if echo "$ENV_DATA" | gpg --batch --yes --symmetric --passphrase "$GPG_KEY" \
            --cipher-algo AES256 -o "$CACHE_GPG" 2>/dev/null; then
            chmod 600 "$CACHE_GPG"
            log_info "Local encrypted cache updated at $CACHE_GPG"
        else
            log_warn "Disk backup failed: GPG encryption error."
        fi
    fi
    
    # --- 4.11. Timestamp Update ---
    if [[ -n "$LAST_SYNC_FILE" ]]; then
        date "+%Y-%m-%d %H:%M:%S" > "$LAST_SYNC_FILE"
        chmod 600 "$LAST_SYNC_FILE"
    fi

    log_info "Unified Sync & Unlock complete. Secrets are now active."
    
    # --- 4.12. Finalization ---
    release_lock
    
    # Notify daemon only if called manually.
    [[ "$run_mode" != "--daemon" ]] && notify_daemon "SIGUSR1" "Resume Sync"
    
    return "$EXIT_SUCCESS"
}

# --- 5. Security: The Emergency Lockdown ---
# $1: Mode (Optional '--daemon' to prevent signal loops)
function lock_vault() {
    local run_mode="$1"
    # --- 5.1. Idempotency Check ---
    if [[ ! -f "$TEMP_ENV" ]] && [[ ! -f "$SESSION_FILE" ]] && ! bw status | grep -q '"status":"unlocked"'; then
        log_info "Environment is already locked."
        # SECURITY: Even if already locked, ensure the daemon is paused if called manually.
        [[ "$run_mode" != "--daemon" ]] && notify_daemon "SIGUSR2" "Pause Sync"
        return "$EXIT_SUCCESS"
    fi

    # AUTHORITATIVE LOCK: If the environment is busy, we break the lock to ensure immediate lockdown.
    if ! flock -n "$LOCK_FILE" -c true 2>/dev/null; then
        log_warn "Environment is busy. Breaking lock to force security lockdown..."
        force_release_lock
    fi
    acquire_lock

    log_info "Executing Security Lockdown..."
    
    # 5.2. Purge volatile RAM secrets.
    if [[ -f "$TEMP_ENV" ]]; then
        # SECURITY: Broadcast revocation signal to all active shells before deleting the cache.
        broadcast_purge
        rm -f "$TEMP_ENV"
        log_info "Volatile RAM environment secrets purged globally."
    fi
    
    # 5.3. Invalidate Bitwarden session and destroy the shared bridge.
    log_info "Invalidating Bitwarden session and destroying bridge..."
    bw lock
    clear_session # Wipes and deletes the shared session file.

    # 5.4. Flush GPG agent memory.
    log_info "Flushing GPG agent memory..."
    gpg-connect-agent reloadagent /bye
    
    log_info "Lockdown successful. Environment is now completely cold."
    release_lock

    # 5.3.2. Daemon Notification
    # SECURITY: Notify AFTER releasing the lock.
    [[ "$run_mode" != "--daemon" ]] && notify_daemon "SIGUSR2" "Pause Sync"

    return "$EXIT_SUCCESS"
}

# --- 5.5. Total Destruction: The Nuclear Option ---
function purge_all() {
    log_warn "NUCLEAR OPTION: Executing total environment destruction..."
    
    # AUTHORITATIVE LOCK: Ensure nothing stops the nuclear option.
    if ! flock -n "$LOCK_FILE" -c true 2>/dev/null; then
        log_warn "Environment is busy. Breaking lock to force total destruction..."
        force_release_lock
    fi
    acquire_lock

    # 1. Stop the background daemon first.
    log_info "Stopping background synchronization service..."
    systemctl --user stop bw-env-sync.service 2>/dev/null
    
    # 2. Execute a standard lockdown first.
    log_info "Initiating global revocation..."
    broadcast_purge
    
    # 3. Securely wipe all remaining RAM-based files.
    log_info "Wiping volatile RAM caches and bridges..."
    wipe_file "$TEMP_ENV"
    wipe_file "$SESSION_FILE"
    wipe_file "$GPG_BRIDGE_FILE"
    wipe_file "$SUBS_REGISTRY_INTERACTIVE"
    wipe_file "$SUBS_REGISTRY_NON_INTERACTIVE"
    
    # 4. Securely wipe the persistent disk cache.
    log_info "Destroying persistent disk backup ($CACHE_GPG)..."
    wipe_file "$CACHE_GPG"
    
    # 5. Force release and destroy the concurrency lock.
    force_release_lock
    
    # 6. Invalidate Bitwarden session.
    bw lock 2>/dev/null
    
    log_info "PURGE COMPLETE. No traces of secrets remain on this machine."
    return "$EXIT_SUCCESS"
}

# --- 6. Resilience: Cold Cache Restoration ---
function decrypt_cache() {
    # --- 6.1. Idempotency Check ---
    if [[ -f "$TEMP_ENV" ]]; then
        log_info "Environment cache is already active in RAM."
        return "$EXIT_SUCCESS"
    fi

    # Acquire exclusive lock to prevent sync collisions during restoration.
    acquire_lock

    log_info "Cold start detected: Restoring environment from disk backup..."
    
    local error=""
    local attempts=0
    local max_attempts="${MAX_AUTH_ATTEMPTS:-3}"

    while true; do
        # Check attempt limit
        ((attempts++))
        if [[ $attempts -gt $max_attempts ]]; then
            log_err "Maximum authentication attempts ($max_attempts) reached. Aborting."
            release_lock
            exit "$EXIT_MAX_ATTEMPTS"
        fi

        # Prompt for password to re-derive the hash needed by GPG.
        prompt_master_password "🔓 Unlock Local Environment" "Enter Master Password to decrypt local cache:" "$error"
        EXIT_CODE=$?
        if [[ $EXIT_CODE -eq "$EXIT_USER_CANCEL" ]]; then
            release_lock
            exit "$EXIT_USER_CANCEL"
        fi
        
        log_info "Re-calculating salted encryption key (Attempt $attempts/$max_attempts)..."
        GPG_KEY=$(derive_key "$MASTER_PASS")
        if [[ -n "$GPG_KEY" ]]; then
            log_info "Derivation successful."
        else
            log_err "Key derivation failed."
            exit "$EXIT_CRYPTO_ERR"
        fi
        
        log_info "Attempting to decrypt disk backup into RAM memory..."
        local temp_file="${TEMP_ENV}.tmp"
        if gpg --quiet --batch --decrypt --passphrase "$GPG_KEY" --pinentry-mode loopback "$CACHE_GPG" > "$temp_file"; then
            chmod 600 "$temp_file"
            mv -f "$temp_file" "$TEMP_ENV"
            log_info "RAM cache successfully restored from disk backup."
            # Update the global keys registry for revocation support.
            register_keys
            break
        else
            error="Decryption failed: Incorrect password provided for local cache."
            log_warn "$error"
            rm -f "$temp_file"
            wipe_var MASTER_PASS; wipe_var GPG_KEY
        fi
    done
    
    release_lock
    return "$EXIT_SUCCESS"
}

# show_logs: Displays the last N entries from the system journal for this tool.
function show_logs() {
    local n="${1:-20}"
    echo "=== BW-ENV SYSTEM LOGS (Last $n entries) ==="
    journalctl -t "$LOG_TAG" -t "$DAEMON_TAG" -n "$n" --no-pager
}

# --- 7. CLI Entry Point ---
DAEMON_FLAG=""
[[ "$*" == *"--daemon"* ]] && DAEMON_FLAG="--daemon"

if [[ "$*" == *"--force"* ]]; then
    force_release_lock
fi

case "$1" in
    unlock|sync) unlock_unified "$DAEMON_FLAG" ;;
    lock)        lock_vault "$DAEMON_FLAG" ;;
    purge)       purge_all ;;
    decrypt)     decrypt_cache ;;
    get|drop)
        log_err "'bw-env $1' is a shell-side command — it must run inside your shell process."
        log_info "Make sure bw-env is loaded as a shell function (source ~/.kshrc) and not called as a subprocess."
        exit 1
        ;;
    gui)
        exec /usr/bin/python3 "$UTILS_DIR/gui/control_center.py"
        ;;
    tray)
        shift
        exec bash "$UTILS_DIR/gui/tray.sh" "${1:-start}"
        ;;
    restart)
        log_info "Restarting background synchronization service..."
        systemctl --user restart bw-env-sync.service
        ;;
    start)
          log_info "Starting background synchronization service..."
          systemctl --user start bw-env-sync.service
          ;;
      config)
          shift
          case "$1" in
              list|"")
                  if [[ "$2" == "--json" ]]; then
                      emit_config_json
                  else
                      while read -r key; do
                          [[ -n "$key" ]] || continue
                          echo "$key=$(config_value "$key")"
                      done < <(relevant_config_keys)
                  fi
                  ;;
              --json)
                  emit_config_json
                  ;;
              get)
                  [[ -n "$2" ]] || { log_err "Usage: bw-env config get KEY"; exit 1; }
                  if ! grep -qx "$2" < <(relevant_config_keys); then
                      log_err "Unsupported config key: $2"
                      exit 1
                  fi
                  config_value "$2"
                  echo
                  ;;
              set)
                  [[ -n "$2" && -n "$3" ]] || { log_err "Usage: bw-env config set KEY VALUE"; exit 1; }
                  set_config_value "$2" "$3"
                  ;;
              *)
                  log_err "Unsupported config action: $1"
                  exit 1
                  ;;
          esac
          ;;
    stop)
        log_info "Stopping background synchronization service..."
        systemctl --user stop bw-env-sync.service
        ;;
    pause)
        if [[ -f "$DAEMON_PID_FILE" ]]; then
            d_pid=$(cat "$DAEMON_PID_FILE")
            log_info "Sending pause signal to daemon [PID $d_pid]..."
            kill -SIGUSR2 "$d_pid" 2>/dev/null && log_info "Daemon paused."
        else
            log_err "Daemon is not running."
        fi
        ;;
    resume)
        if [[ -f "$DAEMON_PID_FILE" ]]; then
            d_pid=$(cat "$DAEMON_PID_FILE")
            log_info "Sending resume signal to daemon [PID $d_pid]..."
            kill -SIGUSR1 "$d_pid" 2>/dev/null && log_info "Daemon resumed."
        else
            log_err "Daemon is not running."
        fi
        ;;
    logs)        
        shift
        lines=20
        [[ "$1" == "-n" ]] && { lines="$2"; shift 2; }
        show_logs "$lines"
        ;;
      help|--help) show_help ;;
      status)
          if [[ "$2" == "--json" ]]; then
              emit_status_json
              exit 0
          fi
          prune_subscribers
          echo "=== BW-ENV STATUS (ATOMIC & SHARED) ==="
        daemon_status="❌ STOPPED"
        if [[ -n "$DAEMON_PID_FILE" ]] && [[ -f "$DAEMON_PID_FILE" ]]; then
            d_pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
            if [[ -n "$d_pid" ]] && kill -0 "$d_pid" 2>/dev/null; then
                d_state="UNKNOWN"
                [[ -f "$DAEMON_STATE_FILE" ]] && d_state=$(cat "$DAEMON_STATE_FILE")
                if [[ "$d_state" == "PAUSED" ]]; then
                    daemon_status="⚠️ PAUSED (PID $d_pid)"
                else
                    daemon_status="✅ ACTIVE (PID $d_pid)"
                fi
            fi
        fi
        echo "Sync Daemon:    $daemon_status"
        last_sync="NEVER"
        [[ -f "$LAST_SYNC_FILE" ]] && last_sync=$(cat "$LAST_SYNC_FILE")
        echo "Last Sync:      $last_sync"
        [[ -f "$TEMP_ENV" ]] && echo "RAM Cache:      ✅ ACTIVE ($TEMP_ENV)" || echo "RAM Cache:      ❌ LOCKED"
        [[ -f "$CACHE_GPG" ]] && echo "Disk Cache: ✅ ENCRYPTED ($CACHE_GPG)" || echo "Disk Cache: ❌ MISSING"
        bw status | grep -q '"status":"unlocked"' && echo "Bitwarden:      ✅ UNLOCKED" || echo "Bitwarden:      ❌ LOCKED"
        [[ -f "$SESSION_FILE" ]] && echo "Shared Bridge:  ✅ ACTIVE (RAM)" || echo "Shared Bridge:  ❌ CLOSED"
        [[ -f "$GPG_BRIDGE_FILE" ]] && echo "GPG Bridge:     ✅ ACTIVE (RAM)" || echo "GPG Bridge:     ❌ CLOSED"
        if [[ -z "$LOCK_FILE" ]]; then
            echo "Concurrency:    ⚠️ UNPROTECTED (LOCK_FILE not configured)"
        elif flock -n "$LOCK_FILE" -c true 2>/dev/null; then
            echo "Concurrency:    ✅ LOCK FREE"
        else
            holder_pid=$(cat "$LOCK_FILE" 2>/dev/null)
            if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
                echo "Concurrency:    ⚠️ STALE LOCK (Process [$holder_pid] is dead)"
            else
                echo "Concurrency:    🔒 LOCKED (by process [${holder_pid:-UNKNOWN}])"
            fi
        fi
        echo -e "\n=== GLOBAL REVOCATION (PUB-SUB) ==="
        if [[ -f "$SUBS_REGISTRY_INTERACTIVE" ]]; then
            sub_count=$(wc -l < "$SUBS_REGISTRY_INTERACTIVE")
            sub_list=$(tr '\n' ',' < "$SUBS_REGISTRY_INTERACTIVE" | sed 's/,$//' | sed 's/,/, /g')
            echo "Interactive:    ✅ $sub_count shell subscriber(s) registered."
            echo "Subscribers:    [ $sub_list ]"
        else
            echo "Interactive:    ❌ No interactive subscribers registered."
        fi
        if [[ -f "$SUBS_REGISTRY_NON_INTERACTIVE" ]]; then
            sub_count=$(wc -l < "$SUBS_REGISTRY_NON_INTERACTIVE")
            echo "Non-Interactive: ✅ $sub_count process subscriber(s) registered."
            while read -r pid; do
                [[ -n "$pid" ]] || continue
                proc_line=$(ps -p "$pid" -o pid=,tty=,comm=,args= 2>/dev/null)
                [[ -n "$proc_line" ]] || continue
                proc_pid=$(echo "$proc_line" | awk '{print $1}')
                proc_tty=$(echo "$proc_line" | awk '{print $2}')
                proc_comm=$(echo "$proc_line" | awk '{print $3}')
                proc_args=$(echo "$proc_line" | awk '{$1=$2=$3=""; sub(/^   */, ""); print}')
                echo "  - PID: $proc_pid | TTY: $proc_tty | Comm: $proc_comm"
                echo "    Cmd: $proc_args"
            done < "$SUBS_REGISTRY_NON_INTERACTIVE"
        else
            echo "Non-Interactive: ❌ No non-interactive subscribers registered."
        fi
        if [[ -f "$KEYS_REGISTRY" ]]; then
            key_count=$(wc -l < "$KEYS_REGISTRY")
            key_list=$(tr '\n' ',' < "$KEYS_REGISTRY" | sed 's/,$//' | sed 's/,/, /g')
            if [[ -f "$TEMP_ENV" ]]; then
                echo "Injected Keys:  ✅ $key_count variable(s) active in RAM."
                echo "Key List:       { $key_list }"
            else
                echo "Injected Keys:  🔒 $key_count variable(s) indexed (Vault Locked)."
                echo "Key List:       { $key_list }"
            fi
        else
            echo "Injected Keys:  ❌ No keys indexed."
        fi
        ;;
    *) show_help ;;
esac
