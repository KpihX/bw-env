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

if [[ -f "$DAEMON_PID_FILE" ]]; then
    OLD_PID=$(cat "$DAEMON_PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        log_sys "Daemon already running (PID $OLD_PID). Exiting to prevent duplicate instance."
        exit 0
    else
        log_sys "Stale PID file found (PID $OLD_PID no longer exists). Overwriting."
    fi
fi
echo $$ > "$DAEMON_PID_FILE"
update_daemon_state "ACTIVE"

# --- 2.1. Signal Handling (IPC) ---
# PAUSED state: When true, the daemon stops prompting for passwords but keeps the D-Bus monitor alive.
PAUSED=false

# resume_daemon: Signal handler for SIGUSR1. Triggered by manual 'bw-env unlock' in a terminal.
resume_daemon() {
    log_sys "Signal SIGUSR1 received. Resuming background synchronization."
    PAUSED=false
    update_daemon_state "ACTIVE"
    send_notification "Background sync RESUMED. Manual unlock detected."
    # Kill the current sleep process to force an immediate loop iteration.
    pkill -P $$ sleep 2>/dev/null
}

# pause_daemon: Signal handler for SIGUSR2. Triggered by manual 'bw-env lock' in a terminal.
pause_daemon() {
    log_sys "Signal SIGUSR2 received. Daemon entering PAUSED state."
    PAUSED=true
    update_daemon_state "PAUSED"
    send_notification "Background sync PAUSED. Manual lock detected."
}

trap 'resume_daemon' SIGUSR1
trap 'pause_daemon' SIGUSR2
trap "rm -f '$DAEMON_PID_FILE' '$DAEMON_STATE_FILE'" EXIT

# --- 2.2. Desktop Notification Helper ---
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

# --- 3. System Signal Listener (The Guard) ---
# Listens for system-wide D-Bus signals indicating Sleep/Wake or Screen Lock/Unlock.
# Encapsulated in a function to allow supervised restarts.
function start_dbus_monitor() {
    if ! command -v dbus-monitor >/dev/null 2>&1; then
        log_err "dbus-monitor not found. Automatic security features will be unavailable."
        return 1
    fi

    (
        log_sys "D-Bus monitor process started."
        dbus-monitor --system \
            "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" \
            "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',arg0='org.freedesktop.login1.Session'" | \
        while IFS= read -r line; do
            case "$line" in
                *member=PrepareForSleep*)   current_signal="sleep" ;;
                *member=PropertiesChanged*) current_signal="session" ;;
                *LockedHint*)               [[ "$current_signal" == "session" ]] && current_signal="locked_hint" ;;
            esac

            case "$current_signal" in
                sleep|locked_hint)
                    case "$line" in
                        *"boolean true"*)
                            log_sys "Security event (Sleep/Lock on '$current_signal'). Initiating environment purge."
                            "$UTILS_DIR/main.sh" lock
                            current_signal=""
                            ;;
                        *"boolean false"*)
                            log_sys "System event (Wake/Unlock on '$current_signal'). Refreshing environment."
                            "$UTILS_DIR/main.sh" sync --daemon
                            current_signal=""
                            ;;
                    esac
                    ;;
            esac
        done
    ) &
    MONITOR_PID=$!
    log_sys "System monitoring active (PID: $MONITOR_PID): Sleep/Wake and Lock/Unlock detection enabled."
}

# Initial start of the monitor.
start_dbus_monitor

# --- 4. Initial Boot/Login Sync ---
# Ensure secrets are requested immediately upon daemon startup.
log_sys "Daemon startup: Performing initial environment synchronization."
"$UTILS_DIR/main.sh" sync --daemon
EXIT_CODE=$?
log_sys "Initial sync finished with Exit Code: $EXIT_CODE"

if [[ $EXIT_CODE -eq "$EXIT_USER_CANCEL" ]] || [[ $EXIT_CODE -eq "$EXIT_MAX_ATTEMPTS" ]]; then
    reason="User cancelled or skipped authentication."
    [[ $EXIT_CODE -eq "$EXIT_MAX_ATTEMPTS" ]] && reason="Maximum authentication attempts reached."
    
    log_sys "Initial authentication failed: $reason. Daemon entering PAUSED state."
    PAUSED=true
    update_daemon_state "PAUSED"
    send_notification "Background sync PAUSED: $reason. Manual unlock required."
fi

# --- 5. Main Synchronization Loop (The Clock) ---
log_sys "Background synchronization loop active (Interval: ${CHECK_INTERVAL:-300}s)."

while true; do
    # 5.1. Monitor Supervision: Ensure the security guard is always alive.
    if ! kill -0 "$MONITOR_PID" 2>/dev/null; then
        log_warn "D-Bus monitor process (PID: $MONITOR_PID) died unexpectedly. Restarting security guard..."
        start_dbus_monitor
    fi

    # 5.2. Pause Management
    if [[ "$PAUSED" == "true" ]]; then
        # Silent wait while paused.
        sleep "${CHECK_INTERVAL:-300}"
        continue
    fi

    # 5.3. Shared Authentication Management
    load_session
    load_gpg_key
    
    # 5.4. Status Check
    if bw status | grep -q '"status":"unlocked"'; then
        # Session is valid: Sync fresh data from the server.
        log_sys "Session active. Starting background sync cycle..."
        if ! "$UTILS_DIR/main.sh" sync --daemon; then
            log_sys "Background sync failed (likely network issue). Will retry in next cycle."
        fi
    else
        # Session is locked: The daemon attempts to re-establish the bridge.
        log_sys "Bitwarden session is locked. Requesting Master Unlock to resume background sync."
        "$UTILS_DIR/main.sh" unlock --daemon
        EXIT_CODE=$?
        log_sys "Authentication attempt finished with Exit Code: $EXIT_CODE"

        if [[ $EXIT_CODE -eq "$EXIT_USER_CANCEL" ]] || [[ $EXIT_CODE -eq "$EXIT_MAX_ATTEMPTS" ]]; then
            reason="User cancelled or skipped authentication."
            [[ $EXIT_CODE -eq "$EXIT_MAX_ATTEMPTS" ]] && reason="Maximum authentication attempts reached."
            
            log_sys "Authentication failed: $reason. Daemon entering PAUSED state to avoid spamming."
            PAUSED=true
            update_daemon_state "PAUSED"
            send_notification "Background sync PAUSED: $reason. Manual unlock required."
        fi
    fi
    
    # Wait for the next check interval using an interruptible wait.
    # This allows the daemon to process SIGUSR1/SIGUSR2 signals immediately.
    sleep "${CHECK_INTERVAL:-300}" &
    wait $!
done
