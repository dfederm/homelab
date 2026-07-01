# Forgejo

Git hosting (the `forgejo` container) plus a co-located **Actions CI runner** (the
`forgejo-runner` container). Both ship in this one compose project: the runner has no purpose
without the git host, and being in the same project lets it reach Forgejo over the internal
network at `http://forgejo:3000` (no public-FQDN NAT hairpin, no TLS) and start/stop alongside it.

Both images are the **genuine official** Forgejo images, pulled from our own ghcr mirror
(`ghcr.io/dfederm/homelab/*`) because the upstream Forgejo registries are unreachable from this
network — the mirror is synced by [`.github/workflows/mirror-images.yml`](../../.github/workflows/mirror-images.yml).

Forgejo itself is configured entirely through `FORGEJO__*` env vars (see `docker-compose.yml`) and
needs no manual setup beyond claiming the admin account on first launch. The runner, however, needs
a few one-time admin actions, documented below.

## Actions runner

The runner lets Forgejo repos run Actions workflows and publish container images to Forgejo's
built-in OCI registry.

- **Image:** the official `forgejo-runner`, via our ghcr mirror
  (`ghcr.io/dfederm/homelab/forgejo-runner`). The upstream `code.forgejo.org` registry is
  unreachable from this network and has no third-party mirror, so we mirror the genuine image to
  ghcr ourselves. The official image is a bare binary, so the compose `command` builds a connection
  config from the shared secret and runs the daemon. See the comment block in `docker-compose.yml`.
- **State:** the generated connection config persists at
  `${DOCKER_APPDATA_ROOT}/forgejo-runner/config.yml` and survives container recreation.
- **Labels:** defined in the read-only `runner-config.yaml` (authoritative on every restart). The
  default label is `docker`; a workflow opts in with `runs-on: docker`.

### One-time operator setup

These steps need Forgejo admin access and write access to the NAS config dir — do them once, in
order. Field names below are exact.

#### 1. Confirm the Forgejo prerequisites (Site Admin)

Sign in as admin and open `https://<FORGEJO_FQDN>/-/admin`:

- **Actions** are enabled (default in Forgejo 15.x — no override is set here).
- The **Packages / container registry** is present (built-in, always on).
- **Site Admin → Actions → Runners** shows **no runner yet** (this is what we're adding).

#### 2. Register the runner with a shared secret

The runner uses the shared-secret model — a token from the web UI's "Create new Runner" does
**not** work. Generate a 40-char hex secret, register it with Forgejo (idempotent), then store it:

- Generate: `openssl rand -hex 20`.
- Register it on the Forgejo side (in the Docker LXC), naming the runner:
  ```bash
  docker exec --user git forgejo forgejo forgejo-cli actions register --keep-labels --name <host> --secret <secret>
  ```
- On the NAS, add it to the Docker host's env file (e.g. `apollo.env`):
  ```
  FORGEJO_RUNNER_TOKEN=<secret>
  ```
  The runner derives the matching connection uuid from the secret and connects on start; nothing
  is consumed, so re-deploys keep working.

> No `HOMELAB_SERVICES` change is needed — the runner is part of the `forgejo` service, so it
> deploys whenever `forgejo` does.

#### 3. Create two package access tokens (Forgejo PATs)

**Forgejo → Settings → Applications → Access Tokens.** Create two tokens, each scoped to
**`package`** only:

| Token | Scope | Used by |
|---|---|---|
| **CI push** | `package` → **write** | The CI workflow, to push the image. |
| **Host pull** | `package` → **read** | The Docker host, to pull the private image at deploy time (via the `configure-docker-registry` setup module). |

> Tip: in Forgejo the `package` scope offers read/write granularity. Use write for CI, read for the
> pull-only host token, so the long-lived host credential cannot push.

#### 4. Add the CI secrets to each repo that will use the registry

For each repo that runs CI against this runner: **Repo → Settings → Actions → Secrets**, add:

| Secret | Value |
|---|---|
| `CONTAINER_REGISTRY` | the registry host, i.e. `<FORGEJO_FQDN>` (no scheme). |
| `REGISTRY_USER` | the Forgejo username that owns the **CI push** PAT. |
| `REGISTRY_TOKEN` | the **CI push** PAT (`package:write`) from step 3. |

The **host pull** PAT (`package:read`) is consumed by the `configure-docker-registry` setup module,
which runs `docker login <CONTAINER_REGISTRY>` on the Docker host at setup time. Store it in the NAS
env as `CONTAINER_REGISTRY_TOKEN` (with `CONTAINER_REGISTRY_USER`), not as a repo secret.

#### 5. Enable Actions on the repo

**Repo → Settings → (Advanced / Units)** → enable **Actions** for each repo that will run workflows.

#### 6. Deploy and verify

> **Prerequisite:** both `ghcr.io/dfederm/homelab/forgejo` and `…/forgejo-runner` must already be
> mirrored and the packages set to **public** (the first
> [`mirror-images.yml`](../../.github/workflows/mirror-images.yml) run + the one-time
> visibility change) — otherwise this deploy's `docker compose pull` can't fetch them.

Deploy the Forgejo stack (on the Docker LXC):
```bash
./scripts/run-service.sh forgejo
```
Then confirm:

- **Site Admin → Actions → Runners** shows the runner as **Idle / online** with the `docker` label.
- Container logs show the runner registered and the daemon polling for jobs:
  ```bash
  docker logs forgejo-runner
  ```
- A repo workflow with `runs-on: docker` is picked up and runs.

### Day-2 notes

- **Re-register from scratch:** the secret is reusable — just re-run the `forgejo-cli actions
  register` from step 2 (idempotent) and redeploy. The generated `/data/config.yml` rebuilds on
  start; remove it (and any stale `.runner`) if you change the secret.
- **Changing runner labels / backend:** edit `runner-config.yaml`, then restart just the runner so
  it is re-read — this avoids bouncing the git host:
  ```bash
  docker restart forgejo-runner
  ```
  A label here MUST match a workflow's `runs-on:` exactly, or its jobs queue forever.
- **Egress:** job containers pull base images (e.g. `node` and language SDKs) from public
  registries — the Docker LXC needs outbound access to them (it has it).
