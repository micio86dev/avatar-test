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
pointers. It MUST declare exactly three git submodules — `api` (Laravel 13,
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
**PostgreSQL 17** (via `pgvector/pgvector:pg17-alpine` — PostgreSQL 17 + pgVector
pre-installed), **Redis 8** (`redis:8.0-alpine`), and Mailpit (`axllent/mailpit:v1.22`)
with **pinned image tags** (no `latest`, no bare majors — see Version Catalog in
design.md D25). All three apps MUST connect to these services using values from
their respective `.env` files. A `.env.example` MUST exist in each submodule
documenting every required variable. The PostgreSQL major version MUST match
the Supabase project version used for staging and production.

#### Scenario: Infrastructure comes up cleanly from cold start

- GIVEN Docker is installed and no containers are running
- WHEN the contributor runs `docker compose up -d` in the wrapper
- THEN PostgreSQL 17, Redis 8, and Mailpit containers reach healthy status
- AND all containers remain running (no crash-restart loop)

#### Scenario: API app connects to PostgreSQL and Redis

- GIVEN `docker compose up -d` has completed and `api/.env` is populated from `api/.env.example`
- WHEN the Laravel application boots (`php artisan about`)
- THEN the DB connection resolves to PostgreSQL without error
- AND the Redis connection resolves without error

#### Scenario: Frontend app boots in SSR development mode

- GIVEN `docker compose up -d` has completed and `frontend/.env` is populated from `frontend/.env.example`
- WHEN the contributor runs `bun run dev` inside `frontend/`
- THEN the Nuxt SSR dev server starts and the health page responds with HTTP 200

#### Scenario: Backoffice app boots in SPA development mode

- GIVEN `backoffice/.env` is populated from `backoffice/.env.example`
- WHEN the contributor runs `bun run dev` inside `backoffice/`
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
reachable without authentication. The `api` health JSON body is a
**machine-readable status payload and MUST NOT be localized** — the literal
`{ "status": "ok" }` is returned regardless of the active locale (see the i18n
Mandate requirement's machine-readable exemption).

#### Scenario: API health endpoint returns 200

- GIVEN the Laravel app is booted and connected to PostgreSQL/Redis
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
- WHEN `bun run test:unit` is run
- THEN the smoke test fails

#### Scenario: Frontend smoke test passes after health component is implemented (GREEN)

- GIVEN the frontend health page component renders an "ok" status text
- WHEN `bun run test:unit` is run
- THEN the smoke test passes

#### Scenario: Backoffice smoke test fails then passes (RED→GREEN)

- GIVEN Vitest is installed in `backoffice` and the smoke test asserts the health page renders an "ok" status text
- WHEN the component does not yet render that text and `bun run test:unit` is run
- THEN the smoke test fails
- AND WHEN the health page is implemented and `bun run test:unit` is re-run
- THEN the smoke test passes

---

### Requirement: Test Database — Dedicated PostgreSQL & Migration Standards

The `api` test suite MUST run against a dedicated PostgreSQL database (`beai_test`),
using the same `pgvector/pgvector:pg17-alpine` image as local development. Using
a different engine for tests than for production masks constraint enforcement
differences, JSON operator semantics, full-text search behaviour, and
PostgreSQL-specific type handling (including pgVector column types). The
`beai_test` database MUST be provisioned automatically in both local dev
(docker-compose PostgreSQL init script) and CI (PostgreSQL `services` block).
Laravel MUST override `DB_CONNECTION` and `DB_DATABASE` for the test environment
via a committed `.env.testing` file and a `<php>` block in `phpunit.xml`. The
`RefreshDatabase` trait MUST be used in all Pest feature tests.

Migration standards are established here and MUST be followed from C2 onward
for every migration across all slices:

- **Atomic and single-concern**: one migration per logical change; unrelated
  changes MUST NOT be bundled in a single file.
- **Reversible**: `down()` MUST correctly and completely undo `up()`.
- **Immutable once deployed**: never edit a shipped migration; always add a new one.
- **Normalized by default (3NF)**: denormalization is only allowed when a
  concrete, measurable performance requirement justifies it; the justification
  MUST be documented in a comment inside the migration file.
- **No redundant columns** unless the redundancy explicitly serves a
  query-performance need (e.g. a cached aggregation column) and is documented.
- **FK columns indexed**: every foreign-key column MUST have an index.
- **Composite indexes lead with `organization_id`**: the multi-tenant
  discriminator is the most selective filter in every query; composite indexes
  MUST place `organization_id` first.
- **Right-sized column types**: use the narrowest type that correctly models the
  domain (e.g. `smallint` for bounded status codes, `text` for unbounded strings).
- **pgVector migrations**: any migration introducing a vector column MUST ensure
  the `vector` extension is created first (`CREATE EXTENSION IF NOT EXISTS vector`).

#### Scenario: Pest feature tests connect to PostgreSQL beai_test, not SQLite

- GIVEN `.env.testing` sets `DB_CONNECTION=pgsql` and `DB_DATABASE=beai_test`
- AND `phpunit.xml` overrides `DB_CONNECTION=pgsql` and `DB_DATABASE=beai_test` in `<php>`
- WHEN `php artisan test` runs in the test environment
- THEN all feature tests connect to the PostgreSQL `beai_test` database
- AND no test uses the SQLite driver or `:memory:` connection

#### Scenario: Test database is clean between test runs

- GIVEN Pest feature tests use the `RefreshDatabase` trait
- WHEN one test inserts rows into `beai_test`
- THEN the next test starts from a clean state (transaction rollback or re-migration)

#### Scenario: beai_test database is provisioned in docker-compose on first start

- GIVEN the wrapper `docker-compose.yml` PostgreSQL service includes an init script at `/docker-entrypoint-initdb.d/`
- WHEN `docker compose up -d` runs for the first time
- THEN both `beai` (development) and `beai_test` (test) databases are created and accessible with the configured credentials

#### Scenario: No SQLite reference exists in the api test configuration

- GIVEN `phpunit.xml`, `.env.testing`, and all Pest test files in `api`
- WHEN they are inspected
- THEN no SQLite driver (`DB_CONNECTION=sqlite`, `:memory:`) is configured or referenced anywhere

---

### Requirement: Code Quality Tooling — Pre-commit Hooks & Code Formatting

Each submodule MUST enforce code formatting and linting automatically at commit
time via pre-commit git hooks, so style violations are caught locally before
reaching CI.

**`frontend` and `backoffice` (Nuxt apps):** Prettier MUST be installed and
configured with a committed `.prettierrc` at the repo root, covering `.vue`,
`.ts`, `.js`, `.json`, `.css`, and `.md` files. Husky MUST install git hooks
via the `prepare` script (triggered automatically by `bun install`). `lint-staged`
MUST configure the pre-commit hook to run `eslint --fix` followed by
`prettier --write` on all staged files matching the covered extensions. If
auto-fix leaves unresolvable lint errors the commit MUST be aborted. CI MUST
also run a Prettier format-check step (`prettier --check .`) as a required,
non-`continue-on-error` step so format drift is caught in review even when the
local hook is bypassed.

**`api` (Laravel):** A pre-commit hook MUST run PHP Pint on staged PHP files
(`pint --dirty`) before each commit. The hook runner MUST be wired so that
`composer install` sets up the hook automatically — no manual step for a new
contributor. A commit that fails Pint MUST be aborted.

#### Scenario: Staged PHP file with a Pint violation is rejected

- GIVEN a staged `*.php` file that violates the Pint (PSR-12 / Laravel) style rules
- WHEN the contributor runs `git commit`
- THEN the pre-commit hook runs `./vendor/bin/pint --dirty` on the staged file
- AND the commit is aborted with a Pint formatting error

#### Scenario: Staged PHP file passes Pint and commits cleanly

- GIVEN a staged `*.php` file that already complies with Pint rules
- WHEN the contributor runs `git commit`
- THEN the pre-commit hook completes without error and the commit proceeds

#### Scenario: Staged Vue/TS file is auto-fixed and re-staged before commit

- GIVEN a staged `.vue` or `.ts` file with a lint-fixable ESLint issue or a Prettier diff
- WHEN the contributor runs `git commit`
- THEN `lint-staged` runs `eslint --fix` + `prettier --write` on the staged file
- AND the corrected file is re-staged automatically
- AND the commit proceeds if no non-auto-fixable errors remain

#### Scenario: Staged file with a non-auto-fixable ESLint error blocks the commit

- GIVEN a staged file with a lint error that `eslint --fix` cannot resolve automatically
- WHEN the contributor runs `git commit`
- THEN lint-staged aborts the commit after the fix pass
- AND the contributor must manually fix the error before committing

#### Scenario: Prettier config is committed to each Nuxt repo

- GIVEN a freshly cloned `frontend` or `backoffice` repo
- WHEN the contributor inspects the repository root
- THEN a `.prettierrc` is present with project-wide formatting rules
- AND running `prettier --check .` on committed source files exits 0

#### Scenario: Pre-commit hooks install automatically on bun install (Nuxt repos)

- GIVEN a freshly cloned `frontend` or `backoffice` repo
- WHEN the contributor runs `bun install`
- THEN Husky installs the pre-commit hook into `.git/hooks/` via the `prepare` script
- AND no additional manual step is required

#### Scenario: Pre-commit hook installs automatically on composer install (api)

- GIVEN a freshly cloned `api` repo
- WHEN the contributor runs `composer install`
- THEN the pre-commit hook is wired into `.git/hooks/` automatically via Composer post-install scripts
- AND no additional manual step is required

#### Scenario: CI format-check catches Prettier drift even when hook was bypassed

- GIVEN a committed `.vue` or `.ts` file that does not comply with the project Prettier config
- WHEN CI runs the format-check step
- THEN the `prettier --check .` step fails and the CI job is aborted

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
stack — **PostgreSQL 17** (`pgvector/pgvector:pg17-alpine`) + **Redis 8** (`redis:8.0-alpine`) + Mailpit (`axllent/mailpit:v1.22`)
**plus the three app services** built from those Dockerfiles; all base image
tags MUST be pinned (no `latest`) — see Version Catalog in design.md D25. **Railway MUST build via Docker** using the same Dockerfiles
so the local image equals the production image (Railway config committed but
parked — no deploy in C1).

#### Scenario: Each app has a production-grade Dockerfile

- GIVEN each of `api`, `frontend`, and `backoffice`
- WHEN its Dockerfile is inspected
- THEN it is multi-stage, runs as a non-root user, and declares a `HEALTHCHECK`

#### Scenario: Compose runs infra plus the three app services

- GIVEN the wrapper `docker-compose.yml`
- WHEN `docker compose up` runs
- THEN PostgreSQL 17, Redis 8, Mailpit, and the `api`, `frontend`, and `backoffice` services all start (the app services built from their Dockerfiles)

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

---

### Requirement: TypeScript Strict Mode (Both Nuxt Apps)

Both `frontend` and `backoffice` MUST enable `strict: true` in their
`tsconfig.json`. Additional required flags: `noUnusedLocals: true`,
`noUnusedParameters: true`, `exactOptionalPropertyTypes: true`. The `any` type
is banned; use typed generics, discriminated unions, or Zod-inferred types.
`unknown` is acceptable only with an explicit type-narrowing guard. Nuxt-generated
files (`.nuxt/`) MUST be excluded from strict checks. Running `tsc --noEmit` (or
`nuxi typecheck`) MUST report zero errors on the scaffolded C1 codebase.

#### Scenario: TypeScript typecheck passes with no errors

- GIVEN both Nuxt apps are scaffolded with C1 code
- WHEN `bunx nuxi typecheck` (or `tsc --noEmit`) is run in each Nuxt repo
- THEN it exits 0 with no TypeScript errors

#### Scenario: `any` type is rejected in authored source

- GIVEN a `.vue` or `.ts` file in `frontend` or `backoffice` that explicitly uses `any`
- WHEN `tsc --noEmit` runs
- THEN it reports a type error (because `noImplicitAny: true` is in effect)

---

### Requirement: CSS Framework — Tailwind CSS v4

Both `frontend` and `backoffice` MUST have Tailwind CSS v4 (`tailwindcss ^4.0`)
installed and wired via the `@tailwindcss/vite` plugin. The main CSS entry point
MUST use `@import "tailwindcss"`. Custom design tokens MUST be defined via CSS
`@theme {}` blocks, sourced from `DESIGN.md` at the wrapper root. Utility classes
MUST resolve in `.vue` SFCs. The `@tailwindcss/forms` and `@tailwindcss/typography`
plugins MUST be installed. Tailwind configuration MUST target the supported
browsers per NFR: Chrome 120+, Edge 120+, Safari 17+ (no Firefox, no mobile).

#### Scenario: Tailwind utility classes resolve in a Vue SFC

- GIVEN a `.vue` component using a Tailwind class (e.g. `class="bg-blue-500"`)
- WHEN the Nuxt dev server builds the component
- THEN the class is present in the generated CSS output

#### Scenario: Design tokens from DESIGN.md are wired as CSS custom properties

- GIVEN the `@theme {}` block in `assets/css/main.css`
- WHEN the CSS is inspected
- THEN the custom properties defined in `DESIGN.md` (colors, typography, spacing) are declared on `:root`

---

### Requirement: PHP Static Analysis (PHPStan Level 8)

The `api` submodule MUST have PHPStan `^2.0` and Larastan `^3.0` installed as
dev dependencies. A `phpstan.neon` MUST be committed at the `api/` root with
`level: 8` and the Larastan preset included. Running `./vendor/bin/phpstan analyse`
MUST exit 0 on the C1 `app/` directory (with a permitted baseline for unavoidable
scaffold noise, cleared progressively). PHPStan MUST run as a required blocking
CI step in the `api` workflow.

#### Scenario: PHPStan analysis passes at level 8

- GIVEN the C1 `api/` Laravel scaffold with a committed `phpstan.neon`
- WHEN `./vendor/bin/phpstan analyse` is run
- THEN it exits 0 (or exits 0 with a committed baseline covering only unavoidable stubs)

#### Scenario: PHPStan catches a type error in authored code

- GIVEN a PHP method that returns a `string` but the implementation returns `null`
- WHEN PHPStan analyses the file
- THEN it reports a type mismatch at level 8

---

### Requirement: Accessibility — WCAG 2.1 Level AA

All pages in both `frontend` and `backoffice` MUST satisfy WCAG 2.1 Level AA.
Minimum requirements: semantic HTML5 landmark elements, full keyboard operability,
color contrast ≥ 4.5:1 for normal text / ≥ 3:1 for large text and UI components,
`alt` attribute on all images, `aria-label` or `aria-describedby` on interactive
elements without visible text labels, visible focus indicators, `lang` attribute
on the `<html>` element, and `aria-live` regions for dynamic content updates.
All ARIA labels MUST be sourced from the i18n system (never hardcoded).
`@axe-core/playwright` MUST be integrated into the Playwright E2E suite; a
per-page `axe` audit MUST run after navigation and MUST fail the test on any
WCAG 2.1 AA violation.

#### Scenario: Playwright E2E page passes axe audit at level AA

- GIVEN the health page (or any scaffolded page) in `frontend` or `backoffice`
- WHEN a Playwright E2E test navigates to the page and runs `@axe-core/playwright`
- THEN zero WCAG 2.1 AA violations are reported
- AND the test passes

#### Scenario: Missing `lang` attribute fails the accessibility audit

- GIVEN an `<html>` element without a `lang` attribute
- WHEN `@axe-core/playwright` audits the page
- THEN it reports a WCAG 2.1 AA violation and the test fails

#### Scenario: ARIA labels are i18n-sourced

- GIVEN an interactive element with an `aria-label` attribute in a Vue SFC
- WHEN the template is inspected
- THEN the value is an i18n expression (e.g. `$t('aria.someLabel')`) — never a raw string literal

---

### Requirement: GDPR-Compliant Candidate Flow Structure

Before any interview begins, the candidate MUST be shown a **privacy notice**
covering: the data controller's identity, the categories of data collected (audio,
video snapshots, transcript, evaluation), the data retention period, and the
candidate's right to withdraw consent. The candidate MUST give **explicit consent**
for recording and proctoring before proceeding; declining MUST allow the candidate
to exit without completing the interview. The backend MUST emit an **audit log
event** recording the consent decision (accepted / declined) with a timestamp,
candidate reference, and project ID. In the `backoffice`, a **data deletion request
mechanism** MUST be present in the candidate record view. (Note: consent UI is
scaffolded in C1; full wiring into the candidate flow is C7/C8.)

#### Scenario: Candidate cannot start interview without explicit consent

- GIVEN a candidate accessing the interview entry point
- WHEN the privacy notice is shown
- THEN the candidate cannot proceed to the interview without explicitly accepting
- AND declining allows the candidate to exit cleanly

---

### Requirement: noindex Policy

The `backoffice` app MUST serve `<meta name="robots" content="noindex, nofollow">`
on ALL pages in EVERY environment (it is an admin panel and must never be indexed
by search engines). The `frontend` app MUST serve `<meta name="robots" content="noindex, nofollow">` on `local` and `staging` environments; `production` may
serve normal robots headers for the public landing/entry page. Both apps MUST
implement this via `useHead` in the root layout, driven by the `NUXT_PUBLIC_APP_ENV`
runtime config environment variable.

#### Scenario: Backoffice page is always noindex

- GIVEN the `backoffice` app served in any environment (`local`, `staging`, or `production`)
- WHEN the page HTML is inspected
- THEN `<meta name="robots" content="noindex, nofollow">` is present in `<head>`

#### Scenario: Frontend is noindex on local and staging

- GIVEN the `frontend` app served with `NUXT_PUBLIC_APP_ENV` set to `local` or `staging`
- WHEN the page HTML is inspected
- THEN `<meta name="robots" content="noindex, nofollow">` is present in `<head>`

#### Scenario: Frontend does not block indexing on production

- GIVEN the `frontend` app served with `NUXT_PUBLIC_APP_ENV` set to `production`
- WHEN the page HTML is inspected
- THEN no `noindex` meta tag is injected by the layout (normal robots headers apply)

---

### Requirement: Lighthouse Performance Targets

The `frontend` application MUST achieve the following Lighthouse scores on
production-equivalent builds: Performance ≥ 90, Accessibility **100**, Best
Practices **100**, SEO ≥ 90 (landing page only). Core Web Vitals targets: LCP < 2.5 s,
CLS < 0.1, INP < 200 ms. Lighthouse CI (`lhci`) is integrated as a **non-blocking
advisory** step in C1 CI; blocking enforcement is a C13 NFR hardening concern.
The `backoffice` is excluded from SEO Lighthouse targets (noindex by design) but
MUST meet Performance ≥ 90, Accessibility **100**, Best Practices **100**.

#### Scenario: Lighthouse CI runs as advisory step (non-blocking in C1)

- GIVEN the `frontend` or `backoffice` CI workflow with an `lhci` step
- WHEN the step runs
- THEN it reports the Lighthouse scores in the CI log
- AND it does NOT fail the CI job in C1 (non-blocking advisory; promoted to blocking in C13)

---

### Requirement: i18n Mandate — Zero Hardcoded Text

No string literal intended for end users MAY appear inline in any Vue template,
PHP controller, API response, validation message, error message, email body,
notification payload, or Playwright test assertion label. ALL user-facing strings
MUST live in `lang/{it,en}.php` (api) or `i18n/locales/{it,en}.json` (Nuxt apps).
Use `$t('key')` in Vue templates; `__('key')` in PHP. ARIA attributes, button
labels, error messages, and meta description content MUST all be i18n keys.

This mandate applies to **user-facing** strings only. Machine-readable values are
explicitly exempt and MUST NOT be localized: API status payloads (e.g.
`/api/health` → `{"status":"ok"}`), enum values, database column and API field
names, log message keys, HTTP header names/values, and configuration keys. These
are returned or emitted literally in every locale.

#### Scenario: Zero inline string literals in Vue templates (outside translation files)

- GIVEN all `.vue` files in `frontend` and `backoffice`
- WHEN they are scanned for string literals in template text content and attribute values
- THEN every user-facing string uses `$t('key')` — no raw string literals appear in templates

#### Scenario: Zero inline string literals in PHP controllers and responses

- GIVEN all PHP files in `api/app/`
- WHEN they are scanned for inline user-facing string literals
- THEN every user-facing string uses `__('key')` — no raw English/Italian strings in responses

---

### Requirement: English-Only Code Policy

All source code identifiers, class names, method names, variable names, enum
values, database column names, API field names, PHP/TS comments, PHPDoc/TSDoc,
migration names, test names, and CI step names MUST be written in English.
Non-English natural language MUST NOT appear in source files, migration files,
test files, or CI workflow files. The sole permitted exception is i18n translation
files (`lang/*.php`, `i18n/locales/*.json`) which intentionally contain multiple
languages.

#### Scenario: No non-English identifiers in source files

- GIVEN all PHP and TypeScript/Vue source files across the three submodule repos
- WHEN they are scanned for non-English identifiers and comments
- THEN zero non-English identifiers or comments are found outside translation files

---

### Requirement: DESIGN.md as Authoritative UX Reference

A `DESIGN.md` file MUST exist at the wrapper repository root. It is the
authoritative reference for all UX/UI decisions: design tokens (colors, typography,
spacing), component architecture, responsive strategy, accessibility guidelines,
and interaction patterns. All Tailwind `@theme` custom properties in the Nuxt
apps MUST match the design tokens defined in `DESIGN.md`. No design decision
that contradicts `DESIGN.md` may be implemented without first updating `DESIGN.md`.

#### Scenario: DESIGN.md exists at the wrapper root

- GIVEN the wrapper repository on any branch
- WHEN the root directory is listed
- THEN `DESIGN.md` is present

---

### Requirement: Security Headers (API + Frontend + Backoffice)

All three apps MUST serve a defined set of HTTP security headers on every response.
The `api` MUST apply headers via a Laravel middleware registered globally:
`Content-Security-Policy`, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`,
`Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy` (deny camera/mic
by default; candidate interview route may override for its own context),
`Strict-Transport-Security: max-age=31536000; includeSubDomains` (HTTPS only).
Both Nuxt apps MUST apply the same headers via `nuxt.config.ts` `nitro.routeRules`
(or `routeRules` with `headers:`). No endpoint may disable security headers globally;
individual overrides (e.g. CSP for the avatar iframe) MUST be scoped to the specific
route. Docker images run as **non-root** users (already required in D17) — this
applies at the infrastructure layer.

#### Scenario: API responses include required security headers

- GIVEN a running `api` service
- WHEN any endpoint (including `GET /api/health`) is called
- THEN the response contains `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`,
  and `Referrer-Policy: strict-origin-when-cross-origin` headers

#### Scenario: Frontend and backoffice responses include security headers

- GIVEN a running `frontend` or `backoffice` Nuxt app
- WHEN any page or asset is requested
- THEN the response includes `X-Frame-Options`, `X-Content-Type-Options`, and `Referrer-Policy` headers

#### Scenario: Docker containers run as non-root

- GIVEN the built Docker image for any of the three apps
- WHEN `docker inspect` or the Dockerfile `USER` instruction is checked
- THEN the runtime user is NOT `root` (UID ≠ 0)

---

### Requirement: Dependency Resolution Policy

All runtime, framework, and library versions are pinned by the Version Catalog
(design.md D25) and locked in `composer.lock` / `bun.lockb`. An autonomous
implementation session MUST treat these pins as immutable. If any pinned
dependency cannot be installed or resolved — a version conflict, a yanked
release, an unmet platform requirement, or a missing required tool — the session
MUST **stop and report** the failure (the failing package, its version, and the
error) and wait for a human decision. The session MUST NOT downgrade a package,
MUST NOT replace a package with an alternative library, MUST NOT remove or loosen
a version constraint, and MUST NOT substitute an unspecified tool. A blocked
dependency is an open question for a human, never an autonomous implementation
decision.

#### Scenario: A pinned dependency that will not resolve halts the run

- GIVEN an autonomous apply session installing dependencies at their pinned versions
- WHEN a pinned package cannot be resolved or installed
- THEN the session stops at the failing step and reports the package, version, and error
- AND it does NOT downgrade, replace, unpin, or substitute the package to proceed

#### Scenario: Version constraints are never loosened to force a build

- GIVEN a dependency conflict between two pinned packages
- WHEN the conflict is encountered
- THEN the constraint is left unchanged and the conflict is reported
- AND no `^minor` pin is widened (e.g. to `*`) and no alternative library is introduced

---

### Requirement: Required Local Development Toolchain

An autonomous local implementation of C1 assumes the following tools are
installed and available on `PATH`, at the versions defined in the Version Catalog
(design.md D25): PHP 8.5 with the PCOV and `pdo_pgsql` extensions; Composer 2.4+;
Bun 1.3; Node 24 LTS; Docker with Docker Compose v2; the Playwright browsers
Chromium and WebKit (installed with `--with-deps`); go-task; and git. k6 is
required only for the local load-test task. The toolchain MUST be documented in
`docs/dev-setup.md`. A missing required tool MUST trigger the Dependency
Resolution Policy (stop and report — never substitute an alternative).

#### Scenario: Toolchain is documented and preconditions are checkable

- GIVEN a fresh wrapper clone
- WHEN a contributor (or an autonomous session) reads `docs/dev-setup.md`
- THEN every required local tool and its pinned version is listed
- AND a missing required tool causes the run to stop and report rather than substitute an alternative
