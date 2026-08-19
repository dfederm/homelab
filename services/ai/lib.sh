#!/bin/bash

load_litellm_client_config() {
    validate_env LITELLM_CLIENTS LITELLM_MASTER_KEY LITELLM_SALT_KEY

    LITELLM_CLIENT_PREFIXES=()
    LITELLM_CLIENT_SECRET_NAMES=(
        LITELLM_MASTER_KEY
        LITELLM_SALT_KEY
    )

    local -A seen_prefixes=()
    local -A seen_aliases=()
    local client_prefix

    for client_prefix in $LITELLM_CLIENTS; do
        if [[ ! "$client_prefix" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            echo "  ERROR: invalid LiteLLM client prefix '$client_prefix'." >&2
            exit 1
        fi
        if [[ -v "seen_prefixes[$client_prefix]" ]]; then
            echo "  ERROR: duplicate LiteLLM client prefix '$client_prefix'." >&2
            exit 1
        fi
        seen_prefixes["$client_prefix"]=1

        local alias_name="LITELLM_${client_prefix}_KEY_ALIAS"
        local key_name="LITELLM_${client_prefix}_API_KEY"
        local models_name="LITELLM_${client_prefix}_MODELS"
        validate_env "$alias_name" "$key_name" "$models_name"

        local alias_value="${!alias_name}"
        if [[ ! "$alias_value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            echo "  ERROR: $alias_name contains an invalid key alias." >&2
            exit 1
        fi
        if [[ -v "seen_aliases[$alias_value]" ]]; then
            echo "  ERROR: duplicate LiteLLM key alias '$alias_value'." >&2
            exit 1
        fi
        seen_aliases["$alias_value"]=1

        local -a allowed_models=()
        read -r -a allowed_models <<< "${!models_name}"
        if [ "${#allowed_models[@]}" -eq 0 ]; then
            echo "  ERROR: $models_name must allow at least one model alias." >&2
            exit 1
        fi

        LITELLM_CLIENT_PREFIXES+=("$client_prefix")
        LITELLM_CLIENT_SECRET_NAMES+=("$key_name")
    done

    if [[ " ${LITELLM_CLIENT_PREFIXES[*]} " != *" OPEN_WEBUI "* ]]; then
        echo "  ERROR: LITELLM_CLIENTS must include OPEN_WEBUI for the bundled frontend." >&2
        exit 1
    fi

    local secret_name
    for secret_name in "${LITELLM_CLIENT_SECRET_NAMES[@]}"; do
        local secret_value="${!secret_name}"
        if [[ "$secret_value" != sk-* ]] || [ "${#secret_value}" -lt 16 ]; then
            echo "  ERROR: $secret_name must start with sk- and contain at least 16 characters." >&2
            exit 1
        fi
    done

    local left
    local right
    for ((left = 0; left < ${#LITELLM_CLIENT_SECRET_NAMES[@]}; left++)); do
        for ((right = left + 1; right < ${#LITELLM_CLIENT_SECRET_NAMES[@]}; right++)); do
            local left_name="${LITELLM_CLIENT_SECRET_NAMES[$left]}"
            local right_name="${LITELLM_CLIENT_SECRET_NAMES[$right]}"
            if [ "${!left_name}" = "${!right_name}" ]; then
                echo "  ERROR: LiteLLM master, salt, and client secrets must all be distinct." >&2
                exit 1
            fi
        done
    done
}
