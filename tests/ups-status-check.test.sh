#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/upsc" <<'EOF'
#!/bin/bash
if [ "${FAKE_UPSC_FAIL:-0}" = 1 ]; then
    echo "Connection failure" >&2
    exit 1
fi
cat "$FAKE_UPSC_OUTPUT"
EOF

cat > "$FAKE_BIN/shoutrrr" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_NOTIFICATION_LOG"
EOF

cat > "$FAKE_BIN/logger" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$FAKE_BIN/hostname" <<'EOF'
#!/bin/bash
echo testhost
EOF

chmod +x "$FAKE_BIN"/*

export PATH="$FAKE_BIN:$PATH"
export HOMELAB_ENV_LOADED=1
export HOMELAB_ALERT_SHOUTRRR_URL="pushover://example"
export NUT_UPS_NAME="test-ups"
export UPS_ALERT_REPEAT_HOURS=12
export UPS_ALERT_STATE_DIR="$TEST_ROOT/state"
export TEST_NOTIFICATION_LOG="$TEST_ROOT/notifications"
export FAKE_UPSC_OUTPUT="$TEST_ROOT/upsc-output"

run_check() {
    bash "$REPO_DIR/scripts/ups-status-check.sh"
}

reset_case() {
    rm -rf "$UPS_ALERT_STATE_DIR"
    mkdir -p "$UPS_ALERT_STATE_DIR"
    : > "$TEST_NOTIFICATION_LOG"
    unset FAKE_UPSC_FAIL
    export UPS_ON_BATTERY_ALERT_DELAY_SECONDS=0
    export UPS_COMM_FAILURE_ALERT_DELAY_SECONDS=0
    export UPS_LOAD_WARNING_PERCENT=80
}

write_telemetry() {
    cat > "$FAKE_UPSC_OUTPUT" <<EOF
ups.status: $1
ups.load: $2
battery.charge: $3
battery.runtime: $4
EOF
}

assert_log_contains() {
    local expected="$1"
    if ! grep -q "$expected" "$TEST_NOTIFICATION_LOG"; then
        echo "Expected notification containing '$expected'" >&2
        cat "$TEST_NOTIFICATION_LOG" >&2
        exit 1
    fi
}

reset_case
write_telemetry OL 25 100 1800
run_check >/dev/null
[ ! -s "$TEST_NOTIFICATION_LOG" ]

reset_case
export UPS_ON_BATTERY_ALERT_DELAY_SECONDS=30
write_telemetry OB 25 95 1500
run_check >/dev/null
write_telemetry OL 25 95 1800
run_check >/dev/null
[ ! -s "$TEST_NOTIFICATION_LOG" ]

reset_case
write_telemetry OB 25 95 1500
run_check >/dev/null
assert_log_contains "UPS is on battery"
write_telemetry OL 25 95 1800
run_check >/dev/null
assert_log_contains "returned to line power"

reset_case
export FAKE_UPSC_FAIL=1
if run_check >/dev/null 2>&1; then
    echo "Communication failure should fail the check" >&2
    exit 1
fi
assert_log_contains "telemetry unavailable"
unset FAKE_UPSC_FAIL
write_telemetry OL 25 100 1800
run_check >/dev/null
assert_log_contains "telemetry restored"

reset_case
cat > "$FAKE_UPSC_OUTPUT" <<EOF
ups.status: OL
ups.load: 25
battery.charge: 100
EOF
if run_check >/dev/null 2>&1; then
    echo "Missing required telemetry should fail the check" >&2
    exit 1
fi
assert_log_contains "telemetry incomplete"

reset_case
write_telemetry OL 85 100 1200
run_check >/dev/null
assert_log_contains "UPS load is 85%"

reset_case
write_telemetry "OL RB" 25 100 1800
run_check >/dev/null
assert_log_contains "unhealthy state"

echo "ups-status-check tests passed"
