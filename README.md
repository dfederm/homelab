# Homelab

Declarative configuration for a homelab running [Proxmox VE](https://www.proxmox.com/en/proxmox-virtual-environment/overview). All services, infrastructure, and machine setup are defined in this repo and applied via idempotent scripts.

## Architecture

The primary server runs Proxmox with LXC containers and VMs. Additional machines (e.g. a Raspberry Pi) can use the same setup system with their own env files.

- **Proxmox host** — ZFS pool, GPU driver, creates and manages LXCs/VMs
- **Docker LXC** — Runs all containerized services (Jellyfin, Immich, AdGuard, etc.)
- **NAS LXC** — Samba file sharing with per-user permissions
- **Home Assistant VM** — Smart home automation (restored from HAOS image)

All data lives on a ZFS pool and is bind-mounted into containers. The LXC root filesystems are ephemeral — destroy and recreate from this repo at any time.

## Setup System

The setup system is designed so that a single command on the Proxmox host bootstraps or updates the entire stack — host config, LXC creation, software installation inside each container, and service deployment.

### How It Works

Each machine has a `.env` file (stored outside the repo at `<mount>/homelab/config/<hostname>.env`) that defines:
- Which **setup modules** to run (`HOMELAB_SETUP_MODULES`)
- Which **services** to deploy (`HOMELAB_SERVICES`)
- All machine-specific configuration (IPs, resources, mount points, etc.)

A shared `common.env` in the same directory holds values that must be identical across machines (timezone, network basics, users/groups). It is sourced automatically before the machine-specific file, so machine values can override common ones.

Every Linux `setup.sh` run validates the shared `TZ` value and reconciles the
machine's system timezone before running optional modules or services. This
applies to top-level hosts and remote machines as well as LXCs reached through
the Proxmox cascade.

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
| `configure-kernel-cmdline` | Reconcile boot parameters; report pending reboot without performing one | Proxmox host |
| `configure-pi-kiosk` | Set up Cage + Chromium kiosk browser pointing at a URL (Raspberry Pi specific) | Alarm panel Pi |
| `configure-scrutiny-collector` | Install Scrutiny SMART collector (pinned binary) + timer; pushes drive health to the Scrutiny web UI | Proxmox host |
| `configure-macvlan-bridge` | Persist macvlan bridge so host can reach macvlan containers | Docker LXC |
| `configure-network` | Pin a machine to a static IPv4 address (`STATIC_IP`) via NetworkManager | Remote machines |
| [`configure-nvidia-driver`](scripts/setup/modules/configure-nvidia-driver.md) | Install the headless NVIDIA driver, device nodes, and optional power cap; see the linked runbook for safe tuning | Proxmox host |
| `configure-proxmox-repos` | Switch from paid enterprise repos to free community repos | Proxmox host |
| `configure-sensors` | Install sensors and load board-specific hwmon modules | Bare-metal hosts |
| `configure-smb-mount` | Mount NAS share via CIFS, persist in fstab | Remote machines |
| `configure-lxc-fstrim` | Return freed LXC rootfs blocks to the LVM thin pool | Proxmox host |
| `configure-docker-image-prune` | Prune images unused by any container | Docker LXC |
| `configure-ssh` | Harden SSH (key-only auth) and deploy authorized keys | All machines |
| `configure-storage-alerts` | Periodic threshold alerts for LVM thin-pool + ZFS pool capacity (the storage Beszel can't see) | Proxmox host |
| `configure-storage-health` | Schedule monthly ZFS scrubs + daily pool health check + SMART self-tests (smartd), with degradation alerting | Proxmox host |
| `configure-ups-monitoring` | Monitor UPS health and expose NUT telemetry | Proxmox host |
| `create-lxcs` | Create/update LXC containers from env var definitions (integrated-GPU passthrough via `_GPU=1`, NVIDIA passthrough via `_NVIDIA_GPU=1`, USB via `_USB_DEVICES`) | Proxmox host |
| `create-vms` | Create/update VMs (e.g. Home Assistant) | Proxmox host |
| `create-users` | Create Linux users/groups with aligned UIDs across machines | Docker LXC, NAS LXC |
| `install-beszel-agent` | Install the Beszel monitoring agent natively (binary + systemd) on hosts without Docker | Proxmox host, NAS LXC |
| `install-docker` | Install Docker Engine from official apt repo | Docker LXC |
| `install-nvidia-container-toolkit` | Install the userspace NVIDIA driver (matching the host's `NVIDIA_DRIVER_VERSION`) plus the NVIDIA Container Toolkit, so Docker containers can use GPUs passed into the LXC | Docker LXC |
| `install-samba` | Install Samba, generate smb.conf from env vars | NAS LXC |
| `install-tools` | Install common utilities (git, jq, htop, curl) | All machines |
| `provision-host-volumes` | Provision host LVM-thin volumes for LXC bind mounts | Proxmox host |
| `set-share-permissions` | Apply POSIX ACLs on file share directories | NAS LXC |

### Cascade

After creating each LXC, `create-lxcs` runs `setup.sh` inside it via `pct exec`:

```
setup.sh on Proxmox host
  → host modules (including GPU drivers before guest creation)
  → create-lxcs
    → Docker LXC: setup modules → HOMELAB_SERVICES
    → NAS LXC: setup modules (including Samba)
  → create-vms (Home Assistant)
```

Module order matters. `configure-nvidia-driver` must come before `create-lxcs`, for the
same reason `configure-amdgpu` does: a passthrough step can only pass device nodes that
already exist. Inside the LXC, `install-nvidia-container-toolkit` and
`configure-docker-image-prune` must both come after `install-docker`.

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

Unlike LXCs, VMs do **not** cascade — they manage their own OS internally. The `_IP` variable is informational (for documentation and other configs) and is not passed to `qm`. Appliance guests such as Home Assistant OS also own their system timezone internally; their application configuration must declare the same timezone rather than relying on `create-vms`.

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

The Proxmox host owns the disks. `configure-storage-health` schedules monthly ZFS
scrubs, daily pool checks, and daily short/monthly long SMART self-tests; smartd
also monitors drive health. `configure-scrutiny-collector` reads SMART data on the
host and sends it to the LAN-only `services/scrutiny/` dashboard on the Docker
host; smartd alone schedules the tests. The collector's verified binary version
follows the Scrutiny image tag.

Clear any of `ZFS_SCRUB_SCHEDULE`, `ZFS_HEALTH_CHECK_SCHEDULE`,
`SMART_SELFTEST_SCHEDULE`, or `SCRUTINY_COLLECTOR_SCHEDULE` to disable that
schedule (smartd still monitors drives without scheduled tests).
`HOMELAB_ALERT_SHOUTRRR_URL` is the shared alert channel; host checks also log
to the journal.

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

Authelia provides OIDC for apps with native clients (including Open WebUI) and
Caddy forward-auth for browser-only UIs. Jellyfin, Home Assistant, and Radicale
retain their own authentication because their native clients cannot use
forward-auth. Secrets and user records live outside the repo; persistent 2FA
state is ZFS-backed, but sessions are in memory and require re-login after a
restart. See [`services/authelia/README.md`](services/authelia/README.md) for
first-run setup and integration recipes.

### AI (llama-swap + LiteLLM + Open WebUI)

`services/ai/` runs the family AI stack as one Compose project on the shared internal `ai` network:
[llama-swap](https://github.com/mostlygeek/llama-swap) owns model-specific `llama-server`
processes, [LiteLLM](https://www.litellm.ai/) provides authenticated workload aliases and usage
accounting, and [Open WebUI](https://openwebui.com) is the multi-user chat frontend.

llama-swap is the only model lifecycle owner. Its operator-owned configuration lives outside this
public repository at `${CONFIG_DIR}/llama-swap/config.yml`, on the NAS-backed config dataset. Model
IDs, commands, context and sampling settings, GPU placement, and the routing matrix all belong in
that external file rather than in this public repository. `LLAMA_SWAP_NVIDIA_VISIBLE_DEVICES`
controls which devices Docker exposes to the lifecycle owner; Compose does not assign workloads to
specific devices. llama-swap has no authentication and publishes no host port; only LiteLLM can
reach it over the internal network. A missing NVIDIA runtime or container GPU setting fails
deployment rather than silently serving on the CPU.

Model files live under `LLAMA_MODELS_ROOT`, normally a fast volume bind-mounted into the Docker LXC.
The operator-owned `${CONFIG_DIR}/ai/models.txt` manifest pins each public artifact by immutable
repository revision and SHA-256. Each non-comment line uses
`relative-path|sha256|size-in-bytes|https-url`. Before every AI deployment,
`download-models.sh` verifies existing files and downloads only missing or corrupt artifacts.
Downloads resume from a `.partial` file and are atomically renamed only after the checksum passes.

LiteLLM is the durable routing boundary between clients and llama-swap. Its model aliases and backend
mappings are deliberately **not** committed to this repository. They live in the ZFS-backed
`${CONFIG_DIR}/litellm/config.yaml`, mounted read-only into the gateway. This keeps workload names
stable while internal model IDs remain replaceable. Repository scripts do not rewrite the
operator-owned YAML. Keep prompt logging disabled, retain the database-backed general settings, and
do not configure external callbacks or fallback providers.

LiteLLM publishes `${LITELLM_HTTP_PORT}:4000` for authenticated LAN clients and has no Caddy route.
Its PostgreSQL state persists under `${DOCKER_APPDATA_ROOT}/litellm/db`. The `ai` post-up hook
declaratively reconciles every prefix in `LITELLM_CLIENTS`. Each prefix supplies its reporting alias,
fixed virtual key, and space-separated model allowlist through
`LITELLM_<PREFIX>_{KEY_ALIAS,API_KEY,MODELS}` in the external env file. `OPEN_WEBUI` is required;
other clients are configuration-driven. The master key is administrative and must never be given to
a client. Generate the master key, immutable salt, and each client key independently as `sk-`
followed by random data. Give each external client its own prefix and narrow model allowlist so usage
remains attributable by client.

Open WebUI **does** have its own multi-user auth (the first account created becomes the
admin), so it is exposed via Caddy at `OPEN_WEBUI_FQDN`. It is also reachable
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
- **All model traffic runs through LiteLLM over Open WebUI's OpenAI-compatible clients.** Keep the
  chat and RAG base URLs fixed at `http://litellm:4000/v1`, disable the native Ollama API, and select
  only profiles allowed by `LITELLM_OPEN_WEBUI_MODELS`. Context limits belong in each external
  llama-server profile rather than in Open WebUI.
- On a **fresh** Open WebUI database, Compose seeds the LiteLLM URL, its dedicated key, and the
  `x-litellm-end-user-id: {{USER_ID}}` connection header. That connection also blanks
  `X-OpenWebUI-User-Jwt` and all `X-OpenWebUI-User-{Name,Id,Email,Role}` headers so the global Athena
  identity forwarding setting does not copy names or email addresses into LiteLLM. On an
  **existing** instance these are PersistentConfig: add all those custom headers in Admin Settings
  → Connections with the same URL and key. Open WebUI substitutes the authenticated user's opaque,
  stable internal ID server-side; do not substitute a name or email.
- `OPEN_WEBUI_TASK_MODEL_EXTERNAL` selects the LiteLLM alias for title/tag/query generation.
  `TASK_MODEL` is intentionally empty because the native model API is disabled. The external task
  model must be readable by non-admin users under Admin Settings → Models.
- `OPEN_WEBUI_RAG_EMBEDDING_MODEL` selects the embedding alias through LiteLLM. Set Documents →
  Embedding Engine to `OpenAI`, the URL to
  `http://litellm:4000/v1`, and the key to `LITELLM_OPEN_WEBUI_API_KEY` on an existing instance.
- Keep Open WebUI's reasoning setting consistent with the selected external model profile.

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

Deploy the stack as follows:

1. Create `${CONFIG_DIR}/llama-swap/config.yml` with the model commands, hardware assignment, and
   routing matrix.
2. Set `LLAMA_MODELS_ROOT` and `LLAMA_SWAP_NVIDIA_VISIBLE_DEVICES` in the Docker LXC's external env
   file.
3. Configure the external LiteLLM aliases and OpenAI-compatible llama-swap mappings. Add each
   client prefix and allowlist without changing `LITELLM_SALT_KEY`.
4. Deploy `ai`. The pre-up hook validates the external llama-swap config and verifies/downloads the
   model files; after LiteLLM is healthy, the
   post-up hook creates or updates the configured client keys.
5. On an existing Open WebUI instance, update the persisted Connections, Interface, and Documents
   settings described above; Compose env values only seed a fresh database.
6. Verify model listing, streaming, configured reasoning behavior, task generation, embeddings,
   tool calls, signed user identity, and distinct opaque user IDs in LiteLLM usage.

Rollback is intentionally simple for this manually recoverable household service: restore the prior
repository revision and external settings, redeploy, and re-download old model data if it has
already been removed. Do not delete or recreate LiteLLM's database, and never rotate its salt as
part of rollback.

Open WebUI's native **web search** is disabled; Athena MCP exposes bounded `web_search` and protected
`fetch_url` tools instead. SearXNG remains the private backend for Athena's search tool.

### Web search (SearXNG)

SearXNG backs Athena MCP's web search inside `services/ai/`. It has **no
authentication or public port**; only clients on the `ai` network can reach
`http://searxng:8080`. Its read-only `settings.yml` enables JSON responses,
and `SEARXNG_SECRET` stays in the external env file. Open WebUI's native search
is disabled; on existing installs, also disable it in Admin Settings → Web
Search because that setting persists in the database.

### Athena MCP (family tools)

Athena MCP runs in `services/ai/`, exposing household tools to Open WebUI over
the internal Docker network at `http://athena-mcp:8080`. It has no standalone
authentication or public port. Its web tools use private SearXNG: `web_search`
returns at most five results and `fetch_url` fetches bounded public text while
blocking private-network destinations and unsafe redirects.

Forgejo CI publishes the private image. Renovate cannot inspect that registry;
update its tag **and digest** in `services/ai/docker-compose.yml` from the CI
publish summary and registry manifest. Service endpoints and Home Assistant's
proof lifetime/denylist use external `ATHENA_MCP_*` env vars; Koffan is reached
via its published host port because it uses a separate Docker network.

The canonical roster and per-user credentials are the exception. They live in the external
`${CONFIG_DIR}/athena/users.json`, mounted read-only at `/run/secrets/athena-users.json`. The file is
the complete authoritative snapshot for the roster and the Vikunja, Radicale, Jellyfin, Immich, and
Home Assistant credential dictionaries:

```json
{
  "Users": {
    "user_id": { "Email": "user@example.invalid" }
  },
  "Apps": {
    "Vikunja": {
      "Credentials": {
        "user_id": { "ApiToken": "replace-with-api-token" }
      }
    },
    "Radicale": {
      "Credentials": {
        "user_id": {
          "Username": "replace-with-username",
          "Password": "replace-with-password"
        }
      }
    },
    "Jellyfin": {
      "Credentials": {
        "user_id": { "AccessToken": "replace-with-access-token" }
      }
    },
    "Immich": {
      "Credentials": {
        "user_id": { "ApiKey": "replace-with-api-key" }
      }
    },
    "HomeAssistant": {
      "Credentials": {
        "user_id": { "AccessToken": "replace-with-access-token" }
      }
    }
  }
}
```

Use stable lowercase IDs matching `[a-z][a-z0-9_]*`; emails and IDs must be unique
case-insensitively. Omit a provider credential for users who do not use that provider. Never put
endpoints, shared identity secrets, list settings, or unrelated application configuration in this
file: the application ignores those keys here.

Keep curated knowledge outside this repo under `${CONFIG_DIR}/athena/knowledge`,
mounted read-only at `/knowledge`, with this fixed layout:

```text
knowledge/
├── registry/
│   └── household.yaml
└── curated/
    └── shared/
        └── <topic>.md
```

Athena loads only the registry and top-level `curated/shared/*.md`, validating
the corpus on knowledge-tool calls. Never commit or log its private contents.

**One-time operator setup** (needs admin on Forgejo/Beszel/Proxmox/Home Assistant + write access to
the NAS config):

1. **Configure registry access:** set `CONTAINER_REGISTRY`, `CONTAINER_REGISTRY_USER`,
   and `CONTAINER_REGISTRY_TOKEN` (a `package:read` PAT). The `ai` pre-up hook
   logs in before pulling the image. **List `dns`, `reverse-proxy`, and `forgejo`
   before `ai` in `HOMELAB_SERVICES`** so cold rebuilds can reach the registry.
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
4. **Create the user snapshot** at `${CONFIG_DIR}/athena/users.json` using the
   schema above. Map each user's provider credentials to their stable ID without
   printing secrets. Write a temp file in the same directory, set mode `0644`,
   then rename it atomically; Athena validates the entire file at startup.

   Keep HA's conversation-Assist exposure limited to entities Athena may read. Transfer the current
   hazard inventory, without changing membership, to
   `ATHENA_MCP_HOMEASSISTANT_DENIED_ENTITY_IDS` as one JSON array of exact entity IDs. In the NAS env,
   use a shell-safe value such as `'["light.example","switch.example"]'`; use `[]` only when the
   inventory is intentionally empty.
5. **Create the curated knowledge corpus** using the layout above and Athena
   MCP's `docs/knowledge-tools.md` schema. Keep files on the NAS, readable by
   the container but never in repo or logs.
6. **Register the server in Open WebUI** (PersistentConfig/UI state) at
   `http://athena-mcp:8080`, grant it to the intended users/groups, and attach it to the Athena
   model. Keep that model's `builtin_tools` capability disabled. The server spotlights every tool
   result inside an escaped `<external_data>` provenance boundary; set the model's system prompt to
   state that content inside that boundary is untrusted data, never instructions, and must not be
   echoed. Deploying the container only makes new tools reachable through an existing unfiltered
   connection; it does not create the connection, grants, model attachment, or prompt.

Before replacing Athena MCP, back up its external configuration, record the
current image pin, and drain active model responses so the in-memory Home
Assistant action ledger is not reset mid-turn.

After deployment, confirm `docker ps` shows `athena-mcp` `(healthy)` and
`docker exec open-webui curl -s http://athena-mcp:8080/health` returns `Healthy`.

Verify the intended image, read-only knowledge mount, and a non-admin user's
knowledge, search/fetch, and provider read-only tools without logging family
data. Keep Open WebUI's native search disabled under Admin Settings → Web Search
on an existing installation (PersistentConfig).

For credential-file updates, drain responses, atomically replace `users.json`
with mode `0644`, and run `./scripts/recreate-service.sh ai`. A restart can
retain the old bind-mounted inode; Compose may not recreate an unchanged service.

If identity, provider access, or Home Assistant safety fails, restore the
previous image and external configuration before redeploying.

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
5. `ATHENA_MCP_HOMEASSISTANT_DENIED_ENTITY_IDS` blocks known hazardous exact entities and groups
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

`services/koffan/` runs a local-first shopping-list PWA. Its SQLite state
persists under `${DOCKER_APPDATA_ROOT}/koffan`; Caddy exposes it at
`KOFFAN_FQDN`. Set `KOFFAN_API_TOKEN` to enable the token-gated REST API.

**Auth.** Koffan has a simple single-password login (`KOFFAN_APP_PASSWORD`, a secret; a blank value
falls back to Koffan's public default, so set a strong one). Since it is publicly exposed, once
Authelia is in place move Koffan behind it: set `KOFFAN_DISABLE_AUTH=true` (defaults `false`, which
ignores `APP_PASSWORD`), bind the host port to localhost (or drop it) so the LAN can't bypass the
proxy, and add `forward_auth` to the Caddy block for the UI/`/ws` while **bypassing `/api/*`** (the
REST API uses its own `API_TOKEN` bearer and can't do interactive SSO).

### Radicale (CalDAV/CardDAV)

`services/radicale/` stores calendars and contacts on ZFS-backed appdata.
It uses its own bcrypt htpasswd authentication because CalDAV/CardDAV clients
cannot use Authelia forward-auth. Strong per-user credentials are required:
Caddy exposes `RADICALE_FQDN` publicly.

Users own personal collections under `/<user>/`; adults can read all personal
calendars. The shared `/family/` calendar is adult-write/kid-read by default.
Radicale does not auto-create `/family/`: issue `MKCOL` for `/family/`, then
`MKCALENDAR` for `/family/<name>/`; add that URL to each device manually
(auto-discovery finds only personal collections). Radicale stores events, not
scheduling invitations.

Create `<config_dir>/radicale/users` using `htpasswd -B` (`-c` only for the
first user). Copy `services/radicale/rights.example` to
`<config_dir>/radicale/rights` and replace placeholder names. Both files
contain private data, must stay off repo, and **must exist before deployment**
or Docker creates missing bind sources as directories. `pre-up.sh` checks
their existence and grants read access to the non-root container.

### Forgejo (git hosting + Actions runner)

`services/forgejo/` runs Forgejo and its Actions runner together. Both pull
official images from the [self-hosted ghcr mirror](#self-mirrored-images-ghcr)
because the upstream registry is unreachable from the homelab. The runner
uses the host Docker socket to start jobs; registration state persists under
`${DOCKER_APPDATA_ROOT}/forgejo-runner/`. Labels live in
`services/forgejo/runner-config.yaml`; restart **only the runner** after editing
that file. See [`services/forgejo/README.md`](services/forgejo/README.md) for
one-time registration, credentials, and CI setup.

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
runs as its own Bedrock server (`minecraft-<world>`) with its own TCP signaling port,
UDP gameplay range, and ZFS-backed `/data` (`${DOCKER_APPDATA_ROOT}/minecraft/<world>`).
Per-world settings (ports, game mode, difficulty, …) live in
`<config_dir>/minecraft/<world>.env` (copy
`services/minecraft/world.env.example`); gamerules such as
`keepInventory` go in `<config_dir>/minecraft/<world>.init` (one command per line) and are
applied automatically after start (see `services/minecraft/post-up.sh`).

Bedrock Dedicated Server 1.26.50+ documents NetherNet as its default. Current
releases warn that the older transport is unsupported, though existing worlds
may still accept legacy UDP connections. The Compose service explicitly sets
`TRANSPORT=nethernet` rather than relying on that compatibility. Set
`MINECRAFT_PORT` to each world's unique TCP signaling port, and set
`MINECRAFT_UDP_PORT_RANGE` to a distinct UDP gameplay range with at least one
port per player (the default maximum is 10).
The Compose service publishes both and advertises the existing `DOCKER_HOST_IP` to
clients, so that address must be reachable from their LAN. Configure **every**
per-world env file with a non-overlapping range before redeploying. BedrockConnect's
menu remains on UDP 19132; its world entries retain the same address and
`MINECRAFT_PORT`. Confirm console transfers into each world after deployment.
These ports are for LAN play, not internet forwarding.

Game consoles can't enter an arbitrary server IP, so `services/bedrock-connect/` runs
[BedrockConnect](https://github.com/Pugmatt/BedrockConnect): point an AdGuard DNS rewrite of
an unused "featured server" hostname at the Docker host, and consoles get an in-game menu of
the worlds. The menu is defined by `custom_servers.json` in the NAS directory
`BEDROCK_CONNECT_CONFIG` (see `services/bedrock-connect/custom_servers.example.json`).
Adding a world is therefore NAS-only: create its `<world>.env`, add it to `MINECRAFT_INSTANCES`,
and add an entry to the BedrockConnect menu file.

### Backup (cloud sync)

Each `BACKUP_INSTANCES` target runs a separate rclone sync container with
read-only source and per-target `<config_dir>/backup/<target>.env` (see
`services/backup/backup.env.example`). Sync runs on start and on `BACKUP_CRON`
(default 03:00 daily); stagger targets sharing rclone config.

Set `BACKUP_SOURCE_PATH` to an existing absolute Docker-host directory. Deploy
through `run-service.sh`: its pre-up check rejects missing/relative sources;
calling Compose directly can create a missing source directory.

Remotes live in writable `${DOCKER_APPDATA_ROOT}/backup/rclone/rclone.conf`;
rclone refreshes OAuth tokens there. To edit it over SMB while preserving
service write access and private file modes, include its directory in
`SMB_ADMIN_CONFIG_DIRS` in the NAS env file.

**Before first deployment**, create the remote with `rclone config` inside a
one-off rclone container that mounts `${DOCKER_APPDATA_ROOT}/backup/rclone`
at `/config/rclone` (as in `services/backup/docker-compose.yml`). The startup
sync cannot succeed without the remote. For later token refreshes, run
`docker exec -it backup-<target> rclone config reconnect <remote>:` inside a
running target container. Running plain `rclone config` on the Docker host
would write a different config file. On a new config, a subsequent NAS
`setup.sh` run makes `rclone.conf` admin-editable. **Destinations on the same remote must be
disjoint:** sync prunes the destination, so an equal or ancestor path can
delete another target's data. `pre-up.sh` rejects overlaps before deployment.

## Env Files

Machine-specific configuration lives in `.env` files **outside the repo** (not committed — they contain secrets). The `.env.template` in the repo documents all available variables.

A shared `common.env` is sourced first, then the machine-specific file. This keeps values that must be identical across machines (timezone, network basics, users/groups) in one place. Machine-specific values override common ones. `TZ` is required: `setup.sh` uses it to reconcile every managed Linux machine's system timezone, and Docker services consume the same value.

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

## Tests

Tests are standalone Bash scripts under `tests/`. Run one directly:

```bash
bash tests/setup-timezone.test.sh
```

Or run the complete suite:

```bash
for test in tests/*.test.sh; do
    bash "$test" || exit
done
```

The PowerShell operator tools have a standalone mocked test entrypoint:

```powershell
pwsh -NoLogo -NoProfile -File tests\Test-DeploymentOperatorTools.ps1
```

The Compose test requires Python with PyYAML. When Docker Compose is installed it also runs
`docker compose config --no-interpolate` against every service definition; otherwise it reports that
semantic Compose validation was skipped and uses the PyYAML structural fallback.

## Image Management

Docker images are pinned to specific versions with SHA256 digests for reproducibility. [Renovate Bot](https://docs.renovatebot.com/) automatically opens PRs when new versions are available, so updates are reviewed before deployment.

### Reclaiming superseded images

`configure-docker-image-prune` schedules `scripts/docker-image-prune.sh` on
`DOCKER_IMAGE_PRUNE_SCHEDULE`. It removes images unused by any container (even
stopped ones), **never volumes, containers, or build cache**. `-a` is needed
because digest-pinned images show as `<none>` but are not dangling. Schedule the
prune before `LXC_FSTRIM_SCHEDULE` so the host returns freed LXC blocks to the
thin pool. Preview with `bash scripts/docker-image-prune.sh --dry-run`.

A prune racing a deploy may remove a newly pulled image before it is used. A
subsequent deploy re-pulls it; a service waiting inside `compose up` on a
health gate may instead fail until the next deploy.

### Self-mirrored images (ghcr)

The [`mirror-images`](.github/workflows/mirror-images.yml) workflow copies
official images from registries this network cannot reach to public
`ghcr.io/dfederm/homelab/*`. It runs weekly or on demand; add images to its
matrix and use the published tag and digest from the run summary. Renovate
updates Compose pins after mirroring.

**Run the mirror workflow before first repointing a Compose image** and pin a
tag it actually published; otherwise the next deployment cannot pull it.

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
- `${DEPLOY_LOG_DIR}` (`/var/log/homelab-deploy`) — preserved per-run setup output, with `latest.log` pointing to the active or most recent run

To follow the active or latest deployment and automatically switch when a newer
run starts:

```bash
tail -F /var/log/homelab-deploy/latest.log
```

Use the configured `DEPLOY_LOG_DIR` instead if it differs from the default.

For each LXC's first local-copy setup, `create-lxcs` maps the host's resolved
`CONFIG_DIR` through that LXC's `_MP0`, `_MP1`, ... entries to derive the
corresponding config path inside the guest. Different LXCs may therefore mount
the shared homelab root at different guest paths without another setting.

`DEPLOY_RETENTION_DAYS` removes old per-run logs. The run referenced by
`latest.log` is retained until a newer run replaces it, so the stable path
remains usable during long periods without deployments. The event log rotates
by `DEPLOY_EVENT_LOG_MAX_BYTES` and retains one previous segment.

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

### Operator Tools

Repository-owned PowerShell commands under `tools/` support deployment operations from an operator
workstation without embedding any Homelab-specific topology:

- `Get-ForgejoContainerPin.ps1` resolves a Forgejo container package to an immutable
  `version@sha256:digest` reference. Host, owner, package, and a local Git checkout whose `origin`
  uses the same Forgejo credential are explicit inputs. When version is omitted, the newest numeric
  semantic version is selected. Authentication failures are sanitized, and one stale Git Credential
  Manager refresh is attempted before the API request fails.
- `Wait-HomelabDeployment.ps1` waits for an exact full commit to appear in every target's
  `last-success`. Targets are supplied explicitly as name/address mappings. Worker and event state
  are reported as progress, and a `run-failure` event for the requested commit fails immediately,
  but only `last-success` proves deployment completion.

Example with placeholder values:

```powershell
$pin = & .\tools\Get-ForgejoContainerPin.ps1 `
    -ForgejoHost forgejo.example.com `
    -Owner example `
    -Package application `
    -CredentialRepo C:\path\to\forgejo-checkout

$targets = [ordered]@{
    primary = "192.0.2.10"
    remote = "host.example.com"
}

& .\tools\Wait-HomelabDeployment.ps1 `
    -Commit 0123456789abcdef0123456789abcdef01234567 `
    -Targets $targets
```

The watcher verifies the generic Homelab deployment coordinator only. Service-specific checks such
as container health or an expected image pin remain separate operator steps because they are not
proof that every top-level target completed the requested commit. For detailed live setup output,
use `ssh root@<target> tail -F /var/log/homelab-deploy/latest.log` (or the target's configured
`DEPLOY_LOG_DIR`) alongside the watcher. The stable log is diagnostic output; `last-success` and
commit-specific events remain the watcher's authoritative completion and failure signals.

### GitHub Webhook Configuration

In the repo's Settings → Webhooks:
- **URL:** `https://<webhook-fqdn>/deploy`
- **Content type:** `application/json`
- **Secret:** same value as `WEBHOOK_SECRET` in the env file
- **Events:** "Just the push event"
