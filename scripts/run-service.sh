#!/bin/bash
# Deploy a single Docker Compose service.
#
# Usage: run-service.sh <service-name>

set -euo pipefail

SCRIPT=$(readlink -f "$0")
REPOPATH=$(dirname "$(dirname "$SCRIPT")")
ENV_FILE="/etc/homelab.env"

if [ -z "${1:-}" ]; then
    echo "Error: Provide a service name" >&2
    exit 1
fi

SERVICE="$1"
SERVICEPATH="$REPOPATH/services/$SERVICE"

if [ ! -f "$SERVICEPATH/docker-compose.yml" ]; then
    echo "Error: Service $SERVICE does not exist" >&2
    exit 1
fi

echo "Deploying: $SERVICE"

cd "$SERVICEPATH"

docker compose --env-file "$ENV_FILE" pull
docker compose --env-file "$ENV_FILE" up --force-recreate --remove-orphans --build -d
docker image prune -f
docker volume prune -f
