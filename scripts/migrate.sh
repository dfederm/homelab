#!/bin/bash
# migrate.sh — One-shot migration script for fresh Proxmox host
#
# Imports a ZFS pool from TrueNAS, fixes properties, runs setup scripts,
# deploys services, restores Docker volumes, and prints remaining manual steps.
#
# Usage:
#   bash /path/to/migrate.sh <pool-name>
#
# Example:
#   bash /tank/homelab/repo/scripts/migrate.sh tank
#
# Prerequisites:
#   - Proxmox VE installed on boot SSD
#   - ZFS pool NOT yet imported (this script handles it)
#   - Docker volume backups already created (backup-volumes.sh on old host)
#   - HAOS backup already created (via HA UI on old host)

set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <pool-name>" >&2
    echo "  e.g. $0 Aether" >&2
    exit 1
fi

POOL="$1"
REPO_DIR="/$POOL/homelab/repo"
CONFIG_DIR="/$POOL/homelab/config"

log() {
    echo ""
    echo "==========================================="
    echo "  $*"
    echo "==========================================="
    echo ""
}

# --------------------------------------------------
log "Step 1: Import ZFS pool"
# --------------------------------------------------

if zpool list "$POOL" &>/dev/null; then
    echo "Pool $POOL already imported"
else
    zpool import -f "$POOL"
    echo "Pool $POOL imported"
fi

# Verify critical paths exist
for path in "$REPO_DIR" "$CONFIG_DIR"; do
    if [ ! -e "$path" ]; then
        echo "ERROR: Expected path not found: $path" >&2
        echo "Is the ZFS pool imported correctly?" >&2
        exit 1
    fi
done

# Find the Proxmox host env file (matches hostname or is the only .env without a matching LXC)
ENV_FILE="$CONFIG_DIR/$(hostname).env"
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: No env file found for hostname '$(hostname)' at $ENV_FILE" >&2
    echo "  Available: $(ls "$CONFIG_DIR"/*.env 2>/dev/null | xargs -I{} basename {})" >&2
    exit 1
fi

# Install git on Proxmox host (not included by default)
if ! command -v git &>/dev/null; then
    apt-get update -qq > /dev/null
    apt-get install -y -qq git > /dev/null
    echo "Installed git"
fi
git config --global --add safe.directory "$REPO_DIR" 2>/dev/null || true

# Source env files for config values
set -a
if [ -f "$CONFIG_DIR/common.env" ]; then
    source "$CONFIG_DIR/common.env"
fi
source "$ENV_FILE"
set +a
source "$REPO_DIR/scripts/lib.sh"

# --------------------------------------------------
log "Step 2: Stage LXC template"
# --------------------------------------------------

TEMPLATE_CACHE="/var/lib/vz/template/cache"

mkdir -p "$TEMPLATE_CACHE"
if ls "$TEMPLATE_CACHE"/debian-*-standard_*_amd64.tar.zst &>/dev/null; then
    echo "Debian LXC template already in cache"
else
    # Look for a pre-downloaded template on ZFS
    TEMPLATE_SRC=$(find "/$POOL/homelab/images" -name 'debian-*-standard_*_amd64.tar.zst' 2>/dev/null | head -1)
    if [ -n "$TEMPLATE_SRC" ]; then
        cp "$TEMPLATE_SRC" "$TEMPLATE_CACHE/"
        echo "Copied Debian LXC template from $TEMPLATE_SRC"
    else
        echo "No pre-staged template found; create-lxcs will attempt to download."
        echo "If download.proxmox.com is blocked, place a Debian template at:"
        echo "  /$POOL/homelab/images/debian-12-standard_*.tar.zst"
    fi
fi

# --------------------------------------------------
log "Step 3: Fix ZFS properties for Linux compatibility"
# --------------------------------------------------

# Discover datasets from LXC mount points (avoids hardcoding dataset names)
datasets=""
for prefix in $HOMELAB_LXCS; do
    i=0
    while true; do
        mp_var="${prefix}_MP${i}"
        mp_val="${!mp_var:-}"
        [ -z "$mp_val" ] && break
        # Extract the ZFS path (before the comma): e.g. "/Aether/homelab" from "/Aether/homelab,mp=/mnt/homelab"
        zfs_path="${mp_val%%,*}"
        ds="${zfs_path#/}"
        if ! echo "$datasets" | grep -qw "$ds"; then
            datasets="$datasets $ds"
        fi
        i=$((i + 1))
    done
done

for ds in $datasets; do
    if ! zfs list "$ds" &>/dev/null; then
        echo "  Dataset $ds not found, skipping"
        continue
    fi

    # acltype=posixacl: required for setfacl/getfacl
    current=$(zfs get -H -o value acltype "$ds")
    if [ "$current" != "posixacl" ]; then
        zfs set acltype=posixacl "$ds"
        echo "  $ds: acltype changed from $current to posixacl"
    fi

    # aclmode=passthrough: required for chmod to work when ACLs exist
    # TrueNAS sets aclmode=restricted which blocks permission changes
    current=$(zfs get -H -o value aclmode "$ds")
    if [ "$current" != "passthrough" ]; then
        zfs set aclmode=passthrough "$ds"
        echo "  $ds: aclmode changed from $current to passthrough"
    fi

    # xattr=sa: required for POSIX ACL storage (TrueNAS uses xattr=on)
    current=$(zfs get -H -o value xattr "$ds")
    if [ "$current" != "sa" ]; then
        zfs set xattr=sa "$ds"
        echo "  $ds: xattr changed from $current to sa"
    fi

    echo "  $ds: OK"
done

# --------------------------------------------------
log "Step 4: Run setup (cascading bootstrap)"
# --------------------------------------------------

echo "This creates the Proxmox host config, LXC containers,"
echo "NAS LXC, and Home Assistant VM — all in one shot."
echo ""

bash "$REPO_DIR/scripts/setup/setup.sh" "$ENV_FILE"

# --------------------------------------------------
log "Step 5: Fix file ownership (TrueNAS UID remapping)"
# --------------------------------------------------

# Fix each ZFS dataset's base directory permissions
for ds in $datasets; do
    dir="/$ds"
    if [ -d "$dir" ]; then
        chmod 755 "$dir"
        echo "  $dir: 755"
    fi
done

# Homelab infrastructure: ensure root ownership and 755 throughout
echo "Fixing homelab infrastructure permissions..."
chown -R root:root "/$POOL/homelab"
chmod -R u=rwX,g=rX,o=rX "/$POOL/homelab"

# Config dir needs admin group write access (env files edited via SMB)
chown -R "root:${ADMIN_GID}" "/$POOL/homelab/config"
chmod -R 775 "/$POOL/homelab/config"

# Media: root-owned, world-readable
if [ -d "/$POOL/media" ]; then
    echo "Fixing media permissions..."
    chown -R root:root "/$POOL/media"
    chmod -R u=rwX,g=rX,o=rX "/$POOL/media"
fi

# User data: recursive chown from TrueNAS UIDs to new UIDs
echo "Fixing user data ownership (this may take a few minutes)..."
for prefix in $HOMELAB_USERS; do
    validate_env "${prefix}_UID"
    name="${prefix,,}"
    uid_var="${prefix}_UID"
    uid="${!uid_var}"
    dir="/$POOL/federshare/$name"

    if [ ! -d "$dir" ]; then
        continue
    fi

    echo "  $dir: chown $uid:$uid..."
    chown -R "$uid":"$uid" "$dir"
done

echo "Ownership fix complete"

# --------------------------------------------------
log "Step 6: Deploy Docker services"
# --------------------------------------------------

pct exec "$DOCKER_LXC_VMID" -- bash /mnt/homelab/repo/scripts/run-all-services.sh

# --------------------------------------------------
log "Step 7: Restore Docker volumes from backup"
# --------------------------------------------------

# Stop services so volumes can be safely overwritten
echo "Stopping services for volume restore..."
pct exec "$DOCKER_LXC_VMID" -- bash -c 'cd /mnt/homelab/repo && for svc in services/*/; do docker compose -f "$svc/docker-compose.yml" down 2>/dev/null; done'

pct exec "$DOCKER_LXC_VMID" -- bash /mnt/homelab/repo/scripts/backup/restore-volumes.sh

# Restart services with restored data
echo "Restarting services..."
pct exec "$DOCKER_LXC_VMID" -- bash /mnt/homelab/repo/scripts/run-all-services.sh

# --------------------------------------------------
log "Migration complete!"
# --------------------------------------------------

echo "Remaining manual steps:"
echo ""
echo "1. Set Samba passwords (run each, enter password when prompted):"
for prefix in $HOMELAB_USERS; do
    name="${prefix,,}"
    echo "   pct exec $NAS_LXC_VMID -- smbpasswd -a $name"
done
echo ""
echo "2. Restore Home Assistant from backup:"
# Find the HAOS VM IP from env vars
haos_ip=""
for prefix in $HOMELAB_VMS; do
    ip_var="${prefix}_IP"
    if [ -n "${!ip_var:-}" ]; then
        haos_ip="${!ip_var}"
        break
    fi
done
if [ -n "$haos_ip" ]; then
    echo "   Open http://$haos_ip:8123 in your browser"
else
    echo "   Open the Home Assistant VM console in Proxmox to find its IP"
fi
echo "   Follow the restore-from-backup flow in the HA UI"
echo ""
echo "3. Verify services, SMB shares, and SSH access"
echo ""
echo "4. Clean up (after everything is verified):"
echo "   - Remove migration scripts from the repo"
echo "   - Delete the migration-tools branch"
