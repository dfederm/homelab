#!/bin/bash
# Module: configure-sensors
#
# Installs lm-sensors and persists the hardware-monitoring kernel modules this
# machine needs, so `sensors` reports fan speeds and board temperatures on every
# boot rather than only until the next one.
#
# CPU/GPU hwmon drivers autoload, but the Super I/O chip that owns the fan
# tachometers and board temperature sensors generally does not — its driver has
# to be named explicitly. Run `sensors-detect` (interactive) on the machine to
# find it: e.g. nct6775 for Nuvoton NCT67xx chips, it87 for ITE.
#
# Env vars:
#   REPO_DIR                (required, set by setup.sh) repo path on this host
#   SENSORS_KERNEL_MODULES  (optional) space-separated hwmon kernel modules to
#                           load on boot. Empty = install lm-sensors only.

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

echo "Configuring sensors..."
apt-get update -qq > /dev/null
apt-get install -y -qq lm-sensors > /dev/null

for kmod in ${SENSORS_KERNEL_MODULES:-}; do
    ensure_kernel_module "$kmod"
done

# Every chip block in `sensors` output carries an Adapter: line.
CHIP_COUNT=$(sensors 2>/dev/null | grep -c '^Adapter:' || true)
if [ "$CHIP_COUNT" -gt 0 ]; then
    echo "  $CHIP_COUNT sensor chip(s) reporting"
else
    echo "  WARNING: no sensor chips reporting. Reboot may be required."
fi
