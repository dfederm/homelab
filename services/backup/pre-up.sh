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

set -euo pipefail

: "${CONFIG_DIR:?CONFIG_DIR not set}"

# Instance list: the argument from run-service, or BACKUP_INSTANCES when run standalone.
INSTANCES="${1:-${BACKUP_INSTANCES:-}}"

# Read BACKUP_DEST for one target. Grep (not source): instance env files are docker
# --env-file KEY=VALUE format, where unquoted values with spaces (e.g. BACKUP_CRON=0 3 * * *)
# would break a shell source. Returns non-zero if the file or the key is absent.
get_dest() {
    local f="$CONFIG_DIR/backup/$1.env" v
    [ -f "$f" ] || return 1
    v=$(grep -E '^[[:space:]]*BACKUP_DEST=' "$f" | tail -n1) || return 1
    v=${v#*BACKUP_DEST=}            # strip the key
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
for inst in $INSTANCES; do
    if ! dest=$(get_dest "$inst"); then
        echo "  WARNING: no BACKUP_DEST for backup target '$inst' — skipping its disjointness check" >&2
        continue
    fi
    if [[ "$dest" != *:* ]]; then
        echo "ERROR: backup target '$inst' has BACKUP_DEST='$dest', not in remote:path form" >&2
        exit 1
    fi
    names+=("$inst")
    remotes+=("${dest%%:*}")
    paths+=("$(norm_path "${dest#*:}")")
done

conflict=0
count=${#names[@]}
for ((i = 0; i < count; i++)); do
    for ((j = i + 1; j < count; j++)); do
        [ "${remotes[i]}" = "${remotes[j]}" ] || continue
        if overlaps "${paths[i]}" "${paths[j]}"; then
            echo "ERROR: backup targets '${names[i]}' and '${names[j]}' have OVERLAPPING destinations on remote '${remotes[i]}':" >&2
            echo "         ${names[i]} -> ${remotes[i]}:/${paths[i]}" >&2
            echo "         ${names[j]} -> ${remotes[j]}:/${paths[j]}" >&2
            echo "       rclone sync prunes its dest, so one would delete the other's backup. Use disjoint paths." >&2
            conflict=1
        fi
    done
done

[ "$conflict" -eq 0 ] || exit 1
echo "  backup: destinations are disjoint ($count target(s) checked)"
