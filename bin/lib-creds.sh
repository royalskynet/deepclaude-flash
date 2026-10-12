#!/usr/bin/env bash
# Shared cred loader for bin/deepclaude and bin/deepclaude-proxyd. Source, don't exec.
# Prefers the sandbox-readable kv mirror (~/.creds/kv/<VAR>.txt); falls back to the
# provider env file (~/.creds/<provider>/env, `export VAR=...` style). Missing key is
# not an error here — the backend that actually needs it reports that at use time.
load_cred() {
    local var="$1" provider="$2"
    local kv="$HOME/.creds/kv/$var.txt"
    if [[ -f "$kv" ]]; then
        export "$var"="$(<"$kv")"
    elif [[ -f "$HOME/.creds/$provider/env" ]]; then
        . "$HOME/.creds/$provider/env"
    fi
}
