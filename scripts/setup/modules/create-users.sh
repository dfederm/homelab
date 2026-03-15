#!/bin/bash
# Module: Create shared homelab users and groups
# Idempotent — skips existing users/groups, updates supplementary groups.
# UIDs/GIDs must match across all machines for consistent file ownership.
#
# Env vars:
#   HOMELAB_GROUPS - Space-separated prefixes for role groups
#     Each prefix requires: _GID
#     Group name is derived by lowercasing the prefix.
#     e.g. HOMELAB_GROUPS="ADULTS KIDS" with ADULTS_GID=1100
#   HOMELAB_USERS  - Space-separated prefixes for user definitions
#     Each prefix requires: _UID, _GROUPS (comma-separated group names)
#     Username is derived by lowercasing the prefix.
#     A primary group with matching name and GID is created automatically.
#     e.g. HOMELAB_USERS="ALICE BOB" with ALICE_UID=1001, ALICE_GROUPS="adults,family"

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

: "${HOMELAB_GROUPS:?HOMELAB_GROUPS must be set}"
: "${HOMELAB_USERS:?HOMELAB_USERS must be set}"

echo "Ensuring users and groups exist..."

# Create role groups
for prefix in $HOMELAB_GROUPS; do
    validate_env "${prefix}_GID"

    name="${prefix,,}"
    gid_var="${prefix}_GID"
    gid="${!gid_var}"

    existing_gid=$(getent group "$name" 2>/dev/null | cut -d: -f3) || true
    if [ -z "$existing_gid" ]; then
        groupadd -g "$gid" "$name"
        echo "  Created group $name (GID $gid)"
    elif [ "$existing_gid" != "$gid" ]; then
        echo "ERROR: Group $name exists with GID $existing_gid, expected $gid" >&2
        exit 1
    fi
done

# Create per-user primary groups and users
for prefix in $HOMELAB_USERS; do
    validate_env "${prefix}_UID" "${prefix}_GROUPS"

    name="${prefix,,}"
    uid_var="${prefix}_UID"
    uid="${!uid_var}"
    groups_var="${prefix}_GROUPS"
    groups="${!groups_var}"

    # Primary group (same name and GID as user)
    existing_gid=$(getent group "$name" 2>/dev/null | cut -d: -f3) || true
    if [ -z "$existing_gid" ]; then
        groupadd -g "$uid" "$name"
    elif [ "$existing_gid" != "$uid" ]; then
        echo "ERROR: Primary group $name exists with GID $existing_gid, expected $uid" >&2
        exit 1
    fi

    # Create or update user (no home dir, no login shell)
    existing_uid=$(id -u "$name" 2>/dev/null) || true
    if [ -z "$existing_uid" ]; then
        useradd -u "$uid" -g "$uid" -G "$groups" -M -s /usr/sbin/nologin "$name"
        echo "  Created user $name (UID $uid)"
    elif [ "$existing_uid" != "$uid" ]; then
        echo "ERROR: User $name exists with UID $existing_uid, expected $uid" >&2
        exit 1
    else
        # Ensure primary and supplementary groups are current
        usermod -g "$uid" -G "$groups" "$name"
    fi
done

echo "Users and groups ready"
