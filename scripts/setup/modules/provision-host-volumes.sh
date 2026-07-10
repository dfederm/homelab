#!/bin/bash
# Module: provision-host-volumes (Proxmox host only)
#
# Creates dedicated LVM-thin volumes on the host and mounts them, ready to be
# bind-mounted into an LXC via a _MP* entry (e.g. a faster store for the Ollama
# model dir). Must run BEFORE create-lxcs so the mountpoint exists for the bind.
#
# Each volume is defined by a prefix in HOMELAB_HOST_VOLUMES (space-separated),
# mirroring the HOMELAB_LXCS / HOMELAB_VMS pattern. For prefix "OLLAMA_SSD":
#   OLLAMA_SSD_LV_NAME      logical volume name (created in the thin pool)
#   OLLAMA_SSD_SIZE_GIB     virtual size in GiB (thin: backs only what's written)
#   OLLAMA_SSD_MOUNTPOINT   absolute host path to mount it at
#   OLLAMA_SSD_THINPOOL     optional, thin pool (default: pve/data)
#   OLLAMA_SSD_FS           optional, filesystem type (default: ext4)
#
# Idempotent + data-safe: LV created only if absent; mkfs runs only when the
# volume has no filesystem (never reformats data); fstab appended only if missing;
# mounts only if not already mounted.
#
# Global env: HOMELAB_HOST_VOLUMES (if unset/empty, this module is a no-op).

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

if [ -z "${HOMELAB_HOST_VOLUMES:-}" ]; then
    echo "No HOMELAB_HOST_VOLUMES configured, nothing to do"
    exit 0
fi

for prefix in $HOMELAB_HOST_VOLUMES; do
    lv_name_var="${prefix}_LV_NAME"
    size_var="${prefix}_SIZE_GIB"
    mountpoint_var="${prefix}_MOUNTPOINT"

    validate_env "$lv_name_var" "$size_var" "$mountpoint_var"

    lv_name="${!lv_name_var}"
    size_gib="${!size_var}"
    mountpoint="${!mountpoint_var}"
    thinpool="${prefix}_THINPOOL"
    thinpool="${!thinpool:-pve/data}"
    fs_var="${prefix}_FS"
    fs="${!fs_var:-ext4}"

    vg="${thinpool%%/*}"
    lv_path="/dev/${vg}/${lv_name}"

    echo "--- $prefix: ${lv_path} (${size_gib}G ${fs}) -> ${mountpoint} ---"

    # Create the thin LV if absent (never resize/remove here).
    if lvs "${vg}/${lv_name}" &>/dev/null; then
        echo "  LV ${vg}/${lv_name} already exists"
    else
        lvcreate --type thin --virtualsize "${size_gib}G" \
            --thinpool "$thinpool" --name "$lv_name" "$vg"
        echo "  LV ${vg}/${lv_name} created (${size_gib}G virtual)"
    fi

    # Make a filesystem only if the volume has none (never reformat data).
    if blkid "$lv_path" &>/dev/null; then
        echo "  filesystem already present, leaving intact"
    else
        "mkfs.${fs}" "$lv_path"
        echo "  filesystem (${fs}) created"
    fi

    mkdir -p "$mountpoint"

    # nofail so a failed data volume never drops the host into emergency mode.
    if grep -qE "^[^#]*[[:space:]]${mountpoint}[[:space:]]" /etc/fstab; then
        echo "  fstab entry already present"
    else
        echo "${lv_path} ${mountpoint} ${fs} defaults,nofail 0 2" >> /etc/fstab
        echo "  fstab entry added"
    fi

    if mountpoint -q "$mountpoint"; then
        echo "  already mounted"
    else
        mount "$mountpoint"
        echo "  mounted"
    fi
done

echo "Host volumes provisioned"
