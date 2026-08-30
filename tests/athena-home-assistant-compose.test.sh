#!/bin/bash

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$REPO_DIR/services/ai/docker-compose.yml"
ENV_TEMPLATE="$REPO_DIR/.env.template"
FAILURES=0
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

pass() {
    echo "  PASS: $1"
}

fail() {
    echo "  FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

expect_line() {
    local file="$1"
    local line="$2"
    local description="$3"

    if [ "$(grep -Fc -- "$line" "$file")" -eq 1 ]; then
        pass "$description"
    else
        fail "$description"
    fi
}

expect_absent_literal() {
    local pattern="$1"
    local description="$2"

    if grep -Fq -- "$pattern" "$COMPOSE" "$ENV_TEMPLATE"; then
        fail "$description"
    else
        pass "$description"
    fi
}

expect_absent_regex() {
    local pattern="$1"
    local description="$2"

    if grep -Eq -- "$pattern" "$COMPOSE" "$ENV_TEMPLATE"; then
        fail "$description"
    else
        pass "$description"
    fi
}

echo "=== Athena MCP canonical user deployment contract ==="

expect_line "$COMPOSE" \
    '  athena-mcp:' \
    "Athena MCP service is declared"
# shellcheck disable=SC2016
expect_line "$COMPOSE" \
    '    image: ${CONTAINER_REGISTRY}/david/athena-mcp:0.1.41@sha256:b1c980d8173b87208558101e6469b998b9fa1ac7ff8118b36b21ae202665e62c' \
    "Athena MCP uses the published canonical-schema image"

for user_id in alice bob; do
    expect_line "$COMPOSE" \
        "      - Users__${user_id}__Email" \
        "$user_id roster email is passed through once"
    expect_line "$ENV_TEMPLATE" \
        "Users__${user_id}__Email=" \
        "$user_id roster email is documented once"
done

for credential in \
    "HomeAssistant:AccessToken" \
    "Vikunja:ApiToken" \
    "Radicale:Username" \
    "Radicale:Password" \
    "Jellyfin:AccessToken" \
    "Immich:ApiKey"
do
    provider=${credential%%:*}
    field=${credential#*:}
    for user_id in alice bob; do
        key="Apps__${provider}__Credentials__${user_id}__${field}"
        expect_line "$COMPOSE" \
            "      - $key" \
            "$provider $field is keyed by $user_id and omitted when undefined"
        expect_line "$ENV_TEMPLATE" \
            "# $key=" \
            "$provider $field for $user_id is documented as optional"
    done
done

if grep -Eq '^[[:space:]]*Apps__.*__Credentials__.*=' "$ENV_TEMPLATE"; then
    fail "optional credential examples remain undefined rather than blank"
else
    pass "optional credential examples remain undefined rather than blank"
fi

if grep -Eq '^[[:space:]]+- (Users__.*__Email|Apps__.*__Credentials__.*)=' "$COMPOSE"; then
    fail "roster and credential keys use omission-preserving bare pass-through entries"
else
    pass "roster and credential keys use omission-preserving bare pass-through entries"
fi

# shellcheck disable=SC2016
expect_line "$COMPOSE" \
    '      - Apps__HomeAssistant__BaseUrl=http://${HOMEASSISTANT_IP}:${HOMEASSISTANT_HTTP_PORT}' \
    "Home Assistant base URL reuses the declared host variables"
# shellcheck disable=SC2016
expect_line "$COMPOSE" \
    '      - Apps__HomeAssistant__TargetProofLifetimeSeconds=${ATHENA_MCP_HOMEASSISTANT_TARGET_PROOF_LIFETIME_SECONDS:-90}' \
    "target proof lifetime is configurable with the server default"
expect_line "$COMPOSE" \
    '      - Apps__HomeAssistant__DeniedEntityIds' \
    "Home Assistant denylist is passed as one scalar JSON array"
expect_line "$ENV_TEMPLATE" \
    "Apps__HomeAssistant__DeniedEntityIds='[]'" \
    "Home Assistant denylist defaults to a shell-safe empty JSON array"

cat > "$TMP_DIR/denylist.env" <<'EOF'
Apps__HomeAssistant__DeniedEntityIds='["light.example_hazard","switch.example_hazard"]'
EOF
denylist_value=$(bash -c \
    'set -a; source "$1"; printf "%s" "$Apps__HomeAssistant__DeniedEntityIds"' \
    _ "$TMP_DIR/denylist.env")
if [ "$denylist_value" = '["light.example_hazard","switch.example_hazard"]' ]; then
    pass "Bash env loading preserves a non-empty denylist as valid JSON"
else
    fail "Bash env loading preserves a non-empty denylist as valid JSON"
fi

expect_absent_literal "__Users__" "indexed provider user paths are rejected"
expect_absent_literal "DeniedEntityIds__" "indexed Home Assistant denylist paths are rejected"
expect_absent_regex \
    'ATHENA_MCP_(HOMEASSISTANT|VIKUNJA|RADICALE|JELLYFIN|IMMICH)_USER_[0-9]+' \
    "indexed external user variables are rejected"
expect_absent_literal \
    "ATHENA_MCP_HOMEASSISTANT_DENIED_ENTITY_ID_" \
    "indexed external denylist variables are rejected"
expect_absent_literal "ha-mcp-bridge" "the old bridge service is removed"
expect_absent_literal "HA_MCP_TOKEN" "the retired shared bridge credential is removed"
expect_absent_literal "ghcr.io/open-webui/mcpo" "the mcpo image is removed"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "Athena MCP canonical user compose tests passed"
else
    echo "$FAILURES test(s) failed"
fi

exit "$FAILURES"
