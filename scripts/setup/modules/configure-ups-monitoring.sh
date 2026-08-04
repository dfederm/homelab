#!/bin/bash
# Module: Configure NUT UPS monitoring (Proxmox host)
# Idempotent - installs NUT, reconciles its server/driver configuration, and
# installs a read-only health check with shared Shoutrrr alerting.
#
# Required env vars:
#   NUT_UPS_NAME        - NUT device name exposed to clients
#   NUT_LISTEN_ADDRESS  - LAN address on which upsd accepts monitoring clients
#   REPO_DIR            - Repo root (set by setup.sh)
#
# Optional env vars:
#   NUT_UPS_DESCRIPTION
#   UPS_LOAD_WARNING_PERCENT
#   UPS_ON_BATTERY_ALERT_DELAY_SECONDS
#   UPS_COMM_FAILURE_ALERT_DELAY_SECONDS
#   UPS_ALERT_REPEAT_HOURS
#   HOMELAB_ALERT_SHOUTRRR_URL

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

validate_env NUT_UPS_NAME NUT_LISTEN_ADDRESS REPO_DIR

if ! [[ "$NUT_UPS_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: NUT_UPS_NAME may contain only letters, numbers, dots, underscores, and hyphens" >&2
    exit 1
fi
if ! [[ "$NUT_LISTEN_ADDRESS" =~ ^[A-Za-z0-9.:_-]+$ ]]; then
    echo "ERROR: NUT_LISTEN_ADDRESS must be an IP address or hostname without whitespace" >&2
    exit 1
fi
if [[ "${NUT_UPS_DESCRIPTION:-}" == *$'\n'* ]] || [[ "${NUT_UPS_DESCRIPTION:-}" == *\"* ]]; then
    echo "ERROR: NUT_UPS_DESCRIPTION may not contain quotes or newlines" >&2
    exit 1
fi

CHECK_SCRIPT="$REPO_DIR/scripts/ups-status-check.sh"
NUT_CONFIG_DIR="${NUT_CONFIG_DIR:-/etc/nut}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
SERVICE_FILE="$SYSTEMD_UNIT_DIR/homelab-ups-check.service"
TIMER_FILE="$SYSTEMD_UNIT_DIR/homelab-ups-check.timer"

if [ ! -f "$CHECK_SCRIPT" ]; then
    echo "ERROR: check script not found: $CHECK_SCRIPT" >&2
    exit 1
fi

echo "Installing NUT..."
apt_get update -qq >/dev/null
apt_get install -y -qq nut-client nut-server >/dev/null

# The package installs USB permission rules, but its post-install trigger is
# gated on a legacy /etc/init.d/udev check that is absent on current Proxmox.
# Reprocess already-connected USB devices so the NUT group can open the UPS
# without requiring a physical unplug/replug.
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb --action=change
udevadm settle

if ! ensure_shoutrrr; then
    echo "  WARNING: shoutrrr CLI unavailable; UPS alerts log to syslog only until it installs."
fi

changed=0
mkdir -p "$NUT_CONFIG_DIR" "$SYSTEMD_UNIT_DIR"

install_config() {
    local temp_file="$1"
    local destination="$2"
    local mode="$3"

    if [ -f "$destination" ] && cmp -s "$temp_file" "$destination"; then
        rm -f "$temp_file"
        echo "$(basename "$destination") unchanged"
        return 0
    fi

    install -o root -g nut -m "$mode" "$temp_file" "$destination"
    rm -f "$temp_file"
    changed=1
    echo "$(basename "$destination") updated"
}

temp_file=$(mktemp)
cat > "$temp_file" <<EOF
MODE=netserver
EOF
install_config "$temp_file" "$NUT_CONFIG_DIR/nut.conf" 640

temp_file=$(mktemp)
{
    cat <<EOF
[${NUT_UPS_NAME}]
    driver = usbhid-ups
    port = auto
EOF
    if [ -n "${NUT_UPS_DESCRIPTION:-}" ]; then
        echo "    desc = \"${NUT_UPS_DESCRIPTION}\""
    fi
} > "$temp_file"
install_config "$temp_file" "$NUT_CONFIG_DIR/ups.conf" 640

temp_file=$(mktemp)
cat > "$temp_file" <<EOF
LISTEN 127.0.0.1 3493
EOF
if [ "$NUT_LISTEN_ADDRESS" != "127.0.0.1" ]; then
    echo "LISTEN ${NUT_LISTEN_ADDRESS} 3493" >> "$temp_file"
fi
install_config "$temp_file" "$NUT_CONFIG_DIR/upsd.conf" 640

# Debian's enabled nut.target wants nut-monitor regardless of whether that unit
# is merely disabled. Mask it so the shutdown controller stays off after reboot.
monitor_state=$(systemctl is-enabled nut-monitor.service 2>/dev/null || true)
if [ "$monitor_state" != "masked" ]; then
    systemctl mask --now nut-monitor.service >/dev/null
    echo "Masked nut-monitor shutdown controller"
else
    echo "nut-monitor shutdown controller already masked"
fi

if [ "$changed" = 1 ]; then
    if systemctl list-unit-files nut-driver-enumerator.service --no-legend 2>/dev/null \
        | grep -q '^nut-driver-enumerator.service'; then
        systemctl restart nut-driver-enumerator.service
    else
        upsdrvctl stop >/dev/null 2>&1 || true
        upsdrvctl start
    fi
    systemctl restart nut-server.service
    echo "NUT driver and server restarted"
fi
systemctl enable --now nut-server.service >/dev/null

temp_file=$(mktemp)
cat > "$temp_file" <<EOF
[Unit]
Description=Homelab UPS telemetry and health check
After=nut-server.service network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${CHECK_SCRIPT}
EOF
if [ -f "$SERVICE_FILE" ] && cmp -s "$temp_file" "$SERVICE_FILE"; then
    rm -f "$temp_file"
    echo "UPS check service unchanged"
else
    mv "$temp_file" "$SERVICE_FILE"
    changed=1
    echo "UPS check service installed"
fi

temp_file=$(mktemp)
cat > "$temp_file" <<EOF
[Unit]
Description=Run the homelab UPS check periodically

[Timer]
OnBootSec=1min
OnUnitActiveSec=15s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
if [ -f "$TIMER_FILE" ] && cmp -s "$temp_file" "$TIMER_FILE"; then
    rm -f "$temp_file"
    echo "UPS check timer unchanged"
else
    mv "$temp_file" "$TIMER_FILE"
    changed=1
    echo "UPS check timer installed"
fi

if [ "$changed" = 1 ]; then
    systemctl daemon-reload
fi
systemctl enable --now homelab-ups-check.timer >/dev/null

sleep 1
if ! systemctl is-active --quiet nut-server.service; then
    echo "ERROR: nut-server is not active; recent status:" >&2
    systemctl --no-pager --lines=20 status nut-server.service >&2 || true
    exit 1
fi

telemetry=""
telemetry_ready=0
for attempt in {1..10}; do
    if telemetry=$(upsc "${NUT_UPS_NAME}@localhost" 2>&1); then
        telemetry_ready=1
        break
    fi
    [ "$attempt" -eq 10 ] || sleep 2
done
if [ "$telemetry_ready" -ne 1 ]; then
    echo "ERROR: NUT did not produce telemetry after startup: $telemetry" >&2
    exit 1
fi
for field in ups.status ups.load battery.charge battery.runtime; do
    if ! grep -q "^${field}: " <<< "$telemetry"; then
        echo "ERROR: NUT telemetry does not include required field: $field" >&2
        exit 1
    fi
done

echo "NUT UPS monitoring ready: ${NUT_UPS_NAME} on ${NUT_LISTEN_ADDRESS}:3493"
