#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

CONFIG_DIR="$TEST_ROOT/config"
export CONFIG_DIR
mkdir -p "$CONFIG_DIR/backup" "$TEST_ROOT/source"
printf 'test data\n' > "$TEST_ROOT/source/file"
guard="$REPO_DIR/services/backup/pre-up.sh"

write_target() {
    printf 'BACKUP_DEST=remote:/first\nBACKUP_SOURCE_PATH=%s\n' "$1" \
        > "$CONFIG_DIR/backup/first.env"
}

expect_failure() {
    local expected="$1"
    if bash "$guard" first > "$TEST_ROOT/output" 2>&1; then
        echo "Expected backup pre-deploy guard to reject: $expected" >&2
        exit 1
    fi
    if ! grep -Fq "$expected" "$TEST_ROOT/output"; then
        cat "$TEST_ROOT/output" >&2
        exit 1
    fi
}

unset BACKUP_SOURCE_PATH || true
printf 'BACKUP_DEST=remote:/first\nBACKUP_SOURCE_DIR=source\n' \
    > "$CONFIG_DIR/backup/first.env"
expect_failure 'must set BACKUP_SOURCE_PATH'

write_target source
expect_failure 'relative BACKUP_SOURCE_PATH'

write_target "$TEST_ROOT/missing"
expect_failure 'not an existing directory'

write_target "$TEST_ROOT/source/file"
expect_failure 'not an existing directory'

write_target /
expect_failure 'must not back up the filesystem root'

write_target "$TEST_ROOT/source"
BACKUP_SOURCE_PATH="$TEST_ROOT/missing" expect_failure 'only in each target'

bash "$guard" first > "$TEST_ROOT/output"

printf 'BACKUP_DEST=remote:/second\nBACKUP_SOURCE_PATH=%s\n' \
    "$TEST_ROOT/source" > "$CONFIG_DIR/backup/second.env"
bash "$guard" 'first second' > "$TEST_ROOT/output"

printf 'BACKUP_DEST=remote:/first/child\nBACKUP_SOURCE_PATH=%s\n' \
    "$TEST_ROOT/source" > "$CONFIG_DIR/backup/second.env"
if bash "$guard" 'first second' > "$TEST_ROOT/output" 2>&1; then
    echo "Expected overlapping destinations to be rejected" >&2
    exit 1
fi
grep -Fq 'OVERLAPPING destinations' "$TEST_ROOT/output"

echo "backup source tests passed"
