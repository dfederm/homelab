#!/bin/bash
# Restore Docker named volumes from ZFS-backed backups.
# Run AFTER migration to restore data backed up by backup-volumes.sh.
#
# Usage: ./scripts/backup/restore-volumes.sh [timestamp]
#   If no timestamp given, uses the latest backup for each volume.

set -euo pipefail

ENV_FILE="/etc/homelab.env"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$(readlink -f "$ENV_FILE")"; set +a
fi

: "${DOCKER_APPDATA_ROOT:?DOCKER_APPDATA_ROOT must be set}"

BACKUP_DIR="$DOCKER_APPDATA_ROOT/volume-backups"
TIMESTAMP="${1:-}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

restore_volume() {
    local volume="$1"

    # Find the backup archive
    local archive
    if [ -n "$TIMESTAMP" ]; then
        archive="$BACKUP_DIR/${volume}_${TIMESTAMP}.tar.gz"
    else
        archive=$(ls -t "$BACKUP_DIR"/${volume}_*.tar.gz 2>/dev/null | head -1)
    fi

    if [ -z "$archive" ] || [ ! -f "$archive" ]; then
        log "WARNING: No backup found for $volume, skipping"
        return
    fi

    log "Restoring $volume from $archive..."

    # Create volume if it doesn't exist
    docker volume create "$volume" &>/dev/null || true

    docker run --rm \
        -v "${volume}:/target" \
        -v "$BACKUP_DIR:/backup:ro" \
        alpine sh -c "rm -rf /target/* && tar xzf /backup/$(basename "$archive") -C /target"

    log "  $volume restored"
}

if [ ! -d "$BACKUP_DIR" ]; then
    echo "ERROR: Backup directory not found: $BACKUP_DIR" >&2
    exit 1
fi

# Restore in same order as backup
restore_volume "immich_database-data"
restore_volume "monitoring_beszel-data"
restore_volume "monitoring_beszel-agent-data"

log "=== Volume restore complete ==="
