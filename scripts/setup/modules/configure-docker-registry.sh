#!/bin/bash
# Module: configure-docker-registry
#
# Logs the Docker host into a private container registry so it can pull the
# homelab's self-published images (e.g. the athena-mcp MCP server published by
# the athena-mcp CI to ${CONTAINER_REGISTRY}). Without this, `docker compose pull`
# for those images fails with an auth error and aborts the deploy.
#
# Declarative by design: the credentials live in the NAS env files, so a rebuilt
# (ephemeral) Docker LXC re-authenticates automatically on the next setup run —
# there is no manual `docker login` to remember. Each run reconciles the host
# login against the configured credentials (the env file is the source of truth).
#
# Docker-host only. Add to the Docker host's HOMELAB_SETUP_MODULES AFTER
# install-docker (it needs the docker CLI present).
#
# Required env vars:
#   CONTAINER_REGISTRY        Registry host to log into (no scheme, e.g. the Forgejo FQDN)
#   CONTAINER_REGISTRY_USER   Username for the registry
#   CONTAINER_REGISTRY_TOKEN  Access token / password (package:read scope is sufficient)
#   REPO_DIR                  Repo root (set by setup.sh; used to source lib.sh)

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

validate_env CONTAINER_REGISTRY CONTAINER_REGISTRY_USER CONTAINER_REGISTRY_TOKEN

if ! command -v docker &> /dev/null; then
    echo "ERROR: docker not found — list install-docker before configure-docker-registry" >&2
    exit 1
fi

# Reconcile the host login to the configured credentials. docker login is
# effectively idempotent (it just (re)writes the stored auth, no restart), and
# re-running it picks up a rotated token from the env file automatically.
printf '%s' "$CONTAINER_REGISTRY_TOKEN" \
    | docker login "$CONTAINER_REGISTRY" \
        --username "$CONTAINER_REGISTRY_USER" \
        --password-stdin

echo "Logged in to $CONTAINER_REGISTRY as $CONTAINER_REGISTRY_USER"
