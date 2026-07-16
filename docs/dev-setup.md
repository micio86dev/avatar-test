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

## References

- Version Catalog: `openspec/changes/project-skeleton-ci/design.md` — section D25
- Dependency Resolution Policy: design.md D37
- Toolchain contract: design.md D38
- Git Flow: `docs/git-flow.md`
