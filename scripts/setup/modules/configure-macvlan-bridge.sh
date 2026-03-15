#!/bin/bash
# Module: Configure macvlan bridge for host-to-container communication
# Idempotent — generates a systemd service, restarts only if changed.
#
# Docker's macvlan networking prevents the host from communicating with
# macvlan containers. This creates a bridge interface that routes traffic
# from the host to the macvlan container's IP.
#
# Env vars:
#   NETWORK_INTERFACE - Host network interface (e.g. eth0)
#   DOCKER_HOST_IP    - This machine's IP address (e.g. 192.168.1.6)
#   ADGUARDHOME_IP    - AdGuard Home's macvlan IP (e.g. 192.168.1.7)

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

validate_env NETWORK_INTERFACE DOCKER_HOST_IP ADGUARDHOME_IP

SERVICE_FILE="/etc/systemd/system/macvlan-bridge.service"
TEMP_FILE=$(mktemp)

cat > "$TEMP_FILE" <<EOF
[Unit]
Description=Macvlan bridge for host-to-macvlan container communication
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/sbin/ip link del macvlan-br
ExecStart=/sbin/ip link add macvlan-br link ${NETWORK_INTERFACE} type macvlan mode bridge
ExecStart=/sbin/ip addr add ${DOCKER_HOST_IP}/32 dev macvlan-br
ExecStart=/sbin/ip link set macvlan-br up
ExecStart=/sbin/ip route add ${ADGUARDHOME_IP}/32 dev macvlan-br
ExecStop=/sbin/ip link del macvlan-br

[Install]
WantedBy=multi-user.target
EOF

if [ -f "$SERVICE_FILE" ] && cmp -s "$TEMP_FILE" "$SERVICE_FILE"; then
    rm "$TEMP_FILE"
    echo "macvlan-bridge service unchanged"
else
    mv "$TEMP_FILE" "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable macvlan-bridge.service
    systemctl restart macvlan-bridge.service
    echo "macvlan-bridge service installed and started"
fi
