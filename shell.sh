#!/usr/bin/env bash
# === BW-ENV SHELL INTEGRATION ===
# Purpose: Shell-agnostic integration layer for bw-env (Bash + Zsh).
# Sourced by ~/.kshrc to keep the Universal Hub clean.
# Provides: bw-env wrapper with shell-side subcommands (get, drop).

# bw-env: Unified entry point — delegates to main.sh or handles shell-side ops locally.
bw-env() {
    local _load="$HOME/Work/sh/bw-env/load.sh"
    local _main="$HOME/Work/sh/bw-env/main.sh"
    case "$1" in
        # Shell-side only: must run in the current shell process to affect its environment.
        get)
            # Inject secrets into this terminal and register as subscriber.
            # Bypasses load.sh UTILS_DIR auto-detection (unreliable from inside a Zsh function).
            local _dir="$HOME/Work/sh/bw-env"
            if [[ ! -f "$_dir/utils.sh" || ! -f "$_dir/.env" ]]; then
                echo "❌ [bw-env] Missing files in $_dir"; return 1
            fi
            source "$_dir/utils.sh"
            source "$_dir/.env"
            if [[ -f "$TEMP_ENV" ]]; then
                # Wipe stale keys (removed from vault since last injection) before re-sourcing.
                if [[ -f "$KEYS_REGISTRY" ]]; then
                    while read -r _key; do
                        [[ -n "$_key" ]] && unset "$_key"
                    done < "$KEYS_REGISTRY"
                fi
                source "$TEMP_ENV"
                register_subscriber
                # Trap SIGUSR1: auto-refresh when a sync broadcasts from another shell/daemon.
                # Falls back to manual 'bw-env get' if broadcast was missed.
                trap '_bw_d="$HOME/Work/sh/bw-env"; source "$_bw_d/utils.sh" 2>/dev/null; source "$_bw_d/.env" 2>/dev/null; [[ -f "$KEYS_REGISTRY" ]] && while read -r _k; do [[ -n "$_k" ]] && unset "$_k"; done < "$KEYS_REGISTRY"; [[ -f "$TEMP_ENV" ]] && { source "$TEMP_ENV"; echo "🔄 [bw-env] Shell [$$] secrets refreshed."; }' SIGUSR1
                echo "✅ [bw-env] Shell [$$] secrets injected and registered."
            else
                echo "⚠️  [bw-env] No secrets in RAM. Run 'bw-env unlock' first."
                return 1
            fi
            ;;
        drop)
            # Wipe secrets from this terminal and remove it from the subscriber list.
            # wipe_shell_env already prints its own security alert — no extra echo needed.
            if type wipe_shell_env &>/dev/null; then
                wipe_shell_env
            else
                echo "⚠️  [bw-env] wipe_shell_env not available — secrets may still be in scope."
            fi
            if type remove_subscriber &>/dev/null; then
                remove_subscriber
            fi
            # Unset BW_ENV_LOADED (PID-scoped guard) so that sourcing ~/.kshrc
            # again in this shell (e.g. after 'bw-env get') will re-run load.sh.
            # drop intentionally leaves TEMP_ENV intact — fresh login shells must
            # still be able to read secrets from it.
            unset BW_ENV_LOADED
            ;;
        *)
            # Delegate all other subcommands to main.sh (runs in a subprocess).
            bash "$_main" "$@"
            local ret=$?
            # Successful unlock/sync -> inject secrets into this shell immediately.
            # WHY not source "$_load": load.sh uses ${(%):-%x} to detect its own path,
            # which is unreliable when sourced from inside a Zsh function (gives caller
            # path instead of load.sh path → UTILS_DIR wrong → TEMP_ENV never resolved).
            # Fix: use the same direct-path pattern already proven in the 'get' case.
            if [[ $ret -eq 0 ]]; then
                case "$1" in
                    unlock|sync)
                        local _dir="$HOME/Work/sh/bw-env"
                        local _already_registered=0
                        if [[ -f "$_dir/utils.sh" && -f "$_dir/.env" ]]; then
                            source "$_dir/utils.sh"
                            source "$_dir/.env"
                            local _registry
                            _registry=$(current_subscriber_registry)
                            if [[ -n "$_registry" ]] && grep -q "^$$\$" "$_registry" 2>/dev/null; then
                                _already_registered=1
                            fi
                            if [[ -f "$TEMP_ENV" ]]; then
                                source "$TEMP_ENV"
                                register_subscriber
                                if [[ $_already_registered -eq 0 ]]; then
                                    echo "✅ [bw-env] Shell [$$] secrets auto-injected after '$1'."
                                fi
                            fi
                        fi
                        ;;
                esac
            fi
            # Lock/purge -> trigger local shell revocation via SIGUSR2 trap.
            if [[ "$1" == "lock" || "$1" == "purge" ]]; then
                kill -SIGUSR2 $$ 2>/dev/null
            fi
            return $ret
            ;;
    esac
}

# Load secrets at shell startup.
# Guard: PID-scoped idempotency — prevents double sourcing WITHIN the same shell
# process (e.g. when .zprofile and .zshrc both source .kshrc in a login+interactive
# shell), while ensuring every new child process sources secrets independently.
#
# Why PID and not a fixed value (=1):
#   A fixed exported value is inherited by all descendants, permanently blocking
#   load.sh in any subprocess spawned by an existing session (MCP zsh -l -c,
#   new terminal tabs, tool scripts…). With the PID, an inherited value always
#   differs from the child's own $$, so the guard is transparent to children.
#
# BW_ENV_LOADED is NOT exported — belt-and-suspenders on top of the PID check.
if [[ -z "$BW_ENV_LOADED" ]] || [[ "$BW_ENV_LOADED" != "$$" ]]; then
    [[ -f "$HOME/Work/sh/bw-env/load.sh" ]] && source "$HOME/Work/sh/bw-env/load.sh"
    BW_ENV_LOADED=$$
fi
