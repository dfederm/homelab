#!/bin/bash
# zfs-health-check.sh <pool>
#
# Inspect a ZFS pool's health and its most recent scrub result. On any problem it
# prints the details and exits non-zero — which fails the invoking systemd unit,
# making the failure visible via `systemctl --failed` and the journal.
#
# Problems detected:
#   - pool state not ONLINE (DEGRADED / FAULTED / ...)
#   - `zpool status -x` reports an error or advisory. This is the catch-all: it
#     fires on device read/write/CHECKSUM errors (even corrected ones, where the
#     pool is still ONLINE with "No known data errors"), degraded vdevs, and
#     "device needs attention" advisories that the coarser checks below miss.
#   - known data errors
#   - a scrub that completed WITH errors
#
# Detection only: active push notifications are intentionally deferred until the
# homelab alerting backend is chosen (separate todo).
#
# Safe to run frequently (read-only). Runs daily on a timer and also immediately
# after a scheduled scrub completes.

set -euo pipefail

POOL="${1:?usage: zfs-health-check.sh <pool>}"

if ! command -v zpool >/dev/null 2>&1; then
    echo "zpool not found; not a ZFS host — nothing to check." >&2
    exit 0
fi

if ! zpool list -H -o name "$POOL" >/dev/null 2>&1; then
    echo "ERROR: ZFS pool '$POOL' not found on $(hostname). It may be unimported, faulted, or its disks missing." >&2
    exit 1
fi

status="$(zpool status "$POOL")"
xstatus="$(zpool status -x "$POOL")"
health="$(zpool list -H -o health "$POOL")"
errors_line="$(printf '%s\n' "$status" | sed -n 's/^[[:space:]]*errors:[[:space:]]*//p' | head -n1)"
scan_line="$(printf '%s\n' "$status" | sed -n 's/^[[:space:]]*scan:[[:space:]]*//p' | head -n1)"

problems=()

[ "$health" != "ONLINE" ] && problems+=("Pool state is '$health' (expected ONLINE).")

# `zpool status -x <pool>` prints "pool '<pool>' is healthy" ONLY when there are no
# errors, advisories, or degraded devices. Anything else (including corrected device
# read/write/checksum errors) makes it emit the full status instead — flag that.
if ! printf '%s\n' "$xstatus" | grep -qi 'is healthy'; then
    problems+=("zpool status -x reports an error or advisory (device read/write/checksum errors, a degraded vdev, or a device needing attention).")
fi

if [ -n "$errors_line" ] && [ "$errors_line" != "No known data errors" ]; then
    problems+=("Data errors reported: $errors_line")
fi

# A finished scrub line looks like:
#   scrub repaired 0B in 01:23:45 with 0 errors on Sun ...
# Flag any non-zero error count.
if printf '%s\n' "$scan_line" | grep -qE 'with [1-9][0-9]* errors'; then
    problems+=("Last scrub completed WITH errors: $scan_line")
fi

if [ "${#problems[@]}" -gt 0 ]; then
    {
        echo "ZFS pool '$POOL' on $(hostname) needs attention:"
        for p in "${problems[@]}"; do
            echo "  - $p"
        done
        echo ""
        echo "Full zpool status:"
        printf '%s\n' "$status"
    } >&2
    exit 1
fi

echo "ZFS pool '$POOL' is healthy (state ONLINE, no data/scrub/device errors)."
