#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/empty"
cat > "$TEST_ROOT/bin/logger" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ALERT_LOG"
EOF
cat > "$TEST_ROOT/bin/shoutrrr" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$TEST_NOTIFICATION_LOG"
if [ "${TEST_SEND_FAIL:-0}" = 1 ]; then
    exit 1
fi
EOF
chmod +x "$TEST_ROOT/bin/"*

export PATH="$TEST_ROOT/bin:$PATH"
export TEST_ALERT_LOG="$TEST_ROOT/alerts"
export TEST_NOTIFICATION_LOG="$TEST_ROOT/notifications"
source "$REPO_DIR/scripts/lib.sh"

unset HOMELAB_ALERT_SHOUTRRR_URL
[ "$(send_alert "homelab storage" "disk full" "homelab-storage-alert")" = "ALERT: disk full" ]
[ "$(cat "$TEST_ALERT_LOG")" = "-t homelab-storage-alert disk full" ]
[ ! -e "$TEST_NOTIFICATION_LOG" ]

: > "$TEST_ALERT_LOG"
[ "$(send_alert "homelab backup" "dump failed")" = "ALERT: dump failed" ]
[ "$(cat "$TEST_ALERT_LOG")" = "-t homelab-alert dump failed" ]

export HOMELAB_ALERT_SHOUTRRR_URL="pushover://test"
send_alert "homelab storage" "disk full" "homelab-storage-alert" > /dev/null
printf 'send\n--url\npushover://test\n--title\nhomelab storage\n--message\ndisk full\n' \
    > "$TEST_ROOT/expected"
cmp "$TEST_ROOT/expected" "$TEST_NOTIFICATION_LOG"

export TEST_SEND_FAIL=1
if send_alert "homelab storage" "disk full" > "$TEST_ROOT/output" 2>&1; then
    echo "Expected failed Shoutrrr send to be reported" >&2
    exit 1
fi
grep -Fq "shoutrrr send failed" "$TEST_ROOT/output"
unset TEST_SEND_FAIL

if PATH="$TEST_ROOT/empty" send_alert "homelab storage" "disk full" \
    > "$TEST_ROOT/output" 2>&1; then
    echo "Expected missing Shoutrrr CLI to be reported" >&2
    exit 1
fi
grep -Fq "shoutrrr is unavailable" "$TEST_ROOT/output"

echo "alert delivery tests passed"
