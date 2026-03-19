#!/bin/bash
# Force-recreate a single Docker Compose service.
# Use when you need a fresh container (e.g. bind-mounted config changed).
#
# Usage: recreate-service.sh <service-name>

set -euo pipefail

SCRIPT=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT")

exec bash "$SCRIPT_DIR/run-service.sh" --force-recreate "$@"
