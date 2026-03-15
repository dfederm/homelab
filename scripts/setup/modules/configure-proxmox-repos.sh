#!/bin/bash
# Module: Configure Proxmox apt repositories
# Idempotent — only runs on Proxmox hosts (detected by pveversion).
#
# Proxmox ships with enterprise repos that require a paid subscription.
# This replaces them with the free no-subscription community repos.

set -euo pipefail

if ! command -v pveversion &> /dev/null; then
    echo "Not a Proxmox host, skipping"
    exit 0
fi

CHANGED=false
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

# Remove any enterprise repo files (both legacy .list and modern .sources formats)
for f in /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.sources \
         /etc/apt/sources.list.d/ceph.list /etc/apt/sources.list.d/ceph.sources; do
    if [ -f "$f" ]; then
        rm -f "$f"
        CHANGED=true
    fi
done

# Add no-subscription repo if missing
NSR="/etc/apt/sources.list.d/pve-no-subscription.list"
NSR_SOURCES="/etc/apt/sources.list.d/pve-no-subscription.sources"
if [ ! -f "$NSR" ] && [ ! -f "$NSR_SOURCES" ]; then
    # Use DEB822 format if the system already uses .sources files, otherwise legacy .list
    if ls /etc/apt/sources.list.d/*.sources &> /dev/null; then
        cat > "$NSR_SOURCES" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $CODENAME
Components: pve-no-subscription
EOF
    else
        echo "deb http://download.proxmox.com/debian/pve $CODENAME pve-no-subscription" > "$NSR"
    fi
    CHANGED=true
fi

if [ "$CHANGED" = true ]; then
    echo "Proxmox repos configured"
else
    echo "Proxmox repos already configured"
fi
