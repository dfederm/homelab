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
#   _NVIDIA_GPU (set to 1 to pass through /dev/nvidia* for CUDA workloads)
#   _USB_DEVICES (space-separated host device paths to pass through, typically
#                 by-id symlinks, e.g. /dev/serial/by-id/usb-Zooz_800_Z-Wave_Stick_...-if00)
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
# Returns 0 if config was changed, 1 if already configured or skipped.
configure_gpu_passthrough() {
    local vmid="$1"
    local prefix="$2"
    local gpu_var="${prefix}_GPU"

    [ "${!gpu_var:-0}" != "1" ] && return 1

    if [ ! -d /dev/dri ]; then
        echo "  WARNING: ${prefix}_GPU=1 but /dev/dri not found — skipping"
        echo "  Ensure GPU drivers are loaded (e.g. configure-amdgpu)"
        return 1
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
        return 0
    fi
    return 1
}

# Add NVIDIA GPU passthrough entries to the LXC config if _NVIDIA_GPU=1.
# Kept separate from _GPU — that one passes /dev/dri for integrated-GPU
# transcoding, and the two are independent: a host can have either, both, or
# neither, and an integrated-GPU-only host must be unaffected by this.
#
# Device majors are read off the device nodes themselves with stat, the same way
# configure_usb_passthrough does it, rather than being hardcoded or looked up by
# name. Neither shortcut survives contact with reality: the per-GPU nodes sit at
# a fixed major but nvidia-uvm and nvidia-caps are assigned one dynamically when
# the driver loads, and the names /proc/devices uses for them differ between
# driver versions (the main node has been listed as both "nvidia" and
# "nvidia-frontend"). Reading the nodes that are actually there sidesteps both.
#
# Returns 0 if config was changed, 1 if already configured or skipped.
configure_nvidia_passthrough() {
    local vmid="$1"
    local prefix="$2"
    local nvidia_var="${prefix}_NVIDIA_GPU"

    [ "${!nvidia_var:-0}" != "1" ] && return 1

    # These nodes are created when something first opens the driver, not at
    # boot, so finding none here usually means the host-side setup hasn't run
    # yet rather than that the driver is missing.
    local -a nodes=()
    local node
    for node in /dev/nvidia*; do
        if [ -e "$node" ]; then
            nodes+=("$node")
        fi
    done

    if [ "${#nodes[@]}" -eq 0 ]; then
        echo "  WARNING: ${prefix}_NVIDIA_GPU=1 but no /dev/nvidia* devices found — skipping"
        echo "  Ensure the NVIDIA driver is installed and loaded (e.g. configure-nvidia-driver)"
        return 1
    fi

    local conf="/etc/pve/lxc/${vmid}.conf"
    local changed=false

    # /dev/nvidia-caps is a directory of character devices on its own major, so
    # the majors have to come from the leaf nodes, not just the top level.
    local -a devnodes=()
    for node in "${nodes[@]}"; do
        if [ -d "$node" ]; then
            local child
            for child in "$node"/*; do
                [ -c "$child" ] && devnodes+=("$child")
            done
        elif [ -c "$node" ]; then
            devnodes+=("$node")
        fi
    done

    local seen_majors=" "
    local devnode major_hex major
    for devnode in "${devnodes[@]}"; do
        major_hex=$(stat -c '%t' "$devnode" 2>/dev/null) || continue
        [ -n "$major_hex" ] || continue
        major=$((16#$major_hex))
        case "$seen_majors" in
            *" $major "*) continue ;;
        esac
        seen_majors="$seen_majors$major "
        if ! grep -q "lxc.cgroup2.devices.allow: c $major:" "$conf"; then
            echo "lxc.cgroup2.devices.allow: c $major:* rwm" >> "$conf"
            changed=true
        fi
    done

    # /dev/nvidia-caps is a directory; the rest are character devices.
    for node in "${nodes[@]}"; do
        if ! grep -qF "lxc.mount.entry: $node " "$conf"; then
            local nodename create
            nodename=$(basename "$node")
            if [ -d "$node" ]; then
                create="dir"
            else
                create="file"
            fi
            echo "lxc.mount.entry: $node dev/$nodename none bind,optional,create=$create" >> "$conf"
            changed=true
        fi
    done

    if [ "$changed" = true ]; then
        echo "  NVIDIA passthrough configured: ${nodes[*]}"
        return 0
    fi
    return 1
}

# Add USB device passthrough entries to the LXC config from _USB_DEVICES.
# _USB_DEVICES is a space-separated list of host device paths, typically by-id
# symlinks (e.g. /dev/serial/by-id/usb-Zooz_800_...-if00). Each device's
# underlying real path is bound at the same name, and a cgroup allow is added
# for the device's major number (detected via stat) — so this works for USB ACM
# (Z-Wave, Zigbee CC), USB serial (FTDI, CP210x), and other character device
# classes uniformly. /dev/serial is bound as a directory so by-id symlinks
# resolve inside the container.
# Returns 0 if config was changed, 1 if already configured or skipped.
configure_usb_passthrough() {
    local vmid="$1"
    local prefix="$2"
    local devices_var="${prefix}_USB_DEVICES"
    local devices="${!devices_var:-}"

    [ -z "$devices" ] && return 1

    local conf="/etc/pve/lxc/${vmid}.conf"
    local changed=false

    if ! grep -q "lxc.mount.entry: /dev/serial " "$conf"; then
        echo "lxc.mount.entry: /dev/serial dev/serial none bind,optional,create=dir" >> "$conf"
        changed=true
    fi

    for device in $devices; do
        if [ ! -e "$device" ]; then
            echo "  WARNING: ${prefix}_USB_DEVICES references missing $device — skipping"
            continue
        fi
        local real
        real=$(readlink -f "$device")
        if [ -z "$real" ]; then
            echo "  WARNING: ${prefix}_USB_DEVICES could not resolve $device — skipping"
            continue
        fi

        # cgroup allow for this device's major number (detected dynamically so
        # USB ACM (166), USB serial (188), and others work without code change).
        local major_hex
        major_hex=$(stat -c '%t' "$real" 2>/dev/null)
        if [ -n "$major_hex" ]; then
            local major=$((16#$major_hex))
            if ! grep -q "lxc.cgroup2.devices.allow: c $major:" "$conf"; then
                echo "lxc.cgroup2.devices.allow: c $major:* rwm" >> "$conf"
                changed=true
            fi
        fi

        if ! grep -qF "lxc.mount.entry: $real " "$conf"; then
            local realname
            realname=$(basename "$real")
            echo "lxc.mount.entry: $real dev/$realname none bind,optional,create=file" >> "$conf"
            changed=true
        fi
    done

    if [ "$changed" = true ]; then
        echo "  USB passthrough configured: $devices"
        return 0
    fi
    return 1
}

resolve_lxc_config_dir() {
    local prefix="$1"
    local host_config_dir
    local best_source=""
    local best_target=""
    local i=0

    host_config_dir=$(readlink -f "$CONFIG_DIR")

    while true; do
        local mp_var="${prefix}_MP${i}"
        local mp_value="${!mp_var:-}"
        [ -z "$mp_value" ] && break

        local source_path="${mp_value%%,*}"
        source_path="${source_path#volume=}"
        local target_path=""
        local field
        local -a fields=()
        IFS=',' read -ra fields <<< "$mp_value"
        for field in "${fields[@]:1}"; do
            case "$field" in
                mp=*)
                    target_path="${field#mp=}"
                    break
                    ;;
            esac
        done

        local source_real
        source_real=$(readlink -f "$source_path" 2>/dev/null || true)
        if [ -n "$source_real" ] && [ -n "$target_path" ] \
            && { [ "$source_real" = "/" ] \
                || [ "$host_config_dir" = "$source_real" ] \
                || [[ "$host_config_dir" = "$source_real/"* ]]; } \
            && [ "${#source_real}" -gt "${#best_source}" ]; then
            best_source="$source_real"
            while [ "$target_path" != "/" ] \
                && [ "${target_path%/}" != "$target_path" ]; do
                target_path="${target_path%/}"
            done
            best_target="$target_path"
            [ -n "$best_target" ] || best_target="/"
        fi

        i=$((i + 1))
    done

    if [ -z "$best_source" ]; then
        echo "ERROR: $prefix has no _MP* mapping containing $host_config_dir" >&2
        return 1
    fi

    local relative="${host_config_dir#"$best_source"}"
    if [ "$best_target" = "/" ]; then
        printf '/%s\n' "${relative#/}"
    else
        printf '%s/%s\n' "$best_target" "${relative#/}"
    fi
}

sync_repo_and_run_setup() {
    local vmid="$1"
    local prefix="$2"
    local repo_dir="${HOMELAB_REPO_DIR:-/opt/homelab/repo}"
    local config_dir
    local lxc_script

    config_dir=$(resolve_lxc_config_dir "$prefix")

    for path in "$repo_dir" "$config_dir"; do
        if ! [[ "$path" = /* ]] || [[ "$path" = "/" ]] \
            || [[ "$path" = *".."* ]] \
            || ! [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
            echo "ERROR: LXC repo/config paths must be safe absolute paths" >&2
            exit 1
        fi
    done

    read -r -d '' lxc_script <<'EOF' || true
set -euo pipefail

repo_dir="$1"
config_dir="$2"
lock_file="${HOMELAB_SETUP_LOCK_FILE:-/run/lock/homelab-setup.lock}"
mkdir -p "$(dirname "$lock_file")" "$(dirname "$repo_dir")"
exec 9> "$lock_file"
flock 9

staging=$(mktemp -d "$(dirname "$repo_dir")/.homelab-repo.XXXXXX")
trap 'rm -rf "$staging"' EXIT
tar -xf - -C "$staging"

same_path_type() {
    local existing="$1"
    local desired="$2"

    if [ -L "$existing" ]; then
        [ -L "$desired" ]
    elif [ -d "$existing" ]; then
        [ -d "$desired" ] && [ ! -L "$desired" ]
    elif [ -f "$existing" ]; then
        [ -f "$desired" ] && [ ! -L "$desired" ]
    else
        [ -e "$desired" ] && [ ! -L "$desired" ] \
            && [ ! -d "$desired" ] && [ ! -f "$desired" ]
    fi
}

if [ -d "$repo_dir" ]; then
    while IFS= read -r -d '' existing; do
        relative="${existing#"$repo_dir"/}"
        if { [ ! -e "$staging/$relative" ] \
                && [ ! -L "$staging/$relative" ]; } \
            || ! same_path_type "$existing" "$staging/$relative"; then
            rm -rf -- "$existing"
        fi
    done < <(find "$repo_dir" -mindepth 1 -depth -print0)
else
    mkdir -p "$repo_dir"
fi

cp -a "$staging/." "$repo_dir/"
rm -rf "$staging"
trap - EXIT

CONFIG_DIR="$config_dir" HOMELAB_SETUP_LOCK_HELD=1 \
    bash "$repo_dir/scripts/setup/setup.sh"
EOF

    tar --exclude=.git -C "$REPO_DIR" -cf - . \
        | pct exec "$vmid" -- bash -c "$lxc_script" bash \
            "$repo_dir" "$config_dir"
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
                    cur_sorted=$(echo "$current" | sed 's/^hwaddr=[^,]*,//;s/,hwaddr=[^,]*//;s/^type=veth,//;s/,type=veth//' | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
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

        local needs_restart=false

        if [ "$needs_update" = true ]; then
            pct set "$vmid" "${_common[@]}"
            needs_restart=true
            echo "$label $vmid config updated"
        else
            echo "$label $vmid config unchanged"
        fi

        # Rootfs resize — expand if configured size exceeds current size.
        # Only grows; never shrinks (shrinking risks data loss).
        local rootfs_var="${label}_ROOTFS_GIB"
        local desired_gib="${!rootfs_var}"
        local current_gib
        current_gib=$(echo "$current_config" | awk -F': ' '$1 == "rootfs" {print $2}' | grep -oP 'size=\K[0-9]+')
        if [ -n "$desired_gib" ] && [ -n "$current_gib" ] && [ "$desired_gib" -gt "$current_gib" ]; then
            local expand_by=$(( desired_gib - current_gib ))

            # Check available space in the thin pool before resizing
            local free_bytes free_gib
            free_bytes=$(lvs --noheadings --nosuffix --units b -o lv_size /dev/pve/data 2>/dev/null | tr -d ' ')
            local used_bytes
            used_bytes=$(lvs --noheadings --nosuffix --units b -o data_percent /dev/pve/data 2>/dev/null | tr -d ' ')
            free_gib=$(lvs --noheadings --nosuffix --units g -o lv_size /dev/pve/data 2>/dev/null | tr -d ' ')
            local used_pct
            used_pct=$(lvs --noheadings --nosuffix -o data_percent /dev/pve/data 2>/dev/null | tr -d ' ')
            local avail_gib
            avail_gib=$(awk "BEGIN {printf \"%d\", ${free_gib:-0} * (100 - ${used_pct:-100}) / 100}")

            if [ "$expand_by" -gt "$avail_gib" ]; then
                echo "  WARNING: Cannot resize rootfs — need ${expand_by}G but only ${avail_gib}G available in local-lvm"
                echo "  Skipping resize for $label $vmid"
            else
                pct resize "$vmid" rootfs "+${expand_by}G"
                echo "$label $vmid rootfs resized: ${current_gib}G → ${desired_gib}G"
            fi
        fi

        # GPU passthrough — apply before restart so one reboot covers both
        if configure_gpu_passthrough "$vmid" "$label"; then
            needs_restart=true
        fi

        # NVIDIA GPU passthrough — apply before restart
        if configure_nvidia_passthrough "$vmid" "$label"; then
            needs_restart=true
        fi

        # USB passthrough — apply before restart
        if configure_usb_passthrough "$vmid" "$label"; then
            needs_restart=true
        fi

        if [ "$needs_restart" = true ] && [ "$(pct status "$vmid" | awk '{print $2}')" = "running" ]; then
            echo "Restarting LXC..."
            pct reboot "$vmid"
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

        # GPU passthrough — entries applied before first start
        configure_gpu_passthrough "$vmid" "$label" || true

        # NVIDIA GPU passthrough — entries applied before first start
        configure_nvidia_passthrough "$vmid" "$label" || true

        # USB passthrough — entries applied before first start
        configure_usb_passthrough "$vmid" "$label" || true
    fi

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

    # Synchronize a stable local source copy and run setup under the LXC's lock.
    echo "Running setup inside $label $vmid..."
    sync_repo_and_run_setup "$vmid" "$label"
}

# --- Main ---

# Download Debian LXC template if not cached
TEMPLATE_DIR="${LXC_TEMPLATE_DIR:-/var/lib/vz/template/cache}"
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
