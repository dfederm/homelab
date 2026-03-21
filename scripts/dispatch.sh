#!/bin/bash
# Dispatch deployments to all machines in the homelab.
#
# Called by the webhook on push to main. Two-phase approach:
#   Phase 1 (sync):  Pull latest code. All machines share the repo via NAS
#                    mounts, so one pull updates it for everyone.
#   Phase 2 (async): SSH to each deploy target and kick off setup.sh in the
#                    background (fire-and-forget). No git operations on remote
#                    machines, so concurrent execution is safe — each machine
#                    only reads the repo and writes to its own local state.
#
# The async phase avoids the self-termination problem: the deploy chain
# eventually restarts this webhook container, which would kill a synchronous
# dispatch mid-execution. With fire-and-forget, dispatch completes in seconds.
#
# Deploy results are logged on each target at /var/log/homelab-deploy.log.
# Check the monitoring stack (Uptime Kuma) or target logs if a deploy fails.
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

# --- Phase 1: Pull latest code (synchronous) ---
# All machines share the repo via NAS mounts (ZFS bind mounts, SMB, etc.),
# so pulling once here updates it everywhere. This runs inside the webhook
# container where the repo is bind-mounted at /repo.

if ! git config --global --get-all safe.directory 2>/dev/null | grep -qFx "$REPO_DIR"; then
    git config --global --add safe.directory "$REPO_DIR"
fi

log "Pulling latest changes..."
git fetch origin main
git reset --hard origin/main

# --- Source env files (after pull, so we use the latest versions) ---

source "$REPO_DIR/scripts/lib.sh"

# Save container environment vars before sourcing (env file values would override them)
SAVED_DEPLOY_KEY_PATH="${DEPLOY_KEY_PATH:-}"
source_env
[ -n "$SAVED_DEPLOY_KEY_PATH" ] && DEPLOY_KEY_PATH="$SAVED_DEPLOY_KEY_PATH"

# SSH requires strict permissions on the key file. The mounted key may have
# loose permissions from the host filesystem, so copy it to a temp file.
DEPLOY_KEY_TEMP=$(mktemp)
trap 'rm -f "$DEPLOY_KEY_TEMP"' EXIT
cp "$DEPLOY_KEY_PATH" "$DEPLOY_KEY_TEMP"
chmod 600 "$DEPLOY_KEY_TEMP"
DEPLOY_KEY_PATH="$DEPLOY_KEY_TEMP"

if [ -z "${DEPLOY_KEY_PATH:-}" ]; then
    log "ERROR: DEPLOY_KEY_PATH not set" >&2
    exit 1
fi

# --- Phase 2: Deploy to all targets (async, fire-and-forget) ---
# Each target runs setup.sh (not deploy.sh) — git operations already happened
# above. setup.sh is launched via nohup so it survives SSH disconnection, which
# is critical because the deploy chain may restart this webhook container.
# Concurrent execution is safe: each machine only reads the (now-updated) repo
# and writes to its own local state.

DISPATCH_FAILURES=()

for PREFIX in ${HOMELAB_DEPLOY_TARGETS:-}; do
    host_var="${PREFIX}_DEPLOY_HOST"
    TARGET_HOST="${!host_var:-}"

    if [ -z "$TARGET_HOST" ]; then
        log "WARNING: ${PREFIX}_DEPLOY_HOST not set, skipping"
        continue
    fi

    log "Dispatching to ${PREFIX} (${TARGET_HOST})..."
    # Derive repo path from /etc/homelab.env: symlink → <mount>/homelab/config/host.env
    # Two dirnames up gives <mount>/homelab, then append /repo
    # Setup is launched with nohup and backgrounded so it runs independently.
    # shellcheck disable=SC2029
    if ! ssh -i "$DEPLOY_KEY_PATH" \
        -o StrictHostKeyChecking=accept-new \
        -o BatchMode=yes \
        "root@${TARGET_HOST}" \
        'bash -c "REPO=\$(dirname \$(dirname \$(readlink -f /etc/homelab.env)))/repo && nohup bash \$REPO/scripts/setup/setup.sh > /var/log/homelab-deploy.log 2>&1 & disown"'; then
        log "ERROR: Failed to dispatch to ${PREFIX} (${TARGET_HOST})"
        DISPATCH_FAILURES+=("$PREFIX")
    fi
done

if [ ${#DISPATCH_FAILURES[@]} -gt 0 ]; then
    log "ERROR: Failed to dispatch to: ${DISPATCH_FAILURES[*]}"
    log "=== Dispatch complete (with errors) ==="
    exit 1
fi

log "=== Dispatch complete ==="