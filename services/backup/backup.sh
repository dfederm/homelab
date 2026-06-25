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

echo "--- Syncing /data to $BACKUP_DEST ---"
rclone sync /data "$BACKUP_DEST" -v --create-empty-src-dirs --metadata --modify-window 2s \
    --exclude "Thumbs.db" \
    --exclude "desktop.ini" \
    --exclude ".DS_Store"
echo "--- Sync complete ---"
