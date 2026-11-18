#!/bin/bash

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAILURES=0

pass() {
    echo "  PASS: $1"
}

fail() {
    echo "  FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/models/test"
cat > "$TMP_DIR/bin/curl" <<'EOF'
#!/bin/bash
set -eu

head=false
continue_at=false
follow_redirects=false
output=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --head) head=true; shift ;;
        --continue-at) continue_at=true; shift 2 ;;
        --location) follow_redirects=true; shift ;;
        --output) output="$2"; shift 2 ;;
        --retry|--retry-delay|--connect-timeout|--max-time) shift 2 ;;
        --fail|--silent|--show-error) shift ;;
        *) url="$1"; shift ;;
    esac
done

if [ "$head" = true ]; then
    printf 'HEAD %s\n' "$url" >> "$MOCK_LOG"
    [ "${MOCK_METADATA_FAIL:-0}" -eq 0 ] || exit 22
    if [ "${MOCK_REDIRECT:-0}" -eq 1 ]; then
        printf 'HTTP/1.1 307 Temporary Redirect\r\nLocation: https://huggingface.co/example/moved/resolve/main/model.gguf\r\n\r\n'
        [ "$follow_redirects" = true ] || exit 0
        printf 'FOLLOW https://huggingface.co/example/moved/resolve/main/model.gguf\n' >> "$MOCK_LOG"
    fi
    printf 'HTTP/1.1 302 Found\r\nx-repo-commit: %s\r\nX-Linked-ETag: "%s"\r\nX-Linked-Size: %s\r\n\r\n' \
        "$MOCK_COMMIT" "$MOCK_SHA" "$MOCK_SIZE"
else
    if [ -f "$output" ] && [ "$continue_at" = true ]; then
        printf 'RESUME %s\n' "$url" >> "$MOCK_LOG"
    else
        printf 'GET %s\n' "$url" >> "$MOCK_LOG"
    fi
    if [ "${MOCK_DOWNLOAD_FAIL:-0}" -eq 1 ]; then
        head -c 7 "$MOCK_SOURCE" > "$output"
        exit 22
    fi
    if [ -f "$output" ] && [ "$continue_at" = true ]; then
        offset="$(wc -c < "$output")"
        tail -c "+$((offset + 1))" "$MOCK_SOURCE" >> "$output"
    else
        cp "$MOCK_SOURCE" "$output"
    fi
fi
EOF
chmod +x "$TMP_DIR/bin/curl"

commit_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
commit_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
model="$TMP_DIR/models/test/model.gguf"
receipt="$model.sha256"
partial="$model.partial"
printf 'original model\n' > "$TMP_DIR/source"
sha_a="$(sha256sum "$TMP_DIR/source" | cut -d' ' -f1)"
size_a="$(wc -c < "$TMP_DIR/source")"
printf 'test/model.gguf|https://huggingface.co/example/model/resolve/main/model.gguf\n' \
    > "$TMP_DIR/manifest"
cp "$TMP_DIR/source" "$model"
printf '%s\n' "$sha_a" > "$receipt"
: > "$TMP_DIR/curl.log"

run_downloader() {
    PATH="$TMP_DIR/bin:$PATH" \
    LLAMA_MODELS_ROOT="$TMP_DIR/models" \
    LLAMA_MODEL_MANIFEST="$TMP_DIR/manifest" \
    MOCK_LOG="$TMP_DIR/curl.log" \
    MOCK_SOURCE="$TMP_DIR/source" \
    MOCK_COMMIT="${MOCK_COMMIT:-$commit_a}" \
    MOCK_SHA="${MOCK_SHA:-$sha_a}" \
    MOCK_SIZE="${MOCK_SIZE:-$size_a}" \
    MOCK_REDIRECT="${MOCK_REDIRECT:-0}" \
        bash "$REPO_DIR/services/ai/download-models.sh" > "$TMP_DIR/out" 2>&1
}

echo "=== Hugging Face model updates ==="
if run_downloader \
    && grep -Fxq 'HEAD https://huggingface.co/example/model/resolve/main/model.gguf' "$TMP_DIR/curl.log" \
    && [ "$(wc -l < "$TMP_DIR/curl.log")" -eq 1 ] \
    && grep -Fq 'Model accepted from checksum receipt' "$TMP_DIR/out"; then
    pass "the configured branch is checked and an unchanged model is reused"
else
    fail "the configured branch is checked and an unchanged model is reused"
fi

printf 'test/model.gguf|https://huggingface.co/example/model/resolve/candidate/model.gguf\n' \
    > "$TMP_DIR/manifest"
: > "$TMP_DIR/curl.log"
if run_downloader \
    && grep -Fxq 'HEAD https://huggingface.co/example/model/resolve/candidate/model.gguf' "$TMP_DIR/curl.log"; then
    pass "a manifest branch is followed instead of main"
else
    fail "a manifest branch is followed instead of main"
fi
printf 'test/model.gguf|https://huggingface.co/example/model/resolve/main/model.gguf\n' \
    > "$TMP_DIR/manifest"

printf 'updated model payload\n' > "$TMP_DIR/source"
sha_b="$(sha256sum "$TMP_DIR/source" | cut -d' ' -f1)"
size_b="$(wc -c < "$TMP_DIR/source")"
: > "$TMP_DIR/curl.log"
if MOCK_COMMIT="$commit_b" MOCK_SHA="$sha_b" MOCK_SIZE="$size_b" run_downloader \
    && cmp -s "$TMP_DIR/source" "$model" \
    && [ "$(cat "$receipt")" = "$sha_b" ] \
    && grep -Fxq "GET https://huggingface.co/example/model/resolve/$commit_b/model.gguf" "$TMP_DIR/curl.log"; then
    pass "an update is verified and downloaded from the resolved commit"
else
    fail "an update is verified and downloaded from the resolved commit"
fi

printf 'redirected model payload\n' > "$TMP_DIR/source"
sha_redirect="$(sha256sum "$TMP_DIR/source" | cut -d' ' -f1)"
size_redirect="$(wc -c < "$TMP_DIR/source")"
printf 'test/redirect/model.gguf|https://huggingface.co/example/original/resolve/main/model.gguf\n' \
    > "$TMP_DIR/manifest"
: > "$TMP_DIR/curl.log"
if MOCK_REDIRECT=1 MOCK_COMMIT="$commit_b" MOCK_SHA="$sha_redirect" MOCK_SIZE="$size_redirect" run_downloader \
    && cmp -s "$TMP_DIR/source" "$TMP_DIR/models/test/redirect/model.gguf" \
    && grep -Fxq 'FOLLOW https://huggingface.co/example/moved/resolve/main/model.gguf' "$TMP_DIR/curl.log"; then
    pass "metadata from a redirected Hugging Face repository is followed"
else
    fail "metadata from a redirected Hugging Face repository is followed"
fi

printf 'test/model.gguf|https://huggingface.co/example/model/resolve/main/model.gguf\n' \
    > "$TMP_DIR/manifest"
: > "$TMP_DIR/curl.log"
if MOCK_COMMIT="$commit_a" MOCK_SHA="$sha_b" MOCK_SIZE="$size_b" run_downloader \
    && [ "$(wc -l < "$TMP_DIR/curl.log")" -eq 1 ]; then
    pass "a repository commit change without a file change does not redownload"
else
    fail "a repository commit change without a file change does not redownload"
fi

printf 'third model payload\n' > "$TMP_DIR/source"
sha_c="$(sha256sum "$TMP_DIR/source" | cut -d' ' -f1)"
size_c="$(wc -c < "$TMP_DIR/source")"
cp "$model" "$TMP_DIR/previous"
if MOCK_COMMIT="$commit_a" MOCK_SHA="$sha_a" MOCK_SIZE="$size_c" run_downloader; then
    fail "an update with the wrong checksum is rejected"
elif cmp -s "$TMP_DIR/previous" "$model" \
    && [ "$(cat "$receipt")" = "$sha_b" ] \
    && [ ! -e "$partial" ]; then
    pass "an update with the wrong checksum preserves the installed model"
else
    fail "an update with the wrong checksum is rejected"
fi

if MOCK_COMMIT="$commit_a" MOCK_SHA="$sha_c" MOCK_SIZE="$size_c" MOCK_DOWNLOAD_FAIL=1 run_downloader; then
    fail "a failed update preserves the installed model"
elif cmp -s "$TMP_DIR/previous" "$model" \
    && [ "$(cat "$receipt")" = "$sha_b" ] \
    && [ "$(cat "$partial.sha256")" = "$sha_c" ] \
    && [ -f "$partial" ]; then
    pass "a failed update preserves the installed model and resumable partial"
else
    fail "a failed update preserves the installed model"
fi

: > "$TMP_DIR/curl.log"
if MOCK_COMMIT="$commit_a" MOCK_SHA="$sha_c" MOCK_SIZE="$size_c" run_downloader \
    && cmp -s "$TMP_DIR/source" "$model" \
    && grep -Fxq "RESUME https://huggingface.co/example/model/resolve/$commit_a/model.gguf" "$TMP_DIR/curl.log"; then
    pass "a partial for the same upstream version is resumed"
else
    fail "a partial for the same upstream version is resumed"
fi

printf 'fourth model payload\n' > "$TMP_DIR/source"
sha_d="$(sha256sum "$TMP_DIR/source" | cut -d' ' -f1)"
size_d="$(wc -c < "$TMP_DIR/source")"
MOCK_COMMIT="$commit_b" MOCK_SHA="$sha_d" MOCK_SIZE="$size_d" MOCK_DOWNLOAD_FAIL=1 run_downloader || true
printf 'fifth model payload\n' > "$TMP_DIR/source"
sha_e="$(sha256sum "$TMP_DIR/source" | cut -d' ' -f1)"
size_e="$(wc -c < "$TMP_DIR/source")"
: > "$TMP_DIR/curl.log"
if MOCK_COMMIT="$commit_b" MOCK_SHA="$sha_e" MOCK_SIZE="$size_e" run_downloader \
    && cmp -s "$TMP_DIR/source" "$model" \
    && grep -Fxq "GET https://huggingface.co/example/model/resolve/$commit_b/model.gguf" "$TMP_DIR/curl.log" \
    && [ ! -e "$partial.sha256" ]; then
    pass "a partial from another upstream version is not resumed"
else
    fail "a partial from another upstream version is not resumed"
fi

if MOCK_METADATA_FAIL=1 run_downloader \
    && cmp -s "$TMP_DIR/source" "$model" \
    && grep -Fq 'using cached model' "$TMP_DIR/out"; then
    pass "metadata failure preserves and uses a cached verified model"
else
    fail "metadata failure preserves and uses a cached verified model"
fi

if MOCK_SHA=not-a-sha run_downloader \
    && cmp -s "$TMP_DIR/source" "$model" \
    && grep -Fq 'using cached model' "$TMP_DIR/out"; then
    pass "invalid upstream metadata does not replace a cached model"
else
    fail "invalid upstream metadata does not replace a cached model"
fi

printf 'test/model.gguf|https://huggingface.co/example/other/resolve/main/model.gguf\n' > "$TMP_DIR/manifest"
if MOCK_METADATA_FAIL=1 run_downloader; then
    fail "an offline source change does not reuse a different model"
elif cmp -s "$TMP_DIR/source" "$model"; then
    pass "an offline source change does not reuse a different model"
else
    fail "an offline source change preserves the existing model"
fi

rm "$model" "$receipt"
printf 'test/model.gguf|https://huggingface.co/example/model/resolve/main/model.gguf\r\n' > "$TMP_DIR/manifest"
if MOCK_METADATA_FAIL=1 run_downloader; then
    fail "metadata failure without a verified model fails deployment"
else
    pass "metadata failure without a verified model fails deployment"
fi

: > "$TMP_DIR/curl.log"
if MOCK_COMMIT="$commit_b" MOCK_SHA="$sha_e" MOCK_SIZE="$size_e" run_downloader \
    && cmp -s "$TMP_DIR/source" "$model" \
    && [ "$(cat "$receipt")" = "$sha_e" ] \
    && grep -Fxq 'HEAD https://huggingface.co/example/model/resolve/main/model.gguf' "$TMP_DIR/curl.log"; then
    pass "a CRLF Hugging Face entry can be installed without manifest pins"
else
    fail "a CRLF Hugging Face entry can be installed without manifest pins"
fi

printf 'test/model.gguf|https://example.invalid/model.gguf\n' > "$TMP_DIR/manifest"
if run_downloader; then
    fail "a non-Hugging Face URL is rejected"
else
    pass "a non-Hugging Face URL is rejected"
fi

printf 'test/model.gguf|%s|%s|https://huggingface.co/example/model/resolve/main/model.gguf\n' \
    "$sha_e" "$size_e" > "$TMP_DIR/manifest"
if run_downloader; then
    fail "the old four-field manifest format is rejected"
else
    pass "the old four-field manifest format is rejected"
fi

if [ "$FAILURES" -eq 0 ]; then
    echo "Hugging Face model update tests passed"
else
    echo "$FAILURES test(s) failed"
fi
exit "$FAILURES"
