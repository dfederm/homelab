#!/bin/bash
# backup-service-state.sh — stage application-consistent copies of service state.
#
# The existing cloud sync (services/backup) is a plain `rclone sync` from a bare
# rclone image. That is the right tool for *files*, but it cannot produce a
# consistent copy of live service state: an rclone container has no access to
# another container's binaries, so it cannot run `forgejo dump` or `pg_dump`, and
# copying a database's files out from under a running server yields a backup that
# looks fine and fails on restore.
#
# This script fills that gap. It runs on the Docker host, produces a consistent
# copy of each configured piece of state into a staging tree, and then stops — the
# staging tree is shipped offsite by an ordinary services/backup target pointed at
# SERVICE_BACKUP_ROOT. Dump here, ship there; one mechanism per concern.
#
# Output paths are STABLE (no per-run dated directories) so the follow-on rclone
# sync only uploads what actually changed — a dated tree would re-upload every
# byte nightly. Retaining the copy a sync would otherwise destroy is that sync's
# job, via BACKUP_ARCHIVE_DEST (rclone --backup-dir), which keeps the most recent
# superseded copy of each file remotely at no upload cost.
#
# Each job that produces a dump file writes to a `.part` and renames it into place
# only on success, so a failed or interrupted run can never replace a good backup
# with a truncated one. A `path` job instead mirrors in place (deletions deferred to
# the end of the transfer) and is protected by refusing a missing or empty source —
# the realistic way it would destroy a good copy is a bind mount that did not
# populate. Jobs are independent: one failure does not abort the others, and the run
# exits non-zero (and alerts) with the full list of what failed.
#
# Env vars:
#   SERVICE_BACKUP_ROOT   (required) staging dir; one subdirectory per job
#   SERVICE_BACKUP_JOBS   space-separated list of job PREFIXES (see below);
#                         empty = nothing to do
#   HOMELAB_ALERT_SHOUTRRR_URL  shared alert channel (optional; logs if unset)
#
# Each prefix P in SERVICE_BACKUP_JOBS defines one job:
#   P_TYPE      path | sqlite | postgres | forgejo   (required)
#   P_NAME      staging subdirectory name (default: lowercased prefix)
#
#   type=path      P_PATH       absolute source dir/file, mirrored with rsync
#   type=sqlite    P_PATH       absolute path to the .db file
#   type=postgres  P_CONTAINER  container name
#                  P_DB_NAME    database name
#                  P_DB_USER    database user
#   type=forgejo   P_CONTAINER  container name
#                  P_USER       exec user   (default: git)
#                  P_CONFIG     app.ini path inside the container
#                               (default: /data/gitea/conf/app.ini)
#                  P_TEMPDIR    scratch dir inside the container (default:
#                               /data/tmp). Must be on the container's persistent
#                               volume, NOT its writable layer: the dump is
#                               assembled there and the writable layer is on the
#                               LXC rootfs, whose thin pool a multi-GB dump can
#                               fill.

set -euo pipefail

SCRIPT=$(readlink -f "$0")
REPO_DIR=$(dirname "$(dirname "$SCRIPT")")
export REPO_DIR

source "$REPO_DIR/scripts/lib.sh"
source_env

# Any non-zero exit must reach the alert channel, not just the journal. Several checks
# below abort before the job loop, and nothing in the lab polls `systemctl --failed` —
# without this, a run that dies on a config error goes completely unannounced while the
# cloud sync keeps shipping an increasingly stale staging tree.
run_alerted=false
on_exit() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$run_alerted" = false ]; then
        send_alert "homelab backup" \
            "Service-state backup aborted on $(hostname) (exit $rc) before it could report per-job results. The offsite copy of this state is now stale. See: journalctl -u homelab-service-backup.service" || true
    fi
}
# A signalled death needs its own trap: the EXIT trap still runs, but $? inside it is 0
# for a signal, so it would stay silent while the run dies. That is precisely the
# TimeoutStartSec path — systemd sends SIGTERM — plus `systemctl stop`, LXC shutdown and
# reboot-mid-run, i.e. the cases most likely to stop backups indefinitely.
on_abort() {
    local sig="$1" code="$2"
    run_alerted=true
    send_alert "homelab backup" \
        "Service-state backup was TERMINATED by SIG${sig} on $(hostname) (timeout, shutdown or manual stop). The staging tree may be incomplete and the offsite copy is now stale. See: journalctl -u homelab-service-backup.service" || true
    exit "$code"
}
trap 'on_abort TERM 143' TERM
trap 'on_abort INT 130' INT
trap on_exit EXIT

SERVICE_BACKUP_JOBS="${SERVICE_BACKUP_JOBS:-}"

if [ -z "$SERVICE_BACKUP_JOBS" ]; then
    echo "No SERVICE_BACKUP_JOBS configured, nothing to do"
    exit 0
fi

validate_env SERVICE_BACKUP_ROOT

# rsync --delete runs against a path derived from this root, so a root that is
# relative, or is "/", would point the mirror somewhere destructive.
case "$SERVICE_BACKUP_ROOT" in
    /) echo "ERROR: SERVICE_BACKUP_ROOT must not be /" >&2; exit 1 ;;
    /*) ;;
    *) echo "ERROR: SERVICE_BACKUP_ROOT must be an absolute path (got '$SERVICE_BACKUP_ROOT')" >&2; exit 1 ;;
esac

# A symlinked root would let the mkdir/chmod below, and every job's writes, land
# somewhere other than the audited path.
if [ -L "$SERVICE_BACKUP_ROOT" ]; then
    echo "ERROR: SERVICE_BACKUP_ROOT must not be a symlink: $SERVICE_BACKUP_ROOT" >&2
    exit 1
fi

# Staging inside appdata would put the tree inside the very data some jobs mirror, so a
# path job could recurse into its own output and the cloud target would ship appdata twice.
case "${DOCKER_APPDATA_ROOT:-}" in
    "") ;;
    *) case "$SERVICE_BACKUP_ROOT/" in
           "${DOCKER_APPDATA_ROOT%/}/"*)
               echo "ERROR: SERVICE_BACKUP_ROOT must not live inside DOCKER_APPDATA_ROOT" >&2
               exit 1
               ;;
       esac ;;
esac

# Create it private, but never re-chmod a directory that already existed: the value is
# operator-supplied, and silently changing the mode of an existing directory is exactly
# the kind of side effect a backup script must not have. Drift is reported, not "fixed".
if [ ! -d "$SERVICE_BACKUP_ROOT" ]; then
    mkdir -p "$SERVICE_BACKUP_ROOT"
    # The tree holds database dumps and, typically, a copy of the config dir — i.e. every
    # credential in the lab — under a ZFS path that is also published as an admin SMB share.
    chmod 700 "$SERVICE_BACKUP_ROOT"
else
    # Compare only the permission triad: stat reports 4 digits when a setgid/sticky bit is
    # set (2700 on a setgid dir), which chmod 700 preserves — so a plain string compare
    # would warn about a directory this script created itself.
    root_mode="$(stat -c '%a' "$SERVICE_BACKUP_ROOT" 2>/dev/null)"
    if [ "${root_mode: -3}" != "700" ]; then
        echo "  WARNING: $SERVICE_BACKUP_ROOT is mode ${root_mode:-?}, not 700; it holds database dumps and secrets." >&2
    fi
fi

# Read "${prefix}_${suffix}", falling back to $3 when unset/empty.
job_var() {
    local name="${1}_${2}"
    echo "${!name:-${3:-}}"
}

# Every handler below checks its own commands explicitly and returns non-zero on
# failure. It must NOT lean on `set -e`: these are invoked as `handler ... || status=failed`,
# and bash disables errexit inside a function called in a `||` list — so a failed dump
# would otherwise fall through to the rename and report success, replacing a good
# backup with an empty one. (Observed: a `pg_dump` against a dead container still
# produced a valid-looking 20-byte gzip.) Nothing is renamed into place unless the
# command succeeded AND produced a non-empty file.

# Mirror a directory (or copy a single file) verbatim. For state that is plain
# files — no database engine holding it open — where a byte copy is a valid
# backup. Fails if the source is missing rather than mirroring emptiness onto a
# good backup.
backup_path() {
    local prefix="$1" dest="$2" src
    src="$(job_var "$prefix" PATH)"
    [ -n "$src" ] || { echo "  ERROR: ${prefix}_PATH is not set" >&2; return 1; }
    [ -e "$src" ] || { echo "  ERROR: source does not exist: $src" >&2; return 1; }
    # "Exists" and even "is not empty" are both too weak. A bind mount that did not
    # populate frequently leaves the directory skeleton behind, and `ls -A` counts those
    # empty subdirectories as content — so the check has to reach an actual FILE. Without
    # this, rsync mirrors the skeleton over the staged copy and the next sync propagates
    # the deletion offsite.
    if [ -d "$src" ] && [ -z "$(find "$src" -type f -print -quit 2>/dev/null)" ]; then
        echo "  ERROR: source directory contains no files (only empty directories?): $src" >&2
        return 1
    fi
    # Single-file source: the same reasoning, one level down — a zero-byte file is the
    # file-shaped version of an unpopulated mount.
    if [ -f "$src" ] && [ ! -s "$src" ]; then
        echo "  ERROR: source file is empty: $src" >&2
        return 1
    fi

    mkdir -p "$dest" || return 1
    # Trailing slash on a directory source copies its contents (not the dir
    # itself) into dest, so the staging layout stays <root>/<name>/<contents>.
    if [ -d "$src" ]; then
        src="${src%/}/"
    fi
    # --delete-after, not plain --delete: deletions happen only once every file has
    # transferred, so an interrupted run can't leave the mirror missing files it
    # already removed.
    if ! rsync -a --delete-after "$src" "$dest/"; then
        echo "  ERROR: rsync failed for $src" >&2
        return 1
    fi
}

# Copy a SQLite database with sqlite3's online backup API, which takes a read
# lock and produces a transactionally consistent file while the service keeps
# writing. A plain `cp` of a live SQLite database can capture a torn page or miss
# the -wal, producing a file that only fails at restore time.
#
# -readonly guarantees the backup can never modify the live database (without it
# sqlite may checkpoint the WAL or roll back a hot journal). A failure here
# therefore means "no consistent read was possible", which is worth surfacing
# rather than silently downgrading to a byte copy.
backup_sqlite() {
    local prefix="$1" dest="$2" src out
    src="$(job_var "$prefix" PATH)"
    [ -n "$src" ] || { echo "  ERROR: ${prefix}_PATH is not set" >&2; return 1; }
    [ -f "$src" ] || { echo "  ERROR: SQLite database not found: $src" >&2; return 1; }

    mkdir -p "$dest" || return 1
    out="$dest/$(basename "$src")"
    rm -f "$out.part"
    if ! sqlite3 -readonly "$src" ".backup '$out.part'"; then
        echo "  ERROR: sqlite3 backup failed for $src" >&2
        rm -f "$out.part"
        return 1
    fi
    # Two probes, because they catch different failures and neither catches both.
    # quick_check rejects a truncated or corrupt copy. It does NOT reject a
    # structurally valid but EMPTY database — measured: a 0-page source backs up to a
    # file that reports "ok" — so the object count is what catches "the source was an
    # unpopulated database". This is the same vacuous-guard shape already found in the
    # gzip and tar.gz handlers, where size alone proved meaningless.
    if [ "$(sqlite3 "$out.part" 'PRAGMA quick_check;' 2>/dev/null | head -n 1)" != "ok" ]; then
        echo "  ERROR: sqlite3 backup of $src did not pass quick_check" >&2
        rm -f "$out.part"
        return 1
    fi
    local objects
    objects="$(sqlite3 "$out.part" 'SELECT count(*) FROM sqlite_master;' 2>/dev/null)"
    if ! [[ "$objects" =~ ^[0-9]+$ ]] || [ "$objects" -lt 1 ]; then
        echo "  ERROR: sqlite3 backup of $src contains no tables (source database is empty?)" >&2
        rm -f "$out.part"
        return 1
    fi
    mv -f "$out.part" "$out"
}

# Dump a PostgreSQL database with pg_dump inside its own container, so the dump
# is taken by a client of exactly the server's version and is transactionally
# consistent. --clean --if-exists makes the dump restorable over an existing
# database. Deliberately no `docker exec -t`: a TTY would translate newlines and
# corrupt the piped output.
backup_postgres() {
    local prefix="$1" dest="$2" container db user out
    container="$(job_var "$prefix" CONTAINER)"
    db="$(job_var "$prefix" DB_NAME)"
    user="$(job_var "$prefix" DB_USER)"
    [ -n "$container" ] && [ -n "$db" ] && [ -n "$user" ] || {
        echo "  ERROR: ${prefix}_CONTAINER, ${prefix}_DB_NAME and ${prefix}_DB_USER are all required" >&2
        return 1
    }

    mkdir -p "$dest" || return 1
    out="$dest/${db}.sql.gz"
    rm -f "$out.part"
    # pipefail makes a pg_dump failure fail the whole pipeline even though gzip
    # succeeds on the empty input it gets.
    if ! docker exec "$container" pg_dump --clean --if-exists \
        --dbname="$db" --username="$user" | gzip > "$out.part"; then
        echo "  ERROR: pg_dump failed for database '$db' in container '$container'" >&2
        rm -f "$out.part"
        return 1
    fi
    # A file-size check cannot backstop that: gzip emits a ~20-byte header even for
    # empty input, so an empty dump still looks like a plausible file. Inspect the
    # DECOMPRESSED bytes instead. head bounds the read, so this stays cheap on a
    # large dump, and the exit status of the pipeline is deliberately not consulted
    # (head closing the pipe early would look like a failure).
    if [ -z "$(gzip -dc "$out.part" 2>/dev/null | head -c 200)" ]; then
        echo "  ERROR: pg_dump produced an empty dump for database '$db'" >&2
        rm -f "$out.part"
        return 1
    fi
    # Nor is "decompresses to something" enough: pg_dump of a database with ZERO
    # objects still emits a few hundred bytes of SET/comment preamble, which sails past
    # any byte-count check. Require at least one table definition, so a dump taken
    # against an empty or wrong database cannot replace a real one.
    if [ "$(gzip -dc "$out.part" 2>/dev/null | grep -m1 -c '^CREATE TABLE' || true)" != "1" ]; then
        echo "  ERROR: pg_dump of '$db' contains no table definitions (empty or wrong database?)" >&2
        rm -f "$out.part"
        return 1
    fi
    mv -f "$out.part" "$out"
}

# Dump Forgejo with its own `forgejo dump`, which captures the database, repos,
# LFS, packages (the OCI registry) and config as one restorable archive. A file
# copy of the data dir is not equivalent: the database is live underneath it.
#
# --file - streams the archive to stdout so it lands directly in the staging tree
# instead of inside the container.
backup_forgejo() {
    local prefix="$1" dest="$2" container user config tempdir out
    container="$(job_var "$prefix" CONTAINER)"
    [ -n "$container" ] || { echo "  ERROR: ${prefix}_CONTAINER is not set" >&2; return 1; }
    user="$(job_var "$prefix" USER git)"
    config="$(job_var "$prefix" CONFIG /data/gitea/conf/app.ini)"
    tempdir="$(job_var "$prefix" TEMPDIR /data/tmp)"

    mkdir -p "$dest" || return 1
    out="$dest/forgejo-dump.tar.gz"
    rm -f "$out.part"
    if ! docker exec -u "$user" "$container" mkdir -p "$tempdir"; then
        echo "  ERROR: could not create temp dir '$tempdir' in container '$container'" >&2
        return 1
    fi
    if ! docker exec -u "$user" "$container" forgejo dump \
        --config "$config" --tempdir "$tempdir" \
        --type tar.gz --file - --quiet > "$out.part"; then
        echo "  ERROR: forgejo dump failed in container '$container'" >&2
        rm -f "$out.part"
        return 1
    fi
    # A size check is not a backstop here: an EMPTY tar.gz is still ~120 bytes of
    # header and padding, so a dump of nothing looks like a plausible archive. Verify
    # the archive actually parses and contains at least one member. head bounds the
    # read, and the pipeline's exit status is deliberately not consulted (head closing
    # the pipe early would look like a failure).
    if [ -z "$(tar -tzf "$out.part" 2>/dev/null | head -n 1)" ]; then
        echo "  ERROR: forgejo dump produced an empty or unreadable archive" >&2
        rm -f "$out.part"
        return 1
    fi
    # "Parses and has members" is still too weak — an archive carrying only app.ini
    # satisfies it. The database dump is the irreplaceable member, so require it by
    # name (gitea- covers the upstream naming this tool inherited).
    if [ -z "$(tar -tzf "$out.part" 2>/dev/null | grep -m1 -E '(^|/)(forgejo|gitea)-db\.sql$' || true)" ]; then
        echo "  ERROR: forgejo dump contains no database dump (forgejo-db.sql missing)" >&2
        rm -f "$out.part"
        return 1
    fi
    mv -f "$out.part" "$out"
}

echo "=== Service-state backup: $(hostname) $(date '+%Y-%m-%d %H:%M:%S') ==="

failed=()
seen_names=""
manifest="$SERVICE_BACKUP_ROOT/backup-manifest.txt"
manifest_tmp="$(mktemp)"
{
    echo "# Service-state backup staged by scripts/backup-service-state.sh"
    echo "# host: $(hostname)   completed: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "# Restore procedure per job type is documented in README.md."
    echo ""
} > "$manifest_tmp"

for prefix in $SERVICE_BACKUP_JOBS; do
    # Validate the prefix before any indirect expansion: `${!name}` on a prefix
    # containing e.g. a hyphen is a bad substitution that aborts the whole run under
    # `set -u`, which would break the per-job independence the rest of this loop provides.
    if ! [[ "$prefix" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "--- $prefix ---"
        echo "  ERROR: invalid job prefix '$prefix' (must be a shell-variable-safe name)" >&2
        failed+=("$prefix")
        continue
    fi

    type="$(job_var "$prefix" TYPE)"
    name="$(job_var "$prefix" NAME "$(echo "$prefix" | tr 'A-Z_' 'a-z-')")"
    dest="$SERVICE_BACKUP_ROOT/$name"

    echo "--- $prefix (type: ${type:-<unset>}) -> $name ---"

    # The name becomes the second half of a path that rsync --delete-after writes to,
    # so a value containing a slash or ".." would aim that mirror outside the staging
    # root — the same hazard SERVICE_BACKUP_ROOT is checked for above. Requiring the
    # first character to be alphanumeric also rules out "..", "." and hidden names.
    # Deliberately [[ =~ ]] and not grep: grep matches line-by-line, so a name
    # containing a newline would pass with only its first line examined.
    if ! [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        echo "  ERROR: invalid ${prefix}_NAME '$name' (allowed: letters, digits, . _ -; must start alphanumeric)" >&2
        failed+=("$prefix")
        printf '%-24s %-10s %-8s %s\n' "$prefix" "${type:-?}" "FAILED" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$manifest_tmp"
        continue
    fi

    # Two jobs sharing a name share a staging directory, where the second silently
    # destroys the first's output — leaving a backup that looks complete and is
    # missing a service.
    case " $seen_names " in
        *" $name "*)
            echo "  ERROR: staging name '$name' is already used by an earlier job" >&2
            failed+=("$prefix")
            printf '%-24s %-10s %-8s %s\n' "$prefix" "${type:-?}" "FAILED" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$manifest_tmp"
            continue
            ;;
    esac
    seen_names="$seen_names $name"

    status=ok
    case "$type" in
        path)     backup_path "$prefix" "$dest" || status=failed ;;
        sqlite)   backup_sqlite "$prefix" "$dest" || status=failed ;;
        postgres) backup_postgres "$prefix" "$dest" || status=failed ;;
        forgejo)  backup_forgejo "$prefix" "$dest" || status=failed ;;
        "")       echo "  ERROR: ${prefix}_TYPE is not set" >&2; status=failed ;;
        *)        echo "  ERROR: unknown ${prefix}_TYPE '$type'" >&2; status=failed ;;
    esac

    if [ "$status" = ok ]; then
        echo "  ok ($(du -sh "$dest" 2>/dev/null | cut -f1) staged)"
        printf '%-24s %-10s %-8s %s\n' "$name" "$type" \
            "$(du -sh "$dest" 2>/dev/null | cut -f1)" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$manifest_tmp"
    else
        echo "  FAILED"
        failed+=("$name")
        printf '%-24s %-10s %-8s %s\n' "$name" "$type" "FAILED" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$manifest_tmp"
    fi
done

# The manifest ships with the backup, so a restorer can see what the last run
# actually produced — and how old it is, which is the only on-site signal that
# the timer silently stopped running.
mv -f "$manifest_tmp" "$manifest"
chmod 644 "$manifest"

if [ "${#failed[@]}" -gt 0 ]; then
    run_alerted=true
    send_alert "homelab backup" \
        "Service-state backup FAILED on $(hostname) for: ${failed[*]}. The offsite copy of this state is now stale. See: journalctl -u homelab-service-backup.service" || true
    echo "=== Service-state backup FAILED (${failed[*]}) ===" >&2
    exit 1
fi

echo "=== Service-state backup complete ==="
