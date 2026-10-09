#!/bin/bash
# zfs-snapshot.sh <period> <keep> <dataset> [<dataset> ...]
#
# Take one recursive snapshot of each dataset and prune that period's older
# snapshots down to <keep>. Invoked by the homelab-zfs-snapshot-<period> systemd
# units installed by the configure-zfs-snapshots module.
#
# Snapshots are the fastest recovery path for the failure mode offsite backup is
# worst at: "I deleted the wrong thing an hour ago". Restoring is a file copy out
# of <mountpoint>/.zfs/snapshot/<name>/ — no download, no restore job, no cost.
# They are NOT a backup: they live on the same pool and die with it.
#
# Names are homelab-<period>-<UTC timestamp>. Two properties matter:
#   - The homelab- prefix scopes pruning. This script destroys ONLY snapshots it
#     created; a manual snapshot, or one another tool made, is never touched.
#   - The timestamp is UTC. A local-time name would collide with itself in the
#     hour that repeats when DST ends, and `zfs snapshot` fails on a name that
#     already exists.
#
# Exits non-zero if anything failed, which fails the systemd unit and surfaces in
# `systemctl --failed` and the journal.

set -euo pipefail

PERIOD="${1:?usage: zfs-snapshot.sh <period> <keep> <dataset>...}"
KEEP="${2:?usage: zfs-snapshot.sh <period> <keep> <dataset>...}"
shift 2

if [ "$#" -eq 0 ]; then
    echo "ERROR: no datasets given" >&2
    exit 1
fi

if ! [[ "$KEEP" =~ ^[0-9]+$ ]]; then
    echo "ERROR: keep count must be a number (got '$KEEP')" >&2
    exit 1
fi

# Keeping 0 would mean "snapshot, then immediately destroy it" — never intended,
# and the way to turn a period off is to clear its schedule.
if [ "$KEEP" -lt 1 ]; then
    echo "ERROR: keep count must be at least 1 (got '$KEEP')" >&2
    exit 1
fi

if ! command -v zfs > /dev/null 2>&1; then
    echo "ERROR: zfs command not found; not a ZFS host" >&2
    exit 1
fi

PREFIX="homelab-${PERIOD}-"
STAMP="$(date -u +%Y-%m-%dT%H%M%SZ)"
failures=0

for dataset in "$@"; do
    if ! zfs list -H -o name "$dataset" > /dev/null 2>&1; then
        echo "ERROR: dataset '$dataset' not found" >&2
        failures=$((failures + 1))
        continue
    fi

    snapshot="${dataset}@${PREFIX}${STAMP}"
    if zfs snapshot -r "$snapshot"; then
        echo "  created $snapshot (recursive)"
    else
        echo "ERROR: failed to create $snapshot" >&2
        failures=$((failures + 1))
        continue
    fi

    # Prune this dataset's own snapshots for this period only. -d 1 keeps the
    # listing to this dataset (children carry the same name and are destroyed by
    # the recursive destroy below, so listing them would double-count).
    # A `zfs list` failure must not degrade to "nothing to prune": that silently stops
    # retention while the snapshot timer keeps creating, which is unbounded growth —
    # exactly what this script exists to prevent.
    if ! listing="$(zfs list -H -d 1 -t snapshot -o name -s creation "$dataset" 2>&1)"; then
        echo "ERROR: could not list snapshots for '$dataset': $listing" >&2
        failures=$((failures + 1))
        continue
    fi
    mapfile -t existing < <(printf '%s\n' "$listing" | grep -F "@${PREFIX}" || true)

    local_count=${#existing[@]}
    if [ "$local_count" -le "$KEEP" ]; then
        echo "  $dataset: $local_count ${PERIOD} snapshot(s), keeping $KEEP — nothing to prune"
        continue
    fi

    prune_count=$((local_count - KEEP))
    echo "  $dataset: $local_count ${PERIOD} snapshot(s), pruning oldest $prune_count"
    for ((i = 0; i < prune_count; i++)); do
        snap="${existing[i]}"
        # Belt and braces before a destroy: the name must be a snapshot of this
        # dataset carrying our own prefix. Without the @ check a malformed name
        # would make this `zfs destroy` a DATASET destroy.
        case "$snap" in
            "${dataset}@${PREFIX}"*) ;;
            *)
                echo "ERROR: refusing to destroy unexpected name '$snap'" >&2
                failures=$((failures + 1))
                continue
                ;;
        esac
        if zfs destroy -r "$snap"; then
            echo "    destroyed $snap"
        else
            # A held or cloned snapshot fails here. Report and keep going rather
            # than abandoning the remaining datasets' pruning.
            echo "ERROR: failed to destroy $snap" >&2
            failures=$((failures + 1))
        fi
    done
done

if [ "$failures" -gt 0 ]; then
    echo "ZFS ${PERIOD} snapshots completed with $failures error(s)" >&2
    exit 1
fi

echo "ZFS ${PERIOD} snapshots complete (kept $KEEP per dataset)"
