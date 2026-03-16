#!/bin/bash
# Module: create-lxcs
#
# Creates/updates Proxmox LXC containers from env var definitions, then
# runs setup.sh inside each one via pct exec (cascading bootstrap).
#
# Each LXC is defined by a prefix in HOMELAB_LXCS. The prefix determines
# the env var names (e.g. prefix "DOCKER_LXC" → DOCKER_LXC_VMID, etc.).
#
# Existing LXCs: applies config via pct set, restarts only if changed.
# New LXCs: downloads Debian template if needed, creates with pct create.
#
# Required env vars per prefix:
#   _VMID, _HOSTNAME, _IP, _MEMORY_MIB, _CORES, _ROOTFS_GIB, _NESTING
#   _MP0 (and optionally _MP1, _MP2, ...)
#
# Optional env vars per prefix:
#   _GPU (set to 1 to pass through /dev/dri for hardware transcoding)
#
# Global env vars: NETWORK_ROUTER_IP, NETWORK_PREFIX, DNS_IP

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

: "${HOMELAB_LXCS:?HOMELAB_LXCS must be set}"

# --- Helper functions ---

# Collect numbered mount point env vars (MP0, MP1, ...) into a pct args array.
collect_mount_args() {
    local prefix="$1"
    local -n _mounts="$2"
    local i=0
    while true; do
        local mp_var="${prefix}MP${i}"
        local mp_val="${!mp_var:-}"
        [ -z "$mp_val" ] && break
        _mounts+=(--mp${i} "$mp_val")
        i=$((i + 1))
    done
}

# Add GPU passthrough entries to the LXC config if _GPU=1.
# These are raw lxc.* directives that can't go through pct set.
configure_gpu_passthrough() {
    local vmid="$1"
    local prefix="$2"
    local gpu_var="${prefix}_GPU"

    [ "${!gpu_var:-0}" != "1" ] && return 0

    if [ ! -d /dev/dri ]; then
        echo "  WARNING: ${prefix}_GPU=1 but /dev/dri not found — skipping"
        echo "  Ensure GPU drivers are loaded (e.g. configure-amdgpu)"
        return 0
    fi

    local conf="/etc/pve/lxc/${vmid}.conf"
    local changed=false

    if ! grep -q "lxc.cgroup2.devices.allow: c 226:" "$conf"; then
        echo "lxc.cgroup2.devices.allow: c 226:* rwm" >> "$conf"
        changed=true
    fi

    if ! grep -q "lxc.mount.entry: /dev/dri" "$conf"; then
        echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir" >> "$conf"
        changed=true
    fi

    if [ "$changed" = true ]; then
        echo "  GPU passthrough configured"
        if [ "$(pct status "$vmid" | awk '{print $2}')" = "running" ]; then
            echo "  Restarting LXC for GPU passthrough..."
            pct reboot "$vmid"
        fi
    fi
}

# Create or update an LXC. COMMON_ARGS go to both pct create/set.
# CREATE_ARGS go only to pct create (rootfs, features, unprivileged).
create_or_update_lxc() {
    local vmid="$1"
    local label="$2"
    local -n _common="$3"
    local -n _create_only="$4"

    if pct status "$vmid" &>/dev/null; then
        echo "$label $vmid already exists, checking config..."

        # Compare desired config with current to avoid unnecessary restarts.
        # pct set regenerates auto-assigned fields (hwaddr, type in net0),
        # which causes false positives with naive md5sum comparison.
        local needs_update=false
        local current_config
        current_config=$(pct config "$vmid")

        local i=0
        while [ $i -lt ${#_common[@]} ]; do
            local key="${_common[$i]#--}"
            local desired="${_common[$((i+1))]}"
            local current
            current=$(echo "$current_config" | awk -F': ' -v k="$key" '$1 == k {print $2}')

            case "$key" in
                net*)
                    # Strip auto-assigned hwaddr and type, sort for order-independent compare
                    local cur_sorted des_sorted
                    cur_sorted=$(echo "$current" | sed 's/,hwaddr=[^,]*//;s/,type=veth//' | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
                    des_sorted=$(echo "$desired" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
                    [ "$cur_sorted" != "$des_sorted" ] && needs_update=true
                    ;;
                *)
                    [ "$current" != "$desired" ] && needs_update=true
                    ;;
            esac

            [ "$needs_update" = true ] && break
            i=$((i + 2))
        done

        if [ "$needs_update" = true ]; then
            pct set "$vmid" "${_common[@]}"
            if [ "$(pct status "$vmid" | awk '{print $2}')" = "running" ]; then
                echo "Config changed, restarting LXC..."
                pct reboot "$vmid"
            else
                echo "Config changed (will take effect on next start)"
            fi
            echo "$label $vmid updated"
        else
            echo "$label $vmid config unchanged"
        fi
    else
        local template_file template
        template_file=$(ls /var/lib/vz/template/cache/debian-*-standard_*_amd64.tar.zst 2>/dev/null | sort -V | tail -1)
        if [ -z "$template_file" ]; then
            echo "ERROR: No Debian template found" >&2
            exit 1
        fi
        template="local:vztmpl/$(basename "$template_file")"
        pct create "$vmid" "$template" "${_common[@]}" "${_create_only[@]}"
        echo "$label $vmid created"
    fi

    # GPU passthrough (raw lxc.* entries, can't go through pct set)
    configure_gpu_passthrough "$vmid" "$label"

    # Ensure running
    if [ "$(pct status "$vmid" 2>/dev/null | awk '{print $2}')" != "running" ]; then
        pct start "$vmid"
        echo "$label $vmid started"
    fi

    # Wait for LXC to be ready before running setup
    echo "Waiting for $label $vmid to be ready..."
    local retries=30
    while ! pct exec "$vmid" -- true &>/dev/null; do
        retries=$((retries - 1))
        if [ "$retries" -le 0 ]; then
            echo "ERROR: $label $vmid did not become ready in time" >&2
            exit 1
        fi
        sleep 1
    done

    # Run setup inside the LXC (idempotent)
    echo "Running setup inside $label $vmid..."
    pct exec "$vmid" -- bash /mnt/homelab/repo/scripts/setup/setup.sh
}

# --- Main ---

# Download Debian LXC template if not cached
TEMPLATE_DIR="/var/lib/vz/template/cache"
if ! ls "$TEMPLATE_DIR"/debian-*-standard_*_amd64.tar.zst &>/dev/null; then
    echo "Downloading Debian LXC template..."
    pveam update
    TEMPLATE_NAME=$(pveam available --section system | grep 'debian-12-standard' | awk '{print $2}' | tail -1)
    if [ -z "$TEMPLATE_NAME" ]; then
        echo "ERROR: No Debian 12 template found in pveam" >&2
        exit 1
    fi
    pveam download local "$TEMPLATE_NAME"
fi

for prefix in $HOMELAB_LXCS; do
    vmid_var="${prefix}_VMID"
    hostname_var="${prefix}_HOSTNAME"
    ip_var="${prefix}_IP"
    memory_var="${prefix}_MEMORY_MIB"
    cores_var="${prefix}_CORES"
    rootfs_var="${prefix}_ROOTFS_GIB"
    nesting_var="${prefix}_NESTING"

    validate_env "${vmid_var}" "${hostname_var}" "${ip_var}" \
        "${memory_var}" "${cores_var}" "${rootfs_var}" "${nesting_var}" \
        "${prefix}_MP0" NETWORK_ROUTER_IP NETWORK_PREFIX DNS_IP

    COMMON_ARGS=(
        --hostname "${!hostname_var}"
        --memory "${!memory_var}"
        --cores "${!cores_var}"
        --onboot 1
        --net0 "name=eth0,bridge=vmbr0,ip=${!ip_var}/${NETWORK_PREFIX},gw=${NETWORK_ROUTER_IP}"
        --nameserver "$DNS_IP"
    )
    collect_mount_args "${prefix}_" COMMON_ARGS

    CREATE_ARGS=(
        --rootfs "local-lvm:${!rootfs_var}"
        --features "nesting=${!nesting_var}"
        --unprivileged 0
    )

    create_or_update_lxc "${!vmid_var}" "$prefix" COMMON_ARGS CREATE_ARGS
done

echo "LXCs ready"
