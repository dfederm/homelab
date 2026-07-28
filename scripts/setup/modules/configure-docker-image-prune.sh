#!/bin/bash
# Module: configure-docker-image-prune (Docker host only)
#
# Schedules a periodic sweep of Docker images that no container references
# (scripts/docker-image-prune.sh). Digest-pinned images are replaced, never removed:
# Renovate bumps a pinned digest, the deploy pulls the new image, and the superseded
# one stays on disk forever, so this host's rootfs climbs monotonically until a human
# cleans it by hand. The sweep is the automated half of that cleanup.
#
# Docker-host-only, which is the structural difference from configure-lxc-fstrim: the
# images live in this machine's Docker storage, so the reclaim has to happen here. The
# module fails if Docker is missing rather than skipping, because a schedule silently
# installed on a machine that cannot run it is worse than a failed deploy — so list it
# after install-docker in HOMELAB_SETUP_MODULES.
#
# Ordering matters, and nothing enforces it but the schedules: freeing files inside an
# LXC does not return the blocks to the LVM thin pool - only `pct fstrim` from the
# Proxmox host does that. So DOCKER_IMAGE_PRUNE_SCHEDULE must land BEFORE the host's
# LXC_FSTRIM_SCHEDULE in the week, or the space sits reclaimed-but-not-returned for a
# further week. The defaults in .env.template (prune Sunday, trim Monday) do that.
#
# Schedule semantics (mirrors configure-lxc-fstrim): a NON-EMPTY
# DOCKER_IMAGE_PRUNE_SCHEDULE enables the timer on that systemd OnCalendar; an EMPTY
# (or unset) value DISABLES it and removes any previously-installed unit. The
# recommended default lives in .env.template.
#
# Idempotent: generated units are compared (cmp) before replacing; the timer is
# only (re)started when something actually changed.
#
# Env vars:
#   REPO_DIR                     (required, set by setup.sh) repo path on this host
#   DOCKER_IMAGE_PRUNE_SCHEDULE  systemd OnCalendar for the sweep; empty = disabled.
#                                Recommended: weekly, before LXC_FSTRIM_SCHEDULE.

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

validate_env REPO_DIR

DOCKER_IMAGE_PRUNE_SCHEDULE="${DOCKER_IMAGE_PRUNE_SCHEDULE:-}"

PRUNE_SCRIPT="$REPO_DIR/scripts/docker-image-prune.sh"
SERVICE_FILE="/etc/systemd/system/homelab-docker-image-prune.service"
TIMER_FILE="/etc/systemd/system/homelab-docker-image-prune.timer"

if [ ! -f "$PRUNE_SCRIPT" ]; then
    echo "ERROR: prune script not found: $PRUNE_SCRIPT" >&2
    exit 1
fi

if [ -n "$DOCKER_IMAGE_PRUNE_SCHEDULE" ] && ! command -v docker &> /dev/null; then
    echo "ERROR: docker not found; configure-docker-image-prune belongs on the Docker host." >&2
    exit 1
fi

DAEMON_RELOAD=false

# Write $1 (a temp file) to $2 only if different. Echoes "changed" when it
# replaced the destination, "unchanged" otherwise.
install_if_changed() {
    local tmp="$1" dest="$2"
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        echo "unchanged"
    else
        mv "$tmp" "$dest"
        echo "changed"
    fi
}

# Disable + remove a systemd unit if it exists (used when the feature is disabled).
remove_unit() {
    local unit="$1"
    if [ -f "/etc/systemd/system/$unit" ]; then
        systemctl disable --now "$unit" > /dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$unit"
        DAEMON_RELOAD=true
        echo "  removed $unit"
    fi
}

if [ -n "$DOCKER_IMAGE_PRUNE_SCHEDULE" ]; then
    TEMP_UNIT=$(mktemp)
    cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=Homelab periodic Docker image prune
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash ${PRUNE_SCRIPT}
EOF
    [ "$(install_if_changed "$TEMP_UNIT" "$SERVICE_FILE")" = "changed" ] && DAEMON_RELOAD=true

    TEMP_UNIT=$(mktemp)
    cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=Homelab Docker image prune timer

[Timer]
OnCalendar=${DOCKER_IMAGE_PRUNE_SCHEDULE}
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF
    [ "$(install_if_changed "$TEMP_UNIT" "$TIMER_FILE")" = "changed" ] && DAEMON_RELOAD=true
else
    remove_unit homelab-docker-image-prune.timer
    remove_unit homelab-docker-image-prune.service
fi

if [ "$DAEMON_RELOAD" = true ]; then
    systemctl daemon-reload
    echo "  systemd units updated"
else
    echo "  systemd units unchanged"
fi

# Enable/start the timer only when the feature is configured (idempotent).
if [ -n "$DOCKER_IMAGE_PRUNE_SCHEDULE" ]; then
    systemctl enable --now homelab-docker-image-prune.timer > /dev/null
fi

echo "Docker image prune configured (schedule: '${DOCKER_IMAGE_PRUNE_SCHEDULE:-disabled}')"
