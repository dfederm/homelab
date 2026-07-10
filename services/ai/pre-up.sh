#!/bin/bash
# Pre-deploy hook for the ai stack: log the Docker host into the private Forgejo OCI
# registry before `docker compose pull` fetches our athena-mcp image.
#
# The login lives here rather than in a setup module because the registry is reached at
# the Forgejo FQDN through the reverse proxy (dns -> reverse-proxy -> forgejo, all
# services). A setup module runs before any service, so it would deadlock a cold re-pave.
# Running in this hook — with dns, reverse-proxy and forgejo listed before ai in
# HOMELAB_SERVICES — lets that path come up earlier in the same service phase, so a
# single setup.sh converges. Idempotent: docker login just rewrites the stored auth.

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:?CONFIG_DIR not set}"
ENV_FILE="${ENV_FILE:?ENV_FILE not set}"

# source_env only exports CONFIG_DIR/ENV_FILE, so re-source the env for the creds
# (same pattern as services/radicale/pre-up.sh).
set -a
# shellcheck disable=SC1090,SC1091
[ -f "$CONFIG_DIR/common.env" ] && . "$CONFIG_DIR/common.env"
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${CONTAINER_REGISTRY:?CONTAINER_REGISTRY not set}"
: "${CONTAINER_REGISTRY_USER:?CONTAINER_REGISTRY_USER not set}"
: "${CONTAINER_REGISTRY_TOKEN:?CONTAINER_REGISTRY_TOKEN not set}"

if ! command -v docker &> /dev/null; then
    echo "  ERROR: docker not found — ai pre-up needs the docker CLI" >&2
    exit 1
fi

# Retry docker login within a bounded window: on a cold re-pave the registry path (DNS,
# reverse proxy, Forgejo, and on a greenfield deploy the TLS cert) may still be warming
# up. Retrying login directly hits the same endpoint the pull uses; a bad token just
# exhausts the window and exits fatally.
echo "  pre-up: logging in to registry $CONTAINER_REGISTRY ..."
deadline=$(( $(date +%s) + 180 ))
until printf '%s' "$CONTAINER_REGISTRY_TOKEN" \
        | docker login "$CONTAINER_REGISTRY" \
            --username "$CONTAINER_REGISTRY_USER" \
            --password-stdin
do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "  ERROR: could not log in to $CONTAINER_REGISTRY within the wait window." >&2
        echo "         It is the Forgejo FQDN served via the reverse proxy, so list 'dns'," >&2
        echo "         'reverse-proxy', and 'forgejo' before 'ai' in HOMELAB_SERVICES, and" >&2
        echo "         verify CONTAINER_REGISTRY_USER / CONTAINER_REGISTRY_TOKEN." >&2
        exit 1
    fi
    echo "  pre-up: registry not ready yet, retrying login ..." >&2
    sleep 5
done

echo "  pre-up: logged in to $CONTAINER_REGISTRY as $CONTAINER_REGISTRY_USER"
