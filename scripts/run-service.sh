#!/bin/bash
# Deploy a single Docker Compose service.
# Idempotent — only recreates containers whose config or image changed.
#
# Usage: run-service.sh [--force-recreate] <service-name>
#   --force-recreate: Force container recreation even if nothing changed.

set -euo pipefail

SCRIPT=$(readlink -f "$0")
REPOPATH=$(dirname "$(dirname "$SCRIPT")")

source "$REPOPATH/scripts/lib.sh"
source_env

FORCE=""
if [ "${1:-}" = "--force-recreate" ]; then
    FORCE="--force-recreate"
    shift
fi

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

# Create local .env pointing to the resolved real path.
# Resolving the symlink avoids snap Docker filesystem restrictions.
ln -sf "$ENV_FILE" "$SERVICEPATH/.env"

# Build env-file args (common first, machine-specific overrides)
COMMON_ENV="$CONFIG_DIR/common.env"
ENV_ARGS=()
if [ -f "$COMMON_ENV" ]; then
    ENV_ARGS+=(--env-file "$COMMON_ENV")
fi
ENV_ARGS+=(--env-file "$ENV_FILE")

docker compose "${ENV_ARGS[@]}" pull
docker compose "${ENV_ARGS[@]}" up $FORCE --remove-orphans --build -d
docker image prune -f
