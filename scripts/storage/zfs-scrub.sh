#!/bin/bash
# zfs-scrub.sh <pool>
#
# Start a scrub of the given ZFS pool, wait for it to finish, then evaluate the
# result via zfs-health-check.sh (which exits non-zero — failing this systemd unit
# — if the scrub found errors or the pool is degraded). Invoked monthly by the
# homelab-zfs-scrub.service timer.
#
# Scrub cadence note: monthly is the recommended interval for spinning HDDs —
# frequent enough to catch latent corruption / bit-rot, infrequent enough to
# avoid the constant random-IO load (and wear) of weekly scrubs. The unit avoids
# overlapping by skipping if a scrub is already running.
#
# Detection only: a failed scrub / degraded pool surfaces via `systemctl --failed`
# and the journal. Active push notifications are deferred until the homelab
# alerting backend is chosen.

set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
POOL="${1:?usage: zfs-scrub.sh <pool>}"

if ! command -v zpool >/dev/null 2>&1; then
    echo "zpool not found; not a ZFS host — skipping scrub." >&2
    exit 0
fi

if ! zpool list -H -o name "$POOL" >/dev/null 2>&1; then
    echo "ERROR: scheduled scrub could not run — pool '$POOL' not found on $(hostname)." >&2
    exit 1
fi

if zpool status "$POOL" | grep -q 'scrub in progress'; then
    echo "A scrub is already in progress on '$POOL'; not starting another."
else
    echo "Starting scrub of '$POOL' (waiting for completion)..."
    # -w waits for the scrub to finish so the post-scrub health check below
    # evaluates this run's result.
    zpool scrub -w "$POOL"
    echo "Scrub of '$POOL' finished."
fi

exec "$DIR/zfs-health-check.sh" "$POOL"
