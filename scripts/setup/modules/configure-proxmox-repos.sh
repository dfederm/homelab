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
SIGNING_KEY="/etc/apt/trusted.gpg.d/proxmox-release-$CODENAME.gpg"

if [ ! -f "$SIGNING_KEY" ]; then
    echo "Error: Signing key not found at $SIGNING_KEY"
    exit 1
fi

# Remove any enterprise repo files (both legacy .list and modern .sources formats)
for f in /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.sources \
         /etc/apt/sources.list.d/ceph.list /etc/apt/sources.list.d/ceph.sources; do
    if [ -f "$f" ]; then
        rm -f "$f"
        CHANGED=true
    fi
done

# Ensure no-subscription repo is configured with signed-by
NSR="/etc/apt/sources.list.d/pve-no-subscription.list"
NSR_SOURCES="/etc/apt/sources.list.d/pve-no-subscription.sources"
TEMP_FILE=$(mktemp)
trap 'rm -f "$TEMP_FILE"' EXIT

# Use DEB822 format if already using .sources, otherwise legacy .list
if [ -f "$NSR_SOURCES" ] || { [ ! -f "$NSR" ] && ls /etc/apt/sources.list.d/*.sources &> /dev/null; }; then
    TARGET="$NSR_SOURCES"
    cat > "$TEMP_FILE" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $CODENAME
Components: pve-no-subscription
Signed-By: $SIGNING_KEY
EOF
    # Clean up legacy format if present
    if [ -f "$NSR" ]; then
        rm -f "$NSR"
        CHANGED=true
    fi
else
    TARGET="$NSR"
    echo "deb [signed-by=$SIGNING_KEY] http://download.proxmox.com/debian/pve $CODENAME pve-no-subscription" > "$TEMP_FILE"
fi

if [ -f "$TARGET" ] && cmp -s "$TEMP_FILE" "$TARGET"; then
    rm "$TEMP_FILE"
else
    mv "$TEMP_FILE" "$TARGET"
    CHANGED=true
fi

if [ "$CHANGED" = true ]; then
    echo "Proxmox repos configured"
else
    echo "Proxmox repos already configured"
fi
