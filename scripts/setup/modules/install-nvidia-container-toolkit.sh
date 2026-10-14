#!/bin/bash
# Module: install-nvidia-container-toolkit
#
# The LXC uses the host's kernel driver and passed-through device nodes. Its
# userspace NVIDIA driver must match the host version across Debian releases.
# Install without Recommends: libcuda1 otherwise pulls DKMS into the LXC.
# The toolkit cannot manage cgroups inside the guest; the host already gates
# device access. Missing Docker/devices or a mismatch is a warning, not fatal:
# failing this module would abort the host's setup cascade for other guests.
#
# Env vars:
#   REPO_DIR              (required, set by setup.sh) repo path on this host
#   NVIDIA_DRIVER_VERSION (optional) exact version shared with the host;
#                         empty uses this machine's repo version.

set -euo pipefail

source "$REPO_DIR/scripts/lib.sh"

PIN_FILE="/etc/apt/preferences.d/homelab-nvidia-driver.pref"
KEYRING_DIR="/etc/apt/keyrings"
TOOLKIT_KEYRING="$KEYRING_DIR/nvidia-container-toolkit.gpg"
TOOLKIT_LIST="/etc/apt/sources.list.d/nvidia-container-toolkit.list"
RUNTIME_CONFIG="/etc/nvidia-container-runtime/config.toml"
DOCKER_DAEMON_CONFIG="/etc/docker/daemon.json"
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

# Capture command output before grep -q/awk: early reader exit raises SIGPIPE
# under pipefail and can turn a successful match into a false negative.

apt_candidate() {
    local policy
    policy=$(apt-cache policy "$1" 2>/dev/null) || policy=""
    awk '/Candidate:/ { print $2; exit }' <<< "$policy"
}

apt_offers_version() {
    local versions
    versions=$(apt-cache madison "$1" 2>/dev/null) || return 1
    grep -qF " $2 " <<< "$versions"
}

apt_offered_versions() {
    local versions
    versions=$(apt-cache madison "$1" 2>/dev/null) || return 0
    awk 'NR <= 5 { print $3 }' <<< "$versions" | tr '\n' ' '
}

# Hash a file that may not exist, so "did this change" survives first creation.
config_fingerprint() {
    if [ -f "$1" ]; then
        md5sum < "$1"
    else
        echo "absent"
    fi
}

echo "Installing NVIDIA container toolkit..."

# --- Preconditions -----------------------------------------------------------

if ! command -v docker &> /dev/null; then
    # Non-fatal for the same reason as the device-node check below: this module
    # runs inside a container whose setup is driven from the hypervisor, so
    # exiting non-zero aborts the hypervisor's loop over its other guests too.
    echo "  WARNING: docker is not installed — nothing to configure a runtime for"
    echo "  install-nvidia-container-toolkit must run after install-docker in"
    echo "  HOMELAB_SETUP_MODULES. Skipping."
    exit 0
fi

if [ ! -e /dev/nvidiactl ]; then
    echo "  WARNING: no /dev/nvidiactl — the GPUs have not been passed in to this machine"
    echo "  Nothing to do until the hypervisor has its NVIDIA driver loaded and"
    echo "  passthrough configured; re-run setup after that. Skipping."
    exit 0
fi

if [ ! -e /dev/nvidia-uvm ]; then
    # Worth calling out separately: nvidia-smi will happily work without this,
    # so the problem only shows up later as CUDA failing inside a container.
    echo "  WARNING: /dev/nvidiactl is present but /dev/nvidia-uvm is not"
    echo "  CUDA workloads will fail even though nvidia-smi appears to work."
    echo "  On the hypervisor, ensure the device nodes are created before guests start."
fi

DEBIAN_VERSION_ID=$(. /etc/os-release && echo "${VERSION_ID:-}")
case "$DEBIAN_VERSION_ID" in
    1[0-9]) CUDA_REPO_DIST="debian${DEBIAN_VERSION_ID}" ;;
    *) die "unrecognized Debian release '$DEBIAN_VERSION_ID'" \
           "Expected an ID matching a repo under https://developer.download.nvidia.com/compute/cuda/repos/" ;;
esac
CUDA_REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/$CUDA_REPO_DIST/x86_64"

# --- NVIDIA CUDA repository (userspace driver) -------------------------------

apt_get install -y -qq ca-certificates curl gnupg > /dev/null

if dpkg -s "$KEYRING_PKG" > /dev/null 2>&1; then
    echo "  NVIDIA CUDA repo already enabled ($CUDA_REPO_DIST)"
else
    echo "  Enabling NVIDIA CUDA repo ($CUDA_REPO_DIST)..."
    TEMP_DEB=$(mktemp --suffix=.deb)
    trap 'rm -f "$TEMP_DEB"' EXIT
    curl -fsSL -o "$TEMP_DEB" "$CUDA_REPO_URL/$KEYRING_DEB" \
        || die "could not download $KEYRING_DEB from $CUDA_REPO_URL" \
               "NVIDIA may not publish a repository for $CUDA_REPO_DIST."
    dpkg -i "$TEMP_DEB" > /dev/null
    rm -f "$TEMP_DEB"
    trap - EXIT
fi

# --- NVIDIA Container Toolkit repository -------------------------------------

# One repository serves every distribution here, so unlike the driver repo above
# there is nothing release-specific to resolve.
TOOLKIT_REPO_CHANGED=0
if [ ! -s "$TOOLKIT_KEYRING" ]; then
    install -m 0755 -d "$KEYRING_DIR"
    # Dearmoured into a temp file first: a fetch that dies part-way would
    # otherwise leave a short or empty keyring behind, which the existence check
    # above would then treat as done forever while apt rejects the repo.
    TEMP_KEY=$(mktemp)
    trap 'rm -f "$TEMP_KEY"' EXIT
    # --batch keeps gpg from reaching for a terminal; this runs unattended, and
    # under some invocations there isn't one to reach for.
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --batch --yes --dearmor -o "$TEMP_KEY" \
        || die "could not fetch the NVIDIA container toolkit signing key"
    [ -s "$TEMP_KEY" ] || die "the NVIDIA container toolkit signing key came back empty"
    mv "$TEMP_KEY" "$TOOLKIT_KEYRING"
    chmod a+r "$TOOLKIT_KEYRING"
    trap - EXIT
    TOOLKIT_REPO_CHANGED=1
fi

TEMP_LIST=$(mktemp)
trap 'rm -f "$TEMP_LIST"' EXIT
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed "s#deb https://#deb [signed-by=$TOOLKIT_KEYRING] https://#g" > "$TEMP_LIST"
[ -s "$TEMP_LIST" ] || die "could not fetch the NVIDIA container toolkit sources list"

if ! cmp -s "$TEMP_LIST" "$TOOLKIT_LIST"; then
    mv "$TEMP_LIST" "$TOOLKIT_LIST"
    chmod 0644 "$TOOLKIT_LIST"
    TOOLKIT_REPO_CHANGED=1
    echo "  Configured NVIDIA container toolkit repo"
fi
rm -f "$TEMP_LIST"
trap - EXIT

apt_get update -qq > /dev/null

# --- Userspace driver --------------------------------------------------------

DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-}"
if [ -n "$DRIVER_VERSION" ]; then
    if ! apt_offers_version nvidia-driver-cuda "$DRIVER_VERSION"; then
        die "NVIDIA_DRIVER_VERSION '$DRIVER_VERSION' is not offered by the $CUDA_REPO_DIST repo" \
            "The hypervisor and this machine run different Debian releases, so a version" \
            "available there is not automatically available here." \
            "Available: $(apt_offered_versions nvidia-driver-cuda)"
    fi
    DRIVER_PKG="nvidia-driver-cuda=$DRIVER_VERSION"
else
    DRIVER_VERSION=$(apt_candidate nvidia-driver-cuda)
    # Empty means apt has never heard of the package; "(none)" means it knows it
    # but can't reach an installable version. Neither can be installed, and an
    # empty value would otherwise flow on as an empty version specifier.
    if [ -z "$DRIVER_VERSION" ] || [ "$DRIVER_VERSION" = "(none)" ]; then
        die "the $CUDA_REPO_DIST repo offers no installable nvidia-driver-cuda package" \
            "apt reported candidate: ${DRIVER_VERSION:-<empty>}"
    fi
    DRIVER_PKG="nvidia-driver-cuda"
    echo "  WARNING: NVIDIA_DRIVER_VERSION is unset — installing $DRIVER_VERSION"
    echo "           Pin it on both this machine and the hypervisor, or a future"
    echo "           upgrade on either side will break GPU access here."
fi

if [ -n "${NVIDIA_DRIVER_VERSION:-}" ]; then
    TEMP_PIN=$(mktemp)
    trap 'rm -f "$TEMP_PIN"' EXIT
    cat > "$TEMP_PIN" <<EOF
# Managed by the install-nvidia-container-toolkit setup module.
# This must stay equal to the hypervisor's kernel module version.
Package: nvidia-driver-cuda
Pin: version $NVIDIA_DRIVER_VERSION
Pin-Priority: 1001
EOF
    if ! cmp -s "$TEMP_PIN" "$PIN_FILE"; then
        mv "$TEMP_PIN" "$PIN_FILE"
        chmod 0644 "$PIN_FILE"
        echo "  Pinned userspace driver to $NVIDIA_DRIVER_VERSION"
    fi
    rm -f "$TEMP_PIN"
    trap - EXIT
elif [ -f "$PIN_FILE" ]; then
    rm -f "$PIN_FILE"
fi

# --no-install-recommends keeps libcuda1's recommended DKMS package out; see the
# header. Only reinstall when the wanted version isn't already the one present —
# and ask dpkg for the install *state* too, since a removed-but-not-purged
# package still reports a version and would look like a match.
INSTALLED_DRIVER=$(dpkg-query -W -f='${db:Status-Status} ${Version}' nvidia-driver-cuda 2>/dev/null || true)
INSTALLED_DRIVER=${INSTALLED_DRIVER#installed }
case "$INSTALLED_DRIVER" in
    *" "*) INSTALLED_DRIVER="" ;;   # any other status: treat as not installed
esac
if [ "$INSTALLED_DRIVER" != "$DRIVER_VERSION" ]; then
    echo "  Installing userspace driver $DRIVER_VERSION..."
    apt_get install -y -qq --no-install-recommends "$DRIVER_PKG" > /dev/null
else
    echo "  Userspace driver already at $DRIVER_VERSION"
fi

DPKG_LIST=$(dpkg -l 2>/dev/null || true)
if grep -qE '^ii\s+nvidia-kernel(-open)?-dkms' <<< "$DPKG_LIST"; then
    echo "  WARNING: a DKMS kernel module package is installed on this machine."
    echo "           It cannot build or load in a container; the hypervisor owns the module."
fi

# --- Container toolkit -------------------------------------------------------

if [ "$TOOLKIT_REPO_CHANGED" -eq 1 ] || ! command -v nvidia-ctk &> /dev/null; then
    echo "  Installing nvidia-container-toolkit..."
    apt_get install -y -qq nvidia-container-toolkit > /dev/null
else
    echo "  nvidia-container-toolkit already installed"
fi

# Restarting Docker restarts every container on this machine, so both of the
# changes below are compared before and after and the restart only happens if
# something actually moved.
RUNTIME_BEFORE=$(config_fingerprint "$RUNTIME_CONFIG")
DAEMON_BEFORE=$(config_fingerprint "$DOCKER_DAEMON_CONFIG")

nvidia-ctk config --in-place --set nvidia-container-cli.no-cgroups=true > /dev/null

# Read the result back rather than trusting the write — a toolkit that quietly
# ignored the key would leave containers failing on a cgroup write instead.
if ! grep -qE '^[[:space:]]*no-cgroups[[:space:]]*=[[:space:]]*true' "$RUNTIME_CONFIG"; then
    die "no-cgroups is not set to true in $RUNTIME_CONFIG after configuring it" \
        "Without it the toolkit tries to write device cgroup rules this machine does not own."
fi

nvidia-ctk runtime configure --runtime=docker > /dev/null

RUNTIME_AFTER=$(config_fingerprint "$RUNTIME_CONFIG")
DAEMON_AFTER=$(config_fingerprint "$DOCKER_DAEMON_CONFIG")

if [ "$RUNTIME_BEFORE" != "$RUNTIME_AFTER" ] || [ "$DAEMON_BEFORE" != "$DAEMON_AFTER" ]; then
    echo "  Container runtime configuration changed — restarting Docker"
    systemctl restart docker
else
    echo "  Container runtime already configured"
fi

# --- Verify ------------------------------------------------------------------

# The whole point of matching versions is that this call succeeds, so it is
# checked rather than assumed. It warns rather than exits, for the same reason
# the missing-device-nodes check above does: this module runs inside a container
# whose setup is itself driven from the hypervisor, so a non-zero exit here
# aborts not just this machine's remaining services but the hypervisor's loop
# over its other guests. The loud failure that matters happens anyway when a
# GPU-requesting service refuses to start.
if SMI_OUTPUT=$(nvidia-smi --query-gpu=index,name,driver_version --format=csv,noheader 2>&1); then
    echo "  GPUs visible:"
    echo "$SMI_OUTPUT" | sed 's/^/    /'
    echo "NVIDIA container toolkit ready"
else
    echo "  WARNING: nvidia-smi failed on this machine — GPU access is NOT working" >&2
    echo "$SMI_OUTPUT" | sed 's/^/    /' >&2
    echo "  A 'Driver/library version mismatch' means NVIDIA_DRIVER_VERSION ($DRIVER_VERSION)" >&2
    echo "  differs from the kernel module version on the hypervisor. Compare with" >&2
    echo "  'nvidia-smi --query-gpu=driver_version --format=csv,noheader' there." >&2
fi
