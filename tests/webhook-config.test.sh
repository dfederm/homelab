#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_FILE="$REPO_DIR/services/webhook/hooks.json"
COMPOSE_FILE="$REPO_DIR/services/webhook/docker-compose.yml"
PYTHON=$(command -v python3 || command -v python || command -v python.exe)

"$PYTHON" - "$HOOKS_FILE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
rendered = path.read_text(encoding="utf-8").replace(
    '{{ getenv "WEBHOOK_SECRET" | js }}',
    "test-secret",
)
hooks = json.loads(rendered)
arguments = hooks[0]["pass-arguments-to-command"]
names = [argument["name"] for argument in arguments]
if names != ["ref"]:
    raise SystemExit(f"unexpected webhook arguments: {names}")
if hooks[0]["execute-command"] != "/opt/homelab/scripts/dispatch.sh":
    raise SystemExit("webhook does not execute the image-baked signal handler")
PY

if grep -qF ':/repo' "$COMPOSE_FILE"; then
    echo "webhook still mounts mutable repository source" >&2
    exit 1
fi
if grep -qE 'docker\.sock|/usr/bin/docker|homelab-deploy' "$COMPOSE_FILE"; then
    echo "webhook still mounts deployment state or Docker control" >&2
    exit 1
fi
grep -qF 'context: ../..' "$COMPOSE_FILE"
grep -qF 'COPY services/webhook/dispatch.sh scripts/lib.sh /opt/homelab/scripts/' \
    "$REPO_DIR/services/webhook/Dockerfile"
grep -qF 'COPY services/webhook/hooks.json /opt/homelab/hooks.json' \
    "$REPO_DIR/services/webhook/Dockerfile"
grep -qF 'command: ["-template", "-hooks", "/opt/homelab/hooks.json", "-verbose"]' \
    "$COMPOSE_FILE"
if grep -qF '/etc/webhook/hooks.json' \
    "$REPO_DIR/services/webhook/Dockerfile" "$COMPOSE_FILE"; then
    echo "webhook hook config still uses the image's declared volume" >&2
    exit 1
fi
if grep -qE 'apk add .*git|apk add .*util-linux' \
    "$REPO_DIR/services/webhook/Dockerfile"; then
    echo "webhook image still installs obsolete Git/locking tools" >&2
    exit 1
fi
grep -qF 'env_file: ${ENV_FILE}' \
    "$REPO_DIR/services/reverse-proxy/docker-compose.yml"
if grep -R -qE '^[[:space:]]*env_file:[[:space:]]+\.env$' \
    "$REPO_DIR/services"; then
    echo "service Compose still depends on a source-tree .env file" >&2
    exit 1
fi
if grep -q 'ln -sf .*\\.env' "$REPO_DIR/scripts/run-service.sh"; then
    echo "run-service still mutates its source tree" >&2
    exit 1
fi

echo "webhook config tests passed"
