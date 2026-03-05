#!/bin/bash
# === BW-ENV SHELL BRIDGE ===
# Logic: Fast shell environment loading from RAM.
# Purpose: This script is sourced by shell profiles (e.g., .zshrc, .kshrc).
# Compatibility: Designed for both Bash and Zsh.

# --- 1. Robust Initialization ---
# Universal path detection for sourced scripts (works in Bash and Zsh).
if [ -n "$ZSH_VERSION" ]; then
    UTILS_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
else
    UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Verify the presence of the utility library.
if [[ -f "$UTILS_DIR/utils.sh" ]]; then
    source "$UTILS_DIR/utils.sh"
    load_config # Dynamically loads ITEM_ID, AUTHORIZED_USER, etc.
else
    logger -t "bw-env-load" "[ERR] Critical failure: utils.sh missing at $UTILS_DIR"
    return 1 2>/dev/null || exit 1
fi

# --- 2. Immediate Security Setup ---
# wipe_shell_env: Reactive function triggered by SIGUSR2 to purge secrets from this shell.
wipe_shell_env() {
    if [[ -n "$KEYS_REGISTRY" ]] && [[ -f "$KEYS_REGISTRY" ]]; then
        while read -r key; do
            [[ -n "$key" ]] && unset "$key"
        done < "$KEYS_REGISTRY"
        [[ -t 1 ]] && echo -e "\n⚠️ [bw-env] Security Alert: Environment secrets revoked and purged from this shell."
        log_sys "Shell [PID $$] environment successfully revoked."
        unset KEYS_REGISTRY
    fi
}

# Set up reactive traps immediately to ensure protection.
trap 'wipe_shell_env' SIGUSR2
trap 'remove_subscriber' EXIT

# --- 3. Identity & Context Protection ---
# Security check: Only load secrets if the current user matches the authorized owner.
# Context check: Skip automatic loading if an SSH session is detected.
if [[ "$USER" != "$AUTHORIZED_USER" ]] || [[ -n "$SSH_CLIENT" || -n "$SSH_TTY" || -n "$SSH_CONNECTION" ]]; then
    unset UTILS_DIR AUTHORIZED_USER
    return 0
fi

# --- 4. Shell Deployment ---
# If secrets are in RAM, inject them into the current terminal.
if [[ -f "$TEMP_ENV" ]]; then
    source "$TEMP_ENV" || log_err "Sourcing failed for RAM cache at $TEMP_ENV"
    # Register this shell for global revocation support.
    register_subscriber
else
    # If secrets are missing, notify the user without blocking the shell startup.
    if [[ -t 1 ]]; then
        echo "ℹ️ [bw-env] Bitwarden secrets are locked. Run 'bw-env unlock' to load."
    fi
    log_sys "Shell startup: Secrets missing in RAM. Skipping injection."
fi

# --- 5. Environment Sanitization ---
# 🧹 DYNAMIC CLEANUP: Remove internal configuration variables from the shell scope.
# We preserve KEYS_REGISTRY as it is needed for the reactive revocation trap.
if [[ -f "$UTILS_DIR/.env" ]]; then
    for var in $(grep -E '^[A-Z_]+=' "$UTILS_DIR/.env" | cut -d= -f1); do
        [[ "$var" == "KEYS_REGISTRY" ]] && continue
        unset "$var"
    done
fi

# Final cleanup of bootstrap variables.
unset UTILS_DIR var AUTHORIZED_USER
# Note: 'load_config' and 'log_*' functions remain in the shell for 'bw-env' command support.
