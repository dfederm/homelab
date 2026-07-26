#!/bin/bash
# Module: configure-amdgpu
#
# Adds "amdgpu" to /etc/modules (persists across reboots) and loads it
# immediately via modprobe. Creates /dev/dri/* which is needed for GPU
# passthrough to LXCs.
#
# No env vars required (REPO_DIR is set by setup.sh).

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

echo "Configuring AMD GPU..."
ensure_kernel_module amdgpu

if [ -d /dev/dri ]; then
    echo "  /dev/dri found:"
    ls -la /dev/dri/
else
    echo "  WARNING: /dev/dri not found. Reboot may be required."
fi
