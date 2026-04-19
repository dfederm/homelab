#!/bin/bash
# Module: Mount NAS share via CIFS
# Idempotent — installs cifs-utils, creates credentials file, adds fstab entry, mounts share.
#
# Env vars:
#   SMB_SHARE            - UNC path to the NAS share (e.g. //192.168.1.5/homelab)
#   SMB_MOUNT_POINT      - Local mount point (e.g. /mnt/homelab)
#   SMB_CREDENTIALS_FILE - Path to credentials file (e.g. /etc/smbcredentials)
#   SMB_USERNAME         - Username for the credentials file
#   SMB_PASSWORD         - Password for the credentials file

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

validate_env SMB_SHARE SMB_MOUNT_POINT SMB_CREDENTIALS_FILE SMB_USERNAME SMB_PASSWORD

echo "Configuring SMB mount..."

# Install cifs-utils (idempotent — apt-get skips already installed)
apt-get install -y -qq cifs-utils > /dev/null

# Create/update credentials file
DESIRED_CREDS="username=${SMB_USERNAME}
password=${SMB_PASSWORD}"

if [ ! -f "$SMB_CREDENTIALS_FILE" ] || [ "$DESIRED_CREDS" != "$(cat "$SMB_CREDENTIALS_FILE")" ]; then
    echo "$DESIRED_CREDS" > "$SMB_CREDENTIALS_FILE"
    chmod 600 "$SMB_CREDENTIALS_FILE"
    echo "Credentials file updated: $SMB_CREDENTIALS_FILE"
else
    echo "Credentials file unchanged"
fi

# Create mount point
mkdir -p "$SMB_MOUNT_POINT"

# Add/update fstab entry
FSTAB_ENTRY="${SMB_SHARE} ${SMB_MOUNT_POINT} cifs credentials=${SMB_CREDENTIALS_FILE},iocharset=utf8,_netdev,nofail 0 0"
if grep -qF "$SMB_SHARE" /etc/fstab; then
    # Replace existing entry for this share (mount point or options may have changed)
    sed -i "\|${SMB_SHARE}|c\\${FSTAB_ENTRY}" /etc/fstab
    echo "Updated fstab entry"
else
    echo "$FSTAB_ENTRY" >> /etc/fstab
    echo "Added fstab entry"
fi

# Mount if not already mounted
if ! mountpoint -q "$SMB_MOUNT_POINT"; then
    mount "$SMB_MOUNT_POINT"
    echo "Mounted $SMB_SHARE at $SMB_MOUNT_POINT"
else
    echo "Already mounted"
fi

echo "SMB mount ready"
