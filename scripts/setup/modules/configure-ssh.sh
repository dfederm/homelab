#!/bin/bash
# Module: Configure SSH with key-based authentication
# Idempotent — installs openssh-server, hardens config, deploys authorized keys.
#
# Authorized keys file resolution (first match wins):
#   1. SSH_AUTHORIZED_KEYS_FILE env var (explicit path)
#   2. <config_dir>/authorized_keys  (next to machine .env files)
#
# If no authorized keys file is found, SSH is hardened but key deployment is skipped.

set -euo pipefail

echo "Configuring SSH..."

apt-get install -y -qq openssh-server > /dev/null

# Harden SSH via drop-in config (Debian 12+ includes sshd_config.d/*.conf by default)
cat > /etc/ssh/sshd_config.d/99-homelab.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
EOF

# Resolve authorized keys file
# ENV_FILE may be /etc/homelab.env (a symlink); resolve to real path for dirname
KEYS_FILE="${SSH_AUTHORIZED_KEYS_FILE:-}"
if [ -z "$KEYS_FILE" ] && [ -n "${ENV_FILE:-}" ]; then
    KEYS_FILE="$(dirname "$(readlink -f "$ENV_FILE")")/authorized_keys"
fi

if [ -n "$KEYS_FILE" ] && [ -f "$KEYS_FILE" ]; then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    # Strip Windows carriage returns — file lives on SMB share and may be edited from Windows
    sed 's/\r$//' "$KEYS_FILE" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    echo "Authorized keys deployed from $KEYS_FILE"
else
    echo "WARNING: No authorized keys file found — SSH is key-only but no keys deployed"
    [ -n "$KEYS_FILE" ] && echo "  Expected: $KEYS_FILE"
fi

systemctl restart ssh
echo "SSH ready"
