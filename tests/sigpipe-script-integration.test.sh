#!/bin/bash

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REAL_BASH=$(command -v bash)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

FAILURES=0

pass() {
    echo "  PASS: $1"
}

fail() {
    echo "  FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

make_git_fake() {
    local bin_dir="$1"

    cat > "$bin_dir/git" <<'EOF'
#!/bin/bash
if [ "$1 $2 $3 $4" = "config --global --get-all safe.directory" ]; then
    printf '%s\n' "$EXPECTED_REPO"
    seq 1 200000
elif [ "$1 $2 $3" = "config --global --add" ]; then
    echo "safe-directory-added" >> "$COMMAND_LOG"
else
    printf '%s\n' "$*" >> "$COMMAND_LOG"
fi
EOF
    chmod +x "$bin_dir/git"
}

echo "=== deploy safe-directory check ==="
deploy_bin="$TEST_ROOT/deploy-bin"
mkdir -p "$deploy_bin"
make_git_fake "$deploy_bin"
cat > "$deploy_bin/bash" <<'EOF'
#!/bin/bash
printf 'bash %s\n' "$*" >> "$COMMAND_LOG"
EOF
chmod +x "$deploy_bin/bash"
deploy_log="$TEST_ROOT/deploy.log"
: > "$deploy_log"
if EXPECTED_REPO="$REPO_DIR" COMMAND_LOG="$deploy_log" PATH="$deploy_bin:$PATH" \
    "$REAL_BASH" "$REPO_DIR/scripts/deploy.sh" >/dev/null; then
    if grep -q '^safe-directory-added$' "$deploy_log"; then
        fail "deploy preserves an existing early safe.directory match"
    else
        pass "deploy preserves an existing early safe.directory match"
    fi
else
    fail "deploy preserves an existing early safe.directory match"
fi

echo
echo "=== dispatch safe-directory check ==="
dispatch_repo="$TEST_ROOT/dispatch-repo"
dispatch_bin="$TEST_ROOT/dispatch-bin"
mkdir -p "$dispatch_repo/scripts" "$dispatch_bin"
cp "$REPO_DIR/scripts/dispatch.sh" "$dispatch_repo/scripts/dispatch.sh"
cat > "$dispatch_repo/scripts/lib.sh" <<'EOF'
source_env() {
    :
}
EOF
make_git_fake "$dispatch_bin"
dispatch_log="$TEST_ROOT/dispatch.log"
deploy_key="$TEST_ROOT/deploy-key"
: > "$dispatch_log"
: > "$deploy_key"
if EXPECTED_REPO="$dispatch_repo" COMMAND_LOG="$dispatch_log" DEPLOY_KEY_PATH="$deploy_key" \
    HOMELAB_DEPLOY_TARGETS="" PATH="$dispatch_bin:$PATH" \
    "$REAL_BASH" "$dispatch_repo/scripts/dispatch.sh" >/dev/null; then
    if grep -q '^safe-directory-added$' "$dispatch_log"; then
        fail "dispatch preserves an existing early safe.directory match"
    else
        pass "dispatch preserves an existing early safe.directory match"
    fi
else
    fail "dispatch preserves an existing early safe.directory match"
fi

echo
echo "=== configure-network route selection ==="
network_repo="$TEST_ROOT/network-repo"
network_bin="$TEST_ROOT/network-bin"
mkdir -p "$network_repo/scripts/setup/modules" "$network_bin"
cp "$REPO_DIR/scripts/setup/modules/configure-network.sh" \
    "$network_repo/scripts/setup/modules/configure-network.sh"
cat > "$network_repo/scripts/lib.sh" <<'EOF'
validate_env() {
    :
}
EOF
cat > "$network_bin/ip" <<'EOF'
#!/bin/bash
if [ "${FAKE_IP_FAIL:-0}" = 1 ]; then
    exit 7
fi
printf 'default via 192.0.2.1 dev eth0 proto dhcp\n'
seq 1 200000 | awk '{ print "default via 192.0.2.1 dev filler" $1 " proto dhcp" }'
EOF
cat > "$network_bin/nmcli" <<'EOF'
#!/bin/bash
case "$*" in
    "-g GENERAL.CONNECTION device show eth0") echo "test-connection" ;;
    "-g ipv4.method connection show test-connection") echo "manual" ;;
    "-g ipv4.addresses connection show test-connection") echo "192.0.2.10/24" ;;
    "-g ipv4.gateway connection show test-connection") echo "192.0.2.1" ;;
    "-g ipv4.dns connection show test-connection") echo "192.0.2.1" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$network_bin"/*
if REPO_DIR="$network_repo" STATIC_IP=192.0.2.10 NETWORK_ROUTER_IP=192.0.2.1 \
    NETWORK_PREFIX=24 PATH="$network_bin:$PATH" \
    "$REAL_BASH" "$network_repo/scripts/setup/modules/configure-network.sh" >/dev/null; then
    pass "configure-network selects an early default route"
else
    fail "configure-network selects an early default route"
fi
if REPO_DIR="$network_repo" STATIC_IP=192.0.2.10 NETWORK_ROUTER_IP=192.0.2.1 \
    NETWORK_PREFIX=24 FAKE_IP_FAIL=1 PATH="$network_bin:$PATH" \
    "$REAL_BASH" "$network_repo/scripts/setup/modules/configure-network.sh" >/dev/null 2>&1; then
    fail "configure-network propagates an ip failure"
else
    status=$?
    if [ "$status" -eq 7 ]; then
        pass "configure-network propagates an ip failure"
    else
        fail "configure-network propagates an ip failure"
    fi
fi

echo
echo "=== install-tools locale detection ==="
tools_repo="$TEST_ROOT/tools-repo"
tools_bin="$TEST_ROOT/tools-bin"
mkdir -p "$tools_repo/scripts/setup/modules" "$tools_bin"
cp "$REPO_DIR/scripts/setup/modules/install-tools.sh" \
    "$tools_repo/scripts/setup/modules/install-tools.sh"
cat > "$tools_repo/scripts/lib.sh" <<'EOF'
apt_get() {
    :
}
EOF
cat > "$tools_bin/locale" <<'EOF'
#!/bin/bash
printf 'en_US.utf8\n'
seq 1 200000
EOF
for command in sed locale-gen; do
    cat > "$tools_bin/$command" <<'EOF'
#!/bin/bash
printf '%s\n' "$0" >> "$COMMAND_LOG"
EOF
done
chmod +x "$tools_bin"/*
tools_log="$TEST_ROOT/tools.log"
: > "$tools_log"
if REPO_DIR="$tools_repo" COMMAND_LOG="$tools_log" PATH="$tools_bin:$PATH" \
    "$REAL_BASH" "$tools_repo/scripts/setup/modules/install-tools.sh" >/dev/null; then
    if [ -s "$tools_log" ]; then
        fail "install-tools recognizes an early existing locale"
    else
        pass "install-tools recognizes an early existing locale"
    fi
else
    fail "install-tools recognizes an early existing locale"
fi

echo
echo "=== zfs-scrub status handling ==="
zfs_dir="$TEST_ROOT/zfs"
zfs_bin="$TEST_ROOT/zfs-bin"
mkdir -p "$zfs_dir" "$zfs_bin"
cp "$REPO_DIR/scripts/storage/zfs-scrub.sh" "$zfs_dir/zfs-scrub.sh"
cat > "$zfs_dir/zfs-health-check.sh" <<'EOF'
#!/bin/bash
echo "health-check" >> "$COMMAND_LOG"
EOF
cat > "$zfs_bin/zpool" <<'EOF'
#!/bin/bash
case "$1" in
    list)
        exit 0
        ;;
    status)
        if [ "${FAKE_ZPOOL_STATUS_FAIL:-0}" = 1 ]; then
            exit 7
        fi
        printf '  scan: scrub in progress since today\n'
        seq 1 200000
        ;;
    scrub)
        echo "scrub-started" >> "$COMMAND_LOG"
        ;;
esac
EOF
chmod +x "$zfs_dir/zfs-health-check.sh" "$zfs_bin/zpool"
zfs_log="$TEST_ROOT/zfs.log"
: > "$zfs_log"
if COMMAND_LOG="$zfs_log" PATH="$zfs_bin:$PATH" \
    "$REAL_BASH" "$zfs_dir/zfs-scrub.sh" tank >/dev/null; then
    if grep -q '^scrub-started$' "$zfs_log"; then
        fail "zfs-scrub detects an early in-progress status"
    else
        pass "zfs-scrub detects an early in-progress status"
    fi
else
    fail "zfs-scrub detects an early in-progress status"
fi
: > "$zfs_log"
if COMMAND_LOG="$zfs_log" FAKE_ZPOOL_STATUS_FAIL=1 PATH="$zfs_bin:$PATH" \
    "$REAL_BASH" "$zfs_dir/zfs-scrub.sh" tank >/dev/null 2>&1; then
    fail "zfs-scrub propagates a zpool status failure"
else
    status=$?
    if [ "$status" -eq 7 ] && [ ! -s "$zfs_log" ]; then
        pass "zfs-scrub propagates a zpool status failure"
    else
        fail "zfs-scrub propagates a zpool status failure"
    fi
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "sigpipe script integration tests passed"
else
    echo "$FAILURES test(s) failed"
fi

exit "$FAILURES"
