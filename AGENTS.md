# Repository Instructions — Homelab

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
- Automated deployments use persistent local Git checkouts on top-level targets. The Proxmox cascade synchronizes stable local source copies into LXCs; ZFS remains authoritative for config, secrets, and persistent data.

## Critical Conventions

### Scripts

- All scripts use `set -euo pipefail`.
- All setup modules **must be idempotent** — running them twice produces the same result with no unnecessary restarts or side effects.
- Source `$REPO_DIR/scripts/lib.sh` for shared helpers (e.g. `validate_env`, `apt_get`).
- Use `validate_env` to assert required env vars at the top of each module.
- Env vars use a **prefix-based pattern**: a space-separated list of prefixes (e.g. `HOMELAB_LXCS="DOCKER_LXC NAS_LXC"`), and each prefix has associated vars (`DOCKER_LXC_VMID`, `DOCKER_LXC_IP`, etc.). Use bash indirect expansion (`${!var_name}`) to access them.

### Idempotency Patterns

When writing or modifying setup modules, use these established patterns:

1. **Config file comparison (cmp)**: Generate desired config to a temp file, compare with existing, only replace + restart if different. Used by `install-samba`, `configure-macvlan-bridge`.
2. **Grep-before-append**: Check if a line exists before appending to a config file. Used for `lxc.*` entries in `create-lxcs` GPU passthrough.
3. **Config field comparison**: For `pct set`/`qm set`, parse current config and compare field-by-field against desired values. Strip auto-generated fields (hwaddr, type in net0 for LXCs; MAC address for VMs). Only apply + restart if something actually changed.
4. **`apt_get install -y -qq`**: use `lib.sh`'s `apt_get` wrapper, never bare `apt-get` — it retries past apt lock contention from the host's background update timers, which would otherwise abort the whole setup run. apt skips already-installed packages, so no explicit check is needed.

### Docker Compose Services

- Each service is a directory under `services/<name>/` with a `docker-compose.yml`.
- All values are parameterized via env vars — **no hardcoded IPs, domains, ports, or paths**.
- Images are **pinned by version AND sha256 digest** (e.g. `image: jellyfin/jellyfin:10.11.6@sha256:...`). Renovate Bot manages version bumps via PRs.
- Deploy with `scripts/run-service.sh <name>`. It sources the env files and runs `docker compose up -d`.
- Use `${DOCKER_APPDATA_ROOT}/<service>/` for persistent data bind mounts.

### Env Files

- Env files live **outside the repo** at `<zfs_mount>/homelab/config/`. They contain secrets and machine-specific values.
- `.env.template` inventories available variables. Keep it updated when adding new vars.
- `common.env` is sourced before machine-specific env files. Machine values override common ones.
- Explain non-obvious formats, dependencies, defaults, and hazards in `.env.template`; self-describing names need no comment.

### Proxmox / LXC / VM specifics

- LXCs are **privileged** (`--unprivileged 0`) for device passthrough and Docker compatibility.
- `pct set` cannot manage raw `lxc.*` config entries — those must be appended directly to `/etc/pve/lxc/<vmid>.conf`.
- `qm set` on a running VM triggers hot-plug which can fail (especially net0). Always compare config first and stop the VM before applying changes.
- `pct set` regenerates auto-assigned fields (hwaddr, type) in net0. Naive before/after comparison will always see "changes". Parse and compare individual fields, stripping auto-generated ones.

## When Creating New Setup Modules

1. Follow nearby modules in `scripts/setup/modules/<name>.sh`: `set -euo pipefail`, source `lib.sh`, validate required vars, use `apt_get`, and reconcile changes idempotently. List required env vars in the header.
2. List the module in the README and any new vars in `.env.template`. Activate it through the machine's `HOMELAB_SETUP_MODULES`.

## When Creating New Docker Services

1. Follow nearby Compose definitions in `services/<name>/docker-compose.yml`: parameterize site-specific values, pin image version and digest, and bind-mount persistent state under `${DOCKER_APPDATA_ROOT}/<name>/`.
2. Document the service in the README and new vars in `.env.template`. Activate it through the machine's `HOMELAB_SERVICES`.

## Style and Preferences

- **Data integrity is paramount** — This homelab stores irreplaceable personal data (family photos, documents, media). All operations must be non-destructive and safe. Never run destructive ZFS commands (`zfs destroy`, `zpool`), `rm -rf` on data directories, or Docker volume removal without explicit user confirmation. When in doubt, ask before acting. Prefer copy-then-verify over move operations.
- **YAGNI** — Don't over-engineer or add features "just in case". Solve the current problem.
- **Config-driven** — Behavior should be controlled by env vars, not by editing scripts.
- **Simple and readable** — Prefer clear bash over clever one-liners. Comment only when the "why" isn't obvious.
- **No secrets in the repo** — This repo is public. All sensitive values go in env files.
- **No personal information in the repo** — Never hardcode setup-specific IPs, hostnames, usernames, domains, or paths; use env vars. Keep any details shared for troubleshooting out of committed files.
- **Don't commit without review, don't push without explicit approval** — Leave changes unstaged for the user to review. Never auto-commit. **Push may trigger immediate deployment** if the user has configured a deploy webhook (push → webhook signals each top-level target → each worker serializes and coalesces `setup.sh`). The user may want to stack multiple commits and push as a batch to avoid deploy churn. Always wait for explicit "push" / "deploy" / "go ahead" from the user before `git push`.
- **Surgical changes** — When modifying existing files, change only what's needed. Don't reformat or restructure unrelated code.

## Testing Changes

- Run `setup.sh` on the Proxmox host — it cascades into LXCs automatically.
- Run `setup.sh` **twice** to verify idempotency. The second run should produce no restarts, no "config changed" messages.
- For Docker service changes, use `scripts/run-service.sh <name>` to redeploy. This script must run **inside the Docker LXC**, not on the Proxmox host.
- Verify services are healthy after changes (e.g. `docker ps`, check web UIs).

## Important Operational Details

- **Module ordering matters** — Modules run in the order listed in `HOMELAB_SETUP_MODULES`. Dependencies must be reflected in ordering (e.g. `configure-amdgpu` before `create-lxcs` so `/dev/dri` exists for GPU passthrough).
- **run-service.sh runs inside the Docker LXC** — It sources env files and calls `docker compose`. From the Proxmox host, use `pct exec <vmid> -- bash ...` or SSH into the LXC.
- **Bind mount paths differ per context** — ZFS data and config datasets are mounted at different paths on the host vs inside LXCs. `create-lxcs` derives the guest config path from each prefix's `_MP*` mappings; deployment source uses `HOMELAB_REPO_DIR`.
- **The env file discovery chain** — `setup.sh` finds its env file via: (1) explicit CLI argument, (2) `/etc/homelab.env` symlink (created on first run), (3) `<config_dir>/<hostname>.env`. Once resolved, it symlinks to `/etc/homelab.env` for future runs.
- **ZFS datasets need POSIX ACL support** — If the user reports permission issues, check that `acltype=posixacl` and `xattr=sa` are set on the relevant datasets.

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
