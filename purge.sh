#!/usr/bin/env bash
# === BW-ENV UNINSTALLER (purge.sh) ===
# Reverses install.sh: stops + removes systemd services, removes the CLI wrapper,
# removes shell integration from ~/.kshrc, wipes RAM bridges, and optionally
# removes the installed files.
#
# Usage:
#   ./purge.sh                — interactive (prompts before each destructive step)
#   ./purge.sh -y             — silent mode (all defaults, no y/n prompts)
#   ./purge.sh /install/path  — target a specific install dir
#   ./purge.sh -y /path       — silent + explicit path
#
# This script does NOT touch the bw-env source repository (~/Work/sh/bw_env/).
# It only removes the installed artefacts (wrapper, services, .env, install dir).

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
readonly WRAPPER_PATH="${_BW_WRAPPER_PATH:-$HOME/.local/bin/bw-env}"
readonly SYSTEMD_DIR="${_BW_SYSTEMD_DIR:-$HOME/.config/systemd/user}"
readonly SYNC_SERVICE="$SYSTEMD_DIR/bw-env-sync.service"
readonly TRAY_SERVICE="$SYSTEMD_DIR/bw-env-tray.service"
readonly KSHRC="${_BW_KSHRC:-$HOME/.kshrc}"

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo "  ℹ️  $*"; }
ok()      { echo "  ✅  $*"; }
warn()    { echo "  ⚠️  $*"; }
err()     { echo "  ❌  $*" >&2; }
section() { echo; echo "─── $* ───────────────────────────────────────────"; }

ask_yn() {
    local prompt="$1" default="${2:-n}"
    local hint
    [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    read -r -p "  $prompt $hint  " answer
    answer="${answer:-$default}"
    [[ "${answer,,}" =~ ^y(es)?$ ]]
}

# ── Argument parsing ──────────────────────────────────────────────────────────
YES_MODE=false
INSTALL_DIR=""

for arg in "$@"; do
    case "$arg" in
        -y|--yes) YES_MODE=true ;;
        -*) err "Unknown flag: $arg"; exit 1 ;;
        *) INSTALL_DIR="$arg" ;;
    esac
done

# ── Auto-detect install dir if not provided ───────────────────────────────────
if [[ -z "$INSTALL_DIR" ]]; then
    # Try to derive from the running wrapper.
    if [[ -f "$WRAPPER_PATH" ]]; then
        _detected=$(grep -oE '"[^"]+/main\.sh"' "$WRAPPER_PATH" 2>/dev/null | tr -d '"' | sed 's|/main\.sh$||')
        if [[ -n "$_detected" && -d "$_detected" ]]; then
            INSTALL_DIR="$_detected"
        fi
    fi
    # Default fallback.
    INSTALL_DIR="${INSTALL_DIR:-$HOME/.bw_env}"
fi

# ── Banner ────────────────────────────────────────────────────────────────────
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║         BW-ENV UNINSTALLER  🗑️                       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo
info "Target install dir : $INSTALL_DIR"
info "Wrapper            : $WRAPPER_PATH"
info "Systemd dir        : $SYSTEMD_DIR"
[[ "$YES_MODE" == "true" ]] && info "Running in silent mode (-y)."

if [[ "$YES_MODE" == "false" ]]; then
    echo
    echo "  This will remove bw-env from your system."
    echo "  Your source repository (~/Work/sh/bw_env/) will NOT be touched."
    echo
    ask_yn "Continue?" "n" || { info "Aborted."; exit 0; }
fi

# ── Step 1: Wipe RAM bridges ──────────────────────────────────────────────────
section "1 · Wipe RAM Bridges"

# Derive RAM bridge paths from the installed .env when available.
# Falling back to $USER-based defaults only avoids wiping a different user's
# bridges — critical for correct behaviour when testing in sandboxed environments.
_env_file="$INSTALL_DIR/.env"
_load_env_path() {
    local key="$1" default="$2"
    if [[ -f "$_env_file" ]]; then
        local raw
        raw=$(grep -E "^${key}=" "$_env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
        # Expand $HOME and $USER in the value.
        raw="${raw//\$HOME/$HOME}"
        raw="${raw//\$USER/$USER}"
        echo "${raw:-$default}"
    else
        echo "$default"
    fi
}

_ram_files=(
    "$(_load_env_path TEMP_ENV            "/dev/shm/bw-${USER}.env")"
    "$(_load_env_path SESSION_FILE         "/dev/shm/bw-session-${USER}")"
    "$(_load_env_path GPG_BRIDGE_FILE      "/dev/shm/bw-gpg-${USER}")"
    "$(_load_env_path LOCK_FILE            "/dev/shm/bw-env-${USER}.lock")"
    "$(_load_env_path DAEMON_PID_FILE      "/dev/shm/bw-env-daemon-${USER}.pid")"
    "$(_load_env_path DAEMON_STATE_FILE    "/dev/shm/bw-env-daemon-${USER}.state")"
    "$(_load_env_path LAST_SYNC_FILE       "/dev/shm/bw-env-${USER}.lastsync")"
    "$(_load_env_path KEYS_REGISTRY        "/dev/shm/bw-keys-${USER}.list")"
    "$(_load_env_path SUBS_REGISTRY_INTERACTIVE    "/dev/shm/bw-subs-interactive-${USER}.list")"
    "$(_load_env_path SUBS_REGISTRY_NON_INTERACTIVE "/dev/shm/bw-subs-noninteractive-${USER}.list")"
    "/dev/shm/bw-env-tray-${USER}.pid"
)
_wiped=0
for f in "${_ram_files[@]}"; do
    if [[ -f "$f" ]]; then
        # Overwrite before removal to prevent recovery from memory-mapped artefacts.
        dd if=/dev/urandom of="$f" bs=1 count="$(wc -c < "$f")" conv=notrunc &>/dev/null || true
        rm -f "$f"
        (( _wiped++ )) || true
    fi
done
ok "$_wiped RAM bridge file(s) wiped."

# ── Step 2: Stop and remove systemd services ──────────────────────────────────
section "2 · Systemd Services"
_remove_service() {
    local svc_file="$1" svc_name
    svc_name="$(basename "$svc_file")"
    if "${_BW_SYSTEMCTL:-systemctl}" --user is-active "$svc_name" &>/dev/null; then
        "${_BW_SYSTEMCTL:-systemctl}" --user stop "$svc_name" && info "Stopped $svc_name."
    fi
    if "${_BW_SYSTEMCTL:-systemctl}" --user is-enabled "$svc_name" &>/dev/null; then
        "${_BW_SYSTEMCTL:-systemctl}" --user disable "$svc_name" && info "Disabled $svc_name."
    fi
    if [[ -f "$svc_file" ]]; then
        rm -f "$svc_file"
        ok "Removed $svc_file"
    else
        info "$svc_name service file not found — skipping."
    fi
}
_remove_service "$TRAY_SERVICE"
_remove_service "$SYNC_SERVICE"
"${_BW_SYSTEMCTL:-systemctl}" --user daemon-reload 2>/dev/null || true

# ── Step 3: Remove CLI wrapper ────────────────────────────────────────────────
section "3 · CLI Wrapper"
if [[ -f "$WRAPPER_PATH" ]]; then
    rm -f "$WRAPPER_PATH"
    ok "Removed $WRAPPER_PATH"
else
    info "Wrapper not found at $WRAPPER_PATH — skipping."
fi

# ── Step 4: Remove shell integration from ~/.kshrc ────────────────────────────
section "4 · Shell Integration"
if [[ -f "$KSHRC" ]] && grep -qE "bw.env/shell\.sh" "$KSHRC" 2>/dev/null; then
    # Remove the comment line and the source line as a pair.
    sed -i '/# bw-env shell integration (added by install.sh)/d' "$KSHRC"
    sed -i '\|bw.env/shell\.sh|d' "$KSHRC"
    # Also remove any trailing blank lines that were added before the block.
    ok "Shell integration removed from $KSHRC"
    warn "Reload your shell to deactivate the bw-env function: source $KSHRC"
else
    info "No bw-env integration found in $KSHRC — skipping."
fi

# ── Step 5: Remove installed files ────────────────────────────────────────────
section "5 · Installed Files"
if [[ -d "$INSTALL_DIR" ]]; then
    _do_remove=false
    if [[ "$YES_MODE" == "true" ]]; then
        _do_remove=true
    else
        if ask_yn "Remove install directory $INSTALL_DIR (including .env and GPG cache)?" "n"; then
            _do_remove=true
        fi
    fi
    if [[ "$_do_remove" == "true" ]]; then
        # Wipe .env and GPG cache with zeroes before deletion.
        [[ -f "$INSTALL_DIR/.env" ]] && \
            dd if=/dev/zero of="$INSTALL_DIR/.env" bs=1 count="$(wc -c < "$INSTALL_DIR/.env")" conv=notrunc &>/dev/null || true
        _gpg_cache="$INSTALL_DIR/.bw/env/cache.env.gpg"
        [[ -f "$_gpg_cache" ]] && \
            dd if=/dev/urandom of="$_gpg_cache" bs=1024 count=1 conv=notrunc &>/dev/null || true
        rm -rf "$INSTALL_DIR"
        ok "Removed $INSTALL_DIR"
    else
        info "Skipped removal of $INSTALL_DIR (manual cleanup: rm -rf $INSTALL_DIR)"
    fi
else
    info "Install directory $INSTALL_DIR not found — skipping."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✅  BW-ENV UNINSTALL COMPLETE                       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo
info "bw-env has been removed from your system."
info "Source repository ~/Work/sh/bw_env/ was NOT touched."
info "To reinstall: cd ~/Work/sh/bw_env && ./install.sh"
echo
