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

# Ensure a kernel module is loaded now and on every boot (via /etc/modules).
# Idempotent: only appends to /etc/modules when the module isn't listed.
#
# Returns non-zero (after warning) if the module still isn't loaded afterwards,
# so callers can report degraded state instead of silently continuing. Callers
# running under `set -e` must handle that explicitly.
#
# Usage: ensure_kernel_module "amdgpu"
ensure_kernel_module() {
    local kmod="$1"

    # Match the module name as its own field — /etc/modules lines may carry
    # trailing module parameters.
    if grep -qE "^[[:space:]]*${kmod}([[:space:]]|$)" /etc/modules 2>/dev/null; then
        echo "  $kmod already in /etc/modules"
    else
        # A file whose last line is unterminated would otherwise absorb the new
        # entry into it.
        if [ -s /etc/modules ] && [ -n "$(tail -c 1 /etc/modules)" ]; then
            echo "" >> /etc/modules
        fi
        echo "$kmod" >> /etc/modules
        echo "  Added $kmod to /etc/modules"
    fi

    modprobe "$kmod" || true

    # /sys/module covers built-in modules too, which lsmod does not list. The
    # kernel reports names with underscores regardless of how they're spelled.
    if [ -d "/sys/module/${kmod//-/_}" ]; then
        echo "  $kmod loaded"
    else
        echo "  WARNING: $kmod is not loaded (may need reboot)"
        return 1
    fi
}

# Whether a kernel command line already contains an exact parameter.
#
# Compared token-wise: "iommu=pt" is not present merely because the command line
# contains "amd_iommu=on", and "iommu=soft" does not satisfy "iommu=pt".
#
# Usage: cmdline_has_param "$(cat /proc/cmdline)" "iommu=pt"
cmdline_has_param() {
    local cmdline="$1"
    local wanted="$2"
    local token
    local -a tokens=()

    read -ra tokens <<< "$cmdline"
    for token in "${tokens[@]}"; do
        if [ "$token" = "$wanted" ]; then
            return 0
        fi
    done
    return 1
}

# Merge parameters into a kernel command line and echo the result.
#
# A parameter whose key is already present is replaced where it stands, and any
# later duplicate of that key is dropped — two values for one key is a
# silent-misconfiguration trap. Parameters not already present are appended.
#
# One value per key, so this is not for keys the kernel accepts more than once
# (console=, cgroup_enable=). Existing ones are left alone; just don't pass them.
#
# Usage: merge_cmdline_params "quiet iommu=soft" iommu=pt
merge_cmdline_params() {
    local cmdline="$1"
    shift
    local -a tokens=()
    read -ra tokens <<< "$cmdline"

    local wanted key token placed
    local -a result
    for wanted in "$@"; do
        key="${wanted%%=*}"
        result=()
        placed=0
        for token in "${tokens[@]}"; do
            if [ "${token%%=*}" != "$key" ]; then
                result+=("$token")
            elif [ "$placed" -eq 0 ]; then
                result+=("$wanted")
                placed=1
            fi
        done
        if [ "$placed" -eq 0 ]; then
            result+=("$wanted")
        fi
        tokens=("${result[@]}")
    done

    echo "${tokens[*]}"
}

# Resolve the env file and config directory, then source common.env
# (shared vars) followed by the machine-specific env file (overrides).
# Creates /etc/homelab.env symlink so future runs need no arguments.
#
# Sets: ENV_FILE, CONFIG_DIR (exported)
# Sources: common.env (if exists), then machine env file
#
# Resolution order for env file:
#   1. /etc/homelab.env symlink (most common path)
#   2. CONFIG_DIR env var + hostname (e.g. inside webhook container)
#   3. <repo>/../config/<hostname>.env (first run, derived from REPO_DIR)
#
# Usage: source_env
source_env() {
    local system_env="/etc/homelab.env"
    local hostname
    hostname=$(hostname)

    if [ -f "$system_env" ]; then
        ENV_FILE=$(readlink -f "$system_env")
    elif [ -n "${CONFIG_DIR:-}" ] && [ -f "$CONFIG_DIR/${hostname}.env" ]; then
        ENV_FILE="$CONFIG_DIR/${hostname}.env"
    elif [ -n "${REPO_DIR:-}" ] && [ -f "$REPO_DIR/../config/${hostname}.env" ]; then
        ENV_FILE="$REPO_DIR/../config/${hostname}.env"
    else
        echo "ERROR: No env file found for ${hostname}." >&2
        echo "  Tried: $system_env" >&2
        [ -n "${REPO_DIR:-}" ] && echo "  Tried: $REPO_DIR/../config/${hostname}.env" >&2
        return 1
    fi

    if [ -z "${CONFIG_DIR:-}" ]; then
        CONFIG_DIR=$(dirname "$(realpath "$ENV_FILE")")
    fi
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
