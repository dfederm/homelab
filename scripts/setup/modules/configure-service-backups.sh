#!/bin/bash
# Module: configure-service-backups (Docker host)
#
# Schedules scripts/backup-service-state.sh, which stages consistent copies of
# service state (databases, Forgejo, config dirs) into SERVICE_BACKUP_ROOT.
#
# Why a timer here rather than another rclone container: the services/backup
# containers are bare rclone images, so they can copy files but cannot ask a
# service for a consistent copy of itself. `forgejo dump`, `pg_dump` and
# sqlite3's backup API have to run where Docker is, which is this host. The
# staging tree this produces is then shipped offsite by an ordinary
# services/backup target pointed at SERVICE_BACKUP_ROOT — so there is still one
# cloud-sync mechanism, just fed with something safe to copy.
#
# Schedule semantics (mirrors configure-storage-health / configure-lxc-fstrim): a
# NON-EMPTY SERVICE_BACKUP_SCHEDULE enables the timer on that systemd OnCalendar;
# an EMPTY (or unset) value DISABLES it and removes any previously-installed unit.
# The recommended default lives in .env.template.
#
# Idempotent: generated units are compared (cmp) before replacing; the timer is
# only (re)started when something actually changed.
#
# Env vars:
#   REPO_DIR                (required, set by setup.sh) repo path on this host
#   SERVICE_BACKUP_SCHEDULE systemd OnCalendar for the staging run; empty =
#                           disabled. Must land far enough BEFORE the BACKUP_CRON
#                           of the target that ships SERVICE_BACKUP_ROOT that a
#                           slow dump cannot still be running when the sync starts.
#   SERVICE_BACKUP_ROOT     staging dir (consumed by the backup script)
#   SERVICE_BACKUP_JOBS     jobs to stage (consumed by the backup script)

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

validate_env REPO_DIR

SERVICE_BACKUP_SCHEDULE="${SERVICE_BACKUP_SCHEDULE:-}"

BACKUP_SCRIPT="$REPO_DIR/scripts/backup-service-state.sh"
SERVICE_FILE="/etc/systemd/system/homelab-service-backup.service"
TIMER_FILE="/etc/systemd/system/homelab-service-backup.timer"

if [ ! -f "$BACKUP_SCRIPT" ]; then
    echo "ERROR: backup script not found: $BACKUP_SCRIPT" >&2
    exit 1
fi

# The worktree may not carry the exec bit, and the unit below invokes the script via
# /bin/bash rather than relying on it — but keep the bit correct so a hand-run works too.
chmod +x "$BACKUP_SCRIPT"

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

if [ -n "$SERVICE_BACKUP_SCHEDULE" ]; then
    # rsync mirrors file-type jobs; sqlite3 provides the online-backup API that
    # makes a live SQLite database safe to copy. Both are absent from a minimal
    # Debian LXC, and a missing one would fail the job at 01:00 rather than here.
    echo "Installing backup tooling (rsync, sqlite3)..."
    apt_get update -qq > /dev/null
    apt_get install -y -qq rsync sqlite3 > /dev/null

    # The sender for the failure alert. Best-effort — the run still logs to the
    # journal and fails its unit if this is unavailable.
    if ! ensure_shoutrrr; then
        echo "  WARNING: shoutrrr CLI unavailable; backup failures log to syslog only until it installs."
    fi

    TEMP_UNIT=$(mktemp)
    cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=Homelab service-state backup staging
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
# Generous but FINITE. A dump can legitimately run long, but with no timeout at all a
# hung run sits in "activating" forever: it never fails the unit, so it reaches neither
# the failed-unit list nor the alert below, and the next timer tick is skipped because
# the unit is still "running" — silently stopping backups with no signal anywhere.
TimeoutStartSec=4h
ExecStart=/bin/bash ${BACKUP_SCRIPT}
EOF
    [ "$(install_if_changed "$TEMP_UNIT" "$SERVICE_FILE")" = "changed" ] && DAEMON_RELOAD=true

    TEMP_UNIT=$(mktemp)
    cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=Homelab service-state backup timer

[Timer]
OnCalendar=${SERVICE_BACKUP_SCHEDULE}
Persistent=true
# Deliberately no RandomizedDelaySec: the staging run has to finish before the
# rclone target that ships it starts, and a random spread would erode that gap.

[Install]
WantedBy=timers.target
EOF
    [ "$(install_if_changed "$TEMP_UNIT" "$TIMER_FILE")" = "changed" ] && DAEMON_RELOAD=true
else
    remove_unit homelab-service-backup.timer
    remove_unit homelab-service-backup.service
fi

if [ "$DAEMON_RELOAD" = true ]; then
    systemctl daemon-reload
    echo "  systemd units updated"
else
    echo "  systemd units unchanged"
fi

# Enable/start the timer only when the feature is configured (idempotent).
if [ -n "$SERVICE_BACKUP_SCHEDULE" ]; then
    systemctl enable --now homelab-service-backup.timer > /dev/null
fi

echo "Service-state backup configured (schedule: '${SERVICE_BACKUP_SCHEDULE:-disabled}', jobs: '${SERVICE_BACKUP_JOBS:-none}')"
