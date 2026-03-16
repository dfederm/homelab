#!/bin/bash
# update.sh — Update system packages on the Proxmox host and all LXC containers.
#
# Runs apt full-upgrade on each running LXC first, then on the host.
# If the host needs a reboot, all LXCs restart with it.
# Otherwise, only LXCs that need a restart are rebooted individually.
#
# Usage: bash scripts/update.sh

set -euo pipefail

lxcs_needing_restart=()

# Update LXCs first — if host upgrade requires a reboot, LXCs are already done
for vmid in $(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}'); do
    name=$(pct list | awk -v id="$vmid" '$1==id {print $3}')
    echo "=== Updating LXC $vmid ($name) ==="
    pct exec "$vmid" -- bash -c "apt-get update -qq && apt-get full-upgrade -y"
    if pct exec "$vmid" -- test -f /var/run/reboot-required 2>/dev/null; then
        lxcs_needing_restart+=("$vmid")
    fi
    echo ""
done

echo "=== Updating host: $(hostname) ==="
apt-get update -qq
apt-get full-upgrade -y
echo ""

if [ -f /var/run/reboot-required ]; then
    echo "*** Host reboot required (LXCs will restart with it) ***"
    echo "Run 'reboot' when ready."
elif [ ${#lxcs_needing_restart[@]} -gt 0 ]; then
    echo "Restarting LXCs that need it: ${lxcs_needing_restart[*]}"
    for vmid in "${lxcs_needing_restart[@]}"; do
        pct reboot "$vmid"
    done
else
    echo "No restarts required"
fi

echo "=== Updates complete ==="
