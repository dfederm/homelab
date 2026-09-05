#!/bin/bash
# shellcheck disable=SC2016

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$REPO_DIR/services/ai/docker-compose.yml"
ENV_TEMPLATE="$REPO_DIR/.env.template"
README="$REPO_DIR/README.md"
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

echo "=== Athena MCP deployment contract ==="

service_count=$(grep -c '^  athena-mcp:' "$COMPOSE")
if [ "$service_count" -eq 1 ]; then
    pass "exactly one Athena MCP service is declared"
else
    fail "exactly one Athena MCP service is declared"
fi

expect_line "$COMPOSE" \
    '    image: ${CONTAINER_REGISTRY}/david/athena-mcp:0.1.43@sha256:ba30a1aa8589686dbd1ccff0a2d7ba88b6560fdca983eacb96572b96b0860ea5' \
    "the PR 39 image is pinned by the published version and digest"
expect_line "$COMPOSE" \
    '      - ATHENA_MCP_USER_CONFIG_FILE=/run/secrets/athena-users.json' \
    "the application reads the fixed in-container user configuration path"
expect_line "$COMPOSE" \
    '      - Knowledge__CuratedRootPath=/knowledge' \
    "the application reads curated knowledge from the fixed in-container root"
expect_line "$COMPOSE" \
    '      - ${CONFIG_DIR}/athena/users.json:/run/secrets/athena-users.json:ro' \
    "the external user configuration is mounted read-only"
expect_line "$COMPOSE" \
    '      - ${CONFIG_DIR}/athena/knowledge:/knowledge:ro' \
    "the external curated knowledge root is mounted read-only"
expect_line "$COMPOSE" \
    "      - 'Apps__HomeAssistant__DeniedEntityIds=\${ATHENA_MCP_HOMEASSISTANT_DENIED_ENTITY_IDS}'" \
    "the Home Assistant denylist uses one JSON-array value"

expect_line "$COMPOSE" \
    '      - Identity__ForwardedUserJwtSecret=${OPEN_WEBUI_FORWARD_USER_JWT_SECRET}' \
    "the shared forwarded-identity secret remains ordinary configuration"
expect_line "$COMPOSE" \
    '      - Apps__HomeAssistant__BaseUrl=http://${HOMEASSISTANT_IP}:${HOMEASSISTANT_HTTP_PORT}' \
    "the Home Assistant endpoint remains ordinary configuration"
expect_line "$COMPOSE" \
    '      - Apps__Vikunja__BaseUrl=http://${DOCKER_HOST_IP}:${VIKUNJA_HTTP_PORT}' \
    "the Vikunja endpoint remains ordinary configuration"
expect_line "$COMPOSE" \
    '      - Apps__Radicale__FamilyCalendarUrl=http://${DOCKER_HOST_IP}:${RADICALE_HTTP_PORT}/${ATHENA_MCP_RADICALE_FAMILY_CALENDAR_URL}' \
    "the Radicale shared-list setting remains ordinary configuration"

for provider in HomeAssistant Vikunja Radicale Jellyfin Immich; do
    expect_absent "Apps__${provider}__Users__" \
        "$provider indexed roster and credential pass-through is removed"
done
expect_absent "ATHENA_MCP_HOMEASSISTANT_DENIED_ENTITY_ID_" \
    "the old indexed Home Assistant denylist is not passed through or templated"

expect_line "$ENV_TEMPLATE" \
    "ATHENA_MCP_HOMEASSISTANT_DENIED_ENTITY_IDS=[]" \
    "the scalar denylist is documented with an explicit empty default"
expect_line "$ENV_TEMPLATE" \
    '# Shared curated knowledge lives in ${CONFIG_DIR}/athena/knowledge and is mounted read-only at' \
    "the external curated knowledge location is documented"
expect_line "$README" \
    '   `${CONFIG_DIR}/athena/`, set it to mode `0644`, then rename it to `users.json` in the same' \
    "the atomic user snapshot procedure preserves container readability"

if grep -Fq -- '${CONFIG_DIR}/athena/knowledge:/knowledge:rw' "$COMPOSE"; then
    fail "the curated knowledge mount is never writable"
else
    pass "the curated knowledge mount is never writable"
fi

if command -v docker > /dev/null; then
    if docker compose --file "$COMPOSE" config --no-interpolate --quiet; then
        pass "AI Compose parses without interpolating secret values"
    else
        fail "AI Compose parses without interpolating secret values"
    fi
else
    echo "  SKIP: Docker CLI is unavailable; Compose parsing was not run"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "Athena MCP deployment tests passed"
else
    echo "$FAILURES test(s) failed"
fi

exit "$FAILURES"
