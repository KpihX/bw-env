#!/bin/bash
# === BW-ENV SYNC DAEMON ===
# Logic: Background synchronization + Automated session sharing + Proactive auto-lock.
# This daemon ensures your local cache stays fresh and automatically locks when you are away.

# --- 1. Robust Bootstrap ---
# Locate shared logic and configuration.
UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$UTILS_DIR/utils.sh" ]]; then
    source "$UTILS_DIR/utils.sh"
    load_config
else
    # Fallback logging if initialization fails.
    logger -t "bw-env-daemon" "[ERR] [$$] Initialization failed: utils.sh missing at $UTILS_DIR"
    exit 1
fi

# --- 2. Anti-Multi-Instance Guard (PID File) ---
# update_daemon_state: Publishes the current state for the 'status' command.
update_daemon_state() {
    if [[ -n "$DAEMON_STATE_FILE" ]]; then
        echo "$1" > "$DAEMON_STATE_FILE"
        chmod 600 "$DAEMON_STATE_FILE"
    fi
}

# --- 2. Anti-Multi-Instance Guard (PID File) ---
if [[ -f "$DAEMON_PID_FILE" ]]; then
    OLD_PID=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        log_sys "Daemon already running (PID $OLD_PID). Exiting to prevent duplicate instance."
        exit 0
    else
        log_sys "Stale or empty PID file found. Overwriting."
    fi
fi
echo $$ > "$DAEMON_PID_FILE"
chmod 600 "$DAEMON_PID_FILE"
update_daemon_state "ACTIVE"

# --- 2. State Management ---
PAUSED=false
DAEMON_PID=$$
PROCESSING_SIGNAL=false

config_flag_enabled() {
    local value="${1:-false}"
    case "${value,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# get_graphical_env: Exports DISPLAY and DBUS variables for Zenity support.
get_graphical_env() {
    export DISPLAY="${DISPLAY:-:0}"
    local user_id=$(id -u)
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$user_id/bus}"
}

# resume_daemon: Signal handler for SIGUSR1. Triggered by manual 'bw-env unlock' in a terminal or System Wake.
resume_daemon() {
    if [[ "$PROCESSING_SIGNAL" == "true" ]]; then
        log_sys "Signal SIGUSR1 received but already processing. Skipping."
        return
    fi
    PROCESSING_SIGNAL=true
    
    local was_paused="$PAUSED"
    
    # AUTHORITATIVE RECOVERY: Use --force ONLY if this is a system wake event (detected via D-Bus).
    get_graphical_env
    local force_flag=""
    [[ "$current_signal" == "sleep" ]] && force_flag="--force"
    
    log_sys "Signal SIGUSR1 received. Resuming background synchronization."
    # Small delay to ensure graphical context is fully active.
    sleep "${GRAPHICAL_WAIT_DELAY:-1}"
    if "$UTILS_DIR/main.sh" unlock $force_flag --daemon; then
        PAUSED=false
        update_daemon_state "ACTIVE"
        # Only notify if we were previously PAUSED to avoid spamming on manual refreshes.
        if [[ "$was_paused" == "true" ]]; then
            send_notification "Background sync RESUMED. Environment refreshed."
        fi
    else
        local exit_code=$?
        log_sys "Unlock failed or cancelled (Code $exit_code). Reverting to PAUSED state."
        PAUSED=true
        update_daemon_state "PAUSED"
        # Always notify on failure as it's a state change to PAUSED.
        send_notification "Background sync PAUSED. Unlock failed or cancelled."
    fi
    
    PROCESSING_SIGNAL=false
    # Kill the current sleep process to force an immediate loop iteration.
    pkill -P $$ sleep 2>/dev/null
}

# pause_daemon: Signal handler for SIGUSR2. Triggered by manual 'bw-env lock' or 'bw-env pause'.
pause_daemon() {
    if [[ "$PROCESSING_SIGNAL" == "true" ]]; then
        return
    fi
    PROCESSING_SIGNAL=true
    
    local was_paused="$PAUSED"
    PAUSED=true
    update_daemon_state "PAUSED"
    
    log_sys "Signal SIGUSR2 received. Daemon entering PAUSED state."
    
    # Only notify if we were previously ACTIVE.
    if [[ "$was_paused" == "false" ]]; then
        send_notification "Background sync PAUSED."
    fi
    
    # Kill the current sleep process to force an immediate loop iteration.
    pkill -P $$ sleep 2>/dev/null
    PROCESSING_SIGNAL=false
}

# cleanup_daemon: Ensures all child processes (like the monitor) are killed on exit.
cleanup_daemon() {
    log_sys "Daemon shutting down. Cleaning up resources..."
    [[ -n "$MONITOR_PID" ]] && kill "$MONITOR_PID" 2>/dev/null
    [[ -n "$DBUS_FD" ]] && exec {DBUS_FD}<&-
    rm -f "$DAEMON_PID_FILE" "$DAEMON_STATE_FILE"
    exit 0
}

trap 'resume_daemon' SIGUSR1
trap 'pause_daemon' SIGUSR2
trap 'cleanup_daemon' SIGTERM SIGINT

# --- 2.3. Desktop Notification Helper ---
# Ensures notifications work even when running as a systemd user service.
send_notification() {
    local msg="$1"
    local user_id=$(id -u)
    local dbus_address="unix:path=/run/user/$user_id/bus"
    
    # Method: Direct D-Bus call with CRITICAL urgency (byte 2) to force a pop-up banner.
    if command -v gdbus >/dev/null 2>&1; then
        if gdbus call --address "$dbus_address" \
                      --dest org.freedesktop.Notifications \
                      --object-path /org/freedesktop/Notifications \
                      --method org.freedesktop.Notifications.Notify \
                      "bw-env" 0 "security-high" "🛡️ BW-ENV" "$msg" \
                      "[]" "{'urgency': <byte 2>}" 10000 >/dev/null 2>&1; then
            log_sys "Critical desktop notification sent via gdbus."
            return 0
        fi
    fi

    # Fallback to notify-send with critical urgency.
    if command -v notify-send >/dev/null 2>&1; then
        DBUS_SESSION_BUS_ADDRESS="$dbus_address" DISPLAY=":0" notify-send -u critical "🛡️ BW-ENV" "$msg" >/dev/null 2>&1
        log_sys "Critical desktop notification attempted via notify-send (fallback)."
    fi
}

# --- 3. System Signal Listener (The Ear) ---
# The monitor ONLY sends signals to the parent daemon. It NEVER calls main.sh directly.
# We use process substitution to avoid subshell pipes that can cause accidental exits.
function start_dbus_monitor() {
    if ! command -v dbus-monitor >/dev/null 2>&1; then
        log_err "dbus-monitor not found. Automatic security features will be unavailable."
        return 1
    fi

    log_sys "Starting D-Bus monitor..."
    
    # Launch dbus-monitor in the background and read its output line by line.
    # Note: --system BecomeMonitor is denied for user services; dbus-monitor falls back
    # to eavesdropping which delivers identical signals. Redirect stderr to suppress the
    # cosmetic AccessDenied startup message.
    exec {DBUS_FD}< <(dbus-monitor --system \
        "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" \
        "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',arg0='org.freedesktop.login1.Session'" \
        2>/dev/null)
    
    (
        local current_signal=""
        while IFS= read -r line <&$DBUS_FD; do
            case "$line" in
                *member=PrepareForSleep*)   current_signal="sleep" ;;
                *member=PropertiesChanged*) current_signal="session" ;;
                *LockedHint*)               [[ "$current_signal" == "session" ]] && current_signal="locked_hint" ;;
            esac

            case "$current_signal" in
                sleep|locked_hint)
                    case "$line" in
                        *"boolean true"*)
                            log_sys "D-Bus: Security event (Sleep/Lock) detected. Forcing RAM purge and Pause."
                            get_graphical_env
                            "$UTILS_DIR/main.sh" lock --daemon
                            kill -SIGUSR2 $DAEMON_PID
                            current_signal=""
                            ;;
                        *"boolean false"*)
                            log_sys "D-Bus: System event (Wake/Unlock) detected. Debouncing..."
                            # Wait for the graphical session to be fully ready.
                            sleep "${WAKE_DEBOUNCE_DELAY:-2}"
                            if config_flag_enabled "${AUTO_START_ON_WAKE:-false}"; then
                                kill -SIGUSR1 $DAEMON_PID
                            else
                                log_sys "AUTO_START_ON_WAKE=false. Daemon remains PAUSED after wake."
                            fi
                            current_signal=""
                            ;;
                    esac
                    ;;
            esac
        done
    ) &
    MONITOR_PID=$!
    log_sys "System monitoring active (PID: $MONITOR_PID)."
}

start_dbus_monitor

# --- 3.5. Graphical Session Readiness Check ---
# At boot, the daemon starts before the graphical session (DISPLAY/D-Bus) is ready.
# This function blocks until the D-Bus user socket exists, ensuring Zenity can appear.
wait_for_graphical_session() {
    local user_id; user_id=$(id -u)
    local dbus_socket="/run/user/$user_id/bus"
    local max_wait="${GRAPHICAL_WAIT_MAX:-60}"
    local step=2
    local waited=0

    log_sys "Waiting for graphical session (D-Bus socket: $dbus_socket)..."
    while [[ $waited -lt $max_wait ]]; do
        if [[ -S "$dbus_socket" ]]; then
            export DBUS_SESSION_BUS_ADDRESS="unix:path=$dbus_socket"
            export DISPLAY="${DISPLAY:-:0}"
            log_sys "Graphical session ready after ${waited}s."
            return 0
        fi
        sleep $step
        waited=$(( waited + step ))
    done
    log_sys "Timeout (${max_wait}s): graphical session not detected. Proceeding anyway."
    return 1
}

# --- 4. Initial Boot/Login Sync ---
# Request secrets immediately on daemon startup only when auto-start on boot is enabled.
if config_flag_enabled "${AUTO_START_ON_BOOT:-true}"; then
    # Wait for the graphical session before attempting Zenity-based unlock.
    wait_for_graphical_session
    log_sys "Daemon startup: Performing initial environment synchronization."
    if "$UTILS_DIR/main.sh" sync --daemon; then
        log_sys "Initial synchronization successful. Daemon is ACTIVE."
        PAUSED=false
        update_daemon_state "ACTIVE"
    else
        EXIT_CODE=$?
        log_sys "Initial synchronization failed (Code $EXIT_CODE). Daemon starting in PAUSED state."
        PAUSED=true
        update_daemon_state "PAUSED"
        send_notification "Background sync PAUSED. Initial synchronization failed."
    fi
else
    log_sys "AUTO_START_ON_BOOT=false. Daemon starting in PAUSED state without initial sync."
    PAUSED=true
    update_daemon_state "PAUSED"
fi

# --- 5. Main Synchronization Loop (The Clock) ---
log_sys "Background synchronization loop starting (Interval: ${CHECK_INTERVAL:-300}s)."

while true; do
    log_sys "Loop iteration started. State: PAUSED=$PAUSED"
    prune_subscribers
    
    # 5.1. Monitor Supervision: Ensure the security guard is always alive.
    if [[ -z "$MONITOR_PID" ]] || ! kill -0 "$MONITOR_PID" 2>/dev/null; then
        log_sys "D-Bus monitor not running. Restarting security guard (auto-healing)..."
        start_dbus_monitor
    fi

    # 5.2. Periodic Synchronization
    if [[ "$PAUSED" == "false" ]]; then
        load_session
        if bw status | grep -q '"status":"unlocked"'; then
            log_sys "Periodic sync: Vault is unlocked. Refreshing..."
            if "$UTILS_DIR/main.sh" sync --daemon; then
                # SECURITY: Only set to ACTIVE if we haven't been paused in the meantime.
                [[ "$PAUSED" == "false" ]] && update_daemon_state "ACTIVE"
            fi
        else
            log_sys "Periodic sync: Vault is locked. Requesting unlock..."
            get_graphical_env
            if "$UTILS_DIR/main.sh" unlock --daemon; then
                # SECURITY: Only set to ACTIVE if we haven't been paused in the meantime.
                if [[ "$PAUSED" == "false" ]]; then
                    PAUSED=false
                    update_daemon_state "ACTIVE"
                fi
            else
                EXIT_CODE=$?
                if [[ $EXIT_CODE -eq "$EXIT_USER_CANCEL" ]] || [[ $EXIT_CODE -eq "$EXIT_MAX_ATTEMPTS" ]]; then
                    PAUSED=true
                    update_daemon_state "PAUSED"
                    send_notification "Background sync PAUSED. Manual unlock required."
                fi
            fi
        fi
    fi
    
    # 5.3. Wait for next cycle.
    # We use 'sleep & wait' to ensure signals (SIGUSR1/SIGUSR2) are handled INSTANTLY.
    # The '|| true' ensures the loop continues if wait is interrupted by a signal.
    sleep "${CHECK_INTERVAL:-300}" &
    wait $! || true
done
