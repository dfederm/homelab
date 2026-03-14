#!/bin/bash
# Back up Docker named volumes to ZFS-backed storage.
# Run BEFORE migration to preserve data that lives on local disk.
# Restoring: see scripts/backup/restore-volumes.sh
#
# Usage: ./scripts/backup/backup-volumes.sh

set -euo pipefail

ENV_FILE="/etc/homelab.env"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$(readlink -f "$ENV_FILE")"; set +a
fi

: "${DOCKER_APPDATA_ROOT:?DOCKER_APPDATA_ROOT must be set}"

BACKUP_DIR="$DOCKER_APPDATA_ROOT/volume-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

backup_volume() {
    local volume="$1"
    local archive="$BACKUP_DIR/${volume}_${TIMESTAMP}.tar.gz"

    if ! docker volume inspect "$volume" &>/dev/null; then
        log "WARNING: Volume $volume does not exist, skipping"
        return
    fi

    log "Backing up $volume..."
    docker run --rm \
        -v "${volume}:/source:ro" \
        -v "$BACKUP_DIR:/backup" \
        alpine tar czf "/backup/${volume}_${TIMESTAMP}.tar.gz" -C /source .
    log "  -> $archive"
}

mkdir -p "$BACKUP_DIR"

# Critical: Immich database (all photo metadata)
backup_volume "immich_database-data"

# Optional: Beszel monitoring history
backup_volume "monitoring_beszel-data"
backup_volume "monitoring_beszel-agent-data"

# Skip: model-cache (re-downloads), beszel-socket (runtime)

log "=== Volume backup complete ==="
log "Backups at: $BACKUP_DIR"
ls -lh "$BACKUP_DIR"/*_${TIMESTAMP}.tar.gz 2>/dev/null
