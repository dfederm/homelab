#!/bin/bash
# Pre-deploy hook for Radicale: make the secret files mounted into the container readable by
# the Radicale process. tomsquest/docker-radicale runs radicale as a non-root user (uid 2999)
# and its entrypoint only chowns /data, never /config — so the bind-mounted htpasswd `users`
# and `rights` files must be readable by "other" (o+r) or auth/rights silently fail. Files
# newly created in the NAS config dir inherit a restrictive default ACL (no others-read), so
# this re-applies o+r on every deploy. Idempotent: chmod o+r is a no-op once already set.
#
# Also guards against a missing file: Docker would turn a missing bind-mount source into an
# empty directory, which breaks Radicale (htpasswd_filename / rights file would point at a dir).

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:?CONFIG_DIR not set}"
RADICALE_CONFIG_DIR="$CONFIG_DIR/radicale"

for f in users rights; do
    path="$RADICALE_CONFIG_DIR/$f"
    if [ ! -f "$path" ]; then
        echo "  ERROR: required Radicale file missing: $path" >&2
        echo "  Create it before deploying (see the Radicale section in README.md and rights.example)." >&2
        exit 1
    fi
    chmod o+r "$path"
done

echo "  pre-up: ensured Radicale users + rights are readable by the container (o+r)"
