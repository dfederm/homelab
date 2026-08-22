#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_REPO="$TEST_ROOT/repo"
FAKE_BIN="$TEST_ROOT/bin"
TIMEDATECTL_STATE="$TEST_ROOT/timezone"
TIMEDATECTL_LOG="$TEST_ROOT/timedatectl.log"

mkdir -p "$FAKE_REPO/scripts/setup" "$FAKE_BIN" "$TEST_ROOT/config"
cp "$REPO_DIR/scripts/setup/setup.sh" "$FAKE_REPO/scripts/setup/setup.sh"

cat > "$FAKE_REPO/scripts/lib.sh" <<'EOF'
validate_env() {
    local name
    for name in "$@"; do
        if [ -z "${!name:-}" ]; then
            echo "ERROR: $name must be set" >&2
            exit 1
        fi
    done
}

source_env() {
    TZ="${TEST_TZ:-}"
    HOMELAB_SETUP_MODULES=""
    HOMELAB_SERVICES=""
    ENV_FILE="$TEST_ROOT/config/test.env"
    CONFIG_DIR="$TEST_ROOT/config"
    export TZ HOMELAB_SETUP_MODULES HOMELAB_SERVICES ENV_FILE CONFIG_DIR
}
EOF

cat > "$FAKE_BIN/git" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$FAKE_BIN/timedatectl" <<'EOF'
#!/bin/bash
set -euo pipefail

printf '%s\n' "$*" >> "$TIMEDATECTL_LOG"
case "$1" in
    list-timezones)
        echo "America/Los_Angeles"
        for i in $(seq 1 20000); do
            echo "Test/Zone-$i"
        done
        echo "list-complete" >> "$TIMEDATECTL_LOG"
        ;;
    show)
        cat "$TIMEDATECTL_STATE"
        ;;
    set-timezone)
        printf '%s\n' "$2" > "$TIMEDATECTL_STATE"
        ;;
    *)
        exit 2
        ;;
esac
EOF

chmod +x "$FAKE_BIN"/*
export PATH="$FAKE_BIN:$PATH"
export TEST_ROOT TIMEDATECTL_STATE TIMEDATECTL_LOG

run_setup() {
    HOMELAB_SETUP_LOCK_HELD=1 TEST_TZ="$1" \
        bash "$FAKE_REPO/scripts/setup/setup.sh"
}

echo "Etc/UTC" > "$TIMEDATECTL_STATE"
: > "$TIMEDATECTL_LOG"

first_output=$(run_setup "America/Los_Angeles")
grep -q '^System timezone updated: Etc/UTC -> America/Los_Angeles$' \
    <<< "$first_output"
grep -q '^WARNING: No modules or services configured, nothing to do$' \
    <<< "$first_output"
[ "$(cat "$TIMEDATECTL_STATE")" = "America/Los_Angeles" ]
[ "$(grep -c '^set-timezone America/Los_Angeles$' "$TIMEDATECTL_LOG")" -eq 1 ]
grep -q '^list-complete$' "$TIMEDATECTL_LOG"

second_output=$(run_setup "America/Los_Angeles")
grep -q '^System timezone already configured: America/Los_Angeles$' \
    <<< "$second_output"
[ "$(grep -c '^set-timezone America/Los_Angeles$' "$TIMEDATECTL_LOG")" -eq 1 ]

: > "$TIMEDATECTL_LOG"
if run_setup "" > "$TEST_ROOT/missing.out" 2>&1; then
    echo "Setup should reject a missing TZ" >&2
    exit 1
fi
grep -q '^ERROR: TZ must be set$' "$TEST_ROOT/missing.out"
if grep -q '^set-timezone ' "$TIMEDATECTL_LOG"; then
    echo "Missing TZ must not change the system timezone" >&2
    exit 1
fi

: > "$TIMEDATECTL_LOG"
if run_setup "Not/A_Timezone" > "$TEST_ROOT/invalid.out" 2>&1; then
    echo "Setup should reject an invalid TZ" >&2
    exit 1
fi
grep -q '^ERROR: TZ is not a valid system timezone: Not/A_Timezone$' \
    "$TEST_ROOT/invalid.out"
grep -q '^list-complete$' "$TIMEDATECTL_LOG"
if grep -qE '^(show|set-timezone) ' "$TIMEDATECTL_LOG"; then
    echo "Invalid TZ must be rejected before reading or changing current state" >&2
    exit 1
fi

echo "setup timezone tests passed"
