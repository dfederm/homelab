#!/bin/bash
# Module: Install and configure Samba
# Idempotent — installs once, generates smb.conf from env vars, restarts only if changed.
#
# Env vars:
#   SHARE_ROOT      - Root path of the file share (e.g. /mnt/share)
#   HOMELAB_USERS   - Space-separated prefixes for user definitions
#                     (a prefix with _SERVICE=1 is a service account: no personal
#                      share, and a valid user only of the admin shares it needs,
#                      not the family shares)
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

# Build user lists by group membership.
# Admin membership is group-based and applies to everyone, so a service account
# in the admin group is a valid user of the admin infrastructure shares
# (homelab/media, via $admins). Service accounts (_SERVICE=1) are otherwise NOT
# valid users of any non-admin share: they're left out of $all_users (the
# root/federshare share and [family]) and $adults (the [adults] share and other
# users' personal shares), so a repo-sync credential can't reach family data over SMB.
adults=""
admins=""
all_users=""
for prefix in $HOMELAB_USERS; do
    validate_env "${prefix}_GROUPS"
    name="${prefix,,}"
    groups_var="${prefix}_GROUPS"
    groups="${!groups_var}"
    service_var="${prefix}_SERVICE"

    if echo "$groups" | grep -qw "admin"; then
        admins="$admins $name"
    fi

    # Service accounts are valid users only of the admin shares above.
    [ "${!service_var:-0}" = "1" ] && continue

    all_users="$all_users $name"
    if echo "$groups" | grep -qw "adults"; then
        adults="$adults $name"
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
        # Service accounts get no personal share (see set-share-permissions.sh)
        service_var="${prefix}_SERVICE"
        [ "${!service_var:-0}" = "1" ] && continue
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
    # Top-level only: admin group needs write so members of the admin group
    # can manage the library via SMB. Default ACL seeds inheritance for newly
    # created content at this level.
    chown root:admin "$SMB_MEDIA_PATH"
    chmod 770 "$SMB_MEDIA_PATH"
    setfacl -m g:admin:rwx "$SMB_MEDIA_PATH"
    setfacl -d -m g:admin:rwx "$SMB_MEDIA_PATH"
    SMB_CONF="$SMB_CONF

[media]
   path = $SMB_MEDIA_PATH
   valid users = $admins
   read only = no
   create mask = 0770
   directory mask = 0770"
fi

# Optional: Homelab share (admin only)
if [ -n "${SMB_HOMELAB_PATH:-}" ]; then
    chmod 755 "$SMB_HOMELAB_PATH"

    # Config dir needs admin write access (env files edited via SMB)
    if [ -d "$SMB_HOMELAB_PATH/config" ]; then
        chown -R root:admin "$SMB_HOMELAB_PATH/config"
        chmod -R 775 "$SMB_HOMELAB_PATH/config"
    fi

    # Backup dir needs admin write access (e.g. Home Assistant backups via SMB)
    mkdir -p "$SMB_HOMELAB_PATH/backup"
    chown root:admin "$SMB_HOMELAB_PATH/backup"
    chmod 775 "$SMB_HOMELAB_PATH/backup"

    # Appdata dir needs admin write access (remote machines create service dirs via SMB)
    mkdir -p "$SMB_HOMELAB_PATH/appdata"
    chown root:admin "$SMB_HOMELAB_PATH/appdata"
    chmod 775 "$SMB_HOMELAB_PATH/appdata"

    # Images dir needs admin write access (VM images / ISOs deposited via SMB).
    # A default ACL grants the admin group rwx on new content so images added over
    # SMB inherit admin-write (mirrors the media share; the one-time recursive fix
    # for pre-existing root-owned images lives in scripts/repair-share-acls.sh).
    mkdir -p "$SMB_HOMELAB_PATH/images"
    chown root:admin "$SMB_HOMELAB_PATH/images"
    chmod 775 "$SMB_HOMELAB_PATH/images"
    setfacl -d -m g:admin:rwx "$SMB_HOMELAB_PATH/images"

    # Admin-editable config dirs (SMB_ADMIN_CONFIG_DIRS): a space-separated list of
    # appdata config dirs that a service writes but an admin also legitimately edits
    # over SMB. Each is normalized to one uniform, service-agnostic policy — a
    # deliberate, scoped exception to "appdata is owned by its writing service",
    # justified because these hold hand-edited configuration, not opaque service data.
    # The dir becomes root:admin 2770 (setgid so new files inherit the admin group)
    # with a default ACL granting the admin group rwx, and files already inside are
    # made group-writable and non-world-readable (g+rw,o= — keeps any secrets out of
    # "other"). This keeps BOTH the writing container (root) and the admin group able
    # to write. Where a service preserves an existing file's owner+mode when it
    # rewrites it (e.g. rclone rewriting rclone.conf to rotate OAuth refresh tokens),
    # the admin grant is durable across those rewrites; a file the service creates
    # from scratch may land service-owned until the next run of this module
    # re-normalizes it. A listed dir not yet present (service not deployed) is skipped.
    for admin_cfg_dir in ${SMB_ADMIN_CONFIG_DIRS:-}; do
        [ -d "$admin_cfg_dir" ] || continue
        chown root:admin "$admin_cfg_dir"
        chmod 2770 "$admin_cfg_dir"
        setfacl -m g:admin:rwx -m m::rwx "$admin_cfg_dir"
        setfacl -d -m g:admin:rwx -m m::rwx "$admin_cfg_dir"
        find "$admin_cfg_dir" -maxdepth 1 -type f -exec chown root:admin {} + -exec chmod g+rw,o= {} +
        echo "  $admin_cfg_dir: root:admin 2770, default ACL admin:rwx (contained files g+rw,o=)"
    done

    # Repo dir needs admin read access (remote machines, e.g. a Raspberry Pi, source setup.sh
    # from the SMB-mounted repo via the svc service account, which is in the admin group).
    # Use capital X so non-executable files don't gain spurious execute bits — git tracks file modes.
    if [ -d "$SMB_HOMELAB_PATH/repo" ]; then
        chown -R root:admin "$SMB_HOMELAB_PATH/repo"
        chmod -R u=rwX,g=rwX,o=rX "$SMB_HOMELAB_PATH/repo"
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
