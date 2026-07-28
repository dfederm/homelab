#!/bin/bash
# Module: configure-nvidia-driver
#
# Installs the NVIDIA driver on this host and keeps it working across kernel
# upgrades, so a re-pave restores it instead of leaving it as a hand-install
# nobody remembers.
#
# Install source is NVIDIA's CUDA apt repository, chosen because the
# alternatives don't hold up here: Debian's packaged driver lives in the
# non-free component, which is not enabled, and lags too far behind to build
# against a current Proxmox kernel; the .run installer isn't reproducible from a
# re-pave. The CUDA repo is apt-managed, rebuilds via DKMS on kernel upgrade,
# and — decisively — publishes the same driver version for several Debian
# releases at once, which is what lets a host and a container running a
# different Debian release agree on a version. That agreement is not optional:
# a container's userspace driver talks to the host's kernel module, and a
# mismatch fails with a confusing "Driver/library version mismatch".
#
# The package set is deliberately minimal and headless. The nvidia-open and
# cuda-drivers metapackages pull nvidia-settings, nvidia-xconfig and
# xserver-xorg-video-nvidia, none of which belong on a hypervisor, so the two
# packages that actually matter are named directly:
#   nvidia-kernel-open-dkms  the kernel modules (open flavour, which is what
#                            NVIDIA supports for Turing and later)
#   nvidia-driver-cuda       CUDA userspace; it Provides nvidia-smi and pulls in
#                            nvidia-modprobe and nvidia-persistenced
#
# nvidia-drm modesetting is deliberately NOT enabled: this host serves compute
# and passes the cards to containers, and modesetting only matters for driving a
# display. It is worth being precise about what that does and doesn't buy,
# because /dev/dri numbering matters here — an integrated GPU owns the lowest
# DRM node, and container hardware transcoding is pinned to that node by path.
# Leaving modesetting off is NOT what protects that numbering; the NVIDIA DRM
# module registers render nodes either way. What protects it is load order: the
# integrated driver is listed in /etc/modules and so is loaded before these
# cards are probed. Verify the mapping after any change with
# /dev/dri/by-path rather than assuming it held.
#
# Two things here only take effect on the next boot: the nouveau blacklist
# (nouveau claims the cards at boot and cannot be swapped out from under a
# running console) and, consequently, the driver itself. This module never
# reboots — it reports whether one is still pending.
#
# Env vars:
#   REPO_DIR              (required, set by setup.sh) repo path on this host
#   NVIDIA_DRIVER_VERSION (optional) exact apt version to install and hold, e.g.
#                         "610.43.02-1". Empty installs whatever the repo offers
#                         and reports it, which is fine for a single host but
#                         drifts apart from a container's userspace over time —
#                         so pin it once both sides are up.
#   NVIDIA_POWER_LIMIT_WATTS (optional) per-GPU power cap re-applied on every
#                         boot. Empty leaves the cards at their stock limit.

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

BLACKLIST_FILE="/etc/modprobe.d/homelab-nvidia-blacklist.conf"
PIN_FILE="/etc/apt/preferences.d/homelab-nvidia-driver.pref"
UNIT_NAME="homelab-nvidia.service"
UNIT_FILE="/etc/systemd/system/$UNIT_NAME"
KEYRING_PKG="cuda-keyring"
KEYRING_DEB="cuda-keyring_1.1-1_all.deb"

die() {
    echo "ERROR: $1" >&2
    shift
    local line
    for line in "$@"; do
        echo "  $line" >&2
    done
    exit 1
}

# A pipeline whose reader stops early — grep -q on a match, awk on exit — kills
# the writer upstream with SIGPIPE, and `set -o pipefail` then reports that as
# the pipeline's status. So piping a command straight into one of those turns a
# *successful* match into a non-zero result: an available version reads as
# unavailable, a loaded module reads as absent. The helpers below capture the
# output first and match against it, which is why none of them pipe directly.

# The candidate version apt would install, or "(none)" when the package isn't
# reachable from any configured source.
apt_candidate() {
    local policy
    policy=$(apt-cache policy "$1" 2>/dev/null) || policy=""
    awk '/Candidate:/ { print $2; exit }' <<< "$policy"
}

apt_available() {
    local candidate
    candidate=$(apt_candidate "$1")
    # An unknown package yields no output at all, a known-but-unreachable one
    # yields "(none)" — neither is installable, and an empty value would sail
    # past a "(none)" test and become an empty version specifier later.
    [ -n "$candidate" ] && [ "$candidate" != "(none)" ]
}

# Whether the configured sources offer this exact version of a package.
apt_offers_version() {
    local versions
    versions=$(apt-cache madison "$1" 2>/dev/null) || return 1
    grep -qF " $2 " <<< "$versions"
}

# The versions the configured sources do offer, newest first, for error messages.
apt_offered_versions() {
    local versions
    versions=$(apt-cache madison "$1" 2>/dev/null) || return 0
    awk '{ print $3 }' <<< "$versions" | head -5 | tr '\n' ' '
}

# Whether an in-tree driver still owns the GPUs. Until one is unloaded — which
# takes a reboot — the NVIDIA module cannot bind, so this is what separates
# "installed" from "in effect".
intree_driver_loaded() {
    local loaded
    loaded=$(lsmod) || return 1
    grep -qE '^(nouveau|nova_core)[[:space:]]' <<< "$loaded"
}

# Replace a file's contents atomically, preserving its mode when it already
# exists. Returns 0 when the contents changed, 1 when they already matched.
write_if_changed() {
    local path="$1"
    local content="$2"
    local temp
    temp=$(mktemp "$path.XXXXXX")
    printf '%s\n' "$content" > "$temp"
    if [ -f "$path" ]; then
        chmod --reference="$path" "$temp"
        if cmp -s "$temp" "$path"; then
            rm -f "$temp"
            return 1
        fi
    else
        chmod 0644 "$temp"
    fi
    mv "$temp" "$path"
    return 0
}

echo "Configuring NVIDIA driver..."

# --- Preconditions -----------------------------------------------------------

# An enabled module that quietly does nothing is the failure this is meant to
# prevent, so a host with no NVIDIA GPU is an error rather than a no-op. Match
# on the display-class functions only — every card also exposes an audio
# function that would otherwise make a GPU-less host look populated.
GPU_COUNT=$(lspci -nn 2>/dev/null \
    | grep -ciE '(VGA compatible controller|3D controller).*NVIDIA' || true)
if [ "$GPU_COUNT" -eq 0 ]; then
    die "no NVIDIA GPU found on this host" \
        "configure-nvidia-driver is enabled in HOMELAB_SETUP_MODULES but lspci reports no NVIDIA display device." \
        "Remove the module from this machine's env file, or check that the card is seated."
fi
echo "  Found $GPU_COUNT NVIDIA GPU(s)"

# Rejected here rather than by nvidia-smi at boot, where it would surface as a
# failed unit long after the change was made.
if [ -n "${NVIDIA_POWER_LIMIT_WATTS:-}" ] \
    && ! [[ "$NVIDIA_POWER_LIMIT_WATTS" =~ ^[0-9]+$ ]]; then
    die "NVIDIA_POWER_LIMIT_WATTS must be a whole number of watts" \
        "Got: $NVIDIA_POWER_LIMIT_WATTS"
fi

# NVIDIA publishes one repository per Debian release, and they are signed by
# different keys, so the release has to be resolved rather than assumed.
DEBIAN_VERSION_ID=$(. /etc/os-release && echo "${VERSION_ID:-}")
case "$DEBIAN_VERSION_ID" in
    1[0-9]) CUDA_REPO_DIST="debian${DEBIAN_VERSION_ID}" ;;
    *) die "unrecognized Debian release '$DEBIAN_VERSION_ID'" \
           "Expected an ID matching a repo under https://developer.download.nvidia.com/compute/cuda/repos/" ;;
esac
CUDA_REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/$CUDA_REPO_DIST/x86_64"

# --- Kernel headers ----------------------------------------------------------

# DKMS builds nothing without headers for the running kernel, and it does so
# quietly — the package installs, dkms status looks plausible, and the module
# simply isn't there. Proxmox renamed this package (pve-headers-* on older
# releases, proxmox-headers-* now) and a plain Debian host uses a third name, so
# all three are tried and a host with none is an error rather than a warning.
apt_get update -qq > /dev/null

RUNNING_KERNEL=$(uname -r)
HEADER_PKG=""
for candidate in "proxmox-headers-$RUNNING_KERNEL" "pve-headers-$RUNNING_KERNEL" \
                 "linux-headers-$RUNNING_KERNEL"; do
    if apt_available "$candidate"; then
        HEADER_PKG="$candidate"
        break
    fi
done

if [ -z "$HEADER_PKG" ]; then
    die "no kernel headers package available for the running kernel ($RUNNING_KERNEL)" \
        "Tried: proxmox-headers-$RUNNING_KERNEL, pve-headers-$RUNNING_KERNEL, linux-headers-$RUNNING_KERNEL" \
        "Without headers DKMS builds no module at all, so this stops here rather than appearing to succeed."
fi

# The versioned package above only covers the kernel running right now. This
# meta-package follows whichever kernel becomes the default, which is what makes
# the driver survive the next kernel upgrade without a manual step.
HEADER_META=""
for candidate in proxmox-default-headers pve-headers linux-headers-amd64; do
    if apt_available "$candidate"; then
        HEADER_META="$candidate"
        break
    fi
done

echo "  Kernel headers: $HEADER_PKG${HEADER_META:+ (+ $HEADER_META for future kernels)}"
apt_get install -y -qq "$HEADER_PKG" ${HEADER_META:+"$HEADER_META"} > /dev/null

if [ -z "$HEADER_META" ]; then
    echo "  WARNING: no default-headers meta-package found; a future kernel upgrade"
    echo "           may leave DKMS without headers and silently skip the rebuild"
fi

# --- NVIDIA CUDA repository --------------------------------------------------

# The keyring package carries both the signing key and the sources entry, and is
# the only enablement path that works unchanged across Debian releases — the
# bare .pub key file isn't published for every release, and the releases don't
# share a key.
if dpkg -s "$KEYRING_PKG" > /dev/null 2>&1; then
    echo "  NVIDIA CUDA repo already enabled ($CUDA_REPO_DIST)"
else
    echo "  Enabling NVIDIA CUDA repo ($CUDA_REPO_DIST)..."
    apt_get install -y -qq ca-certificates curl > /dev/null
    TEMP_DEB=$(mktemp --suffix=.deb)
    trap 'rm -f "$TEMP_DEB"' EXIT
    curl -fsSL -o "$TEMP_DEB" "$CUDA_REPO_URL/$KEYRING_DEB" \
        || die "could not download $KEYRING_DEB from $CUDA_REPO_URL" \
               "NVIDIA may not publish a repository for $CUDA_REPO_DIST."
    dpkg -i "$TEMP_DEB" > /dev/null
    rm -f "$TEMP_DEB"
    trap - EXIT
    apt_get update -qq > /dev/null
fi

# --- Driver version ----------------------------------------------------------

DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-}"
if [ -n "$DRIVER_VERSION" ]; then
    if ! apt_offers_version nvidia-driver-cuda "$DRIVER_VERSION"; then
        die "NVIDIA_DRIVER_VERSION '$DRIVER_VERSION' is not offered by the $CUDA_REPO_DIST repo" \
            "Available: $(apt_offered_versions nvidia-driver-cuda)"
    fi
    NVIDIA_PKGS=("nvidia-kernel-open-dkms=$DRIVER_VERSION" "nvidia-driver-cuda=$DRIVER_VERSION")
else
    DRIVER_VERSION=$(apt_candidate nvidia-driver-cuda)
    apt_available nvidia-driver-cuda \
        || die "the $CUDA_REPO_DIST repo offers no installable nvidia-driver-cuda package" \
               "apt reported candidate: ${DRIVER_VERSION:-<empty>}"
    NVIDIA_PKGS=(nvidia-kernel-open-dkms nvidia-driver-cuda)
fi
echo "  Driver version: $DRIVER_VERSION${NVIDIA_DRIVER_VERSION:+ (pinned)}"

# Holding the version matters more than it looks: the repo's routine
# full-upgrade would otherwise move the host's kernel module while a container's
# userspace stayed put, and the two must agree. Only the two top-level packages
# need pinning — every dependency below them is versioned exactly.
if [ -n "${NVIDIA_DRIVER_VERSION:-}" ]; then
    if write_if_changed "$PIN_FILE" "\
# Managed by the configure-nvidia-driver setup module.
# The host kernel module and any container userspace driver must be the same
# version, so this holds the driver until NVIDIA_DRIVER_VERSION changes.
Package: nvidia-kernel-open-dkms nvidia-driver-cuda
Pin: version $NVIDIA_DRIVER_VERSION
Pin-Priority: 1001"; then
        echo "  Pinned driver packages to $NVIDIA_DRIVER_VERSION"
    fi
elif [ -f "$PIN_FILE" ]; then
    rm -f "$PIN_FILE"
    echo "  Removed driver version pin (NVIDIA_DRIVER_VERSION is unset)"
fi

# --- Blacklist the in-tree drivers -------------------------------------------

# nouveau binds these cards at boot and will not release them, so the NVIDIA
# module cannot load until it is out of the way. nova_core is the newer in-tree
# driver and lists itself against the same devices, so blacklisting only nouveau
# would just hand the cards to a different driver on a recent kernel.
BLACKLIST_CHANGED=0
if write_if_changed "$BLACKLIST_FILE" "\
# Managed by the configure-nvidia-driver setup module.
# The in-tree drivers claim these cards at boot; the NVIDIA module cannot bind
# to a device another driver already owns.
blacklist nouveau
options nouveau modeset=0
blacklist nova_core"; then
    BLACKLIST_CHANGED=1
    echo "  Blacklisted in-tree GPU drivers (nouveau, nova_core)"
else
    echo "  In-tree GPU drivers already blacklisted"
fi

# Read the effective config back rather than trusting the write: a drop-in
# elsewhere under /etc/modprobe.d could countermand this file.
EFFECTIVE_MODPROBE=$(modprobe --showconfig 2>/dev/null || true)
for mod in nouveau nova_core; do
    grep -qE "^blacklist[[:space:]]+$mod\$" <<< "$EFFECTIVE_MODPROBE" \
        || die "$mod is not blacklisted in the effective modprobe config after writing $BLACKLIST_FILE" \
               "Check for a conflicting drop-in under /etc/modprobe.d."
done

# The blacklist only reaches early boot through the initramfs, so regenerate
# whenever the file changed or the driver still isn't the one bound to the card.
if [ "$BLACKLIST_CHANGED" -eq 1 ] || intree_driver_loaded; then
    update-initramfs -u > /dev/null
    echo "  Regenerated initramfs"
fi

# --- Install the driver ------------------------------------------------------

# Captured either side of the install so the boot-time settings below can be
# re-applied when the driver actually moved. An upgrade reloads the modules,
# which drops persistence mode and the power cap with them. The install state is
# read alongside the version because a removed-but-not-purged package still
# reports one, which would read as "unchanged".
installed_driver_version() {
    local status_version
    status_version=$(dpkg-query -W -f='${db:Status-Status} ${Version}' nvidia-driver-cuda 2>/dev/null || true)
    case "$status_version" in
        "installed "*) printf '%s' "${status_version#installed }" ;;
        *) printf '' ;;
    esac
}

INSTALLED_BEFORE=$(installed_driver_version)
apt_get install -y -qq dkms "${NVIDIA_PKGS[@]}" > /dev/null
INSTALLED_AFTER=$(installed_driver_version)
DRIVER_CHANGED=0
[ "$INSTALLED_BEFORE" != "$INSTALLED_AFTER" ] && DRIVER_CHANGED=1
echo "  Installed: ${NVIDIA_PKGS[*]}"

# --- Verify DKMS actually produced a module ----------------------------------

# This is the check that matters. The packages can install cleanly, and even
# dkms status can look plausible, while no module exists for the running kernel.
# modinfo against the running kernel is the only answer that isn't a guess.
BUILT_VERSION=$(modinfo -k "$RUNNING_KERNEL" -F version nvidia 2>/dev/null || true)
if [ -z "$BUILT_VERSION" ]; then
    die "DKMS did not produce an nvidia module for the running kernel ($RUNNING_KERNEL)" \
        "dkms status: $(dkms status 2>&1 | tr '\n' ';')" \
        "Build log: /var/lib/dkms/nvidia/*/build/make.log"
fi

# The version string is the upstream release (610.43.02), while the apt version
# carries a Debian revision (610.43.02-1), so compare on the upstream prefix.
if [ "${DRIVER_VERSION%%-*}" != "$BUILT_VERSION" ]; then
    die "the built nvidia module is version $BUILT_VERSION but $DRIVER_VERSION was installed" \
        "A stale DKMS build for this kernel is shadowing the new one." \
        "dkms status: $(dkms status 2>&1 | tr '\n' ';')"
fi
echo "  DKMS module built for $RUNNING_KERNEL: nvidia $BUILT_VERSION"

# nvidia_uvm is built by the same DKMS package but is a separate module, and it
# is the one CUDA actually needs. Checking only `nvidia` would pass while the
# module whose absence produces the confusing container-side failure is missing.
modinfo -k "$RUNNING_KERNEL" nvidia_uvm > /dev/null 2>&1 \
    || die "DKMS produced nvidia but not nvidia_uvm for $RUNNING_KERNEL" \
           "CUDA workloads need /dev/nvidia-uvm, which this module provides." \
           "dkms status: $(dkms status 2>&1 | tr '\n' ';')"

# --- Boot-time device nodes, persistence and power cap ------------------------

# Two things make this a unit rather than a one-off command.
#
# First, /dev/nvidia-uvm does not exist until something opens the driver — it is
# created on demand, not at boot. A container that starts before then binds an
# empty path and CUDA fails inside it, while every by-hand test on the host
# afterwards works. Hence the ordering against pve-guests.service, which is what
# starts Proxmox guests at boot.
#
# Second, persistence mode keeps the driver resident, so the device nodes and
# the power cap survive the last process exiting — without it a cap set at boot
# is quietly lost the first time the driver has no clients. nvidia-persistenced
# is the supported way to hold that state, so it does that job and this unit
# does the rest.
UNIT_CONTENT="\
# Managed by the configure-nvidia-driver setup module.
[Unit]
Description=Homelab NVIDIA device node and power state setup
After=nvidia-persistenced.service
# The UVM device node is created on first use, not at boot. Proxmox guests bind
# these nodes optionally, so a guest that starts first binds nothing and fails
# with no visible error.
Before=pve-guests.service
ConditionPathExists=/usr/bin/nvidia-modprobe

[Service]
Type=oneshot
RemainAfterExit=yes
# Ordered so that the most independently-fragile step comes last among the two
# that create nodes: this one also creates the per-GPU nodes and /dev/nvidiactl,
# so running it first means a UVM problem can't take those down with it
# (a oneshot stops at the first failing ExecStart).
ExecStart=/usr/bin/nvidia-smi -pm 1
# Creates /dev/nvidia-uvm and /dev/nvidia-uvm-tools, which exist only once
# something has opened the driver.
ExecStart=/usr/bin/nvidia-modprobe -u"

# Ordered last on purpose: a power value the driver rejects must not stop the
# device nodes above from being created, which is the part guests depend on.
if [ -n "${NVIDIA_POWER_LIMIT_WATTS:-}" ]; then
    UNIT_CONTENT="$UNIT_CONTENT
# Power cap. Deliberately -pl and not -lgc: locking clocks isn't portable
# across GPU generations, whereas a power cap is.
ExecStart=/usr/bin/nvidia-smi -pl $NVIDIA_POWER_LIMIT_WATTS"
fi

UNIT_CONTENT="$UNIT_CONTENT

[Install]
WantedBy=multi-user.target"

UNIT_CHANGED=0
if write_if_changed "$UNIT_FILE" "$UNIT_CONTENT"; then
    UNIT_CHANGED=1
    systemctl daemon-reload
    echo "  Wrote $UNIT_NAME${NVIDIA_POWER_LIMIT_WATTS:+ (power limit ${NVIDIA_POWER_LIMIT_WATTS}W)}"
else
    echo "  $UNIT_NAME already up to date${NVIDIA_POWER_LIMIT_WATTS:+ (power limit ${NVIDIA_POWER_LIMIT_WATTS}W)}"
fi

if systemctl list-unit-files nvidia-persistenced.service > /dev/null 2>&1; then
    systemctl enable nvidia-persistenced.service > /dev/null || true
fi
systemctl enable "$UNIT_NAME" > /dev/null

# --- Report staged vs in effect ----------------------------------------------

# Which driver actually owns the cards is the only thing that distinguishes
# "installed" from "in use": until the machine reboots, they are still the
# in-tree driver's.
if intree_driver_loaded; then
    echo "  REBOOT REQUIRED to take effect: in-tree driver still bound to the GPUs"
    echo "  After reboot, GPU-consuming containers need a restart to pick up the device nodes"
elif [ -d /sys/module/nvidia ]; then
    # Safe to act now — the driver is already the one bound to the cards.
    #
    # The unit is a oneshot with RemainAfterExit, so a plain start is a no-op
    # once it has run. Reloading the driver clears persistence mode and the
    # power cap, so a version change has to re-run it rather than assume the
    # settings from the last boot are still in force.
    if [ "$DRIVER_CHANGED" -eq 1 ] || [ "$UNIT_CHANGED" -eq 1 ]; then
        SETTINGS_ACTION=restart
    else
        SETTINGS_ACTION=start
    fi
    systemctl "$SETTINGS_ACTION" "$UNIT_NAME" > /dev/null 2>&1 \
        || echo "  WARNING: $UNIT_NAME failed to $SETTINGS_ACTION; check systemctl status $UNIT_NAME"
    echo "  Active in the running kernel: nvidia $BUILT_VERSION"
    nvidia-smi --query-gpu=index,name,driver_version,power.limit \
        --format=csv,noheader 2>/dev/null | sed 's/^/    /' || true

    # Read the cap back instead of trusting that the unit succeeded. systemd
    # accepts any value here; only the driver knows whether it is within the
    # card's supported range, and it rejects it at the point of use.
    if [ -n "${NVIDIA_POWER_LIMIT_WATTS:-}" ]; then
        while read -r gpu_index gpu_limit; do
            [ -n "$gpu_index" ] || continue
            if [ "${gpu_limit%%.*}" != "$NVIDIA_POWER_LIMIT_WATTS" ]; then
                echo "  WARNING: GPU $gpu_index power limit reads ${gpu_limit}W, expected ${NVIDIA_POWER_LIMIT_WATTS}W"
                echo "           Check the supported range with: nvidia-smi -q -d POWER"
            fi
        done < <(nvidia-smi --query-gpu=index,power.limit \
                     --format=csv,noheader,nounits 2>/dev/null | tr -d ',')
    fi
else
    echo "  REBOOT REQUIRED to take effect: nvidia module built but not loaded"
fi
