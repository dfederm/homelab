#!/bin/bash
# Module: Install common utility packages
# Idempotent — apt-get skips already installed packages.

set -euo pipefail

echo "Installing common tools..."
apt-get update -qq > /dev/null
apt-get install -y -qq git jq htop curl > /dev/null
echo "Tools ready"
