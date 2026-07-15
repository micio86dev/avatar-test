# Proposal: Project Skeleton & CI Foundation (C1)

## Intent

BEAI rebuilds an Astro avatar demo into a multi-tenant AI voice-interview platform across 12 vertical slices (C2–C13). None can start honestly without a shared, tested foundation. C1 delivers the greenfield **wrapper superproject** plus three **git submodules** (`api`, `frontend`, `backoffice`), local dev infra, an end-to-end test harness per repo (proven red→green), i18n scaffolding in both Nuxt apps, the OpenAPI→TS client contract, documented Git Flow (×4), and per-repo CI enforcing an 85% coverage gate. Success = a contributor clones `--recursive`, runs one command, gets three apps + PostgreSQL/Redis, and every push in each repo runs lint+tests+coverage on green.

## Scope

### In Scope

- **Wrapper superproject** (this repo): holds `docs/`, `openspec/` (SDD), `CLAUDE.md`, `docker-compose.yml`, submodule pointers, and a wrapper Taskfile/scripts to sync/init submodules. Astro demo relocated to `legacy-demo/` (plain folder, reference — NOT a submodule).
- **Submodule `api`** — **Laravel 13** + Eloquent + **PHP 8.5** + **PostgreSQL 17** (`pgvector/pgvector:pg17-alpine` local/CI; **Supabase** stage/prod) + **Redis 8** / Horizon, **API-only** (no Blade UI). **Scramble** (`dedoc/scramble ^0.12`) installed to publish the OpenAPI spec (`openapi.json`). Pest `^3.0` + PCOV coverage.
- **Submodule `frontend`** — **Nuxt 4** (Vue 3) **SSR**, `@nuxtjs/i18n ^9.0` (it/en). Candidate interview app. **Bun 1.3** install/build + **Node 24 LTS** SSR runtime. Vitest `^3.0` + Vue Test Utils `^2.4` + Playwright `^1.52` (3-project browser matrix). Codegen a typed TS client from `api`'s `openapi.json` (`openapi-typescript ^7.0`).
- **Submodule `backoffice`** — **Nuxt 4** (Vue 3) **SPA** (`ssr: false`), `@nuxtjs/i18n ^9.0` (it/en). Admin panel. **Bun 1.3** install/build + **Node 24 LTS** test runners. Vitest `^3.0` + Vue Test Utils `^2.4` + Playwright `^1.52` (3-project browser matrix). Codegen a typed TS client from `api`'s `openapi.json`.
- **API contract:** Scramble publishes `openapi.json`; `frontend` and `backoffice` each generate a typed TS client (e.g. `openapi-typescript`). Wire the codegen script + committed generated client per Nuxt repo.
- **Docker done properly:** a **multi-stage production-grade Dockerfile per app** (`api`, `frontend`, `backoffice`) — small final image, non-root user, healthcheck. Wrapper `docker-compose.yml` for local dev runs **PostgreSQL 17** (`pgvector/pgvector:pg17-alpine`) + **Redis 8** (`redis:8.0-alpine`) + Mailpit (`axllent/mailpit:v1.22`) **plus the three app services** (built from those Dockerfiles). **Railway builds via Docker** (same image local↔prod; Railway config parked, no deploy). CI builds the images too. A per-app `.env.example` in each submodule. **All base image tags pinned to exact versions (no `latest`)** — see Version Catalog in design.md D25.
- **Bun (hybrid) toolchain:** **Bun `1.3`** (`oven/bun:1.3`) for install/dev/**build** of both Nuxt apps (and the backoffice SPA static runtime); **Node `24 LTS`** (`node:24-slim`) for the `frontend` **SSR production runtime** (Nitro `node-server` preset) and for the **Playwright/Vitest** runners (officially Node-targeted). `frontend` Dockerfile: build on `oven/bun:1.3` → serve the Nitro node-server output on a `node:24-slim` runtime stage; `backoffice` builds with Bun and serves static (`nginx:1.27-alpine`). CI installs deps with Bun but runs Vitest/Playwright on Node. All exact patch versions locked in `bun.lockb`.
- **Auth = JWT, not Sanctum (referenced here; built in C2):** `tymon/jwt-auth` — bearer JWT for backoffice user auth (access + refresh, short expiry, Redis denylist for revocation), short-lived JWT for the candidate magic-link, JWT client token / API-key for external M2M. RBAC via `spatie/laravel-permission` in **teams mode** (`team_id = organization_id`). Because JWT is bearer/stateless, there is **no shared-parent-domain cookie constraint** — backoffice SPA and API may be different origins freely. (No auth code in C1; only references/notes.)
- Test harness wired end-to-end per repo: Pest (api), Vitest + Vue Test Utils + Playwright (frontend, backoffice), each proven red→green.
- **Playwright browser matrix** (both Nuxt apps) via Playwright `projects`: **Chromium** (desktop, full suite), **WebKit/Safari** (desktop, full suite — Safari is a supported browser per NFR), and a **mobile-viewport** project (device descriptor) that asserts the **unsupported-experience gate (SA-11)**, NOT full mobile support (product is desktop-only; Firefox intentionally excluded). Playwright best practices: web-first assertions, fixtures, trace-on-failure, no hard-coded waits, a fake interview provider for the candidate flow.
- **Every test tier runs in CI** — Pest (api), Vitest (both Nuxt), and Playwright (both Nuxt, all three projects) all execute in each repo's pipeline as **required** jobs (not nightly-only, not optional/skippable); browsers installed + cached in CI.
- **Per-repo CI** (GitHub Actions in each submodule): lint + tests (all tiers) + 85% coverage gate on `develop`/PRs. Wrapper CI runs cross-stack checks (clone `--recursive`, submodule-pointer sanity, compose smoke). No deploy (Railway config parked, not activated).
- i18n it/en scaffolding: Laravel `lang/` (api), `@nuxtjs/i18n` in both Nuxt apps.
- Health-check endpoint per app + one intentionally-failing smoke test each to prove TDD harness (red→green).
- Documented Git Flow (`main`/`develop`, `feature/*`, `release/*`, `hotfix/*`) for the wrapper AND each submodule (×4).
- **SemVer `M.m.p` versioning** driven by Git Flow, in the wrapper AND each submodule (each versioned independently): `release/*` bumps the version, `main` is tagged `vM.m.p` on release then merged back to `develop`; wrapper pins submodule release tags. Each repo seeds at `0.1.0` with a per-repo version source of truth (`package.json` version for Nuxt apps; a `VERSION` file + `composer.json` for `api`; `package.json`/`VERSION` for the wrapper).

### Out of Scope

- Any domain/business logic: tenancy, framework catalog, interview engine, scoring, webhooks (C2+).
- Live deploy / Railway activation; S3 storage; **auth implementation (JWT `tymon/jwt-auth` + `spatie/laravel-permission` teams mode) is C2** — C1 only fixes references/notes so nothing says Sanctum and no auth code is written.
- Real OpenAPI surface beyond the health endpoint (only the health route is documented via Scramble in C1; the client codegen is proven against that minimal spec).
- The 7 open product decisions — none block C1.

## Capabilities

### New Capabilities

- `project-skeleton`: wrapper + submodule topology, submodule wiring, local dev infra (compose + 3 app services with dedicated `beai_test` **PostgreSQL** database for testing; **Supabase** stage/prod; **pgVector** for AI features), per-app multi-stage Docker + Bun/Node hybrid toolchain, i18n scaffolding, OpenAPI→TS client contract, health-check endpoints, Git Flow ×4, SemVer `M.m.p` versioning ×4, per-repo pre-commit hooks (CaptainHook + Pint for `api`, Husky + lint-staged + Prettier for Nuxt apps), migration standards established (3NF, reversible, immutable, `organization_id`-first composite indexes, pgVector extension required), environment parity via pinned Docker tags, **Tailwind CSS v4** with design tokens from `DESIGN.md` in both Nuxt apps, **TypeScript strict mode** (`strict: true`, no `any`/`unknown`) in both Nuxt apps, **PHPStan level 8 + Larastan** in `api`, **WCAG 2.1 AA** accessibility enforced via `@axe-core/playwright` in Playwright E2E, **GDPR-compliant candidate flow structure** (privacy notice, explicit consent, audit log event), **noindex policy** (backoffice always; frontend on local + staging), **i18n mandate** (zero hardcoded text across all three repos), **English-only code policy** across all source files, `DESIGN.md` at wrapper root as authoritative UX/UI reference.
- `ci-pipeline`: per-repo GitHub Actions lint/test/coverage-gate workflows (all test tiers required, incl. the Playwright browser matrix and **PostgreSQL `beai_test` service + migrate for the api job**) + Docker image builds, wrapper cross-stack CI, and the test-harness contract. Additionally: **PHPStan `^2.0` static analysis** as a required blocking CI step in `api`, **`tsc --noEmit` / `nuxi typecheck`** as a required blocking CI step in both Nuxt workflows, **`@axe-core/playwright`** accessibility gate in the Playwright E2E step (blocking), **Lighthouse CI** advisory step in both Nuxt workflows (non-blocking in C1; promoted to blocking in C13), **independent deploy pipelines** (each Railway service monitors only its own repo's `main`; a deploy of `api` never triggers `frontend` or `backoffice`), **security pipeline** (`composer audit`, `bun audit`, Trivy container CVE scan as required blocking steps; GitHub secret scanning + Dependabot on all repos; GitHub Actions pinned to full SHA; security headers on all apps), **K6 load testing** (local-only against Docker Compose stack; manual `workflow_dispatch` CI trigger; baseline/stress/spike scenarios; HTML+JSON report in `docs/load-testing/`; answers concurrent-user capacity question), **cost-aware AI testing** (`FakeLLMProvider` + VCR cassette pattern; zero real AI API calls on standard PR CI; `@ai` Pest group in a dedicated `workflow_dispatch`-only `ai-integration.yml` workflow using cheap model; standard 85% gate satisfied by mock-based tests only).

### Modified Capabilities

None (greenfield; no existing specs).

## Approach

- Turn the repo root into the **wrapper**: keep `docs/`, `openspec/`, `CLAUDE.md`; add `docker-compose.yml`, a wrapper `Taskfile.yml`/scripts, and `.gitmodules`. Move the Astro demo wholesale into `legacy-demo/` (plain folder).
- Create three submodules — `api` (Laravel 13 + PHP 8.5 API-only + Scramble), `frontend` (Nuxt 4 SSR), `backoffice` (Nuxt 4 SPA) — each its own repo with its own Git Flow branches, `.env.example`, test harness, and CI workflow. Pin each into the wrapper via `.gitmodules`.
- `docker-compose.yml` in the wrapper provisions **PostgreSQL 17** (`pgvector/pgvector:pg17-alpine`, with an init script creating both `beai` and `beai_test` databases) + **Redis 8** (`redis:8.0-alpine`) + Mailpit (`axllent/mailpit:v1.22`) + the three app services (built from each app's multi-stage Dockerfile); each submodule's `.env.example` points at the compose service names. All base image tags pinned — see Version Catalog in design.md D25.
- Give each app a production-grade multi-stage Dockerfile (Bun build stage; Node runtime for `frontend` SSR / test runners; static serve for `backoffice`), non-root + healthcheck, so the local image equals the Railway image (Railway builds via Docker; no deploy in C1).
- Prove the harness per app with a health-check route/page + a first-failing smoke test, then make it pass — locking the RED→GREEN loop each repo's CI depends on.
- Wire the API contract: `api` exposes the health route and Scramble publishes `openapi.json`; `frontend` and `backoffice` each add a codegen script (`openapi-typescript`) that emits a typed client and a smoke test that consumes the generated `health` type.
- Per-submodule CI workflow: install, lint, test, enforce `--min=85`. Wrapper CI clones `--recursive` and runs cross-stack sanity (pointer freshness + compose smoke). Railway config committed but gated off.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| wrapper root (this repo) | Modified/New | `docker-compose.yml` (infra + 3 app services), `Taskfile.yml`/scripts, `.gitmodules`, wrapper `.github/workflows/`, `docs/git-flow.md` |
| `api` (submodule) | New repo | Laravel 13 + PHP 8.5, API-only, Scramble `^0.12`/OpenAPI, Pest `^3.0`, Horizon, `lang/` it/en, health route, multi-stage Dockerfile (`php:8.5-fpm-alpine`), JWT `^2.2`/Spatie `^6.0` packages present (not wired), own CI |
| `frontend` (submodule) | New repo | Nuxt 4 SSR, `@nuxtjs/i18n` it/en, Vitest/Playwright, OpenAPI→TS client, health page, multi-stage Dockerfile (Bun build → Node SSR runtime), own CI |
| `backoffice` (submodule) | New repo | Nuxt 4 SPA (`ssr: false`), `@nuxtjs/i18n` it/en, Vitest/Playwright, OpenAPI→TS client, health page, multi-stage Dockerfile (Bun build → static serve), own CI |
| `legacy-demo/` | Moved | Existing Astro demo relocated as plain-folder reference |
| `openspec/config.yaml`, `docs/` | Modified | Flip test-command statuses; document Git Flow ×4 + SemVer release flow |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Coverage gate blocks trivial skeleton (little real code) | Med | Scope gate to authored code per repo; smoke tests + generated-client smoke seed meaningful coverage |
| Submodule wiring friction (detached HEAD, forgotten `--recursive`, stale pointers) | Med | Wrapper Taskfile init/sync tasks; CI clones `--recursive`; pointer-freshness check in wrapper CI; document in `docs/git-flow.md` |
| OpenAPI→TS codegen drift between `api` and the two Nuxt clients | Med | Commit generated client + a smoke test that fails if the `health` type is absent; regenerate in CI and diff |
| Four parallel Git Flow repos add coordination overhead | Med | Chained per-repo PRs; wrapper pointer bump is the last PR; documented merge order |
| WebKit/Safari + mobile Playwright projects flake or slow CI | Med | Web-first assertions, trace-on-failure, fixtures, no hard-coded waits; browsers cached; mobile project runs only the SA-11 gate spec, not the full suite |
| Independent SemVer across 4 repos drifts / wrapper pins stale tags | Med | Version source of truth per repo; `release/*` bump + `vM.m.p` tag documented; wrapper pins submodule release tags and pointer-check flags drift |
| Bun/Node hybrid mismatch (deps built with Bun, tests/SSR run on Node) | Med | Pin Bun + Node versions; Dockerfile stages explicit (Bun build → Node runtime); CI installs with Bun but runs Vitest/Playwright on Node — proven green in C1 |
| Docker image build cost / multi-stage complexity in CI | Med | Multi-stage keeps final image small + non-root; layer caching in CI; build is a required but cache-friendly step |
| Local infra drift (versions) | Low | All image tags pinned per Version Catalog (design.md D25); `pgvector/pgvector:pg17-alpine` must match the Supabase PostgreSQL major version (17); bumps are deliberate and reviewed |

## Rollback Plan

Pure additive scaffolding. Each submodule lives on its own `feature/*` branch in its own repo; the wrapper pins them on a `feature/*` branch. Rollback = revert the wrapper feature branch (drop `.gitmodules` entries + submodule pointers) and discard the submodule feature branches; restore demo to root if needed. No data or production impact (no deploy).

## Dependencies

- None (foundation change). Downstream C2–C13 depend on C1. C7/C8 build inside `frontend`; C11 builds inside `backoffice`; all API work lands in `api`.

## Success Criteria

- [ ] `git clone --recursive` (or wrapper init task) brings the wrapper + all three submodules.
- [ ] `docker-compose up` brings **PostgreSQL 17** (`pgvector/pgvector:pg17-alpine`) + **Redis 8** + Mailpit + the three app services (built from their Dockerfiles); all three apps boot against them; both `beai` and `beai_test` databases are provisioned on first start.
- [ ] Each app has a multi-stage, non-root, healthchecked Dockerfile; `frontend` builds with Bun and serves Nitro `node-server` on a Node runtime stage; `backoffice` builds with Bun and serves static; the same image builds on Railway (parked, no deploy).
- [ ] CI builds each app's Docker image; deps install with Bun, Vitest/Playwright run on Node.
- [ ] No artifact references Sanctum; auth notes name JWT (`tymon/jwt-auth`) + `spatie/laravel-permission` teams mode, with the cross-origin cookie constraint removed (bearer JWT).
- [ ] Health endpoints respond 200 in `api`, `frontend`, and `backoffice`.
- [ ] Smoke test proven red→green in all three submodules.
- [ ] `api` Scramble publishes `openapi.json`; `frontend` and `backoffice` each codegen a typed client from it and a smoke test consumes the generated `health` type.
- [ ] Both Nuxt apps run a Playwright 3-project matrix (Chromium + WebKit/Safari full; mobile-viewport asserting the SA-11 unsupported-experience gate), all green.
- [ ] Per-repo CI runs lint + **all test tiers** (Pest / Vitest / Playwright matrix) + 85% coverage gate on PRs to `develop`, green; every tier is a required job; wrapper CI runs cross-stack sanity green.
- [ ] i18n it/en resolves in `api`, `frontend`, and `backoffice`; Git Flow documented for all four repos.
- [ ] SemVer `M.m.p` seeded at `0.1.0` in all four repos with a documented `release/*` → `vM.m.p` tag flow; wrapper pins submodule release tags.
- [ ] `openspec/config.yaml` test-command statuses flipped to scaffolded.
- [ ] Each submodule's pre-commit hook installs automatically on `composer install` (`api`) / `bun install` (`frontend`, `backoffice`), and staged formatting violations are rejected (`api`) or auto-fixed + re-staged (Nuxt apps).
- [ ] `beai_test` PostgreSQL database provisioned in docker-compose on first start; `api` Pest feature tests connect to PostgreSQL `beai_test` (never SQLite) both locally and in CI; migration standards documented and enforced from C2 onward (including `CREATE EXTENSION IF NOT EXISTS vector` for pgVector migrations).
- [ ] PHPStan level 8 + Larastan installed in `api`; `phpstan analyse` exits clean (or with a committed baseline for scaffold-only noise); PHPStan runs as a required blocking CI step before Pest.
- [ ] Both Nuxt apps have `strict: true` TypeScript; `nuxi typecheck` exits 0 on the C1 scaffold; the `typecheck` CI step is required and blocking in both Nuxt workflows.
- [ ] Tailwind CSS v4 installed in both Nuxt apps; utility classes resolve in `.vue` SFCs; design tokens from `DESIGN.md` are wired via CSS `@theme {}` blocks.
- [ ] `@axe-core/playwright` integrated into Playwright E2E of both Nuxt apps; zero WCAG 2.1 AA violations on all C1 scaffold pages; accessibility gate is a required blocking E2E step.
- [ ] `backoffice` always serves `<meta name="robots" content="noindex, nofollow">`; `frontend` serves `noindex` on `local` and `staging` environments; both driven by `NUXT_PUBLIC_APP_ENV`.
- [ ] Zero hardcoded user-facing string literals in any Vue template, PHP controller, or API response; all user-facing strings use `$t('key')` (Vue) or `__('key')` (PHP).
- [ ] All source code identifiers, comments, and copy across all three repos are in English; non-English language present only in i18n locale files.
- [ ] `DESIGN.md` exists at the wrapper root and is referenced in `README.md` and `CLAUDE.md`; Tailwind `@theme` tokens in both Nuxt apps match the design tokens defined in `DESIGN.md`.
- [ ] Each submodule has an independent Railway service config; merging to `api`'s `main` does NOT trigger `frontend` or `backoffice` deployments; deploy independence documented in `docs/deploy.md`.
- [ ] `api` CI includes required blocking steps: `composer audit` (dependency CVE check) + Trivy container scan (HIGH/CRITICAL CVE → fail); both Nuxt CIs include `bun audit` + Trivy; security headers (`X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`) served by all three apps; Dependabot enabled on all submodule repos; GitHub Actions pinned to full SHA.
- [ ] K6 load-test scripts present in `api/tests/k6/` (baseline, stress, spike); Taskfile `test:load` task runs against local Docker Compose stack; `load-test.yml` workflow is `workflow_dispatch`-only; initial capacity report committed to `docs/load-testing/`.
- [ ] `FakeLLMProvider` bound in test environment with zero real AI API calls during `php artisan test`; VCR cassette pattern established; `@ai` Pest group excluded from standard CI; dedicated `ai-integration.yml` workflow uses `claude-haiku-4-5-20251001` model on `workflow_dispatch` or `release/*` only.
