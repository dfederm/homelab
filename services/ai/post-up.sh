#!/bin/bash
# Reconcile the fixed LiteLLM client keys after the gateway is healthy.

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:?CONFIG_DIR not set}"
ENV_FILE="${ENV_FILE:?ENV_FILE not set}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

source "$REPO_ROOT/scripts/lib.sh"
source "$REPO_ROOT/services/ai/lib.sh"

set -a
# shellcheck disable=SC1090,SC1091
[ -f "$CONFIG_DIR/common.env" ] && . "$CONFIG_DIR/common.env"
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

validate_env LITELLM_HTTP_PORT
load_litellm_client_config

for command in curl jq; do
    if ! command -v "$command" &> /dev/null; then
        echo "  ERROR: $command not found — ai post-up needs it to reconcile LiteLLM keys." >&2
        exit 1
    fi
done

LITELLM_URL="http://127.0.0.1:${LITELLM_HTTP_PORT}"
RESPONSE_FILE=$(mktemp)
trap 'rm -f "$RESPONSE_FILE"' EXIT

echo "  post-up: waiting for LiteLLM ..."
deadline=$(( $(date +%s) + 180 ))
until curl --fail --silent --show-error \
        "$LITELLM_URL/health/readiness" \
        > /dev/null
do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "  ERROR: LiteLLM did not become ready within the wait window." >&2
        exit 1
    fi
    sleep 5
done

reconcile_key() {
    local alias="$1"
    local key="$2"
    shift 2

    local models_json
    models_json=$(printf '%s\n' "$@" | jq --raw-input . | jq --slurp .)

    local payload
    payload=$(jq --compact-output --null-input \
        --arg key "$key" \
        --arg alias "$alias" \
        --argjson models "$models_json" \
        '{
            key: $key,
            key_alias: $alias,
            models: $models
        }')

    local status
    status=$(curl --silent --show-error \
        --output "$RESPONSE_FILE" \
        --write-out '%{http_code}' \
        --request POST \
        --header "Authorization: Bearer $LITELLM_MASTER_KEY" \
        --header "Content-Type: application/json" \
        --data "$payload" \
        "$LITELLM_URL/key/update")

    if [ "$status" = "200" ]; then
        echo "  post-up: reconciled LiteLLM client '$alias'"
        return
    fi

    if [ "$status" != "404" ]; then
        echo "  ERROR: LiteLLM key update for '$alias' failed with HTTP $status." >&2
        exit 1
    fi

    local delete_payload
    delete_payload=$(jq --compact-output --null-input \
        --arg alias "$alias" \
        '{key_aliases: [$alias]}')

    # The OSS API cannot regenerate virtual keys. Deleting by stable alias first makes an
    # externally supplied replacement key converge without leaving the old credential valid.
    status=$(curl --silent --show-error \
        --output "$RESPONSE_FILE" \
        --write-out '%{http_code}' \
        --request POST \
        --header "Authorization: Bearer $LITELLM_MASTER_KEY" \
        --header "Content-Type: application/json" \
        --data "$delete_payload" \
        "$LITELLM_URL/key/delete")

    if [ "$status" != "200" ] && [ "$status" != "404" ]; then
        echo "  ERROR: LiteLLM old-key removal for '$alias' failed with HTTP $status." >&2
        exit 1
    fi

    status=$(curl --silent --show-error \
        --output "$RESPONSE_FILE" \
        --write-out '%{http_code}' \
        --request POST \
        --header "Authorization: Bearer $LITELLM_MASTER_KEY" \
        --header "Content-Type: application/json" \
        --data "$payload" \
        "$LITELLM_URL/key/generate")

    if [ "$status" != "200" ]; then
        echo "  ERROR: LiteLLM key creation for '$alias' failed with HTTP $status." >&2
        exit 1
    fi

    echo "  post-up: created or rotated LiteLLM client '$alias'"
}

for client_prefix in "${LITELLM_CLIENT_PREFIXES[@]}"; do
    alias_name="LITELLM_${client_prefix}_KEY_ALIAS"
    key_name="LITELLM_${client_prefix}_API_KEY"
    models_name="LITELLM_${client_prefix}_MODELS"
    read -r -a client_models <<< "${!models_name}"
    reconcile_key "${!alias_name}" "${!key_name}" "${client_models[@]}"
done
