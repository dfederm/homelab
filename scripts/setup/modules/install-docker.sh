#!/bin/bash
# Module: Install Docker Engine (official method)
# Idempotent — skips installation if already present, always ensures service is running.

set -euo pipefail

if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    apt-get update -qq > /dev/null
    apt-get install -y -qq ca-certificates curl gnupg > /dev/null
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq > /dev/null
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null
else
    echo "Docker already installed"
fi

# Always ensure Docker is enabled and running
systemctl enable docker
systemctl start docker
echo "Docker ready"
