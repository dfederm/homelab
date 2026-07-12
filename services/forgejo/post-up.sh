#!/bin/bash
# Post-deploy hook: register the Actions runner's shared secret with Forgejo so the forgejo-runner
# container can connect. Idempotent — keyed on the uuid derived from FORGEJO_RUNNER_TOKEN, so every
# deploy just reconciles the existing runner.
#
# It's a post-up (not pre-up) hook because registration needs the forgejo container running. /data is
# on ZFS and persists across repaves, so a repaved host boots an already-installed forgejo and this
# registers in the same deploy; a brand-new forgejo with no persisted /data boots uninstalled (see the
# register loop below).
#
# Best-effort: a failure never breaks the deploy. The secret is piped via stdin so it never appears in
# a process argument list.

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:?CONFIG_DIR not set}"
ENV_FILE="${ENV_FILE:?ENV_FILE not set}"

# source_env exports only CONFIG_DIR/ENV_FILE; re-source the env files to get the secret.
set -a
# shellcheck disable=SC1090,SC1091
[ -f "$CONFIG_DIR/common.env" ] && . "$CONFIG_DIR/common.env"
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

if [ -z "${FORGEJO_RUNNER_TOKEN:-}" ]; then
    echo "  post-up: FORGEJO_RUNNER_TOKEN not set — skipping runner registration." >&2
    echo "           Generate one (openssl rand -hex 20) and add it to the env file to enable the runner." >&2
    exit 0
fi

# A malformed secret can never register — fail fast instead of burning the retry window below.
# Forgejo requires exactly 40 lowercase hex.
if ! printf '%s' "$FORGEJO_RUNNER_TOKEN" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "  post-up: FORGEJO_RUNNER_TOKEN is not a 40-char hex string — skipping runner registration." >&2
    echo "           Regenerate it (openssl rand -hex 20) and update the env file." >&2
    exit 0
fi

if ! command -v docker &> /dev/null; then
    echo "  ERROR: docker not found — forgejo post-up needs the docker CLI" >&2
    exit 1
fi

# Retry within a bounded window to ride out first-boot DB migrations; the runner retries its own
# connection meanwhile. A brand-new forgejo boots uninstalled (forgejo-cli errors "MustInstalled") —
# detect that and skip fast rather than waiting out the window.
#
# `--secret-stdin=stdin`, not a bare `--secret-stdin`: forgejo-cli treats it as a value-expecting flag
# (urfave/cli), so a bare terminal flag fails to parse ("flag needs an argument"). The value is
# ignored; the secret is read from stdin.
echo "  post-up: registering Forgejo Actions runner ..."
deadline=$(( $(date +%s) + 180 ))
while true; do
    if out=$(printf '%s' "$FORGEJO_RUNNER_TOKEN" \
                | docker exec -i --user git forgejo \
                    forgejo forgejo-cli actions register --keep-labels --name "$(hostname)" --secret-stdin=stdin 2>&1)
    then
        echo "  post-up: Forgejo Actions runner registered."
        break
    fi

    # Brand-new git host: forgejo isn't installed yet, so registration can't succeed — skip.
    if printf '%s' "$out" | grep -qiE 'mustinstalled|command to install forgejo'; then
        echo "  post-up: forgejo is not installed yet (brand-new git host, admin not claimed) —" >&2
        echo "           skipping runner registration. Complete first-run setup (claim the admin" >&2
        echo "           account at https://<FORGEJO_FQDN>/), then re-deploy; this hook registers the" >&2
        echo "           runner on that deploy." >&2
        exit 0
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "  WARNING: could not register the Forgejo runner within the wait window." >&2
        echo "           $out" >&2
        echo "           The deploy still succeeds; the runner keeps retrying its connection and the" >&2
        echo "           next deploy will register it. Check FORGEJO_RUNNER_TOKEN (40-char hex) and" >&2
        echo "           'docker logs forgejo'." >&2
        exit 0
    fi

    echo "  post-up: forgejo not ready yet, retrying registration ..." >&2
    sleep 3
done
