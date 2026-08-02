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

# Run apt-get, waiting out another process that holds an apt lock.
#
# Do not "simplify" this into `-o DPkg::Lock::Timeout=N`. That option is read
# only by debSystem::Lock(), which guards the dpkg locks. The lists lock
# (/var/lib/apt/lists/lock, taken by `update`) and the archives lock
# (/var/cache/apt/archives/lock, taken by `install`) are both acquired by
# pkgAcquire::GetLock() via a non-blocking fcntl(F_SETLK) that fails instantly
# and consults no configuration. apt has never shipped an option that makes
# those two wait, so the waiting has to happen out here. The option is still
# passed below, since it does cover the dpkg half of an install — with the
# caveat that apt then does that wait internally, so a dpkg-lock collision is
# absorbed silently rather than reported by the retry notices below.
#
# This matters because a Proxmox host runs several randomized apt-touching
# timers (apt-daily, apt-daily-upgrade, pve-daily-update), and pve-daily-update
# is Persistent=yes — a window missed while the machine was off is caught up
# shortly after boot, which is exactly when a rebuild deploy tends to run. A
# collision of a few seconds is enough to abort the whole setup cascade.
#
# apt-get exits 100 for every failure, so the exit status says nothing about
# whether waiting would help. Retrying is gated on apt's contention messages
# instead. Note the deliberately narrow match: "Unable to lock directory" is NOT
# one of them, because apt emits it for a permission error too, and retrying
# that would spend the whole budget hiding a real fault.
#
# stdout is left alone, so callers keep whatever redirection they already had.
# stderr is captured to match against, then replayed — including on success, so
# apt warnings still reach the journal. Retry notices go to stderr as well,
# since callers routinely send this function's stdout to /dev/null.
#
# Env vars:
#   APT_LOCK_TIMEOUT  (optional, default 120) seconds to keep retrying for. It
#                     bounds when the last retry may *start*, so a run can
#                     overshoot it by one backoff interval.
#
# Usage: apt_get install -y -qq curl > /dev/null
apt_get() {
    local timeout="${APT_LOCK_TIMEOUT:-120}"
    if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
        # Left unchecked this silently becomes 0 in the arithmetic below, i.e. no
        # retries at all — the exact failure this function exists to prevent.
        echo "  WARNING: APT_LOCK_TIMEOUT is not a number ('$timeout'), using 120" >&2
        timeout=120
    fi
    local deadline=$(( $(date +%s) + timeout ))
    local delay=2
    local attempt=1
    local errfile status
    errfile=$(mktemp) || return 1

    while true; do
        status=0
        # LC_ALL=C so the messages matched below are apt's untranslated originals.
        LC_ALL=C apt-get -o DPkg::Lock::Timeout="$timeout" "$@" 2> "$errfile" || status=$?

        if [ "$status" -eq 0 ]; then
            break
        fi

        # "Could not get lock" is the lists/archives contention message and is
        # not emitted for permission failures (those say "Could not open lock
        # file"). "is another process using it" is the dpkg-lock equivalent,
        # whose permanent counterpart reads "are you root?".
        if ! grep -qE 'Could not get lock|is another process using it' "$errfile"; then
            break
        fi

        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "  apt-get $*: apt lock still held after ${timeout}s, giving up" >&2
            break
        fi

        echo "  apt-get $*: apt lock held by another process, retrying in ${delay}s (attempt $attempt)" >&2
        sleep "$delay"
        attempt=$(( attempt + 1 ))
        if [ "$delay" -lt 30 ]; then
            delay=$(( delay * 2 ))
        fi
    done

    cat "$errfile" >&2
    rm -f "$errfile"
    return "$status"
}

# Install the Shoutrrr CLI used by host-side checks to deliver alerts through
# HOMELAB_ALERT_SHOUTRRR_URL. Best-effort: callers can continue with syslog-only
# alerting when GitHub or the release asset is temporarily unavailable.
# renovate: datasource=github-releases depName=nicholas-fedor/shoutrrr
SHOUTRRR_VERSION="0.16.3"
ensure_shoutrrr() {
    local bin="/usr/local/bin/shoutrrr"
    local marker="/usr/local/bin/.shoutrrr-version"
    if [ -x "$bin" ] && [ "$(cat "$marker" 2>/dev/null)" = "$SHOUTRRR_VERSION" ]; then
        echo "shoutrrr $SHOUTRRR_VERSION already installed"
        return 0
    fi

    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null || ! command -v tar &>/dev/null; then
        apt_get update -qq >/dev/null
        apt_get install -y -qq jq curl tar >/dev/null
    fi

    local repo="nicholas-fedor/shoutrrr"
    local tag="v${SHOUTRRR_VERSION}"
    local asset="shoutrrr_linux_amd64_${SHOUTRRR_VERSION}.tar.gz"
    local digest
    digest="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${repo}/releases/tags/${tag}" \
        | jq -r --arg n "$asset" '.assets[] | select(.name == $n) | .digest' \
        | sed 's/^sha256://')"
    if ! printf '%s' "$digest" | grep -qE '^[0-9a-f]{64}$'; then
        echo "  WARNING: could not get a sha256 digest for $asset @ ${tag} from GitHub" >&2
        return 1
    fi

    local tmp
    tmp="$(mktemp -d)"
    if ! curl -fsSL --retry 3 --retry-delay 2 \
        "https://github.com/${repo}/releases/download/${tag}/${asset}" -o "$tmp/$asset"; then
        rm -rf "$tmp"
        echo "  WARNING: shoutrrr download failed" >&2
        return 1
    fi
    if [ "$(sha256sum "$tmp/$asset" | cut -d' ' -f1)" != "$digest" ]; then
        rm -rf "$tmp"
        echo "  WARNING: shoutrrr checksum mismatch" >&2
        return 1
    fi
    if ! tar -xzf "$tmp/$asset" -C "$tmp" shoutrrr; then
        rm -rf "$tmp"
        echo "  WARNING: shoutrrr extract failed" >&2
        return 1
    fi
    if ! install -m 755 "$tmp/shoutrrr" "$bin"; then
        rm -rf "$tmp"
        echo "  WARNING: shoutrrr install failed" >&2
        return 1
    fi

    echo "$SHOUTRRR_VERSION" > "$marker"
    rm -rf "$tmp"
    echo "Installed shoutrrr $SHOUTRRR_VERSION (verified against GitHub digest)"
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
