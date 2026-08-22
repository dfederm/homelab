#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_MANIFEST="${LLAMA_MODEL_MANIFEST:-$SCRIPT_DIR/models.txt}"
: "${LLAMA_MODELS_ROOT:?LLAMA_MODELS_ROOT not set}"

for command in curl sha256sum; do
    if ! command -v "$command" &> /dev/null; then
        echo "ERROR: $command not found - AI model acquisition needs it" >&2
        exit 1
    fi
done

if [ ! -f "$MODEL_MANIFEST" ]; then
    echo "ERROR: model manifest not found: $MODEL_MANIFEST" >&2
    exit 1
fi

install -d "$LLAMA_MODELS_ROOT"

while IFS='|' read -r relative_path expected_sha expected_size url; do
    [ -z "$relative_path" ] && continue
    [[ "$relative_path" == \#* ]] && continue

    if [[ ! "$relative_path" =~ ^[A-Za-z0-9._/-]+$ ]] \
        || [[ "$relative_path" =~ (^|/)\.\.(/|$) ]] \
        || [[ "$relative_path" == /* ]]; then
        echo "ERROR: invalid model path in manifest: $relative_path" >&2
        exit 1
    fi
    if [[ ! "$expected_sha" =~ ^[0-9a-f]{64}$ ]]; then
        echo "ERROR: invalid SHA-256 for $relative_path" >&2
        exit 1
    fi
    if [[ ! "$expected_size" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: invalid size for $relative_path" >&2
        exit 1
    fi
    if [[ ! "$url" =~ ^https:// ]]; then
        echo "ERROR: model URL must use HTTPS: $relative_path" >&2
        exit 1
    fi

    target="$LLAMA_MODELS_ROOT/$relative_path"
    partial="$target.partial"
    install -d "$(dirname "$target")"

    if [ -f "$partial" ]; then
        actual_sha="$(sha256sum "$partial" | cut -d' ' -f1)"
        if [ "$actual_sha" = "$expected_sha" ]; then
            mv "$partial" "$target"
            echo "  Installed verified model: $relative_path"
            continue
        fi
        if [ "$(wc -c < "$partial")" -ge "$expected_size" ]; then
            rm -f "$partial"
            echo "  Discarded invalid complete partial: $relative_path"
        fi
    fi

    if [ -f "$target" ]; then
        actual_sha="$(sha256sum "$target" | cut -d' ' -f1)"
        if [ "$actual_sha" = "$expected_sha" ]; then
            echo "  Model already verified: $relative_path"
            continue
        fi
        echo "  Existing model failed verification; downloading replacement: $relative_path"
    else
        echo "  Downloading model: $relative_path"
    fi

    if ! curl --fail --location --retry 5 --retry-delay 5 \
        --continue-at - --output "$partial" "$url"; then
        echo "ERROR: model download failed: $relative_path" >&2
        echo "       Partial data was retained for the next deployment to resume." >&2
        exit 1
    fi

    actual_sha="$(sha256sum "$partial" | cut -d' ' -f1)"
    actual_size="$(wc -c < "$partial")"
    if [ "$actual_sha" != "$expected_sha" ] || [ "$actual_size" -ne "$expected_size" ]; then
        rm -f "$partial"
        echo "ERROR: verification failed for $relative_path" >&2
        echo "       expected: $expected_sha ($expected_size bytes)" >&2
        echo "       actual:   $actual_sha ($actual_size bytes)" >&2
        exit 1
    fi

    mv "$partial" "$target"
    echo "  Installed verified model: $relative_path"
done < "$MODEL_MANIFEST"
