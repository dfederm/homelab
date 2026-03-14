#!/bin/bash
# Deploy all services configured for this machine.
# Services are defined by HOMELAB_SERVICES in .env (comma-separated).
#
# Usage: ./scripts/run-all-services.sh

SCRIPT=$(readlink -f "$0")
REPOPATH=$(dirname $(dirname "$SCRIPT"))

# Source .env for the service list
if [ -f "$REPOPATH/.env" ]; then
    HOMELAB_SERVICES=$(grep '^HOMELAB_SERVICES=' "$REPOPATH/.env" | cut -d= -f2-)
fi

if [ -z "${HOMELAB_SERVICES:-}" ]; then
    echo "Error: HOMELAB_SERVICES not set in .env" 1>&2
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
