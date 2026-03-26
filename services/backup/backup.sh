#!/bin/sh

# Run rclone sync for each target sequentially.
# BACKUP_TARGETS format: "Dir1=remote1:/path Dir2=remote2:/path ..."
# Directory names must not contain spaces.
# Failures are logged but don't prevent other targets from running.

if [ -z "$BACKUP_TARGETS" ]; then
    echo "ERROR: BACKUP_TARGETS is not set or empty"
    exit 1
fi

failed=0
for target in $BACKUP_TARGETS; do
    source_dir="${target%%=*}"
    dest="${target#*=}"
    echo "--- Syncing $source_dir to $dest ---"
    rclone sync "/data/$source_dir" "$dest" -v --create-empty-src-dirs --metadata --modify-window 2s \
        --exclude "Thumbs.db" \
        --exclude "desktop.ini" \
        --exclude ".DS_Store"
    rc=$?
    if [ $rc -eq 0 ]; then
        echo "--- $source_dir sync complete ---"
    else
        echo "--- ERROR: $source_dir sync failed (exit code $rc) ---"
        failed=$((failed + 1))
    fi
done

if [ "$failed" -gt 0 ]; then
    echo "$failed backup(s) failed"
    exit 1
fi
