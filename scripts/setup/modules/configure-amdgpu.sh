#!/bin/bash
# Module: configure-amdgpu
#
# Adds "amdgpu" to /etc/modules (persists across reboots) and loads it
# immediately via modprobe. Creates /dev/dri/* which is needed for GPU
# passthrough to LXCs.
#
# No env vars required.

set -euo pipefail

echo "Configuring AMD GPU..."
if ! grep -q "^amdgpu" /etc/modules 2>/dev/null; then
    echo "amdgpu" >> /etc/modules
    echo "  Added amdgpu to /etc/modules"
else
    echo "  amdgpu already in /etc/modules"
fi

modprobe amdgpu || echo "  WARNING: Could not load amdgpu module (may need reboot)"

if [ -d /dev/dri ]; then
    echo "  /dev/dri found:"
    ls -la /dev/dri/
else
    echo "  WARNING: /dev/dri not found. Reboot may be required."
fi
