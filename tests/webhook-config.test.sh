#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_FILE="$REPO_DIR/services/webhook/hooks.json"
COMPOSE_FILE="$REPO_DIR/services/webhook/docker-compose.yml"
PYTHON=$(command -v python3 || command -v python || command -v python.exe)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

"$PYTHON" - "$HOOKS_FILE" "$COMPOSE_FILE" <<'PY'
import json
import pathlib
import re
import sys

import yaml

hooks_path = pathlib.Path(sys.argv[1])
compose_path = pathlib.Path(sys.argv[2])

rendered = re.sub(
    r"\{\{.*?\}\}",
    "test-secret",
    hooks_path.read_text(encoding="utf-8"),
)
hooks = json.loads(rendered)
if not isinstance(hooks, list) or not hooks:
    raise SystemExit("webhook hooks must be a non-empty JSON array")

webhook = yaml.safe_load(compose_path.read_text(encoding="utf-8"))["services"]["webhook"]

volumes = webhook.get("volumes", [])
for volume in volumes:
    serialized = json.dumps(volume) if isinstance(volume, dict) else volume
    if any(
        forbidden in serialized
        for forbidden in (":/repo", "docker.sock", "homelab-deploy")
    ):
        raise SystemExit(f"webhook has forbidden deployment access: {volume}")
PY

FAKE_REPO="$TEST_ROOT/repo"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_CONFIG="$TEST_ROOT/config"
mkdir -p "$FAKE_REPO/scripts" "$FAKE_REPO/services/webhook" \
    "$FAKE_BIN" "$FAKE_CONFIG"
cp "$REPO_DIR/scripts/run-service.sh" "$FAKE_REPO/scripts/run-service.sh"
touch "$FAKE_REPO/services/webhook/docker-compose.yml" "$FAKE_CONFIG/test.env"

cat > "$FAKE_REPO/scripts/lib.sh" <<'EOF'
source_env() {
    CONFIG_DIR="$TEST_CONFIG_DIR"
    ENV_FILE="$TEST_ENV_FILE"
    export CONFIG_DIR ENV_FILE
}
EOF

cat > "$FAKE_BIN/docker" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_DOCKER_LOG"
EOF
chmod +x "$FAKE_BIN/docker"

TEST_CONFIG_DIR="$FAKE_CONFIG" \
TEST_ENV_FILE="$FAKE_CONFIG/test.env" \
TEST_DOCKER_LOG="$TEST_ROOT/docker.log" \
HOMELAB_SETUP_LOCK_HELD=1 \
PATH="$FAKE_BIN:$PATH" \
    bash "$FAKE_REPO/scripts/run-service.sh" webhook >/dev/null

if [ -e "$FAKE_REPO/services/webhook/.env" ]; then
    echo "run-service must not create a source-tree .env file" >&2
    exit 1
fi

echo "webhook config tests passed"
