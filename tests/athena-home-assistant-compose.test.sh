#!/bin/bash

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$REPO_DIR/services/ai/docker-compose.yml"
ENV_TEMPLATE="$REPO_DIR/.env.template"
FAILURES=0

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

    if grep -Fq -- "$line" "$file"; then
        pass "$description"
    else
        fail "$description"
    fi
}

expect_absent() {
    local pattern="$1"
    local description="$2"

    if grep -Fq -- "$pattern" "$COMPOSE" "$ENV_TEMPLATE"; then
        fail "$description"
    else
        pass "$description"
    fi
}

echo "=== Athena MCP Home Assistant deployment contract ==="

service_count=$(grep -c '^  athena-mcp:' "$COMPOSE")
if [ "$service_count" -eq 1 ]; then
    pass "exactly one Athena MCP service is declared"
else
    fail "exactly one Athena MCP service is declared"
fi

if grep -Eq \
    '^    image: \$\{CONTAINER_REGISTRY\}/david/athena-mcp:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}' \
    "$COMPOSE"; then
    pass "Athena MCP image is pinned by version and digest"
else
    fail "Athena MCP image is pinned by version and digest"
fi

# shellcheck disable=SC2016
expect_line "$COMPOSE" \
    '      - Apps__HomeAssistant__BaseUrl=http://${HOMEASSISTANT_IP}:${HOMEASSISTANT_HTTP_PORT}' \
    "Home Assistant base URL reuses the declared host variables"
# shellcheck disable=SC2016
expect_line "$COMPOSE" \
    '      - Apps__HomeAssistant__TargetProofLifetimeSeconds=${ATHENA_MCP_HOMEASSISTANT_TARGET_PROOF_LIFETIME_SECONDS:-90}' \
    "target proof lifetime is configurable with the server default"

for index in $(seq 0 9); do
    expect_line "$COMPOSE" \
        "      - Apps__HomeAssistant__DeniedEntityIds__${index}=\${ATHENA_MCP_HOMEASSISTANT_DENIED_ENTITY_ID_${index}}" \
        "denylist slot $index is mapped"
    expect_line "$ENV_TEMPLATE" \
        "ATHENA_MCP_HOMEASSISTANT_DENIED_ENTITY_ID_${index}=" \
        "denylist slot $index is documented"
done

for index in $(seq 0 4); do
    expect_line "$COMPOSE" \
        "      - Apps__HomeAssistant__Users__${index}__Email=\${ATHENA_MCP_HOMEASSISTANT_USER_${index}_EMAIL}" \
        "Home Assistant user $index email is mapped"
    expect_line "$COMPOSE" \
        "      - Apps__HomeAssistant__Users__${index}__AccessToken=\${ATHENA_MCP_HOMEASSISTANT_USER_${index}_TOKEN}" \
        "Home Assistant user $index token is mapped"
    expect_line "$ENV_TEMPLATE" \
        "ATHENA_MCP_HOMEASSISTANT_USER_${index}_EMAIL=" \
        "Home Assistant user $index email is documented"
    expect_line "$ENV_TEMPLATE" \
        "ATHENA_MCP_HOMEASSISTANT_USER_${index}_TOKEN=" \
        "Home Assistant user $index token is documented"
done

expect_absent "ha-mcp-bridge" "the old bridge service is removed"
expect_absent "HA_MCP_TOKEN" "the retired shared bridge credential is removed"
expect_absent "ghcr.io/open-webui/mcpo" "the mcpo image is removed"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "Athena MCP Home Assistant compose tests passed"
else
    echo "$FAILURES test(s) failed"
fi

exit "$FAILURES"
