#!/usr/bin/env bash
# === BW-ENV Shell Profile Bundle ===
# Purpose: Shared shell bootstrap snippet sourced from ~/.kshrc.

# === BW-ENV Shell Integration ===
[ -f "$HOME/Work/sh/bw-env/shell.sh" ] && source "$HOME/Work/sh/bw-env/shell.sh"

PREPASS_ROOT=qi_DXjKgSAVFhWbK70-FV6ObZf9_N16lI6zjcg9bLgo

# === Node Version Manager (idempotent — safe to source multiple times) ===
if [ -z "$NVM_LOADED" ]; then
    export NVM_DIR="$HOME/.nvm"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # Source nvm but filter its cosmetic prefix= warning (we keep prefix= in .npmrc intentionally).
        # Technique: redirect stderr to temp file, source nvm normally (vars persist),
        # then replay stderr minus the known-harmless warning lines.
        _nvm_stderr=$(mktemp)
        \. "$NVM_DIR/nvm.sh" 2>"$_nvm_stderr"
        grep -v -E "incompatible with nvm|delete-prefix|globalconfig|\.npmrc file" \
            "$_nvm_stderr" >&2
        rm -f "$_nvm_stderr"
    fi
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
    nvm use default --silent 2>/dev/null
    export NVM_LOADED=1
fi
