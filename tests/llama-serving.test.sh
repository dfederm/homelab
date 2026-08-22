#!/bin/bash

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$REPO_DIR/services/ai/docker-compose.yml"
DOWNLOADER="$REPO_DIR/services/ai/download-models.sh"
MANIFEST="$REPO_DIR/services/ai/models.txt"
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

    if grep -Fq -- "$line" "$file"; then
        pass "$description"
    else
        fail "$description"
    fi
}

echo "=== llama-swap serving contract ==="

if grep -Eq \
    '^    image: ghcr\.io/mostlygeek/llama-swap:[^@]+@sha256:[0-9a-f]{64}' \
    "$COMPOSE"; then
    pass "llama-swap image is pinned by tag and digest"
else
    fail "llama-swap image is pinned by tag and digest"
fi

expect_line "$COMPOSE" "  llama-swap:" "llama-swap service is declared"
expect_line "$COMPOSE" "    runtime: nvidia" "llama-swap requires the NVIDIA runtime"
expect_line "$COMPOSE" \
    '      - ${LLAMA_MODELS_ROOT:?LLAMA_MODELS_ROOT not set}:/models:ro' \
    "missing model root fails Compose evaluation"
expect_line "$COMPOSE" \
    '      - NVIDIA_VISIBLE_DEVICES=${LLAMA_SWAP_NVIDIA_VISIBLE_DEVICES:?LLAMA_SWAP_NVIDIA_VISIBLE_DEVICES not set}' \
    "missing container GPU exposure fails Compose evaluation"
expect_line "$COMPOSE" \
    '      - ${CONFIG_DIR}/llama-swap/config.yml:/etc/llama-swap/config/config.yaml:ro' \
    "external llama-swap config is mounted read-only"
expect_line "$COMPOSE" \
    "      - ENABLE_OLLAMA_API=false" \
    "Open WebUI disables its native Ollama connection"
expect_line "$COMPOSE" \
    "      - RAG_EMBEDDING_ENGINE=openai" \
    "Open WebUI uses OpenAI-compatible embeddings"
expect_line "$COMPOSE" \
    '      - RAG_OPENAI_API_BASE_URL=http://litellm:4000/v1' \
    "RAG remains behind LiteLLM"

if grep -Eq '^[[:space:]]+ollama(-pull)?:' "$COMPOSE" \
    || grep -Fq 'http://ollama:' "$COMPOSE"; then
    fail "Compose has no Ollama service or route"
else
    pass "Compose has no Ollama service or route"
fi

expect_line "$REPO_DIR/services/ai/pre-up.sh" \
    'if [ ! -f "$CONFIG_DIR/llama-swap/config.yml" ]; then' \
    "deployment requires the external llama-swap config"

if grep -Fq ': "${LLAMA_MODELS_ROOT:?' "$REPO_DIR/services/ai/pre-up.sh" \
    || grep -Fq ': "${LLAMA_SWAP_NVIDIA_VISIBLE_DEVICES:?' "$REPO_DIR/services/ai/pre-up.sh"; then
    fail "pre-up does not validate Compose-owned settings"
else
    pass "Compose-owned settings are not redundantly validated in pre-up"
fi

for name in LLAMA_MODELS_ROOT LLAMA_SWAP_NVIDIA_VISIBLE_DEVICES; do
    expect_line "$ENV_TEMPLATE" "$name=" "$name is documented"
done

if grep -Fq 'LLAMA_ATHENA_GPU' "$COMPOSE" "$ENV_TEMPLATE" "$REPO_DIR/services/ai/pre-up.sh" \
    || grep -Fq 'LLAMA_UTILITY_GPU' "$COMPOSE" "$ENV_TEMPLATE" "$REPO_DIR/services/ai/pre-up.sh"; then
    fail "workload-specific GPU placement does not leak into Compose or env"
else
    pass "workload-specific GPU placement stays inside llama-swap config"
fi

if [ "$(grep -vc '^#' "$MANIFEST")" -eq 4 ] \
    && ! grep -Ev '^(#|[A-Za-z0-9._/-]+\|[0-9a-f]{64}\|[1-9][0-9]*\|https://)' "$MANIFEST" > /dev/null; then
    pass "model manifest pins four HTTPS artifacts by SHA-256 and size"
else
    fail "model manifest pins four HTTPS artifacts by SHA-256 and size"
fi

expect_line "$MANIFEST" \
    "qwen3.8-27b/Qwen3.8-27B-UD-IQ4_XS.gguf|40fac4050e940397dbf13087afd50f4734a11805bf9d65ef8ddd7483470e6199|14252845984|https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/4ca720788d1e01f1bff70c033e0d0028fd02e502/Qwen3.8-27B-UD-IQ4_XS.gguf" \
    "Qwen3.8 acquisition is pinned to the verified immutable artifact"

mkdir "$TMP_DIR/bin" "$TMP_DIR/models"
printf 'test model payload\n' > "$TMP_DIR/source.gguf"
expected_sha=$(sha256sum "$TMP_DIR/source.gguf" | cut -d' ' -f1)
expected_size=$(wc -c < "$TMP_DIR/source.gguf")
cat > "$TMP_DIR/manifest.txt" <<EOF
test/model.gguf|$expected_sha|$expected_size|https://example.invalid/model.gguf
EOF
cat > "$TMP_DIR/bin/curl" <<'EOF'
#!/bin/bash
set -eu

output=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            output="$2"
            shift 2
            ;;
        --retry|--retry-delay|--continue-at)
            shift 2
            ;;
        --fail|--location)
            shift
            ;;
        *)
            shift
            ;;
    esac
done

cp "$MOCK_MODEL_SOURCE" "$output"
printf 'download\n' >> "$MOCK_CURL_LOG"
EOF
chmod +x "$TMP_DIR/bin/curl"
: > "$TMP_DIR/curl.log"

run_downloader() {
    PATH="$TMP_DIR/bin:$PATH" \
    LLAMA_MODELS_ROOT="$TMP_DIR/models" \
    LLAMA_MODEL_MANIFEST="$TMP_DIR/manifest.txt" \
    MOCK_MODEL_SOURCE="$TMP_DIR/source.gguf" \
    MOCK_CURL_LOG="$TMP_DIR/curl.log" \
        bash "$DOWNLOADER" > "$TMP_DIR/download.out" 2>&1
}

if run_downloader \
    && cmp -s "$TMP_DIR/source.gguf" "$TMP_DIR/models/test/model.gguf" \
    && [ "$(wc -l < "$TMP_DIR/curl.log")" -eq 1 ]; then
    pass "model acquisition installs a verified artifact"
else
    fail "model acquisition installs a verified artifact"
fi

if run_downloader && [ "$(wc -l < "$TMP_DIR/curl.log")" -eq 1 ]; then
    pass "verified models are not downloaded again"
else
    fail "verified models are not downloaded again"
fi

mv "$TMP_DIR/models/test/model.gguf" "$TMP_DIR/models/test/model.gguf.partial"
if run_downloader \
    && cmp -s "$TMP_DIR/source.gguf" "$TMP_DIR/models/test/model.gguf" \
    && [ "$(wc -l < "$TMP_DIR/curl.log")" -eq 1 ]; then
    pass "a completed partial download is installed without another transfer"
else
    fail "a completed partial download is installed without another transfer"
fi

printf 'corrupt\n' > "$TMP_DIR/models/test/model.gguf"
if run_downloader \
    && cmp -s "$TMP_DIR/source.gguf" "$TMP_DIR/models/test/model.gguf" \
    && [ "$(wc -l < "$TMP_DIR/curl.log")" -eq 2 ]; then
    pass "a corrupt model is replaced atomically"
else
    fail "a corrupt model is replaced atomically"
fi

rm "$TMP_DIR/models/test/model.gguf"
tr '[:lower:]' '[:upper:]' < "$TMP_DIR/source.gguf" \
    > "$TMP_DIR/models/test/model.gguf.partial"
if run_downloader \
    && cmp -s "$TMP_DIR/source.gguf" "$TMP_DIR/models/test/model.gguf" \
    && [ "$(wc -l < "$TMP_DIR/curl.log")" -eq 3 ]; then
    pass "an invalid complete partial is discarded before retry"
else
    fail "an invalid complete partial is discarded before retry"
fi

cat > "$TMP_DIR/manifest.txt" <<EOF
bad/model.gguf|$(printf '0%.0s' {1..64})|$expected_size|https://example.invalid/model.gguf
EOF
if run_downloader; then
    fail "checksum mismatches fail deployment"
elif [ ! -e "$TMP_DIR/models/bad/model.gguf" ] \
    && [ ! -e "$TMP_DIR/models/bad/model.gguf.partial" ]; then
    pass "checksum mismatches fail without installing partial data"
else
    fail "checksum mismatches fail without installing partial data"
fi

cat > "$TMP_DIR/manifest.txt" <<EOF
../escape.gguf|$expected_sha|$expected_size|https://example.invalid/model.gguf
EOF
if run_downloader; then
    fail "model paths cannot escape the configured root"
else
    pass "model paths cannot escape the configured root"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "llama-swap serving tests passed"
else
    echo "$FAILURES test(s) failed"
fi

exit "$FAILURES"
