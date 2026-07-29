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

# Multi-instance services: when <SERVICE>_INSTANCES is set (space-separated), deploy the
# same compose once per instance as its own project (e.g. minecraft-creative), layering a
# per-instance env file (<config_dir>/<service>/<instance>.env) on top of common + machine
# env. Adding an instance then needs only that env file plus a name in the list. A key set
# in the instance file wins over the same key in common/machine env (see the unset below).
SERVICE_UPPER=$(echo "$SERVICE" | tr 'a-z-' 'A-Z_')
INSTANCES_VAR="${SERVICE_UPPER}_INSTANCES"
INSTANCES="${!INSTANCES_VAR:-}"
if [ -n "$INSTANCES" ]; then
    COMMON_ENV="$CONFIG_DIR/common.env"
    cd "$SERVICEPATH"
    export BUILDX_NO_DEFAULT_ATTESTATIONS=1
    # Optional pre-deploy hook (runs once before deploying), e.g. validate or fix file perms.
    # CONFIG_DIR is exported by source_env. A non-zero exit aborts the deploy (set -e).
    if [ -f "$SERVICEPATH/pre-up.sh" ]; then
        bash "$SERVICEPATH/pre-up.sh" "$INSTANCES"
    fi
    for INSTANCE in $INSTANCES; do
        echo ""
        echo "Deploying: $SERVICE ($INSTANCE)"
        INSTANCE_ENV="$CONFIG_DIR/$SERVICE/$INSTANCE.env"
        ENV_ARGS=()
        [ -f "$COMMON_ENV" ] && ENV_ARGS+=(--env-file "$COMMON_ENV")
        ENV_ARGS+=(--env-file "$ENV_FILE")
        [ -f "$INSTANCE_ENV" ] && ENV_ARGS+=(--env-file "$INSTANCE_ENV")
        # Exported outside the subshell so the post-up hook below still sees it, as
        # before; the subshell inherits it for compose.
        export "${SERVICE_UPPER}_INSTANCE=$INSTANCE"
        # Subshell so the unset below is scoped to this instance and the next one
        # still sees the machine-wide values.
        (
            # Compose resolves interpolation from the shell environment BEFORE any
            # --env-file, and setup.sh exports every machine-env var (`set -a`). So on
            # the push-to-deploy path a per-instance value would be silently ignored
            # for any name that also exists in the machine env — the opposite of what
            # layering the instance file last is supposed to mean, and it fails
            # quietly rather than erroring. Dropping exactly the names the instance
            # file defines lets --env-file resolution win, so a per-instance override
            # behaves the same whether setup.sh or a hand-run deployed it.
            if [ -f "$INSTANCE_ENV" ]; then
                while read -r key; do
                    [ -n "$key" ] && unset "$key" || true
                done < <(sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "$INSTANCE_ENV")
            fi
            docker compose -p "$SERVICE-$INSTANCE" "${ENV_ARGS[@]}" pull
            docker compose -p "$SERVICE-$INSTANCE" "${ENV_ARGS[@]}" up $FORCE --remove-orphans -d
        )
        # Optional per-instance post-deploy hook (e.g. apply gamerules via the console).
        # CONFIG_DIR is exported by source_env, so the hook can find per-instance files.
        if [ -f "$SERVICEPATH/post-up.sh" ]; then
            bash "$SERVICEPATH/post-up.sh" "$INSTANCE"
        fi
    done
    docker image prune -f
    exit 0
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

# Disable BuildKit provenance attestations. Without this, every build produces
# a new attestation manifest (with timestamps), creating a different manifest
# list digest even when layers are fully cached. Compose sees the new digest
# as a changed image and recreates the container unnecessarily.
export BUILDX_NO_DEFAULT_ATTESTATIONS=1

# Optional pre-deploy hook (runs before compose up), e.g. validate or fix file perms.
# CONFIG_DIR is exported by source_env. A non-zero exit aborts the deploy (set -e).
if [ -f "$SERVICEPATH/pre-up.sh" ]; then
    bash "$SERVICEPATH/pre-up.sh"
fi

docker compose "${ENV_ARGS[@]}" pull
docker compose "${ENV_ARGS[@]}" up $FORCE --remove-orphans --build -d

# Optional post-deploy hook (runs after compose up), e.g. a one-time registration that needs the
# container already running. CONFIG_DIR is exported by source_env. A non-zero exit aborts (set -e).
if [ -f "$SERVICEPATH/post-up.sh" ]; then
    bash "$SERVICEPATH/post-up.sh"
fi

docker image prune -f
