#!/bin/bash
# Module: configure-scrutiny-collector
#
# Host-level (Proxmox host) Scrutiny metrics collector. Scrutiny's collector
# needs direct access to the physical disks (it runs `smartctl` on each drive), so
# it must run where the disks physically live: the bare-metal host. The Scrutiny
# web UI + InfluxDB backend run as a normal container service on the Docker host
# (see services/scrutiny/) — only the collector lives here.
#
# Because the Proxmox host runs no Docker, the collector is installed as Scrutiny's
# official standalone binary, run on a systemd timer. Each run reads SMART data and
# POSTs it to the Scrutiny web API.
#
# Note: this collector only READS SMART data — it does NOT initiate self-tests.
# Scheduled self-tests are owned by smartd (configure-storage-health), so the two
# are complementary and never double-schedule tests.
#
# VERSION LOCKSTEP (no manual bump): the collector version is DERIVED from the
# Scrutiny web image tag pinned in services/scrutiny/docker-compose.yml — the single
# source of truth that Renovate already bumps. The downloaded binary is verified
# against GitHub's published per-asset sha256 digest for that exact version
# (fail-closed). So when Renovate bumps the web image, the collector follows on the
# next deploy automatically; there is no second version/checksum to keep in sync.
#
# Idempotent: the binary is only (re)downloaded + verified when the installed version
# (recorded in a marker file) differs from the desired version; the systemd units are
# compared (cmp) before replace.
#
# Env vars:
#   SCRUTINY_COLLECTOR_API_ENDPOINT (required) URL of the Scrutiny web API, e.g.
#                                   http://<docker-host-ip>:<SCRUTINY_WEB_PORT>
#   REPO_DIR                        (required, set by setup.sh)
#   SCRUTINY_COLLECTOR_SCHEDULE     OnCalendar for collection cadence; EMPTY (or unset)
#                                   disables automatic collection (the collector service
#                                   unit is still installed for manual runs, but the
#                                   timer is removed). Recommended: *:0/15 (every 15 min).

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

validate_env SCRUTINY_COLLECTOR_API_ENDPOINT REPO_DIR

SCRUTINY_COLLECTOR_SCHEDULE="${SCRUTINY_COLLECTOR_SCHEDULE:-}"
BIN_PATH="/usr/local/bin/scrutiny-collector-metrics"
VERSION_MARKER="/usr/local/bin/.scrutiny-collector-version"
COMPOSE_FILE="$REPO_DIR/services/scrutiny/docker-compose.yml"
GITHUB_REPO="AnalogJ/scrutiny"

# --- Derive the desired collector version from the web image tag (single source) ---
# Matches e.g.  image: ghcr.io/analogj/scrutiny:v0.9.2-web@sha256:...  ->  v0.9.2
IMAGE_TAG="$(grep -E 'image:[[:space:]]*ghcr\.io/analogj/scrutiny:' "$COMPOSE_FILE" \
    | head -n1 | sed -E 's/.*scrutiny:([^@[:space:]]+).*/\1/')"
COLLECTOR_VERSION="${IMAGE_TAG%-web}"
if ! printf '%s' "$COLLECTOR_VERSION" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "ERROR: could not derive a valid Scrutiny version from $COMPOSE_FILE (got '$IMAGE_TAG')" >&2
    exit 1
fi

# Map machine architecture to the release asset suffix.
case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) echo "ERROR: unsupported architecture $(uname -m) for Scrutiny collector" >&2; exit 1 ;;
esac
ASSET="scrutiny-collector-metrics-linux-${ARCH}"

# The collector shells out to smartctl; jq parses the GitHub release metadata.
apt-get update -qq > /dev/null
apt-get install -y -qq smartmontools curl jq > /dev/null

# (Re)install the binary only when the desired version differs from what's installed.
installed_version=""
[ -f "$VERSION_MARKER" ] && installed_version="$(cat "$VERSION_MARKER")"

if [ "$installed_version" = "$COLLECTOR_VERSION" ] && [ -x "$BIN_PATH" ]; then
    echo "Scrutiny collector ${COLLECTOR_VERSION} already installed"
else
    echo "Installing Scrutiny collector ${COLLECTOR_VERSION} (${ARCH})..."

    # Authoritative integrity source: GitHub's published per-asset sha256 digest for
    # this exact release. No checksum is hardcoded in the repo.
    expected_sha="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${COLLECTOR_VERSION}" \
        | jq -r --arg name "$ASSET" '.assets[] | select(.name == $name) | .digest' \
        | sed 's/^sha256://')"
    if ! printf '%s' "$expected_sha" | grep -qE '^[0-9a-f]{64}$'; then
        echo "ERROR: could not obtain a sha256 digest for $ASSET @ ${COLLECTOR_VERSION} from GitHub" >&2
        exit 1
    fi

    TMP_BIN=$(mktemp)
    curl -fsSL -o "$TMP_BIN" \
        "https://github.com/${GITHUB_REPO}/releases/download/${COLLECTOR_VERSION}/${ASSET}"
    actual_sha="$(sha256sum "$TMP_BIN" | cut -d' ' -f1)"
    if [ "$actual_sha" != "$expected_sha" ]; then
        rm -f "$TMP_BIN"
        echo "ERROR: checksum mismatch for collector binary" >&2
        echo "  expected (GitHub): $expected_sha" >&2
        echo "  actual:            $actual_sha" >&2
        exit 1
    fi
    chmod +x "$TMP_BIN"
    mv "$TMP_BIN" "$BIN_PATH"
    echo "$COLLECTOR_VERSION" > "$VERSION_MARKER"
    echo "  installed $BIN_PATH (verified against GitHub digest)"
fi

DAEMON_RELOAD=false

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

# Disable + remove a systemd unit if it exists (used when collection is turned off).
remove_unit() {
    local unit="$1"
    if [ -f "/etc/systemd/system/$unit" ]; then
        systemctl disable --now "$unit" > /dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$unit"
        DAEMON_RELOAD=true
        echo "  removed $unit"
    fi
}

# Collector service — one-shot SMART collection that POSTs to the Scrutiny web API.
TEMP_UNIT=$(mktemp)
cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=Homelab Scrutiny SMART metrics collector
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=COLLECTOR_API_ENDPOINT=${SCRUTINY_COLLECTOR_API_ENDPOINT}
Environment=COLLECTOR_HOST_ID=$(hostname)
ExecStart=${BIN_PATH} run
EOF
[ "$(install_if_changed "$TEMP_UNIT" /etc/systemd/system/homelab-scrutiny-collector.service)" = "changed" ] && DAEMON_RELOAD=true

# Collector timer — gated by SCRUTINY_COLLECTOR_SCHEDULE (empty = no automatic collection).
if [ -n "$SCRUTINY_COLLECTOR_SCHEDULE" ]; then
    TEMP_UNIT=$(mktemp)
    cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=Homelab Scrutiny SMART metrics collector timer

[Timer]
OnCalendar=${SCRUTINY_COLLECTOR_SCHEDULE}
Persistent=true
RandomizedDelaySec=1m

[Install]
WantedBy=timers.target
EOF
    [ "$(install_if_changed "$TEMP_UNIT" /etc/systemd/system/homelab-scrutiny-collector.timer)" = "changed" ] && DAEMON_RELOAD=true
else
    remove_unit homelab-scrutiny-collector.timer
fi

if [ "$DAEMON_RELOAD" = true ]; then
    systemctl daemon-reload
    echo "  systemd units updated"
else
    echo "  systemd units unchanged"
fi

if [ -n "$SCRUTINY_COLLECTOR_SCHEDULE" ]; then
    systemctl enable --now homelab-scrutiny-collector.timer > /dev/null
fi

echo "Scrutiny collector configured (version ${COLLECTOR_VERSION}, endpoint: ${SCRUTINY_COLLECTOR_API_ENDPOINT}, schedule: '${SCRUTINY_COLLECTOR_SCHEDULE:-disabled}')"
