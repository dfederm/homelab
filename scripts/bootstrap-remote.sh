#!/bin/bash
# Bootstrap a remote machine into the homelab deployment system.
#
# Solves the chicken-and-egg problem: the machine needs the NAS mount to
# access the repo, but the SMB mount module is IN the repo. This script
# handles the initial mount, then hands off to setup.sh for everything else.
#
# Usage:
#   curl/scp this script to the machine, then run it:
#
#   SMB_SHARE="//192.168.1.5/homelab" \
#   SMB_MOUNT_POINT="/mnt/homelab" \
#   SMB_USERNAME="user" \
#   SMB_PASSWORD="pass" \
#   bash bootstrap-remote.sh [hostname]
#
# Arguments:
#   hostname  - (Optional) Machine hostname for env file lookup.
#               Defaults to $(hostname). Used to find <config_dir>/<hostname>.env.

set -euo pipefail

MACHINE_HOSTNAME="${1:-$(hostname)}"
SMB_SHARE="${SMB_SHARE:?SMB_SHARE must be set}"
SMB_MOUNT_POINT="${SMB_MOUNT_POINT:?SMB_MOUNT_POINT must be set}"
SMB_USERNAME="${SMB_USERNAME:?SMB_USERNAME must be set}"
SMB_PASSWORD="${SMB_PASSWORD:?SMB_PASSWORD must be set}"

echo "=== Bootstrap: $MACHINE_HOSTNAME ==="

# Install cifs-utils
echo "Installing cifs-utils..."
apt-get update -qq > /dev/null
apt-get install -y -qq cifs-utils > /dev/null

# Create mount point
mkdir -p "$SMB_MOUNT_POINT"

# Mount the NAS share (temporary — the configure-smb-mount module will persist it)
if ! mountpoint -q "$SMB_MOUNT_POINT"; then
    echo "Mounting $SMB_SHARE at $SMB_MOUNT_POINT..."
    mount -t cifs "$SMB_SHARE" "$SMB_MOUNT_POINT" \
        -o "username=${SMB_USERNAME},password=${SMB_PASSWORD},_netdev,nofail"
else
    echo "Already mounted"
fi

# Locate the repo and env file on the NAS
# Convention: <mount>/homelab/repo and <mount>/homelab/config/<hostname>.env
REPO_DIR="$SMB_MOUNT_POINT/homelab/repo"
CONFIG_DIR="$SMB_MOUNT_POINT/homelab/config"
ENV_FILE="$CONFIG_DIR/${MACHINE_HOSTNAME}.env"

if [ ! -d "$REPO_DIR" ]; then
    echo "ERROR: Repo not found at $REPO_DIR" >&2
    exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: Env file not found at $ENV_FILE" >&2
    echo "  Create $ENV_FILE on the NAS before running bootstrap." >&2
    exit 1
fi

# Hand off to setup.sh (source_env will create /etc/homelab.env symlink automatically)
echo "Running setup.sh..."
bash "$REPO_DIR/scripts/setup/setup.sh"

echo "=== Bootstrap complete ==="
