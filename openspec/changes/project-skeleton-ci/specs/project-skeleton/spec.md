# Project Skeleton Specification

## Purpose

Defines the wrapper-superproject + three-submodule topology, submodule wiring,
local development infrastructure, i18n scaffolding, the OpenAPI→TS client
contract, and the health-check contract for the BEAI foundation (C1). All
downstream slices (C2–C13) depend on these guarantees.

## Requirements

### Requirement: Wrapper Superproject & Submodule Topology

The repository MUST be a **wrapper superproject** holding `docs/`, `openspec/`,
`CLAUDE.md`, `docker-compose.yml`, wrapper task scripts, and git submodule
pointers. It MUST declare exactly three git submodules — `api` (Laravel 12,
API-only), `frontend` (Nuxt 4 SSR), and `backoffice` (Nuxt 4 SPA) — via a
`.gitmodules` file. The Astro demo MUST be relocated to `legacy-demo/` as a
plain folder (NOT a submodule), kept only as a reference. No application source
code from `api`, `frontend`, or `backoffice` may live at the wrapper root.

#### Scenario: Wrapper declares three submodules

- GIVEN a fresh clone of the wrapper repository on the `develop` branch
- WHEN the contributor reads `.gitmodules`
- THEN it declares exactly three submodules: `api`, `frontend`, and `backoffice`
- AND `legacy-demo/` is present as a plain folder with no entry in `.gitmodules`

#### Scenario: Recursive clone materializes all submodules

- GIVEN the wrapper repository
- WHEN the contributor runs `git clone --recursive` (or the wrapper init task)
- THEN the `api/`, `frontend/`, and `backoffice/` submodule working trees are populated at their pinned commits
- AND each is an independent git repository with its own history

#### Scenario: No app source leaks into the wrapper root

- GIVEN the wrapper repository
- WHEN the contributor lists the root directory
- THEN no Laravel or Nuxt application source exists at the root (only wrapper files, `legacy-demo/`, and the three submodule mount points)

#### Scenario: Legacy demo is isolated from the new apps

- GIVEN the `legacy-demo/` directory is present
- WHEN any of `api`, `frontend`, or `backoffice` is built or booted
- THEN none of them imports or references any file from `legacy-demo/`

---

### Requirement: Submodule Wiring & Pointer Sync

The wrapper MUST provide a task/script layer (e.g. `Taskfile.yml`) to initialize
and update submodules and to sync the pinned pointers. A stale or uninitialized
submodule pointer MUST be detectable. Each submodule MUST be independently
bootable and testable without the wrapper present.

#### Scenario: Wrapper task initializes submodules

- GIVEN a fresh wrapper clone without `--recursive`
- WHEN the contributor runs the wrapper submodule-init task
- THEN all three submodules are initialized and checked out at their pinned commits

#### Scenario: Stale pointer is detectable

- GIVEN a submodule whose remote `develop` has advanced past the wrapper's pinned commit
- WHEN the contributor runs the wrapper pointer-check task
- THEN the task reports the submodule pointer as out of date (non-zero / warning), not silently green

#### Scenario: Submodule is independently bootable

- GIVEN any one submodule checked out on its own (without the wrapper)
- WHEN its install + boot commands run
- THEN it boots and its tests run without requiring the wrapper or the sibling submodules

---

### Requirement: Local Development Infrastructure

The wrapper MUST provide a `docker-compose.yml` at the root that provisions
MySQL 8, Redis, and Mailpit with pinned image tags. All three apps MUST connect
to these services using values from their respective `.env` files. A
`.env.example` MUST exist in each submodule documenting every required variable.

#### Scenario: Infrastructure comes up cleanly from cold start

- GIVEN Docker is installed and no containers are running
- WHEN the contributor runs `docker compose up -d` in the wrapper
- THEN MySQL 8, Redis, and Mailpit containers reach healthy status
- AND all containers remain running (no crash-restart loop)

#### Scenario: API app connects to MySQL and Redis

- GIVEN `docker compose up -d` has completed and `api/.env` is populated from `api/.env.example`
- WHEN the Laravel application boots (`php artisan about`)
- THEN the DB connection resolves to MySQL 8 without error
- AND the Redis connection resolves without error

#### Scenario: Frontend app boots in SSR development mode

- GIVEN `docker compose up -d` has completed and `frontend/.env` is populated from `frontend/.env.example`
- WHEN the contributor runs `pnpm dev` inside `frontend/`
- THEN the Nuxt SSR dev server starts and the health page responds with HTTP 200

#### Scenario: Backoffice app boots in SPA development mode

- GIVEN `backoffice/.env` is populated from `backoffice/.env.example`
- WHEN the contributor runs `pnpm dev` inside `backoffice/`
- THEN the Nuxt app starts with `ssr: false` and the health page responds with HTTP 200

#### Scenario: Missing .env prevents silent misconfiguration

- GIVEN `api/.env` does not exist
- WHEN the Laravel application attempts to boot
- THEN it exits with a clear configuration-missing error rather than connecting to an unintended database

---

### Requirement: Health-Check Endpoints

The `api` app MUST expose a `GET /api/health` route returning HTTP 200 and a
JSON body confirming the app is alive. The `frontend` and `backoffice` apps MUST
each expose a `/health` page returning HTTP 200. All health endpoints MUST be
reachable without authentication.

#### Scenario: API health endpoint returns 200

- GIVEN the Laravel app is booted and connected to MySQL/Redis
- WHEN an unauthenticated HTTP GET request is made to `/api/health`
- THEN the response status is 200
- AND the response body is valid JSON containing at least `{ "status": "ok" }`

#### Scenario: Frontend health page returns 200

- GIVEN the frontend Nuxt SSR dev server is running
- WHEN an HTTP GET request is made to `/health`
- THEN the response status is 200

#### Scenario: Backoffice health page returns 200

- GIVEN the backoffice Nuxt SPA dev server is running
- WHEN an HTTP GET request is made to `/health`
- THEN the response status is 200

#### Scenario: Health endpoints do not require auth headers

- GIVEN no `Authorization` header or session cookie is present
- WHEN GET `/api/health` is called on the API
- THEN the response is 200, not 401 or 403

---

### Requirement: OpenAPI Publication & Typed Client Codegen

The `api` app MUST publish an OpenAPI document (`openapi.json`) via Scramble
(`dedoc/scramble`) that includes at least the health route. The `frontend` and
`backoffice` apps MUST each provide a codegen script that generates a typed
TypeScript client from that `openapi.json` (e.g. `openapi-typescript`), MUST
commit the generated client, and MUST NOT hand-maintain request/response types.

#### Scenario: API publishes an OpenAPI document

- GIVEN Scramble is installed and configured in `api`
- WHEN the OpenAPI document is generated (e.g. `php artisan scramble:export`)
- THEN a valid `openapi.json` is produced that documents at least the `GET /api/health` route

#### Scenario: Frontend generates a typed client from the OpenAPI spec

- GIVEN a valid `api` `openapi.json` is available to `frontend`
- WHEN the frontend codegen script runs
- THEN a typed TypeScript client is generated and committed
- AND a type for the `health` response is present in the generated output

#### Scenario: Backoffice generates a typed client from the OpenAPI spec

- GIVEN a valid `api` `openapi.json` is available to `backoffice`
- WHEN the backoffice codegen script runs
- THEN a typed TypeScript client is generated and committed
- AND a type for the `health` response is present in the generated output

#### Scenario: Types are not hand-maintained

- GIVEN the generated client files in `frontend` and `backoffice`
- WHEN they are inspected
- THEN they are produced by the codegen tool (regenerable), not authored by hand

---

### Requirement: i18n Scaffolding

The `api` app MUST include Laravel language files under `lang/it/` and
`lang/en/` each containing at least one translated key. The `frontend` and
`backoffice` apps MUST each configure `@nuxtjs/i18n` with `it` as the default
locale and `en` as a secondary locale, each locale backed by at least one
translated key. Complete translations are not required in C1 — scaffolding and
wiring are the goal.

#### Scenario: API resolves Italian translation key

- GIVEN `lang/it/<file>.php` contains at least one key-value pair
- WHEN `__('key')` or `trans('key')` is called with the `it` locale active
- THEN the Italian string is returned, not the key itself

#### Scenario: API resolves English translation key

- GIVEN `lang/en/<file>.php` contains the same key with an English value
- WHEN `__('key')` is called with the `en` locale active
- THEN the English string is returned

#### Scenario: Frontend resolves locale string for default locale (it)

- GIVEN `@nuxtjs/i18n` in `frontend` is configured with `defaultLocale: 'it'` and an `it` messages file contains at least one key
- WHEN the frontend app is accessed without an explicit locale prefix
- THEN `$t('key')` resolves to the Italian string

#### Scenario: Frontend resolves locale string for secondary locale (en)

- GIVEN the `en` locale is active in `frontend` (e.g. `/en/` prefix or locale switch)
- WHEN `$t('key')` is called for the same key
- THEN the English string is returned

#### Scenario: Backoffice resolves it and en locale strings

- GIVEN `@nuxtjs/i18n` in `backoffice` is configured with `defaultLocale: 'it'` and both `it` and `en` messages files each contain the key
- WHEN the app resolves `$t('key')` under each active locale
- THEN it returns the Italian string for `it` and the English string for `en`

---

### Requirement: TDD Smoke Test (Red→Green)

Each of the three submodules (`api`, `frontend`, `backoffice`) MUST include
exactly one smoke test that is intentionally written to fail first (RED), then
made to pass (GREEN) before C1 is merged. This proves each repo's test harness
is wired end-to-end and its CI can catch real regressions.

#### Scenario: API smoke test fails before implementation (RED)

- GIVEN Pest is installed and the smoke test asserts the health endpoint returns 200
- WHEN the route does not exist yet
- WHEN `php artisan test` is run
- THEN the smoke test fails with a meaningful assertion error

#### Scenario: API smoke test passes after health route is added (GREEN)

- GIVEN the `GET /api/health` route exists and returns 200
- WHEN `php artisan test` is run
- THEN the smoke test passes

#### Scenario: Frontend smoke test fails before implementation (RED)

- GIVEN Vitest is installed in `frontend` and the smoke test asserts the health page component renders an "ok" status text
- WHEN the component does not yet render that text
- WHEN `pnpm test:unit` is run
- THEN the smoke test fails

#### Scenario: Frontend smoke test passes after health component is implemented (GREEN)

- GIVEN the frontend health page component renders an "ok" status text
- WHEN `pnpm test:unit` is run
- THEN the smoke test passes

#### Scenario: Backoffice smoke test fails then passes (RED→GREEN)

- GIVEN Vitest is installed in `backoffice` and the smoke test asserts the health page renders an "ok" status text
- WHEN the component does not yet render that text and `pnpm test:unit` is run
- THEN the smoke test fails
- AND WHEN the health page is implemented and `pnpm test:unit` is re-run
- THEN the smoke test passes

---

### Requirement: Git Flow Branch Model Documentation (×4)

The wrapper MUST document the Git Flow branch model — `main`, `develop`,
`feature/*`, `release/*`, and `hotfix/*` — and MUST state that it applies to the
wrapper AND each of the three submodules (four independent Git Flow repos). The
documentation MUST cover submodule considerations: recursive clone, pointer
pinning, and merge ordering across repos. It MUST be accessible from the wrapper
root (e.g. `docs/git-flow.md`).

#### Scenario: Git Flow doc is discoverable from the wrapper root

- GIVEN the wrapper repository has been cloned
- WHEN the contributor looks for branch model documentation from the root
- THEN a file exists (e.g. `docs/git-flow.md`) describing all five branch types and their merge targets

#### Scenario: Documentation covers all four repos

- GIVEN the Git Flow doc exists
- WHEN a contributor reads it
- THEN it states the model applies to the wrapper and each submodule (`api`, `frontend`, `backoffice`)
- AND it describes recursive clone, submodule pointer pinning, and cross-repo merge ordering

#### Scenario: Documentation covers hotfix flow

- GIVEN the Git Flow doc exists
- WHEN a contributor reads the hotfix section
- THEN it states that hotfix branches are cut from `main` and merged back to both `main` and `develop` (in every repo)

---

### Requirement: SemVer Versioning Driven by Git Flow (×4)

The wrapper AND each submodule (`api`, `frontend`, `backoffice`) MUST each carry
an independent **SemVer `M.m.p`** version with a single per-repo source of truth:
`package.json` `version` for the Nuxt apps and the wrapper (or a `VERSION` file
for the wrapper), and a `VERSION` file (aligned with `composer.json`) for `api`.
The version MUST be bumped on a `release/*` branch; on release, `main` MUST be
tagged `vM.m.p` and merged back to `develop`. Each repo MUST be seeded at
`0.1.0`. The wrapper MUST pin each submodule to a released tag (not a floating
branch) for reproducible builds. The release flow MUST be documented alongside
the Git Flow docs.

#### Scenario: Each repo declares a SemVer source of truth seeded at 0.1.0

- GIVEN a fresh clone of any of the four repositories
- WHEN the contributor reads that repo's version source of truth (`package.json` `version`, or the `api`/wrapper `VERSION` file)
- THEN it contains a valid SemVer `M.m.p` value
- AND the initial seeded value is `0.1.0`

#### Scenario: Release branch bumps the version and tags main

- GIVEN a `release/*` branch is opened in any repo
- WHEN the release is finalized
- THEN the version source of truth is bumped to the new `M.m.p`
- AND `main` is tagged `vM.m.p` (with the leading `v`)
- AND the release branch is merged back into `develop` so it carries the bump

#### Scenario: Tag format is vM.m.p

- GIVEN a released repository
- WHEN its git tags are listed
- THEN each release tag matches the pattern `vM.m.p` (e.g. `v0.1.0`), major.minor.patch

#### Scenario: Wrapper pins submodules to released tags

- GIVEN the wrapper's `.gitmodules` and pinned submodule commits
- WHEN a contributor inspects each submodule pin
- THEN each pinned commit corresponds to a released `vM.m.p` tag of that submodule (not a floating branch head)

#### Scenario: Versioning is documented with the release flow

- GIVEN the repository documentation (e.g. `docs/git-flow.md` or a sibling)
- WHEN a contributor reads the versioning section
- THEN it describes SemVer `M.m.p`, the `release/*` bump, the `vM.m.p` tag on `main`, merge-back to `develop`, per-repo independence, and wrapper pinning of submodule release tags

---

### Requirement: Containerization & Local/Railway Parity

Each app (`api`, `frontend`, `backoffice`) MUST ship a **multi-stage,
production-grade Dockerfile**: a small final image, a **non-root** runtime user,
and a `HEALTHCHECK`. The wrapper `docker-compose.yml` MUST run the local dev
stack — MySQL 8 + Redis + Mailpit **plus the three app services** built from
those Dockerfiles. **Railway MUST build via Docker** using the same Dockerfiles
so the local image equals the production image (Railway config committed but
parked — no deploy in C1).

#### Scenario: Each app has a production-grade Dockerfile

- GIVEN each of `api`, `frontend`, and `backoffice`
- WHEN its Dockerfile is inspected
- THEN it is multi-stage, runs as a non-root user, and declares a `HEALTHCHECK`

#### Scenario: Compose runs infra plus the three app services

- GIVEN the wrapper `docker-compose.yml`
- WHEN `docker compose up` runs
- THEN MySQL 8, Redis, Mailpit, and the `api`, `frontend`, and `backoffice` services all start (the app services built from their Dockerfiles)

#### Scenario: Railway builds the same Docker image (parked)

- GIVEN each app's Railway config
- WHEN it is inspected
- THEN it selects the Docker builder pointing at that app's Dockerfile (same image as local)
- AND no CI or Railway step triggers an actual deploy in C1

---

### Requirement: Bun-Hybrid Toolchain (Bun build / Node SSR + test)

Both Nuxt apps MUST use **Bun** for dependency install, dev, and **build**, and
**Node** for the `frontend` **SSR production runtime** (Nitro `node-server`
preset) and for the Vitest/Playwright test runners. The `frontend` Dockerfile
MUST build on a Bun image and run the SSR output on a Node runtime stage; the
`backoffice` Dockerfile MUST build on a Bun image and serve the static output.

#### Scenario: Frontend Dockerfile builds with Bun and runs SSR on Node

- GIVEN the `frontend` multi-stage Dockerfile
- WHEN it is inspected
- THEN the build stage uses a Bun base image (e.g. `oven/bun`) to install and build
- AND the runtime stage uses a Node base image serving the Nitro `node-server` output

#### Scenario: Backoffice builds with Bun and serves static

- GIVEN the `backoffice` multi-stage Dockerfile
- WHEN it is inspected
- THEN the build stage uses a Bun base image and the runtime stage serves the static SPA build

#### Scenario: Tests run on Node even though deps install with Bun

- GIVEN a Nuxt app's tooling
- WHEN Vitest and Playwright are executed
- THEN they run on the Node runtime (their officially supported target)
- AND dependency install and the Nuxt build are performed with Bun
