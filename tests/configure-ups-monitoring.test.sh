#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_REPO="$TEST_ROOT/repo"
FAKE_BIN="$TEST_ROOT/bin"
NUT_CONFIG_DIR="$TEST_ROOT/etc/nut"
SYSTEMD_UNIT_DIR="$TEST_ROOT/etc/systemd/system"
SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
SYSTEMCTL_STATE="$TEST_ROOT/systemctl-state"
UDEVADM_LOG="$TEST_ROOT/udevadm.log"

mkdir -p "$FAKE_REPO/scripts/setup/modules" "$FAKE_BIN" "$SYSTEMCTL_STATE"
cp "$REPO_DIR/scripts/setup/modules/configure-ups-monitoring.sh" \
    "$FAKE_REPO/scripts/setup/modules/configure-ups-monitoring.sh"
touch "$FAKE_REPO/scripts/ups-status-check.sh"

cat > "$FAKE_REPO/scripts/lib.sh" <<'EOF'
validate_env() {
    local name
    for name in "$@"; do
        [ -n "${!name:-}" ] || return 1
    done
}
apt_get() { return 0; }
ensure_shoutrrr() { return 0; }
EOF

cat > "$FAKE_BIN/install" <<'EOF'
#!/bin/bash
set -euo pipefail
while [[ "$1" == -* ]]; do
    shift 2
done
cp "$1" "$2"
EOF

cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$1" in
    is-enabled)
        if [ "$2" = "nut-monitor.service" ]; then
            if [ -f "$SYSTEMCTL_STATE/nut-monitor.masked" ]; then
                echo "masked"
                exit 1
            fi
            echo "enabled"
        fi
        ;;
    mask)
        touch "$SYSTEMCTL_STATE/nut-monitor.masked"
        ;;
    list-unit-files)
        echo "nut-driver-enumerator.service enabled"
        for i in $(seq 1 200000); do
            echo "filler-${i}.service disabled"
        done
        ;;
    is-active)
        [ "${*: -1}" = "nut-server.service" ]
        ;;
esac
EOF

cat > "$FAKE_BIN/upsc" <<'EOF'
#!/bin/bash
printf '%s\n' \
    'ups.status: OL' \
    'ups.load: 25' \
    'battery.charge: 100' \
    'battery.runtime: 1800'
EOF

cat > "$FAKE_BIN/udevadm" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$UDEVADM_LOG"
EOF

chmod +x "$FAKE_BIN"/*

export PATH="$FAKE_BIN:$PATH"
export SYSTEMCTL_LOG SYSTEMCTL_STATE UDEVADM_LOG

run_module() {
    REPO_DIR="$FAKE_REPO" \
    NUT_CONFIG_DIR="$NUT_CONFIG_DIR" \
    SYSTEMD_UNIT_DIR="$SYSTEMD_UNIT_DIR" \
    NUT_UPS_NAME="test-ups" \
    NUT_UPS_DESCRIPTION="Test UPS" \
    NUT_LISTEN_ADDRESS="192.0.2.10" \
        bash "$FAKE_REPO/scripts/setup/modules/configure-ups-monitoring.sh"
}

run_module >/dev/null

grep -q '^MODE=netserver$' "$NUT_CONFIG_DIR/nut.conf"
grep -q '^    driver = usbhid-ups$' "$NUT_CONFIG_DIR/ups.conf"
grep -q '^    port = auto$' "$NUT_CONFIG_DIR/ups.conf"
grep -q '^LISTEN 192.0.2.10 3493$' "$NUT_CONFIG_DIR/upsd.conf"
grep -q '^After=nut-server.service network-online.target$' \
    "$SYSTEMD_UNIT_DIR/homelab-ups-check.service"
if grep -q '^Requires=nut-server.service$' "$SYSTEMD_UNIT_DIR/homelab-ups-check.service"; then
    echo "UPS check must run even when nut-server fails" >&2
    exit 1
fi
grep -q '^mask --now nut-monitor.service$' "$SYSTEMCTL_LOG"
grep -q '^restart nut-driver-enumerator.service$' "$SYSTEMCTL_LOG"
grep -q '^restart nut-server.service$' "$SYSTEMCTL_LOG"
grep -q '^control --reload-rules$' "$UDEVADM_LOG"
grep -q '^trigger --subsystem-match=usb --action=change$' "$UDEVADM_LOG"
grep -q '^settle$' "$UDEVADM_LOG"

: > "$SYSTEMCTL_LOG"
: > "$UDEVADM_LOG"
run_module >/dev/null

if grep -q '^mask --now nut-monitor.service$' "$SYSTEMCTL_LOG"; then
    echo "Second run should preserve the existing nut-monitor mask" >&2
    exit 1
fi
if grep -q '^restart nut-driver-enumerator.service$' "$SYSTEMCTL_LOG" \
    || grep -q '^restart nut-server.service$' "$SYSTEMCTL_LOG"; then
    echo "Second run should not restart unchanged NUT services" >&2
    exit 1
fi
grep -q '^control --reload-rules$' "$UDEVADM_LOG"
grep -q '^trigger --subsystem-match=usb --action=change$' "$UDEVADM_LOG"
grep -q '^settle$' "$UDEVADM_LOG"

echo "configure-ups-monitoring tests passed"
