#!/bin/bash
# storage-space-check.sh - Threshold check for the storage that Beszel can't see.
#
# Beszel's agent reports per-mount *filesystem* usage (statfs). Two important
# capacity numbers on the Proxmox host are NOT filesystems and so are invisible
# to Beszel:
#   1. The LVM thin pool (pve/data) - backs every LXC rootfs + VM disk. When it
#      fills, containers/VMs go read-only. Visible only via `lvs data_percent`.
#   2. The ZFS pool's true capacity % - `zpool list` is authoritative;
#      a ZFS dataset's statfs % is only a pool-relative proxy.
#
# This script reads both, prints them (a CLI at-a-glance), and fires a threshold
# alert through the shared alert channel. Intended to run from a systemd timer
# on the Proxmox host; installed by the configure-storage-alerts module.
#
# Env vars (from common.env / the host env file, sourced below):
#   ZFS_POOL                          - ZFS pool name (e.g. tank)
#   STORAGE_ALERT_THINPOOL            - LVM thin pool (default: pve/data)
#   STORAGE_ALERT_THINPOOL_PERCENT    - thin-pool data% alert threshold (default 80)
#   STORAGE_ALERT_ZPOOL_PERCENT       - zpool capacity% alert threshold (default 85)
#   STORAGE_ALERT_COOLDOWN_HOURS      - min hours between repeat alerts (default 12)
#   HOMELAB_ALERT_SHOUTRRR_URL        - shared alert channel (see notify(); stub)

set -euo pipefail

SCRIPT=$(readlink -f "$0")
REPO_DIR=$(dirname "$(dirname "$SCRIPT")")
export REPO_DIR

source "$REPO_DIR/scripts/lib.sh"
source_env

THINPOOL="${STORAGE_ALERT_THINPOOL:-pve/data}"
THINPOOL_THRESHOLD="${STORAGE_ALERT_THINPOOL_PERCENT:-80}"
ZPOOL_THRESHOLD="${STORAGE_ALERT_ZPOOL_PERCENT:-85}"
COOLDOWN_HOURS="${STORAGE_ALERT_COOLDOWN_HOURS:-12}"
STATE_DIR="/var/lib/homelab-storage-alerts"

mkdir -p "$STATE_DIR"

# Returns 0 (true) if float $1 is greater than float $2.
gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; }

# Deliver an alert through the shared channel, honoring a per-key cooldown so a
# persistently-full disk doesn't notify on every run.
notify() {
    local key="$1" title="$2" body="$3"
    local stamp="$STATE_DIR/${key}.last"
    local now cooldown_secs
    now=$(date +%s)
    cooldown_secs=$(( COOLDOWN_HOURS * 3600 ))

    if [ -f "$stamp" ]; then
        local last
        last=$(cat "$stamp" 2>/dev/null || echo 0)
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        if [ $(( now - last )) -lt "$cooldown_secs" ]; then
            echo "  (within cooldown; not re-alerting for '$key')"
            return 0
        fi
    fi

    local full="$title - $body"
    logger -t homelab-storage-alert "$full" 2>/dev/null || true
    echo "ALERT: $full"

    # --- Alert delivery via the shared Shoutrrr channel (backend: Pushover) ---
    # HOMELAB_ALERT_SHOUTRRR_URL (common.env) is the ONE channel shared with the
    # Beszel hub and scrutiny. Backend is Pushover:
    #   pushover://shoutrrr:<APP_TOKEN>@<USER_KEY>/
    # The shoutrrr CLI (installed by the configure-storage-alerts module) sends it.
    # If the URL is unset (not yet configured) the alert is logged to syslog only -
    # a safe no-op - so the check is harmless before Pushover credentials are set.
    if [ -n "${HOMELAB_ALERT_SHOUTRRR_URL:-}" ]; then
        if command -v shoutrrr &>/dev/null; then
            if shoutrrr send --url "$HOMELAB_ALERT_SHOUTRRR_URL" \
                --title "homelab storage" --message "$full"; then
                echo "$now" > "$stamp"
            else
                echo "  WARNING: shoutrrr send failed; will retry next run" >&2
            fi
            return 0
        fi
        echo "  WARNING: HOMELAB_ALERT_SHOUTRRR_URL set but 'shoutrrr' CLI missing; logged only" >&2
    fi
    # Stub path: record the alert time so syslog isn't spammed every run either.
    echo "$now" > "$stamp"
}

echo "=== Storage space check: $(hostname) $(date '+%Y-%m-%d %H:%M:%S') ==="

# --- LVM thin pool (backs all LXC rootfs + VM disks) ---

if command -v lvs &>/dev/null; then
    thinpool_pct=$(lvs --noheadings -o data_percent "$THINPOOL" 2>/dev/null | tr -d ' ' || true)
    if [ -n "$thinpool_pct" ]; then
        echo "LVM thin pool $THINPOOL: ${thinpool_pct}% used (threshold ${THINPOOL_THRESHOLD}%)"
        if gt "$thinpool_pct" "$THINPOOL_THRESHOLD"; then
            notify "thinpool" "LVM thin pool ${THINPOOL} is ${thinpool_pct}% full" \
                "All LXC rootfs and VM disks live here; at 100% they go read-only. Reclaim space or extend the pool."
        fi
    else
        echo "WARNING: could not read data_percent for thin pool $THINPOOL" >&2
    fi
else
    echo "WARNING: lvs not found; skipping thin-pool check" >&2
fi

# --- ZFS pool capacity (authoritative pool used-%) ---

if command -v zpool &>/dev/null && [ -n "${ZFS_POOL:-}" ]; then
    zpool_pct=$(zpool list -H -o capacity "$ZFS_POOL" 2>/dev/null | tr -d ' %' || true)
    if [ -n "$zpool_pct" ]; then
        echo "ZFS pool $ZFS_POOL: ${zpool_pct}% used (threshold ${ZPOOL_THRESHOLD}%)"
        if gt "$zpool_pct" "$ZPOOL_THRESHOLD"; then
            notify "zpool" "ZFS pool ${ZFS_POOL} is ${zpool_pct}% full" \
                "Free space is shared by all datasets on the pool. ZFS performance degrades when very full."
        fi
    else
        echo "WARNING: could not read capacity for ZFS pool $ZFS_POOL" >&2
    fi
else
    echo "WARNING: zpool not found or ZFS_POOL unset; skipping pool check" >&2
fi

echo "=== Storage space check complete ==="
