#!/bin/bash

set -euo pipefail

MODEL_MANIFEST="${LLAMA_MODEL_MANIFEST:-${CONFIG_DIR:?CONFIG_DIR not set}/ai/models.txt}"
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

write_receipt() {
    local receipt_path="$1"
    local verified_sha="$2"
    local temporary_receipt

    if ! temporary_receipt="$(mktemp "${receipt_path}.tmp.XXXXXX")"; then
        return 1
    fi
    if ! printf '%s\n' "$verified_sha" > "$temporary_receipt" \
        || ! mv -f "$temporary_receipt" "$receipt_path"; then
        rm -f "$temporary_receipt"
        return 1
    fi
}

install -d "$LLAMA_MODELS_ROOT"

while IFS='|' read -r relative_path expected_sha expected_size url; do
    url=${url%$'\r'}

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
    receipt="$target.sha256"
    install -d "$(dirname "$target")"

    if [ -f "$target" ] && [ -f "$receipt" ]; then
        receipt_sha="$(cat "$receipt")"
        if [ "$receipt_sha" = "$expected_sha" ]; then
            echo "  Model accepted from checksum receipt: $relative_path"
            continue
        fi
        if [[ "$receipt_sha" =~ ^[0-9a-f]{64}$ ]]; then
            echo "  Model receipt does not match expected checksum; downloading replacement: $relative_path"
        fi
    fi

    if [ -f "$target" ] && { [ ! -f "$receipt" ] || [[ ! "$receipt_sha" =~ ^[0-9a-f]{64}$ ]]; }; then
        actual_sha="$(sha256sum "$target" | cut -d' ' -f1)"
        if [ "$actual_sha" = "$expected_sha" ]; then
            if ! write_receipt "$receipt" "$actual_sha"; then
                echo "WARNING: could not write checksum receipt for $relative_path; it will be re-verified next deployment." >&2
            fi
            echo "  Model verified: $relative_path"
            continue
        fi
        echo "  Existing model failed verification; downloading replacement: $relative_path"
    elif [ ! -f "$target" ]; then
        echo "  Downloading model: $relative_path"
    fi

    if [ -f "$partial" ]; then
        actual_sha="$(sha256sum "$partial" | cut -d' ' -f1)"
        actual_size="$(wc -c < "$partial")"
        if [ "$actual_sha" = "$expected_sha" ] && [ "$actual_size" -eq "$expected_size" ]; then
            if [ -e "$receipt" ] && ! rm -f "$receipt"; then
                echo "ERROR: could not invalidate checksum receipt for $relative_path" >&2
                exit 1
            fi
            if ! mv -f "$partial" "$target"; then
                echo "ERROR: could not install verified model: $relative_path" >&2
                exit 1
            fi
            if ! write_receipt "$receipt" "$actual_sha"; then
                echo "WARNING: could not write checksum receipt for $relative_path; it will be re-verified next deployment." >&2
            fi
            echo "  Installed verified model: $relative_path"
            continue
        fi
        if [ "$actual_size" -ge "$expected_size" ]; then
            rm -f "$partial"
            echo "  Discarded invalid complete partial: $relative_path"
        fi
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

    if [ -e "$receipt" ] && ! rm -f "$receipt"; then
        echo "ERROR: could not invalidate checksum receipt for $relative_path" >&2
        exit 1
    fi
    if ! mv -f "$partial" "$target"; then
        echo "ERROR: could not install verified model: $relative_path" >&2
        exit 1
    fi
    if ! write_receipt "$receipt" "$actual_sha"; then
        echo "WARNING: could not write checksum receipt for $relative_path; it will be re-verified next deployment." >&2
    fi
    echo "  Installed verified model: $relative_path"
done < "$MODEL_MANIFEST"
