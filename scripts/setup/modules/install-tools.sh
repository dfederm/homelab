#!/bin/bash
# Module: Install common utility packages
# Idempotent — apt-get skips already installed packages.

set -euo pipefail

echo "Installing common tools..."
apt-get update -qq > /dev/null
apt-get install -y -qq git jq htop curl locales > /dev/null

# Generate locale to suppress perl locale warnings in LXCs
if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
    sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
    locale-gen > /dev/null 2>&1
fi

echo "Tools ready"
