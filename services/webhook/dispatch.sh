#!/bin/bash
# Signal each top-level target to update from the latest origin/main.

set -euo pipefail

SCRIPT=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT")
source "$SCRIPT_DIR/lib.sh"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

REF="${1:-unknown}"
DEPLOY_KEY_PATH_FROM_CONTAINER="${DEPLOY_KEY_PATH:-}"

source_env
[ -n "$DEPLOY_KEY_PATH_FROM_CONTAINER" ] \
    && DEPLOY_KEY_PATH="$DEPLOY_KEY_PATH_FROM_CONTAINER"

log "=== Deployment signal ==="
log "Ref: $REF"

if [ -z "${HOMELAB_DEPLOY_TARGETS:-}" ]; then
    log "WARNING: HOMELAB_DEPLOY_TARGETS is empty"
    exit 0
fi

validate_env DEPLOY_KEY_PATH
DEPLOY_KEY_TEMP=$(mktemp)
trap 'rm -f "$DEPLOY_KEY_TEMP"' EXIT
cp "$DEPLOY_KEY_PATH" "$DEPLOY_KEY_TEMP"
chmod 600 "$DEPLOY_KEY_TEMP"

FAILED=()
for PREFIX in $HOMELAB_DEPLOY_TARGETS; do
    host_var="${PREFIX}_DEPLOY_HOST"
    TARGET_HOST="${!host_var:-}"

    if [ -z "$TARGET_HOST" ]; then
        log "WARNING: ${PREFIX}_DEPLOY_HOST not set, skipping"
        FAILED+=("$PREFIX")
        continue
    fi

    log "Signaling ${PREFIX} (${TARGET_HOST})..."
    # shellcheck disable=SC2029
    if ! ssh -i "$DEPLOY_KEY_TEMP" \
        -o StrictHostKeyChecking=accept-new \
        -o BatchMode=yes \
        "root@${TARGET_HOST}" \
        '/usr/local/lib/homelab/deploy-signal.sh'; then
        log "WARNING: Could not signal ${PREFIX}; periodic reconciliation remains active"
        FAILED+=("$PREFIX")
    fi
done

if [ ${#FAILED[@]} -gt 0 ]; then
    log "ERROR: Failed to signal: ${FAILED[*]}"
    exit 1
fi

log "=== Deployment signal complete ==="
