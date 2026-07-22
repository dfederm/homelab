#!/bin/bash
# Module: Configure storage-space threshold alerting (Proxmox host only)
# Idempotent - generates a systemd service + timer, reloads/restarts only if changed.
#
# Installs a periodic check (scripts/storage-space-check.sh) that alerts on the
# two capacity numbers Beszel can't see because they aren't filesystems: the LVM
# thin pool data% and the ZFS pool capacity%. Runs on the Proxmox host, which is
# the only host that can read `lvs` (thin pool) and `zpool` (pool owner).
#
# The shared alert channel is a single Shoutrrr URL (HOMELAB_ALERT_SHOUTRRR_URL in
# common.env) - the same URL the Beszel hub and scrutiny use. Backend: Pushover
# (see artifacts/disk-monitoring-findings.md). This module also installs the
# shoutrrr CLI, which is the sender the check uses; if HOMELAB_ALERT_SHOUTRRR_URL
# is empty the check logs to syslog only, so deploying before the URL is set is safe.
#
# Relevant env vars are consumed by the check script itself (ZFS_POOL,
# STORAGE_ALERT_*, HOMELAB_ALERT_SHOUTRRR_URL).

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

CHECK_SCRIPT="$REPO_DIR/scripts/storage-space-check.sh"
SERVICE_FILE="/etc/systemd/system/homelab-storage-check.service"
TIMER_FILE="/etc/systemd/system/homelab-storage-check.timer"

if [ ! -f "$CHECK_SCRIPT" ]; then
    echo "ERROR: check script not found: $CHECK_SCRIPT" >&2
    exit 1
fi

# Install the shoutrrr CLI - the sender the storage check uses to deliver alerts
# through the shared Shoutrrr URL. nicholas-fedor/shoutrrr is the same fork Beszel
# embeds, so it parses HOMELAB_ALERT_SHOUTRRR_URL identically. The version below is
# kept current by Renovate (custom manager in renovate.json, github-releases
# datasource - it opens a PR to bump it like any Docker image), and the binary is
# verified against GitHub's published per-asset sha256 digest. Best-effort: a
# failure here does NOT fail the deploy - the check falls back to syslog meanwhile.
# renovate: datasource=github-releases depName=nicholas-fedor/shoutrrr
SHOUTRRR_VERSION="0.16.2"
ensure_shoutrrr() {
    local bin="/usr/local/bin/shoutrrr"
    local marker="/usr/local/bin/.shoutrrr-version"
    if [ -x "$bin" ] && [ "$(cat "$marker" 2>/dev/null)" = "$SHOUTRRR_VERSION" ]; then
        echo "shoutrrr $SHOUTRRR_VERSION already installed"
        return 0
    fi
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null || ! command -v tar &>/dev/null; then
        apt-get update -qq >/dev/null
        apt-get install -y -qq jq curl tar >/dev/null
    fi
    local repo="nicholas-fedor/shoutrrr"
    local tag="v${SHOUTRRR_VERSION}"
    local asset="shoutrrr_linux_amd64_${SHOUTRRR_VERSION}.tar.gz"
    local digest
    digest="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${repo}/releases/tags/${tag}" \
        | jq -r --arg n "$asset" '.assets[] | select(.name == $n) | .digest' \
        | sed 's/^sha256://')"
    if ! printf '%s' "$digest" | grep -qE '^[0-9a-f]{64}$'; then
        echo "  WARNING: could not get a sha256 digest for $asset @ ${tag} from GitHub" >&2
        return 1
    fi
    local tmp
    tmp="$(mktemp -d)"
    if ! curl -fsSL --retry 3 --retry-delay 2 \
        "https://github.com/${repo}/releases/download/${tag}/${asset}" -o "$tmp/$asset"; then
        rm -rf "$tmp"; echo "  WARNING: shoutrrr download failed" >&2; return 1
    fi
    if [ "$(sha256sum "$tmp/$asset" | cut -d' ' -f1)" != "$digest" ]; then
        rm -rf "$tmp"; echo "  WARNING: shoutrrr checksum mismatch" >&2; return 1
    fi
    if ! tar -xzf "$tmp/$asset" -C "$tmp" shoutrrr; then
        rm -rf "$tmp"; echo "  WARNING: shoutrrr extract failed" >&2; return 1
    fi
    if ! install -m 755 "$tmp/shoutrrr" "$bin"; then
        rm -rf "$tmp"; echo "  WARNING: shoutrrr install failed" >&2; return 1
    fi
    echo "$SHOUTRRR_VERSION" > "$marker"
    rm -rf "$tmp"
    echo "Installed shoutrrr $SHOUTRRR_VERSION (verified against GitHub digest)"
}

if ! ensure_shoutrrr; then
    echo "  WARNING: shoutrrr CLI unavailable; storage-space alerts log to syslog only until it installs."
fi

changed=0

# --- Service unit (oneshot; runs the check) ---

SERVICE_TEMP=$(mktemp)
cat > "$SERVICE_TEMP" <<EOF
[Unit]
Description=Homelab storage-space threshold check
After=network-online.target zfs.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${CHECK_SCRIPT}
EOF

if [ -f "$SERVICE_FILE" ] && cmp -s "$SERVICE_TEMP" "$SERVICE_FILE"; then
    rm "$SERVICE_TEMP"
    echo "storage-check service unchanged"
else
    mv "$SERVICE_TEMP" "$SERVICE_FILE"
    changed=1
    echo "storage-check service installed"
fi

# --- Timer unit (every 15 min, plus shortly after boot) ---

TIMER_TEMP=$(mktemp)
cat > "$TIMER_TEMP" <<EOF
[Unit]
Description=Run the homelab storage-space check periodically

[Timer]
OnBootSec=5min
OnCalendar=*:0/15
Persistent=true

[Install]
WantedBy=timers.target
EOF

if [ -f "$TIMER_FILE" ] && cmp -s "$TIMER_TEMP" "$TIMER_FILE"; then
    rm "$TIMER_TEMP"
    echo "storage-check timer unchanged"
else
    mv "$TIMER_TEMP" "$TIMER_FILE"
    changed=1
    echo "storage-check timer installed"
fi

if [ "$changed" = 1 ]; then
    systemctl daemon-reload
fi

# Ensure the timer is enabled and running (idempotent).
if ! systemctl is-enabled --quiet homelab-storage-check.timer; then
    systemctl enable homelab-storage-check.timer &>/dev/null
fi
if [ "$changed" = 1 ] || ! systemctl is-active --quiet homelab-storage-check.timer; then
    systemctl restart homelab-storage-check.timer
    echo "storage-check timer (re)started"
fi

echo "Storage-space alerting ready"
