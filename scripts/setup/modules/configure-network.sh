#!/bin/bash
# Module: Pin this machine to a static IPv4 address (NetworkManager)
# Idempotent — reconciles the active connection's IPv4 config; only changes it
# when the desired address/gateway/DNS/method differ from the current values.
#
# Targets the NetworkManager connection currently carrying the default route
# (auto-detected), so it works whether the machine is on Ethernet or WiFi and
# does not depend on a hardcoded interface name. On WiFi it edits the existing
# connection in place, so the WiFi credentials never have to leave the machine.
#
# Applying a new address to the connection you are connected THROUGH would drop
# the running SSH session and any CIFS mount that setup.sh is executing from, so
# this module only persists the config — it does NOT reactivate the connection.
# The change takes effect on the next reboot (or a manual `nmcli connection up`).
# A steady-state run where the config already matches is a silent no-op.
#
# Env vars:
#   STATIC_IP         - Desired IPv4 address (e.g. 192.168.1.4)
#   NETWORK_ROUTER_IP - Default gateway (e.g. 192.168.1.1)
#   NETWORK_PREFIX    - Subnet prefix length (e.g. 24)
#   STATIC_DNS        - Optional. DNS servers, comma- or space-separated.
#                       Defaults to NETWORK_ROUTER_IP.

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

validate_env STATIC_IP NETWORK_ROUTER_IP NETWORK_PREFIX

echo "Configuring static IP..."

# DNS defaults to the gateway; normalize to the comma list nmcli stores (accept
# comma- or space-separated input, collapse repeats, trim stray separators).
STATIC_DNS="${STATIC_DNS:-$NETWORK_ROUTER_IP}"
DESIRED_DNS=$(echo "$STATIC_DNS" | tr ',' ' ' | xargs | tr ' ' ',')

# Identify the connection on the interface that owns the default route.
PRIMARY_IFACE=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
if [ -z "$PRIMARY_IFACE" ]; then
    echo "ERROR: no default-route interface found; cannot pin static IP" >&2
    exit 1
fi

CONN=$(nmcli -g GENERAL.CONNECTION device show "$PRIMARY_IFACE" 2>/dev/null || true)
if [ -z "$CONN" ]; then
    echo "ERROR: no NetworkManager connection active on $PRIMARY_IFACE" >&2
    exit 1
fi

DESIRED_ADDR="${STATIC_IP}/${NETWORK_PREFIX}"

CUR_METHOD=$(nmcli -g ipv4.method connection show "$CONN")
CUR_ADDR=$(nmcli -g ipv4.addresses connection show "$CONN")
CUR_GW=$(nmcli -g ipv4.gateway connection show "$CONN")
CUR_DNS=$(nmcli -g ipv4.dns connection show "$CONN")

if [ "$CUR_METHOD" = "manual" ] \
    && [ "$CUR_ADDR" = "$DESIRED_ADDR" ] \
    && [ "$CUR_GW" = "$NETWORK_ROUTER_IP" ] \
    && [ "$CUR_DNS" = "$DESIRED_DNS" ]; then
    echo "Static IP already configured ($DESIRED_ADDR on $CONN)"
    exit 0
fi

nmcli connection modify "$CONN" \
    ipv4.method manual \
    ipv4.addresses "$DESIRED_ADDR" \
    ipv4.gateway "$NETWORK_ROUTER_IP" \
    ipv4.dns "$DESIRED_DNS"

echo "Static IP persisted: $DESIRED_ADDR (gw $NETWORK_ROUTER_IP, dns $DESIRED_DNS) on $CONN"
echo "Reboot to apply (or run: nmcli connection up \"$CONN\") — this drops the current"
echo "connection if you are connected over $PRIMARY_IFACE."
