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

reconcile_model_source() {
    if [ ! -f "$source_receipt" ] || [ "$(cat "$source_receipt")" != "$model_source" ]; then
        if ! write_receipt "$source_receipt" "$model_source"; then
            echo "WARNING: could not record model source for $relative_path; offline use may be unavailable." >&2
        fi
    fi
}

read_huggingface_metadata() {
    local headers

    if ! headers="$(curl --fail --silent --show-error --head --location --retry 5 --retry-delay 5 \
        --connect-timeout 10 --max-time 30 "$1")"; then
        return 1
    fi

    metadata_commit="$(printf '%s\n' "$headers" | awk 'tolower($1) == "x-repo-commit:" {gsub("\r", "", $2); print $2}')"
    metadata_sha="$(printf '%s\n' "$headers" | awk 'tolower($1) == "x-linked-etag:" {gsub(/["\r]/, "", $2); print $2}')"
    metadata_size="$(printf '%s\n' "$headers" | awk 'tolower($1) == "x-linked-size:" {gsub("\r", "", $2); print $2}')"
    [[ "$metadata_commit" =~ ^[0-9a-f]{40}$ ]] \
        && [[ "$metadata_sha" =~ ^[0-9a-f]{64}$ ]] \
        && [[ "$metadata_size" =~ ^[1-9][0-9]*$ ]]
}

install -d "$LLAMA_MODELS_ROOT"

while IFS='|' read -r relative_path url extra; do
    [ -z "$relative_path" ] && continue
    [[ "$relative_path" == \#* ]] && continue

    url=${url%$'\r'}

    if [[ ! "$relative_path" =~ ^[A-Za-z0-9._/-]+$ ]] \
        || [[ "$relative_path" =~ (^|/)\.\.(/|$) ]] \
        || [[ "$relative_path" == /* ]]; then
        echo "ERROR: invalid model path in manifest: $relative_path" >&2
        exit 1
    fi
    if [ -n "$extra" ] \
        || [[ ! "$url" =~ ^https://huggingface\.co/([^/]+/[^/]+)/resolve/([^/]+)/(.+)$ ]]; then
        echo "ERROR: expected relative-path|Hugging Face URL for $relative_path" >&2
        exit 1
    fi
    repo="${BASH_REMATCH[1]}"
    filename="${BASH_REMATCH[3]}"

    target="$LLAMA_MODELS_ROOT/$relative_path"
    partial="$target.partial"
    receipt="$target.sha256"
    source_receipt="$target.source"
    install -d "$(dirname "$target")"

    model_source="$url"
    if ! read_huggingface_metadata "$model_source"; then
        if [ -f "$target" ] && [ -f "$receipt" ] && [ -f "$source_receipt" ] \
            && [[ "$(cat "$receipt")" =~ ^[0-9a-f]{64}$ ]] \
            && [ "$(cat "$source_receipt")" = "$model_source" ]; then
            echo "WARNING: could not check for model updates; using cached model: $relative_path" >&2
            continue
        fi
        echo "ERROR: could not check for model updates and no verified model is available: $relative_path" >&2
        exit 1
    fi
    expected_sha="$metadata_sha"
    expected_size="$metadata_size"
    url="https://huggingface.co/$repo/resolve/$metadata_commit/$filename"

    if [ -f "$target" ] && [ -f "$receipt" ]; then
        receipt_sha="$(cat "$receipt")"
        if [ "$receipt_sha" = "$expected_sha" ]; then
            reconcile_model_source
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
            reconcile_model_source
            echo "  Model verified: $relative_path"
            continue
        fi
        echo "  Existing model failed verification; downloading replacement: $relative_path"
    elif [ ! -f "$target" ]; then
        echo "  Downloading model: $relative_path"
    fi

    if [ -f "$partial" ] \
        && { [ ! -f "$partial.sha256" ] || [ "$(cat "$partial.sha256")" != "$expected_sha" ]; }; then
        rm -f "$partial" "$partial.sha256"
    fi

    if [ -f "$partial" ]; then
        actual_sha="$(sha256sum "$partial" | cut -d' ' -f1)"
        actual_size="$(wc -c < "$partial")"
        if [ "$actual_sha" = "$expected_sha" ] && [ "$actual_size" -eq "$expected_size" ]; then
            if [ -e "$source_receipt" ] && ! rm -f "$source_receipt"; then
                echo "ERROR: could not invalidate model source for $relative_path" >&2
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
            rm -f "$partial.sha256"
            if ! write_receipt "$receipt" "$actual_sha"; then
                echo "WARNING: could not write checksum receipt for $relative_path; it will be re-verified next deployment." >&2
            fi
            reconcile_model_source
            echo "  Installed verified model: $relative_path"
            continue
        fi
        if [ "$actual_size" -ge "$expected_size" ]; then
            rm -f "$partial"
            echo "  Discarded invalid complete partial: $relative_path"
        fi
    fi

    if ! write_receipt "$partial.sha256" "$expected_sha"; then
        echo "ERROR: could not record partial model checksum: $relative_path" >&2
        exit 1
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
        rm -f "$partial.sha256"
        echo "ERROR: verification failed for $relative_path" >&2
        echo "       expected: $expected_sha ($expected_size bytes)" >&2
        echo "       actual:   $actual_sha ($actual_size bytes)" >&2
        exit 1
    fi

    if [ -e "$source_receipt" ] && ! rm -f "$source_receipt"; then
        echo "ERROR: could not invalidate model source for $relative_path" >&2
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
    rm -f "$partial.sha256"
    if ! write_receipt "$receipt" "$actual_sha"; then
        echo "WARNING: could not write checksum receipt for $relative_path; it will be re-verified next deployment." >&2
    fi
    reconcile_model_source
    echo "  Installed verified model: $relative_path"
done < "$MODEL_MANIFEST"
