#!/bin/bash
# Module: configure-lxc-fstrim (Proxmox host only)
#
# Schedules periodic `pct fstrim` of LXC rootfs volumes so blocks freed inside
# containers return to the LVM thin pool (pve/data). Without it, each container's
# pool allocation (lvs data_percent) only ever grows as files are deleted,
# steadily consuming thin-pool headroom shared by every LXC rootfs and VM disk.
#
# Host-only: LXC rootfs is host-mounted directly (no QEMU block layer), so
# `pct fstrim` reclaims from host context with no in-guest cooperation and no disk
# `discard` flag. VMs reclaim separately via discard=on + their own guest fstrim
# (see create-vms.sh).
#
# A periodic batch trim is deliberately preferred over the inline `discard` mount
# option, whose per-delete overhead hurts write-heavy containers (Docker image churn).
#
# Schedule semantics (mirrors configure-storage-health): a NON-EMPTY
# LXC_FSTRIM_SCHEDULE enables the timer on that systemd OnCalendar; an EMPTY (or
# unset) value DISABLES it and removes any previously-installed unit. The
# recommended default lives in .env.template.
#
# Idempotent: generated units are compared (cmp) before replacing; the timer is
# only (re)started when something actually changed.
#
# Env vars:
#   REPO_DIR             (required, set by setup.sh) repo path on this host
#   LXC_FSTRIM_SCHEDULE  systemd OnCalendar for the trim; empty = disabled.
#                        Recommended: weekly.

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

validate_env REPO_DIR

LXC_FSTRIM_SCHEDULE="${LXC_FSTRIM_SCHEDULE:-}"

TRIM_SCRIPT="$REPO_DIR/scripts/lxc-fstrim.sh"
SERVICE_FILE="/etc/systemd/system/homelab-lxc-fstrim.service"
TIMER_FILE="/etc/systemd/system/homelab-lxc-fstrim.timer"

if [ ! -f "$TRIM_SCRIPT" ]; then
    echo "ERROR: trim script not found: $TRIM_SCRIPT" >&2
    exit 1
fi

DAEMON_RELOAD=false

# Write $1 (a temp file) to $2 only if different. Echoes "changed" when it
# replaced the destination, "unchanged" otherwise.
install_if_changed() {
    local tmp="$1" dest="$2"
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        echo "unchanged"
    else
        mv "$tmp" "$dest"
        echo "changed"
    fi
}

# Disable + remove a systemd unit if it exists (used when the feature is disabled).
remove_unit() {
    local unit="$1"
    if [ -f "/etc/systemd/system/$unit" ]; then
        systemctl disable --now "$unit" > /dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$unit"
        DAEMON_RELOAD=true
        echo "  removed $unit"
    fi
}

if [ -n "$LXC_FSTRIM_SCHEDULE" ]; then
    TEMP_UNIT=$(mktemp)
    cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=Homelab periodic LXC rootfs fstrim
After=pve-guests.service

[Service]
Type=oneshot
ExecStart=/bin/bash ${TRIM_SCRIPT}
EOF
    [ "$(install_if_changed "$TEMP_UNIT" "$SERVICE_FILE")" = "changed" ] && DAEMON_RELOAD=true

    TEMP_UNIT=$(mktemp)
    cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=Homelab LXC fstrim timer

[Timer]
OnCalendar=${LXC_FSTRIM_SCHEDULE}
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF
    [ "$(install_if_changed "$TEMP_UNIT" "$TIMER_FILE")" = "changed" ] && DAEMON_RELOAD=true
else
    remove_unit homelab-lxc-fstrim.timer
    remove_unit homelab-lxc-fstrim.service
fi

if [ "$DAEMON_RELOAD" = true ]; then
    systemctl daemon-reload
    echo "  systemd units updated"
else
    echo "  systemd units unchanged"
fi

# Enable/start the timer only when the feature is configured (idempotent).
if [ -n "$LXC_FSTRIM_SCHEDULE" ]; then
    systemctl enable --now homelab-lxc-fstrim.timer > /dev/null
fi

echo "LXC fstrim configured (schedule: '${LXC_FSTRIM_SCHEDULE:-disabled}')"
