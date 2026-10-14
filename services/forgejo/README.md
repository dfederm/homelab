# Forgejo

Forgejo and its Actions runner deploy together. Their official images come
from the [ghcr mirror](../../.github/workflows/mirror-images.yml) because the
upstream registries are unreachable. Claim the admin account on first launch;
the runner needs the one-time setup below.

## Actions runner

The runner's connection state persists under `${DOCKER_APPDATA_ROOT}/forgejo-runner/`.
Labels live in the read-only `runner-config.yaml`; jobs use `runs-on: docker`
by default.

### One-time operator setup

These steps need Forgejo admin access and write access to the NAS config dir — do them once, in
order. Field names below are exact.

#### 1. Confirm the Forgejo prerequisites (Site Admin)

Sign in as admin and open `https://<FORGEJO_FQDN>/-/admin`:

- **Actions** are enabled (default in Forgejo 15.x — no override is set here).
- The **Packages / container registry** is present (built-in, always on).
- **Site Admin → Actions → Runners** shows **no runner yet** (this is what we're adding).

#### 2. Add the runner's shared secret to the env file

The runner uses a shared secret, **not** a token from the UI's "Create new
Runner". Generate 40 hex characters with `openssl rand -hex 20` and set
`FORGEJO_RUNNER_TOKEN` in the Docker host's external env file.

`post-up.sh` registers it idempotently after Compose starts. On a brand-new
Forgejo with no persisted `/data`, first complete the setup wizard and claim
admin; the hook skips registration until the next deploy.

To register manually when debugging:
```bash
printf '%s' "$FORGEJO_RUNNER_TOKEN" | docker exec -i --user git forgejo \
  forgejo forgejo-cli actions register --keep-labels --name <host> --secret-stdin=stdin
```
`--secret-stdin=stdin` requires a value even though the value is ignored.

#### 3. Create two package access tokens (Forgejo PATs)

**Forgejo → Settings → Applications → Access Tokens.** Create two tokens, each scoped to
**`package`** only:

| Token | Scope | Used by |
|---|---|---|
| **CI push** | `package` → **write** | The CI workflow, to push the image. |
| **Host pull** | `package` → **read** | The Docker host, to pull the private image at deploy time (via the `ai` stack's `pre-up.sh` hook). |

#### 4. Add the CI secrets to each repo that will use the registry

For each repo that runs CI against this runner: **Repo → Settings → Actions → Secrets**, add:

| Secret | Value |
|---|---|
| `CONTAINER_REGISTRY` | the registry host, i.e. `<FORGEJO_FQDN>` (no scheme). |
| `REGISTRY_USER` | the Forgejo username that owns the **CI push** PAT. |
| `REGISTRY_TOKEN` | the **CI push** PAT (`package:write`) from step 3. |

The **host pull** PAT (`package:read`) is consumed by the `ai` stack's pre-deploy hook
(`services/ai/pre-up.sh`), which runs `docker login <CONTAINER_REGISTRY>` on the Docker host right
before pulling `athena-mcp`. Store it in the NAS env as `CONTAINER_REGISTRY_TOKEN` (with
`CONTAINER_REGISTRY_USER`), not as a repo secret.

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

- **Re-register from scratch:** the secret is reusable — a re-register happens automatically on
  every `run-service.sh forgejo` (the `post-up.sh` hook, idempotent). The generated `/data/config.yml`
  rebuilds on start; remove it (and any stale `.runner`) if you change the secret.
- **Changing runner labels / backend:** edit `runner-config.yaml`, then restart just the runner so
  it is re-read — this avoids bouncing the git host:
  ```bash
  docker restart forgejo-runner
  ```
  A label here MUST match a workflow's `runs-on:` exactly, or its jobs queue forever.
- **Egress:** job containers pull base images (e.g. `node` and language SDKs) from public
  registries — the Docker LXC needs outbound access to them (it has it).
