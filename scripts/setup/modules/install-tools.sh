#!/bin/bash
# Module: Install common utility packages
# Idempotent — apt-get skips already installed packages.
#
# Env vars:
#   REPO_DIR  (required, set by setup.sh) repo path on this host

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

echo "Installing common tools..."
apt_get update -qq > /dev/null
apt_get install -y -qq git jq htop curl locales > /dev/null

# Generate locale to suppress perl locale warnings in LXCs
available_locales=$(locale -a 2>/dev/null || true)
if ! grep -q "en_US.utf8" <<< "$available_locales"; then
    sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
    locale-gen > /dev/null 2>&1
fi

echo "Tools ready"
