#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT=$(mktemp -d)
cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    [ "$expected" = "$actual" ] \
        || fail "$message (expected '$expected', got '$actual')"
}

wait_for_file() {
    local file="$1"
    local attempts=200

    while [ ! -f "$file" ] && [ "$attempts" -gt 0 ]; do
        sleep 0.05
        attempts=$((attempts - 1))
    done
    [ -f "$file" ] || fail "timed out waiting for $file"
}

echo "=== target signal coalescing ==="

SIGNAL_INSTALL="$TEST_ROOT/signal-install"
SIGNAL_CONFIG="$TEST_ROOT/signal-config"
SIGNAL_STATE="$TEST_ROOT/signal-state"
SIGNAL_BIN="$TEST_ROOT/signal-bin"
SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
mkdir -p "$SIGNAL_INSTALL" "$SIGNAL_CONFIG" "$SIGNAL_BIN"
cp "$REPO_DIR/scripts/deploy-signal.sh" "$SIGNAL_INSTALL/deploy-signal.sh"
cp "$REPO_DIR/scripts/deploy-state.sh" "$SIGNAL_INSTALL/deploy-state.sh"
cat > "$SIGNAL_CONFIG/test.env" <<EOF
DEPLOY_STATE_DIR=$SIGNAL_STATE
EOF
cat > "$SIGNAL_BIN/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
EOF
chmod +x "$SIGNAL_BIN/systemctl"

run_signal() {
    HOMELAB_SYSTEM_ENV="$SIGNAL_CONFIG/test.env" \
    SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
    PATH="$SIGNAL_BIN:$PATH" \
        bash "$SIGNAL_INSTALL/deploy-signal.sh"
}

run_signal
run_signal
[ -f "$SIGNAL_STATE/pending" ] || fail "signal did not persist pending state"
assert_equals "1" "$(find "$SIGNAL_STATE" -maxdepth 1 -name pending | wc -l | tr -d ' ')" \
    "signals use one pending bit"
grep -q $'signal\tcoalesced=false' "$SIGNAL_STATE/events.log" \
    || fail "first signal was not logged"
grep -q $'signal\tcoalesced=true' "$SIGNAL_STATE/events.log" \
    || fail "coalesced signal was not logged"
assert_equals "2" "$(wc -l < "$SYSTEMCTL_LOG" | tr -d ' ')" \
    "each signal requests a low-latency wake"

echo "=== webhook dispatch signals installed target helpers ==="

DISPATCH_REPO="$TEST_ROOT/dispatch-repo"
DISPATCH_BIN="$TEST_ROOT/dispatch-bin"
DISPATCH_KEY="$TEST_ROOT/dispatch-key"
SSH_LOG="$TEST_ROOT/ssh.log"
mkdir -p "$DISPATCH_REPO/scripts" "$DISPATCH_BIN"
cp "$REPO_DIR/services/webhook/dispatch.sh" \
    "$DISPATCH_REPO/scripts/dispatch.sh"
cat > "$DISPATCH_REPO/scripts/lib.sh" <<'EOF'
source_env() { :; }
validate_env() {
    local name
    for name in "$@"; do
        [ -n "${!name:-}" ] || return 1
    done
}
EOF
cat > "$DISPATCH_BIN/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_LOG"
EOF
chmod +x "$DISPATCH_BIN/ssh"
touch "$DISPATCH_KEY"

DEPLOY_KEY_PATH="$DISPATCH_KEY" \
HOMELAB_DEPLOY_TARGETS=TEST \
TEST_DEPLOY_HOST=192.0.2.10 \
SSH_LOG="$SSH_LOG" \
PATH="$DISPATCH_BIN:$PATH" \
    bash "$DISPATCH_REPO/scripts/dispatch.sh" refs/heads/main >/dev/null
grep -q 'root@192.0.2.10 /usr/local/lib/homelab/deploy-signal.sh$' "$SSH_LOG" \
    || fail "dispatch did not invoke the installed target signal helper"

echo "=== worker serialization, trailing pass, and reconciliation ==="

ORIGIN="$TEST_ROOT/origin.git"
SEED="$TEST_ROOT/seed"
WORKER_INSTALL="$TEST_ROOT/worker-install"
WORKER_CONFIG="$TEST_ROOT/worker-config"
WORKER_CHECKOUT="$TEST_ROOT/worker-checkout"
WORKER_STATE="$TEST_ROOT/worker-state"
WORKER_LOGS="$TEST_ROOT/worker-logs"
WORKER_BIN="$TEST_ROOT/worker-bin"
CONTROL="$TEST_ROOT/control"
SETUP_LOCK="$TEST_ROOT/setup.lock"
WORKER_LOCK="$TEST_ROOT/worker.lock"

git init --bare "$ORIGIN" >/dev/null
git init -b main "$SEED" >/dev/null
git -C "$SEED" config user.name Test
git -C "$SEED" config user.email test@example.com
git -C "$SEED" remote add origin "$ORIGIN"
mkdir -p "$SEED/scripts/setup" "$WORKER_INSTALL" "$WORKER_CONFIG" \
    "$WORKER_BIN" "$CONTROL"

cat > "$SEED/scripts/setup/setup.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
commit=$(git -C "$repo_dir" rev-parse HEAD)

exec 6> "$TEST_CONTROL/state.lock"
flock 6
active=$(cat "$TEST_CONTROL/active" 2>/dev/null || echo 0)
active=$((active + 1))
echo "$active" > "$TEST_CONTROL/active"
maximum=$(cat "$TEST_CONTROL/maximum" 2>/dev/null || echo 0)
[ "$active" -le "$maximum" ] || echo "$active" > "$TEST_CONTROL/maximum"
printf '%s\n' "$commit" >> "$TEST_CONTROL/runs"
printf '%s\n' "$repo_dir" >> "$TEST_CONTROL/paths"
flock -u 6

if [ -f "$TEST_CONTROL/block-$commit" ]; then
    touch "$TEST_CONTROL/started-$commit"
    while [ ! -f "$TEST_CONTROL/release-$commit" ]; do
        sleep 0.05
    done
fi

status=0
if [ -f "$TEST_CONTROL/fail-once-$commit" ]; then
    rm -f "$TEST_CONTROL/fail-once-$commit"
    status=7
fi

flock 6
active=$(cat "$TEST_CONTROL/active")
echo $((active - 1)) > "$TEST_CONTROL/active"
flock -u 6
exit "$status"
EOF
chmod +x "$SEED/scripts/setup/setup.sh"
printf 'a\n' > "$SEED/value.txt"
git -C "$SEED" add .
git -C "$SEED" commit -m A >/dev/null
git -C "$SEED" push -u origin main >/dev/null
COMMIT_A=$(git -C "$SEED" rev-parse HEAD)

cp "$REPO_DIR/scripts/deploy-worker.sh" "$WORKER_INSTALL/deploy-worker.sh"
cp "$REPO_DIR/scripts/deploy-signal.sh" "$WORKER_INSTALL/deploy-signal.sh"
cp "$REPO_DIR/scripts/deploy-state.sh" "$WORKER_INSTALL/deploy-state.sh"
write_worker_config() {
    local repository_url="$1"

    cat > "$WORKER_CONFIG/test.env" <<EOF
DEPLOY_REPOSITORY_URL=$repository_url
HOMELAB_REPO_DIR=$WORKER_CHECKOUT
DEPLOY_STATE_DIR=$WORKER_STATE
DEPLOY_LOG_DIR=$WORKER_LOGS
DEPLOY_RETENTION_DAYS=30
EOF
}
write_worker_config "$ORIGIN"
cat > "$WORKER_BIN/systemctl" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$WORKER_BIN/systemctl"

run_worker_signal() {
    HOMELAB_SYSTEM_ENV="$WORKER_CONFIG/test.env" \
    PATH="$WORKER_BIN:$PATH" \
        bash "$WORKER_INSTALL/deploy-signal.sh"
}

run_worker() {
    HOMELAB_SYSTEM_ENV="$WORKER_CONFIG/test.env" \
    HOMELAB_SETUP_LOCK_FILE="$SETUP_LOCK" \
    HOMELAB_DEPLOY_WORKER_LOCK="$WORKER_LOCK" \
    TEST_CONTROL="$CONTROL" \
    PATH="${WORKER_EXTRA_PATH:-}$WORKER_BIN:$PATH" \
        bash "$WORKER_INSTALL/deploy-worker.sh"
}

run_worker_signal
touch "$CONTROL/block-$COMMIT_A"
run_worker >/dev/null 2>&1 &
WORKER_PID=$!
wait_for_file "$CONTROL/started-$COMMIT_A"

printf 'b\n' > "$SEED/value.txt"
git -C "$SEED" commit -am B >/dev/null
printf 'c\n' > "$SEED/value.txt"
git -C "$SEED" commit -am C >/dev/null
git -C "$SEED" push origin main >/dev/null
COMMIT_C=$(git -C "$SEED" rev-parse HEAD)
run_worker_signal
run_worker_signal
touch "$CONTROL/release-$COMMIT_A"
wait "$WORKER_PID"

assert_equals "$(printf '%s\n%s' "$COMMIT_A" "$COMMIT_C")" \
    "$(cat "$CONTROL/runs")" \
    "signals during a run collapse into one latest-at-run-time trailing pass"
assert_equals "1" "$(cat "$CONTROL/maximum")" "setup runs are serialized"
assert_equals "1" "$(sort -u "$CONTROL/paths" | wc -l | tr -d ' ')" \
    "worker reuses one stable checkout"
assert_equals "$WORKER_CHECKOUT" "$(head -n 1 "$CONTROL/paths")" \
    "worker runs setup from its local checkout"
assert_equals "$COMMIT_C" "$(cat "$WORKER_STATE/last-success")" \
    "worker records only the successful commit"
grep -q $'trailing-run\t' "$WORKER_STATE/events.log" \
    || fail "worker did not log its trailing pass"

run_worker >/dev/null 2>&1
assert_equals "2" "$(wc -l < "$CONTROL/runs" | tr -d ' ')" \
    "reconciliation skips an already-successful commit"

printf 'd\n' > "$SEED/value.txt"
git -C "$SEED" commit -am D >/dev/null
git -C "$SEED" push origin main >/dev/null
COMMIT_D=$(git -C "$SEED" rev-parse HEAD)
run_worker >/dev/null 2>&1
assert_equals "$COMMIT_D" "$(tail -n 1 "$CONTROL/runs")" \
    "timer-style reconciliation deploys a missed signal"

printf 'e\n' > "$SEED/value.txt"
git -C "$SEED" commit -am E >/dev/null
git -C "$SEED" push origin main >/dev/null
COMMIT_E=$(git -C "$SEED" rev-parse HEAD)
touch "$CONTROL/fail-once-$COMMIT_E"
if run_worker >/dev/null 2>&1; then
    fail "failed setup unexpectedly succeeded"
else
    assert_equals "7" "$?" "worker preserves setup failure status"
fi
assert_equals "$COMMIT_D" "$(cat "$WORKER_STATE/last-success")" \
    "failed setup does not advance successful state"
run_worker >/dev/null 2>&1
assert_equals "$COMMIT_E" "$(cat "$WORKER_STATE/last-success")" \
    "later reconciliation retries a failed commit"

touch "$CONTROL/fail-once-$COMMIT_E"
run_worker_signal
if run_worker >/dev/null 2>&1; then
    fail "same-commit signaled failure unexpectedly succeeded"
fi
[ -f "$WORKER_STATE/retry-signal" ] \
    || fail "failed same-commit signal was not preserved for retry"
RUN_COUNT=$(wc -l < "$CONTROL/runs" | tr -d ' ')
run_worker >/dev/null 2>&1
assert_equals "$((RUN_COUNT + 1))" \
    "$(wc -l < "$CONTROL/runs" | tr -d ' ')" \
    "preserved same-commit signal is retried"
[ ! -e "$WORKER_STATE/retry-signal" ] \
    || fail "successful retry did not clear durable signal state"

printf 'stale\n' > "$WORKER_STATE/active-signal"
RUN_COUNT=$(wc -l < "$CONTROL/runs" | tr -d ' ')
run_worker >/dev/null 2>&1
assert_equals "$((RUN_COUNT + 1))" \
    "$(wc -l < "$CONTROL/runs" | tr -d ' ')" \
    "stale active signal from a killed worker is recovered"
[ ! -e "$WORKER_STATE/active-signal" ] \
    || fail "recovered active signal was not cleared"

echo "=== interrupted signal claim preserves durable intent ==="

INTERRUPT_BIN="$TEST_ROOT/interrupt-bin"
INTERRUPT_MARKER="$TEST_ROOT/claim-interrupted"
REAL_RM=$(command -v rm)
mkdir -p "$INTERRUPT_BIN"
cat > "$INTERRUPT_BIN/rm" <<'EOF'
#!/bin/bash
if [[ "$*" = *pending*retry-signal* ]] \
    && [ ! -f "$INTERRUPT_MARKER" ]; then
    [ -f "$WORKER_STATE/active-signal" ] || exit 98
    touch "$INTERRUPT_MARKER"
    exit 99
fi
exec "$REAL_RM" "$@"
EOF
chmod +x "$INTERRUPT_BIN/rm"

run_worker_signal
RUN_COUNT=$(wc -l < "$CONTROL/runs" | tr -d ' ')
if INTERRUPT_MARKER="$INTERRUPT_MARKER" WORKER_STATE="$WORKER_STATE" \
    REAL_RM="$REAL_RM" WORKER_EXTRA_PATH="$INTERRUPT_BIN:" \
    run_worker >/dev/null 2>&1; then
    fail "interrupted signal claim unexpectedly succeeded"
fi
[ -f "$WORKER_STATE/active-signal" ] \
    || fail "signal claim removed pending state before creating active state"
run_worker >/dev/null 2>&1
assert_equals "$((RUN_COUNT + 1))" \
    "$(wc -l < "$CONTROL/runs" | tr -d ' ')" \
    "interrupted same-commit signal is recovered"

echo "=== worker fetch occurs after the setup lock ==="

(
    exec 9> "$SETUP_LOCK"
    flock 9
    touch "$CONTROL/setup-lock-held"
    while [ ! -f "$CONTROL/setup-lock-release" ]; do
        sleep 0.05
    done
) &
LOCK_PID=$!
wait_for_file "$CONTROL/setup-lock-held"

run_worker_signal
run_worker >/dev/null 2>&1 &
WAITING_WORKER_PID=$!
sleep 0.1
printf 'f\n' > "$SEED/value.txt"
git -C "$SEED" commit -am F >/dev/null
git -C "$SEED" push origin main >/dev/null
COMMIT_F=$(git -C "$SEED" rev-parse HEAD)
touch "$CONTROL/setup-lock-release"
wait "$LOCK_PID"
wait "$WAITING_WORKER_PID"
assert_equals "$COMMIT_F" "$(tail -n 1 "$CONTROL/runs")" \
    "worker fetches latest origin/main only after obtaining the target lock"

echo "=== partially corrupt checkout recovery ==="

RUN_COUNT=$(wc -l < "$CONTROL/runs" | tr -d ' ')
git -C "$WORKER_CHECKOUT" remote remove origin
run_worker >/dev/null 2>&1
assert_equals "$RUN_COUNT" "$(wc -l < "$CONTROL/runs" | tr -d ' ')" \
    "checkout repair does not redeploy an already-successful commit"
assert_equals "$ORIGIN" "$(git -C "$WORKER_CHECKOUT" remote get-url origin)" \
    "worker rebuilds a checkout with missing origin"

echo "=== failed checkout rebuild preserves signal and source ==="

RUN_COUNT=$(wc -l < "$CONTROL/runs" | tr -d ' ')
CHECKOUT_COMMIT=$(git -C "$WORKER_CHECKOUT" rev-parse HEAD)
write_worker_config "$TEST_ROOT/missing-origin.git"
run_worker_signal
if run_worker >/dev/null 2>&1; then
    fail "worker used stale source after a failed checkout rebuild"
fi
assert_equals "$RUN_COUNT" "$(wc -l < "$CONTROL/runs" | tr -d ' ')" \
    "failed checkout rebuild does not run stale setup"
assert_equals "$CHECKOUT_COMMIT" "$(git -C "$WORKER_CHECKOUT" rev-parse HEAD)" \
    "failed checkout rebuild preserves the old disposable checkout"
[ -f "$WORKER_STATE/retry-signal" ] \
    || fail "failed checkout rebuild did not preserve its signal"

write_worker_config "$ORIGIN"
run_worker >/dev/null 2>&1
assert_equals "$((RUN_COUNT + 1))" \
    "$(wc -l < "$CONTROL/runs" | tr -d ' ')" \
    "recovered checkout applies the preserved same-commit signal"
[ ! -e "$WORKER_STATE/retry-signal" ] \
    || fail "successful checkout recovery did not clear retry state"

echo "=== worker module idempotency and durable wake path ==="

MODULE_REPO="$TEST_ROOT/module-repo"
MODULE_BIN="$TEST_ROOT/module-bin"
MODULE_INSTALL="$TEST_ROOT/module-install"
MODULE_UNITS="$TEST_ROOT/module-units"
MODULE_STATE="$TEST_ROOT/module-state"
MODULE_SYSTEMCTL_LOG="$TEST_ROOT/module-systemctl.log"
mkdir -p "$MODULE_REPO/scripts/setup/modules" "$MODULE_BIN"
cp "$REPO_DIR/scripts/setup/modules/configure-deploy-worker.sh" \
    "$MODULE_REPO/scripts/setup/modules/configure-deploy-worker.sh"
cp "$REPO_DIR/scripts/deploy-worker.sh" "$MODULE_REPO/scripts/deploy-worker.sh"
cp "$REPO_DIR/scripts/deploy-signal.sh" "$MODULE_REPO/scripts/deploy-signal.sh"
cp "$REPO_DIR/scripts/deploy-state.sh" "$MODULE_REPO/scripts/deploy-state.sh"
cat > "$MODULE_REPO/scripts/lib.sh" <<'EOF'
validate_env() {
    local name
    for name in "$@"; do
        [ -n "${!name:-}" ] || return 1
    done
}
apt_get() { return 0; }
EOF
cat > "$MODULE_BIN/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MODULE_SYSTEMCTL_LOG"
EOF
chmod +x "$MODULE_BIN/systemctl"

run_worker_module() {
    REPO_DIR="$MODULE_REPO" \
    DEPLOY_REPOSITORY_URL="$ORIGIN" \
    DEPLOY_STATE_DIR="$MODULE_STATE" \
    DEPLOY_BOOT_DELAY_SEC=11 \
    DEPLOY_RECONCILE_INTERVAL_SEC=37 \
    DEPLOY_WORKER_INSTALL_DIR="$MODULE_INSTALL" \
    SYSTEMD_UNIT_DIR="$MODULE_UNITS" \
    MODULE_SYSTEMCTL_LOG="$MODULE_SYSTEMCTL_LOG" \
    PATH="$MODULE_BIN:$PATH" \
        bash "$MODULE_REPO/scripts/setup/modules/configure-deploy-worker.sh"
}

run_worker_module >/dev/null
[ -x "$MODULE_INSTALL/deploy-worker.sh" ] \
    || fail "worker module did not install the worker"
[ -x "$MODULE_INSTALL/deploy-signal.sh" ] \
    || fail "worker module did not install the signal helper"
grep -q "^PathExists=$MODULE_STATE/pending$" \
    "$MODULE_UNITS/homelab-deploy-worker.path" \
    || fail "path unit does not preserve end-of-run signals"
grep -q '^OnBootSec=11s$' "$MODULE_UNITS/homelab-deploy-worker.timer" \
    || fail "worker module did not configure boot reconciliation"
grep -q '^OnUnitInactiveSec=37s$' \
    "$MODULE_UNITS/homelab-deploy-worker.timer" \
    || fail "worker module did not configure periodic reconciliation"
grep -q '^daemon-reload$' "$MODULE_SYSTEMCTL_LOG" \
    || fail "worker module did not reload changed units"

: > "$MODULE_SYSTEMCTL_LOG"
run_worker_module >/dev/null
if grep -q '^daemon-reload$' "$MODULE_SYSTEMCTL_LOG"; then
    fail "worker module reloaded unchanged units"
fi
grep -q '^enable --now homelab-deploy-worker.path homelab-deploy-worker.timer$' \
    "$MODULE_SYSTEMCTL_LOG" \
    || fail "worker module did not enable both durable triggers"

echo "=== LXC stable local source synchronization ==="

LXC_REPO="$TEST_ROOT/lxc-source"
LXC_BIN="$TEST_ROOT/lxc-bin"
LXC_TEMPLATES="$TEST_ROOT/lxc-templates"
LXC_LOCAL_REPO="$TEST_ROOT/lxc-local/opt/homelab/repo"
LXC_SHARED_ROOT="$TEST_ROOT/lxc-shared"
LXC_GUEST_ROOT="$TEST_ROOT/lxc-guest/mnt/homelab"
LXC_NESTED_GUEST_ROOT="$TEST_ROOT/lxc-guest/mnt/nested"
LXC_ROOT_GUEST="$TEST_ROOT/lxc-guest/mnt/host-root"
LXC_HOST_CONFIG="$LXC_SHARED_ROOT/nested/config"
LXC_CONTROL="$TEST_ROOT/lxc-control"
PCT_LOG="$TEST_ROOT/pct.log"
mkdir -p "$LXC_REPO/scripts/setup/modules" "$LXC_REPO/scripts/setup" \
    "$LXC_BIN" "$LXC_TEMPLATES" "$LXC_CONTROL" \
    "$LXC_HOST_CONFIG" "$TEST_ROOT/lxc-share" "$TEST_ROOT/lxc-other"
cp "$REPO_DIR/scripts/setup/modules/create-lxcs.sh" \
    "$LXC_REPO/scripts/setup/modules/create-lxcs.sh"
cat > "$LXC_REPO/scripts/lib.sh" <<'EOF'
validate_env() {
    local name
    for name in "$@"; do
        [ -n "${!name:-}" ] || return 1
    done
}
EOF
cat > "$LXC_REPO/scripts/setup/setup.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\t%s\t%s\n' \
    "$(readlink -f "$0")" \
    "${HOMELAB_SETUP_LOCK_HELD:-0}" \
    "${CONFIG_DIR:-}" \
    >> "$LXC_CONTROL/runs"
EOF
chmod +x "$LXC_REPO/scripts/setup/setup.sh"
mkdir -p "$LXC_REPO/dir-to-file"
printf 'old\n' > "$LXC_REPO/dir-to-file/value"
printf 'old\n' > "$LXC_REPO/file-to-dir"
touch "$LXC_TEMPLATES/debian-12-standard_test_amd64.tar.zst"
cat > "$LXC_BIN/pct" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$PCT_LOG"
case "$1" in
    status)
        echo "status: running"
        ;;
    config)
        cat <<CONFIG
hostname: test-lxc
memory: 512
cores: 1
onboot: 1
net0: name=eth0,bridge=vmbr0,ip=192.0.2.20/24,gw=192.0.2.1
nameserver: 192.0.2.1
mp0: $TEST_LXC_MP0
rootfs: local-lvm:vm-100-disk-0,size=8G
CONFIG
        [ -z "${TEST_LXC_MP1:-}" ] || echo "mp1: $TEST_LXC_MP1"
        [ -z "${TEST_LXC_MP2:-}" ] || echo "mp2: $TEST_LXC_MP2"
        ;;
    exec)
        shift 3
        "$@"
        ;;
esac
EOF
chmod +x "$LXC_BIN/pct"

run_lxc_module() {
    local config_dir="${LXC_TEST_CONFIG_DIR:-$LXC_HOST_CONFIG}"
    local mp0="${LXC_TEST_MP0:-$TEST_ROOT/lxc-share,mp=/mnt/wrong}"
    local mp1="${LXC_TEST_MP1-$LXC_SHARED_ROOT/,mp=$LXC_GUEST_ROOT/}"
    local mp2="${LXC_TEST_MP2-volume=$LXC_SHARED_ROOT/nested/,mp=$LXC_NESTED_GUEST_ROOT/}"

    REPO_DIR="$LXC_REPO" \
    CONFIG_DIR="$config_dir" \
    HOMELAB_REPO_DIR="$LXC_LOCAL_REPO" \
    HOMELAB_LXCS=TEST_LXC \
    TEST_LXC_VMID=100 \
    TEST_LXC_HOSTNAME=test-lxc \
    TEST_LXC_IP=192.0.2.20 \
    TEST_LXC_MEMORY_MIB=512 \
    TEST_LXC_CORES=1 \
    TEST_LXC_ROOTFS_GIB=8 \
    TEST_LXC_NESTING=0 \
    TEST_LXC_MP0="$mp0" \
    TEST_LXC_MP1="$mp1" \
    TEST_LXC_MP2="$mp2" \
    NETWORK_ROUTER_IP=192.0.2.1 \
    NETWORK_PREFIX=24 \
    DNS_IP=192.0.2.1 \
    LXC_TEMPLATE_DIR="$LXC_TEMPLATES" \
    LXC_CONTROL="$LXC_CONTROL" \
    PCT_LOG="$PCT_LOG" \
    PATH="$LXC_BIN:$PATH" \
        bash "$LXC_REPO/scripts/setup/modules/create-lxcs.sh" >/dev/null
}

run_lxc_module
touch "$LXC_LOCAL_REPO/stale"
rm -rf "$LXC_REPO/dir-to-file"
printf 'new\n' > "$LXC_REPO/dir-to-file"
rm -f "$LXC_REPO/file-to-dir"
mkdir -p "$LXC_REPO/file-to-dir"
printf 'new\n' > "$LXC_REPO/file-to-dir/value"
printf 'new\n' > "$LXC_REPO/new-file"
run_lxc_module
[ ! -e "$LXC_LOCAL_REPO/stale" ] \
    || fail "LXC synchronization retained a removed source file"
[ -f "$LXC_LOCAL_REPO/new-file" ] \
    || fail "LXC synchronization missed a new source file"
[ -f "$LXC_LOCAL_REPO/dir-to-file" ] \
    || fail "LXC synchronization failed a directory-to-file transition"
[ -d "$LXC_LOCAL_REPO/file-to-dir" ] \
    || fail "LXC synchronization failed a file-to-directory transition"
assert_equals "1" "$(cut -f2 "$LXC_CONTROL/runs" | sort -u)" \
    "LXC setup runs while its source-copy lock is held"
assert_equals "$LXC_LOCAL_REPO/scripts/setup/setup.sh" \
    "$(head -n 1 "$LXC_CONTROL/runs" | cut -f1)" \
    "LXC setup runs from its stable local copy"
assert_equals "$LXC_NESTED_GUEST_ROOT/config" \
    "$(head -n 1 "$LXC_CONTROL/runs" | cut -f3)" \
    "LXC config path supports keyed volumes, longest matching, and slashes"

LXC_TEST_MP0="/,mp=$LXC_ROOT_GUEST/" \
LXC_TEST_MP1="" \
LXC_TEST_MP2="" \
    run_lxc_module
assert_equals "$LXC_ROOT_GUEST/$(readlink -f "$LXC_HOST_CONFIG" | sed 's#^/##')" \
    "$(tail -n 1 "$LXC_CONTROL/runs" | cut -f3)" \
    "LXC config path supports a host root mount"

RUN_COUNT=$(wc -l < "$LXC_CONTROL/runs" | tr -d ' ')
if LXC_TEST_CONFIG_DIR="$LXC_HOST_CONFIG" \
    LXC_TEST_MP0="$TEST_ROOT/lxc-other,mp=/mnt/other" \
    LXC_TEST_MP1="" \
    LXC_TEST_MP2="" \
    run_lxc_module 2>/dev/null; then
    fail "LXC setup accepted config outside every mount"
fi
assert_equals "$RUN_COUNT" "$(wc -l < "$LXC_CONTROL/runs" | tr -d ' ')" \
    "missing config mount fails before LXC setup"

echo "deploy coordination tests passed"
