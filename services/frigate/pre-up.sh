#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/../../scripts/lib.sh"

validate_env CONFIG_DIR ENV_FILE

set -a
# shellcheck disable=SC1090,SC1091
[ -f "$CONFIG_DIR/common.env" ] && source "$CONFIG_DIR/common.env"
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [ -z "${FRIGATE_MODEL_URL:-}" ] && [ -z "${FRIGATE_MODEL_SHA256:-}" ]; then
    echo "No Frigate model preparation configured"
    exit 0
fi

validate_env DOCKER_APPDATA_ROOT FRIGATE_MODEL_URL FRIGATE_MODEL_SHA256

model_name="${FRIGATE_MODEL_NAME:-detector}"
input_size="${FRIGATE_MODEL_INPUT_SIZE:-640}"
opset="${FRIGATE_MODEL_OPSET:-13}"

if [[ ! "$model_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "ERROR: FRIGATE_MODEL_NAME must be a single model-cache directory name" >&2
    exit 1
fi
if [[ "$FRIGATE_MODEL_URL" != https://?* ]]; then
    echo "ERROR: FRIGATE_MODEL_URL must use HTTPS" >&2
    exit 1
fi
if [[ ! "$FRIGATE_MODEL_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]]; then
    echo "ERROR: FRIGATE_MODEL_SHA256 must be a SHA-256 checksum" >&2
    exit 1
fi
if [[ ! "$input_size" =~ ^[1-9][0-9]*$ ]] \
    || [[ ! "$opset" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: FRIGATE_MODEL_INPUT_SIZE and FRIGATE_MODEL_OPSET must be positive integers" >&2
    exit 1
fi

model_dir="$DOCKER_APPDATA_ROOT/frigate/model_cache/$model_name"
build_env="$DOCKER_APPDATA_ROOT/frigate/model-build-env"
args=("$model_dir"
    --checkpoint-url "$FRIGATE_MODEL_URL"
    --checkpoint-sha256 "$FRIGATE_MODEL_SHA256"
    --input-size "$input_size"
    --opset "$opset")

if [ -e "$model_dir" ] && [ ! -d "$model_dir" ]; then
    echo "ERROR: model destination must be a directory: $model_dir" >&2
    exit 1
fi

if ! command -v python3 >/dev/null; then
    apt_get update -qq >/dev/null
    apt_get install -y -qq python3-venv >/dev/null
fi

if [ -d "$model_dir" ] \
    && [ -n "$(find -H "$model_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    python3 "$SCRIPT_DIR/prepare-model.py" "${args[@]}"
    exit 0
fi

if ! python3 -c 'import sys; sys.exit(0 if (3, 11) <= sys.version_info[:2] <= (3, 12) else 1)'; then
    echo "ERROR: model conversion requires Python 3.11 or 3.12" >&2
    exit 1
fi

apt_get update -qq >/dev/null
apt_get install -y -qq python3-venv libgl1 libglib2.0-0 >/dev/null

if [ ! -x "$build_env/bin/python" ]; then
    python3 -m venv "$build_env"
fi

python="$build_env/bin/python"
mapfile -t cpu_requirements < <(
    grep -E '^(torch|torchvision)==' "$SCRIPT_DIR/requirements-model.txt" | tr -d '\r'
)
"$python" -m pip install "${cpu_requirements[@]}" \
    --index-url https://download.pytorch.org/whl/cpu
"$python" -m pip install -r "$SCRIPT_DIR/requirements-model.txt"
"$python" "$SCRIPT_DIR/prepare-model.py" "${args[@]}"
