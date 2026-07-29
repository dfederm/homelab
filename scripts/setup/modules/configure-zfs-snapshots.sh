#!/bin/bash
# Module: configure-zfs-snapshots (Proxmox host only)
#
# Schedules recursive ZFS snapshots of the configured datasets, with per-period
# retention. Host-only because the pool is owned by bare metal, like the sibling
# configure-storage-health module.
#
# Snapshots cover the failure mode that offsite backup covers worst: an
# accidental delete or a bad edit noticed minutes-to-days later. Recovery is a
# copy out of <mountpoint>/.zfs/snapshot/<name>/ — instant, free, and needs no
# restore job. They are explicitly NOT a backup: they share the pool's fate, so
# they complement the offsite copy rather than replacing it.
#
# Deliberately plain systemd timers + scripts/storage/zfs-snapshot.sh rather than
# sanoid: sanoid would add a Perl runtime plus its own INI file as a second source
# of truth that this repo would then have to generate and keep in sync, to
# schedule what two `zfs` commands already do. Timers also match every other
# scheduled task here, so there is one thing to learn and one place to look when
# something didn't run.
#
# Schedule semantics (mirrors configure-storage-health): each period is gated by
# its own schedule env var. A NON-EMPTY value enables that period on that systemd
# OnCalendar; an EMPTY (or unset) value DISABLES it and removes its units. The
# recommended defaults live in .env.template.
#
# Idempotent: generated units are compared (cmp) before replacing; timers are
# only (re)started when something actually changed.
#
# Env vars:
#   REPO_DIR                       (required, set by setup.sh) repo path
#   ZFS_SNAPSHOT_DATASETS          space-separated datasets to snapshot
#                                  recursively (e.g. "tank/homelab tank/media").
#                                  Required when any schedule below is set.
#   ZFS_SNAPSHOT_HOURLY_SCHEDULE   OnCalendar; empty = no hourly snapshots
#   ZFS_SNAPSHOT_HOURLY_KEEP       how many hourly snapshots to retain
#   ZFS_SNAPSHOT_DAILY_SCHEDULE    OnCalendar; empty = no daily snapshots
#   ZFS_SNAPSHOT_DAILY_KEEP        how many daily snapshots to retain
#   ZFS_SNAPSHOT_MONTHLY_SCHEDULE  OnCalendar; empty = no monthly snapshots
#   ZFS_SNAPSHOT_MONTHLY_KEEP      how many monthly snapshots to retain

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

validate_env REPO_DIR

ZFS_SNAPSHOT_DATASETS="${ZFS_SNAPSHOT_DATASETS:-}"

STORAGE_DIR="$REPO_DIR/scripts/storage"
SNAPSHOT_SCRIPT="$STORAGE_DIR/zfs-snapshot.sh"

if [ ! -f "$SNAPSHOT_SCRIPT" ]; then
    echo "ERROR: snapshot script not found: $SNAPSHOT_SCRIPT" >&2
    exit 1
fi

# The worktree may not carry the exec bit; the units invoke by path.
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

# Disable + remove a systemd unit if it exists (used when a period is turned off).
remove_unit() {
    local unit="$1"
    if [ -f "/etc/systemd/system/$unit" ]; then
        systemctl disable --now "$unit" > /dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$unit"
        DAEMON_RELOAD=true
        echo "  removed $unit"
    fi
}

any_enabled=false
for period in hourly daily monthly; do
    upper="$(echo "$period" | tr '[:lower:]' '[:upper:]')"
    schedule_var="ZFS_SNAPSHOT_${upper}_SCHEDULE"
    keep_var="ZFS_SNAPSHOT_${upper}_KEEP"
    schedule="${!schedule_var:-}"
    keep="${!keep_var:-}"
    unit="homelab-zfs-snapshot-${period}"

    # An empty dataset list means this machine has not opted in. Treat it exactly like an
    # empty schedule — REMOVE the units — rather than returning early: a bare `exit 0`
    # here would leave previously-installed timers running against the old dataset list,
    # so clearing the variable would look like "disabled" while snapshots kept being
    # taken. The recommended schedules in .env.template stay inert until a dataset is named.
    if [ -z "$schedule" ] || [ -z "$ZFS_SNAPSHOT_DATASETS" ]; then
        remove_unit "${unit}.timer"
        remove_unit "${unit}.service"
        continue
    fi

    if [ -z "$keep" ]; then
        echo "ERROR: $schedule_var is set but $keep_var is empty" >&2
        exit 1
    fi

    any_enabled=true

    TEMP_UNIT=$(mktemp)
    cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=Homelab ${period} ZFS snapshots
After=zfs.target
Requires=zfs.target

[Service]
Type=oneshot
ExecStart=${SNAPSHOT_SCRIPT} ${period} ${keep} ${ZFS_SNAPSHOT_DATASETS}
EOF
    [ "$(install_if_changed "$TEMP_UNIT" "/etc/systemd/system/${unit}.service")" = "changed" ] && DAEMON_RELOAD=true

    TEMP_UNIT=$(mktemp)
    cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=Homelab ${period} ZFS snapshot timer

[Timer]
OnCalendar=${schedule}
Persistent=true
# Deliberately no RandomizedDelaySec: snapshots are near-instant, and a spread
# would blur the "top of the hour" boundary that makes a snapshot name mean
# something when you are hunting for the state just before a mistake.

[Install]
WantedBy=timers.target
EOF
    [ "$(install_if_changed "$TEMP_UNIT" "/etc/systemd/system/${unit}.timer")" = "changed" ] && DAEMON_RELOAD=true
done

if [ "$DAEMON_RELOAD" = true ]; then
    systemctl daemon-reload
    echo "  systemd units updated"
else
    echo "  systemd units unchanged"
fi

# Enable/start only the periods that are configured (idempotent).
for period in hourly daily monthly; do
    upper="$(echo "$period" | tr '[:lower:]' '[:upper:]')"
    schedule_var="ZFS_SNAPSHOT_${upper}_SCHEDULE"
    if [ -n "${!schedule_var:-}" ] && [ -n "$ZFS_SNAPSHOT_DATASETS" ]; then
        systemctl enable --now "homelab-zfs-snapshot-${period}.timer" > /dev/null
    fi
done

if [ "$any_enabled" = true ]; then
    echo "ZFS snapshots configured for: ${ZFS_SNAPSHOT_DATASETS}"
    echo "  hourly: '${ZFS_SNAPSHOT_HOURLY_SCHEDULE:-disabled}' (keep ${ZFS_SNAPSHOT_HOURLY_KEEP:-n/a})"
    echo "  daily: '${ZFS_SNAPSHOT_DAILY_SCHEDULE:-disabled}' (keep ${ZFS_SNAPSHOT_DAILY_KEEP:-n/a})"
    echo "  monthly: '${ZFS_SNAPSHOT_MONTHLY_SCHEDULE:-disabled}' (keep ${ZFS_SNAPSHOT_MONTHLY_KEEP:-n/a})"
elif [ -z "$ZFS_SNAPSHOT_DATASETS" ]; then
    echo "ZFS snapshots disabled (ZFS_SNAPSHOT_DATASETS is empty)"
else
    echo "ZFS snapshots disabled (no schedules set)"
fi
