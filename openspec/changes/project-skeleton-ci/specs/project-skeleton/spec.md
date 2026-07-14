# Project Skeleton Specification

## Purpose

Defines the monorepo layout, local development infrastructure, i18n scaffolding,
and health-check contract for the BEAI foundation (C1). All downstream slices
(C2–C13) depend on these guarantees.

## Requirements

### Requirement: Monorepo Layout

The repository MUST contain three top-level workspace directories: `api/`
(Laravel 12), `web/` (Nuxt 4), and `legacy-demo/` (relocated Astro reference).
Each workspace MUST be independently bootable without the others present.

#### Scenario: Repository structure is verifiable after clone

- GIVEN a fresh clone of the repository on the `develop` branch
- WHEN the contributor lists the root directory
- THEN `api/`, `web/`, and `legacy-demo/` are all present
- AND no application source code from `api/` or `web/` exists at the repo root

#### Scenario: Legacy demo is isolated from new apps

- GIVEN the `legacy-demo/` directory is present
- WHEN either `api/` or `web/` is built or booted
- THEN neither app imports or references any file from `legacy-demo/`

---

### Requirement: Local Development Infrastructure

The repository MUST provide a `docker-compose.yml` at the root that provisions
MySQL 8 and Redis with pinned image tags. Both apps MUST connect to these
services using values from their respective `.env` files. A `.env.example` MUST
exist for each app documenting every required variable.

#### Scenario: Infrastructure comes up cleanly from cold start

- GIVEN Docker is installed and no containers are running
- WHEN the contributor runs `docker compose up -d`
- THEN MySQL 8 and Redis containers reach healthy status
- AND both containers remain running (no crash-restart loop)

#### Scenario: API app connects to MySQL and Redis

- GIVEN `docker compose up -d` has completed and `api/.env` is populated from `api/.env.example`
- WHEN the Laravel application boots (`php artisan about`)
- THEN the DB connection resolves to MySQL 8 without error
- AND the Redis connection resolves without error

#### Scenario: Web app boots in development mode

- GIVEN `docker compose up -d` has completed and `web/.env` is populated from `web/.env.example`
- WHEN the contributor runs `pnpm dev` inside `web/`
- THEN the Nuxt dev server starts and the health page responds with HTTP 200

#### Scenario: Missing .env prevents silent misconfiguration

- GIVEN `api/.env` does not exist
- WHEN the Laravel application attempts to boot
- THEN it exits with a clear configuration-missing error rather than connecting to an unintended database

---

### Requirement: Health-Check Endpoints

The `api/` app MUST expose a `GET /api/health` route returning HTTP 200 and a
JSON body confirming the app is alive. The `web/` app MUST expose a `/health`
page returning HTTP 200. Both endpoints MUST be reachable without authentication.

#### Scenario: API health endpoint returns 200

- GIVEN the Laravel app is booted and connected to MySQL/Redis
- WHEN an unauthenticated HTTP GET request is made to `/api/health`
- THEN the response status is 200
- AND the response body is valid JSON containing at least `{ "status": "ok" }`

#### Scenario: Web health page returns 200

- GIVEN the Nuxt dev server is running
- WHEN an HTTP GET request is made to `/health`
- THEN the response status is 200

#### Scenario: Health endpoints do not require auth headers

- GIVEN no `Authorization` header or session cookie is present
- WHEN GET `/api/health` is called on the API
- THEN the response is 200, not 401 or 403

---

### Requirement: i18n Scaffolding

The `api/` app MUST include Laravel language files under `lang/it/` and
`lang/en/` each containing at least one translated key. The `web/` app MUST
configure `@nuxtjs/i18n` with `it` as the default locale and `en` as a
secondary locale, each locale backed by at least one translated key. Neither
side requires complete translations in C1 — scaffolding and wiring are the goal.

#### Scenario: API resolves Italian translation key

- GIVEN `lang/it/<file>.php` contains at least one key-value pair
- WHEN `__('key')` or `trans('key')` is called with the `it` locale active
- THEN the Italian string is returned, not the key itself

#### Scenario: API resolves English translation key

- GIVEN `lang/en/<file>.php` contains the same key with an English value
- WHEN `__('key')` is called with the `en` locale active
- THEN the English string is returned

#### Scenario: Web resolves locale string for default locale (it)

- GIVEN `@nuxtjs/i18n` is configured with `defaultLocale: 'it'` and an `it` messages file contains at least one key
- WHEN the Nuxt app is accessed without an explicit locale prefix
- THEN `$t('key')` resolves to the Italian string

#### Scenario: Web resolves locale string for secondary locale (en)

- GIVEN the `en` locale is active (e.g. `/en/` prefix or locale switch)
- WHEN `$t('key')` is called for the same key
- THEN the English string is returned

---

### Requirement: TDD Smoke Test (Red→Green)

Each app MUST include exactly one smoke test that is intentionally written to
fail first (RED), then made to pass (GREEN) before C1 is merged. This proves the
test harness is wired end-to-end and CI can catch real regressions.

#### Scenario: API smoke test fails before implementation (RED)

- GIVEN Pest is installed and the smoke test asserts the health endpoint returns 200
- WHEN the route does not exist yet
- WHEN `php artisan test` is run
- THEN the smoke test fails with a meaningful assertion error

#### Scenario: API smoke test passes after health route is added (GREEN)

- GIVEN the `GET /api/health` route exists and returns 200
- WHEN `php artisan test` is run
- THEN the smoke test passes

#### Scenario: Web smoke test fails before implementation (RED)

- GIVEN Vitest is installed and the smoke test asserts the health page component renders an "ok" status text
- WHEN the component does not yet render that text
- WHEN `pnpm test:unit` is run
- THEN the smoke test fails

#### Scenario: Web smoke test passes after health component is implemented (GREEN)

- GIVEN the health page component renders an "ok" status text
- WHEN `pnpm test:unit` is run
- THEN the smoke test passes

---

### Requirement: Git Flow Branch Model Documentation

The repository MUST include documentation of the Git Flow branch model covering:
`main`, `develop`, `feature/*`, `release/*`, and `hotfix/*` branches, their
purposes, and merge targets. This documentation MUST be accessible from the repo
root (e.g. `docs/git-flow.md` or equivalent).

#### Scenario: Git Flow doc is discoverable from repo root

- GIVEN the repository has been cloned
- WHEN the contributor looks for branch model documentation from the root
- THEN a file exists (e.g. `docs/git-flow.md`) describing all five branch types and their merge targets

#### Scenario: Documentation covers hotfix flow

- GIVEN the Git Flow doc exists
- WHEN a contributor reads the hotfix section
- THEN it states that hotfix branches are cut from `main` and merged back to both `main` and `develop`
