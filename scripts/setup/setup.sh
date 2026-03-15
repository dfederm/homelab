#!/bin/bash
# setup.sh — Machine setup runner
#
# Sources an optional common.env (shared vars like TZ, users, network) then
# a machine-specific .env file, and runs each module listed in
# HOMELAB_SETUP_MODULES as a subprocess. Modules inherit all exported
# env vars. Machine-specific values override common ones.
#
# Env file resolution (first match wins):
#   1. Explicit argument:  setup.sh /path/to/host.env
#   2. /etc/homelab.env    (symlink created on first run)
#   3. <repo>/../config/<hostname>.env
#
# Creates /etc/homelab.env symlink so subsequent runs need no arguments.
# REPO_DIR and ENV_FILE are re-set after sourcing to prevent env file override.

set -euo pipefail

SYSTEM_ENV="/etc/homelab.env"

# Derive repo root from this script's location
SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_DIR="$(cd "$REPO_DIR/.." && pwd)/config"

if [ -n "${1:-}" ]; then
    ENV_FILE="$1"
elif [ -f "$SYSTEM_ENV" ]; then
    ENV_FILE="$SYSTEM_ENV"
elif [ -f "$CONFIG_DIR/$(hostname).env" ]; then
    ENV_FILE="$CONFIG_DIR/$(hostname).env"
else
    echo "ERROR: No env file found." >&2
    echo "  Tried: $SYSTEM_ENV" >&2
    echo "  Tried: $CONFIG_DIR/$(hostname).env" >&2
    echo "  Or pass an explicit path: setup.sh <env-file>" >&2
    exit 1
fi

# Create/update system symlink so future runs need no arguments
ln -sf "$(realpath "$ENV_FILE")" "$SYSTEM_ENV"

# Resolve config directory from the real env file path
REAL_ENV="$(realpath "$ENV_FILE")"
ENV_DIR="$(dirname "$REAL_ENV")"
COMMON_ENV="$ENV_DIR/common.env"

# Source common env first (shared vars), then machine-specific (overrides)
set -a
if [ -f "$COMMON_ENV" ]; then
    source "$COMMON_ENV"
fi
source "$ENV_FILE"
set +a

# Script-derived vars (set after source to prevent env file override)
export REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
export ENV_FILE

# Ensure git trusts the repo directory (needed when repo lives on a shared/imported filesystem)
git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true

MODULES_DIR="$SCRIPT_DIR/modules"

if [ -z "${HOMELAB_SETUP_MODULES:-}" ]; then
    echo "WARNING: HOMELAB_SETUP_MODULES is empty, nothing to do"
    exit 0
fi

echo "=== Setup: $(hostname) ==="
echo "Env: $ENV_FILE"
echo "Modules: $HOMELAB_SETUP_MODULES"
echo ""

for module in $HOMELAB_SETUP_MODULES; do
    module_path="$MODULES_DIR/$module.sh"
    if [ ! -f "$module_path" ]; then
        echo "ERROR: module not found: $module_path" >&2
        exit 1
    fi
    echo "--- Running module: $module ---"
    bash "$module_path"
    echo ""
done

echo "=== Setup complete ==="
