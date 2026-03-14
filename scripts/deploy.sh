#!/bin/bash
# Deploy script triggered by webhook on git push to main.
# Pulls latest changes and redeploys all services.
#
# Usage: ./scripts/deploy.sh [ref]
#   ref: Git ref that was pushed (e.g., refs/heads/main). Optional.

set -euo pipefail

SCRIPT=$(readlink -f "$0")
REPO_DIR=$(dirname "$(dirname "$SCRIPT")")

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "=== Deploy triggered ==="
log "Ref: ${1:-unknown}"

cd "$REPO_DIR"

log "Pulling latest changes..."
git fetch origin main
git reset --hard origin/main

log "Deploying all services..."
bash "$REPO_DIR/scripts/run-all-services.sh"

log "=== Deploy complete ==="
