#!/bin/bash
# Apply pending signals and reconcile a target with the latest origin/main.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
source "$SCRIPT_DIR/deploy-state.sh"

deploy_state_load_env

DEPLOY_REPOSITORY_URL="${DEPLOY_REPOSITORY_URL:-}"
HOMELAB_REPO_DIR="${HOMELAB_REPO_DIR:-/opt/homelab/repo}"
DEPLOY_STATE_DIR="${DEPLOY_STATE_DIR:-/var/lib/homelab-deploy}"
DEPLOY_LOG_DIR="${DEPLOY_LOG_DIR:-/var/log/homelab-deploy}"
DEPLOY_RETENTION_DAYS="${DEPLOY_RETENTION_DAYS:-30}"

if [ -z "$DEPLOY_REPOSITORY_URL" ]; then
    echo "ERROR: DEPLOY_REPOSITORY_URL must be set" >&2
    exit 1
fi
for path in "$HOMELAB_REPO_DIR" "$DEPLOY_STATE_DIR" "$DEPLOY_LOG_DIR"; do
    if ! deploy_state_validate_absolute_path "$path"; then
        echo "ERROR: deployment paths must be safe absolute paths: $path" >&2
        exit 1
    fi
done
if ! [[ "$DEPLOY_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: DEPLOY_RETENTION_DAYS must be a non-negative integer" >&2
    exit 1
fi

mkdir -p "$DEPLOY_STATE_DIR" "$DEPLOY_LOG_DIR" /run/lock

WORKER_LOCK_FILE="${HOMELAB_DEPLOY_WORKER_LOCK:-/run/lock/homelab-deploy-worker.lock}"
mkdir -p "$(dirname "$WORKER_LOCK_FILE")"
exec 8> "$WORKER_LOCK_FILE"
if ! flock -n 8; then
    echo "Deployment worker already active"
    exit 0
fi

SETUP_LOCK_FILE="${HOMELAB_SETUP_LOCK_FILE:-/run/lock/homelab-setup.lock}"
mkdir -p "$(dirname "$SETUP_LOCK_FILE")"
exec 7> "$SETUP_LOCK_FILE"
flock 7

event() {
    deploy_state_append_event "$DEPLOY_STATE_DIR/events.log" "$@"
}

claim_signal() {
    local signaled=false

    exec 9> "$DEPLOY_STATE_DIR/state.lock"
    flock 9
    if [ -f "$DEPLOY_STATE_DIR/pending" ] \
        || [ -f "$DEPLOY_STATE_DIR/retry-signal" ] \
        || [ -f "$DEPLOY_STATE_DIR/active-signal" ]; then
        deploy_state_atomic_write "$DEPLOY_STATE_DIR/active-signal" \
            "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        rm -f "$DEPLOY_STATE_DIR/pending" "$DEPLOY_STATE_DIR/retry-signal" \
            || return $?
        signaled=true
    fi
    flock -u 9
    exec 9>&-

    printf '%s\n' "$signaled"
}

complete_signal() {
    exec 9> "$DEPLOY_STATE_DIR/state.lock"
    flock 9
    rm -f "$DEPLOY_STATE_DIR/active-signal"
    flock -u 9
    exec 9>&-
}

retry_signal() {
    exec 9> "$DEPLOY_STATE_DIR/state.lock"
    flock 9
    if [ -f "$DEPLOY_STATE_DIR/active-signal" ]; then
        mv "$DEPLOY_STATE_DIR/active-signal" \
            "$DEPLOY_STATE_DIR/retry-signal"
    fi
    flock -u 9
    exec 9>&-
}

pending_signal_exists() {
    local pending=false

    exec 9> "$DEPLOY_STATE_DIR/state.lock"
    flock 9
    [ -f "$DEPLOY_STATE_DIR/pending" ] && pending=true
    flock -u 9
    exec 9>&-

    [ "$pending" = true ]
}

install_fresh_checkout() {
    local reason="$1"
    local parent temp backup=""

    parent=$(dirname "$HOMELAB_REPO_DIR")
    mkdir -p "$parent"

    temp=$(mktemp -d "$parent/.homelab-repo.XXXXXX")
    rm -rf "$temp"
    if ! git clone --branch main --single-branch \
        "$DEPLOY_REPOSITORY_URL" "$temp"; then
        rm -rf "$temp"
        return 1
    fi

    if [ -e "$HOMELAB_REPO_DIR" ] || [ -L "$HOMELAB_REPO_DIR" ]; then
        backup="${HOMELAB_REPO_DIR}.corrupt.$(date -u '+%Y%m%dT%H%M%SZ').$$"
        mv "$HOMELAB_REPO_DIR" "$backup"
    fi
    if ! mv "$temp" "$HOMELAB_REPO_DIR"; then
        [ -z "$backup" ] || mv "$backup" "$HOMELAB_REPO_DIR"
        return 1
    fi
    [ -z "$backup" ] || rm -rf "$backup"
    event checkout-created "path=$HOMELAB_REPO_DIR" "reason=$reason"
}

sync_checkout() {
    git -C "$HOMELAB_REPO_DIR" remote set-url origin \
        "$DEPLOY_REPOSITORY_URL" || return
    git -C "$HOMELAB_REPO_DIR" fetch --prune origin \
        '+refs/heads/main:refs/remotes/origin/main' >&2 || return
    git -C "$HOMELAB_REPO_DIR" reset --hard origin/main >&2 || return
    git -C "$HOMELAB_REPO_DIR" clean -fdx >&2
}

prepare_checkout() {
    local reusable=true

    if [ -L "$HOMELAB_REPO_DIR" ] \
        || ! git -C "$HOMELAB_REPO_DIR" rev-parse --is-inside-work-tree \
            &>/dev/null \
        || ! git -C "$HOMELAB_REPO_DIR" remote get-url origin &>/dev/null; then
        reusable=false
    fi

    if [ "$reusable" = false ]; then
        install_fresh_checkout invalid || return
        sync_checkout || return
    elif ! sync_checkout; then
        event checkout-rebuild "path=$HOMELAB_REPO_DIR"
        install_fresh_checkout sync-failed || return
        sync_checkout || return
    fi

    git -C "$HOMELAB_REPO_DIR" rev-parse 'HEAD^{commit}'
}

while true; do
    SIGNALED=$(claim_signal)
    status=0
    set +e
    DESIRED_COMMIT=$(prepare_checkout)
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
        [ "$SIGNALED" = false ] || retry_signal
        event fetch-failure "status=$status" "trigger=$SIGNALED"
        exit "$status"
    fi
    if ! deploy_state_validate_commit "$DESIRED_COMMIT"; then
        [ "$SIGNALED" = false ] || retry_signal
        echo "ERROR: origin/main did not resolve to a commit" >&2
        exit 1
    fi

    APPLIED_COMMIT=""
    APPLIED_COMMIT=$(deploy_state_read_commit \
        "$DEPLOY_STATE_DIR/last-success" 2>/dev/null || true)

    if [ "$SIGNALED" = false ] && [ "$DESIRED_COMMIT" = "$APPLIED_COMMIT" ]; then
        event reconcile-noop "commit=$DESIRED_COMMIT"
        deploy_state_cleanup_logs "$DEPLOY_LOG_DIR" "$DEPLOY_RETENTION_DAYS"
        exit 0
    fi

    RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-${DESIRED_COMMIT:0:12}-$$"
    RUN_LOG="$DEPLOY_LOG_DIR/$RUN_ID.log"
    TRIGGER=reconcile
    [ "$SIGNALED" = true ] && TRIGGER=signal

    event run-start \
        "run=$RUN_ID" \
        "desired=$DESIRED_COMMIT" \
        "applied=${APPLIED_COMMIT:-none}" \
        "trigger=$TRIGGER"
    {
        echo "=== Homelab deployment run ==="
        echo "Run: $RUN_ID"
        echo "Desired commit: $DESIRED_COMMIT"
        echo "Previously successful: ${APPLIED_COMMIT:-none}"
        echo "Trigger: $TRIGGER"
        echo ""
    } > "$RUN_LOG"

    status=0
    set +e
    HOMELAB_SETUP_LOCK_HELD=1 \
        bash "$HOMELAB_REPO_DIR/scripts/setup/setup.sh" \
        2>&1 | tee -a "$RUN_LOG"
    status=${PIPESTATUS[0]}
    set -e

    if [ "$status" -ne 0 ]; then
        [ "$SIGNALED" = false ] || retry_signal
        event run-failure \
            "run=$RUN_ID" \
            "commit=$DESIRED_COMMIT" \
            "status=$status"
        printf '\n=== Deployment failed (status %s) ===\n' "$status" \
            >> "$RUN_LOG"
        deploy_state_cleanup_logs "$DEPLOY_LOG_DIR" "$DEPLOY_RETENTION_DAYS"
        exit "$status"
    fi

    deploy_state_atomic_write "$DEPLOY_STATE_DIR/last-success" \
        "$DESIRED_COMMIT"
    [ "$SIGNALED" = false ] || complete_signal
    event run-success "run=$RUN_ID" "applied=$DESIRED_COMMIT"
    printf '\n=== Deployment succeeded ===\n' >> "$RUN_LOG"
    deploy_state_cleanup_logs "$DEPLOY_LOG_DIR" "$DEPLOY_RETENTION_DAYS"

    if pending_signal_exists; then
        event trailing-run "previous=$DESIRED_COMMIT"
        continue
    fi
    exit 0
done
