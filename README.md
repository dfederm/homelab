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
│   ├── deploy.sh          # Deploy changes on this machine (setup + services)
│   ├── dispatch.sh        # Webhook handler: fans out deploy.sh to all machines
│   ├── lib.sh             # Shared helper functions (sourced by other scripts)
│   ├── recreate-service.sh # Force-recreate a service container
│   ├── run-all-services.sh
│   ├── run-service.sh     # Deploy a single Docker Compose service
│   ├── update.sh          # Update system packages on host and all LXCs
│   └── setup/
│       ├── setup.sh       # Main setup runner (see below)
│       └── modules/       # Idempotent setup modules
└── services/              # Docker Compose service definitions
    ├── dns/               # AdGuard Home
    ├── dozzle/            # Docker log viewer
    ├── files/             # Filestash + Collabora
    ├── homepage/          # Landing page dashboard
    ├── jellyfin/          # Media streaming
    ├── monitoring/        # Beszel + Uptime Kuma
    ├── photos/            # Immich
    ├── reverse-proxy/     # Caddy
    ├── webhook/           # CI/CD webhook receiver
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
| `configure-macvlan-bridge` | Persist macvlan bridge so host can reach macvlan containers | Docker LXC |
| `configure-proxmox-repos` | Switch from paid enterprise repos to free community repos | Proxmox host |
| `configure-ssh` | Harden SSH (key-only auth) and deploy authorized keys | All machines |
| `create-lxcs` | Create/update LXC containers from env var definitions (supports GPU passthrough via `_GPU=1`) | Proxmox host |
| `create-vms` | Create/update VMs (e.g. Home Assistant) | Proxmox host |
| `create-users` | Create Linux users/groups with aligned UIDs across machines | Docker LXC, NAS LXC |
| `install-docker` | Install Docker Engine from official apt repo | Docker LXC |
| `install-samba` | Install Samba, generate smb.conf from env vars | NAS LXC |
| `install-tools` | Install common utilities (git, jq, htop, curl) | All machines |
| `set-share-permissions` | Apply POSIX ACLs on file share directories | NAS LXC |

### Cascade

The `create-lxcs` module doesn't just create containers — after creation, it runs `setup.sh` inside each LXC via `pct exec`. This means:

```
setup.sh on Proxmox host
  → configure-proxmox-repos, install-tools, configure-amdgpu, configure-ssh
  → create-lxcs
    → creates Docker LXC (GPU passthrough if _GPU=1), then runs setup.sh inside it
      → create-users, install-tools, configure-ssh, install-docker, configure-macvlan-bridge
      → deploys HOMELAB_SERVICES (Jellyfin, Immich, Caddy, etc.)
    → creates NAS LXC, then runs setup.sh inside it
      → create-users, install-tools, configure-ssh, install-samba, set-share-permissions
  → create-vms (Home Assistant)
```

One command. Everything configured.

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

Each prefix requires `_GID` (groups) or `_UID` + `_GROUPS` (users). Names are derived by lowercasing the prefix. A primary group matching the username and UID is created automatically for each user.

To add a user: add their prefix to `HOMELAB_USERS` in `common.env`, define `_UID` and `_GROUPS`, then re-run `setup.sh` on each machine.

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

Infrastructure shares (`media`, `homelab`) are admin-only — non-admin family members access media through applications (e.g. Jellyfin), not the raw files.

Samba share definitions are **generated** by `install-samba` from the user/group env vars — no static config file to maintain. The `[global]` section lives in `nas/smb.conf.global` in the repo.

After creating the NAS LXC, set each user's Samba password:
```bash
smbpasswd -a <username>
```

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

## Env Files

Machine-specific configuration lives in `.env` files **outside the repo** (not committed — they contain secrets). The `.env.template` in the repo documents all available variables.

A shared `common.env` is sourced first, then the machine-specific file. This keeps values that must be identical across machines (timezone, network basics, users/groups) in one place. Machine-specific values override common ones.

Convention:
```
<mount>/homelab/
  ├── config/
  │   ├── common.env        # Shared vars (TZ, network, users/groups)
  │   ├── authorized_keys   # SSH public keys (shared by all machines)
  │   ├── olympus.env       # Proxmox host
  │   ├── apollo.env        # Docker LXC
  │   └── atlas.env         # NAS LXC
  └── repo/                # This git repo
```

Scripts find the env file via `/etc/homelab.env` (a symlink created on first setup) or by convention from the repo's location and the machine's hostname.

Values with spaces must be quoted:
```
HOMELAB_SETUP_MODULES="create-users install-tools install-docker"
```

## Image Management

Docker images are pinned to specific versions with SHA256 digests for reproducibility. [Renovate Bot](https://docs.renovatebot.com/) automatically opens PRs when new versions are available, so updates are reviewed before deployment.

## CI/CD

Pushes to `main` are automatically deployed via a [webhook receiver](https://github.com/adnanh/webhook) running in the Docker LXC. The Docker LXC acts as the deployment coordinator — it fans out to all physical machines via SSH.

### How It Works

1. GitHub sends a push event to the webhook endpoint
2. The webhook validates the HMAC-SHA256 signature and branch
3. `dispatch.sh` SSHes to each deploy target
4. Each machine's `deploy.sh` pulls latest changes and runs `setup.sh`
5. `setup.sh` runs idempotent modules, then deploys services — unchanged modules are no-ops and unchanged containers don't restart

Deploy targets are defined per the prefix-based pattern (`HOMELAB_DEPLOY_TARGETS`). Each target only needs a `_DEPLOY_HOST` — the machine's own env file determines what modules and services it runs.

For manual deployments (e.g. after changing env files), run `deploy.sh` on the machine, or use `run-service.sh <name>` / `run-all-services.sh` directly. To force-recreate a container (e.g. after changing a bind-mounted config file), use `recreate-service.sh <name>`.

### GitHub Webhook Configuration

In the repo's Settings → Webhooks:
- **URL:** `https://<webhook-fqdn>/deploy`
- **Content type:** `application/json`
- **Secret:** same value as `WEBHOOK_SECRET` in the env file
- **Events:** "Just the push event"
