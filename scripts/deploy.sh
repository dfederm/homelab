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

if [ "${HOMELAB_SETUP_LOCK_HELD:-0}" != "1" ]; then
    SETUP_LOCK_FILE="${HOMELAB_SETUP_LOCK_FILE:-/run/lock/homelab-setup.lock}"
    mkdir -p "$(dirname "$SETUP_LOCK_FILE")"
    echo "Waiting for setup lock: $SETUP_LOCK_FILE"
    exec flock "$SETUP_LOCK_FILE" env HOMELAB_SETUP_LOCK_HELD=1 \
        /bin/bash "$SCRIPT" "$@"
fi

REPO_DIR=$(dirname "$(dirname "$SCRIPT")")
source "$REPO_DIR/scripts/deploy-state.sh"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "=== Deploy: $(hostname) ==="

cd "$REPO_DIR"

# Needed when the repo is bind-mounted from a different host/user
safe_directories=$(git config --global --get-all safe.directory 2>/dev/null || true)
if ! grep -qFx "$REPO_DIR" <<< "$safe_directories"; then
    git config --global --add safe.directory "$REPO_DIR"
fi

log "Pulling latest changes..."
git fetch origin main
git reset --hard origin/main

log "Running setup (modules + services)..."
bash "$REPO_DIR/scripts/setup/setup.sh"

deploy_state_load_env
DEPLOY_STATE_DIR="${DEPLOY_STATE_DIR:-/var/lib/homelab-deploy}"
if ! deploy_state_validate_absolute_path "$DEPLOY_STATE_DIR"; then
    log "ERROR: DEPLOY_STATE_DIR must be a safe absolute path" >&2
    exit 1
fi
APPLIED_COMMIT=$(git rev-parse 'HEAD^{commit}')
deploy_state_atomic_write "$DEPLOY_STATE_DIR/last-success" "$APPLIED_COMMIT"
deploy_state_append_event "$DEPLOY_STATE_DIR/events.log" manual-success \
    "applied=$APPLIED_COMMIT"

log "=== Deploy complete ==="