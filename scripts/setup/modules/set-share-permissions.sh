#!/bin/bash
# Module: Set POSIX ACLs on file share directories
# Idempotent — re-applies ownership and ACLs on top-level dirs only.
#
# Env vars:
#   SHARE_ROOT     - Root path of the file share (e.g. /mnt/federshare)
#   HOMELAB_USERS  - Space-separated prefixes for user definitions
#     Each prefix requires: _GROUPS (comma-separated group names)
#     Username is derived by lowercasing the prefix.
#
# Directory structure (under SHARE_ROOT):
#   <username>/  - Personal directory for each user
#   adults/      - Shared directory for the "adults" group
#   family/      - Shared directory for the "family" group
#
# Permission logic:
#   - All personal dirs: owner rwx, admin rwx
#   - Adult personal dirs: other adults r-x (read-only)
#   - Kid personal dirs: adults rwx (parental oversight)
#   - adults/ dir: adults group rwx
#   - family/ dir: family group rwx

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

: "${SHARE_ROOT:?SHARE_ROOT must be set}"
: "${HOMELAB_USERS:?HOMELAB_USERS must be set}"

echo "Setting share permissions on $SHARE_ROOT..."

# Ensure the share root is traversable (ZFS imports may have restrictive defaults)
chmod 755 "$SHARE_ROOT"

for prefix in $HOMELAB_USERS; do
    validate_env "${prefix}_GROUPS"

    name="${prefix,,}"
    groups_var="${prefix}_GROUPS"
    groups="${!groups_var}"
    dir="$SHARE_ROOT/$name"

    mkdir -p "$dir"
    chown "$name":"$name" "$dir"
    chmod 770 "$dir"

    # Admin gets full control on all personal dirs
    setfacl -m g:admin:rwx "$dir"
    setfacl -d -m g:admin:rwx "$dir"

    if echo "$groups" | grep -qw "adults"; then
        # Adult personal dir: other adults can only read
        setfacl -m g:adults:rx "$dir"
        setfacl -d -m g:adults:rx "$dir"
        echo "  $dir: owner=$name, admin=rwx, adults=r-x"
    else
        # Kid personal dir: adults get full access (parental oversight)
        setfacl -m g:adults:rwx "$dir"
        setfacl -d -m g:adults:rwx "$dir"
        echo "  $dir: owner=$name, admin=rwx, adults=rwx"
    fi
done

# Adults-only shared folder
mkdir -p "$SHARE_ROOT/adults"
chown root:adults "$SHARE_ROOT/adults"
chmod 770 "$SHARE_ROOT/adults"
setfacl -m g:admin:rwx "$SHARE_ROOT/adults"
setfacl -d -m g:admin:rwx "$SHARE_ROOT/adults"
setfacl -m g:adults:rwx "$SHARE_ROOT/adults"
setfacl -d -m g:adults:rwx "$SHARE_ROOT/adults"
echo "  $SHARE_ROOT/adults: group=adults, rwx"

# Family shared folder
mkdir -p "$SHARE_ROOT/family"
chown root:family "$SHARE_ROOT/family"
chmod 770 "$SHARE_ROOT/family"
setfacl -m g:admin:rwx "$SHARE_ROOT/family"
setfacl -d -m g:admin:rwx "$SHARE_ROOT/family"
setfacl -m g:family:rwx "$SHARE_ROOT/family"
setfacl -d -m g:family:rwx "$SHARE_ROOT/family"
echo "  $SHARE_ROOT/family: group=family, rwx"

echo "Permissions set"
