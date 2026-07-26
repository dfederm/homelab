#!/bin/bash
# Module: configure-kernel-cmdline
#
# Ensures the kernel command-line parameters this machine needs
# (KERNEL_CMDLINE_PARAMS) are present in the bootloader config, so they survive
# a re-pave instead of living on as a hand-edit nobody remembers.
#
# Where the command line lives depends on how the host boots, so it is detected
# rather than assumed. proxmox-boot-tool reports what kind of entries each ESP
# holds: systemd-boot ("uefi") and unified-kernel-image ("uki") entries take the
# command line from /etc/kernel/cmdline, while grub-on-ESP entries are generated
# by update-grub and take it from GRUB_CMDLINE_LINUX_DEFAULT in
# /etc/default/grub. A host can have both kinds, so both files may need
# managing; `proxmox-boot-tool refresh` regenerates either. A host that
# proxmox-boot-tool doesn't manage is a plain GRUB install, refreshed with
# `update-grub`. An unrecognized bootloader is an error, not a silent no-op.
#
# On the GRUB side only GRUB_CMDLINE_LINUX_DEFAULT is managed. GRUB appends it
# after GRUB_CMDLINE_LINUX on the default boot entry, so it wins on any key the
# two both set.
#
# Parameters only take effect on the next boot, and this module never reboots —
# it reports whether one is still pending.
#
# Env vars:
#   REPO_DIR              (required, set by setup.sh) repo path on this host
#   KERNEL_CMDLINE_PARAMS (optional) space-separated kernel parameters to ensure
#                         are set, e.g. "iommu=pt". A parameter already present
#                         with a different value is replaced, not duplicated.
#                         Empty = nothing to do.

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

GRUB_FILE="/etc/default/grub"
GRUB_VAR="GRUB_CMDLINE_LINUX_DEFAULT"
PBT_FILE="/etc/kernel/cmdline"

die() {
    echo "ERROR: $1" >&2
    shift
    local line
    for line in "$@"; do
        echo "  $line" >&2
    done
    exit 1
}

target_desc() {
    case "$1" in
        pbt)  echo "$PBT_FILE" ;;
        grub) echo "$GRUB_VAR in $GRUB_FILE" ;;
    esac
}

# The value GRUB_CMDLINE_LINUX_DEFAULT resolves to. Sourcing is how grub-mkconfig
# reads the file, so this handles every quoting style. grub-mkconfig then sources
# /etc/default/grub.d/*.cfg, which can override the main file — pass "dropins"
# to account for those as well.
grub_cmdline_value() {
    (
        set +u
        # Anything the sourced files print would otherwise be captured as part
        # of the value by the caller's command substitution.
        {
            # shellcheck disable=SC1090
            . "$GRUB_FILE"
            if [ "${1:-}" = "dropins" ]; then
                for dropin in /etc/default/grub.d/*.cfg; do
                    if [ -e "$dropin" ]; then
                        # shellcheck disable=SC1090
                        . "$dropin"
                    fi
                done
            fi
        } > /dev/null
        printf '%s' "${GRUB_CMDLINE_LINUX_DEFAULT:-}"
    )
}

# Replace a file's contents atomically, keeping its mode. A half-written
# bootloader config is not something to leave behind on an interrupted run.
replace_file() {
    local path="$1"
    local content="$2"
    local temp
    temp=$(mktemp "$path.XXXXXX")
    printf '%s\n' "$content" > "$temp"
    chmod --reference="$path" "$temp"
    mv "$temp" "$path"
}

# How many times a key appears in a kernel command line.
cmdline_key_count() {
    local key="$2"
    local token count=0
    local -a tokens=()

    read -ra tokens <<< "$1"
    for token in "${tokens[@]}"; do
        if [ "${token%%=*}" = "$key" ]; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

# Escape a value for interpolation into a double-quoted shell assignment. A
# pre-existing parameter such as memmap=4G\$4G reads back unescaped, and would
# otherwise be re-expanded — silently — the next time the file is sourced.
escape_for_dquotes() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    value="${value//\`/\\\`}"
    printf '%s' "$value"
}

write_grub_cmdline() {
    local assignment content line_no line
    assignment="${GRUB_VAR}=\"$(escape_for_dquotes "$1")\""

    if grep -qE "^[[:space:]]*${GRUB_VAR}=" "$GRUB_FILE"; then
        # Later assignments win when the file is sourced, so rewrite the last one.
        line_no=$(grep -nE "^[[:space:]]*${GRUB_VAR}=" "$GRUB_FILE" | tail -1 | cut -d: -f1)
        line=$(sed -n "${line_no}p" "$GRUB_FILE")
        # Swapping a single line only works if the assignment is a single line.
        # A quoted or backslash continuation would leave its remainder orphaned.
        if ! bash -n <<< "$line" 2>/dev/null; then
            die "$GRUB_VAR at $GRUB_FILE line $line_no continues onto another line" \
                "Rewrite it as a single-line assignment, then re-run."
        fi
        # Via the environment, not -v: awk expands escape sequences in a -v
        # assignment, so a backslash in the value would not survive intact.
        content=$(GRUB_ASSIGNMENT="$assignment" awk -v n="$line_no" \
            'NR == n { print ENVIRON["GRUB_ASSIGNMENT"]; next } { print }' "$GRUB_FILE")
    else
        # awk terminates the existing final line, which would otherwise absorb
        # the appended assignment into it.
        content=$(GRUB_ASSIGNMENT="$assignment" awk \
            '{ print } END { print ENVIRON["GRUB_ASSIGNMENT"] }' "$GRUB_FILE")
    fi

    if ! bash -n <<< "$content" 2>/dev/null; then
        die "rewriting $GRUB_VAR would leave $GRUB_FILE unparseable; nothing written"
    fi

    replace_file "$GRUB_FILE" "$content"
}

echo "Configuring kernel command line..."

read -ra DESIRED <<< "${KERNEL_CMDLINE_PARAMS:-}"
if [ "${#DESIRED[@]}" -eq 0 ]; then
    echo "  No parameters configured"
    exit 0
fi

# These end up inside a double-quoted shell assignment in /etc/default/grub, so
# anything the shell would interpret has to be rejected before it corrupts the
# file rather than after. Two values for one key would also make the merge
# result depend on ordering.
SEEN_KEYS=""
for param in "${DESIRED[@]}"; do
    if [[ ! "$param" =~ ^[A-Za-z0-9_.-]+(=[A-Za-z0-9_.,:/=+%@-]*)?$ ]]; then
        die "KERNEL_CMDLINE_PARAMS entry '$param' is not a plain kernel parameter"
    fi
    case " $SEEN_KEYS " in
        *" ${param%%=*} "*)
            die "KERNEL_CMDLINE_PARAMS sets '${param%%=*}' more than once" ;;
    esac
    SEEN_KEYS="$SEEN_KEYS ${param%%=*}"
done

TARGETS=()
if command -v proxmox-boot-tool > /dev/null 2>&1 \
    && proxmox-boot-tool status --quiet > /dev/null 2>&1; then
    PROPAGATE=(proxmox-boot-tool refresh)
    # --quiet answers "is this host proxmox-boot-tool managed" without mounting
    # anything; the ESP modes need the full status, which mounts each ESP. Its
    # warnings are left on stderr — an ESP it couldn't mount is not reported,
    # and that is worth seeing.
    if ! MODES=$(proxmox-boot-tool status | sed -n 's/.*is configured with: //p'); then
        die "proxmox-boot-tool status failed; cannot tell where the command line lives"
    fi
    case "$MODES" in *uefi*|*uki*) TARGETS+=(pbt) ;; esac
    case "$MODES" in *grub*)       TARGETS+=(grub) ;; esac
    if [ "${#TARGETS[@]}" -eq 0 ]; then
        die "proxmox-boot-tool manages boot but reported no usable ESP" \
            "Reported: ${MODES:-<nothing>}"
    fi
elif [ -f "$GRUB_FILE" ]; then
    PROPAGATE=(update-grub)
    TARGETS+=(grub)
else
    die "no supported bootloader config found" \
        "proxmox-boot-tool is not managing this host and $GRUB_FILE does not exist"
fi

CHANGED=0

for target in "${TARGETS[@]}"; do
    case "$target" in
        pbt)
            [ -f "$PBT_FILE" ] || die "boot entries are generated from $PBT_FILE but it does not exist"
            # Only the file's first line reaches the boot entry, so a second one
            # would be silently dropped rather than appended.
            if [ "$(grep -c . "$PBT_FILE")" -gt 1 ]; then
                die "$PBT_FILE has more than one non-empty line; refusing to rewrite it"
            fi
            current=$(tr -d '\n' < "$PBT_FILE")
            ;;
        grub)
            [ -f "$GRUB_FILE" ] || die "boot entries are generated from $GRUB_FILE but it does not exist"
            bash -n "$GRUB_FILE" 2>/dev/null \
                || die "$GRUB_FILE is not valid shell; refusing to modify it"
            # That check is the real guard here: command substitutions do not
            # inherit errexit, so a failed source below would go unnoticed.
            current=$(grub_cmdline_value) \
                || die "could not read $GRUB_VAR from $GRUB_FILE"
            ;;
    esac

    # A few keys are legitimately repeatable (console=, cgroup_enable=). Setting
    # one of those collapses the existing entries into a single value, which
    # would silently drop the others — refuse rather than pick for the operator.
    for param in "${DESIRED[@]}"; do
        if [ "$(cmdline_key_count "$current" "${param%%=*}")" -gt 1 ]; then
            die "$(target_desc "$target") already sets '${param%%=*}' more than once" \
                "Setting it here would collapse those into one value. Reconcile them by hand first." \
                "Current: $current"
        fi
    done

    merged=$(merge_cmdline_params "$current" "${DESIRED[@]}")

    if [ "$merged" = "$current" ]; then
        echo "  $(target_desc "$target") already set to: $current"
    else
        case "$target" in
            pbt)  replace_file "$PBT_FILE" "$merged" ;;
            grub) write_grub_cmdline "$merged" ;;
        esac
        CHANGED=1
        echo "  $(target_desc "$target") updated: $current -> $merged"
    fi

    # Read back rather than trust the write, and do it before regenerating the
    # boot entries so a config that didn't take is caught while the bootloader
    # is still untouched. The merged set proves the file says what this module
    # decided to write; the requested set proves the merge itself did what was
    # asked. On the GRUB side a /etc/default/grub.d drop-in can override what
    # was written.
    case "$target" in
        pbt)  effective=$(tr -d '\n' < "$PBT_FILE") ;;
        grub) effective=$(grub_cmdline_value dropins) ;;
    esac

    read -ra EXPECTED <<< "$merged"
    for param in "${EXPECTED[@]}" "${DESIRED[@]}"; do
        cmdline_has_param "$effective" "$param" \
            || die "$param is missing from the effective boot config after writing it" \
                   "$(target_desc "$target") resolves to: $effective"
    done
done

# /proc/cmdline is the command line the running kernel actually booted with,
# which is the only thing that distinguishes "in effect" from "staged".
RUNNING=$(cat /proc/cmdline)
PENDING=()
for param in "${DESIRED[@]}"; do
    cmdline_has_param "$RUNNING" "$param" || PENDING+=("$param")
done

# Regenerate whenever the parameters aren't live yet, not only when the config
# changed. A config that was written but never propagated — an earlier run that
# failed part-way, or a hand edit — would otherwise stay staged forever while
# every run reported success.
if [ "$CHANGED" -eq 1 ] || [ "${#PENDING[@]}" -gt 0 ]; then
    "${PROPAGATE[@]}" > /dev/null
    echo "  Regenerated boot entries (${PROPAGATE[*]})"
fi

if [ "${#PENDING[@]}" -gt 0 ]; then
    echo "  REBOOT REQUIRED to take effect: ${PENDING[*]}"
else
    echo "  Active in the running kernel"
fi
