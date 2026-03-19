#!/bin/bash
# Dispatch deployments to all machines in the homelab.
#
# Called by the webhook on push to main. SSHes to each deploy target
# and runs deploy.sh, which pulls latest changes and runs setup.sh.
# Everything is idempotent — unchanged modules are no-ops and unchanged
# containers don't restart.
#
# Usage: ./scripts/dispatch.sh [ref]
#   ref: Git ref that was pushed (e.g., refs/heads/main). For logging only.

set -euo pipefail

SCRIPT=$(readlink -f "$0")
REPO_DIR=$(dirname "$(dirname "$SCRIPT")")

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "=== Dispatch triggered ==="
log "Ref: ${1:-unknown}"

cd "$REPO_DIR"

# --- Source env files ---

source "$REPO_DIR/scripts/lib.sh"
source_env

if [ -z "${DEPLOY_KEY_PATH:-}" ]; then
    log "ERROR: DEPLOY_KEY_PATH not set" >&2
    exit 1
fi

# --- Fan out to all deploy targets ---
# Targets are deployed sequentially. Do NOT parallelize — multiple machines
# may share the same repo on a network filesystem (ZFS bind mount, SMB),
# and concurrent git operations on the same .git directory will fail.

DEPLOY_FAILURES=()

for PREFIX in ${HOMELAB_DEPLOY_TARGETS:-}; do
    host_var="${PREFIX}_DEPLOY_HOST"
    TARGET_HOST="${!host_var:-}"

    if [ -z "$TARGET_HOST" ]; then
        log "WARNING: ${PREFIX}_DEPLOY_HOST not set, skipping"
        continue
    fi

    log "Dispatching to ${PREFIX} (${TARGET_HOST})..."
    # shellcheck disable=SC2029
    if ! ssh -i "$DEPLOY_KEY_PATH" \
        -o StrictHostKeyChecking=accept-new \
        -o BatchMode=yes \
        "root@${TARGET_HOST}" \
        'bash -c "source /etc/homelab.env && bash \$REPO_DIR/scripts/deploy.sh"'; then
        log "ERROR: Deploy to ${PREFIX} (${TARGET_HOST}) failed"
        DEPLOY_FAILURES+=("$PREFIX")
    fi
done

if [ ${#DEPLOY_FAILURES[@]} -gt 0 ]; then
    log "ERROR: Deployment failed for: ${DEPLOY_FAILURES[*]}"
    log "=== Dispatch complete (with errors) ==="
    exit 1
fi

log "=== Dispatch complete ==="