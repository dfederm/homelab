#!/bin/bash
# Module: Install the Beszel monitoring agent natively (binary + systemd unit)
# Idempotent - installs the pinned binary, verifies its integrity, and
# regenerates the systemd unit only when it changes (restarting only then).
#
# For hosts that DON'T run Docker (the Proxmox host and the NAS LXC) and therefore
# can't use the Docker `monitoring-agent` service. These are exactly the hosts
# whose disk usage matters most: the Proxmox host owns the host root, the LVM thin
# pool, and the ZFS pool; the NAS LXC serves the file shares. The agent reports
# per-mount disk usage to the same Beszel hub the Docker agents use.
#
# Targets amd64 hosts (the Proxmox host and NAS LXC). An arm-based host (e.g. a
# Raspberry Pi) uses the Docker agent instead, so this module intentionally only
# ships the linux/amd64 binary.
#
# VERSION LOCKSTEP (no manual bump): the agent version is DERIVED from the
# henrygd/beszel-agent image tag pinned in services/monitoring-agent/docker-compose.yml
# - the single source of truth Renovate already bumps (the "beszel" group). The
# downloaded binary is verified against GitHub's published per-asset sha256 digest
# for that exact version (fail-closed). So when Renovate bumps the image, the native
# agent follows on the next deploy; there is no second version/checksum to keep in sync.
#
# Required env vars:
#   BESZEL_AGENT_KEY   - Hub public SSH key (shared by all agents; common.env)
#   BESZEL_AGENT_PORT  - Port the agent listens on (matches the Docker agent)
#   REPO_DIR           - Repo root (set by setup.sh; used to read the compose pin)
#
# Optional env vars:
#   BESZEL_AGENT_EXTRA_FILESYSTEMS  - Comma-separated extra mountpoints to
#                                     monitor beyond the root filesystem, e.g.
#                                     "/tank/data,/tank/media". Each may
#                                     use "path__Name" to set a display name.

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

validate_env BESZEL_AGENT_KEY BESZEL_AGENT_PORT REPO_DIR

EXTRA_FILESYSTEMS="${BESZEL_AGENT_EXTRA_FILESYSTEMS:-}"

AGENT_DIR="/opt/beszel-agent"
BIN_PATH="$AGENT_DIR/beszel-agent"
VERSION_STAMP="$AGENT_DIR/.installed-version"
SERVICE_FILE="/etc/systemd/system/beszel-agent.service"
COMPOSE_FILE="$REPO_DIR/services/monitoring-agent/docker-compose.yml"
GITHUB_REPO="henrygd/beszel"
ASSET="beszel-agent_linux_amd64.tar.gz"

# Derive the desired version from the agent image tag - the single source of
# truth Renovate bumps. Matches e.g.
#   image: henrygd/beszel-agent:0.18.7@sha256:...  ->  0.18.7
AGENT_VERSION="$(grep -E 'image:[[:space:]]*henrygd/beszel-agent:' "$COMPOSE_FILE" \
    | head -n1 | sed -E 's|.*beszel-agent:([^@[:space:]]+).*|\1|')"
if ! printf '%s' "$AGENT_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "ERROR: could not derive a valid Beszel version from $COMPOSE_FILE (got '$AGENT_VERSION')" >&2
    exit 1
fi
RELEASE_TAG="v${AGENT_VERSION}"

arch="$(uname -m)"
if [ "$arch" != "x86_64" ]; then
    echo "ERROR: install-beszel-agent targets amd64 hosts; found $arch." >&2
    echo "  (The arm RPi uses the Docker monitoring-agent service instead.)" >&2
    exit 1
fi

# Ensure download tools exist (apt skips already-installed packages).
# jq parses the GitHub release metadata for the per-asset digest.
if ! command -v curl &>/dev/null || ! command -v tar &>/dev/null || ! command -v jq &>/dev/null; then
    apt-get update -qq > /dev/null
    apt-get install -y -qq curl tar jq > /dev/null
fi

# Dedicated unprivileged service user.
if ! id -u beszel &>/dev/null; then
    useradd --system --home-dir /nonexistent --shell /bin/false beszel
    echo "Created user: beszel"
fi

# Persistent machine fingerprint for the hub (matches upstream installer).
if [ ! -f /etc/machine-id ]; then
    tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id
fi

mkdir -p "$AGENT_DIR"

# --- Install/upgrade the binary (skip if already at the derived version) ---

if [ -x "$BIN_PATH" ] && [ "$(cat "$VERSION_STAMP" 2>/dev/null)" = "$AGENT_VERSION" ]; then
    echo "beszel-agent v$AGENT_VERSION already installed"
    binary_changed=0
else
    echo "Installing beszel-agent v$AGENT_VERSION..."

    # Authoritative integrity source: GitHub's published per-asset sha256 digest
    # for this exact release. No checksum is hardcoded in the repo.
    expected_sha="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${RELEASE_TAG}" \
        | jq -r --arg name "$ASSET" '.assets[] | select(.name == $name) | .digest' \
        | sed 's/^sha256://')"
    if ! printf '%s' "$expected_sha" | grep -qE '^[0-9a-f]{64}$'; then
        echo "ERROR: could not obtain a sha256 digest for $ASSET @ ${RELEASE_TAG} from GitHub" >&2
        exit 1
    fi

    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT
    curl -fsSL --retry 3 --retry-delay 2 \
        "https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}/${ASSET}" -o "$tmp_dir/$ASSET"

    actual_sha="$(sha256sum "$tmp_dir/$ASSET" | cut -d' ' -f1)"
    if [ "$actual_sha" != "$expected_sha" ]; then
        echo "ERROR: checksum mismatch for $ASSET ($actual_sha != $expected_sha)" >&2
        exit 1
    fi

    tar -xzf "$tmp_dir/$ASSET" -C "$tmp_dir" beszel-agent
    install -o beszel -g beszel -m 755 "$tmp_dir/beszel-agent" "$BIN_PATH"
    echo "$AGENT_VERSION" > "$VERSION_STAMP"
    rm -rf "$tmp_dir"
    trap - EXIT
    binary_changed=1
    echo "Installed beszel-agent v$AGENT_VERSION (verified against GitHub digest)"
fi

# --- Generate the systemd unit (regenerate + restart only if changed) ---

TEMP_FILE=$(mktemp)
{
    cat <<EOF
[Unit]
Description=Beszel Agent Service
Wants=network-online.target
After=network-online.target

[Service]
Environment="LISTEN=${BESZEL_AGENT_PORT}"
Environment="KEY=${BESZEL_AGENT_KEY}"
EOF
    if [ -n "$EXTRA_FILESYSTEMS" ]; then
        echo "Environment=\"EXTRA_FILESYSTEMS=${EXTRA_FILESYSTEMS}\""
    fi
    cat <<EOF
ExecStart=${BIN_PATH}
User=beszel
Restart=on-failure
RestartSec=5
StateDirectory=beszel-agent
EOF
    # The hardening directives below rely on mount namespacing, which fails inside
    # an LXC (systemd exits 226/NAMESPACE and the agent crash-loops). Apply them only
    # on bare-metal/VM hosts; in a container the agent still runs as the unprivileged
    # `beszel` user, matching the Docker agent's posture.
    if ! systemd-detect-virt --container --quiet; then
        cat <<EOF

# Security/sandboxing (bare-metal/VM only; read-only access suffices for metrics)
KeyringMode=private
LockPersonality=yes
ProtectClock=yes
ProtectHome=read-only
ProtectHostname=yes
ProtectKernelLogs=yes
ProtectSystem=strict
RemoveIPC=yes
RestrictSUIDSGID=true
EOF
    fi
    cat <<EOF

[Install]
WantedBy=multi-user.target
EOF
} > "$TEMP_FILE"

if [ -f "$SERVICE_FILE" ] && cmp -s "$TEMP_FILE" "$SERVICE_FILE"; then
    rm "$TEMP_FILE"
    unit_changed=0
    echo "beszel-agent service unchanged"
else
    mv "$TEMP_FILE" "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable beszel-agent.service &>/dev/null
    unit_changed=1
    echo "beszel-agent service installed"
fi

# Restart if the binary or unit changed; otherwise ensure it's running.
if [ "$binary_changed" = 1 ] || [ "$unit_changed" = 1 ]; then
    systemctl restart beszel-agent.service
    echo "beszel-agent restarted"
elif ! systemctl is-active --quiet beszel-agent.service; then
    systemctl start beszel-agent.service
    echo "beszel-agent started"
fi

# Verify it actually came up. A failed unit auto-restarts (Restart=on-failure), so
# `systemctl restart` can return 0 while the agent is crash-looping; fail loudly here.
sleep 1
if ! systemctl is-active --quiet beszel-agent.service; then
    echo "ERROR: beszel-agent is not active after start; recent status:" >&2
    systemctl --no-pager --lines=15 status beszel-agent.service >&2 || true
    exit 1
fi

echo "Beszel agent ready on port ${BESZEL_AGENT_PORT}"
