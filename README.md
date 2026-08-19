# Homelab

Declarative configuration for a homelab running [Proxmox VE](https://www.proxmox.com/en/proxmox-virtual-environment/overview). All services, infrastructure, and machine setup are defined in this repo and applied via idempotent scripts.

## Architecture

The primary server runs Proxmox with LXC containers and VMs. Additional machines (e.g. a Raspberry Pi) can use the same setup system with their own env files.

- **Proxmox host** — ZFS pool, GPU driver, creates and manages LXCs/VMs
- **Docker LXC** — Runs all containerized services (Jellyfin, Immich, AdGuard, etc.)
- **NAS LXC** — Samba file sharing with per-user permissions
- **Home Assistant VM** — Smart home automation (restored from HAOS image)

All data lives on a ZFS pool and is bind-mounted into containers. The LXC root filesystems are ephemeral — destroy and recreate from this repo at any time.

## Directory Structure

```
├── .env.template          # Template for machine-specific config
├── nas/
│   └── smb.conf.global    # Samba [global] config (shares are generated)
├── renovate.json          # Automated Docker image update config
├── scripts/
│   ├── backup/            # Database and volume backup scripts
│   ├── bootstrap-remote.sh # Bootstrap a new non-LXC machine (SMB mount + first setup)
│   ├── deploy.sh          # Deploy changes on this machine (pull + setup)
│   ├── lib.sh             # Shared helper functions (sourced by other scripts)
│   ├── recreate-service.sh # Force-recreate a service container
│   ├── run-all-services.sh
│   ├── run-service.sh     # Deploy a single Docker Compose service
│   ├── storage/           # Host-level storage-health scripts (ZFS scrub/health, SMART alert dispatch)
│   ├── storage-space-check.sh # Threshold alerts for thin-pool + ZFS pool capacity
│   ├── update.sh          # Update system packages on host and all LXCs
│   └── setup/
│       ├── setup.sh       # Main setup runner (see below)
│       └── modules/       # Idempotent setup modules
└── services/              # Docker Compose service definitions
    ├── ai/               # Ollama + LiteLLM + Open WebUI + SearXNG + Athena MCP
    ├── authelia/          # Single sign-on / OIDC identity provider
    ├── backup/            # Rclone cloud backup
    ├── bedrock-connect/   # Console server-list menu (BedrockConnect) for Minecraft
    ├── dns/               # AdGuard Home
    ├── dozzle/            # Docker log viewer
    ├── files/             # Filestash + Collabora
    ├── forgejo/           # Forgejo git hosting + Actions CI runner
    ├── homepage/          # Landing page dashboard
    ├── jellyfin/          # Media streaming
    ├── koffan/            # Shared shopping list (local-first PWA)
    ├── minecraft/         # Minecraft Bedrock servers (multi-world)
    ├── monitoring/        # Beszel hub + Uptime Kuma
    ├── monitoring-agent/  # Beszel agent (runs on all hosts)
    ├── photos/            # Immich
    ├── radicale/          # CalDAV/CardDAV (calendar + contacts)
    ├── reverse-proxy/     # Caddy
    ├── scrutiny/          # Drive SMART health (web UI + InfluxDB)
    ├── vikunja/           # Vikunja task management (+ Postgres)
    ├── webhook/           # CI/CD webhook receiver and target dispatcher
    └── zwave/             # Z-Wave JS UI
```

## Setup System

The setup system is designed so that a single command on the Proxmox host bootstraps or updates the entire stack — host config, LXC creation, software installation inside each container, and service deployment.

### How It Works

Each machine has a `.env` file (stored outside the repo at `<mount>/homelab/config/<hostname>.env`) that defines:
- Which **setup modules** to run (`HOMELAB_SETUP_MODULES`)
- Which **services** to deploy (`HOMELAB_SERVICES`)
- All machine-specific configuration (IPs, resources, mount points, etc.)

A shared `common.env` in the same directory holds values that must be identical across machines (timezone, network basics, users/groups). It is sourced automatically before the machine-specific file, so machine values can override common ones.

The runner script discovers the env file automatically by hostname:

```bash
# On the Proxmox host — auto-discovers config/<hostname>.env
bash /path/to/repo/scripts/setup/setup.sh
```

On first run, it creates a `/etc/homelab.env` symlink so subsequent runs need no arguments.

### Modules

Modules are standalone, idempotent scripts in `scripts/setup/modules/`. Each handles one concern:

| Module | Purpose | Typical machines |
|--------|---------|-----------------|
| `configure-amdgpu` | Load AMD GPU kernel driver for hardware transcoding | Proxmox host |
| `configure-deploy-worker` | Install target-local signal coalescing, serialized setup, and periodic Git reconciliation | Proxmox host, remote machines |
| `configure-kernel-cmdline` | Ensure the kernel parameters this machine needs (`KERNEL_CMDLINE_PARAMS`, e.g. `iommu=pt`) are set in whichever bootloader config the host actually boots from (`/etc/kernel/cmdline` or `/etc/default/grub`). Never reboots; reports when one is pending | Proxmox host |
| `configure-pi-kiosk` | Set up Cage + Chromium kiosk browser pointing at a URL (Raspberry Pi specific) | Alarm panel Pi |
| `configure-scrutiny-collector` | Install Scrutiny SMART collector (pinned binary) + timer; pushes drive health to the Scrutiny web UI | Proxmox host |
| `configure-macvlan-bridge` | Persist macvlan bridge so host can reach macvlan containers | Docker LXC |
| `configure-network` | Pin a machine to a static IPv4 address (`STATIC_IP`) via NetworkManager | Remote machines |
| [`configure-nvidia-driver`](scripts/setup/modules/configure-nvidia-driver.md) | Install the NVIDIA driver from NVIDIA's CUDA apt repo (open kernel modules via DKMS, headless userspace only), blacklist the in-tree drivers, and create the device nodes + persistence + optional power cap (`NVIDIA_POWER_LIMIT_WATTS`) at boot before guests start. Verifies DKMS actually built for the running kernel; never reboots, reports when one is pending. The companion runbook defines the approval-gated measurement, apply, verification, and rollback path | Proxmox host |
| `configure-proxmox-repos` | Switch from paid enterprise repos to free community repos | Proxmox host |
| `configure-sensors` | Install lm-sensors and persist the hwmon kernel modules for the board's Super I/O chip (`SENSORS_KERNEL_MODULES`), so fan speeds and board temperatures are readable | Bare-metal hosts |
| `configure-smb-mount` | Mount NAS share via CIFS, persist in fstab | Remote machines |
| `configure-lxc-fstrim` | Scheduled `pct fstrim` of LXC rootfs volumes (`LXC_FSTRIM_SCHEDULE`) so blocks freed inside containers return to the LVM thin pool | Proxmox host |
| `configure-docker-image-prune` | Scheduled removal of Docker images no container references (`DOCKER_IMAGE_PRUNE_SCHEDULE`), reclaiming the superseded images left behind by digest bumps | Docker LXC |
| `configure-ssh` | Harden SSH (key-only auth) and deploy authorized keys | All machines |
| `configure-storage-alerts` | Periodic threshold alerts for LVM thin-pool + ZFS pool capacity (the storage Beszel can't see) | Proxmox host |
| `configure-storage-health` | Schedule monthly ZFS scrubs + daily pool health check + SMART self-tests (smartd), with degradation alerting | Proxmox host |
| `configure-ups-monitoring` | Configure a USB UPS through NUT, expose telemetry to Home Assistant, and alert on telemetry/UPS health failures | Proxmox host |
| `create-lxcs` | Create/update LXC containers from env var definitions (integrated-GPU passthrough via `_GPU=1`, NVIDIA passthrough via `_NVIDIA_GPU=1`, USB via `_USB_DEVICES`) | Proxmox host |
| `create-vms` | Create/update VMs (e.g. Home Assistant) | Proxmox host |
| `create-users` | Create Linux users/groups with aligned UIDs across machines | Docker LXC, NAS LXC |
| `install-beszel-agent` | Install the Beszel monitoring agent natively (binary + systemd) on hosts without Docker | Proxmox host, NAS LXC |
| `install-docker` | Install Docker Engine from official apt repo | Docker LXC |
| `install-nvidia-container-toolkit` | Install the userspace NVIDIA driver (matching the host's `NVIDIA_DRIVER_VERSION`) plus the NVIDIA Container Toolkit, so Docker containers can use GPUs passed into the LXC | Docker LXC |
| `install-samba` | Install Samba, generate smb.conf from env vars | NAS LXC |
| `install-tools` | Install common utilities (git, jq, htop, curl) | All machines |
| `provision-host-volumes` | Carve dedicated LVM-thin volumes out of the boot SSD's thin pool and mount them (`HOMELAB_HOST_VOLUMES`), e.g. a fast-NVMe Ollama model store bind-mounted into the Docker LXC | Proxmox host |
| `set-share-permissions` | Apply POSIX ACLs on file share directories | NAS LXC |

### Cascade

The `create-lxcs` module doesn't just create containers — after creation, it runs `setup.sh` inside each LXC via `pct exec`. This means:

```
setup.sh on Proxmox host
  → configure-deploy-worker, configure-proxmox-repos, install-tools, configure-amdgpu, configure-sensors,
    configure-kernel-cmdline, configure-ssh, install-beszel-agent, configure-storage-alerts
  → configure-storage-health (ZFS scrub + SMART self-tests + alerting), configure-scrutiny-collector
  → configure-ups-monitoring (NUT telemetry + UPS health alerting)
  → configure-lxc-fstrim (periodic thin-pool reclaim for LXC rootfs)
  → configure-nvidia-driver (NVIDIA driver + device nodes)
  → provision-host-volumes (dedicated fast-NVMe volumes, e.g. the Ollama model store)
  → create-lxcs
    → creates Docker LXC (GPU passthrough if _GPU=1, NVIDIA if _NVIDIA_GPU=1), then runs setup.sh inside it
      → create-users, install-tools, configure-ssh, install-docker, configure-macvlan-bridge,
        install-nvidia-container-toolkit
      → configure-docker-image-prune (periodic removal of unreferenced Docker images)
      → deploys HOMELAB_SERVICES (Jellyfin, Immich, Caddy, Scrutiny, monitoring, monitoring-agent, etc.)
    → creates NAS LXC, then runs setup.sh inside it
      → create-users, install-tools, configure-ssh, install-samba, set-share-permissions,
        install-beszel-agent
  → create-vms (Home Assistant)
```

Module order matters. `configure-nvidia-driver` must come before `create-lxcs`, for the
same reason `configure-amdgpu` does: a passthrough step can only pass device nodes that
already exist. Inside the LXC, `install-nvidia-container-toolkit` and
`configure-docker-image-prune` must both come after `install-docker`.

One command. Everything configured.

The Proxmox host and NAS LXC don't run Docker, so they get the Beszel monitoring
agent natively (`install-beszel-agent`) instead of the `monitoring-agent` Docker
service that the Docker hosts use — every host reports to the same Beszel hub.

### Adding an LXC

LXCs are defined entirely by env vars. No new scripts needed:

1. Add a prefix to `HOMELAB_LXCS` (e.g. `"DOCKER_LXC NAS_LXC NEW_LXC"`)
2. Define the required vars with that prefix:
   ```
   NEW_LXC_VMID=102
   NEW_LXC_HOSTNAME=mybox
   NEW_LXC_IP=192.168.1.8
   NEW_LXC_MEMORY_MIB=2048
   NEW_LXC_CORES=2
   NEW_LXC_ROOTFS_GIB=8
   NEW_LXC_NESTING=0
   NEW_LXC_MP0=/pool/dataset,mp=/mnt/data
   ```
3. Create a `<hostname>.env` in the config directory for the new LXC's internal setup
4. Re-run `setup.sh`

### Adding a VM

VMs follow the same prefix-based pattern as LXCs:

1. Add a prefix to `HOMELAB_VMS` (e.g. `"HAOS_VM NEW_VM"`)
2. Define the required vars with that prefix:
   ```
   NEW_VM_VMID=103
   NEW_VM_HOSTNAME=myvm
   NEW_VM_MEMORY_MIB=4096
   NEW_VM_CORES=2
   ```
3. Optional vars (with defaults): `_BIOS` (seabios), `_MACHINE` (i440fx), `_OSTYPE` (l26), `_AGENT` (0)
4. To import an existing disk image on first create, set `_IMAGE` to its path on ZFS
5. Re-run `setup.sh`

Unlike LXCs, VMs do **not** cascade — they manage their own OS internally. The `_IP` variable is informational (for documentation and other configs) and is not passed to `qm`.

### Adding a Remote Machine

Machines outside Proxmox (e.g. a Raspberry Pi) can't use ZFS bind mounts — they access config and initial bootstrap source via an SMB mount from the NAS. Automated deployments use a local Git checkout afterward. The `bootstrap-remote.sh` script handles the chicken-and-egg problem: the machine needs the NAS mount before it can install that local deployment worker.

**First-time setup:**

1. Create a `<hostname>.env` in the config directory on the NAS (see `.env.template`)
2. Include `configure-smb-mount` followed by `configure-deploy-worker` in `HOMELAB_SETUP_MODULES` so the mount persists across reboots and the top-level deployment worker is installed
3. Copy `bootstrap-remote.sh` to the machine and run it:
   ```bash
   scp scripts/bootstrap-remote.sh root@<ip>:/root/
   ssh root@<ip>

   SMB_SHARE="//nas-ip/homelab" \
   SMB_MOUNT_POINT="/mnt/homelab" \
   SMB_USERNAME="user" \
   SMB_PASSWORD="pass" \
   bash /root/bootstrap-remote.sh
   ```
4. The script mounts the NAS share, links `/etc/homelab.env`, and runs `setup.sh`
5. Add the machine to `HOMELAB_DEPLOY_TARGETS` and set its `_DEPLOY_HOST` in the webhook host's env file so future pushes wake its worker

After bootstrapping, the machine is fully managed. On every push to `main`, `dispatch.sh` records one pending pass on the target and wakes `homelab-deploy-worker.service`. The worker fetches the latest `origin/main` only after taking the target lock. A path unit preserves signals that arrive during a run, and a timer reconciles missed signals, failed runs, and reboots against the last successful commit. Install the worker only on top-level machines; LXCs reached through a Proxmox cascade are managed by their owning host.

**Pinning a static IP:** to give a remote machine a stable address, set `STATIC_IP` in its `<hostname>.env` and add `configure-network` to `HOMELAB_SETUP_MODULES` (list it first). The module reconciles the address on the connection carrying the default route — it works over Ethernet or WiFi and edits the existing connection in place, so WiFi credentials never leave the machine. It only persists the config; applying it live would drop the session `setup.sh` runs over, so the new address takes effect on the next **reboot** (or a manual `nmcli connection up`). Do the first pin on the device (or over its current address) and reboot, then set the matching `_DEPLOY_HOST` so future pushes reach it at the pinned IP.

### SSH Access

The `configure-ssh` module hardens SSH on every machine (Proxmox host and all LXCs):

- **Key-only authentication** — password login is disabled
- **Root login with key** — `PermitRootLogin prohibit-password`
- **Shared authorized keys** — a single `authorized_keys` file in the config directory (next to the `.env` files) is deployed to all machines automatically

To add or rotate keys, edit `<mount>/homelab/config/authorized_keys` and re-run `setup.sh`. One file, all machines.

Home Assistant uses its own SSH add-on (configured through the HA UI), not this module.

### System Updates

Run `scripts/update.sh` on the Proxmox host to update all system packages:

```bash
bash scripts/update.sh
```

This runs `apt full-upgrade` on each running LXC first, then on the host. If a host reboot is required (e.g. kernel update), it will tell you. VMs are not included — Home Assistant manages its own updates through its UI.

### Users & Groups

The `create-users` module creates Linux users and groups with consistent UIDs/GIDs across all machines that need them (Docker LXC and NAS LXC). This ensures file ownership is identical whether accessed via Samba, Docker bind mounts, or directly on ZFS.

Users and groups follow the same prefix-based pattern as LXCs and VMs, and are defined in `common.env` (shared across machines):

```
HOMELAB_GROUPS="ADMIN ADULTS KIDS FAMILY"
ADMIN_GID=1099
ADULTS_GID=1100

HOMELAB_USERS="DAVID MARIA MAX"
DAVID_UID=1001
DAVID_GROUPS="admin,adults,family"
MARIA_UID=1002
MARIA_GROUPS="adults,family"
MAX_UID=1003
MAX_GROUPS="kids,family"
```

Each prefix requires `_GID` (groups) or `_UID` + `_GROUPS` (users). A user prefix may also set `_SERVICE=1` to mark a service account (see below). Names are derived by lowercasing the prefix. A primary group matching the username and UID is created automatically for each user. User prefixes must not collide with existing `HOMELAB_*` variable names (e.g. don't use `HOMELAB` as a prefix — it would overwrite `HOMELAB_GROUPS`).

To add a user: add their prefix to `HOMELAB_USERS` in `common.env`, define `_UID` and `_GROUPS`, then re-run `setup.sh` on each machine.

**Service account:** A dedicated service account (e.g. `svc`) in the `admin` group exists for infrastructure tasks like SMB mounts from remote machines. This avoids tying infrastructure to a personal account — credential rotation and audit trails stay clean. Remote machines use this account to mount the NAS share and access the repo, config, and appdata. It is marked `_SERVICE=1` (e.g. `SVC_SERVICE=1`): it's in the `admin` group purely for permissions, so the share modules give it **no personal share folder** (an existing empty one is cleaned up on the next `setup.sh` run) and make it a valid user only of the admin infrastructure shares it needs (`homelab`, `media`) — **not** the family file shares. This keeps a repo-sync credential (which lives on a remote machine) from reaching family data over SMB.

### File Sharing & Permissions

The NAS LXC runs Samba for SMB file sharing. Permissions are enforced at the **filesystem layer only** (POSIX ACLs) — Samba controls share visibility (`valid users`) but does not restrict read/write access. This means the same permissions apply whether files are accessed via SMB, Docker bind mounts, or directly on ZFS.

**Permission model:**

| Directory | Owner | Admin | Adults | Kids |
|-----------|-------|-------|--------|------|
| Adult personal dirs | rwx | rwx | r-x | — |
| Kid personal dirs | rwx | rwx | rwx | — |
| `adults/` shared | root | rwx | rwx | — |
| `family/` shared | root | rwx | rwx | rwx |

- **admin** group has full control everywhere
- **adults** group can read other adults' personal dirs, and fully manage kid dirs (parental oversight)
- **kids** can only access their own dir and the family shared folder

**Share organization:**

When `SMB_ROOT_SHARE` is set, a single root share exposes all user folders and shared dirs. Users map one drive and navigate to their folder. ACLs prevent them from opening folders they don't have access to. Individual per-user shares and `adults`/`family` shares are omitted to keep the share list clean.

Infrastructure shares (`media`, `homelab`) are admin-only — non-admin family members access media through applications (e.g. Jellyfin), not the raw files. The `homelab` share's `config/`, `backup/`, `appdata/`, `repo/`, and `images/` subdirectories are set to `root:admin 775` so admin users can edit env files, write backups (e.g. Home Assistant), and deposit VM images/ISOs via SMB. Dirs listed in `SMB_ADMIN_CONFIG_DIRS` are a deliberate, scoped exception to "appdata is owned by its writing service": they hold configuration a service writes but an admin also hand-edits, so `install-samba` keeps each `root:admin` with a default ACL granting the `admin` group write and normalizes contained files to be group-writable but not world-readable. The backup service's rclone config dir is the current example — `rclone.conf` is admin-edited yet the rclone container also rewrites it.

Samba share definitions are **generated** by `install-samba` from the user/group env vars — no static config file to maintain. The `[global]` section lives in `nas/smb.conf.global` in the repo.

After creating the NAS LXC, set each user's Samba password:
```bash
smbpasswd -a <username>
```

## Storage Health

The ZFS pool and physical drives are owned by the **Proxmox host** (bare metal), so
scrubs and drive SMART tests are host-level concerns, configured by setup modules and
run via systemd timers:

- **`configure-storage-health`** (Proxmox host):
  - **Monthly ZFS scrub** of `ZFS_POOL` (first Sunday by default) — `zpool scrub -w`
    followed by an error check. Monthly is the safe cadence for spinning disks.
  - **Daily ZFS pool health check** — catches degraded/faulted vdevs and data errors
    between scrubs.
  - **SMART self-tests via smartd** on all drives — short daily, long monthly — plus
    drive-attribute/health monitoring (reallocated/pending sectors, failing self-test,
    temperature). smartd logs any degradation to syslog/journal. (Long tests are slow on
    large drives — tens of hours on a multi-TB drive — so the default cadence is monthly,
    not weekly.)

- **Scrutiny** (web UI + SMART history) is split to fit the architecture:
  - **`services/scrutiny/`** (Docker host) — the web UI + InfluxDB backend (no disk
    access needed). LAN-only dashboard (accessed by `DOCKER_HOST_IP:SCRUTINY_WEB_PORT`,
    not exposed via Caddy), like Beszel / Uptime Kuma / Dozzle.
  - **`configure-scrutiny-collector`** (Proxmox host) — the collector runs where the
    physical disks are, as a binary on a timer, and POSTs SMART data to the web UI. It
    only *reads* SMART data; smartd owns self-test *scheduling*, so the two never
    double-schedule tests. The collector **version is derived from the `scrutiny` web
    image tag** in `services/scrutiny/docker-compose.yml` (the single source Renovate
    bumps) and the downloaded binary is verified against GitHub's published sha256 digest
    — so a Renovate web-image bump carries the collector automatically, with no second
    version/checksum to keep in lockstep.

Failures are delivered through the shared `HOMELAB_ALERT_SHOUTRRR_URL` channel (Pushover
in the current deployment) where the component supports it, with systemd/journal logging
as the fallback. Scrutiny uses the URL directly; the host-side checks use the pinned
Shoutrrr CLI installed by the setup modules.

**Schedules are opt-out per feature.** Each scheduled task is gated by its schedule env
var (`ZFS_SCRUB_SCHEDULE`, `ZFS_HEALTH_CHECK_SCHEDULE`, `SMART_SELFTEST_SCHEDULE`,
`SCRUTINY_COLLECTOR_SCHEDULE`). `.env.template` ships recommended defaults; **clear a value
(set it empty) to disable that specific feature** — the module then removes the
corresponding timer. (smartd still runs for monitoring even with self-tests disabled.)

## UPS Monitoring

The Proxmox host can monitor a USB-connected UPS with the `configure-ups-monitoring`
module. It installs Network UPS Tools (NUT), configures the `usbhid-ups` driver, and
publishes read-only telemetry on the host's LAN address for monitoring clients.

Set `NUT_UPS_NAME`, `NUT_LISTEN_ADDRESS`, and the optional UPS alert thresholds in the
host env file, then add `configure-ups-monitoring` to `HOMELAB_SETUP_MODULES`. The module
fails setup unless NUT reports `ups.status`, `ups.load`, `battery.charge`, and
`battery.runtime`, so a disconnected or unsupported UPS cannot look successfully
configured.

Beszel does not currently have native UPS/NUT metrics, and Uptime Kuma has no NUT monitor.
Home Assistant is the existing dashboard that exposes the full device state:

1. In Home Assistant, go to **Settings → Devices & services → Add Integration** and add
   **Network UPS Tools (NUT)**.
2. Use `NUT_LISTEN_ADDRESS`, port `3493`, and leave the optional credentials blank.
3. Confirm the device exposes status, load, battery charge, and battery runtime. Runtime is
   a diagnostic entity and may need to be enabled on the integration's entity page.

The host also runs `ups-status-check.sh` every 15 seconds. It alerts through
`HOMELAB_ALERT_SHOUTRRR_URL` when telemetry remains unavailable, the UPS reports unhealthy
flags, or load crosses `UPS_LOAD_WARNING_PERCENT`. On-battery alerts are delayed by
`UPS_ON_BATTERY_ALERT_DELAY_SECONDS` so brief Powerwall transfers do not create noise.
The NUT shutdown controller (`nut-monitor`) is explicitly disabled: this setup is
monitoring-only and does not implement automatic shutdown or load shedding.

## Rebuild & Restore

LXC root filesystems are ephemeral — `setup.sh` can rebuild them from this repo at any time (the modules are idempotent, so a normal run just reconciles to the declared state rather than rebuilding), so there's no manual restore for them. VMs manage their own OS, so rebuilding the Home Assistant VM is a restore-from-backup flow with a few inherent manual steps that can't be captured declaratively.

### Home Assistant (HAOS VM)

On a rebuild, `create-vms` imports the pinned base image (`HAOS_VM_IMAGE`) into a fresh VM. Home Assistant boots clean, then you restore your configuration from a backup.

- **Backups** are written by HA's auto-backup to the `backup/` directory of the `homelab` share on the NAS (ZFS-backed, so they survive a host or LXC rebuild). Restore the most recent one from the HA onboarding screen (or **Settings → System → Backups**).
- Keep `HAOS_VM_IMAGE` reasonably current (see below). Restoring a backup onto a base whose Home Assistant Core is *older* than the backup can fail — a fresh base should be at least as new as the backup it will restore.

**Manual steps after a rebuild** — these live outside HA backups *and* the repo, so set them by hand:

1. **Re-set the static IP.** A fresh HAOS image boots on DHCP, and HA backups do not include HAOS host network settings, so the VM comes up on a DHCP address instead of its expected static IP. Re-apply the static IP in **Settings → System → Network** (this homelab configures static IPs client-side, inside the guest — not via router DHCP reservations), then confirm the VM is reachable at its expected address.
2. **Re-set Samba passwords** on the NAS after a NAS LXC rebuild — Samba passwords aren't stored in the repo or env files. See [File Sharing & Permissions](#file-sharing--permissions) (`smbpasswd -a <username>`).

### Refreshing the pinned HAOS image

`HAOS_VM_IMAGE` pins the base image a rebuild imports. Refresh it periodically — e.g. alongside a major HA upgrade, or a couple of times a year — so a rebuild starts close to the running version instead of far behind (which also avoids the older-base restore-failure risk above):

1. Find the latest release at <https://github.com/home-assistant/operating-system/releases> and note its `haos_ova-<version>.qcow2.xz` asset and that asset's published SHA256.
2. Download it into the NAS images directory (admin-writable over SMB, or via the host/NAS shell), verify the checksum against the published digest, and decompress:
   ```bash
   cd <images_dir>/HomeAssistant
   curl -fLO https://github.com/home-assistant/operating-system/releases/download/<version>/haos_ova-<version>.qcow2.xz
   sha256sum haos_ova-<version>.qcow2.xz   # must match the release's published digest
   xz -d haos_ova-<version>.qcow2.xz       # -> haos_ova-<version>.qcow2
   ```
3. Point `HAOS_VM_IMAGE` (in the host's env file) at the new `.qcow2`.

`_IMAGE` is imported on **first VM create only**, so bumping the pin never touches the running VM — it only changes what a future rebuild starts from.

## Services

Each service is a Docker Compose project in `services/<name>/`. All configuration is parameterized via env vars — no hardcoded domains, IPs, or paths in compose files.

Deploy a single service:
```bash
./scripts/run-service.sh jellyfin
```

Deploy all services configured for this machine:
```bash
./scripts/run-all-services.sh
```

Services are defined per-machine in the env file:
```
HOMELAB_SERVICES=dns,reverse-proxy,jellyfin,photos,files,monitoring,homepage,dozzle
```

### Authelia (SSO)

`services/authelia/` runs [Authelia](https://www.authelia.com) as the homelab's **single sign-on /
identity provider**, giving the family one login for the services that support it and letting admin
surfaces sit behind 2FA. It integrates two ways:

- **OpenID Connect (OIDC)** — Authelia is an OIDC provider; apps that speak OIDC (Open WebUI,
  Forgejo, Immich, Vikunja, Miniflux, …) redirect their login to it. This also works for those
  apps' native/mobile clients, so it's preferred wherever supported.
- **forward-auth** — Caddy can gate a browser-only web UI (e.g. an admin dashboard) by delegating
  the auth decision to Authelia.

**[Open WebUI](#ai-ollama--litellm--open-webui) is wired via OIDC**, keeping its local
login as break-glass. Some services deliberately stay on their **own** auth because SSO breaks their
native clients — Jellyfin (TV/mobile apps), Home Assistant (companion app), Radicale (CalDAV Basic
auth) — which also makes them accidental break-glass access if Authelia is down.

Config is declarative: `services/authelia/configuration.yml` is committed and mounted read-only
(like the Caddyfile), carrying **no secrets and no personal domains**. Scalar secrets come from
`AUTHELIA_*` env vars; personal values (domains, the OIDC issuer key) are injected at load time by
Authelia's `template` config filter. The file user backend (`users.yml`) and the OIDC issuer key are
secrets kept on the NAS at `${CONFIG_DIR}/authelia/`, never in this repo. Authelia's own state — the
SQLite DB of TOTP enrollments + user preferences, and the filesystem notifier file — persists on
`${DOCKER_APPDATA_ROOT}/authelia` (ZFS-backed). Sessions are stored **in-memory** (no Redis): the
only cost is re-login after an Authelia restart; 2FA enrollments persist in SQLite regardless.

Caddy proxies `AUTHELIA_FQDN` to the container (`localhost:${AUTHELIA_HTTP_PORT}`); wildcard DNS
already resolves the host, so only the Caddy site block is needed. Deploy by adding `authelia` to
`HOMELAB_SERVICES`. **First-run setup (secrets, `users.yml`, the OIDC issuer key, the client-secret
pair) and the reusable per-app OIDC / forward-auth recipes are documented in
[`services/authelia/README.md`](services/authelia/README.md).**

### AI (Ollama + LiteLLM + Open WebUI)

`services/ai/` runs the family AI stack as a single compose project on the shared internal
`ai` Docker network: [Ollama](https://ollama.com) for local LLM serving,
[LiteLLM](https://www.litellm.ai/) for authenticated OpenAI-compatible routing and usage
accounting, and [Open WebUI](https://openwebui.com) as the multi-user chat frontend.

Ollama serves on the CPU by default. On a machine with NVIDIA GPUs it can use them
instead, which is a per-machine env-file decision rather than a compose change: set
`OLLAMA_RUNTIME=nvidia` and `OLLAMA_NVIDIA_VISIBLE_DEVICES=all` (or a comma-separated index
list, to leave some cards for another workload). That requires the GPUs to have reached
Docker first — on a Proxmox host that means `configure-nvidia-driver` on the hypervisor,
`_NVIDIA_GPU=1` on the LXC, and `install-nvidia-container-toolkit` inside it. Those are all
setup modules, which `setup.sh` runs before deploying any service, so a rebuilt machine
wires itself up in the right order. Setting the runtime without the toolkit in place fails
the container at start rather than falling back to CPU — deliberately, since a GPU-sized
model quietly running on the CPU is far more expensive to notice than a failed deploy.
`OLLAMA_MAX_LOADED_MODELS` / `OLLAMA_NUM_PARALLEL` / `OLLAMA_CONTEXT_LENGTH` are tuned for
CPU serving and are worth revisiting once weights live in VRAM.

Ollama's data dir (pulled models + cache) is bind-mounted to `/root/.ollama` from
`OLLAMA_MODELS_ROOT` so models survive container recreation. Point it at a faster
store — e.g. an NVMe-backed volume carved by `provision-host-volumes` and bind-mounted
into the Docker LXC via a `_MP*` entry — to speed up cold model loads (and let you relax
`OLLAMA_KEEP_ALIVE`). Leave it blank to fall back to the ZFS-backed
`${DOCKER_APPDATA_ROOT}/ollama`. Ollama has **no authentication**, so it is never placed
behind the public reverse proxy — it is reachable only on the internal `ai` network (Open
WebUI reaches it at `http://ollama:11434`) and, via `OLLAMA_HTTP_PORT`, on the LAN.

LiteLLM is the durable routing boundary between OpenAI-compatible clients and Ollama. Its model
aliases and backend mappings are deliberately **not** committed to this repository. They live in the
ZFS-backed `${CONFIG_DIR}/litellm/config.yaml`, mounted read-only into the gateway. This keeps
workload names and model choices operational configuration: aliases can be added or remapped without
a repository change, while callers remain independent of Ollama model tags.

Repository scripts do not parse, validate, or rewrite the operator-owned YAML. Keep every backend on
`ollama_chat/...` at `http://ollama:11434`, omit callbacks and fallback routing, and retain the
privacy/database settings described below. Declaring a profile does not pull its backend model —
ensure each selected model is already present through `OLLAMA_PULL_MODELS` or an approved manual
pull.

LiteLLM publishes `${LITELLM_HTTP_PORT}:4000` for authenticated LAN clients and has no Caddy route.
Its PostgreSQL state persists under `${DOCKER_APPDATA_ROOT}/litellm/db`. The `ai` post-up hook
declaratively reconciles every prefix in `LITELLM_CLIENTS`. Each prefix supplies its reporting alias,
fixed virtual key, and space-separated model allowlist through
`LITELLM_<PREFIX>_{KEY_ALIAS,API_KEY,MODELS}` in the external env file. `OPEN_WEBUI` is required;
other clients are configuration-driven. The master key is administrative and must never be given to
a client. Generate the master key, immutable salt, and each client key independently as `sk-`
followed by random data.

Open WebUI **does** have its own multi-user auth (the first account created becomes the
admin), so unlike Ollama it is exposed via Caddy at `OPEN_WEBUI_FQDN`. It is also reachable
on the LAN at `http://<docker-host-ip>:${OPEN_WEBUI_HTTP_PORT}`. Its SQLite DB + ChromaDB
(per-user chats, settings, RAG vectors) persist on `${DOCKER_APPDATA_ROOT}/open-webui`
(ZFS-backed).

Open WebUI is also **protected by [Authelia](#authelia-sso) SSO** (OIDC), enforced **SSO-only**: the
local login form is disabled and the login page redirects straight to Authelia. Every user must
complete TOTP 2FA (enrolled on first login). The wiring is
the `OPENID_PROVIDER_URL` / `OAUTH_CLIENT_ID` / `OAUTH_CLIENT_SECRET`
env on the `open-webui` service; see the Authelia section for the client setup.

First-run setup notes:
- **Claim the admin account immediately on a fresh deploy.** Open WebUI is internet-facing
  from the first deploy, and the first account to register becomes the admin/owner (the
  initial-admin signup intentionally bypasses the signup toggle). Create yours right away —
  ideally over the LAN at `http://<docker-host-ip>:${OPEN_WEBUI_HTTP_PORT}` before sharing the
  public URL — so nobody else can claim it.
- Public self-registration is disabled (`ENABLE_SIGNUP=false`); add each family member via
  Admin Settings → Users → Add User. New accounts also default to `pending` (no model
  access) until approved.
- Switch tool calling to **Native** mode (the prompt-injection "Default" mode is deprecated)
  per model that needs tools.
- **Chat runs through LiteLLM over Open WebUI's OpenAI-compatible connection, not its native Ollama
  one.** The OpenAI path preserves multiple tool calls that Open WebUI's Ollama middleware mangles;
  LiteLLM still routes the request only to the same local Ollama server. Keep the base URL fixed at
  `http://litellm:4000/v1` and select one of the profiles allowed by
  `LITELLM_OPEN_WEBUI_MODELS`. The native Ollama connection remains enabled for RAG embeddings and
  model management. Because the OpenAI protocol has no per-request context field, a model's
  `num_ctx` set in the Open WebUI UI is ignored on this path — the context window comes from
  Ollama's `OLLAMA_CONTEXT_LENGTH` instead.
- On a **fresh** Open WebUI database, Compose seeds the LiteLLM URL, its dedicated key, and the
  `x-litellm-end-user-id: {{USER_ID}}` connection header. That connection also blanks
  `X-OpenWebUI-User-Jwt` and all `X-OpenWebUI-User-{Name,Id,Email,Role}` headers so the global Athena
  identity forwarding setting does not copy names or email addresses into LiteLLM. On an
  **existing** instance these are PersistentConfig: add all those custom headers in Admin Settings
  → Connections with the same URL and key. Open WebUI substitutes the authenticated user's opaque,
  stable internal ID server-side; do not substitute a name or email.
- `OPEN_WEBUI_TASK_MODEL` seeds a small/fast task model (e.g. `qwen2.5:7b`) for
  native-Ollama title/tag/query generation; `OPEN_WEBUI_TASK_MODEL_EXTERNAL` selects the configured
  LiteLLM profile for the same work. These are first-launch-seeded PersistentConfig values under
  Admin Settings → Interface. If the applicable model does not resolve, background tasks run on the
  large chat model. That evicts the conversation's cached prompt prefix and can make the next
  CPU-served turn re-prefill the whole context. Both task model IDs must also be readable by
  non-admin users under Admin Settings → Models.
- `OPEN_WEBUI_RAG_EMBEDDING_MODEL` (e.g. `nomic-embed-text`) is used via the local Ollama
  for RAG embeddings instead of Open WebUI's bundled embedder.

Models are **pulled declaratively**: the `ollama-pull` container pulls everything in
`OLLAMA_PULL_MODELS` (set per machine in the env file; `.env.template` documents the
recommended set) on each deploy, once the server is healthy, then exits. This is
idempotent — already-present models are skipped. Large pulls run in the background; follow
progress with:
```bash
docker logs -f ollama-pull
```
To pull an extra model ad-hoc: `docker exec ollama ollama pull <model>`.

Qwen3.6 models are hybrid-thinking: pulling a model does not select a reasoning mode. For
non-thinking chats over an OpenAI-compatible connection, set the Open WebUI model's
**Reasoning Effort** advanced parameter to `none`.

#### LiteLLM operations, privacy, and rollout

The LiteLLM Admin UI is available only on the authenticated LAN port at
`http://<docker-host-ip>:${LITELLM_HTTP_PORT}/ui`; sign in as `admin` with
`LITELLM_MASTER_KEY`. For periodic usage review, group by the configured virtual-key alias first,
then by model profile. Only the key configured for the `OPEN_WEBUI` prefix makes its opaque end-user
ID trustworthy for family attribution. The same header on any other client is self-declared and
must not be interpreted as trusted family identity.

Usage records retain the key, profile, selected backend model, opaque end-user ID, token counts,
timing, and outcome. `store_prompts_in_spend_logs: false` stores empty request/response objects
instead of prompt and completion bodies, and `turn_off_message_logging: true` keeps bodies out of
proxy logs. Do not enable prompt logging or external callbacks. Names and email addresses remain in
Open WebUI and are not copied into LiteLLM.

Deploy this seam during a low-use window:

1. Create `${CONFIG_DIR}/litellm/config.yaml` on the ZFS-backed config dataset. Define the desired
   `model_list` there with literal `ollama_chat/...` backends and `api_base: http://ollama:11434`.
   Set `litellm_settings.turn_off_message_logging: true`, and under `general_settings` set
   `master_key: os.environ/LITELLM_MASTER_KEY`, `database_url: os.environ/DATABASE_URL`,
   `store_model_in_db: false`, and `store_prompts_in_spend_logs: false`. Do not configure callbacks
   or fallbacks.
2. Put all `LITELLM_*` values documented in `.env.template` in the Docker LXC's external env file.
   For each `LITELLM_CLIENTS` prefix, make its `_MODELS` values match aliases in the external YAML.
   Keep `LITELLM_SALT_KEY` unchanged for the lifetime of the database. If a client prefix or key
   alias is removed or renamed later, delete the old alias in the LiteLLM Admin UI; reconciliation
   only manages aliases currently listed in `LITELLM_CLIENTS`.
3. Inside the Docker LXC, deploy `ai`. After the gateway is healthy, the post-up hook creates or
   updates the configured keys.
4. With the master key, confirm the LiteLLM model list matches the external config. With each virtual
   key, confirm its model list and allowlist before migrating a caller.
5. Validate the initial interactive coding client first with its own key and configured profile; do
   not give it the master or Open WebUI key. Keep its prior endpoint/model configuration available
   and restore it immediately if listing, streaming, or inference fails.
6. Before moving family use, retain the existing direct-Ollama OpenAI connection. On a fresh Open
   WebUI database, where Compose seeds only LiteLLM, add a separate direct-Ollama OpenAI connection
   as the rollback path. For an existing database, add a separate LiteLLM connection with the
   `LITELLM_OPEN_WEBUI_API_KEY` and all custom headers described above; do not replace the direct
   connection.
7. Select an allowed interactive profile and verify model listing, streaming, non-thinking controls,
   the configured external task profile, multiple/parallel Athena tool calls, Athena's signed user
   identity, and distinct opaque end-user IDs in LiteLLM usage.
8. Only after those checks pass, point normal family chats at the LiteLLM connection.

If any Open WebUI compatibility or identity check fails, switch chats back to the retained
direct-Ollama OpenAI connection. If the coding client fails, restore its prior endpoint and model.
Repository rollback is the prior repository revision, but Open WebUI connection values are
PersistentConfig and must also be restored in Admin Settings; a Git/Compose revert does not
overwrite them. The external LiteLLM YAML is outside Git, so copy it to a verified sibling backup
before each change and restore that copy separately when rolling back. Leave
`${DOCKER_APPDATA_ROOT}/litellm/db` intact so keys and accounting remain recoverable. Do not delete
the database directory or rotate the salt as part of rollback. Existing direct Ollama callers are
otherwise unaffected.

Open WebUI's native **web search** is disabled; Athena MCP exposes bounded `web_search` and protected
`fetch_url` tools instead. SearXNG remains the private backend for Athena's search tool.

### Web search (SearXNG)

The `services/ai/` stack also runs [SearXNG](https://docs.searxng.org), a self-hosted
metasearch engine, as the homelab's **private web-search backend**. It backs Athena MCP's
`web_search` tool without relying on Open WebUI's scraping-based, rate-limit-prone DuckDuckGo
backend. SearXNG is a backend, not a family-facing UI — it has **no auth**, so like Ollama it is
never placed behind the public reverse proxy. It publishes no host port: consumers reach it over
the shared `ai` Docker network at `http://searxng:8080`.

Config is declarative: `services/ai/searxng/settings.yml` is mounted read-only and carries only
the overrides on top of SearXNG's defaults — chiefly enabling the **JSON API**
(`search.formats: [html, json]`) so programmatic clients can query it. Its runtime cache
persists on `${DOCKER_APPDATA_ROOT}/searxng` (ZFS-backed).

- `SEARXNG_SECRET` (a **secret**, never committed) is injected at runtime and overrides
  SearXNG's `server.secret_key`. Generate one with `openssl rand -hex 32`.
- Open WebUI's native category is seeded disabled with `ENABLE_WEB_SEARCH=false`. This is an Open
  WebUI **PersistentConfig** value — read on first launch then managed in the UI/DB, so changing it
  later requires re-seeding (wiping the Open WebUI data) or updating Admin Settings → Web Search.
- SearXNG deploys as part of the `ai` service — no separate `HOMELAB_SERVICES` entry is needed.

### Athena MCP (family tools)

The `services/ai/` stack also runs **Athena MCP**, an [MCP](https://modelcontextprotocol.io) server
that exposes homelab health, shopping lists, calendars, contacts, media, photos, tasks, weather,
public-web tools, and curated Home Assistant state/actions over Streamable HTTP, consumed by **Open
WebUI's native MCP** client. `web_search` returns at most five bounded SearXNG results without
fetching their pages; `fetch_url` separately retrieves bounded text from one selected public HTTP(S)
page while blocking private-network destinations, automatic or unvalidated redirects, compressed
bodies, scripts, and subresources.

Like Ollama and SearXNG it has **no auth**, so it is never placed behind the public reverse proxy: it
publishes no host port and is reachable only over the shared `ai` Docker network at
`http://athena-mcp:8080`. It deploys as part of the `ai` service — no separate `HOMELAB_SERVICES`
entry is needed.

The image is our own, built + published by the `athena-mcp` repo's Forgejo CI (`dotnet publish
-t:PublishContainer`, no Dockerfile) to the Forgejo OCI registry (the same one Forgejo hosts — see
[`services/forgejo/README.md`](services/forgejo/README.md)). It is **private and pinned by tag AND
digest** (`${CONTAINER_REGISTRY}/david/athena-mcp:<tag>@sha256:…`). Renovate can't reach the private
registry, so the pin is bumped by hand: get the newest tag from the athena-mcp CI publish job summary
and the digest from that build's registry manifest, then update both in `services/ai/docker-compose.yml`.

Config is via env vars (see the `ATHENA_MCP_*` keys in `.env.template`). The Beszel/Scrutiny/Proxmox
and Koffan *connection* details are reused from those services' own vars (Koffan is reached over the
host's published port, `${DOCKER_HOST_IP}:${KOFFAN_HTTP_PORT}`, since it runs on a separate network).
Home Assistant reuses `HOMEASSISTANT_IP` / `HOMEASSISTANT_HTTP_PORT`; its per-user tokens and
hazard-focused denylist use `ATHENA_MCP_HOMEASSISTANT_*`. The other `ATHENA_MCP_*` keys are this
service's own credentials. The internal SearXNG URL and established English search policy are fixed
in compose. The search and direct-fetch domain filters default to empty, matching an unrestricted
native domain-filter list. `Homelab__Proxmox__AllowInsecureTls=true` is set in compose (config, not a
secret): the Proxmox API presents a self-signed cert, trusted for this client only.

**One-time operator setup** (needs admin on Forgejo/Beszel/Proxmox/Home Assistant + write access to
the NAS config):

1. **Give the Docker host registry credentials** so it can pull the image. This is declarative: set
   `CONTAINER_REGISTRY`, `CONTAINER_REGISTRY_USER`, and `CONTAINER_REGISTRY_TOKEN` (a `package:read`
   Forgejo PAT) in the NAS env. The `ai` stack's pre-deploy hook (`services/ai/pre-up.sh`) logs the
   Docker host into the registry automatically right before it pulls `athena-mcp` — no manual
   `docker login`, and it re-authenticates after an LXC rebuild.

   > **Single-pass cold re-pave.** The registry is the Forgejo FQDN served through the reverse proxy
   > (`dns` → `reverse-proxy` → `forgejo`). A setup module runs before any service and would deadlock
   > a from-scratch re-pave, so the login lives in the `ai` pre-up hook instead. **List `dns`,
   > `reverse-proxy`, and `forgejo` before `ai` in `HOMELAB_SERVICES`** so that path is up when the
   > hook runs; a single `setup.sh` then converges with no manual steps.
2. **Create a read-only Beszel user** and set `ATHENA_MCP_BESZEL_IDENTITY` / `_PASSWORD`
   (`_AUTH_COLLECTION` defaults to `users`; use `_superusers` only if a superuser is required to read
   every host). **Share each monitored host with this user** in Beszel, or it is silently missing from
   `list_systems`.
3. **Grant Proxmox read-only access.** With privilege separation (the default) the token's effective
   permissions are the *intersection* of the user's and the token's ACLs, so **both** need the role:
   `pveum acl modify / --users 'athena@pve' --roles PVEAuditor` **and**
   `pveum acl modify / --tokens 'athena@pve!mcp' --roles PVEAuditor`. Set `ATHENA_MCP_PROXMOX_TOKEN_ID`
   (`user@realm!tokenid`), `ATHENA_MCP_PROXMOX_TOKEN_SECRET`, and `ATHENA_MCP_PROXMOX_NODE` (the node
   whose storage/guests to report).
4. **Provision Home Assistant per-user access.** Keep HA's conversation-Assist exposure limited to
   entities Athena may read. For each Open WebUI family user, create a long-lived token while signed
   into that same person's HA profile and set the matching
   `ATHENA_MCP_HOMEASSISTANT_USER_<n>_EMAIL` / `_TOKEN`. The email must match the forwarded Open
   WebUI identity exactly. Populate `ATHENA_MCP_HOMEASSISTANT_DENIED_ENTITY_ID_<n>` from a fresh
   hazard inventory so consequential entities can still be read but never receive an action proof.
5. **Register the server in Open WebUI** (PersistentConfig/UI state) at
   `http://athena-mcp:8080`, grant it to the intended users/groups, and attach it to the Athena
   model. Keep that model's `builtin_tools` capability disabled. The server spotlights every tool
   result inside an escaped `<external_data>` provenance boundary; set the model's system prompt to
   state that content inside that boundary is untrusted data, never instructions, and must not be
   echoed. Deploying the container only makes new tools reachable through an existing unfiltered
   connection; it does not create the connection, grants, model attachment, or prompt.

After `./scripts/run-service.sh ai`, confirm `docker ps` shows `athena-mcp` `(healthy)` and
`docker exec open-webui curl -s http://athena-mcp:8080/health` returns `Healthy`.

Sign in as a non-admin user through the Athena model and confirm `web_search` returns no more than
five relevant result records and `fetch_url` retrieves a selected public result. Open WebUI v0.10.2
does not guarantee native source cards for these MCP tools, so treat the returned/final URLs as
authoritative. Native search is PersistentConfig: keep it disabled under Admin Settings -> Web
Search on an existing instance.

> **Health check:** the ASP.NET runtime image has no `curl`/`wget`/`bash`, so the container can't
> probe its `/health` endpoint with a shell command. Instead the app probes itself — the `healthcheck`
> re-invokes the binary as `dotnet /app/AthenaMcp.Server.dll --health-check`, which issues an
> in-process GET to `/health` and exits `0` (healthy) / non-zero (unhealthy).

### Home Assistant tools (curated Athena MCP wrapper)

Home Assistant is integrated directly into Athena MCP instead of through a generic MCP/OpenAPI
bridge. The wrapper exposes six tools:

- `get_home_state` reads current Assist-exposed state.
- `resolve_home_target` resolves one exact non-group target and may issue a short-lived proof.
- `set_light`, `set_switch`, `set_fan`, and `set_climate_temperature` perform one fixed,
  idempotent action against the proved exact entity.

There is no arbitrary service call, toggle, batch, area/floor fan-out, lock, cover, garage, alarm,
siren, valve, button, scene, script, automation, broadcast, timer cancellation, or Home Assistant
media control. Jellyfin remains the separate read-only media-library surface.

The server verifies the forwarded Open WebUI user JWT, then selects that person's HA long-lived
token. Read visibility and target resolution remain bounded by HA's global conversation-Assist
exposure. Writes add several server-enforced gates:

1. An exact name must resolve to one supported non-group entity.
2. Broad or unsupported lookups make that Open WebUI message read-only.
3. The resolver signs a short-lived proof bound to the caller, chat, message, capability, and entity.
4. A single in-memory turn ledger permits at most one HA action in that message.
5. `ATHENA_MCP_HOMEASSISTANT_DENIED_ENTITY_ID_<n>` blocks known hazardous exact entities and groups
   containing them even when they otherwise resolve.

This safety contract requires **one Athena MCP process**. Do not scale the service to non-sticky
replicas: another process would have a different turn ledger and could issue a second action budget.
Drain active Athena responses before replacing the container.

The old HA bridge and the wrapper must never be live as simultaneous action surfaces. For a cutover,
temporarily restrict the Athena model to the operator, drain active responses, deploy the wrapper
configuration and bridge removal, apply the coordinated Athena prompt, verify that the existing
Athena MCP binding exposes the wrapper tools, and remove any legacy HA binding if one exists. Run
read-only checks before performing only explicitly approved reversible action probes. Keep the
previous image pin, bridge configuration, Open WebUI model/tool backup, and old bridge token
available until verification is complete. Rollback restores the prior homelab commit first, waits
for the old image and bridge to be healthy, then restores the old Open WebUI prompt/binding before
family access is reopened.

### Vikunja (task management)

`services/vikunja/` runs [Vikunja](https://vikunja.io), the self-hosted task manager, as a
single compose project: the merged API/web `vikunja` container plus a dedicated `vikunja-db`
Postgres container. They share the project's default network, so Vikunja reaches the database
at the `vikunja-db` hostname. Both the Postgres data directory and Vikunja's task-attachment
files persist under `${DOCKER_APPDATA_ROOT}/vikunja/` (ZFS-backed).

Vikunja has its own multi-user auth, so it is exposed via Caddy at `VIKUNJA_FQDN` and is also
reachable on the LAN at `http://<docker-host-ip>:${VIKUNJA_HTTP_PORT}`. DB credentials and the
JWT signing secret (`VIKUNJA_DB_USERNAME`, `VIKUNJA_DB_PASSWORD`, `VIKUNJA_JWT_SECRET`) are
secrets and are set in the env file of the machine running the service, never in the repo.

First-run setup notes:
- **Create the family accounts.** Self-registration is disabled
  (`VIKUNJA_ENABLE_REGISTRATION=false`), so provision each account with the CLI inside the
  running container. Omit `-p` to be prompted for the password interactively, or pass it
  explicitly; the password is set at creation time (there is no first-login setup step):
  ```bash
  docker exec -it vikunja /app/vikunja/vikunja user create -u <username> -e <email>
  ```
  In this version user administration (create / list / disable / delete) is done through the
  `vikunja user` CLI — there is no in-app admin role. To allow temporary self-registration
  instead, set `VIKUNJA_ENABLE_REGISTRATION=true`, redeploy, register, then set it back to
  `false`.

### Koffan (shared shopping list)

`services/koffan/` runs [Koffan](https://github.com/PanSalut/Koffan), a featherweight local-first
shopping-list PWA (Go + Fiber + SQLite, ~2.5 MB RAM). It is a **dedicated** app for the household
shopping list — task management stays in Vikunja. It supports multiple named lists (e.g. Grocery,
Costco), works fully offline and auto-syncs on reconnect, and updates in real time over WebSocket
while the app is open on multiple devices.

A single container persists its SQLite database at `${DOCKER_APPDATA_ROOT}/koffan/shopping.db`
(ZFS-backed). It is exposed via Caddy at `KOFFAN_FQDN` (also on the LAN at
`http://<docker-host-ip>:${KOFFAN_HTTP_PORT}`); Caddy upgrades the WebSocket automatically.
Setting `KOFFAN_API_TOKEN` (a secret) enables a token-gated REST API
([wiki](https://github.com/PanSalut/Koffan/wiki/REST-API)).

**Auth.** Koffan has a simple single-password login (`KOFFAN_APP_PASSWORD`, a secret; a blank value
falls back to Koffan's public default, so set a strong one). Since it is publicly exposed, once
Authelia is in place move Koffan behind it: set `KOFFAN_DISABLE_AUTH=true` (defaults `false`, which
ignores `APP_PASSWORD`), bind the host port to localhost (or drop it) so the LAN can't bypass the
proxy, and add `forward_auth` to the Caddy block for the UI/`/ws` while **bypassing `/api/*`** (the
REST API uses its own `API_TOKEN` bearer and can't do interactive SSO).

### Radicale (CalDAV/CardDAV)

`services/radicale/` runs [Radicale](https://radicale.org), a self-hosted CalDAV/CardDAV
server — the homelab's **calendar** (`VEVENT`) and **contacts** (`VCARD`) store. Family
devices sync to it with standard clients (Apple Calendar/Contacts, DAVx⁵ on Android,
Thunderbird). It uses the hardened [`tomsquest/docker-radicale`](https://github.com/tomsquest/docker-radicale)
image (read-only root filesystem, all capabilities dropped except the few its entrypoint
needs, no-new-privileges; runs as a non-root user).

Radicale keeps its **own htpasswd auth** (bcrypt) and is deliberately **not** placed behind
Authelia/forward-auth: native CalDAV/CardDAV clients authenticate with HTTP Basic auth, which
a forward-auth layer would break. It **is** exposed publicly via Caddy at `RADICALE_FQDN`
(site block in `services/reverse-proxy/Caddyfile`), so per-user credentials must be strong. It
is also reachable on the LAN at `http://<docker-host-ip>:${RADICALE_HTTP_PORT}`.

Config is declarative: `services/radicale/config` is mounted read-only (filesystem storage,
htpasswd+bcrypt auth, `from_file` rights). Collections persist on
`${DOCKER_APPDATA_ROOT}/radicale` (ZFS-backed).

**Access model (personal calendars + one shared family calendar).** Radicale has no
scheduling/attendee delivery (it is a store, not groupware), so sharing is by *shared
collection*, not by inviting attendees — though `ATTENDEE` properties are still stored on
events, so a tool like Athena can read who's involved. The rights are:

- Each user owns their personal calendars/address books under `/<user>/`.
- A **shared family calendar** lives at `/family/` — adults read+write, kids read-only by
  default. The vast majority of household events go here; an adult creates it once. Because
  `/family/` is not a user principal, Radicale does not auto-create it, so make the parent
  collection first and then the calendar (a one-step `MKCALENDAR` on the nested path returns
  409): `MKCOL https://<RADICALE_FQDN>/family/` then
  `MKCALENDAR https://<RADICALE_FQDN>/family/<name>/`. Every device then subscribes to that
  calendar URL (CalDAV auto-discovery only surfaces a user's *own* collections, so the shared
  one is added by URL once per device).
- Adults can read every member's personal calendars; kids cannot see others' personal
  calendars by default.

These rules map usernames to collections, so — like the htpasswd file — they live in a rights
file kept **off the repo** on the NAS. The repo ships a name-free template:

- The **htpasswd file is a secret** and is **not** committed. Create it on the NAS at
  `<config_dir>/radicale/users` (mounted read-only at `/config/users`), one `user:bcrypt-hash`
  per line. Generate entries with `htpasswd -B` (bcrypt) — `htpasswd -B -c .../users alice` for
  the first user, then `htpasswd -B .../users bob` to append.
- The **rights file** also contains usernames, so it is **not** committed either. Copy
  `services/radicale/rights.example` to `<config_dir>/radicale/rights` (mounted read-only at
  `/config/rights`), replacing the placeholder adult usernames. The example documents the
  Radicale permission letters and the one-line tweaks for "kids can edit the family calendar"
  or "hide personal calendars from everyone."
- Both files **must exist before the first deploy** — Docker would otherwise create the missing
  bind-mount source as a directory and break Radicale.
- Radicale runs as a non-root user inside the container, so both files must be readable by
  "other". `services/radicale/pre-up.sh` (run automatically on each deploy) enforces this
  (`chmod o+r`) and aborts the deploy if either file is missing, so no manual `chmod` is needed.
- The Caddy block adds the **CalDAV/CardDAV `.well-known` redirects** (`/.well-known/caldav`
  and `/.well-known/carddav` → `/`) so clients can auto-discover the DAV root from the bare
  domain (e.g. adding a CalDAV account on iOS with just the server hostname).

### Forgejo (git hosting + Actions runner)

`services/forgejo/` runs the Forgejo git host and a co-located **Actions CI runner** (the
`forgejo-runner` container) in one compose project, so Forgejo repos can run Actions workflows and
publish container images to Forgejo's built-in OCI registry. The runner has no purpose without the
git host, so the two ship and deploy together (like SearXNG within the `ai` stack). Being in the
same project, the runner reaches Forgejo over the internal network at `http://forgejo:3000` (no
public-FQDN NAT hairpin, no TLS); it uses the host Docker socket to spawn each job's container (the
same socket precedent as `services/webhook`).

Both the git host and the runner use the **genuine official** Forgejo images, pulled from our own
ghcr mirror (`ghcr.io/dfederm/homelab/forgejo` and `…/forgejo-runner`). The upstream Forgejo
registries (`codeberg.org`, `code.forgejo.org`) are unreachable from this network — the
Comcast/Hetzner routing issue — and the runner has no third-party mirror anywhere, so rather than
trust a third-party Docker Hub mirror we mirror the official images to ghcr ourselves via
[`.github/workflows/mirror-images.yml`](.github/workflows/mirror-images.yml) (GitHub-hosted runners
reach the upstreams; the homelab reaches ghcr). The official runner image is a bare binary with no
auto-registration wrapper, so the compose `command` registers once on first start and then runs the
daemon.

Runner labels (which `runs-on:` values it serves) are defined in the committed, read-only
`services/forgejo/runner-config.yaml` rather than via an env var, so they are authoritative on
every restart. The default label is `docker`, backed by the Docker backend. The registration
state persists at `${DOCKER_APPDATA_ROOT}/forgejo-runner/.runner`, so the runner survives
container recreation without re-registering.

**Operator setup (one-time) is documented in
[`services/forgejo/README.md`](services/forgejo/README.md)** — generating the registration token,
creating the package access tokens, the secrets to add, and enabling Actions on a repo. After
editing `runner-config.yaml`, restart just the runner so it is re-read (this avoids bouncing the
git host):
```bash
docker restart forgejo-runner
```

### Multi-instance services

A service can be deployed as several independent instances from a single compose file.
When `<SERVICE>_INSTANCES` is set (space-separated) in the env file, `run-service.sh`
deploys the service's compose once per instance as its own Compose project
(`<service>-<instance>`), layering a per-instance env file
(`<config_dir>/<service>/<instance>.env`) on top of `common.env` + the machine env. The
instance name is exposed to the compose as `<SERVICE>_INSTANCE`. Adding an instance needs
only a new per-instance env file plus its name in the list — no repo change.

### Minecraft (multiple Bedrock worlds)

`services/minecraft/` is a multi-instance service: each world in `MINECRAFT_INSTANCES`
runs as its own Bedrock server (`minecraft-<world>`) with its own UDP port and ZFS-backed
`/data` (`${DOCKER_APPDATA_ROOT}/minecraft/<world>`). Per-world settings (port, game mode,
difficulty, …) live in `<config_dir>/minecraft/<world>.env` (copy
`services/minecraft/world.env.example`); gamerules such as
`keepInventory` go in `<config_dir>/minecraft/<world>.init` (one command per line) and are
applied automatically after start (see `services/minecraft/post-up.sh`).

Game consoles can't enter an arbitrary server IP, so `services/bedrock-connect/` runs
[BedrockConnect](https://github.com/Pugmatt/BedrockConnect): point an AdGuard DNS rewrite of
an unused "featured server" hostname at the Docker host, and consoles get an in-game menu of
the worlds. The menu is defined by `custom_servers.json` in the NAS directory
`BEDROCK_CONNECT_CONFIG` (see `services/bedrock-connect/custom_servers.example.json`).
Adding a world is therefore NAS-only: create its `<world>.env`, add it to `MINECRAFT_INSTANCES`,
and add an entry to the BedrockConnect menu file.

### Backup (cloud sync)

`services/backup/` is a multi-instance service: each target in `BACKUP_INSTANCES` runs as its
own `rclone` container (`backup-<target>`) that syncs one read-only source directory under
`BACKUP_DATA_ROOT` to a cloud destination. Per-target settings — the source subdirectory
(`BACKUP_SOURCE_DIR`), the rclone destination (`BACKUP_DEST`), and an optional cron schedule
(`BACKUP_CRON`) — live in `<config_dir>/backup/<target>.env` (copy
`services/backup/backup.env.example`). Each container runs the sync once on start and then on
its cron schedule (default 03:00 daily; stagger `BACKUP_CRON` per target to avoid contention);
a failed sync exits non-zero and is visible in the container logs.

The rclone remotes are defined once in the shared config at `${DOCKER_APPDATA_ROOT}/backup/rclone`,
mounted read-write so OAuth token refreshes (e.g. OneDrive) persist. Each target reads only its
own remote. Because the config is shared and rclone rewrites it on a token refresh, stagger
`BACKUP_CRON` so targets don't refresh at the same instant; the on-start syncs aren't staggered,
but at deploy time tokens are normally still valid, so a refresh race there is unlikely.

`rclone.conf` is both service-written (rclone rotates OAuth tokens back into it) and admin-edited
(to add a remote / family member), so neither "owned by the service" nor "read-only admin config"
fits. Listing the rclone config dir in `SMB_ADMIN_CONFIG_DIRS` (on the NAS) reconciles this:
`install-samba` keeps it owned `root:admin` with a default ACL granting the `admin` group write and
its files group-writable but not world-readable (so the tokens stay private). rclone preserves an
existing config file's owner+mode when it rewrites it, so that admin grant survives token
rotations — admins can edit `rclone.conf` over SMB without getting locked out.

Adding a target is therefore NAS-only: create its `<target>.env` and add its name to
`BACKUP_INSTANCES` — no repo change. Its remote must exist in the shared `rclone.conf`; minting a
OneDrive remote's token is a one-time interactive step (`rclone config` / `rclone config reconnect
<remote>:` inside the container). On a brand-new config the container first creates `rclone.conf`
as `root:root`; the next `setup.sh` (i.e. `install-samba`) run normalizes it to admin-editable.
Shared folders with no single owner (e.g. `family`, `adults`)
back up into an existing personal remote under a **separate** top-level path so they don't collide
with that person's own backup — e.g. a `family` target → `onedrivedavid:/nas-backup-shared/family`
while david's own backup stays at `onedrivedavid:/nas-backup`. This is enforced, not just advisory:
`run-service.sh` runs `services/backup/pre-up.sh` before deploying and **aborts** if any two
targets' destinations overlap on the same remote (an equal or ancestor path would let one target's
pruning sync delete another's backup).

## Env Files

Machine-specific configuration lives in `.env` files **outside the repo** (not committed — they contain secrets). The `.env.template` in the repo documents all available variables.

A shared `common.env` is sourced first, then the machine-specific file. This keeps values that must be identical across machines (timezone, network basics, users/groups) in one place. Machine-specific values override common ones.

Convention:
```
<mount>/homelab/
  ├── config/
  │   ├── common.env        # Shared vars (TZ, network, users/groups)
  │   ├── authorized_keys   # SSH public keys (shared by all machines)
  │   ├── proxmox.env       # Proxmox host
  │   ├── docker.env        # Docker LXC
  │   ├── nas.env           # NAS LXC
  │   └── pi.env            # Raspberry Pi (e.g. kiosk)
  └── repo/                # This git repo
```

Scripts find the env file via `/etc/homelab.env` (a symlink created on first setup) or by convention from the repo's location and the machine's hostname.

Values with spaces must be quoted:
```
HOMELAB_SETUP_MODULES="create-users install-tools install-docker"
```

## Image Management

Docker images are pinned to specific versions with SHA256 digests for reproducibility. [Renovate Bot](https://docs.renovatebot.com/) automatically opens PRs when new versions are available, so updates are reviewed before deployment.

### Reclaiming superseded images

Each digest bump pulls a new image and leaves the old one on disk, so without a sweep the Docker host's rootfs only ever grows. The **`configure-docker-image-prune`** module (Docker LXC) schedules `scripts/docker-image-prune.sh` on `DOCKER_IMAGE_PRUNE_SCHEDULE`; it logs the unreferenced images by name, then removes them with `docker image prune -a`. A container protects its image whether it is running or stopped, so one-shot containers that exit after a deploy keep theirs, and anything removed is re-pullable from the digest pinned in git.

`-a` is required, not a precaution: because images are pinned by digest, Docker holds them by repo digest rather than by tag, so `docker images` shows their tag as `<none>` without them being dangling. A plain `docker image prune` skips every one of them and can report gigabytes reclaimable while freeing nothing. (The per-deploy `docker image prune -f` in `run-service.sh` is a narrower job — it clears the dangling leftovers of the locally-built `webhook` image.)

**Schedule it earlier in the week than `LXC_FSTRIM_SCHEDULE`.** The prune frees files inside the LXC; only the host's `pct fstrim` returns those blocks to the LVM thin pool. The two timers run on different machines, so nothing enforces the order but the calendar — the defaults in `.env.template` prune on Sunday and trim on Monday.

Volumes are never pruned and stopped containers are never reaped. Removing an image is reversible; removing a volume holding service state is not. Review leftover containers by hand with `docker ps -a --filter status=exited`.

Build cache is not pruned either. It is a few dozen megabytes — noise next to the images this reclaims — and clearing it would make the locally-built `webhook` service rebuild from scratch on its next deploy, producing new layer digests that Compose treats as a changed image and recreates the container for.

A deploy landing in the same moment is an accepted race: between `docker compose pull` and `docker compose up` a freshly pulled image is referenced by no container yet, so a sweep in that window can remove it. Compose pulls a missing image again, so that gap heals itself; the narrower window *inside* a single `up` does not — images are resolved up front, so a service still waiting on a `depends_on` health gate fails to create rather than re-pulling. The next deploy puts it right, since the digest is pinned in git.

To see what a run would remove without removing anything: `bash scripts/docker-image-prune.sh --dry-run`.

### Self-mirrored images (ghcr)

A few upstream registries are unreachable from this network due to upstream routing problems (notably Forgejo's `codeberg.org` and `code.forgejo.org`, which time out from this ISP). Rather than depend on an unverified third-party Docker Hub mirror, the [`mirror-images`](.github/workflows/mirror-images.yml) GitHub Actions workflow copies the genuinely-official images to `ghcr.io/dfederm/homelab/*` (GitHub-hosted runners can reach the upstream registries; the homelab can reach ghcr). The compose files then pull from ghcr.

The workflow runs weekly and on demand (`workflow_dispatch`). For each image in its matrix it picks the newest stable upstream release, copies the full multi-arch manifest with `skopeo copy --all` (preserving the official digest), and prints the pinnable `@sha256` ref in its run summary. Versions are not pinned in the workflow — it always mirrors the newest stable release, and Renovate pins the exact version+digest in the compose files (so a version bump never needs a workflow edit first). To mirror another image, add a row to the workflow's matrix.

One-time admin per mirrored package: none — packages pushed from this public repo inherit its visibility, so they are public and the homelab pulls them without authentication. Renovate tracks the ghcr ref like any other image and opens version/digest bump PRs.

> **Merge ordering matters.** When first repointing a compose image at a self-mirrored ghcr ref, run the workflow *before* merging the compose change, and pin a tag the run actually published (shown in its summary; the workflow mirrors the newest stable upstream release, which may differ from the tag currently in compose). Deploys pull the image (`docker compose pull`) — merging a tag that was never mirrored would point a live service at an image that does not exist yet and fail its next deploy. After bootstrap, Renovate keeps the compose tag and the published ghcr tags in sync.

## CI/CD

Pushes to `main` are automatically deployed via a [webhook receiver](https://github.com/adnanh/webhook) running in the Docker LXC. The webhook is only an update signal; each top-level deploy target owns its checkout and coordinator state.

### How It Works

1. GitHub sends a push event to the webhook endpoint
2. The webhook validates the HMAC-SHA256 signature and branch
3. `dispatch.sh` connects to each configured top-level target, atomically records one pending pass, and wakes its worker
4. Each worker takes the target setup lock before cloning or fetching its reusable local checkout, resets it to the latest `origin/main`, and runs setup synchronously
5. Signals received while setup is active collapse into one pending pass. After the run succeeds, the worker performs that one trailing pass and fetches the latest `origin/main` again
6. On success, the worker records the commit it actually ran. A boot and periodic timer fetches `origin/main` and retries whenever it differs from that last successful commit

This is deliberately one running pass plus one pending bit, not a deployment queue. Ten pushes before a worker starts become one deployment of the latest commit. Ten pushes during a run become one trailing deployment, which fetches whatever is latest when it begins. A signal intentionally runs setup even when the Git commit is unchanged, because configuration outside the repository may have changed.

Webhook deployment never mutates shared source. Dispatch scripts and hook configuration are baked into the webhook image, and each top-level target updates only its own persistent-but-disposable checkout while holding its setup lock. On a Proxmox target, `create-lxcs` copies that locked source into a stable local path inside each LXC while holding the LXC's setup lock, then runs setup from that copy. `setup.sh` and direct service tools use the same local blocking lock, so neither target nor LXC source can change beneath an active setup or service command.

Deploy targets are defined per the prefix-based pattern (`HOMELAB_DEPLOY_TARGETS`). Each target needs a `_DEPLOY_HOST` for the low-latency wakeup and must include `configure-deploy-worker` in its `HOMELAB_SETUP_MODULES`. Enable the worker only on top-level targets such as the Proxmox host and independent remote machines; do not enable it on Docker/NAS LXCs already owned by the Proxmox cascade.

On a remote machine whose config comes from SMB, order `configure-smb-mount` before `configure-deploy-worker`. The worker's Git checkout is local; only external configuration and secrets remain authoritative on the shared storage.

Target-local deployment data uses these paths by default:

- `${HOMELAB_REPO_DIR}` (`/opt/homelab/repo`) — reusable Git checkout, or stable copied source inside an LXC
- `${DEPLOY_STATE_DIR}` (`/var/lib/homelab-deploy`) — pending bit, last successful commit, and run/coalescing events
- `${DEPLOY_LOG_DIR}` (`/var/log/homelab-deploy`) — preserved per-run setup output

For each LXC's first local-copy setup, `create-lxcs` maps the host's resolved
`CONFIG_DIR` through that LXC's `_MP0`, `_MP1`, ... entries to derive the
corresponding config path inside the guest. Different LXCs may therefore mount
the shared homelab root at different guest paths without another setting.

`DEPLOY_RETENTION_DAYS` removes old per-run logs. The event log rotates by `DEPLOY_EVENT_LOG_MAX_BYTES` and retains one previous segment.

### Coordinator Rollout

Roll out the coordinator without letting the old fire-and-forget webhook start overlapping setup runs:

1. Disable the GitHub webhook
2. Put `DEPLOY_REPOSITORY_URL` and any non-default local path, retention, or reconciliation settings in external env files; add `configure-deploy-worker` to every top-level target after any module that mounts its config
3. Push only with explicit deployment authorization
4. Fetch and reset the retained shared checkout to the pushed `origin/main`, then use it to run setup on each top-level target sequentially so workers, local checkouts, timers, and LXC copies are bootstrapped without overlap
5. Verify `homelab-deploy-worker.path`, `homelab-deploy-worker.timer`, `${HOMELAB_REPO_DIR}`, LXC local copies, and `${DEPLOY_STATE_DIR}/last-success`
6. Re-enable and redeliver the webhook, then verify one serialized run per top-level target
7. Retain the old shared checkout for rollback; remove it only as a separate explicitly approved cleanup

For manual deployments (e.g. after changing env files), run `${HOMELAB_REPO_DIR}/scripts/deploy.sh` on a top-level machine. It holds the same local setup lock across its pull and setup phases and records the successful commit. Inside an LXC, run setup and service commands from `${HOMELAB_REPO_DIR}`, not the shared checkout. `run-service.sh <name>` / `run-all-services.sh` use the same lock; `recreate-service.sh <name>` delegates to the locked single-service path.

### GitHub Webhook Configuration

In the repo's Settings → Webhooks:
- **URL:** `https://<webhook-fqdn>/deploy`
- **Content type:** `application/json`
- **Secret:** same value as `WEBHOOK_SECRET` in the env file
- **Events:** "Just the push event"
