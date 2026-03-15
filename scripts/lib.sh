#!/bin/bash
# Shared helper functions for homelab scripts.
# Source this file; do not execute directly.

# Validate that all named env vars are set and non-empty.
# Supports indirect variable names (e.g. dynamically constructed names).
#
# Usage: validate_env "MY_VAR" "OTHER_VAR"
validate_env() {
    for var in "$@"; do
        if [ -z "${!var:-}" ]; then
            echo "ERROR: $var must be set" >&2
            exit 1
        fi
    done
}
