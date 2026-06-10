#!/bin/bash
# Module: configure-storage-health
#
# Host-level (Proxmox host) storage-health scheduling for the ZFS pool and its
# physical drives. The pool and disks are owned by the bare-metal host, so this is a
# host concern (not an LXC one).
#
# Installs and configures, idempotently:
#   - smartmontools (smartd): drive-health/attribute monitoring on ALL drives
#     (reallocated/pending sectors, failed self-test, health fail, temperature),
#     plus scheduled SMART self-tests when SMART_SELFTEST_SCHEDULE is set. smartd
#     logs any degradation to syslog/journal (default behavior).
#   - systemd timer to scrub the ZFS pool (homelab-zfs-scrub) when ZFS_SCRUB_SCHEDULE
#     is set, with a post-scrub health check.
#   - systemd timer for a ZFS pool health check (homelab-zfs-health-check) when
#     ZFS_HEALTH_CHECK_SCHEDULE is set, catching faults/errors between scrubs.
#
# Detection only: problems surface via smartd's syslog/journal logging (SMART) and a
# failed systemd unit + journal output (ZFS health check / scrub). Active push
# notifications are intentionally deferred until the homelab alerting backend is
# chosen (separate todo).
#
# Schedule semantics: each scheduled feature is gated by its schedule env var. A
# NON-EMPTY value enables the feature on that schedule; an EMPTY (or unset) value
# DISABLES it (and removes any previously-installed unit). The recommended default
# schedules live in .env.template — clear a value there to opt out of that feature.
# (smartd itself always runs for monitoring; SMART_SELFTEST_SCHEDULE only controls
# whether it also schedules self-tests.)
#
# Idempotent: generated configs/units are compared (cmp) before replacing, and
# services/timers are only (re)started when something actually changed.
#
# Env vars:
#   ZFS_POOL                  (required) pool to scrub and monitor
#   REPO_DIR                  (required, set by setup.sh) repo path on this host
#   SMART_SELFTEST_SCHEDULE   smartd `-s` test schedule regex; empty = no self-tests.
#                             Recommended: (S/../.././02|L/../15/./03)
#                             = short self-test daily 02:00, long monthly on the 15th
#                             at 03:00. Long tests are slow on large drives (tens of
#                             hours on a multi-TB drive), so monthly — not weekly — keeps
#                             load sane.
#   ZFS_SCRUB_SCHEDULE        systemd OnCalendar for the scrub; empty = no scheduled
#                             scrub. Recommended: Sun *-*-01..07 03:00:00 (1st Sunday).
#   ZFS_HEALTH_CHECK_SCHEDULE systemd OnCalendar for the health check; empty = none.
#                             Recommended: *-*-* 08:00:00 (daily).

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

validate_env ZFS_POOL REPO_DIR

# Default to empty (feature disabled) when unset, so `set -u` is satisfied and a blank
# value cleanly means "don't schedule this".
SMART_SELFTEST_SCHEDULE="${SMART_SELFTEST_SCHEDULE:-}"
ZFS_SCRUB_SCHEDULE="${ZFS_SCRUB_SCHEDULE:-}"
ZFS_HEALTH_CHECK_SCHEDULE="${ZFS_HEALTH_CHECK_SCHEDULE:-}"

STORAGE_DIR="$REPO_DIR/scripts/storage"

# Ensure the host-side scripts are executable (the worktree may not carry the exec
# bit; the systemd units invoke them by path).
chmod +x "$STORAGE_DIR"/*.sh

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

# Disable + remove a systemd unit if it exists (used when a feature is turned off).
remove_unit() {
    local unit="$1"
    if [ -f "/etc/systemd/system/$unit" ]; then
        systemctl disable --now "$unit" > /dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$unit"
        DAEMON_RELOAD=true
        echo "  removed $unit"
    fi
}

# --- smartmontools / smartd: drive monitoring (+ scheduled self-tests if enabled) ---

echo "Installing smartmontools..."
apt-get update -qq > /dev/null
apt-get install -y -qq smartmontools > /dev/null

# Include the self-test schedule directive only when one is configured.
SMART_SELFTEST_DIRECTIVE=""
if [ -n "$SMART_SELFTEST_SCHEDULE" ]; then
    SMART_SELFTEST_DIRECTIVE=" -s ${SMART_SELFTEST_SCHEDULE}"
fi

SMARTD_CONF="/etc/smartd.conf"
TEMP_SMARTD=$(mktemp)
cat > "$TEMP_SMARTD" <<EOF
# Managed by homelab configure-storage-health module. Do not edit by hand.
#
# DEVICESCAN applies the directives below to every drive smartd auto-detects.
#   -a              monitor all standard attributes (health, self-test log, etc.)
#   -o on           enable automatic offline data collection
#   -S on           enable attribute autosave
#   -n standby,q    don't spin up disks that are in standby just to poll them
#   -s ...          scheduled self-tests (only present when SMART_SELFTEST_SCHEDULE set)
#   -W 4,45,55      temperature: log on 4C change, warn at 45C, critical at 55C
# Degradation is logged to syslog/journal (smartd default). Active push
# notification (-M exec / email) is intentionally omitted until the homelab
# alerting backend is chosen.
DEVICESCAN -a -o on -S on -n standby,q${SMART_SELFTEST_DIRECTIVE} -W 4,45,55
EOF

if [ "$(install_if_changed "$TEMP_SMARTD" "$SMARTD_CONF")" = "changed" ]; then
    echo "  smartd.conf updated"
    systemctl enable smartmontools.service > /dev/null 2>&1 || true
    systemctl restart smartmontools.service
    echo "  smartd restarted"
else
    echo "  smartd.conf unchanged"
    systemctl enable --now smartmontools.service > /dev/null 2>&1 || true
fi

# --- ZFS scrub timer (gated by ZFS_SCRUB_SCHEDULE) ---

if [ -n "$ZFS_SCRUB_SCHEDULE" ]; then
    TEMP_UNIT=$(mktemp)
    cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=Homelab ZFS scrub of pool ${ZFS_POOL}
After=zfs.target
Requires=zfs.target

[Service]
Type=oneshot
# A scrub can run for hours; do not let systemd time it out.
TimeoutStartSec=0
ExecStart=${STORAGE_DIR}/zfs-scrub.sh ${ZFS_POOL}
EOF
    [ "$(install_if_changed "$TEMP_UNIT" /etc/systemd/system/homelab-zfs-scrub.service)" = "changed" ] && DAEMON_RELOAD=true

    TEMP_UNIT=$(mktemp)
    cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=Homelab ZFS scrub timer

[Timer]
OnCalendar=${ZFS_SCRUB_SCHEDULE}
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF
    [ "$(install_if_changed "$TEMP_UNIT" /etc/systemd/system/homelab-zfs-scrub.timer)" = "changed" ] && DAEMON_RELOAD=true
else
    remove_unit homelab-zfs-scrub.timer
    remove_unit homelab-zfs-scrub.service
fi

# --- ZFS pool health-check timer (gated by ZFS_HEALTH_CHECK_SCHEDULE) ---

if [ -n "$ZFS_HEALTH_CHECK_SCHEDULE" ]; then
    TEMP_UNIT=$(mktemp)
    cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=Homelab ZFS pool health check for ${ZFS_POOL}
After=zfs.target
Requires=zfs.target

[Service]
Type=oneshot
ExecStart=${STORAGE_DIR}/zfs-health-check.sh ${ZFS_POOL}
EOF
    [ "$(install_if_changed "$TEMP_UNIT" /etc/systemd/system/homelab-zfs-health-check.service)" = "changed" ] && DAEMON_RELOAD=true

    TEMP_UNIT=$(mktemp)
    cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=Homelab ZFS pool health check timer

[Timer]
OnCalendar=${ZFS_HEALTH_CHECK_SCHEDULE}
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
EOF
    [ "$(install_if_changed "$TEMP_UNIT" /etc/systemd/system/homelab-zfs-health-check.timer)" = "changed" ] && DAEMON_RELOAD=true
else
    remove_unit homelab-zfs-health-check.timer
    remove_unit homelab-zfs-health-check.service
fi

if [ "$DAEMON_RELOAD" = true ]; then
    systemctl daemon-reload
    echo "  systemd units updated"
else
    echo "  systemd units unchanged"
fi

# Enable/start only the timers whose feature is configured (idempotent).
if [ -n "$ZFS_SCRUB_SCHEDULE" ]; then
    systemctl enable --now homelab-zfs-scrub.timer > /dev/null
fi
if [ -n "$ZFS_HEALTH_CHECK_SCHEDULE" ]; then
    systemctl enable --now homelab-zfs-health-check.timer > /dev/null
fi

echo "Storage health configured (scrub: '${ZFS_SCRUB_SCHEDULE:-disabled}', health check: '${ZFS_HEALTH_CHECK_SCHEDULE:-disabled}', SMART self-tests: '${SMART_SELFTEST_SCHEDULE:-disabled}')"
