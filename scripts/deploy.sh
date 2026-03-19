#!/bin/bash
# Deploy changes on this machine.
#
# Pulls latest repo changes, then runs setup.sh which handles both
# setup modules and service deployment. Idempotent — unchanged modules
# are no-ops and unchanged containers are not restarted.
#
# Usage: ./scripts/deploy.sh

set -euo pipefail

SCRIPT=$(readlink -f "$0")
REPO_DIR=$(dirname "$(dirname "$SCRIPT")")

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "=== Deploy: $(hostname) ==="

cd "$REPO_DIR"

# Needed when the repo is bind-mounted from a different host/user
if ! git config --global --get-all safe.directory 2>/dev/null | grep -qFx "$REPO_DIR"; then
    git config --global --add safe.directory "$REPO_DIR"
fi

log "Pulling latest changes..."
git fetch origin main
git reset --hard origin/main

log "Running setup (modules + services)..."
bash "$REPO_DIR/scripts/setup/setup.sh"

log "=== Deploy complete ==="