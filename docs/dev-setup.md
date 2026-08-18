# BEAI — Local Development Setup

This document describes the **required local toolchain** for BEAI development (design D38).
All versions are pinned per the Version Catalog (design.md D25) and must match exactly.

> **Dependency Resolution Policy (D37 — mandatory):** if any pinned dependency or tool
> cannot be installed or resolved, **STOP and report** — never downgrade a package, never
> replace it with an alternative library, never remove or loosen a version constraint,
> never substitute an unspecified tool. A blocked dependency is a human decision, not an
> implementation choice.

---

## Required Toolchain

| Tool | Required version | Notes |
|------|-----------------|-------|
| PHP | **8.5.x** (8.5.8 target) | Must include `pdo_pgsql` and PCOV extensions |
| Composer | **2.4+** | Includes `composer audit` built-in |
| Bun | **1.3.x** | Sole package manager for both Nuxt apps |
| Node | **24 LTS** | SSR runtime + Vitest + Playwright runners |
| Docker | **≥ 29.x** | Docker Engine |
| Docker Compose | **v2** (`docker compose`, no hyphen) | Minimum v2.24 |
| go-task | **3.x** | Task runner (`brew install go-task`) |
| git | any recent | Must support `--recursive` submodule clone |
| Playwright browsers | **Chromium + WebKit** | Install with `--with-deps` flag |
| k6 | any recent | Local load tests only; never CI on PRs |

---

## Installation Guide

### macOS (Homebrew)

```bash
# PHP 8.5 via shivammathur/homebrew-php tap
brew tap shivammathur/php
brew install shivammathur/php/php@8.5
brew link php@8.5 --force --overwrite

# Verify
php -v   # PHP 8.5.x

# Composer
brew install composer
composer --version  # 2.x.x

# Node 24 LTS
brew install node@24
brew link node@24 --force --overwrite
node -v  # v24.x.x

# Bun 1.3
curl -fsSL https://bun.sh/install | bash
# Or: brew install bun
bun -v  # 1.3.x

# Docker Desktop (includes Compose v2)
# Download from https://www.docker.com/products/docker-desktop/
docker compose version  # Docker Compose version v2.x.x

# go-task
brew install go-task
task --version  # Task version: 3.x.x

# k6 (local load tests only)
brew install k6
k6 version
```

### PCOV Installation (PHP coverage driver — Homebrew gotcha)

PCOV is faster than Xdebug for coverage collection and is the required driver for
the `api` CI coverage gate (design D8). On macOS with Homebrew PHP, PCOV requires
`pcre2` headers and a manual `phpize` build because the Homebrew PHP formula does
not bundle PCOV out of the box.

```bash
# 1. Ensure pcre2 is installed (dependency for PCOV build)
brew install pcre2

# 2. Install PCOV via PECL (uses phpize under the hood)
pecl install pcov

# 3. Verify the extension loaded
php -m | grep pcov      # should print: pcov
php --ri pcov           # shows PCOV version and config

# 4. In php.ini (or a conf.d drop-in), ensure:
#    extension=pcov.so
#    [pcov]
#    pcov.enabled = 1
#    pcov.directory = /path/to/project/app
#
# Find your php.ini: php --ini | grep "Loaded Configuration"
```

> If `pecl install pcov` fails with "pcre2.h not found": run
> `export PKG_CONFIG_PATH="$(brew --prefix pcre2)/lib/pkgconfig"` before `pecl install pcov`.

### pdo_pgsql Extension

The `api` requires the PostgreSQL PDO driver. On Homebrew PHP 8.5 it may need
to be enabled explicitly:

```bash
# Check if already loaded
php -m | grep pdo_pgsql

# If not loaded, install the extension via PECL or your PHP formula
# For shivammathur/php formula the extension is typically bundled — just enable it:
# Find conf.d: php --ini
# Add file: /opt/homebrew/etc/php/8.5/conf.d/ext-pdo_pgsql.ini
# Content: extension=pdo_pgsql.so
```

### Playwright Browsers

Install Chromium and WebKit with their system dependencies:

```bash
# After installing Node 24 and project deps with Bun:
cd frontend   # or backoffice
bun install
bunx playwright install --with-deps chromium webkit

# The --with-deps flag installs OS-level libraries (FFmpeg, WebKit system libs, etc.)
# Required on CI too (see each app's .github/workflows/ci.yml).
```

---

## Getting Started

Two paths. Pick one:

- **[Containers](#option-a--containers-recommended)** — one command, no host toolchain. This is the
  default and the one to use unless you have a reason not to.
- **[Host toolchain](#option-b--host-toolchain)** — apps run on your machine against
  containerised infra. Needed for step-debugging, IDE integration, or running the
  test suites, which execute on the host (see [Running Tests](#running-tests)).

### Option A — containers (recommended)

```bash
# 1. Clone the wrapper with all submodules
git clone --recursive https://github.com/your-org/beai.git
cd beai

# 2. Start everything
./scripts/dev.sh
```

That single command is idempotent and safe to re-run. It performs the Docker
preflight, creates any missing `.env` from its `.env.example`, initialises
submodules, generates `APP_KEY` and `JWT_SECRET` **on the host** (never baked
into an image — see the comments in the script), starts the full stack, waits
for every healthcheck, applies migrations, and prints the service URLs.

Requires only Docker + Docker Compose v2 — no local PHP, Node or Bun.

| Flag | Effect |
|---|---|
| *(none)* | start everything |
| `--build` | force a rebuild of the app images |
| `--seed` | run database seeders after migrating |
| `--fresh` | **destructive** — wipe volumes and rebuild from zero (asks for confirmation) |
| `--no-worker` | scale `worker` and `scheduler` to zero |
| `--status` | show service health and exit |
| `--logs` | follow logs of all services |
| `--down` | stop containers, preserving volumes |

**Use `--seed` on the first boot**, because that is what gives you a populated
tenant to click through:

```bash
./scripts/dev.sh --seed
```

Plain `./scripts/dev.sh` migrates but seeds nothing, and `DatabaseSeeder` itself
seeds only the `dev-org` organization and the framework catalog — no
participants, no projects, no evaluations. `--seed` also runs
`beai:demo-seed --org=dev-org --create-org`, which brings a rich, BARS-valid
demo dataset into that organization:

```
Demo dataset provisioned.
  | FrameworkVersion | beai-demo-1.0.0 (locked=false)                            |
  | Avatar templates | 2 (1 active)                                              |
  | Projects         | 4                                                        |
  | Participants     | 9 across every lifecycle status                          |
  | Evaluations      | 5 with computed competency results and indicator scores  |
  | Snapshots        | 34 objects written to the configured disk                |
```

No account is created by `--seed`, in any environment — `beai:demo-seed`
**never creates a user**. Log in with an account you already have (or mint one
with `beai:provision-organization`, below); `--create-org` only creates the
`dev-org` organization itself if it is somehow missing, and is refused when
`APP_ENV=production`.

The whole step is idempotent: a second `--seed` writes nothing new. If the
dataset is ever left partially seeded (e.g. a row deleted by hand), a re-run
**refuses** rather than guessing — run `beai:demo-seed`'s teardown counterpart
first:

```bash
docker compose exec api php artisan beai:demo-teardown --org=dev-org
```

`beai:demo-seed` is **not** part of `DatabaseSeeder` and never runs
automatically: `db:seed` executes with `--force` in CI and inside the
production image, and a demo dataset has no business appearing there
unannounced. Every demo row carries the `beai-demo-` prefix (on
`projects.slug`, `participants.candidate_ref`, `framework_versions.version`,
`avatar_templates.name`) so it is never mistaken for real client data and is
always selectable for teardown.

For a **real** tenant — an actual organization with a generated, non-published
password and its own admin account — use the provisioning command instead:

```bash
docker compose exec api php artisan beai:provision-organization \
  --name="Another Tenant" \
  --admin-email=admin@another.test
# Prints a generated password once — store it.
# Use --admin-password=… to choose your own (it is then NOT echoed).
```

> **The api image bakes its source; there is no bind mount.** Any change under
> `api/` — including seeders — reaches the container only after
> `docker compose build api`, or `./scripts/dev.sh --build`. A seeder edit that
> appears to have no effect has almost always simply not been rebuilt.

Services, once up:

| Service | URL |
|---|---|
| Candidate app (frontend) | http://localhost:3000 |
| Backoffice | http://localhost:3001 |
| API health | http://localhost:8000/api/health |
| Mailpit | http://localhost:8025 |
| Postgres · Redis | `localhost:5432` · `localhost:6379` |

Ports are overridable in the wrapper `.env` (`FRONTEND_PORT`, `BACKOFFICE_PORT`,
`API_PORT`, `MAILPIT_UI_PORT`, `POSTGRES_PORT`, `REDIS_PORT`).

### Option B — host toolchain

Requires the full toolchain from [Required Toolchain](#required-toolchain) above.
Infra stays in Docker; the three apps run on your machine.

```bash
# 1. Clone the wrapper with all submodules
git clone --recursive https://github.com/your-org/beai.git
cd beai

# 2. Start local infra (postgres + redis + mailpit)
task up

# 3. Verify infra is healthy
docker compose ps

# 4. Bootstrap the api (in ./api directory)
cd api
cp .env.example .env
# Fill in secrets (POSTGRES_PASSWORD, etc.)
composer install
php artisan migrate

# 4b. Create an organization and an admin to log in with.
#     A migrated database has no organization, so it has no admin, so there is
#     no account the backoffice can authenticate. Every input is an option, so
#     this also works in a container with no TTY.
php artisan beai:provision-organization \
  --name="Local Dev" \
  --admin-email=admin@local.test
# Prints a generated password once — store it.
# Use --admin-password=… to choose your own (it is then NOT echoed).

# 5. Bootstrap the frontend (in ./frontend directory)
cd ../frontend
cp .env.example .env
bun install
bun run dev

# 6. Bootstrap the backoffice (in ./backoffice directory)
cd ../backoffice
cp .env.example .env
bun install
bun run dev
```

---

## Running Tests

```bash
# From the wrapper root — delegates to each app:
task test:api         # Pest suite (requires infra up)
task test:frontend    # Vitest + Playwright (frontend)
task test:backoffice  # Vitest + Playwright (backoffice)

# Load tests (local only, never Railway):
task up               # ensure infra is up first
task test:load
```

---

## Docker Image Builds (local verification)

```bash
# Build each app image locally (no push):
docker build -t beai-api      ./api
docker build -t beai-frontend ./frontend
docker build -t beai-backoffice ./backoffice
```

---

## Mail

Two different transports, on purpose. They are not alternatives to choose
between — they belong to different environments.

### Local — Mailpit, nothing to configure

`docker-compose.yml` pins `MAIL_MAILER: smtp` on the shared `x-api-environment`
anchor, alongside `MAIL_HOST: mailpit` and `MAIL_PORT: 1025`. It reaches `api`,
`worker` **and** `scheduler` together, which matters: the process that actually
sends operator alerts is the worker, and a worker left on the `log` driver
writes every alert into a container filesystem nobody reads.

Read the caught mail at **http://localhost:8025**. Nothing ever leaves your
machine.

Verify the wiring after a change:

```bash
docker compose exec api php artisan tinker --execute="Mail::raw('probe', fn(\$m) => \$m->to('you@example.test')->subject('probe'));"
curl -s http://localhost:8025/api/v1/messages | head
```

### Production — Resend

Ratified 2026-07-30. Laravel 13.20 ships the transport first-party; the
`resend/resend-php` package (D25) is what it type-hints.

| Variable | Value | Notes |
|---|---|---|
| `MAIL_MAILER` | `resend` | Set per environment. **Never** in the compose stack — that is local. |
| `RESEND_API_KEY` | *(secret)* | A credential: Railway's variable store, never committed. `.env.example` may carry the NAME only. |
| `MAIL_FROM_ADDRESS` | a verified sender | Must be on a domain verified in the Resend dashboard. |

**The failure mode to know about.** An unverified sender domain, or a missing
key, does not fail at boot. It throws inside the queued notification job, so it
surfaces as a `failed` row in `notification_logs` — visible on the operator
dashboard, but only if someone looks. The default `MAIL_FROM_ADDRESS` is
`hello@beai.test` in `api/.env.example`, and `hello@example.com` is Laravel's own
fallback in `config/mail.php`. Neither is a real domain, so Resend rejects both —
changing it is not optional.

Tests never touch either transport: `api/phpunit.xml` pins `MAIL_MAILER=array`,
and a test asserts that pin still holds.

---

## References

- Version Catalog: `docs/version-catalog.md`
- Dependency Resolution Policy: design.md D37
- Toolchain contract: design.md D38
- Git Flow: `docs/git-flow.md`
