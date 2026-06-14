#!/bin/bash
# Post-deploy hook for a Minecraft world: apply per-world init commands (e.g. gamerules)
# once the server has finished starting. Invoked by run-service.sh as: post-up.sh <instance>
#
# Reads console commands, one per line, from <CONFIG_DIR>/minecraft/<instance>.init
# (blank lines and lines starting with '#' are ignored). Idempotent: gamerules persist in
# the world, so re-running simply re-applies them. Requires MINECRAFT_ALLOW_CHEATS=true.

set -euo pipefail

INSTANCE="${1:?instance name required}"
CONTAINER="minecraft-${INSTANCE}"
INIT_FILE="${CONFIG_DIR:?CONFIG_DIR not set}/minecraft/${INSTANCE}.init"

if [ ! -f "$INIT_FILE" ]; then
    exit 0
fi

# Wait for the world to finish loading before sending console commands.
ready=0
for _ in $(seq 1 40); do
    logs="$(docker logs "$CONTAINER" 2>&1 || true)"
    if grep -q "Server started" <<<"$logs"; then
        ready=1
        break
    fi
    sleep 3
done

if [ "$ready" -ne 1 ]; then
    echo "  WARNING: $CONTAINER not ready; init commands will apply on the next deploy"
    exit 0
fi

while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in '#'*) continue ;; esac
    echo "  init: $line"
    docker exec "$CONTAINER" send-command "$line"
done < "$INIT_FILE"