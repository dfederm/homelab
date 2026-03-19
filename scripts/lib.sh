#!/bin/bash
# Shared helper functions for homelab scripts.
# Source this file; do not execute directly.

# Validate that all named env vars are set and non-empty.
# Supports indirect variable names (e.g. dynamically constructed names).
#
# Usage: validate_env "MY_VAR" "OTHER_VAR"
validate_env() {
    for var in "$@"; do
        if [ -z "${!var:-}" ]; then
            echo "ERROR: $var must be set" >&2
            exit 1
        fi
    done
}

# Resolve the env file and config directory, then source common.env
# (shared vars) followed by the machine-specific env file (overrides).
# Creates /etc/homelab.env symlink so future runs need no arguments.
#
# Sets: ENV_FILE, CONFIG_DIR (exported)
# Sources: common.env (if exists), then machine env file
#
# Resolution order for env file:
#   1. CONFIG_DIR env var + hostname (inside webhook container)
#   2. /etc/homelab.env symlink (subsequent runs)
#   3. <repo>/../config/<hostname>.env (first run, derived from REPO_DIR)
#
# Usage: source_env
source_env() {
    local system_env="/etc/homelab.env"
    local hostname
    hostname=$(hostname)

    if [ -n "${CONFIG_DIR:-}" ] && [ -f "$CONFIG_DIR/${hostname}.env" ]; then
        ENV_FILE="$CONFIG_DIR/${hostname}.env"
    elif [ -f "$system_env" ]; then
        ENV_FILE=$(readlink -f "$system_env")
    elif [ -n "${REPO_DIR:-}" ] && [ -f "$REPO_DIR/../config/${hostname}.env" ]; then
        ENV_FILE="$REPO_DIR/../config/${hostname}.env"
    else
        echo "ERROR: No env file found for ${hostname}." >&2
        echo "  Tried: $system_env" >&2
        [ -n "${REPO_DIR:-}" ] && echo "  Tried: $REPO_DIR/../config/${hostname}.env" >&2
        return 1
    fi

    CONFIG_DIR=$(dirname "$(realpath "$ENV_FILE")")
    export ENV_FILE CONFIG_DIR

    # Create system symlink on first run so future runs use the fast path
    local real_env
    real_env=$(realpath "$ENV_FILE")
    if [ ! -f "$system_env" ] || [ "$(readlink -f "$system_env")" != "$real_env" ]; then
        ln -sf "$real_env" "$system_env"
    fi

    local common_env="$CONFIG_DIR/common.env"
    if [ -f "$common_env" ]; then
        # shellcheck disable=SC1090
        source "$common_env"
    fi
    # shellcheck disable=SC1090
    source "$ENV_FILE"
}
