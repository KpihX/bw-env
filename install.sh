#!/usr/bin/env bash
# === BW-ENV INSTALLER ===
# Installs bw-env: copies source files, configures .env, wires systemd services,
# and optionally installs the GUI tray integration.
#
# Usage:
#   ./install.sh              — interactive (prompts for path, item ID, GUI choice)
#   ./install.sh -y           — default install ($HOME/.bw-env, skips all y/n prompts)
#   ./install.sh /some/base   — install to /some/base/paths/bw-env (interactive for the rest)
#   ./install.sh -y /some/base — full-default install to /some/base/paths/bw-env
#
# Dependencies (auto-detected, install instructions printed if missing):
#   Required:  bw (Bitwarden CLI), jq, gpg, openssl
#   GUI tray:  python3, python3-gi, gir1.2-ayatanaappindicator3-0.1, zenity

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BW_ENV_FILES=(
    main.sh sync-daemon.sh utils.sh load.sh shell.sh profile.sh
    .env.example README.md CHANGELOG.md
)
readonly GUI_FILES=(gui/tray.sh gui/tray_app.py gui/control_center.py)
readonly WRAPPER_PATH="$HOME/.local/bin/bw-env"
readonly SYSTEMD_DIR="$HOME/.config/systemd/user"
readonly SYNC_SERVICE="$SYSTEMD_DIR/bw-env-sync.service"
readonly TRAY_SERVICE="$SYSTEMD_DIR/bw-env-tray.service"

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo "  ℹ️  $*"; }
ok()      { echo "  ✅  $*"; }
warn()    { echo "  ⚠️  $*"; }
err()     { echo "  ❌  $*" >&2; }
section() { echo; echo "─── $* ───────────────────────────────────────────"; }

ask_yn() {
    # ask_yn <prompt> <default: y|n>
    # Returns 0 (yes) or 1 (no).
    local prompt="$1" default="${2:-n}"
    local hint
    [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    read -r -p "  $prompt $hint  " answer
    answer="${answer:-$default}"
    [[ "${answer,,}" =~ ^y(es)?$ ]]
}

ask_value() {
    # ask_value <prompt> <default>
    # Prints the chosen value to stdout.
    local prompt="$1" default="$2"
    read -r -p "  $prompt [$default]  " value
    echo "${value:-$default}"
}

require_cmd() {
    local cmd="$1" hint="${2:-install $1}"
    if ! command -v "$cmd" &>/dev/null; then
        err "Missing required command: $cmd"
        warn "  → $hint"
        return 1
    fi
}

# ── Argument parsing ──────────────────────────────────────────────────────────
YES_MODE=false
BASE_PATH=""

for arg in "$@"; do
    case "$arg" in
        -y|--yes) YES_MODE=true ;;
        -*) err "Unknown flag: $arg"; exit 1 ;;
        *) BASE_PATH="$arg" ;;
    esac
done

# ── Banner ────────────────────────────────────────────────────────────────────
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║         BW-ENV INSTALLER  🔐                         ║"
echo "║  Bitwarden-backed RAM secret manager                 ║"
echo "╚══════════════════════════════════════════════════════╝"
echo
[[ "$YES_MODE" == "true" ]] && info "Running in default mode (-y). All prompts use defaults."

# ── Step 1: Install bw CLI if missing ─────────────────────────────────────────
section "1 · Bitwarden CLI"
if command -v bw &>/dev/null; then
    ok "bw CLI found: $(command -v bw) ($(bw --version 2>/dev/null || echo 'unknown version'))"
else
    warn "bw CLI not found. Attempting install..."
    _installed_bw=false

    # Try npm first (cleanest, version-managed).
    if command -v npm &>/dev/null; then
        info "Installing via npm: npm install -g @bitwarden/cli"
        npm install -g @bitwarden/cli && _installed_bw=true
    fi

    # Fallback: download the official Linux x64 ZIP from Bitwarden GitHub releases.
    if [[ "$_installed_bw" == "false" ]] && command -v curl &>/dev/null && command -v unzip &>/dev/null; then
        info "Downloading official Bitwarden CLI binary..."
        _bw_zip="$(mktemp --suffix=.zip)"
        _bw_url="https://github.com/bitwarden/clients/releases/latest/download/bw-linux-x64.zip"
        if curl -fsSL "$_bw_url" -o "$_bw_zip"; then
            mkdir -p "$HOME/.local/bin"
            unzip -qo "$_bw_zip" -d "$HOME/.local/bin/"
            chmod +x "$HOME/.local/bin/bw"
            rm -f "$_bw_zip"
            _installed_bw=true
            info "Installed bw to $HOME/.local/bin/bw — ensure it is in your PATH."
        else
            rm -f "$_bw_zip"
        fi
    fi

    if [[ "$_installed_bw" == "false" ]]; then
        err "Could not install bw automatically."
        err "Manual install options:"
        err "  npm install -g @bitwarden/cli"
        err "  OR: snap install bw"
        err "  OR: download from https://bitwarden.com/download/"
        exit 1
    fi
    ok "bw CLI installed: $(command -v bw)"
fi

# ── Step 2: Check other required dependencies ─────────────────────────────────
section "2 · Dependencies"
_missing=0
require_cmd jq    "sudo apt install jq"            || (( _missing++ )) || true
require_cmd gpg   "sudo apt install gpg"           || (( _missing++ )) || true
require_cmd openssl "sudo apt install openssl"     || (( _missing++ )) || true
if (( _missing > 0 )); then
    err "$_missing required dependencies missing. Install them and re-run."
    exit 1
fi
ok "All required dependencies present."

# ── Step 3: Determine install directory ──────────────────────────────────────
section "3 · Install Location"
if [[ -n "$BASE_PATH" ]]; then
    INSTALL_DIR="$BASE_PATH/paths/bw-env"
    info "Base path provided → installing to: $INSTALL_DIR"
elif [[ "$YES_MODE" == "true" ]]; then
    INSTALL_DIR="$HOME/.bw-env"
    info "Default install path: $INSTALL_DIR"
else
    echo "  Where should bw-env be installed?"
    echo "  • Press Enter for default: $HOME/.bw-env"
    echo "  • Or enter a base path (bw-env will be placed in <path>/paths/bw-env)"
    read -r -p "  Path: " _user_path
    if [[ -n "$_user_path" ]]; then
        INSTALL_DIR="$_user_path/paths/bw-env"
    else
        INSTALL_DIR="$HOME/.bw-env"
    fi
fi
info "Install directory: $INSTALL_DIR"

# Warn if the source and install dirs are the same to avoid a no-op copy.
if [[ "$(realpath "$INSTALL_DIR" 2>/dev/null || echo "$INSTALL_DIR")" == \
      "$(realpath "$SCRIPT_DIR")" ]]; then
    warn "Install directory matches source directory — configuring in-place."
    _in_place=true
else
    _in_place=false
fi

# ── Step 4: Copy files ────────────────────────────────────────────────────────
section "4 · Copying Files"
if [[ "$_in_place" == "false" ]]; then
    mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/gui"
    for f in "${BW_ENV_FILES[@]}"; do
        src="$SCRIPT_DIR/$f"
        [[ -f "$src" ]] && cp "$src" "$INSTALL_DIR/$f" && info "Copied $f"
    done
    for f in "${GUI_FILES[@]}"; do
        src="$SCRIPT_DIR/$f"
        [[ -f "$src" ]] && cp "$src" "$INSTALL_DIR/$f" && info "Copied $f"
    done
    # Copy the service template for the tray (rewritten below anyway).
    [[ -f "$SCRIPT_DIR/gui/bw-env-tray.service" ]] && \
        cp "$SCRIPT_DIR/gui/bw-env-tray.service" "$INSTALL_DIR/gui/"
    # Make shell scripts executable.
    chmod +x "$INSTALL_DIR/"*.sh 2>/dev/null || true
    chmod +x "$INSTALL_DIR/gui/"*.sh 2>/dev/null || true
    chmod +x "$INSTALL_DIR/gui/"*.py 2>/dev/null || true
    ok "Files copied to $INSTALL_DIR"
else
    ok "In-place install — no copy needed."
fi

# ── Step 5: Configure .env ────────────────────────────────────────────────────
section "5 · Configuration (.env)"
ENV_FILE="$INSTALL_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
    if [[ "$YES_MODE" == "true" ]]; then
        warn ".env already exists — keeping it as-is (use -y to skip this check)."
    else
        if ! ask_yn ".env already exists. Reconfigure it?" "n"; then
            ok "Keeping existing .env."
            _skip_env=true
        else
            _skip_env=false
        fi
    fi
    _skip_env="${_skip_env:-true}"
else
    _skip_env=false
fi

if [[ "$_skip_env" == "false" ]]; then
    # Gather values.
    if [[ "$YES_MODE" == "true" ]]; then
        ITEM_ID=""
        warn "No ITEM_ID can be set in -y mode without a value. Edit $ENV_FILE manually."
    else
        echo "  Enter the Bitwarden item UUID that contains your API keys / secrets."
        echo "  (Find it with: bw list items --search 'GLOBAL_ENV_VARS' | jq '.[].id')"
        read -r -p "  Bitwarden Item ID: " ITEM_ID
        [[ -z "$ITEM_ID" ]] && warn "No item ID provided — you must set ITEM_ID in $ENV_FILE before using bw-env."
    fi

    # Generate a random INTERNAL_SALT for this installation.
    SALT="BW_ENV_$(openssl rand -hex 8 | tr '[:lower:]' '[:upper:]')"

    # Build .env from template, substituting only the user-specific values.
    # All other defaults from .env.example are preserved.
    cp "$INSTALL_DIR/.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    # Patch the values that must be customized.
    sed -i "s|^AUTHORIZED_USER=.*|AUTHORIZED_USER=\"$USER\"|"     "$ENV_FILE"
    sed -i "s|^ITEM_ID=.*|ITEM_ID=\"${ITEM_ID:-REPLACE_ME}\"|"   "$ENV_FILE"
    sed -i "s|^INTERNAL_SALT=.*|INTERNAL_SALT=\"$SALT\"|"         "$ENV_FILE"
    # Update CACHE_GPG path to use the actual install dir.
    sed -i "s|^CACHE_GPG=.*|CACHE_GPG=\"$INSTALL_DIR/.bw/env/cache.env.gpg\"|" "$ENV_FILE"

    mkdir -p "$INSTALL_DIR/.bw/env"
    chmod 700 "$INSTALL_DIR/.bw" "$INSTALL_DIR/.bw/env"

    ok ".env created at $ENV_FILE"
    info "AUTHORIZED_USER = $USER"
    info "INTERNAL_SALT   = $SALT (generated)"
    [[ -n "${ITEM_ID:-}" ]] && info "ITEM_ID         = $ITEM_ID" || \
        warn "ITEM_ID is empty — edit $ENV_FILE before running 'bw-env unlock'."
fi

# ── Step 6: Create ~/.local/bin/bw-env wrapper ───────────────────────────────
section "6 · CLI Wrapper"
mkdir -p "$HOME/.local/bin"
cat > "$WRAPPER_PATH" <<EOF
#!/bin/bash
# BW-ENV CLI wrapper — generated by install.sh
# Source: $INSTALL_DIR
exec bash "$INSTALL_DIR/main.sh" "\$@"
EOF
chmod +x "$WRAPPER_PATH"
ok "Wrapper created: $WRAPPER_PATH → $INSTALL_DIR/main.sh"

if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
    warn "\$HOME/.local/bin is not in your PATH."
    warn "Add this to your ~/.kshrc or ~/.zshrc:"
    warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# ── Step 7: Add shell integration to ~/.kshrc ─────────────────────────────────
section "7 · Shell Integration"
KSHRC="$HOME/.kshrc"
_shell_line="[ -f \"$INSTALL_DIR/shell.sh\" ] && source \"$INSTALL_DIR/shell.sh\""
_add_shell=false

if [[ -f "$KSHRC" ]]; then
    if grep -q "bw-env/shell.sh" "$KSHRC" 2>/dev/null; then
        warn "Shell integration already present in $KSHRC."
        if [[ "$YES_MODE" == "true" ]]; then
            warn "Skipping (use manual edit to update the path if needed)."
        else
            if ask_yn "Replace existing bw-env integration line with new path?" "n"; then
                # Remove old line and re-add.
                sed -i '\|bw-env/shell.sh|d' "$KSHRC"
                _add_shell=true
            fi
        fi
    else
        _add_shell=true
    fi
else
    _add_shell=true
fi

if [[ "$_add_shell" == "true" ]]; then
    echo "" >> "$KSHRC"
    echo "# bw-env shell integration (added by install.sh)" >> "$KSHRC"
    echo "$_shell_line" >> "$KSHRC"
    ok "Shell integration added to $KSHRC"
    info "Run 'source $KSHRC' or open a new terminal to activate."
fi

# ── Step 8: Systemd sync daemon ───────────────────────────────────────────────
section "8 · Systemd Sync Daemon"
mkdir -p "$SYSTEMD_DIR"
cat > "$SYNC_SERVICE" <<EOF
[Unit]
Description=Bitwarden Environment Variables Sync Daemon
After=network-online.target

[Service]
ExecStart=/bin/bash $INSTALL_DIR/sync-daemon.sh
Restart=on-failure
RestartSec=30s

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
if systemctl --user is-active bw-env-sync.service &>/dev/null; then
    warn "Daemon was running — restarting with new config."
    systemctl --user restart bw-env-sync.service
else
    systemctl --user enable --now bw-env-sync.service
fi
ok "bw-env-sync.service installed and started."
info "Logs: journalctl --user-unit bw-env-sync.service -f"

# ── Step 9: GUI tray (optional) ───────────────────────────────────────────────
section "9 · GUI Tray (optional)"
_install_gui=false
if [[ "$YES_MODE" == "true" ]]; then
    _install_gui=true
    info "Default mode: installing GUI tray."
else
    if ask_yn "Install the GUI tray integration (AppIndicator + control center)?" "y"; then
        _install_gui=true
    fi
fi

if [[ "$_install_gui" == "true" ]]; then
    info "Checking GUI dependencies..."
    _gui_ok=true

    # zenity — password prompts
    if ! command -v zenity &>/dev/null; then
        warn "zenity not found. Attempting: sudo apt install zenity"
        if command -v apt-get &>/dev/null; then
            sudo apt-get install -y zenity || { warn "zenity install failed — GUI prompts will fall back to TTY."; }
        else
            warn "Cannot auto-install zenity. Install it manually: sudo apt install zenity"
        fi
    else
        ok "zenity: $(command -v zenity)"
    fi

    # python3-gi and AppIndicator3 GIR
    _gi_check=$(python3 -c "import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk; print('ok')" 2>&1)
    if [[ "$_gi_check" != "ok" ]]; then
        warn "python3-gi / GTK3 not available. Attempting install..."
        if command -v apt-get &>/dev/null; then
            sudo apt-get install -y python3-gi python3-gi-cairo gir1.2-gtk-3.0 \
                gir1.2-ayatanaappindicator3-0.1 || _gui_ok=false
        else
            warn "Cannot auto-install. Run: sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1"
            _gui_ok=false
        fi
    else
        ok "python3-gi / GTK3 available."
    fi

    _indicator_check=$(python3 -c "import gi; gi.require_version('AyatanaAppIndicator3','0.1'); from gi.repository import AyatanaAppIndicator3; print('ok')" 2>&1)
    if [[ "$_indicator_check" != "ok" ]]; then
        warn "AyatanaAppIndicator3 not available."
        if command -v apt-get &>/dev/null; then
            sudo apt-get install -y gir1.2-ayatanaappindicator3-0.1 || _gui_ok=false
        fi
    else
        ok "AyatanaAppIndicator3 available."
    fi

    # Create tray systemd service pointing to INSTALL_DIR.
    cat > "$TRAY_SERVICE" <<EOF
[Unit]
Description=BW-ENV Tray Integration
After=graphical-session.target

[Service]
Type=simple
ExecStart=/bin/bash $INSTALL_DIR/gui/tray.sh start
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    if [[ "$_gui_ok" == "true" ]]; then
        systemctl --user enable --now bw-env-tray.service
        ok "bw-env-tray.service installed and started."
    else
        systemctl --user enable bw-env-tray.service
        warn "Tray service enabled but NOT started (missing dependencies)."
        warn "Fix the dependencies above, then run: systemctl --user start bw-env-tray.service"
    fi
else
    info "Skipping GUI tray installation."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✅  BW-ENV INSTALL COMPLETE                         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo
echo "  Install dir : $INSTALL_DIR"
echo "  CLI wrapper : $WRAPPER_PATH"
echo "  Config file : $ENV_FILE"
echo
echo "  Next steps:"
echo "  1. Edit $ENV_FILE — verify AUTHORIZED_USER and ITEM_ID."
echo "  2. Reload your shell:  source $KSHRC  (or open a new terminal)"
echo "  3. Unlock:  bw-env unlock"
echo "  4. Inject secrets into this terminal:  bw-env get"
echo "  5. Check status:  bw-env status"
echo
