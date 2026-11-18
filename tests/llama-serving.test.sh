#!/bin/bash

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOWNLOADER="$REPO_DIR/services/ai/download-models.sh"
FAILURES=0
TMP_DIR=$(mktemp -d)
REAL_SHA256SUM="$(command -v sha256sum)"
REAL_MV="$(command -v mv)"
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
printf 'test/model.gguf|https://huggingface.co/example/model/resolve/main/model.gguf\r\n' \
    > "$TMP_DIR/manifest.txt"
cat > "$TMP_DIR/bin/curl" <<'EOF'
#!/bin/bash
set -eu

head=false
output=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --head)
            head=true
            shift
            ;;
        --output)
            output="$2"
            shift 2
            ;;
        --retry|--retry-delay|--continue-at|--connect-timeout|--max-time)
            shift 2
            ;;
        --fail|--location|--silent|--show-error)
            shift
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done

if [ "$head" = true ]; then
    [ "$url" = "https://huggingface.co/example/model/resolve/main/model.gguf" ]
    printf 'X-Repo-Commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\nX-Linked-ETag: "%s"\r\nX-Linked-Size: %s\r\n' \
        "$MOCK_METADATA_SHA" "$MOCK_METADATA_SIZE"
    exit 0
fi

[ "$url" = "https://huggingface.co/example/model/resolve/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/model.gguf" ]
printf 'download\n' >> "$MOCK_CURL_LOG"
if [ "${MOCK_CURL_FAIL:-0}" -eq 1 ]; then
    exit 22
fi
cp "$MOCK_MODEL_SOURCE" "$output"
EOF
cat > "$TMP_DIR/bin/sha256sum" <<'EOF'
#!/bin/bash
set -eu
printf '%s\n' "$*" >> "$MOCK_SHA256_LOG"
exec "$REAL_SHA256SUM" "$@"
EOF
cat > "$TMP_DIR/bin/mv" <<'EOF'
#!/bin/bash
set -eu
source_path="${@: -2:1}"
target_path="${@: -1}"
if [ "${MOCK_MV_FAIL_PARTIAL:-0}" -eq 1 ] && [[ "$source_path" == *.partial ]]; then
    exit 1
fi
if [ "${MOCK_MV_FAIL_RECEIPT:-0}" -eq 1 ] \
    && [[ "$source_path" == *.tmp.* ]] \
    && [[ "$target_path" != *.partial.sha256 ]] \
    && [[ "$target_path" == *.sha256 ]]; then
    exit 1
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$TMP_DIR/bin/curl" "$TMP_DIR/bin/sha256sum" "$TMP_DIR/bin/mv"
: > "$TMP_DIR/curl.log"
: > "$TMP_DIR/sha256.log"

run_downloader() {
    PATH="$TMP_DIR/bin:$PATH" \
    LLAMA_MODELS_ROOT="$TMP_DIR/models" \
    LLAMA_MODEL_MANIFEST="$TMP_DIR/manifest.txt" \
    MOCK_MODEL_SOURCE="$TMP_DIR/source.gguf" \
    MOCK_CURL_LOG="$TMP_DIR/curl.log" \
    MOCK_SHA256_LOG="$TMP_DIR/sha256.log" \
    MOCK_METADATA_SHA="${MOCK_METADATA_SHA:-$expected_sha}" \
    MOCK_METADATA_SIZE="${MOCK_METADATA_SIZE:-$expected_size}" \
    REAL_SHA256SUM="$REAL_SHA256SUM" \
    REAL_MV="$REAL_MV" \
        bash "$DOWNLOADER" > "$TMP_DIR/download.out" 2>&1
}

model="$TMP_DIR/models/test/model.gguf"
receipt="$model.sha256"
partial="$model.partial"

if run_downloader \
    && cmp -s "$TMP_DIR/source.gguf" "$model" \
    && [ "$(cat "$receipt")" = "$expected_sha" ] \
    && [ "$(wc -l < "$TMP_DIR/curl.log")" -eq 1 ] \
    && [ "$(wc -l < "$TMP_DIR/sha256.log")" -eq 1 ]; then
    pass "model acquisition installs a verified artifact from a CRLF manifest"
else
    fail "model acquisition installs a verified artifact from a CRLF manifest"
fi

: > "$TMP_DIR/sha256.log"
if run_downloader \
    && [ "$(wc -l < "$TMP_DIR/curl.log")" -eq 1 ] \
    && [ ! -s "$TMP_DIR/sha256.log" ] \
    && grep -Fq "Model accepted from checksum receipt" "$TMP_DIR/download.out"; then
    pass "a matching receipt skips hashing and downloading"
else
    fail "a matching receipt skips hashing and downloading"
fi

printf 'interrupted transfer\n' > "$partial"
: > "$TMP_DIR/sha256.log"
if run_downloader \
    && [ -f "$partial" ] \
    && [ ! -s "$TMP_DIR/sha256.log" ] \
    && [ "$(wc -l < "$TMP_DIR/curl.log")" -eq 1 ]; then
    pass "a cached model takes precedence over and preserves a leftover partial"
else
    fail "a cached model takes precedence over and preserves a leftover partial"
fi
rm "$partial"

before_downloads=$(wc -l < "$TMP_DIR/curl.log")
: > "$TMP_DIR/sha256.log"
if MOCK_METADATA_SIZE="$((expected_size + 1))" run_downloader \
    && cmp -s "$TMP_DIR/source.gguf" "$model" \
    && [ "$(cat "$receipt")" = "$expected_sha" ] \
    && [ "$(wc -l < "$TMP_DIR/curl.log")" -eq "$before_downloads" ] \
    && [ ! -s "$TMP_DIR/sha256.log" ]; then
    pass "a matching receipt is trusted even if the upstream size changes"
else
    fail "a matching receipt is trusted even if the upstream size changes"
fi

rm "$receipt"
: > "$TMP_DIR/sha256.log"
if run_downloader \
    && [ "$(wc -l < "$TMP_DIR/sha256.log")" -eq 1 ] \
    && [ "$(wc -l < "$TMP_DIR/curl.log")" -eq "$before_downloads" ] \
    && [ "$(cat "$receipt")" = "$expected_sha" ]; then
    pass "a model without a receipt is hashed once and cached"
else
    fail "a model without a receipt is hashed once and cached"
fi

printf 'invalid receipt\n' > "$receipt"
: > "$TMP_DIR/sha256.log"
if run_downloader \
    && [ "$(wc -l < "$TMP_DIR/sha256.log")" -eq 1 ] \
    && [ "$(wc -l < "$TMP_DIR/curl.log")" -eq "$before_downloads" ] \
    && [ "$(cat "$receipt")" = "$expected_sha" ]; then
    pass "an invalid receipt falls back to hashing the existing model"
else
    fail "an invalid receipt falls back to hashing the existing model"
fi

old_content="$TMP_DIR/old-model.gguf"
cp "$model" "$old_content"
old_sha="$(cat "$receipt")"
printf 'updated model payload with a new revision\n' > "$TMP_DIR/source.gguf"
expected_sha=$(sha256sum "$TMP_DIR/source.gguf" | cut -d' ' -f1)
expected_size=$(wc -c < "$TMP_DIR/source.gguf")
if MOCK_METADATA_SIZE="$((expected_size + 1))" run_downloader; then
    fail "a downloaded model with the wrong size is rejected"
elif cmp -s "$old_content" "$model" \
    && [ "$(cat "$receipt")" = "$old_sha" ] \
    && [ ! -e "$partial" ]; then
    pass "a downloaded model with the wrong size preserves the old model"
else
    fail "a downloaded model with the wrong size preserves the old model"
fi

: > "$TMP_DIR/sha256.log"
before_downloads=$(wc -l < "$TMP_DIR/curl.log")
if run_downloader \
    && cmp -s "$TMP_DIR/source.gguf" "$model" \
    && [ "$(cat "$receipt")" = "$expected_sha" ] \
    && [ "$(wc -l < "$TMP_DIR/curl.log")" -eq "$((before_downloads + 1))" ] \
    && [ "$(wc -l < "$TMP_DIR/sha256.log")" -eq 1 ]; then
    pass "a changed upstream model is downloaded and replaces the old model"
else
    fail "a changed upstream model is downloaded and replaces the old model"
fi

new_sha="$expected_sha"
cp "$model" "$old_content"
if MOCK_METADATA_SHA="$(printf '0%.0s' {1..64})" run_downloader; then
    fail "checksum mismatches fail deployment"
elif cmp -s "$old_content" "$model" \
    && [ "$(cat "$receipt")" = "$new_sha" ] \
    && [ ! -e "$partial" ]; then
    pass "checksum mismatches fail without replacing the old model"
else
    fail "checksum mismatches fail without replacing the old model"
fi

cp "$model" "$old_content"
printf 'next model revision\n' > "$TMP_DIR/source.gguf"
expected_sha=$(sha256sum "$TMP_DIR/source.gguf" | cut -d' ' -f1)
expected_size=$(wc -c < "$TMP_DIR/source.gguf")
printf 'partial transfer\n' > "$partial"
printf '%s\n' "$expected_sha" > "$partial.sha256"
if MOCK_CURL_FAIL=1 run_downloader; then
    fail "a failed download is reported"
elif cmp -s "$old_content" "$model" \
    && [ "$(cat "$receipt")" = "$new_sha" ] \
    && [ -f "$partial" ]; then
    pass "a failed download retains the old model, receipt, and partial"
else
    fail "a failed download retains the old model, receipt, and partial"
fi

if run_downloader \
    && cmp -s "$TMP_DIR/source.gguf" "$model" \
    && [ "$(cat "$receipt")" = "$expected_sha" ]; then
    pass "a retained partial can be resumed on the next deployment"
else
    fail "a retained partial can be resumed on the next deployment"
fi

new_sha="$expected_sha"
rm "$model" "$receipt"
cp "$TMP_DIR/source.gguf" "$partial"
printf '%s\n' "$expected_sha" > "$partial.sha256"
: > "$TMP_DIR/sha256.log"
before_downloads=$(wc -l < "$TMP_DIR/curl.log")
if run_downloader \
    && cmp -s "$TMP_DIR/source.gguf" "$model" \
    && [ "$(cat "$receipt")" = "$new_sha" ] \
    && [ "$(wc -l < "$TMP_DIR/curl.log")" -eq "$before_downloads" ] \
    && [ "$(wc -l < "$TMP_DIR/sha256.log")" -eq 1 ]; then
    pass "a completed partial is verified and installed without another transfer"
else
    fail "a completed partial is verified and installed without another transfer"
fi

rm "$model" "$receipt"
tr '[:lower:]' '[:upper:]' < "$TMP_DIR/source.gguf" > "$partial"
printf '%s\n' "$expected_sha" > "$partial.sha256"
before_downloads=$(wc -l < "$TMP_DIR/curl.log")
: > "$TMP_DIR/sha256.log"
if run_downloader \
    && cmp -s "$TMP_DIR/source.gguf" "$model" \
    && [ "$(wc -l < "$TMP_DIR/curl.log")" -eq "$((before_downloads + 1))" ] \
    && [ "$(wc -l < "$TMP_DIR/sha256.log")" -eq 2 ]; then
    pass "an invalid complete partial is discarded before retry"
else
    fail "an invalid complete partial is discarded before retry"
fi

third_model="$TMP_DIR/third-model.gguf"
cp "$model" "$third_model"
printf 'third model revision\n' > "$TMP_DIR/source.gguf"
expected_sha=$(sha256sum "$TMP_DIR/source.gguf" | cut -d' ' -f1)
expected_size=$(wc -c < "$TMP_DIR/source.gguf")
if MOCK_MV_FAIL_PARTIAL=1 run_downloader; then
    fail "a failed atomic replacement is reported"
elif cmp -s "$third_model" "$model" \
    && [ ! -e "$receipt" ] \
    && [ -f "$partial" ]; then
    pass "a failed replacement keeps the old model and invalidates its receipt"
else
    fail "a failed replacement keeps the old model and invalidates its receipt"
fi

if run_downloader \
    && cmp -s "$TMP_DIR/source.gguf" "$model" \
    && [ "$(cat "$receipt")" = "$expected_sha" ]; then
    pass "a verified partial can be installed after a replacement failure"
else
    fail "a verified partial can be installed after a replacement failure"
fi

printf 'fourth model revision\n' > "$TMP_DIR/source.gguf"
expected_sha=$(sha256sum "$TMP_DIR/source.gguf" | cut -d' ' -f1)
expected_size=$(wc -c < "$TMP_DIR/source.gguf")
if MOCK_MV_FAIL_RECEIPT=1 run_downloader \
    && cmp -s "$TMP_DIR/source.gguf" "$model" \
    && [ ! -e "$receipt" ] \
    && grep -Fq "WARNING: could not write checksum receipt" "$TMP_DIR/download.out"; then
    pass "a receipt-write failure warns but keeps the verified model"
else
    fail "a receipt-write failure warns but keeps the verified model"
fi

: > "$TMP_DIR/sha256.log"
if run_downloader \
    && [ "$(wc -l < "$TMP_DIR/sha256.log")" -eq 1 ] \
    && [ "$(cat "$receipt")" = "$expected_sha" ]; then
    pass "a model without a writable receipt is re-verified next run"
else
    fail "a model without a writable receipt is re-verified next run"
fi

printf '../escape.gguf|https://huggingface.co/example/model/resolve/main/model.gguf\n' \
    > "$TMP_DIR/manifest.txt"
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
