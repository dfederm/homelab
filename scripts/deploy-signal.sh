#!/bin/bash
# Record one pending deployment pass and wake the target worker.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
source "$SCRIPT_DIR/deploy-state.sh"

deploy_state_load_env

DEPLOY_STATE_DIR="${DEPLOY_STATE_DIR:-/var/lib/homelab-deploy}"
if ! deploy_state_validate_absolute_path "$DEPLOY_STATE_DIR"; then
    echo "ERROR: DEPLOY_STATE_DIR must be a safe absolute path" >&2
    exit 1
fi

mkdir -p "$DEPLOY_STATE_DIR"
exec 9> "$DEPLOY_STATE_DIR/state.lock"
flock 9

coalesced=false
[ -f "$DEPLOY_STATE_DIR/pending" ] && coalesced=true
deploy_state_atomic_write "$DEPLOY_STATE_DIR/pending" \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
deploy_state_append_event "$DEPLOY_STATE_DIR/events.log" signal \
    "coalesced=$coalesced"

flock -u 9
exec 9>&-

systemctl start --no-block homelab-deploy-worker.service
