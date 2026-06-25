#!/bin/bash
# lxc-fstrim.sh - Return blocks freed inside LXC containers to the LVM thin pool.
#
# LXC rootfs volumes live on the thin pool (pve/data). Deleting files inside a
# container does NOT hand those blocks back to the pool on its own, so each
# container's pool allocation (lvs data_percent) only ever drifts upward, above
# its live usage - steadily eating thin-pool headroom shared by every LXC rootfs
# and VM disk. Running fstrim returns the freed blocks.
#
# LXC rootfs is host-mounted directly (no QEMU block layer), so `pct fstrim`
# works from the host with no in-guest cooperation and no disk `discard` flag -
# unlike VMs, which need discard=on on the virtual disk (see create-vms.sh).
#
# A periodic batch trim is deliberately preferred over the inline `discard` mount
# option: inline discard trims on every delete, adding per-write overhead that
# hurts write-heavy containers (e.g. the Docker LXC's image churn). A periodic
# batch trim reclaims the same space without that steady cost.
#
# Iterates HOMELAB_LXCS (same prefix pattern as create-lxcs) and trims each
# running container. Intended to run from a systemd timer on the Proxmox host;
# installed by the configure-lxc-fstrim module.

set -euo pipefail

SCRIPT=$(readlink -f "$0")
REPO_DIR=$(dirname "$(dirname "$SCRIPT")")
export REPO_DIR

source "$REPO_DIR/scripts/lib.sh"
source_env

: "${HOMELAB_LXCS:?HOMELAB_LXCS must be set}"

echo "=== LXC fstrim: $(hostname) $(date '+%Y-%m-%d %H:%M:%S') ==="

if ! command -v pct &>/dev/null; then
    echo "WARNING: pct not found; this runs on the Proxmox host only. Skipping." >&2
    exit 0
fi

for prefix in $HOMELAB_LXCS; do
    vmid_var="${prefix}_VMID"
    vmid="${!vmid_var:-}"
    if [ -z "$vmid" ]; then
        echo "WARNING: $vmid_var unset; skipping $prefix" >&2
        continue
    fi

    if ! pct status "$vmid" &>/dev/null; then
        echo "$prefix ($vmid): not present; skipping"
        continue
    fi
    if [ "$(pct status "$vmid" | awk '{print $2}')" != "running" ]; then
        echo "$prefix ($vmid): not running; skipping (rootfs not mounted)"
        continue
    fi

    echo "$prefix ($vmid): trimming..."
    pct fstrim "$vmid" || echo "  WARNING: fstrim failed for $prefix ($vmid)" >&2
done

echo "=== LXC fstrim complete ==="
