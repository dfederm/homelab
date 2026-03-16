#!/bin/bash
# Module: create-vms
#
# Creates/updates Proxmox VMs from env var definitions.
# Each VM is defined by a prefix in HOMELAB_VMS. The prefix determines
# the env var names (e.g. prefix "HAOS_VM" → HAOS_VM_VMID, etc.).
#
# Existing VMs: applies config via qm set, restarts only if changed.
# New VMs: creates with qm create, imports disk image if _IMAGE is set.
#
# Required env vars per prefix:
#   _VMID, _HOSTNAME, _MEMORY_MIB, _CORES
#
# Optional env vars per prefix (defaults in parentheses):
#   _BIOS (seabios), _MACHINE (i440fx), _OSTYPE (l26), _AGENT (0)
#   _IMAGE - path to disk image file, imported on first create only
#
# Note: _IP is informational only (documented in env, not passed to qm).
# VMs manage their own networking from within the guest OS.

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

: "${HOMELAB_VMS:?HOMELAB_VMS must be set}"

# --- Helper functions ---

create_or_update_vm() {
    local vmid="$1"
    local prefix="$2"
    local -n _common="$3"
    local -n _create_only="$4"

    if qm status "$vmid" &>/dev/null; then
        echo "$prefix VM $vmid already exists, checking config..."

        # Compare desired config with current to avoid unnecessary restarts.
        # qm set on a running VM tries to hot-plug devices (e.g. net0) which
        # can fail, so we only stop + apply when something actually changed.
        local needs_update=false
        local current_config
        current_config=$(qm config "$vmid")

        local i=0
        while [ $i -lt ${#_common[@]} ]; do
            local key="${_common[$i]#--}"
            local desired="${_common[$((i+1))]}"
            local current
            current=$(echo "$current_config" | awk -F': ' -v k="$key" '$1 == k {print $2}')
            # Strip auto-assigned MAC address for net interface comparison
            current=$(echo "$current" | sed 's/=[A-Fa-f0-9:]\{17\}//')

            if [ "$current" != "$desired" ]; then
                needs_update=true
                break
            fi
            i=$((i + 2))
        done

        if [ "$needs_update" = true ]; then
            if [ "$(qm status "$vmid" | awk '{print $2}')" = "running" ]; then
                echo "Stopping VM for config update..."
                qm shutdown "$vmid" --timeout 30 2>/dev/null || qm stop "$vmid"
            fi
            qm set "$vmid" "${_common[@]}"
            echo "$prefix VM $vmid config updated"
        else
            echo "$prefix VM $vmid config unchanged"
        fi
    else
        qm create "$vmid" "${_common[@]}" "${_create_only[@]}"

        # UEFI VMs need an EFI disk for NVRAM (boot variable persistence)
        local bios_var="${prefix}_BIOS"
        local next_disk=0
        if [ "${!bios_var:-seabios}" = "ovmf" ]; then
            qm set "$vmid" --efidisk0 "local-lvm:0,efitype=4m"
            next_disk=1
        fi

        # Import disk image if specified (first create only)
        local disk_var="${prefix}_IMAGE"
        local disk_path="${!disk_var:-}"
        if [ -n "$disk_path" ]; then
            if [ ! -f "$disk_path" ]; then
                echo "ERROR: Disk image not found: $disk_path" >&2
                exit 1
            fi
            echo "Importing disk image: $disk_path"
            qm importdisk "$vmid" "$disk_path" local-lvm
            qm set "$vmid" --scsi0 "local-lvm:vm-${vmid}-disk-${next_disk}"
            qm set "$vmid" --boot order=scsi0
        fi

        echo "$prefix VM $vmid created"
    fi

    # Ensure running
    if [ "$(qm status "$vmid" 2>/dev/null | awk '{print $2}')" != "running" ]; then
        qm start "$vmid"
        echo "$prefix VM $vmid started"
    fi
}

# --- Main ---

for prefix in $HOMELAB_VMS; do
    vmid_var="${prefix}_VMID"
    hostname_var="${prefix}_HOSTNAME"
    memory_var="${prefix}_MEMORY_MIB"
    cores_var="${prefix}_CORES"

    validate_env "$vmid_var" "$hostname_var" "$memory_var" "$cores_var"

    # Optional settings with sane defaults
    bios_var="${prefix}_BIOS";       bios="${!bios_var:-seabios}"
    machine_var="${prefix}_MACHINE"; machine="${!machine_var:-i440fx}"
    ostype_var="${prefix}_OSTYPE";   ostype="${!ostype_var:-l26}"
    agent_var="${prefix}_AGENT";     agent="${!agent_var:-0}"

    COMMON_ARGS=(
        --name "${!hostname_var}"
        --memory "${!memory_var}"
        --cores "${!cores_var}"
        --scsihw virtio-scsi-pci
        --net0 "virtio,bridge=vmbr0"
    )

    CREATE_ARGS=(
        --bios "$bios"
        --machine "$machine"
        --ostype "$ostype"
        --agent "enabled=$agent"
    )

    create_or_update_vm "${!vmid_var}" "$prefix" COMMON_ARGS CREATE_ARGS
done

echo "VMs ready"
