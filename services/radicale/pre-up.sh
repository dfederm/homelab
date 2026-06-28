#!/bin/bash
# Pre-deploy hook for Radicale. Radicale runs inside the container as a non-root user
# (uid/gid 2999 in tomsquest/docker-radicale), which creates two environment-specific needs
# this hook handles before "docker compose up":
#
#  1. Readable config. The bind-mounted files must be readable by "other" (uid 2999): the
#     committed ./config plus the secret `users` (htpasswd) and `rights` files on the NAS.
#     New files in the ZFS-backed repo / config dirs inherit a default ACL without others-read,
#     so re-apply o+r on every deploy. Also guards that the two secret files exist — a missing
#     bind-mount source would be created by Docker as a directory and break Radicale.
#
#  2. Writable data owned by uid 2999. The image's own chown (TAKE_FILE_OWNERSHIP) is disabled
#     in docker-compose.yml because, under this container's dropped capabilities, it cannot
#     chown bind-mounted ZFS files to uid 2999 (EPERM) and crash-loops. So create and own the
#     data dir here from the host side — this runs as LXC root, which can chown to 2999.
#
# Idempotent: the chmod / chown calls are no-ops once already applied.

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:?CONFIG_DIR not set}"
ENV_FILE="${ENV_FILE:?ENV_FILE not set}"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# tomsquest/docker-radicale's baked-in radicale user (Dockerfile BUILD_UID/BUILD_GID default).
RADICALE_UID=2999
RADICALE_GID=2999

# 1a. Committed config must be readable by the container user.
chmod o+r "$SCRIPT_DIR/config"

# 1b. Secret files must exist and be readable by the container user.
for f in users rights; do
    path="$CONFIG_DIR/radicale/$f"
    if [ ! -f "$path" ]; then
        echo "  ERROR: required Radicale file missing: $path" >&2
        echo "  Create it before deploying (see the Radicale section in README.md and rights.example)." >&2
        exit 1
    fi
    chmod o+r "$path"
done

# 2. Data dir owned by the radicale user so it can write collections. DOCKER_APPDATA_ROOT comes
#    from the env files (source_env only exports CONFIG_DIR/ENV_FILE), so load them here.
set -a
# shellcheck disable=SC1090,SC1091
[ -f "$CONFIG_DIR/common.env" ] && . "$CONFIG_DIR/common.env"
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
: "${DOCKER_APPDATA_ROOT:?DOCKER_APPDATA_ROOT not set}"

data_dir="$DOCKER_APPDATA_ROOT/radicale"
mkdir -p "$data_dir"
chown -R "$RADICALE_UID:$RADICALE_GID" "$data_dir"

echo "  pre-up: Radicale config/users/rights readable (o+r); data dir owned by $RADICALE_UID:$RADICALE_GID"
