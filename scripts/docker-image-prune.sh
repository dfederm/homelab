#!/bin/bash
# docker-image-prune.sh - Remove Docker images that no container references.
#
# Renovate bumps a pinned image digest, the next deploy pulls the new image, and the
# superseded one stays on disk forever. Nothing ever removes it, so the Docker host's
# rootfs climbs monotonically until someone notices and cleans up by hand. This is
# the sweep that stops that.
#
# Why `-a` and not a plain prune: every service image here is pinned by digest
# (image: repo:tag@sha256:...), so Docker holds them by repo digest and `docker images`
# prints their tag as <none>. That looks dangling, but it isn't — and a plain prune
# removes only dangling images. Measured on this host: with 14.12 GB reported
# reclaimable, `docker image prune -f` freed 0 B. (That `-f` only skips the
# confirmation prompt; it forces nothing.) Only `-a`, which removes images not
# referenced by any container, actually reclaims them. The per-deploy
# `docker image prune -f` in run-service.sh is a different job and stays where it is:
# it clears the genuinely dangling leftovers of the locally-built webhook image.
#
# Safety: a container protects its image whether it is running or stopped, so the
# one-shot containers that exit after a deploy keep theirs. An
# image that is removed is always re-pullable - its digest is pinned in git - and a
# service whose container happens to be absent just re-pulls on its next deploy.
#
# Prefer `prune -a` over a hand-rolled `docker rmi` loop over unreferenced image IDs.
# `docker rmi <id>` refuses an image that carries several repository references or has
# dependent children, and forcing past that with `docker rmi -f` would also override
# the stopped-container protection above - which is the whole safety property. The
# listing pass below gives the audit trail that a manual loop was wanted for, without
# reimplementing the removal.
#
# Deliberately NOT done here:
#   - Volumes are never pruned, not even behind a flag. Service state belongs on ZFS
#     appdata bind-mounts, but a stray named volume has slipped through before and
#     cost unrecoverable data. Removing an image is reversible; removing a volume is not.
#   - Stopped containers are never reaped. A stopped container is legitimate state,
#     and reaping is the one action that could turn a protected image into a
#     removable one. Review leftovers by hand: docker ps -a --filter status=exited
#   - Build cache is left alone. It is a few dozen megabytes here - noise next to the
#     multi-gigabyte images this exists to reclaim - and clearing it would force the one
#     locally-built service (webhook) to rebuild from scratch on its next deploy,
#     producing new layer digests that Compose sees as a changed image and recreates the
#     container for. Weekly churn on the deploy path, for no meaningful space.
#
# Runs on the Docker host, from a systemd timer installed by the
# configure-docker-image-prune module. Deleting files inside an LXC does not hand the
# blocks back to the LVM thin pool - the host-side `pct fstrim` does that - so this
# is scheduled to land BEFORE the host's fstrim timer in the week (see
# DOCKER_IMAGE_PRUNE_SCHEDULE / LXC_FSTRIM_SCHEDULE in .env.template).
#
# A deploy running at the same moment is an accepted race: between `docker compose pull`
# and `docker compose up` a freshly pulled image is referenced by no container yet, so a
# sweep landing in that window can remove it. Compose pulls again when the image it
# needs is missing, so that gap heals itself. The narrower window inside a single
# `compose up` does not: images are resolved up front, so a service still waiting on a
# `depends_on` health gate fails to create with "No such image" rather than re-pulling,
# and the deploy log records it. The next deploy puts it right - the digest is pinned in
# git - and the schedule keeps the odds low. Nothing locks against it.
#
# Usage: docker-image-prune.sh [--dry-run]
#   --dry-run: list what would be removed, remove nothing.

set -euo pipefail

DRY_RUN=false
if [ "$#" -gt 1 ]; then
    echo "usage: $(basename "$0") [--dry-run]" >&2
    exit 2
fi
case "${1:-}" in
    --dry-run) DRY_RUN=true ;;
    "") ;;
    *) echo "usage: $(basename "$0") [--dry-run]" >&2; exit 2 ;;
esac

if ! command -v docker &> /dev/null; then
    echo "ERROR: docker not found; this runs on the Docker host only." >&2
    exit 1
fi

echo "=== Docker image prune: $(hostname) $(date '+%Y-%m-%d %H:%M:%S') ==="

docker system df || echo "WARNING: docker system df failed" >&2

# Report what is about to be removed before removing it, so the journal says which
# images went rather than only how many bytes came back. Same rule the prune itself
# applies: an image is in use if ANY container references it, in any state.
#
# This listing is a PREVIEW, not the record: `docker image prune -a` recomputes the set
# inside the daemon and never reads $REFS, and its own output below is what actually
# happened. So a failure here must not be allowed to cancel the reclaim. It can fail for
# ordinary reasons: `docker ps` takes a snapshot and `container inspect` runs a moment
# later, so a container that exits and is removed in that window (deploys use
# --remove-orphans, and one-shot containers come and go) makes inspect return non-zero,
# which under `pipefail` would otherwise abort the script before the prune ran. The two
# sets can also differ without either being wrong - the daemon additionally refuses an
# image that has dependent child images - so treat a line here as a candidate.
#
# `--digests` is required, not decorative: without it the CLI leaves {{.Digest}} empty
# for images that have a repo digest and no tag, which is precisely the population this
# job is about.
REFS=$(mktemp)
trap 'rm -f "$REFS"' EXIT

INVENTORY_OK=true
UNREFERENCED=""
if ! docker ps -aq | xargs -r docker container inspect --format '{{.Image}}' | sort -u > "$REFS"; then
    INVENTORY_OK=false
elif ! UNREFERENCED=$(docker images --no-trunc --digests --format '{{.ID}}\t{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.Digest}}' \
    | awk -F'\t' -v reffile="$REFS" '
        BEGIN { while ((getline line < reffile) > 0) used[line] = 1 }
        !($1 in used) { id = $1; sub(/^sha256:/, "", id); print $2 "  " substr(id, 1, 12) "  (" $3 ")  " $4 }' \
    | sort); then
    INVENTORY_OK=false
fi

echo ""
if [ "$INVENTORY_OK" != true ]; then
    # Deliberately not fatal, and deliberately not printed as a partial list: an
    # incomplete reference set over-reports images as unreferenced, which is the
    # misleading direction.
    echo "WARNING: could not list images and their containers; skipping the inventory." >&2
    echo "         The prune below is unaffected - the daemon computes its own set." >&2
elif [ -z "$UNREFERENCED" ]; then
    echo "No unreferenced images."
else
    echo "Removal candidates - no container in any state references these:"
    printf '%s\n' "$UNREFERENCED" | sed 's/^/  /'
    echo "  (one line per repository reference, so an image with several appears more"
    echo "   than once; sizes are per-image totals and count shared layers repeatedly."
    echo "   The prune output below is the record of what was actually removed.)"
fi
echo ""

if [ "$DRY_RUN" = true ]; then
    if [ "$INVENTORY_OK" != true ]; then
        echo "=== Docker image prune: dry run could not list candidates ===" >&2
        exit 1
    fi
    echo "=== Docker image prune complete (dry run; nothing removed) ==="
    exit 0
fi

docker image prune -a -f

echo ""
docker system df || true

echo "=== Docker image prune complete ==="
