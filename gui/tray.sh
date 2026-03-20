#!/usr/bin/env bash
# BW-ENV tray management wrapper.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRAY_APP="$ROOT_DIR/gui/tray_app.py"
CONTROL_CENTER="$ROOT_DIR/gui/control_center.py"
SERVICE_TEMPLATE="$ROOT_DIR/gui/bw-env-tray.service"
USER_SERVICE_DIR="$HOME/.config/systemd/user"
USER_SERVICE_FILE="$USER_SERVICE_DIR/bw-env-tray.service"
TRAY_PID_FILE="/dev/shm/bw-env-tray-$USER.pid"

have_user_systemd() {
    systemctl --user show-environment >/dev/null 2>&1
}

open_control_center() {
    nohup /usr/bin/python3 "$CONTROL_CENTER" >/tmp/bw-env-gui.log 2>&1 &
}

tray_pid() {
    [[ -f "$TRAY_PID_FILE" ]] || return 1
    cat "$TRAY_PID_FILE" 2>/dev/null
}

stop_manual_tray() {
    local pid
    pid=$(tray_pid 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$TRAY_PID_FILE"
}

start_manual_tray() {
    if [[ -n "${INVOCATION_ID:-}" ]]; then
        exec /usr/bin/python3 "$TRAY_APP"
    fi
    nohup /usr/bin/python3 "$TRAY_APP" >/tmp/bw-env-tray.log 2>&1 &
}

install_service() {
    mkdir -p "$USER_SERVICE_DIR"
    cp "$SERVICE_TEMPLATE" "$USER_SERVICE_FILE"
    if have_user_systemd; then
        systemctl --user daemon-reload
        systemctl --user enable --now bw-env-tray.service
        systemctl --user status bw-env-tray.service --no-pager -n 10
    else
        echo "Installed $USER_SERVICE_FILE"
        echo "User systemd bus not reachable from this context. Run manually:"
        echo "  systemctl --user daemon-reload"
        echo "  systemctl --user enable --now bw-env-tray.service"
    fi
}

case "${1:-start}" in
    start)
        if [[ -z "${INVOCATION_ID:-}" ]] && have_user_systemd && systemctl --user is-enabled bw-env-tray.service >/dev/null 2>&1; then
            systemctl --user start bw-env-tray.service
        else
            start_manual_tray
        fi
        ;;
    stop)
        if have_user_systemd && systemctl --user list-unit-files bw-env-tray.service >/dev/null 2>&1; then
            systemctl --user stop bw-env-tray.service 2>/dev/null || true
        fi
        stop_manual_tray
        ;;
    restart)
        if have_user_systemd && systemctl --user list-unit-files bw-env-tray.service >/dev/null 2>&1; then
            systemctl --user restart bw-env-tray.service
        else
            stop_manual_tray
            start_manual_tray
        fi
        ;;
    open)
        open_control_center
        ;;
    install)
        install_service
        ;;
    *)
        echo "Usage: tray.sh [start|stop|restart|open|install]" >&2
        exit 1
        ;;
esac
