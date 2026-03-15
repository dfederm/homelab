#!/bin/bash
# Module: Install and configure Samba
# Idempotent — installs once, generates smb.conf from env vars, restarts only if changed.
#
# Env vars:
#   SHARE_ROOT      - Root path of the file share (e.g. /mnt/federshare)
#   HOMELAB_USERS   - Space-separated prefixes for user definitions
#   HOMELAB_GROUPS  - Space-separated prefixes for group definitions
#   SMB_ROOT_SHARE   - (Optional) Name for a root share exposing SHARE_ROOT (all users)
#   SMB_MEDIA_PATH  - (Optional) Path to media library; creates admin-only share
#   SMB_HOMELAB_PATH - (Optional) Path to homelab data; creates admin-only share
#
# The [global] section comes from nas/smb.conf.global in the repo.
# Share definitions are generated from user/group env vars.

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

: "${SHARE_ROOT:?SHARE_ROOT must be set}"
: "${HOMELAB_USERS:?HOMELAB_USERS must be set}"
: "${HOMELAB_GROUPS:?HOMELAB_GROUPS must be set}"

SMB_GLOBAL="$REPO_DIR/nas/smb.conf.global"
if [ ! -f "$SMB_GLOBAL" ]; then
    echo "ERROR: smb.conf.global not found at $SMB_GLOBAL" >&2
    exit 1
fi

# Install (idempotent — apt-get skips already installed)
apt-get update -qq > /dev/null
apt-get install -y -qq samba samba-common-bin acl > /dev/null

# Build user lists by group membership
adults=""
admins=""
all_users=""
for prefix in $HOMELAB_USERS; do
    validate_env "${prefix}_GROUPS"
    name="${prefix,,}"
    groups_var="${prefix}_GROUPS"
    groups="${!groups_var}"
    all_users="$all_users $name"
    if echo "$groups" | grep -qw "adults"; then
        adults="$adults $name"
    fi
    if echo "$groups" | grep -qw "admin"; then
        admins="$admins $name"
    fi
done
adults="${adults# }"
admins="${admins# }"
all_users="${all_users# }"

# Generate smb.conf
SMB_CONF=$(cat "$SMB_GLOBAL")

# Personal shares (only if no root share is configured)
if [ -z "${SMB_ROOT_SHARE:-}" ]; then
    for prefix in $HOMELAB_USERS; do
        name="${prefix,,}"
        SMB_CONF="$SMB_CONF

[$name]
   path = $SHARE_ROOT/$name
   valid users = $name $adults
   read only = no
   create mask = 0770
   directory mask = 0770"
    done
fi

# Shared folder shares (only if no root share is configured)
if [ -z "${SMB_ROOT_SHARE:-}" ]; then
    # Adults-only shared folder
    SMB_CONF="$SMB_CONF

[adults]
   path = $SHARE_ROOT/adults
   valid users = $adults
   read only = no
   create mask = 0770
   directory mask = 0770"

    # Family shared folder
    SMB_CONF="$SMB_CONF

[family]
   path = $SHARE_ROOT/family
   valid users = $all_users
   read only = no
   create mask = 0770
   directory mask = 0770"
fi

# Optional: Root share (browsable view of all user folders + shared dirs)
if [ -n "${SMB_ROOT_SHARE:-}" ]; then
    SMB_CONF="$SMB_CONF

[$SMB_ROOT_SHARE]
   path = $SHARE_ROOT
   valid users = $all_users
   read only = no
   create mask = 0770
   directory mask = 0770"
fi

# Optional: Media share (admin only — upload/manage, not consume)
if [ -n "${SMB_MEDIA_PATH:-}" ]; then
    chmod 755 "$SMB_MEDIA_PATH"
    SMB_CONF="$SMB_CONF

[media]
   path = $SMB_MEDIA_PATH
   valid users = $admins
   read only = no"
fi

# Optional: Homelab share (admin only)
if [ -n "${SMB_HOMELAB_PATH:-}" ]; then
    chmod 755 "$SMB_HOMELAB_PATH"

    # Config dir needs admin write access (env files edited via SMB)
    if [ -d "$SMB_HOMELAB_PATH/config" ]; then
        chown -R root:admin "$SMB_HOMELAB_PATH/config"
        chmod -R 775 "$SMB_HOMELAB_PATH/config"
    fi

    SMB_CONF="$SMB_CONF

[homelab]
   path = $SMB_HOMELAB_PATH
   valid users = $admins
   read only = no
   create mask = 0755
   directory mask = 0755"
fi

# Apply config (restart only if changed)
if [ "$SMB_CONF" != "$(cat /etc/samba/smb.conf 2>/dev/null)" ]; then
    echo "$SMB_CONF" > /etc/samba/smb.conf
    echo "Generated smb.conf with shares: $(echo "$all_users" | tr ' ' ', '), adults, family"
    systemctl restart smbd nmbd
    echo "Samba restarted"
else
    echo "smb.conf unchanged"
fi

# Always ensure Samba is enabled and running
systemctl enable smbd nmbd
systemctl start smbd nmbd
echo "Samba running"
