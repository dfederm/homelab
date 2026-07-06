# Authelia (SSO)

The homelab's **single sign-on / identity provider**. It gives the family one login for the
services that support it and lets admin surfaces sit behind 2FA. Authelia offers two integration
methods:

- **OpenID Connect 1.0 (OIDC)** — Authelia acts as an OIDC provider (IdP). Apps that speak OIDC
  (Open WebUI, Forgejo, Immich, Vikunja, Miniflux, …) redirect their login to Authelia. This works
  for those apps' **native/mobile clients** too, so it's the preferred method wherever an app
  supports it.
- **forward-auth** — for browser-only web UIs with no auth of their own (e.g. an admin dashboard),
  Caddy delegates the auth decision to Authelia with a `forward_auth` directive.

Open WebUI is wired via **OIDC** as the reference example (see the recipe below); browser-only UIs
can be added with **forward-auth** using the recipe further down.

### Holdouts (deliberately NOT behind Authelia)

Some services keep their **own** auth because putting them behind SSO would break their native
clients — and, as a bonus, they double as break-glass access if Authelia is ever down:

- **Jellyfin** — TV / tablet / mobile apps expect Jellyfin's own accounts.
- **Home Assistant** — the companion app authenticates against HA directly.
- **Radicale** — CalDAV clients use HTTP Basic auth.

Open WebUI itself also **keeps its local login enabled as break-glass** — OIDC is added on top, not
as a replacement (`OAUTH_AUTO_REDIRECT` is left off so the local login form still appears).

## How the config is structured

- `docker-compose.yml` — the container. Enables the `template` config filter and passes the scalar
  secrets from the environment.
- `configuration.yml` — **committed, declarative, no secrets, no personal domains.** Personal values
  (domains, the OIDC issuer key) are injected at load time by the `template` filter from the
  non-secret env vars and the mounted key file. Scalar secrets are loaded by Authelia directly from
  `AUTHELIA_*` env vars and are intentionally absent from this file.
- `users.example.yml` — a template for the **file user backend**. The real `users.yml` is a secret
  (password hashes + emails) kept on the NAS, never in this repo.

### Secrets and state live off the repo

| Location | Contents | Notes |
|---|---|---|
| `<hostname>.env` | `AUTHELIA_*` secrets + non-secret FQDN/port vars | See `.env.template` for the full list. |
| `${CONFIG_DIR}/authelia/users.yml` | file user backend (argon2 hashes, emails, groups) | Mounted read-only at `/secrets/users.yml`. |
| `${CONFIG_DIR}/authelia/oidc.private.pem` | OIDC issuer RSA private key | Mounted read-only; inlined into `configuration.yml` by the template filter. |
| `${CONFIG_DIR}/authelia/open-webui-client.digest` | pbkdf2 digest of Open WebUI's OIDC client secret | A file (not an env var): the `$`-laden digest would be mangled by `docker compose --env-file` interpolation. Inlined into `configuration.yml`. |
| `${DOCKER_APPDATA_ROOT}/authelia/` | SQLite DB (2FA enrollments + prefs) + notifier file | Persistent state on ZFS-backed appdata. |

> **All three files under `${CONFIG_DIR}/authelia/` must exist before the first deploy.** Docker
> creates a missing bind-mount source as an empty directory, which makes Authelia fail to start.

> **Permissions.** `${CONFIG_DIR}` is an admin SMB share (owner `root:admin`, `group:admin:rwx`). If
> you let the `docker run` in step 2 create `${CONFIG_DIR}/authelia/`, Docker makes it `root:root`
> *without* that ACL, so you won't be able to add `users.yml` to it over SMB afterward. Fix: after
> provisioning the files, normalize the directory as root in the NAS LXC with
> `bash scripts/repair-share-acls.sh --apply` (target the config dir; see the script header). It
> restores `root:admin` + `group:admin:rwx` + world-readable — matching the rest of the config share
> — so admins can edit `users.yml` and the container can read the secrets.

## First-run operator setup

All `authelia crypto …` helpers below can be run with a throwaway container so you don't need
Authelia deployed yet:

```bash
alias authcli='docker run --rm authelia/authelia:4.39.20 authelia'
```

### 1. Generate the scalar secrets → `<hostname>.env`

Each of these is an independent random secret. Generate four:

```bash
authcli crypto rand --length 64 --charset alphanumeric
```

Assign the four values to, in `<hostname>.env`:

| `<hostname>.env` var | Purpose |
|---|---|
| `AUTHELIA_SESSION_SECRET` | Signs session cookies. |
| `AUTHELIA_STORAGE_ENCRYPTION_KEY` | Encrypts sensitive columns in the SQLite DB. |
| `AUTHELIA_JWT_SECRET` | Signs identity-verification (e.g. password-reset) JWTs. |
| `AUTHELIA_OIDC_HMAC_SECRET` | Signs OIDC tokens' HMAC. |

### 2. Generate the OIDC issuer key → NAS

Generate the RSA key pair straight into the NAS config dir, keeping only the private half (Authelia
derives the public key):

```bash
docker run --rm -v ${CONFIG_DIR}/authelia:/out authelia/authelia:4.39.20 \
  sh -c 'authelia crypto pair rsa generate --directory /out && mv /out/private.pem /out/oidc.private.pem && rm -f /out/public.pem'
```

Result: `${CONFIG_DIR}/authelia/oidc.private.pem` (keep the file private; the public half is derived
by Authelia).

### 3. Create the users file → NAS

Copy `users.example.yml` to `${CONFIG_DIR}/authelia/users.yml`, then set real display names, emails,
and password hashes. Leave `groups: []` — every user gets 2FA, and Open WebUI's admin role is managed
inside Open WebUI (the first sign-in becomes admin; others are promoted there). Generate each
password hash:

```bash
authcli crypto hash generate argon2 --password 'the-password'
```

Paste each `$argon2id$…` string as that user's `password:` (quote it — it contains `$`).

### 4. Register the Open WebUI OIDC client secret

Generate a client-secret **plaintext + digest pair** in one command:

```bash
authcli crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986
```

It prints both a **Random Password** (plaintext) and a **Digest**. Store them:

| Value | Where |
|---|---|
| Random Password (plaintext) | `<hostname>.env` → `OPEN_WEBUI_OIDC_CLIENT_SECRET` (Open WebUI reads this). Safe as an env var — the `rfc3986` charset contains no `$`. |
| Digest (`$pbkdf2-sha512$…`) | The file `${CONFIG_DIR}/authelia/open-webui-client.digest` (inlined into `configuration.yml`). It is **not** an env var — its `$` delimiters would be mangled by `docker compose --env-file` interpolation. |

Write the digest to its file, e.g.:

```bash
printf '%s' '$pbkdf2-sha512$...the digest...' > ${CONFIG_DIR}/authelia/open-webui-client.digest
```

(A trailing newline is fine — `configuration.yml` trims it — but do not let your shell interpolate
the `$`; use single quotes as shown.)

### 5. Deploy

Add `authelia` to `HOMELAB_SERVICES` in `<hostname>.env` (and Open WebUI already carries its new OIDC
env). Then, on the Docker LXC:

```bash
./scripts/run-service.sh authelia              # bring up the new IdP container
./scripts/recreate-service.sh reverse-proxy    # apply the new auth.<domain> Caddy block
./scripts/run-service.sh ai                    # re-deploy Open WebUI with the OIDC env
```

`reverse-proxy` uses `recreate-service.sh`, not `run-service.sh`: the Caddyfile is a bind-mounted
config file, and Compose won't recreate the already-running Caddy container when only the mounted
file's *contents* change (Caddy runs without `--watch`; see the deploy notes in the root `README.md`).
`authelia` is a brand-new container so a plain `run-service.sh` applies its config, and Open WebUI's
own service definition changed (new env), so `ai` recreates normally. Once Caddy comes back with the
new block it auto-provisions the `auth.<domain>` cert on first request (wildcard DNS already resolves it).

### 6. Verify

- `https://<AUTHELIA_FQDN>` shows the Authelia login portal.
- On Open WebUI's login page, a **"Login with Authelia"** button appears beneath the local form.
- Every user is challenged for **TOTP** 2FA (the first login prompts enrollment) before Open WebUI
  issues a session.

### TOTP enrollment via the filesystem notifier

The notifier writes to a file instead of sending email. When a user first needs to enroll a TOTP
device, read the link/token from:

```bash
docker exec authelia cat /data/notification.txt
```

(Wire SMTP later if self-service family enrollment is wanted.)

## Reusable recipe: add a new OIDC app

To put another OIDC-capable service (Forgejo, Immich, Vikunja, Miniflux, …) behind Authelia:

1. **Pick a client secret.** Generate a plaintext+digest pair (step 4 above). Give the **plaintext**
   to the app (via an env var — the `rfc3986` charset has no `$`); write the **digest** to
   `${CONFIG_DIR}/authelia/<app>-client.digest` on the NAS (a file, so its `$` delimiters survive
   `docker compose --env-file`).
2. **Add a client** to `identity_providers.oidc.clients` in `configuration.yml`, modeled on
   `open-webui`: set `client_id`, `client_secret` to `'{{ secret "/secrets/<app>-client.digest" | trim }}'`,
   the app's `redirect_uris`, and `scopes`. If the redirect URI needs a personal domain, add a
   matching non-secret `<APP>_REDIRECT_URI` env var in `docker-compose.yml` (templated, un-prefixed)
   and reference it with `{{ env "<APP>_REDIRECT_URI" }}`.
3. **Choose an authorization policy.** Set the client's `authorization_policy` to a built-in
   `one_factor` or `two_factor` (open-webui uses `two_factor`, so 2FA is required for every user).
   For finer control — e.g. 2FA for only some users — define a named policy under
   `authorization_policies` keyed on a group and add that group to those users in `users.yml`.
4. **Configure the app** with Authelia's discovery URL
   `https://<AUTHELIA_FQDN>/.well-known/openid-configuration`, the client id, and the plaintext
   secret. (The container reaches `auth.<domain>` via NAT hairpin, so no `extra_hosts` is needed.)
5. **Add any new env vars** to `.env.template`. Then apply the change: because you edited the
   bind-mounted `configuration.yml` on the already-running Authelia, use `recreate-service.sh authelia`
   (a plain `run-service.sh` won't pick up a changed bind-mounted file); deploy the app itself with
   `run-service.sh <app>`.

## Reusable recipe: gate a browser-only UI with forward-auth

For a web UI that has no auth of its own:

1. In `configuration.yml` under `access_control.rules`, add a rule for the UI's domain with the
   desired `policy` (`one_factor` / `two_factor`). Put any non-interactive path (API/WebDAV) as a
   more specific `bypass` rule **above** it.
2. In the Caddyfile, wrap that site's `reverse_proxy` with a `forward_auth` to Authelia (see the
   Authelia + Caddy docs). Both `configuration.yml` and the Caddyfile are bind-mounted into
   already-running containers, so apply the changes with `recreate-service.sh authelia` and
   `recreate-service.sh reverse-proxy` (a plain `run-service.sh` won't pick up changed bind-mounted
   files).

## Enforcing SSO (hardening)

While proving out a surface, keep the app's own login as break-glass — that's how Open WebUI ships
here (the local form still shows alongside the "Login with Authelia" button). Once SSO is proven,
make Authelia the **only** front door, so its 2FA, brute-force protection, and access policies
can't be sidestepped by a local password. An enabled local login is a real bypass: the SSO boundary
is only as strong as the weakest login path the app still accepts.

**Disable the app's local login.** For an OIDC app, flip its "SSO-only" switch. Open WebUI:

- `ENABLE_LOGIN_FORM=false` — hides the username/password form.
- `OAUTH_AUTO_REDIRECT=true` — skips the chooser and redirects straight to Authelia.

Caveat: SSO must be working first, or you lock everyone out (prove it, then enforce). And unlike
Open WebUI's `oauth.*` vars — re-read from env every boot — `ENABLE_LOGIN_FORM` is a
PersistentConfig/UI setting: apply it at first launch or via Admin Settings, not by editing env on
an already-initialized instance.

**Keep break-glass deliberate.** Don't leave a permanent second password door; keep a *rare,
controlled* recovery path instead (re-enable the form + redeploy, or reset an admin via the app's
DB/CLI). Prefer to keep the break-glass at the Authelia layer rather than per app.

**Mind the LAN bypass (this network's model).** Services also publish their port on `0.0.0.0` and
are reachable directly on the LAN over plain HTTP, not only through Caddy — so "SSO-only" is
enforced differently depending on the mechanism:

- **OIDC apps** (e.g. Open WebUI): safe — the app itself demands OIDC, so even a direct LAN hit
  redirects to Authelia.
- **Forward-auth apps** (e.g. a future Dozzle/Scrutiny): only Caddy enforces auth, so hitting the
  app's published LAN port directly **bypasses Authelia**. Bind those ports to localhost
  (Caddy-only) or the forward-auth gate is just a speed bump on the LAN.

**Migrating existing local accounts (verify per app before enforcing).** OIDC apps generally link
an SSO login to an existing local account by **matching email**, so a user is "upgraded" in place —
no delete-and-recreate — and after enforcing SSO-only the same account persists, just without a
password path. Open WebUI does this via `OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true`. But this is
app-specific: before enforcing, confirm whether a given app (a) links by email in place, (b)
requires the local and SSO emails to match exactly, or (c) needs the account deleted and recreated —
and whether any residual password hash is left usable.
