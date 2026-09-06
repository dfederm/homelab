#!/bin/bash

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOWNLOADER="$REPO_DIR/services/ai/download-models.sh"
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

echo "=== llama-swap deployment behavior ==="

mkdir -p "$TMP_DIR/pre-up/config/ai" "$TMP_DIR/pre-up/config/llama-swap"
cat > "$TMP_DIR/pre-up/config/test.env" <<'EOF'
CONTAINER_REGISTRY=registry.example.invalid
CONTAINER_REGISTRY_USER=test-user
CONTAINER_REGISTRY_TOKEN=test-token
EOF
printf 'model manifest\n' > "$TMP_DIR/pre-up/config/ai/models.txt"

run_pre_up() {
    CONFIG_DIR="$TMP_DIR/pre-up/config" \
    ENV_FILE="$TMP_DIR/pre-up/config/test.env" \
        bash "$REPO_DIR/services/ai/pre-up.sh"
}

if run_pre_up > "$TMP_DIR/missing-config.out" 2>&1; then
    fail "pre-up rejects a missing llama-swap configuration"
elif grep -Fq "llama-swap config not found" "$TMP_DIR/missing-config.out"; then
    pass "pre-up rejects a missing llama-swap configuration"
else
    fail "pre-up rejects a missing llama-swap configuration"
fi

touch "$TMP_DIR/pre-up/config/llama-swap/config.yml"
rm "$TMP_DIR/pre-up/config/ai/models.txt"
if run_pre_up > "$TMP_DIR/missing-manifest.out" 2>&1; then
    fail "pre-up rejects a missing model manifest"
elif grep -Fq "model manifest not found" "$TMP_DIR/missing-manifest.out"; then
    pass "pre-up rejects a missing model manifest"
else
    fail "pre-up rejects a missing model manifest"
fi

mkdir "$TMP_DIR/bin" "$TMP_DIR/models"
printf 'test model payload\n' > "$TMP_DIR/source.gguf"
expected_sha=$(sha256sum "$TMP_DIR/source.gguf" | cut -d' ' -f1)
expected_size=$(wc -c < "$TMP_DIR/source.gguf")
printf '%s|%s|%s|%s\r\n' \
    "test/model.gguf" \
    "$expected_sha" \
    "$expected_size" \
    "https://example.invalid/model.gguf" \
    > "$TMP_DIR/manifest.txt"
cat > "$TMP_DIR/bin/curl" <<'EOF'
#!/bin/bash
set -eu

output=
url=
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
            url="$1"
            shift
            ;;
    esac
done

[ "$url" = "https://example.invalid/model.gguf" ]
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
    pass "model acquisition installs a verified artifact from a CRLF manifest"
else
    fail "model acquisition installs a verified artifact from a CRLF manifest"
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
