# Copilot Instructions — Homelab

## What This Repo Is

Declarative infrastructure-as-code for a homelab running Proxmox VE. Everything — host config, LXC containers, VMs, Docker services, Samba shares, user management — is defined here and applied via idempotent bash scripts. The primary server runs Proxmox with LXCs and VMs, but the setup system supports additional machines (e.g. a Raspberry Pi running a single service). The repo is public; secrets live in env files outside the repo on the ZFS pool.

## Architecture

The specific LXCs, VMs, and services are all defined by env vars — the repo supports any number of each. A typical deployment looks like:

```
Proxmox VE host (Debian)
├── ZFS pool (all persistent data)
├── Docker LXC (privileged) — runs all containerized services
│   └── Docker Compose services (Jellyfin, Immich, AdGuard, Caddy, etc.)
├── NAS LXC (privileged) — Samba file sharing
└── Home Assistant VM — HAOS, manages itself
```

- LXC root filesystems are **ephemeral** — destroy and recreate from this repo at any time.
- All persistent data lives on **ZFS datasets bind-mounted** into containers. No SMB mounts for Docker.
- Docker containers use **bind mounts to ZFS** (via `${DOCKER_APPDATA_ROOT}`), not named volumes. Named volumes are only acceptable for ephemeral IPC (e.g. Unix sockets between containers).
- The repo is cloned on the ZFS pool and bind-mounted into LXCs. Changes flow via git push/pull, not direct SMB edits.

## Critical Conventions

### Scripts

- All scripts use `set -euo pipefail`.
- All setup modules **must be idempotent** — running them twice produces the same result with no unnecessary restarts or side effects.
- Source `$REPO_DIR/scripts/lib.sh` for shared helpers (e.g. `validate_env`).
- Use `validate_env` to assert required env vars at the top of each module.
- Env vars use a **prefix-based pattern**: a space-separated list of prefixes (e.g. `HOMELAB_LXCS="DOCKER_LXC NAS_LXC"`), and each prefix has associated vars (`DOCKER_LXC_VMID`, `DOCKER_LXC_IP`, etc.). Use bash indirect expansion (`${!var_name}`) to access them.

### Idempotency Patterns

When writing or modifying setup modules, use these established patterns:

1. **Config file comparison (cmp)**: Generate desired config to a temp file, compare with existing, only replace + restart if different. Used by `install-samba`, `configure-macvlan-bridge`.
2. **Grep-before-append**: Check if a line exists before appending to a config file. Used for `lxc.*` entries in `create-lxcs` GPU passthrough.
3. **Config field comparison**: For `pct set`/`qm set`, parse current config and compare field-by-field against desired values. Strip auto-generated fields (hwaddr, type in net0 for LXCs; MAC address for VMs). Only apply + restart if something actually changed.
4. **apt-get install -y -qq**: apt skips already-installed packages. No explicit check needed.

### Docker Compose Services

- Each service is a directory under `services/<name>/` with a `docker-compose.yml`.
- All values are parameterized via env vars — **no hardcoded IPs, domains, ports, or paths**.
- Images are **pinned by version AND sha256 digest** (e.g. `image: jellyfin/jellyfin:10.11.6@sha256:...`). Renovate Bot manages version bumps via PRs.
- Deploy with `scripts/run-service.sh <name>`. It sources the env files and runs `docker compose up -d`.
- Use `${DOCKER_APPDATA_ROOT}/<service>/` for persistent data bind mounts.

### Env Files

- Env files live **outside the repo** at `<zfs_mount>/homelab/config/`. They contain secrets and machine-specific values.
- `.env.template` in the repo documents ALL available variables. Keep it updated when adding new vars.
- `common.env` is sourced before machine-specific env files. Machine values override common ones.
- When adding a new env var, add it to `.env.template` with a comment explaining its purpose.

### Proxmox / LXC / VM specifics

- LXCs are **privileged** (`--unprivileged 0`) for device passthrough and Docker compatibility.
- `pct set` cannot manage raw `lxc.*` config entries — those must be appended directly to `/etc/pve/lxc/<vmid>.conf`.
- `qm set` on a running VM triggers hot-plug which can fail (especially net0). Always compare config first and stop the VM before applying changes.
- `pct set` regenerates auto-assigned fields (hwaddr, type) in net0. Naive before/after comparison will always see "changes". Parse and compare individual fields, stripping auto-generated ones.

## When Creating New Setup Modules

1. **Study an existing module first** — Look at 2-3 existing modules in `scripts/setup/modules/` to understand the conventions, patterns, and logging style before writing a new one
2. Place in `scripts/setup/modules/<name>.sh`
3. Start with `set -euo pipefail` and `source "$REPO_DIR/scripts/lib.sh"`
4. Document required env vars in the file header comment
5. Use `validate_env` for required vars
6. Make it idempotent — check before modifying, log what changed vs what was already correct
7. Add to the module table and cascade diagram in `README.md`
8. Add to `.env.template` if new env vars are needed
9. The module is activated by adding its name to `HOMELAB_SETUP_MODULES` in a machine's env file

## When Creating New Docker Services

1. **Study an existing service first** — Look at 2-3 existing services in `services/` to match the compose style, env var naming, and volume mount patterns
2. Create `services/<name>/docker-compose.yml`
3. Parameterize everything — use env vars for ports, paths, domains, credentials
4. Pin the image version with a sha256 digest
5. Use bind mounts to `${DOCKER_APPDATA_ROOT}/<name>/` for persistent data
6. Add the service to the directory listing and services section in `README.md`
7. Add all new env vars to `.env.template` with comments
8. The service is activated by adding its name to `HOMELAB_SERVICES` in a machine's env file

## Style and Preferences

- **Data integrity is paramount** — This homelab stores irreplaceable personal data (family photos, documents, media). All operations must be non-destructive and safe. Never run destructive ZFS commands (`zfs destroy`, `zpool`), `rm -rf` on data directories, or Docker volume removal without explicit user confirmation. When in doubt, ask before acting. Prefer copy-then-verify over move operations.
- **YAGNI** — Don't over-engineer or add features "just in case". Solve the current problem.
- **Config-driven** — Behavior should be controlled by env vars, not by editing scripts.
- **Simple and readable** — Prefer clear bash over clever one-liners. Comment only when the "why" isn't obvious.
- **No secrets in the repo** — This repo is public. All sensitive values go in env files.
- **No personal information in the repo** — This repo is designed to be generic and reusable by anyone. Never hardcode IPs, hostnames, usernames, domains, paths, or any setup-specific values into scripts, compose files, or documentation. All such values must be parameterized via env vars. You may prompt the user for personal/setup-specific information to investigate issues, validate configurations, or provide guidance. You may also store such information in memory (via `store_memory`) for future interactions with the same user. But that information must never be committed to the repo.
- **Don't commit without review** — Leave changes unstaged for the user to review. Never auto-commit.
- **Surgical changes** — When modifying existing files, change only what's needed. Don't reformat or restructure unrelated code.

## Testing Changes

- Run `setup.sh` on the Proxmox host — it cascades into LXCs automatically.
- Run `setup.sh` **twice** to verify idempotency. The second run should produce no restarts, no "config changed" messages.
- For Docker service changes, use `scripts/run-service.sh <name>` to redeploy. This script must run **inside the Docker LXC**, not on the Proxmox host.
- Verify services are healthy after changes (e.g. `docker ps`, check web UIs).

## Important Operational Details

- **Module ordering matters** — Modules run in the order listed in `HOMELAB_SETUP_MODULES`. Dependencies must be reflected in ordering (e.g. `configure-amdgpu` before `create-lxcs` so `/dev/dri` exists for GPU passthrough).
- **run-service.sh runs inside the Docker LXC** — It sources env files and calls `docker compose`. From the Proxmox host, use `pct exec <vmid> -- bash ...` or SSH into the LXC.
- **Bind mount paths differ per context** — ZFS datasets are mounted at different paths on the host vs inside LXCs. For example, the repo might be at `/<pool>/homelab/repo` on the host but `/mnt/homelab/repo` inside an LXC (determined by the `_MP*` env vars). Always use env vars, never assume paths.
- **The env file discovery chain** — `setup.sh` finds its env file via: (1) explicit CLI argument, (2) `/etc/homelab.env` symlink (created on first run), (3) `<config_dir>/<hostname>.env`. Once resolved, it symlinks to `/etc/homelab.env` for future runs.
- **ZFS datasets need POSIX ACL support** — If the user reports permission issues, check that `acltype=posixacl` and `xattr=sa` are set on the relevant datasets.

## Key File Locations (on the server)

If you need to reference paths in scripts or compose files, ask the user for their specific values. These are the env vars that control paths:

- `ZFS_POOL` — ZFS pool name (root dataset)
- `DOCKER_APPDATA_ROOT` — Where Docker service data lives (bind-mounted from ZFS)
- `SHARE_ROOT` — Root of the Samba file share
- `REPO_DIR` — Set automatically by setup.sh; the absolute path to this repo on the server

Do not hardcode any paths. Always use the env vars.

## Common Tasks Reference

| Task | Command (on Proxmox host) |
|------|--------------------------|
| Full setup/update | `bash scripts/setup/setup.sh` |
| System package updates | `bash scripts/update.sh` |
| Deploy one service | On the Docker LXC: `bash <repo_path>/scripts/run-service.sh <name>` |
| Deploy all services | On the Docker LXC: `bash <repo_path>/scripts/run-all-services.sh` |
| Check LXC status | `pct list` |
| Check VM status | `qm list` |
| Enter LXC shell | `pct exec <vmid> -- bash` |

## Getting Oriented in a New Session

When starting a new session or task, quickly orient yourself:

1. Read `README.md` for the current architecture, module list, and cascade diagram
2. Check `.env.template` for all available configuration variables
3. List `services/` to see what Docker services exist
4. List `scripts/setup/modules/` to see what setup modules exist
5. If the user mentions a specific service, machine, or module — read its files before making changes
