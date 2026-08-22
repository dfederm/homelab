#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

ZONEINFO_DIR="$TEST_ROOT/zoneinfo"
LOCALTIME_FILE="$TEST_ROOT/localtime"
TIMEZONE_FILE="$TEST_ROOT/timezone"
FAKE_REPO="$TEST_ROOT/repo"
FAKE_BIN="$TEST_ROOT/bin"
TIMEZONE_LOG="$TEST_ROOT/timezone.log"

mkdir -p "$ZONEINFO_DIR/America" "$ZONEINFO_DIR/Etc"
printf 'TZif-pacific-zone-data\n' > "$ZONEINFO_DIR/America/Los_Angeles"
printf 'TZif-utc-zone-data\n' > "$ZONEINFO_DIR/Etc/UTC"
printf 'country metadata\n' > "$ZONEINFO_DIR/iso3166.tab"
ln -s "$ZONEINFO_DIR/Etc/UTC" "$LOCALTIME_FILE"
printf 'Etc/UTC\n' > "$TIMEZONE_FILE"

source "$REPO_DIR/scripts/lib.sh"

first_output=$(configure_system_timezone \
    "America/Los_Angeles" "$ZONEINFO_DIR" "$LOCALTIME_FILE" "$TIMEZONE_FILE")
grep -q '^System timezone updated: America/Los_Angeles$' \
    <<< "$first_output"
[ "$(readlink -f "$LOCALTIME_FILE")" = "$ZONEINFO_DIR/America/Los_Angeles" ]
[ "$(cat "$TIMEZONE_FILE")" = "America/Los_Angeles" ]

before_inode=$(stat -c '%i' "$LOCALTIME_FILE")
second_output=$(configure_system_timezone \
    "America/Los_Angeles" "$ZONEINFO_DIR" "$LOCALTIME_FILE" "$TIMEZONE_FILE")
grep -q '^System timezone already configured: America/Los_Angeles$' \
    <<< "$second_output"
[ "$(stat -c '%i' "$LOCALTIME_FILE")" = "$before_inode" ]

rm "$TIMEZONE_FILE"
without_legacy_file=$(configure_system_timezone \
    "America/Los_Angeles" "$ZONEINFO_DIR" "$LOCALTIME_FILE" "$TIMEZONE_FILE")
grep -q '^System timezone already configured: America/Los_Angeles$' \
    <<< "$without_legacy_file"
[ ! -e "$TIMEZONE_FILE" ]

rm "$LOCALTIME_FILE"
cp "$ZONEINFO_DIR/America/Los_Angeles" "$LOCALTIME_FILE"
regular_file_output=$(configure_system_timezone \
    "America/Los_Angeles" "$ZONEINFO_DIR" "$LOCALTIME_FILE" "$TIMEZONE_FILE")
grep -q '^System timezone updated: America/Los_Angeles$' \
    <<< "$regular_file_output"
[ -L "$LOCALTIME_FILE" ]
[ "$(readlink -f "$LOCALTIME_FILE")" = "$ZONEINFO_DIR/America/Los_Angeles" ]
[ ! -e "$TIMEZONE_FILE" ]

if configure_system_timezone \
    "Not/A_Timezone" "$ZONEINFO_DIR" "$LOCALTIME_FILE" "$TIMEZONE_FILE" \
    > "$TEST_ROOT/invalid.out" 2>&1; then
    echo "Timezone configuration should reject an invalid TZ" >&2
    exit 1
fi
grep -q '^ERROR: TZ is not a valid system timezone: Not/A_Timezone$' \
    "$TEST_ROOT/invalid.out"
[ "$(readlink -f "$LOCALTIME_FILE")" = "$ZONEINFO_DIR/America/Los_Angeles" ]
[ ! -e "$TIMEZONE_FILE" ]

if configure_system_timezone \
    "../../../etc/passwd" "$ZONEINFO_DIR" "$LOCALTIME_FILE" "$TIMEZONE_FILE" \
    > "$TEST_ROOT/traversal.out" 2>&1; then
    echo "Timezone configuration should reject paths outside zoneinfo" >&2
    exit 1
fi
grep -q '^ERROR: TZ is not a valid system timezone: ../../../etc/passwd$' \
    "$TEST_ROOT/traversal.out"

if configure_system_timezone \
    "iso3166.tab" "$ZONEINFO_DIR" "$LOCALTIME_FILE" "$TIMEZONE_FILE" \
    > "$TEST_ROOT/metadata.out" 2>&1; then
    echo "Timezone configuration should reject zoneinfo metadata" >&2
    exit 1
fi
grep -q '^ERROR: TZ is not a valid system timezone: iso3166.tab$' \
    "$TEST_ROOT/metadata.out"

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

configure_system_timezone() {
    printf '%s\n' "$1" >> "$TIMEZONE_LOG"
    echo "System timezone already configured: $1"
}
EOF

cat > "$FAKE_BIN/git" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$FAKE_BIN/git"

run_setup() {
    HOMELAB_SETUP_LOCK_HELD=1 TEST_TZ="$1" \
    TEST_ROOT="$TEST_ROOT" TIMEZONE_LOG="$TIMEZONE_LOG" \
    PATH="$FAKE_BIN:$PATH" \
        bash "$FAKE_REPO/scripts/setup/setup.sh"
}

: > "$TIMEZONE_LOG"
setup_output=$(run_setup "America/Los_Angeles")
grep -q '^WARNING: No modules or services configured, nothing to do$' \
    <<< "$setup_output"
[ "$(cat "$TIMEZONE_LOG")" = "America/Los_Angeles" ]

: > "$TIMEZONE_LOG"
if run_setup "" > "$TEST_ROOT/missing.out" 2>&1; then
    echo "Setup should reject a missing TZ" >&2
    exit 1
fi
grep -q '^ERROR: TZ must be set$' "$TEST_ROOT/missing.out"
[ ! -s "$TIMEZONE_LOG" ]

echo "setup timezone tests passed"
