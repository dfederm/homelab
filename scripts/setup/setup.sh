#!/bin/bash
# setup.sh — Machine setup runner
#
# Sources env files, runs each module listed in HOMELAB_SETUP_MODULES,
# then deploys any Docker services listed in HOMELAB_SERVICES. Modules
# inherit all exported env vars. Machine-specific values override common ones.
#
# Creates /etc/homelab.env symlink so subsequent runs need no arguments.
# REPO_DIR and ENV_FILE are re-set after sourcing to prevent env file override.

set -euo pipefail

# Derive repo root from this script's location
SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_DIR/scripts/lib.sh"

# Source env files (set -a exports all vars for child module processes)
set -a
source_env
set +a

# Script-derived vars (set after source to prevent env file override)
export REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
export ENV_FILE

# Ensure git trusts the repo directory (needed when repo lives on a shared/imported filesystem)
git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true

MODULES_DIR="$SCRIPT_DIR/modules"

echo "=== Setup: $(hostname) ==="
echo "Env: $ENV_FILE"
echo "Modules: ${HOMELAB_SETUP_MODULES:-<none>}"
echo "Services: ${HOMELAB_SERVICES:-<none>}"
echo ""

if [ -z "${HOMELAB_SETUP_MODULES:-}" ] && [ -z "${HOMELAB_SERVICES:-}" ]; then
    echo "WARNING: No modules or services configured, nothing to do"
    exit 0
fi

# --- Run setup modules ---

for module in ${HOMELAB_SETUP_MODULES:-}; do
    module_path="$MODULES_DIR/$module.sh"
    if [ ! -f "$module_path" ]; then
        echo "ERROR: module not found: $module_path" >&2
        exit 1
    fi
    echo "--- Running module: $module ---"
    bash "$module_path"
    echo ""
done

# --- Deploy services ---

if [ -n "${HOMELAB_SERVICES:-}" ] && command -v docker &> /dev/null; then
    echo "--- Deploying services ---"
    bash "$REPO_DIR/scripts/run-all-services.sh"
    echo ""
fi

echo "=== Setup complete ==="
