#!/bin/bash
# Pre-deploy guard for the backup service. Invoked once by run-service.sh before any
# instance is (re)deployed: pre-up.sh "<space-separated instance list>".
#
# rclone sync MIRRORS and PRUNES its destination, so if two targets' BACKUP_DEST overlap
# on the same remote (one path is equal to, or an ancestor of, the other) the ancestor's
# sync silently DELETES the other target's backup. This refuses the deploy (non-zero exit
# aborts run-service) before any destructive sync can run — enforcing the disjoint-dest
# rule instead of only documenting it.
#
# Reads each target's BACKUP_DEST from <CONFIG_DIR>/backup/<instance>.env (the documented
# per-target location). Destinations on DIFFERENT remotes never conflict (separate drives).
#
# A target's optional BACKUP_ARCHIVE_DEST (rclone --backup-dir, where superseded files are
# kept) is checked as an additional path: it holds the only copy of anything the sync has
# already replaced, so another target pruning over it destroys exactly the history it exists
# to preserve. rclone also refuses a --backup-dir inside its own destination, which the same
# pairwise check catches.

set -euo pipefail

: "${CONFIG_DIR:?CONFIG_DIR not set}"

# Instance list: the argument from run-service, or BACKUP_INSTANCES when run standalone.
INSTANCES="${1:-${BACKUP_INSTANCES:-}}"

# Read one KEY for one target. Grep (not source): instance env files are docker
# --env-file KEY=VALUE format, where unquoted values with spaces (e.g. BACKUP_CRON=0 3 * * *)
# would break a shell source. Returns non-zero if the file or the key is absent.
get_var() {
    local f="$CONFIG_DIR/backup/$1.env" key="$2" v
    [ -f "$f" ] || return 1
    v=$(grep -E "^[[:space:]]*${key}=" "$f" | tail -n1) || return 1
    v=${v#*"${key}"=}               # strip the key
    v=${v%$'\r'}                    # strip a trailing CR (CRLF files)
    v="${v%"${v##*[![:space:]]}"}"  # rtrim trailing whitespace
    case "$v" in                    # strip one layer of surrounding quotes
        \"*\") v=${v#\"}; v=${v%\"} ;;
        \'*\') v=${v#\'}; v=${v%\'} ;;
    esac
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# Normalize an rclone path: drop leading/trailing slashes so "/x", "x" and "x/" compare equal.
norm_path() {
    local p="${1#/}"
    printf '%s' "${p%/}"
}

# Do two normalized paths (already known to share a remote) overlap? Overlap = equal, or one
# is a path-boundary ancestor of the other (so "nas-backup" vs "nas-backup/x" conflicts, but
# "nas-backup" vs "nas-backup-shared" does not). An empty path is the remote root → overlaps all.
overlaps() {
    local a="$1" b="$2"
    [ -z "$a" ] && return 0
    [ -z "$b" ] && return 0
    [ "$a" = "$b" ] && return 0
    case "$b/" in "$a/"*) return 0 ;; esac
    case "$a/" in "$b/"*) return 0 ;; esac
    return 1
}

names=() remotes=() paths=()

# Record one "remote:path" that this deploy will write to, under a human label.
add_dest() {
    local label="$1" dest="$2"
    if [[ "$dest" != *:* ]]; then
        echo "ERROR: $label has destination '$dest', not in remote:path form" >&2
        exit 1
    fi
    names+=("$label")
    remotes+=("${dest%%:*}")
    paths+=("$(norm_path "${dest#*:}")")
}

for inst in $INSTANCES; do
    if ! dest=$(get_var "$inst" BACKUP_DEST); then
        echo "  WARNING: no BACKUP_DEST for backup target '$inst' — skipping its disjointness check" >&2
        continue
    fi
    add_dest "backup target '$inst'" "$dest"
    if archive=$(get_var "$inst" BACKUP_ARCHIVE_DEST); then
        # rclone requires --backup-dir to live on the same remote as the destination;
        # pointed elsewhere it fails at run time, every night, on a target whose whole
        # job is to be there when something has already gone wrong.
        if [ "${archive%%:*}" != "${dest%%:*}" ]; then
            echo "ERROR: backup target '$inst' has BACKUP_ARCHIVE_DEST on remote '${archive%%:*}'" >&2
            echo "       but BACKUP_DEST on remote '${dest%%:*}'. rclone --backup-dir must use the same remote." >&2
            exit 1
        fi
        add_dest "backup target '$inst' (archive)" "$archive"
    fi
done

conflict=0
count=${#names[@]}
for ((i = 0; i < count; i++)); do
    for ((j = i + 1; j < count; j++)); do
        [ "${remotes[i]}" = "${remotes[j]}" ] || continue
        if overlaps "${paths[i]}" "${paths[j]}"; then
            echo "ERROR: ${names[i]} and ${names[j]} have OVERLAPPING destinations on remote '${remotes[i]}':" >&2
            echo "         ${names[i]} -> ${remotes[i]}:/${paths[i]}" >&2
            echo "         ${names[j]} -> ${remotes[j]}:/${paths[j]}" >&2
            echo "       rclone sync prunes its dest, so one would delete the other's backup. Use disjoint paths." >&2
            conflict=1
        fi
    done
done

[ "$conflict" -eq 0 ] || exit 1
echo "  backup: destinations are disjoint ($count path(s) checked)"
