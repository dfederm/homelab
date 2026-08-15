#!/bin/bash
# Deploy all services configured for this machine.
# Services are defined by HOMELAB_SERVICES in .env (comma-separated).
#
# Usage: ./scripts/run-all-services.sh

set -euo pipefail

SCRIPT=$(readlink -f "$0")

if [ "${HOMELAB_SETUP_LOCK_HELD:-0}" != "1" ]; then
    SETUP_LOCK_FILE="${HOMELAB_SETUP_LOCK_FILE:-/run/lock/homelab-setup.lock}"
    mkdir -p "$(dirname "$SETUP_LOCK_FILE")"
    echo "Waiting for setup lock: $SETUP_LOCK_FILE"
    exec flock "$SETUP_LOCK_FILE" env HOMELAB_SETUP_LOCK_HELD=1 \
        /bin/bash "$SCRIPT" "$@"
fi

REPOPATH=$(dirname "$(dirname "$SCRIPT")")
ENV_FILE="/etc/homelab.env"

if [ -f "$ENV_FILE" ]; then
    HOMELAB_SERVICES=$(grep '^HOMELAB_SERVICES=' "$ENV_FILE" | cut -d= -f2-)
fi

if [ -z "${HOMELAB_SERVICES:-}" ]; then
    echo "Error: HOMELAB_SERVICES not set in $ENV_FILE" >&2
    exit 1
fi

# Convert comma-separated list to array
IFS=',' read -ra SERVICES <<< "$HOMELAB_SERVICES"

FAILED=()

for SERVICE in "${SERVICES[@]}"; do
    # Trim whitespace
    SERVICE=$(echo "$SERVICE" | xargs)
    echo ""
    echo "========================================"
    echo "Deploying: $SERVICE"
    echo "========================================"
    if ! bash "$REPOPATH/scripts/run-service.sh" "$SERVICE"; then
        echo "ERROR: Failed to deploy $SERVICE"
        FAILED+=("$SERVICE")
    fi
done

echo ""
echo "========================================"
echo "Deployment Summary"
echo "========================================"

if [ ${#FAILED[@]} -eq 0 ]; then
    echo "All services deployed successfully."
else
    echo "FAILED services: ${FAILED[*]}"
    exit 1
fi
