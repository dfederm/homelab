#!/bin/bash
# Shared helpers for target-local deployment coordination.

deploy_state_validate_absolute_path() {
    local path="$1"

    [ -n "$path" ] \
        && [[ "$path" = /* ]] \
        && [[ "$path" != "/" ]] \
        && [[ "$path" != *".."* ]] \
        && [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]]
}

deploy_state_validate_commit() {
    [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

deploy_state_load_env() {
    local system_env="${HOMELAB_SYSTEM_ENV:-/etc/homelab.env}"
    local env_file config_dir

    [ -f "$system_env" ] || {
        echo "ERROR: $system_env does not exist" >&2
        return 1
    }

    env_file=$(readlink -f "$system_env")
    config_dir=$(dirname "$env_file")

    set -a
    [ -f "$config_dir/common.env" ] && source "$config_dir/common.env"
    source "$env_file"
    set +a
}

deploy_state_atomic_write() {
    local file="$1"
    local value="$2"
    local directory tmp

    directory=$(dirname "$file")
    mkdir -p "$directory"
    tmp=$(mktemp "$directory/.state.XXXXXX")
    printf '%s\n' "$value" > "$tmp"
    chmod 0600 "$tmp"
    mv "$tmp" "$file"
}

deploy_state_read_commit() {
    local file="$1"
    local commit

    [ -f "$file" ] || return 1
    commit=$(cat "$file")
    deploy_state_validate_commit "$commit" || return 1
    printf '%s\n' "$commit"
}

deploy_state_append_event() {
    local file="$1"
    local event="$2"
    local max_bytes="${DEPLOY_EVENT_LOG_MAX_BYTES:-1048576}"
    local line field lock_file
    shift 2

    [[ "$max_bytes" =~ ^[1-9][0-9]*$ ]] || return 1
    mkdir -p "$(dirname "$file")"
    lock_file="${file}.lock"
    exec {event_lock}> "$lock_file"
    flock "$event_lock"

    if [ -f "$file" ] && [ "$(wc -c < "$file")" -ge "$max_bytes" ]; then
        mv -f "$file" "${file}.1"
    fi

    printf -v line '%s\t%s' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$event"
    for field in "$@"; do
        line+=$'\t'"$field"
    done
    printf '%s\n' "$line" >> "$file"

    flock -u "$event_lock"
    exec {event_lock}>&-
}

deploy_state_cleanup_logs() {
    local log_dir="$1"
    local retention_days="$2"

    [[ "$retention_days" =~ ^[0-9]+$ ]] || return 1
    [ -d "$log_dir" ] || return 0
    find "$log_dir" -type f -mtime "+$retention_days" -delete
}
