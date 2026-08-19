#!/bin/bash

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$REPO_DIR/services/ai/docker-compose.yml"
POST_UP="$REPO_DIR/services/ai/post-up.sh"
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

echo "=== LiteLLM routing contract ==="

if command -v docker > /dev/null; then
    if docker compose --file "$COMPOSE" config --no-interpolate --quiet; then
        pass "AI Compose file parses without interpolation"
    else
        fail "AI Compose file parses without interpolation"
    fi
else
    echo "  SKIP: Docker CLI is unavailable; Compose parsing was not run"
fi

cat > "$TMP_DIR/curl" <<'EOF'
#!/bin/bash
set -eu

payload=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --data)
            payload="$2"
            shift 2
            ;;
        --header)
            printf '%s\n' "$2" >> "$MOCK_HEADER_LOG"
            shift 2
            ;;
        --output|--write-out|--request)
            shift 2
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done

case "$url" in
    */health/readiness)
        exit 0
        ;;
    */key/update)
        printf '%s\n' "$payload" >> "$MOCK_PAYLOAD_LOG"
        case "$MOCK_MODE" in
            create) printf '404' ;;
            rotate) printf '404' ;;
            update) printf '200' ;;
            auth) printf '401' ;;
            bad-request) printf '400' ;;
        esac
        ;;
    */key/delete)
        printf '%s\n' "$payload" >> "$MOCK_PAYLOAD_LOG"
        if [ "$MOCK_MODE" = "create" ]; then
            printf '404'
        else
            printf '200'
        fi
        ;;
    */key/generate)
        printf '%s\n' "$payload" >> "$MOCK_PAYLOAD_LOG"
        printf '200'
        ;;
    *)
        exit 2
        ;;
esac
EOF
chmod +x "$TMP_DIR/curl"

mkdir "$TMP_DIR/config"
: > "$TMP_DIR/config/common.env"
cat > "$TMP_DIR/config/test.env" <<'EOF'
LITELLM_HTTP_PORT=4000
LITELLM_MASTER_KEY=sk-master-test-value
LITELLM_SALT_KEY=sk-salt-test-value
LITELLM_CLIENTS="OPEN_WEBUI TERMINAL"
LITELLM_OPEN_WEBUI_KEY_ALIAS=ui-test
LITELLM_OPEN_WEBUI_API_KEY=sk-open-webui-test-value
LITELLM_OPEN_WEBUI_MODELS="chat-primary chat-tasks"
LITELLM_TERMINAL_KEY_ALIAS=terminal-test
LITELLM_TERMINAL_API_KEY=sk-terminal-test-value
LITELLM_TERMINAL_MODELS=developer-primary
EOF

cat > "$TMP_DIR/config/empty-allowlist.env" <<'EOF'
LITELLM_HTTP_PORT=4000
LITELLM_MASTER_KEY=sk-master-test-value
LITELLM_SALT_KEY=sk-salt-test-value
LITELLM_CLIENTS=OPEN_WEBUI
LITELLM_OPEN_WEBUI_KEY_ALIAS=ui-test
LITELLM_OPEN_WEBUI_API_KEY=sk-open-webui-test-value
LITELLM_OPEN_WEBUI_MODELS=" "
EOF
if CONFIG_DIR="$TMP_DIR/config" \
    ENV_FILE="$TMP_DIR/config/empty-allowlist.env" \
    bash "$POST_UP" > "$TMP_DIR/empty-allowlist.out" 2>&1
then
    fail "empty client model allowlists are rejected"
elif grep -Fq "must allow at least one model alias" "$TMP_DIR/empty-allowlist.out"; then
    pass "empty client model allowlists are rejected"
else
    fail "empty client model allowlists are rejected"
fi

run_reconcile() {
    local mode="$1"
    local output="$2"
    local payload_log="$3"
    local header_log="$4"

    PATH="$TMP_DIR:$PATH" \
    CONFIG_DIR="$TMP_DIR/config" \
    ENV_FILE="$TMP_DIR/config/test.env" \
    MOCK_MODE="$mode" \
    MOCK_PAYLOAD_LOG="$payload_log" \
    MOCK_HEADER_LOG="$header_log" \
        bash "$POST_UP" > "$output" 2>&1
}

for mode in create rotate update; do
    output="$TMP_DIR/${mode}.out"
    payload_log="$TMP_DIR/${mode}.payloads"
    header_log="$TMP_DIR/${mode}.headers"
    : > "$payload_log"
    : > "$header_log"

    if run_reconcile "$mode" "$output" "$payload_log" "$header_log"; then
        pass "key reconciliation $mode path succeeds"
    else
        fail "key reconciliation $mode path succeeds"
        continue
    fi

    if jq --exit-status --slurp \
        'any(.[]; .key_alias == "ui-test"
            and .models == ["chat-primary", "chat-tasks"])
         and any(.[]; .key_alias == "terminal-test"
            and .models == ["developer-primary"])' \
        "$payload_log" > /dev/null; then
        pass "key reconciliation $mode path enforces client model allowlists"
    else
        fail "key reconciliation $mode path enforces client model allowlists"
    fi

    if [ "$mode" != "update" ]; then
        if jq --exit-status --slurp \
            'any(.[]; .key_aliases == ["ui-test"])
             and any(.[]; .key_aliases == ["terminal-test"])' \
            "$payload_log" > /dev/null; then
            pass "key reconciliation replaces any old aliased credentials"
        else
            fail "key reconciliation replaces any old aliased credentials"
        fi
    fi

    expected_auth_headers=6
    if [ "$mode" = "update" ]; then
        expected_auth_headers=2
    fi
    actual_auth_headers=$(grep -Fc 'Authorization: Bearer sk-master-test-value' "$header_log")
    if [ "$actual_auth_headers" -eq "$expected_auth_headers" ]; then
        pass "key reconciliation $mode path authenticates every management request"
    else
        fail "key reconciliation $mode path authenticates every management request"
    fi

    if grep -Fq 'sk-' "$output"; then
        fail "key reconciliation $mode path keeps secrets out of output"
    else
        pass "key reconciliation $mode path keeps secrets out of output"
    fi
done

auth_output="$TMP_DIR/auth.out"
auth_payloads="$TMP_DIR/auth.payloads"
auth_headers="$TMP_DIR/auth.headers"
: > "$auth_payloads"
: > "$auth_headers"
if run_reconcile auth "$auth_output" "$auth_payloads" "$auth_headers"; then
    fail "key reconciliation rejects an authentication failure"
elif grep -Fq "failed with HTTP 401" "$auth_output" \
    && [ "$(grep -Fc 'Authorization: Bearer sk-master-test-value' "$auth_headers")" -eq 1 ]
then
    pass "key reconciliation rejects an authentication failure"
else
    fail "key reconciliation rejects an authentication failure"
fi

if grep -Fq 'sk-' "$auth_output"; then
    fail "authentication failure keeps secrets out of output"
else
    pass "authentication failure keeps secrets out of output"
fi

bad_request_output="$TMP_DIR/bad-request.out"
bad_request_payloads="$TMP_DIR/bad-request.payloads"
bad_request_headers="$TMP_DIR/bad-request.headers"
: > "$bad_request_payloads"
: > "$bad_request_headers"
if run_reconcile bad-request "$bad_request_output" "$bad_request_payloads" "$bad_request_headers"; then
    fail "key reconciliation does not create after a malformed update"
elif grep -Fq "failed with HTTP 400" "$bad_request_output" \
    && [ "$(wc -l < "$bad_request_payloads")" -eq 1 ] \
    && [ "$(grep -Fc 'Authorization: Bearer sk-master-test-value' "$bad_request_headers")" -eq 1 ]
then
    pass "key reconciliation does not create after a malformed update"
else
    fail "key reconciliation does not create after a malformed update"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "LiteLLM routing tests passed"
else
    echo "$FAILURES test(s) failed"
fi

exit "$FAILURES"
