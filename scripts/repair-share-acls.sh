#!/bin/bash
# repair-share-acls.sh — One-off remediation for share content with stale
# ownership / ACLs (e.g. files migrated from another NAS where UIDs/GIDs
# and ACLs don't match this system's scheme).
#
# This is NOT a setup module. It is intentionally not idempotent-on-every-run
# work — it walks the entire selected subtree. Use it once after a migration,
# or whenever you discover a directory whose contents predate the current
# ACL scheme.
#
# It mirrors the rules defined by scripts/setup/modules/set-share-permissions.sh,
# but applies them RECURSIVELY to existing content instead of only top-level
# dirs + default ACLs. If you change the rules in that module, mirror them
# in the JOBS list below.
#
# Usage:
#   bash scripts/repair-share-acls.sh [--apply] [target]
#
#   --apply   Actually change ownership / modes / ACLs. Without this flag the
#             script only reports what would change (dry run).
#   target    Optional. Path to limit the repair to. May be:
#               - relative to SHARE_ROOT (e.g. "adults", "adults/Documents", "alice")
#               - an absolute path under any managed root (e.g. "/mnt/media/Movies")
#             Defaults to all top-level dirs the setup module manages.
#
# Examples:
#   bash scripts/repair-share-acls.sh                       # dry-run, all managed roots
#   bash scripts/repair-share-acls.sh adults/Documents      # dry-run, a file-share subtree
#   bash scripts/repair-share-acls.sh --apply adults        # apply to adults/
#   bash scripts/repair-share-acls.sh --apply /mnt/media    # apply to media share
#   bash scripts/repair-share-acls.sh --apply /mnt/homelab/config    # apply to homelab config dir
#
# Run this inside the NAS LXC (where SHARE_ROOT is mounted and the users/groups
# exist), as root.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}
export REPO_DIR

# shellcheck source=lib.sh
source "$REPO_DIR/scripts/lib.sh"

# Load env (SHARE_ROOT, HOMELAB_USERS, *_GROUPS) the same way setup.sh does
source_env

validate_env SHARE_ROOT HOMELAB_USERS

APPLY=0
TARGET=""
for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        -h|--help)
            # Print the leading comment block (everything from line 2 up to but
            # not including the first non-`#` / non-blank line).
            awk 'NR>1 && /^[^#]/ && !/^$/ {exit} NR>1 {sub(/^# ?/, ""); print}' "$0"
            exit 0
            ;;
        --*)
            echo "ERROR: unknown flag: $arg" >&2
            exit 1
            ;;
        *)
            if [ -n "$TARGET" ]; then
                echo "ERROR: only one subdir argument is allowed" >&2
                exit 1
            fi
            TARGET="$arg"
            ;;
    esac
done

if [ "$APPLY" -eq 1 ]; then
    echo "=== APPLY mode — changes will be made under $SHARE_ROOT ==="
else
    echo "=== DRY-RUN mode — no changes will be made (pass --apply to commit) ==="
fi
echo

# Counters
declare -i N_OWNER_FIX=0 N_MODE_FIX=0 N_ACL_FIX=0 N_OK=0

# Check / fix ownership of a single path.
fix_owner() {
    local path="$1" want_user="$2" want_group="$3"
    local cur_user cur_group
    cur_user=$(stat -c '%U' "$path" 2>/dev/null || echo "?")
    cur_group=$(stat -c '%G' "$path" 2>/dev/null || echo "?")
    # stat reports UID/GID as numbers when no name maps — that itself is a fix signal
    local cur_uid cur_gid
    cur_uid=$(stat -c '%u' "$path")
    cur_gid=$(stat -c '%g' "$path")

    if [ "$cur_user" != "$want_user" ] || [ "$cur_group" != "$want_group" ]; then
        echo "  owner: $path  ($cur_user:$cur_group [uid=$cur_uid gid=$cur_gid] -> $want_user:$want_group)"
        N_OWNER_FIX+=1
        if [ "$APPLY" -eq 1 ]; then
            chown "$want_user:$want_group" "$path"
        fi
    fi
}

# Convert an octal digit (0-7) to its rwx representation (used by chmod symbolic mode).
num_to_perm() {
    local n="$1" p=""
    (( n & 4 )) && p+="r"
    (( n & 2 )) && p+="w"
    (( n & 1 )) && p+="x"
    echo "$p"
}

# Check / fix the "other" mode bits of a path. We do NOT enforce user or
# group/mask bits:
#   - User bits are preserved so legitimate executables (Linux binaries,
#     emulator .exe files, personal scripts) keep their exec bit.
#   - The group/mask digit reflects the ACL mask when extended ACLs are
#     present, which is managed by setfacl, not by us.
# The "other" bits are enforced because world-readable/writable files in
# this share would leak data across user accounts.
fix_other_bits() {
    local path="$1" want_o="$2"
    local cur_mode cur_o
    cur_mode=$(stat -c '%a' "$path")
    # Normalise to 3 digits (stat may emit 4 with setuid/sticky)
    cur_mode="${cur_mode: -3}"
    cur_o="${cur_mode:2:1}"

    if [ "$cur_o" != "$want_o" ]; then
        echo "  mode:  $path  (o=$cur_o -> o=$want_o)"
        N_MODE_FIX+=1
        if [ "$APPLY" -eq 1 ]; then
            chmod "o=$(num_to_perm "$want_o")" "$path"
        fi
    fi
}

# Check / fix ACLs. acl_spec is a comma-separated setfacl spec (no -d).
# Dirs additionally get the same spec as default ACLs.
# Empty acl_spec means "no ACLs to enforce" — skip the check entirely.
fix_acl() {
    local path="$1" acl_spec="$2"
    [ -z "$acl_spec" ] && return
    local cur missing=0
    # Strip "#effective:..." annotations and trailing whitespace so entries
    # compare cleanly regardless of mask state.
    cur=$(getfacl --absolute-names --omit-header "$path" 2>/dev/null \
        | sed -E 's/[[:space:]]*#.*$//; s/[[:space:]]+$//' \
        || true)

    # Split spec into entries and check each is present
    IFS=',' read -ra entries <<< "$acl_spec"
    for entry in "${entries[@]}"; do
        # Normalise the entry to the form getfacl prints (e.g. "group:adults:rwx")
        if ! echo "$cur" | grep -qxF "$entry"; then
            missing=1
            break
        fi
    done

    # For directories, also confirm default ACL entries are present
    if [ "$missing" -eq 0 ] && [ -d "$path" ]; then
        for entry in "${entries[@]}"; do
            if ! echo "$cur" | grep -qxF "default:$entry"; then
                missing=1
                break
            fi
        done
    fi

    if [ "$missing" -eq 1 ]; then
        echo "  acl:   $path  (missing: $acl_spec)"
        N_ACL_FIX+=1
        if [ "$APPLY" -eq 1 ]; then
            setfacl -m "$acl_spec" "$path"
            if [ -d "$path" ]; then
                setfacl -d -m "$acl_spec" "$path"
            fi
        fi
    fi
}

# Walk a subtree applying owner / other-mode / acl rules.
#   $1 root path
#   $2 desired owner (user)
#   $3 desired group
#   $4 acl spec (comma-separated, no defaults — defaults derived for dirs;
#                empty string means "no extended ACLs to enforce")
#   $5 desired "other" mode digit (0-7); typically 0 for private shares or
#      5 (r-x) for shares whose content is readable by non-admin system users
#
# Only the "other" mode digit is enforced. User and group/mask bits are
# intentionally not enforced — see fix_other_bits.
repair_subtree() {
    local root="$1" owner="$2" group="$3" acl="$4" other="$5"

    if [ ! -e "$root" ]; then
        echo "  (skip — does not exist: $root)"
        return
    fi

    echo "--- $root  (owner=$owner:$group other=$(num_to_perm "$other") acl=$acl) ---"

    # -print0 / read -d '' to handle weird filenames safely
    while IFS= read -r -d '' path; do
        local before_owner=$N_OWNER_FIX before_mode=$N_MODE_FIX before_acl=$N_ACL_FIX
        fix_owner       "$path" "$owner" "$group"
        fix_other_bits  "$path" "$other"
        fix_acl         "$path" "$acl"
        if [ "$before_owner" -eq "$N_OWNER_FIX" ] && \
           [ "$before_mode"  -eq "$N_MODE_FIX" ]  && \
           [ "$before_acl"   -eq "$N_ACL_FIX" ]; then
            N_OK+=1
        fi
    done < <(find "$root" -print0)
}

# Build the list of (path, rules) tuples to process, matching the logic in
# set-share-permissions.sh and install-samba.sh.

declare -a JOBS  # each entry: "path|owner|group|acl|other"
                 # acl   — comma-separated setfacl spec; empty string means
                 #         "no extended ACLs to enforce — only owner + other-bits"
                 # other — desired "other" mode digit (0-7); 0 for private,
                 #         5 (r-x) for shares with non-admin readers

add_job() {
    JOBS+=("$1|$2|$3|$4|$5")
}

# Per-user personal dirs
for prefix in $HOMELAB_USERS; do
    # Service accounts have no personal dir (mirror set-share-permissions.sh)
    service_var="${prefix}_SERVICE"
    [ "${!service_var:-0}" = "1" ] && continue
    validate_env "${prefix}_GROUPS"
    name="${prefix,,}"
    groups_var="${prefix}_GROUPS"
    groups="${!groups_var}"
    dir="$SHARE_ROOT/$name"

    if echo "$groups" | grep -qw "adults"; then
        # Adult personal dir: owner full, admin rwx, other adults r-x
        add_job "$dir" "$name" "$name" "group:admin:rwx,group:adults:r-x" 0
    else
        # Kid personal dir: owner full, admin rwx, adults rwx
        add_job "$dir" "$name" "$name" "group:admin:rwx,group:adults:rwx" 0
    fi
done

# Shared folders
add_job "$SHARE_ROOT/adults" root adults "group:admin:rwx,group:adults:rwx" 0
add_job "$SHARE_ROOT/family" root family "group:admin:rwx,group:family:rwx" 0

# Optional media share (admin-only). Same ACL idiom as the file-share jobs.
# `mask::rwx` is included explicitly so a file whose group mode bits drifted
# low (which would otherwise collapse the ACL mask and silently neuter the
# named-group entry) is restored to full admin-group writability.
if [ -n "${SMB_MEDIA_PATH:-}" ]; then
    add_job "$SMB_MEDIA_PATH" root admin "group:admin:rwx,mask::rwx" 0
fi

# Optional homelab share (admin-only). Only the subdirs that install-samba.sh
# recursively manages are included — backup/ and appdata/ are intentionally
# scoped at top-level-only in the setup module because their contents are owned
# by their respective writers (Home Assistant backups, Docker services). The
# other-mode bits are 5 (r-x) to mirror the setup module's chmod 775 /
# u=rwX,g=rwX,o=rX.
if [ -n "${SMB_HOMELAB_PATH:-}" ]; then
    add_job "$SMB_HOMELAB_PATH/config" root admin "group:admin:rwx,mask::rwx" 5
    add_job "$SMB_HOMELAB_PATH/repo"   root admin "group:admin:rwx,mask::rwx" 5
fi

# Filter by TARGET if given
if [ -n "$TARGET" ]; then
    if [[ "$TARGET" == /* ]]; then
        abs_target="${TARGET%/}"
    else
        abs_target="$SHARE_ROOT/${TARGET#/}"
        abs_target="${abs_target%/}"
    fi

    filtered=()
    for job in "${JOBS[@]}"; do
        job_path="${job%%|*}"
        # Match if TARGET equals or is inside this job's root
        if [ "$abs_target" = "$job_path" ] || [[ "$abs_target" == "$job_path"/* ]]; then
            # Replace the path with the (deeper) target so we only walk that subtree,
            # but keep this job's ownership/mode/acl rules.
            rest="${job#*|}"
            filtered+=("$abs_target|$rest")
        fi
    done

    if [ ${#filtered[@]} -eq 0 ]; then
        echo "ERROR: '$TARGET' is not under any managed top-level dir" >&2
        echo "Managed roots:" >&2
        for job in "${JOBS[@]}"; do echo "  ${job%%|*}" >&2; done
        exit 1
    fi
    JOBS=("${filtered[@]}")
fi

# Execute
for job in "${JOBS[@]}"; do
    IFS='|' read -r path owner group acl other <<< "$job"
    repair_subtree "$path" "$owner" "$group" "$acl" "$other"
done

echo
echo "=== Summary ==="
echo "  ok (no change):  $N_OK"
echo "  owner fixes:     $N_OWNER_FIX"
echo "  mode fixes:      $N_MODE_FIX"
echo "  acl fixes:       $N_ACL_FIX"
if [ "$APPLY" -eq 0 ]; then
    echo
    echo "Dry-run only. Re-run with --apply to make these changes."
fi
