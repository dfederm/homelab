#!/bin/sh

# Sync this target's source directory to its rclone destination.
# /data is the source (one target's directory, mounted read-only).
# BACKUP_DEST is the rclone destination ("remote:path").
# Exits non-zero on failure so the failure surfaces (container logs / monitoring).

set -eu

if [ -z "${BACKUP_DEST:-}" ]; then
    echo "ERROR: BACKUP_DEST is not set or empty"
    exit 1
fi

# Refuse to sync a target that declared it holds secrets unless its destination
# really is an encrypted remote. Some targets (the homelab config dir, the staged
# service state) carry every credential in the lab; sending those to a consumer
# cloud in the clear is a silent, unrecoverable mistake, and "the remote name has
# crypt in it" is not proof. rclone is the only thing here that can read the
# config, so the check lives at sync time rather than in the deploy-time guard.
if [ "${BACKUP_REQUIRE_ENCRYPTION:-}" = "true" ]; then
    remote="${BACKUP_DEST%%:*}"
    # An empty remote name would make `rclone config show` dump every remote, and a
    # crypt entry belonging to some other target would then satisfy the check.
    if [ -z "$remote" ] || [ "$remote" = "$BACKUP_DEST" ]; then
        echo "ERROR: BACKUP_REQUIRE_ENCRYPTION=true but BACKUP_DEST='$BACKUP_DEST' names no remote."
        echo "       Expected remote:path form."
        exit 1
    fi
    if ! rclone config show "$remote" 2>/dev/null | grep -qE '^type[[:space:]]*=[[:space:]]*crypt$'; then
        echo "ERROR: BACKUP_REQUIRE_ENCRYPTION=true but remote '$remote' is not an rclone crypt remote."
        echo "       Refusing to upload this target's data unencrypted. Create a crypt remote"
        echo "       wrapping the cloud path and point BACKUP_DEST at it."
        exit 1
    fi
    echo "Destination remote '$remote' is an rclone crypt remote (encryption required by this target)."
fi

# Optional extra args, built positionally so patterns with spaces stay intact.
set --

# Keep the copy the sync is about to supersede. rclone sync MIRRORS, so without this
# the nightly run happily propagates a local corruption or an accidental deletion
# over the last good copy. --backup-dir moves the superseded file aside on the remote
# instead of destroying it — server-side, so it costs no extra upload. The archive is
# a mirror path too, so this retains the most recent superseded copy of each file
# rather than a full history. The archive must be on the same remote as the
# destination and disjoint from every target's; pre-up.sh enforces both.
if [ -n "${BACKUP_ARCHIVE_DEST:-}" ]; then
    set -- "$@" --backup-dir "$BACKUP_ARCHIVE_DEST"
fi

# Optional per-target exclude patterns (space-separated rclone filter patterns),
# for sources holding large regenerable content next to the irreplaceable kind —
# e.g. Immich's thumbs/ and encoded-video/, which are rebuilt from the originals.
# Deliberately unquoted: the value is a list and must word-split.
if [ -n "${BACKUP_EXCLUDE:-}" ]; then
    for pattern in ${BACKUP_EXCLUDE}; do
        set -- "$@" --exclude "$pattern"
    done
fi

echo "--- Syncing /data to $BACKUP_DEST ---"

# Refuse to sync an empty source. rclone sync mirrors, so an empty /data means
# "delete everything at the destination" — and the usual reason /data is empty is
# that the bind mount resolved to the wrong path, in which case Docker silently
# created an empty directory for it. Failing here turns a misconfiguration into a
# loud no-op instead of the destruction of an offsite backup. A target whose
# source really is empty can set BACKUP_ALLOW_EMPTY_SOURCE=true.
if [ -z "$(ls -A /data 2>/dev/null)" ] && [ "${BACKUP_ALLOW_EMPTY_SOURCE:-}" != "true" ]; then
    echo "ERROR: source /data is empty — refusing to sync, which would delete everything"
    echo "       under $BACKUP_DEST. Check that BACKUP_DATA_ROOT/BACKUP_SOURCE_DIR point at"
    echo "       a real directory. Set BACKUP_ALLOW_EMPTY_SOURCE=true if empty is expected."
    exit 1
fi

rclone sync /data "$BACKUP_DEST" -v --create-empty-src-dirs --metadata --modify-window 2s \
    --exclude "Thumbs.db" \
    --exclude "desktop.ini" \
    --exclude ".DS_Store" \
    "$@"
echo "--- Sync complete ---"

# Dead-man's-switch ping (e.g. an Uptime Kuma push monitor URL). Only reached on a
# successful sync, so the monitor alerts both when a sync fails AND when it stops
# running at all — the failure mode a container-logs-only design can't see.
# Best-effort: a monitoring outage must not mark a good backup as failed.
if [ -n "${BACKUP_HEARTBEAT_URL:-}" ]; then
    if command -v wget > /dev/null 2>&1; then
        wget -q -O /dev/null --timeout=10 "$BACKUP_HEARTBEAT_URL" \
            && echo "Heartbeat sent" \
            || echo "WARNING: heartbeat ping failed (backup itself succeeded)"
    else
        echo "WARNING: BACKUP_HEARTBEAT_URL set but no wget in this image; heartbeat skipped"
    fi
fi
