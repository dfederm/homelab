#!/bin/bash
# Module: configure-deploy-worker
#
# Installs target-local signaling, serialization, and periodic reconciliation.
# Enable only on top-level deploy targets, not LXCs owned by create-lxcs.
#
# Required env vars:
#   REPO_DIR
#   DEPLOY_REPOSITORY_URL
#
# Optional env vars:
#   DEPLOY_STATE_DIR                 default /var/lib/homelab-deploy
#   DEPLOY_BOOT_DELAY_SEC            default 60
#   DEPLOY_RECONCILE_INTERVAL_SEC    default 900

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"
source "$REPO_DIR/scripts/deploy-state.sh"

validate_env REPO_DIR DEPLOY_REPOSITORY_URL

DEPLOY_STATE_DIR="${DEPLOY_STATE_DIR:-/var/lib/homelab-deploy}"
DEPLOY_BOOT_DELAY_SEC="${DEPLOY_BOOT_DELAY_SEC:-60}"
DEPLOY_RECONCILE_INTERVAL_SEC="${DEPLOY_RECONCILE_INTERVAL_SEC:-900}"

if ! deploy_state_validate_absolute_path "$DEPLOY_STATE_DIR"; then
    echo "ERROR: DEPLOY_STATE_DIR must be a safe absolute path" >&2
    exit 1
fi
for value in "$DEPLOY_BOOT_DELAY_SEC" "$DEPLOY_RECONCILE_INTERVAL_SEC"; do
    if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: deployment timer intervals must be positive integers" >&2
        exit 1
    fi
done

PACKAGES=()
command -v flock &>/dev/null || PACKAGES+=(util-linux)
command -v git &>/dev/null || PACKAGES+=(git)
if [ ${#PACKAGES[@]} -gt 0 ]; then
    apt_get update -qq >/dev/null
    apt_get install -y -qq "${PACKAGES[@]}" >/dev/null
fi

INSTALL_DIR="${DEPLOY_WORKER_INSTALL_DIR:-/usr/local/lib/homelab}"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
SERVICE_FILE="$SYSTEMD_UNIT_DIR/homelab-deploy-worker.service"
PATH_FILE="$SYSTEMD_UNIT_DIR/homelab-deploy-worker.path"
TIMER_FILE="$SYSTEMD_UNIT_DIR/homelab-deploy-worker.timer"
mkdir -p "$INSTALL_DIR" "$SYSTEMD_UNIT_DIR" "$DEPLOY_STATE_DIR"

install_file_if_changed() {
    local source_file="$1"
    local destination="$2"
    local mode="$3"
    local tmp

    tmp=$(mktemp)
    cp "$source_file" "$tmp"
    chmod "$mode" "$tmp"
    if [ -f "$destination" ] && cmp -s "$tmp" "$destination"; then
        rm -f "$tmp"
        echo "unchanged"
    else
        mv "$tmp" "$destination"
        echo "changed"
    fi
}

changed=false
for script in deploy-worker.sh deploy-signal.sh; do
    [ "$(install_file_if_changed "$REPO_DIR/scripts/$script" \
        "$INSTALL_DIR/$script" 755)" = "changed" ] && changed=true
done
[ "$(install_file_if_changed "$REPO_DIR/scripts/deploy-state.sh" \
    "$INSTALL_DIR/deploy-state.sh" 644)" = "changed" ] && changed=true

TEMP_UNIT=$(mktemp)
cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=Apply the latest homelab deployment
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $INSTALL_DIR/deploy-worker.sh
EOF
[ "$(install_file_if_changed "$TEMP_UNIT" "$SERVICE_FILE" 644)" = "changed" ] \
    && changed=true
rm -f "$TEMP_UNIT"

TEMP_UNIT=$(mktemp)
cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=Wake the homelab deployment worker for pending signals

[Path]
PathExists=$DEPLOY_STATE_DIR/pending
Unit=homelab-deploy-worker.service

[Install]
WantedBy=multi-user.target
EOF
[ "$(install_file_if_changed "$TEMP_UNIT" "$PATH_FILE" 644)" = "changed" ] \
    && changed=true
rm -f "$TEMP_UNIT"

TEMP_UNIT=$(mktemp)
cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=Reconcile the latest homelab deployment

[Timer]
OnBootSec=${DEPLOY_BOOT_DELAY_SEC}s
OnUnitInactiveSec=${DEPLOY_RECONCILE_INTERVAL_SEC}s
Unit=homelab-deploy-worker.service

[Install]
WantedBy=timers.target
EOF
[ "$(install_file_if_changed "$TEMP_UNIT" "$TIMER_FILE" 644)" = "changed" ] \
    && changed=true
rm -f "$TEMP_UNIT"

if [ "$changed" = true ]; then
    systemctl daemon-reload
    echo "Deployment worker files updated"
else
    echo "Deployment worker files unchanged"
fi

systemctl enable --now homelab-deploy-worker.path \
    homelab-deploy-worker.timer >/dev/null
echo "Deployment worker configured"
