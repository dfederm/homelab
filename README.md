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
│   ├── dispatch.sh        # Webhook handler: pulls code, fans out setup to all machines
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
    ├── ai/               # Ollama (LLM) + Open WebUI (chat) + SearXNG (web search) + Athena MCP (homelab-status + shopping-list MCP)
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
| `configure-pi-kiosk` | Set up Cage + Chromium kiosk browser pointing at a URL (Raspberry Pi specific) | Alarm panel Pi |
| `configure-scrutiny-collector` | Install Scrutiny SMART collector (pinned binary) + timer; pushes drive health to the Scrutiny web UI | Proxmox host |
| `configure-macvlan-bridge` | Persist macvlan bridge so host can reach macvlan containers | Docker LXC |
| `configure-docker-registry` | Log the Docker host into the private OCI registry (`CONTAINER_REGISTRY`) so it can pull our self-published images (e.g. Athena MCP) | Docker LXC |
| `configure-proxmox-repos` | Switch from paid enterprise repos to free community repos | Proxmox host |
| `configure-smb-mount` | Mount NAS share via CIFS, persist in fstab | Remote machines |
| `configure-lxc-fstrim` | Scheduled `pct fstrim` of LXC rootfs volumes (`LXC_FSTRIM_SCHEDULE`) so blocks freed inside containers return to the LVM thin pool | Proxmox host |
| `configure-ssh` | Harden SSH (key-only auth) and deploy authorized keys | All machines |
| `configure-storage-alerts` | Periodic threshold alerts for LVM thin-pool + ZFS pool capacity (the storage Beszel can't see) | Proxmox host |
| `configure-storage-health` | Schedule monthly ZFS scrubs + daily pool health check + SMART self-tests (smartd), with degradation alerting | Proxmox host |
| `create-lxcs` | Create/update LXC containers from env var definitions (supports GPU passthrough via `_GPU=1`) | Proxmox host |
| `create-vms` | Create/update VMs (e.g. Home Assistant) | Proxmox host |
| `create-users` | Create Linux users/groups with aligned UIDs across machines | Docker LXC, NAS LXC |
| `install-beszel-agent` | Install the Beszel monitoring agent natively (binary + systemd) on hosts without Docker | Proxmox host, NAS LXC |
| `install-docker` | Install Docker Engine from official apt repo | Docker LXC |
| `install-samba` | Install Samba, generate smb.conf from env vars | NAS LXC |
| `install-tools` | Install common utilities (git, jq, htop, curl) | All machines |
| `set-share-permissions` | Apply POSIX ACLs on file share directories | NAS LXC |

### Cascade

The `create-lxcs` module doesn't just create containers — after creation, it runs `setup.sh` inside each LXC via `pct exec`. This means:

```
setup.sh on Proxmox host
  → configure-proxmox-repos, install-tools, configure-amdgpu, configure-ssh,
    install-beszel-agent, configure-storage-alerts
  → configure-storage-health (ZFS scrub + SMART self-tests + alerting), configure-scrutiny-collector
  → configure-lxc-fstrim (periodic thin-pool reclaim for LXC rootfs)
  → create-lxcs
    → creates Docker LXC (GPU passthrough if _GPU=1), then runs setup.sh inside it
      → create-users, install-tools, configure-ssh, install-docker, configure-docker-registry, configure-macvlan-bridge
      → deploys HOMELAB_SERVICES (Jellyfin, Immich, Caddy, Scrutiny, monitoring, monitoring-agent, etc.)
    → creates NAS LXC, then runs setup.sh inside it
      → create-users, install-tools, configure-ssh, install-samba, set-share-permissions,
        install-beszel-agent
  → create-vms (Home Assistant)
```

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

Machines outside Proxmox (e.g. a Raspberry Pi) can't use ZFS bind mounts — they access the repo and config via an SMB mount from the NAS. The `bootstrap-remote.sh` script handles the chicken-and-egg problem: the machine needs the NAS mount to access the repo, but the mount module is in the repo.

**First-time setup:**

1. Create a `<hostname>.env` in the config directory on the NAS (see `.env.template`)
2. Include `configure-smb-mount` in `HOMELAB_SETUP_MODULES` so the mount persists across reboots
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
5. Add the machine to `HOMELAB_DEPLOY_TARGETS` in the webhook host's env file so future pushes deploy automatically

After bootstrapping, the machine is fully managed — `dispatch.sh` will SSH into it and run `setup.sh` on every push to `main`, just like the Proxmox host and LXCs.

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

Infrastructure shares (`media`, `homelab`) are admin-only — non-admin family members access media through applications (e.g. Jellyfin), not the raw files. The `homelab` share's `config/` and `backup/` subdirectories are set to `root:admin 775` so admin users can edit env files and write backups (e.g. Home Assistant) via SMB.

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

**Detection now, push alerting later.** This delivers the *detection*: a failing scrub or
degraded pool fails its systemd unit (visible via `systemctl --failed` and the journal),
smartd logs SMART degradation to syslog, and Scrutiny shows drive health on its dashboard.
Active **push** notifications (ntfy / Pushover / Gotify / Uptime Kuma) are intentionally
deferred until the homelab alerting backend is chosen — that work will hook ZFS + SMART +
Scrutiny into the chosen backend in one place.

**Schedules are opt-out per feature.** Each scheduled task is gated by its schedule env
var (`ZFS_SCRUB_SCHEDULE`, `ZFS_HEALTH_CHECK_SCHEDULE`, `SMART_SELFTEST_SCHEDULE`,
`SCRUTINY_COLLECTOR_SCHEDULE`). `.env.template` ships recommended defaults; **clear a value
(set it empty) to disable that specific feature** — the module then removes the
corresponding timer. (smartd still runs for monitoring even with self-tests disabled.)

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

### AI (Ollama + Open WebUI)

`services/ai/` runs the family AI stack as a single compose project on the shared internal
`ai` Docker network: [Ollama](https://ollama.com) for local, CPU-based LLM serving, and
[Open WebUI](https://openwebui.com) as the multi-user chat frontend in front of it.

Ollama models are pulled into `${DOCKER_APPDATA_ROOT}/ollama` (ZFS-backed) so they
survive container recreation. Ollama has **no authentication**, so it is never placed
behind the public reverse proxy — it is reachable only on the internal `ai` network (Open
WebUI reaches it at `http://ollama:11434`) and, via `OLLAMA_HTTP_PORT`, on the LAN.

Open WebUI **does** have its own multi-user auth (the first account created becomes the
admin), so unlike Ollama it is exposed via Caddy at `OPEN_WEBUI_FQDN`. It is also reachable
on the LAN at `http://<docker-host-ip>:${OPEN_WEBUI_HTTP_PORT}`. Its SQLite DB + ChromaDB
(per-user chats, settings, RAG vectors) persist on `${DOCKER_APPDATA_ROOT}/open-webui`
(ZFS-backed).

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
- `OPEN_WEBUI_TASK_MODEL` seeds a small/fast task model (e.g. `qwen2.5:7b`) for
  title/tag/query generation so the large chat model isn't burned on trivia; it can be
  changed later in the UI (it is a first-launch-seeded "PersistentConfig" value).
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

Open WebUI's **web search** is wired to the self-hosted SearXNG backend (see below), not
the built-in DuckDuckGo scraper.

### Web search (SearXNG)

The `services/ai/` stack also runs [SearXNG](https://docs.searxng.org), a self-hosted
metasearch engine, as the homelab's **private web-search backend**. It replaces Open WebUI's
built-in DuckDuckGo search (scraping-based and rate-limit-prone) and is the intended backend
for a future web-search MCP tool. It is a backend, not a family-facing UI — it has **no auth**, so
like Ollama it is never placed behind the public reverse proxy. It publishes no host port:
consumers reach it over the shared `ai` Docker network at `http://searxng:8080`.

Config is declarative: `services/ai/searxng/settings.yml` is mounted read-only and carries only
the overrides on top of SearXNG's defaults — chiefly enabling the **JSON API**
(`search.formats: [html, json]`) so programmatic clients can query it. Its runtime cache
persists on `${DOCKER_APPDATA_ROOT}/searxng` (ZFS-backed).

- `SEARXNG_SECRET` (a **secret**, never committed) is injected at runtime and overrides
  SearXNG's `server.secret_key`. Generate one with `openssl rand -hex 32`.
- Open WebUI's web-search wiring is the `ENABLE_WEB_SEARCH` / `WEB_SEARCH_ENGINE=searxng` /
  `SEARXNG_QUERY_URL` env on the `open-webui` service. These are Open WebUI **PersistentConfig**
  values — read on first launch then managed in the UI/DB, so changing them later requires
  re-seeding (wiping the Open WebUI data) or toggling them in Admin Settings → Web Search.
- SearXNG deploys as part of the `ai` service — no separate `HOMELAB_SERVICES` entry is needed.

### Athena MCP (homelab-status + shopping-list MCP server)

The `services/ai/` stack also runs **Athena MCP**, an [MCP](https://modelcontextprotocol.io) server
that exposes homelab health as tools — Beszel systems + metrics, Scrutiny drive SMART health, and
Proxmox storage capacity + guests (all read-only) — plus **Koffan shopping-list** tools (list, add,
and check items) over Streamable HTTP, consumed by **Open WebUI's native MCP** client so the family
AI can answer "is everything healthy?" or add to the shopping list from live data.

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
host's published port, `${DOCKER_HOST_IP}:${KOFFAN_HTTP_PORT}`, since it runs on a separate network);
the `ATHENA_MCP_*` keys are this service's own credentials. `Homelab__Proxmox__AllowInsecureTls=true`
is set in compose (config, not a secret): the Proxmox API presents a self-signed cert, trusted for
this client only.

**One-time operator setup** (needs admin on Forgejo/Beszel/Proxmox + write access to the NAS config):

1. **Give the Docker host registry credentials** so it can pull the image. This is declarative: set
   `CONTAINER_REGISTRY`, `CONTAINER_REGISTRY_USER`, and `CONTAINER_REGISTRY_TOKEN` (a `package:read`
   Forgejo PAT) in the NAS env, and add `configure-docker-registry` to the Docker host's
   `HOMELAB_SETUP_MODULES` (after `install-docker`). Setup then runs `docker login` for you and
   re-authenticates automatically after an LXC rebuild — no manual step to remember.
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
4. **Register the server in Open WebUI** (a PersistentConfig/UI step, like the SearXNG web-search
   wiring) pointing at `http://athena-mcp:8080` — deploying only makes it *reachable*, not wired in.

After `./scripts/run-service.sh ai`, confirm `docker ps` shows `athena-mcp` `(healthy)` and
`docker exec open-webui curl -s http://athena-mcp:8080/health` returns `Healthy`.

> **Health check:** the ASP.NET runtime image has no `curl`/`wget`/`bash`, so the container can't
> probe its `/health` endpoint with a shell command. Instead the app probes itself — the `healthcheck`
> re-invokes the binary as `dotnet /app/AthenaMcp.Server.dll --health-check`, which issues an
> in-process GET to `/health` and exits `0` (healthy) / non-zero (unhealthy).

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

Adding a target is therefore NAS-only: create its `<target>.env` and add its name to
`BACKUP_INSTANCES` — no repo change.

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

### Self-mirrored images (ghcr)

A few upstream registries are unreachable from this network due to upstream routing problems (notably Forgejo's `codeberg.org` and `code.forgejo.org`, which time out from this ISP). Rather than depend on an unverified third-party Docker Hub mirror, the [`mirror-images`](.github/workflows/mirror-images.yml) GitHub Actions workflow copies the genuinely-official images to `ghcr.io/dfederm/homelab/*` (GitHub-hosted runners can reach the upstream registries; the homelab can reach ghcr). The compose files then pull from ghcr.

The workflow runs weekly and on demand (`workflow_dispatch`). For each image in its matrix it picks the newest stable upstream release, copies the full multi-arch manifest with `skopeo copy --all` (preserving the official digest), and prints the pinnable `@sha256` ref in its run summary. Versions are not pinned in the workflow — it always mirrors the newest stable release, and Renovate pins the exact version+digest in the compose files (so a version bump never needs a workflow edit first). To mirror another image, add a row to the workflow's matrix.

One-time admin per mirrored package: none — packages pushed from this public repo inherit its visibility, so they are public and the homelab pulls them without authentication. Renovate tracks the ghcr ref like any other image and opens version/digest bump PRs.

> **Merge ordering matters.** When first repointing a compose image at a self-mirrored ghcr ref, run the workflow *before* merging the compose change, and pin a tag the run actually published (shown in its summary; the workflow mirrors the newest stable upstream release, which may differ from the tag currently in compose). Deploys pull the image (`docker compose pull`) — merging a tag that was never mirrored would point a live service at an image that does not exist yet and fail its next deploy. After bootstrap, Renovate keeps the compose tag and the published ghcr tags in sync.

## CI/CD

Pushes to `main` are automatically deployed via a [webhook receiver](https://github.com/adnanh/webhook) running in the Docker LXC. The Docker LXC acts as the deployment coordinator — it pulls the latest code centrally, then fans out to all machines via SSH.

### How It Works

1. GitHub sends a push event to the webhook endpoint
2. The webhook validates the HMAC-SHA256 signature and branch
3. `dispatch.sh` pulls latest code (`git fetch + reset`) — all machines share the repo via NAS mounts, so one pull updates it everywhere
4. `dispatch.sh` SSHes to each deploy target and kicks off `setup.sh` asynchronously (fire-and-forget)
5. Each machine's `setup.sh` runs idempotent modules, then deploys services — unchanged modules are no-ops and unchanged containers don't restart

The async dispatch avoids a self-termination problem: a synchronous deploy chain would eventually restart the webhook container (which is itself a deployed service), killing the dispatch process mid-execution. With fire-and-forget, dispatch completes in seconds before any containers are restarted.

Deploy targets are defined per the prefix-based pattern (`HOMELAB_DEPLOY_TARGETS`). Each target only needs a `_DEPLOY_HOST` — the machine's own env file determines what modules and services it runs.

Deploy results are logged on each target at `/var/log/homelab-deploy.log`.

For manual deployments (e.g. after changing env files), run `deploy.sh` on the machine, or use `run-service.sh <name>` / `run-all-services.sh` directly. To force-recreate a container (e.g. after changing a bind-mounted config file), use `recreate-service.sh <name>`.

### GitHub Webhook Configuration

In the repo's Settings → Webhooks:
- **URL:** `https://<webhook-fqdn>/deploy`
- **Content type:** `application/json`
- **Secret:** same value as `WEBHOOK_SECRET` in the env file
- **Events:** "Just the push event"
