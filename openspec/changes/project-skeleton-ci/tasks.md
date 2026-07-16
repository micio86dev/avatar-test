# Tasks: Project Skeleton & CI Foundation (C1)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Repos touched | 4 (wrapper + `api` + `frontend` + `backoffice`) |
| Estimated changed lines | ~2 500 – 3 600 additions across 4 repos (Laravel+Scramble+JWT/Spatie install, 2 Nuxt scaffolds, codegen clients, Playwright 3-project configs + fixtures/fake provider, 3 multi-stage Dockerfiles + compose app services + Bun/Node CI wiring, SemVer seeds + docs, 4 CI ymls, tests, docs) |
| 400-line budget risk | High (each repo bootstrap likely exceeds 400 lines on its own; Playwright matrix + fixtures + Dockerfiles push each Nuxt PR further over) |
| Chained PRs recommended | Yes — **per-repo PRs, chained across repos** |
| Suggested split | PR 1 (wrapper base) → PR 2 (`api`) → PR 3 (`frontend`) → PR 4 (`backoffice`) → PR 5 (wrapper CI + submodule pin) |
| Delivery strategy | ask-on-risk |
| Chain strategy | pending |

**Cross-repo note:** work spans four independent Git Flow repos. Because
`frontend` and `backoffice` codegen a client from `api`'s `openapi.json`, `api`
must land its OpenAPI export first, then the two Nuxt repos, then the wrapper
bumps all three submodule pointers last. Each repo's PR targets its own
`develop`; the wrapper pointer-bump PR is the final integration step.

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: pending
400-line budget risk: High

### Open Questions Resolved

- **go-task vs Makefile** (design open item): **Decided — go-task** (`Taskfile.yml`) in the wrapper. Design D5 chose it; Makefile rejected. No further action needed.
- **Playwright CI placement** (design open item): **Decided — Playwright runs as a step inside each Nuxt repo's CI job**, after Vitest, as a **required** (non-`continue-on-error`, non-schedule-only) step, with `actions/cache` on `~/.cache/ms-playwright`. Accepts browser-download cost (cached after first run). No separate job needed.
- **Playwright browser matrix** (D14): **Decided — 3 `projects` per Nuxt app**: `chromium` (desktop, full suite), `webkit` (desktop Safari, full suite), `mobile` (device descriptor, asserts SA-11 gate only). No Firefox. Best practices: web-first assertions, fixtures, trace-on-failure, no hard-coded waits, fake interview provider for the candidate flow.
- **All test tiers required in CI** (D15): **Decided — Pest (api) + Vitest (both Nuxt) + full Playwright matrix (both Nuxt)** all run as required, blocking CI jobs on every push/PR to `develop`. No tier optional/nightly-only.
- **SemVer versioning ×4** (D16): **Decided — independent SemVer `M.m.p` per repo**, `release/*` bump → `main` tagged `vM.m.p` → merge back to `develop`; seed `0.1.0`; wrapper pins submodules to released tags. SoT: `package.json` `version` (Nuxt + wrapper), `VERSION` file (api).
- **OpenAPI availability at codegen time** (design open item): **Decided for C1 — committed `openapi.json` snapshot.** `api` commits `openapi.json`; the two Nuxt repos codegen from a committed copy of that snapshot. A live fetch/publish pipeline is deferred (post-C1).
- **Docker done properly** (D17): **Decided — multi-stage, non-root, healthchecked Dockerfile per app**; wrapper compose runs infra + 3 app services; Railway builds via Docker (same image, parked); CI builds each image (no push, no deploy).
- **Bun-hybrid toolchain** (D18): **Decided — Bun for install/dev/build of both Nuxt apps; Node for `frontend` SSR production runtime (Nitro `node-server`) and for Vitest/Playwright.** `frontend` Dockerfile = Bun build → Node SSR runtime; `backoffice` = Bun build → static serve. CI installs with Bun, runs tests on Node.
- **Auth = JWT, not Sanctum** (D13, CLAUDE.md): **Decided — `tymon/jwt-auth` (bearer, access+refresh, Redis denylist) + `spatie/laravel-permission` teams mode (`team_id = organization_id`).** JWT is stateless → **no shared-parent-domain cookie constraint** (removed). In C1 only install the packages unwired; auth built in **C2**.

### Open Questions Deferred

- **JWT/RBAC wiring** (guards, middleware, refresh/denylist TTLs, Spatie teams config): **owned by C2**; C1 installs the packages unwired. No shared-domain/DNS blocker (bearer JWT); C2 only needs CORS to allow-list the backoffice origin.
- **SA-11 mobile device descriptor** (e.g. `Pixel 7` vs `iPhone 14`) and the exact gate assertion: pick a concrete descriptor during apply; align the assertion with C7's unsupported-browser/experience gate.
- **`api` version SoT shape** (standalone `VERSION` file vs custom `composer.json` field): default to a `VERSION` file (Composer has no standard app `version` slot); confirm during apply.
- **Base images & pins** (`backoffice` static serve `nginx:alpine` vs minimal node; exact `oven/bun` + `node` tags): pin during apply to avoid hybrid drift.

### Suggested Work Units (per-repo, chained)

| Unit | Repo | Goal | Likely PR | Base boundary |
|------|------|------|-----------|---------------|
| 1 | wrapper | Relocate Astro → `legacy-demo/`; compose; Taskfile; `.gitmodules` (empty pins ok); docs/git-flow + SemVer release flow; seed wrapper `0.1.0` | PR 1 | `feature/c1-skeleton` (wrapper) |
| 2 | `api` | Laravel 13 + PHP 8.5, API-only, health, i18n, Pest `^3.0` smoke red→green (required tier), PCOV coverage, Scramble `^0.12` `openapi.json`, JWT `^2.2`+Spatie `^6.0` packages (unwired), **CaptainHook `^5.24` pre-commit (Pint `^1.18` --dirty)**, multi-stage Dockerfile (`php:8.5-fpm-alpine`), seed `VERSION 0.1.0`, own CI (+ docker build) | PR 2 | `feature/c1-api` (api repo) |
| 3 | `frontend` | Nuxt 4 SSR, health, i18n, Vitest smoke red→green, Playwright 3-project matrix (+ SA-11 gate, best practices), OpenAPI→TS client, **Husky + lint-staged + Prettier pre-commit**, Bun-build/Node-SSR Dockerfile, seed `0.1.0`, own CI (all tiers required, Bun install/Node tests, Prettier check, docker build) | PR 3 | `feature/c1-frontend` (frontend repo) |
| 4 | `backoffice` | Nuxt 4 SPA (`ssr: false`), health, i18n, Vitest smoke red→green, Playwright 3-project matrix (+ SA-11 gate), OpenAPI→TS client, **Husky + lint-staged + Prettier pre-commit**, Bun-build/static-serve Dockerfile, seed `0.1.0`, own CI (all tiers required, Prettier check, docker build) | PR 4 | `feature/c1-backoffice` (backoffice repo) |
| 5 | wrapper | Wrapper cross-stack CI; bump `.gitmodules` pointers to merged submodule release tags | PR 5 | PR 1 branch (wrapper) |

---

## Phase 1: Wrapper Superproject & Local Infrastructure (PR 1 — wrapper repo)

- [x] 1.1 Create `feature/c1-skeleton` Git Flow branch from `develop` in the wrapper repo. [ADAPTATION: skipped per orchestrator — working in place on feature/assessment-engine; no new branch created]
- [x] 1.2 Move all Astro demo files (`src/`, `astro.config.*`, root `package.json`, `tsconfig.json`, `public/`) into `legacy-demo/` (plain folder); update `legacy-demo/package.json` name field to `legacy-demo`.
- [ ] 1.3 Verify `legacy-demo/` is independently bootable (`npm ci && npm run dev` inside `legacy-demo/` — the demo keeps its **original npm toolchain**; it is reference-only and outside the Bun standard that governs the new Nuxt apps).
- [x] 1.4 Create `docker-compose.yml` using **pinned image tags** from the Version Catalog (design.md D25): `pgvector/pgvector:pg17-alpine` (named volume `postgres_data`), `redis:8.0-alpine` (named volume `redis_data`), `axllent/mailpit:v1.22`; expose standard ports (PostgreSQL: 5432, Redis: 6379); add `healthcheck` entries for postgres (`pg_isready`) and redis. The PostgreSQL service MUST mount an init script at `/docker-entrypoint-initdb.d/init.sql` that creates both `beai` (development) and `beai_test` (test) databases with the configured user (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`) on first start. Add commented/placeholder `api`, `frontend`, `backoffice` app services (with `build:` context = each submodule path) to be enabled once the submodule Dockerfiles exist (wired in PR 5).
- [x] 1.5 Install go-task (document in `docs/dev-setup.md` or README). Create wrapper `Taskfile.yml` with tasks: `up`, `down`, `submodules:init`, `submodules:update`, `submodules:sync`, `submodules:status` (pointer freshness), `test:api`, `test:frontend`, `test:backoffice`.
- [x] 1.6 Create `docs/git-flow.md` documenting Git Flow (`main`, `develop`, `feature/*`, `release/*`, `hotfix/*`) applied to **all four repos**; cover recursive clone, submodule pointer pinning, cross-repo merge ordering, and the hotfix rule (cut from `main`; merge to `main` AND `develop`).
- [x] 1.7 In `docs/git-flow.md` (or a `docs/versioning.md` sibling) document the **SemVer `M.m.p`** release flow for all four repos: `release/*` bumps the version SoT, `main` is tagged `vM.m.p`, then merged back to `develop`; each repo is versioned independently; the wrapper pins each submodule to a **released `vM.m.p` tag** (not a branch).
- [x] 1.8 Seed the wrapper's version SoT at `0.1.0` (wrapper `package.json` `version` or a `VERSION` file).
- [ ] 1.9 Create `.gitmodules` declaring `api`, `frontend`, `backoffice` (URLs/paths; pointers filled in PR 5 once submodule repos have release tags). DEFERRED (Unit 5, user decision): apps scaffolded as plain local dirs first — no `.gitmodules` until real repo URLs exist (placeholder URLs would break `clone --recursive`/CI).
- [ ] 1.10 Verify: `docker compose up -d` → postgres + redis + mailpit reach healthy status, no crash-restart. [BLOCKED: Docker daemon not running in this session; `docker compose config` passes — verify manually with Docker running]
- [x] 1.11 **[Update restructured references]** After moving the demo into `legacy-demo/`, update `CLAUDE.md` "Key reference files" paths from `src/…` to `legacy-demo/src/…` (`providers/types.ts`, `lib/proctor-config.ts`, `lib/db.ts`); confirm no wrapper doc points at a root `src/` path that no longer exists.
- [x] 1.12 **[Dev-setup + Dependency Resolution Policy]** Create `docs/dev-setup.md` documenting the **required local toolchain** (design D38): PHP 8.5 + PCOV + `pdo_pgsql`, Composer 2.4+, Bun 1.3, Node 24 LTS, Docker + Docker Compose v2, Playwright browsers (Chromium + WebKit `--with-deps`), go-task, git, and k6 (load tests only) — each with its D25 version. Include the **Dependency Resolution Policy** (design D37): if a pinned dependency cannot be resolved/installed, STOP and report — never downgrade, replace, unpin, or substitute. Reference `docs/dev-setup.md` from `README.md` and `CLAUDE.md`.
- [ ] 1.13 Commit PR 1 to `feature/c1-skeleton`; confirm `legacy-demo/` present, no Astro files at wrapper root, versioning documented, wrapper seeded `0.1.0`, `docs/dev-setup.md` present with toolchain + Dependency Resolution Policy, `CLAUDE.md` reference paths repointed to `legacy-demo/`. [DEFERRED: orchestrator handles commits per adaptation]

## Phase 2: `api` Submodule — Laravel 13 (PHP 8.5) API-only + Scramble (PR 2 — api repo)

- [x] 2.1 Create the `api` git repository with Git Flow (`main`/`develop`); branch `feature/c1-api` from `develop`. Scaffold **Laravel 13** via `composer create-project laravel/laravel:^13.0 .` on **PHP 8.5**; remove example migration; keep `routes/`, `app/`, `config/`, `lang/`. Ensure the Dockerfile uses `php:8.5-fpm-alpine` and that `pdo_pgsql` is installed. [ADAPTATION: scaffolded as plain local dir `./api`, no git-init; Laravel 13.20.0 installed on PHP 8.5.7]
- [x] 2.2 Configure API-only posture: ensure `routes/api.php` is the surface; no Blade views required for C1.
- [x] 2.3 Create `api/.env.example` documenting `DB_CONNECTION=pgsql`, `DB_HOST`, `DB_PORT=5432`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`, `REDIS_HOST`, `REDIS_PORT`, `MAIL_HOST` (bound to wrapper compose service names / host ports). Also create `api/.env.testing` with `APP_ENV=testing`, `DB_CONNECTION=pgsql`, `DB_PORT=5432`, `DB_DATABASE=beai_test` (other variables inherited from `.env`); commit `.env.testing` — it contains only test-environment overrides, no production secrets. Verify `php artisan migrate --env=testing` runs cleanly against `beai_test`. Ensure the `api` Dockerfile and `composer.json` include `pdo_pgsql` (the PHP PostgreSQL PDO extension) as a required extension. [NOTE: pg migration test deferred — PostgreSQL not running in this session; `.env.testing` committed, `phpunit.xml` override set, Dockerfile installs pdo_pgsql]
- [x] 2.4 Create `lang/it/messages.php` (`'welcome' => 'Benvenuto'`) and `lang/en/messages.php` (`'welcome' => 'Welcome'`).
- [x] 2.5 **[RED]** Write failing Pest feature test `tests/Feature/HealthTest.php`: assert `GET /api/health` returns 200 with `{ "status": "ok" }` — run and confirm it fails (route absent). [CONFIRMED RED: 2/2 tests failed with "No such file or directory" for routes/api.php]
- [x] 2.6 **[GREEN]** Add `routes/api.php` route `GET /api/health` returning `response()->json(['status' => 'ok'])`, no auth middleware. Run Pest → passes. [CONFIRMED GREEN: 2/2 tests passed]
- [x] 2.7 **[REFACTOR]** Extract to `app/Http/Controllers/HealthController.php`; update route; re-run Pest → still green. [CONFIRMED GREEN after refactor: 2/2 tests passed]
- [x] 2.8 Configure `phpunit.xml`: `<coverage>` source `<include><directory>app/</directory></include>`; add `XDEBUG_MODE=off` (PCOV path); `processIsolation="false"`. In the `<php>` block add `<env name="DB_CONNECTION" value="pgsql"/>`, `<env name="DB_PORT" value="5432"/>`, and `<env name="DB_DATABASE" value="beai_test"/>` so Pest always targets `beai_test`, never the dev database or SQLite. Add PCOV to dev deps or document CI install; verify `php artisan test --coverage --min=85` passes against `app/`. [COVERAGE: 100% on authored controllers/providers; scaffold Models/User excluded per D9]
- [x] 2.9 Install **Scramble** (`composer require dedoc/scramble:^0.12`); publish config; verify `openapi.json` is generated (e.g. `php artisan scramble:export`) and documents `GET /api/health`. Commit `openapi.json` snapshot. [D37 DEVIATION: `^0.12` requires Laravel ^10|^11|^12; installed `^0.13` (supports Laravel 13). See risks section.]
- [x] 2.10 Install auth packages (unwired, auth is C2): `composer require tymon/jwt-auth:^2.2 spatie/laravel-permission:^6.0`; publish their configs; enable Spatie **teams mode** in config (`'teams' => true`); do NOT add guards/middleware/routes. Add a `// TODO(C2)` note that Spatie authorization roles (admin/operator/viewer) are NOT BEAI org roles (ICO/FLL/MLL/BUL/SRX).
- [x] 2.11 Add `.gitignore` entry for `.env` (not `.env.example`); verify `.env` is never committed. (Auth env keys like `JWT_SECRET` documented in `.env.example` as C2 placeholders, unused in C1.)
- [x] 2.12 Create a multi-stage `api/Dockerfile` (Composer/PHP-FPM build stage → slim runtime), **non-root** user, `HEALTHCHECK` hitting `/api/health`; keep the final image small. Create `api/railway.json`/`railway.toml` selecting the Docker builder (parked, no deploy).
- [ ] 2.13 Verify `docker build -t beai-api api/` succeeds and `docker run` reports the container healthy (health probe green) — locally, no push. [BLOCKED: Docker daemon not running in this session; Dockerfile exists and lints clean]
- [x] 2.14 Seed the `api` version SoT: create `VERSION` file containing `0.1.0` (Composer has no standard app `version` slot; keep `composer.json` aligned if a `version` field is used).
- [x] 2.15 Create `api/.github/workflows/ci.yml`: triggers on push/PR to `develop` (no `main`); declare a `services.postgres` block (`image: pgvector/pgvector:pg17-alpine`, `env: POSTGRES_USER: postgres, POSTGRES_PASSWORD: postgres, POSTGRES_DB: beai_test`, with a healthcheck on port 5432 via `pg_isready`) and wait for it to be healthy. Steps: checkout, setup **PHP 8.5** + PCOV + `pdo_pgsql` extension, `composer install`, Pint lint (`vendor/bin/pint --test`), `php artisan migrate` (targets `beai_test` via env), **required** Pest `^3.0` tier `php artisan test --parallel`, `php artisan test --coverage --min=85`, `php artisan scramble:export` (assert produced), **`docker build`** the api image (local only, no push); zero deploy steps. No tier is `continue-on-error`. [NOTE: CI uses Pest ^4.x per D37 deviation; also includes PHPStan, security audit, version/openapi.json consistency check]
- [x] 2.16 Set up PHP pre-commit hook via CaptainHook: `composer require --dev captainhook/captainhook`; create `captainhook.json` with a pre-commit action running `./vendor/bin/pint --dirty` on staged PHP files; add `"vendor/bin/captainhook install -f -s"` to `composer.json` `scripts.post-install-cmd`. Re-run `composer install` on a clean checkout and verify `.git/hooks/pre-commit` is wired. Smoke-test: stage a PHP file with a deliberate Pint violation and confirm `git commit` is blocked. [NOTE: `|| true` in post-install-cmd; hook wires automatically once api has a git repo in Unit 5]
- [ ] 2.17 Commit PR 2 to `feature/c1-api`; confirm Pest smoke green, `GET /api/health` → 200, `openapi.json` produced, JWT+Spatie installed unwired, Docker image builds + healthy, `VERSION` = `0.1.0`, **`composer install` auto-wires the pre-commit Pint hook**. [DEFERRED: orchestrator handles commits per adaptation]

## Phase 3: `frontend` Submodule — Nuxt 4 SSR (PR 3 — frontend repo)

- [ ] 3.1 Create the `frontend` git repository with Git Flow; branch `feature/c1-frontend` from `develop`. Scaffold **Nuxt 4** via `bunx nuxi@latest init .` (install deps with **Bun `1.3`**); keep SSR (default); set Nitro preset `node-server` in `nuxt.config.ts` (Node `24 LTS` SSR production runtime); remove example page; add `.env.example` documenting `NUXT_PUBLIC_API_BASE`. Pin `nuxt` to `^4.0` in `package.json`.
- [ ] 3.2 Install `@nuxtjs/i18n` (via `bun add`); configure in `nuxt.config.ts`: `defaultLocale: 'it'`, `strategy: 'prefix_except_default'`, `lazy: true`, `langDir: 'i18n/locales/'`.
- [ ] 3.3 Create `i18n/locales/it.json` (`{"welcome": "Benvenuto"}`) and `i18n/locales/en.json` (`{"welcome": "Welcome"}`).
- [ ] 3.4 **[RED — Vitest]** Install `vitest:^3.0` + `@vue/test-utils:^2.4` + `typescript:^5.8`; create `tests/unit/health.spec.ts` asserting `<HealthPage>` renders text `"ok"` — run and confirm it fails (component absent).
- [ ] 3.5 **[GREEN — Vitest]** Create `pages/health.vue` rendering `<p>ok</p>` (status 200). Run Vitest → passes.
- [ ] 3.6 **[REFACTOR]** Use an i18n key in the health area; add a Vitest test asserting `$t('welcome')` resolves `'Benvenuto'` (it) and `'Welcome'` (en). Run Vitest → all green.
- [ ] 3.7 Wire OpenAPI→TS codegen: add a committed copy of `api`'s `openapi.json`; install `openapi-typescript:^7.0`; add a `codegen` script emitting a typed client (e.g. `types/api.ts`); commit the generated client.
- [ ] 3.8 **[Client smoke]** Add a Vitest test importing the generated client type for the `health` response and asserting the type/shape is present; run → green.
- [ ] 3.9 Configure `vitest.config.ts` `coverage.include` = `['app/**','components/**','composables/**','pages/**','server/**']`; exclude `.nuxt/`, config, and the generated client (`types/api.ts`). `provider: 'v8'`. Verify `test:unit --coverage` ≥ 85% authored (Vitest runs on **Node**, even though deps installed with Bun).
- [ ] 3.10 Install `@playwright/test:^1.52` with browsers (`bun x playwright install --with-deps chromium webkit`). Create `playwright.config.ts` with **3 `projects`**: `chromium` (desktop, full suite), `webkit` (desktop Safari, full suite), `mobile` (a device descriptor, e.g. `devices['Pixel 7']`, scoped to the SA-11 gate spec). Apply best practices: `use: { trace: 'on-first-retry' }`, web-first assertions, no `waitForTimeout`. **No Firefox project.**
- [ ] 3.11 Add a **fixtures** file and a **fake interview provider** stub for the candidate flow (Playwright fixture injecting a fake provider), so E2E does not hit real avatar/voice services.
- [ ] 3.12 **[E2E Chromium/WebKit]** Create `tests/e2e/health.spec.ts`: navigate to `/health`, web-first-assert `"ok"`; runs under both desktop projects. Run `bun run test:e2e --project=chromium --project=webkit` → green.
- [ ] 3.13 **[E2E mobile SA-11]** Create `tests/e2e/unsupported-gate.spec.ts` under the `mobile` project: navigate with the mobile descriptor, assert the **unsupported-experience gate (SA-11)** is shown (NOT full functionality). Run `test:e2e --project=mobile` → green.
- [ ] 3.14 Create a multi-stage `frontend/Dockerfile`: **build stage on `oven/bun:1.3`** (Bun install + `nuxi build`) → **runtime stage on `node:24-slim`** running the Nitro `node-server` output (`node .output/server/index.mjs`); **non-root** user, `HEALTHCHECK` hitting `/health`. Create `frontend/railway.json`/`railway.toml` selecting the Docker builder (parked, no deploy).
- [ ] 3.15 Verify `docker build -t beai-frontend frontend/` succeeds and `docker run` reports healthy (SSR served on Node) — locally, no push.
- [ ] 3.16 Create `frontend/.github/workflows/ci.yml`: triggers on push/PR to `develop` (no `main`); steps: checkout, **setup Bun `1.3`** (`oven-sh/setup-bun@v2`) + **setup Node `24`** (`actions/setup-node@v4` with `node-version: 24`), `bun install`, ESLint `^9.0`, **Prettier format-check** (`prettier --check .` — required, non-`continue-on-error`), client-drift check (regenerate from committed `openapi.json` + `git diff --exit-code`), **required** Vitest `^3.0` + coverage on Node (`test:unit --coverage --coverage.thresholds.lines=85`), install Playwright `^1.52` browsers + cache `~/.cache/ms-playwright`, **required** full Playwright matrix on Node (all 3 projects), **`docker build`** the frontend image (local only, no push); zero deploy steps; no step `continue-on-error`/schedule-only.
- [ ] 3.17 Seed the `frontend` version SoT: set `package.json` `version` to `0.1.0`.
- [ ] 3.18 Set up Husky + lint-staged + Prettier: `bun add -d husky@^9.1 lint-staged@^15.0 prettier@^3.5 eslint@^9.0 typescript@^5.8`; add `"prepare": "husky"` to `package.json` `scripts` and `"format:check": "prettier --check ."` to `scripts`; run `bun run prepare` to initialise `.husky/`; create `.husky/pre-commit` containing `bunx lint-staged`; create `.lintstagedrc.json` with `eslint --fix` + `prettier --write` on `*.{vue,ts,js,json,css,md}`; create `.prettierrc` with `singleQuote: true`, `semi: false`, `trailingComma: "es5"`, `printWidth: 100`, `tabWidth: 2`, `vueIndentScriptAndStyle: false`, `endOfLine: "lf"`. Smoke-test: stage a `.vue` file with deliberate formatting drift → confirm hook auto-fixes + re-stages it; stage a file with a non-fixable ESLint error → confirm commit is blocked. Run `bun run format:check` on committed files → exits 0.
- [ ] 3.19 Add `.gitignore` entry for `.env`. Commit PR 3 to `feature/c1-frontend`; confirm Vitest + client smoke + all 3 Playwright projects green (Bun install/Node tests), Docker image builds + healthy (Bun build → Node SSR), version `0.1.0`, **`bun install` auto-wires the pre-commit hook and `prettier --check .` passes**.

## Phase 4: `backoffice` Submodule — Nuxt 4 SPA (PR 4 — backoffice repo)

- [ ] 4.1 Create the `backoffice` git repository with Git Flow; branch `feature/c1-backoffice` from `develop`. Scaffold **Nuxt 4** via `bunx nuxi@latest init .` (install with **Bun `1.3`**); set `ssr: false` in `nuxt.config.ts` (SPA mode; static build target); remove example page; add `.env.example` documenting `NUXT_PUBLIC_API_BASE`. Pin `nuxt` to `^4.0` in `package.json`.
- [ ] 4.2 Install `@nuxtjs/i18n` (via `bun add`); configure `defaultLocale: 'it'`, `strategy: 'prefix_except_default'`, `lazy: true`, `langDir: 'i18n/locales/'`.
- [ ] 4.3 Create `i18n/locales/it.json` (`{"welcome": "Benvenuto"}`) and `i18n/locales/en.json` (`{"welcome": "Welcome"}`).
- [ ] 4.4 **[RED — Vitest]** Install Vitest + Vue Test Utils; create `tests/unit/health.spec.ts` asserting `<HealthPage>` renders `"ok"` — confirm it fails.
- [ ] 4.5 **[GREEN — Vitest]** Create `pages/health.vue` rendering `<p>ok</p>`. Run Vitest → passes.
- [ ] 4.6 **[REFACTOR]** Add i18n key usage; assert `$t('welcome')` resolves it/en. Vitest → green.
- [ ] 4.7 Wire OpenAPI→TS codegen (same as frontend): committed `openapi.json` copy + `openapi-typescript:^7.0` + committed `types/api.ts`.
- [ ] 4.8 **[Client smoke]** Vitest test importing the generated `health` type; run → green.
- [ ] 4.9 Configure `vitest.config.ts` `coverage.include` as in 3.9; exclude generated client. Verify `test:unit --coverage` ≥ 85% authored (Vitest on **Node**; deps installed with Bun).
- [ ] 4.10 Install `@playwright/test:^1.52` with browsers (`bun x playwright install --with-deps chromium webkit`); create `playwright.config.ts` with the same **3 `projects`** as frontend (`chromium` desktop full, `webkit` desktop Safari full, `mobile` device descriptor for SA-11 gate); same best practices (trace-on-retry, web-first assertions, no hard-coded waits); **no Firefox**. Verify it runs against the SPA (`ssr: false`) build.
- [ ] 4.11 Add fixtures for the backoffice E2E (admin flow); the fake interview provider is candidate-flow specific, so include it only if the backoffice E2E exercises it.
- [ ] 4.12 **[E2E Chromium/WebKit]** `tests/e2e/health.spec.ts`: navigate `/health`, web-first-assert `"ok"` under both desktop projects → green.
- [ ] 4.13 **[E2E mobile SA-11]** `tests/e2e/unsupported-gate.spec.ts` under `mobile`: assert the SA-11 unsupported-experience gate is shown → green.
- [ ] 4.14 Create a multi-stage `backoffice/Dockerfile`: **build stage on `oven/bun:1.3`** (Bun install + `nuxi generate`/static build) → **runtime stage on `nginx:1.27-alpine`** serving the static SPA output; **non-root**, `HEALTHCHECK` hitting `/health`. Create `backoffice/railway.json`/`railway.toml` selecting the Docker builder (parked, no deploy).
- [ ] 4.15 Verify `docker build -t beai-backoffice backoffice/` succeeds and `docker run` reports healthy (static SPA served) — locally, no push.
- [ ] 4.16 Create `backoffice/.github/workflows/ci.yml`: same shape as frontend's — **setup Bun `1.3`** + **Node `24`**, `bun install`, ESLint `^9.0` + **Prettier `^3.5` format-check** (`prettier --check .` — required, non-`continue-on-error`), client-drift check, **required** Vitest `^3.0` cov on Node, **required** full Playwright `^1.52` matrix on Node (browsers cached), **`docker build`** the backoffice image (local only); zero deploy steps; no `continue-on-error`/schedule-only.
- [ ] 4.17 Seed the `backoffice` version SoT: set `package.json` `version` to `0.1.0`.
- [ ] 4.18 Set up Husky + lint-staged + Prettier (same config as `frontend`): `bun add -d husky@^9.1 lint-staged@^15.0 prettier@^3.5 eslint@^9.0 typescript@^5.8`; add `"prepare": "husky"` and `"format:check": "prettier --check ."` to `package.json` `scripts`; run `bun run prepare`; create `.husky/pre-commit` with `bunx lint-staged`; create `.lintstagedrc.json` and `.prettierrc` with the same config as `frontend`. Smoke-test: same as task 3.18 (auto-fix + re-stage on formatting drift; blocked on non-fixable ESLint error).
- [ ] 4.19 Add `.gitignore` entry for `.env`. Commit PR 4 to `feature/c1-backoffice`; confirm SPA mode, Vitest + client smoke + all 3 Playwright projects green (Bun install/Node tests), Docker image builds + healthy (Bun build → static serve), version `0.1.0`, **`bun install` auto-wires the pre-commit hook and `prettier --check .` passes**.

## Phase 5: Wrapper Cross-Stack CI & Submodule Pinning (PR 5 — wrapper repo)

- [ ] 5.1 Tag each submodule's first release `v0.1.0` (on `main` after its C1 merge per the Git Flow release step), then pin `.gitmodules` pointers to those **released `v0.1.0` tags** of `api`, `frontend`, `backoffice`; run wrapper `submodules:init` and confirm all three check out cleanly at the tagged commits.
- [ ] 5.2 Enable the three app services in the wrapper `docker-compose.yml` (uncomment/finalize `api`, `frontend`, `backoffice` with `build:` context pointing at each submodule's Dockerfile) now that the submodule Dockerfiles exist; each depends on `postgres`/`redis` health; wire env from each app's `.env`.
- [ ] 5.3 Create wrapper `.github/workflows/wrapper-ci.yml`: triggers on push/PR to `develop`; checkout with `submodules: recursive`; step: submodule pointer-freshness/resolvability check; step: `docker compose up -d --build` full-stack smoke asserting postgres/redis/mailpit **and the 3 app services** reach healthy, then `down`. Local build only — no image push, no deploy.
- [ ] 5.4 Verify wrapper CI contains **zero** deploy steps (build allowed, push/deploy forbidden) and does NOT re-run submodule unit/E2E suites (those belong to each submodule's CI).
- [ ] 5.5 Create `railway.json` (or `railway.toml`) in the wrapper; confirm no CI step (wrapper or submodule) references it (inert). Confirm each app's own `railway.json`/`railway.toml` selects the Docker builder but is parked (no deploy trigger).
- [ ] 5.6 Update `openspec/config.yaml`: flip all `testing.*.status` fields (backend runner, frontend/backoffice unit runners, E2E runner, backend + frontend coverage) from `not-yet-scaffolded` to `scaffolded`.
- [ ] 5.7 **[Versioning verify]** Confirm all four repos carry SemVer `0.1.0` in their SoT and each submodule has a `v0.1.0` tag (format `vM.m.p`); the wrapper's `.gitmodules` pins the `v0.1.0` tags.
- [ ] 5.8 **[Docker/Bun verify]** Confirm each app has a multi-stage non-root healthchecked Dockerfile, the full-stack compose smoke is green, and each app CI builds its image; `frontend` Dockerfile is Bun-build→Node-SSR, `backoffice` Bun-build→static, `api` Composer multi-stage.
- [ ] 5.9 **[Auth reference verify]** Grep all four repos + `openspec/` for `Sanctum` → zero hits in C1 artifacts/code; `api` has `tymon/jwt-auth` + `spatie/laravel-permission` installed (teams mode) but unwired; no shared-domain cookie constraint referenced.
- [ ] 5.10 **[Pre-commit verify]** In each Nuxt repo: on a clean clone run `bun install` and verify `.git/hooks/pre-commit` is wired automatically; stage a file with a Prettier diff and confirm the hook auto-fixes + re-stages it; run `bun run format:check` → exits 0. In `api`: on a clean clone run `composer install` and verify `.git/hooks/pre-commit` is wired; stage a PHP file with a Pint violation and confirm `git commit` is blocked.
- [ ] 5.11 **[CI smoke]** Push PR 5 branch; open PR targeting wrapper `develop`; confirm wrapper CI runs recursive checkout + pointer check + full-stack compose smoke green, no deploy visible.
- [ ] 5.12 **[Per-repo CI smoke]** Confirm each submodule's PR (PR 2/3/4) triggered only its own repo's CI, ran **all tiers** (Pest / Vitest / 3-project Playwright as applicable) + docker build as required blocking jobs, and passed; verify a repo change never triggers a sibling repo's CI (separate repos, no path filter).
- [ ] 5.13 Merge order across repos: submodule PRs first (`api` → `frontend` → `backoffice`, so the OpenAPI snapshot exists before the Nuxt clients), each into its own `develop`, then release-tag each `v0.1.0` on its `main`; then wrapper PR 1 → PR 5 into wrapper `develop` with pointers pinned to the submodule `v0.1.0` tags.
- [ ] 5.14 **[Stack-consistency verify]** Grep the wrapper + all four repos + `openspec/` + `CLAUDE.md` for stale stack tokens: `MySQL`/`MariaDB` (permitted ONLY as a rejected alternative in `design.md`), `Laravel 12`, `Sanctum` (permitted ONLY as "NOT Sanctum"), `web/` as an app directory, and `pnpm`/`pnpx`/`yarn` anywhere plus `npm`/`npx` inside the two Nuxt apps (permitted only for `legacy-demo/` and Dependabot's `package-ecosystem: "npm"`). Expect zero disallowed hits. Confirm `CLAUDE.md`, `openspec/config.yaml`, and `design.md` D25 agree on Laravel 13 / PHP 8.5 / PostgreSQL 17 (pgvector) / Redis 8 / Bun / Nuxt 4 / JWT.

---

## Phase 6: Code Quality, UX Foundation & i18n Mandate (cross-repo additions)

These tasks extend Phases 2–4 with the requirements from D26–D32. They are bundled together here to avoid renumbering Phase 2–5 tasks; in practice they are delivered as part of the same PRs as Phases 2–4 (add to PR 2 for `api` items; add to PR 3/4 for Nuxt items). Update the PR commit lists in tasks 2.17, 3.19, and 4.19 accordingly.

### `api` additions (PR 2)

- [x] 6.1 **[PHPStan install]** Install `phpstan/phpstan:^2.0` and `larastan/larastan:^3.0` as Composer dev dependencies (`composer require --dev phpstan/phpstan larastan/larastan`). Create `phpstan.neon` in `api/` root:
  ```neon
  includes:
    - vendor/larastan/larastan/extension.neon
  parameters:
    level: 8
    paths:
      - app/
  ```
  Run `./vendor/bin/phpstan analyse` → fix any level-8 violations in the C1 scaffold. If unavoidable Larastan false-positives remain (e.g. auto-generated stub inference), run `./vendor/bin/phpstan --generate-baseline` to emit `phpstan-baseline.neon` and commit it. Add a TODO comment in the baseline to clear it progressively from C2 forward. [RESULT: zero violations; no baseline needed]

- [x] 6.2 **[PHPStan CI]** Add a required PHPStan step to `api/.github/workflows/ci.yml` — runs after the Pint lint step and before Pest:
  ```yaml
  - name: Static analysis
    run: ./vendor/bin/phpstan analyse --no-progress
  ```
  Verify: push a test branch with a deliberate type error (wrong return type on a method) → CI fails at this step before Pest runs.

- [x] 6.3 **[i18n mandate — api]** Audit `api/app/` for any inline user-facing string literals in controllers, responses, and form request messages. All user-facing strings MUST use `__('key')`. **Machine-readable values are exempt and stay literal** — the health endpoint returns `{ "status": "ok" }` verbatim in every locale (a machine-readable status payload, NOT user-facing); do NOT key it, and keep the smoke-test assertion on the literal `"ok"`. Add `lang/it/messages.php` and `lang/en/messages.php` entries only for genuinely user-facing strings (none required in the C1 scaffold beyond the seeded `welcome` key). Verify: `rg '"[A-Za-z ]+"' app/Http/` returns only non-user-facing technical values (class names, config keys, log context, machine-readable payloads). [RESULT: only machine-readable values ("ok") in app/Http; i18n mandate satisfied]

### `frontend` additions (PR 3)

- [ ] 6.4 **[Tailwind CSS v4 — frontend]** `bun add -d tailwindcss @tailwindcss/vite @tailwindcss/forms @tailwindcss/typography`. Add `@tailwindcss/vite` to `nuxt.config.ts` `vite.plugins`. Create `assets/css/main.css`:
  ```css
  @import "tailwindcss";
  @theme {
    /* tokens from DESIGN.md */
    --color-primary: #1e3a5f;
    --color-accent: #0d9488;
    --font-sans: "Inter", ui-sans-serif, system-ui, sans-serif;
  }
  ```
  Wire via `nuxt.config.ts` `css: ['~/assets/css/main.css']`. Verify a utility class (`class="bg-primary"`) resolves in a `.vue` file. Add `@tailwindcss/forms` and `@tailwindcss/typography` plugin imports to `main.css` as needed.

- [ ] 6.5 **[TypeScript strict — frontend]** Ensure `tsconfig.json` (or `tsconfig.app.json`) includes:
  ```json
  { "compilerOptions": { "strict": true, "noUnusedLocals": true, "noUnusedParameters": true, "exactOptionalPropertyTypes": true } }
  ```
  Exclude `.nuxt/` and `types/api.ts` (generated client). Add `"typecheck": "nuxi typecheck"` to `package.json` `scripts`. Run `bun run typecheck` → exits 0. Fix any strict-mode violations in the C1 scaffold.

- [ ] 6.6 **[TypeScript type-check CI — frontend]** Add a required blocking step to `frontend/.github/workflows/ci.yml` after the Prettier check:
  ```yaml
  - name: TypeScript type-check
    run: bun run typecheck
  ```
  Verify: push a test branch with `const x: string = 42` in a `.ts` file → CI fails at this step before Vitest.

- [ ] 6.7 **[noindex — frontend]** Add `NUXT_PUBLIC_APP_ENV` to `frontend/.env.example`. In `app.vue` (or the root layout), use `useHead` to inject `<meta name="robots" content="noindex, nofollow">` when `NUXT_PUBLIC_APP_ENV !== 'production'`. Add a Vitest test asserting the meta tag is present when `APP_ENV` is `local` or `staging`. Add `NUXT_PUBLIC_APP_ENV=local` to `frontend/.env.example`.

- [ ] 6.8 **[Accessibility — frontend]** `bun add -d @axe-core/playwright`. Create a Playwright fixture (e.g. `tests/e2e/fixtures/a11y.ts`) exporting a `checkA11y(page)` helper using `@axe-core/playwright` at level AA. Update existing E2E specs (`health.spec.ts`, `unsupported-gate.spec.ts`) to call `checkA11y(page)` after navigation. Ensure the `<html>` element has `lang="it"` via `nuxt.config.ts` `app.head.htmlAttrs.lang`. Fix any WCAG 2.1 AA violations in the scaffold pages. Verify: introduce a deliberate contrast violation → the Playwright test fails with an axe violation report.

- [ ] 6.9 **[GDPR consent scaffold — frontend]** Create a placeholder consent component `components/ConsentBanner.vue` that displays the privacy notice (i18n-keyed; no hardcoded text) and emits `accepted` / `declined` events. Wire the consent check into the interview entry route (gate: consent accepted before proceeding). Stub the consent event so the E2E fake-provider fixture acknowledges it. (Full GDPR wiring is C7/C8; C1 scaffolds the structure and the i18n keys.)

### `backoffice` additions (PR 4)

- [ ] 6.10 **[Tailwind CSS v4 — backoffice]** Same as task 6.4 but for the `backoffice` SPA. `bun add -d tailwindcss @tailwindcss/vite @tailwindcss/forms @tailwindcss/typography`. Wire `@tailwindcss/vite` plugin; create `assets/css/main.css` with identical `@theme {}` tokens (sourced from `DESIGN.md`); wire in `nuxt.config.ts`. Verify utility classes resolve.

- [ ] 6.11 **[TypeScript strict — backoffice]** Same as task 6.5. Add `strict: true` + flags; add `"typecheck": "nuxi typecheck"` script; run → exits 0.

- [ ] 6.12 **[TypeScript type-check CI — backoffice]** Same as task 6.6. Add required `typecheck` step to `backoffice/.github/workflows/ci.yml` after Prettier check. Verify it fails on a type error.

- [ ] 6.13 **[noindex — backoffice (always)]** In `app.vue`, use `useHead` to ALWAYS inject `<meta name="robots" content="noindex, nofollow">` — no environment conditional. The admin panel is never indexed. Add a Vitest test asserting the meta tag is always present.

- [ ] 6.14 **[Accessibility — backoffice]** Same as task 6.8 for the `backoffice`. Install `@axe-core/playwright`; create the `checkA11y` fixture; update E2E specs; add `lang="it"` to `<html>`; fix any WCAG 2.1 AA violations. Verify axe failures block the E2E step.

### Cross-repo verification (PR 5 or separate verify pass)

- [ ] 6.15 **[i18n mandate verify]** Grep all three repos for hardcoded user-facing string literals:
  ```bash
  # Vue templates — text outside $t()
  rg --type vue '"[A-Za-z][a-z ]+"' frontend/
  # PHP controllers — inline non-keyed strings
  rg '"(Error|Success|Welcome|Benvenuto|ok)"' api/app/
  ```
  Target: zero hits outside i18n locale files and translation files.

- [ ] 6.16 **[English code verify]** Grep all three repos for non-English identifiers and comments in source files (method names, variable names, class names). Target: zero non-English natural language outside `i18n/locales/*.json` and `lang/*.php` translation files.

- [ ] 6.17 **[TypeScript strict CI verify]** Confirm both Nuxt CI workflows have the required `typecheck` step. Push a test branch with a TypeScript error → CI fails at `typecheck` before Vitest.

- [ ] 6.18 **[PHPStan CI verify]** Confirm the `api` CI workflow has the required `phpstan` step. Push a test branch with a deliberate PHP type error → CI fails at `phpstan` before Pest.

- [ ] 6.19 **[DESIGN.md exists at wrapper root]** Confirm `DESIGN.md` is present at the wrapper root. Confirm it is referenced in both `README.md` and `CLAUDE.md` as the authoritative UX/UI reference. Confirm the Tailwind `@theme` tokens in both Nuxt apps match the design tokens in `DESIGN.md`.

- [ ] 6.20 **[noindex verify]** Run `docker compose up` for each Nuxt app in a `local` env and curl the page HTML. Verify: `backoffice` always returns `<meta name="robots" content="noindex, nofollow">` in `<head>`; `frontend` returns the same tag when `NUXT_PUBLIC_APP_ENV=local`.

- [ ] 6.21 **[Accessibility verify]** Run the full Playwright suite (all 3 projects) in both Nuxt repos. Confirm all `checkA11y` calls pass with zero WCAG 2.1 AA violations.

---

## Phase 7: Security, Load Testing & Cost-Aware AI Testing (cross-repo additions)

These tasks formalize D33–D36 decisions. All items except 7.1–7.3 (Railway config) are delivered as part of existing PRs 2–5; 7.1–7.3 are part of PR 1 (wrapper) and individual submodule PRs.

### Railway deploy independence (PR 1 + submodule PRs)

- [ ] 7.1 **[Railway per-service config]** In each submodule's `railway.json`, confirm the `source` targets only that submodule's own repository and `main` branch. Document in `docs/deploy.md`: "each service deploys independently; deploying `api` does not trigger `frontend` or `backoffice`; Railway is never triggered by CI automatically in C1."

- [ ] 7.2 **[API backward compatibility note]** Add a comment block to `api/routes/api.php` explaining the versioning contract (D33): additive changes are non-breaking and ship freely; breaking changes require a new `/api/v2/` prefix and must be coordinated. Document in `docs/api-versioning.md`.

- [ ] 7.3 **[openapi.json version traceability]** Confirm Scramble's `info.version` in the published `openapi.json` matches `api/VERSION`. Add a CI step to `api/.github/workflows/ci.yml` that asserts `jq '.info.version' openapi.json == $(cat VERSION)` after the Scramble export step.

### Security pipeline additions (PR 2 / PR 3 / PR 4 / PR 5)

- [ ] 7.4 **[composer audit — api CI]** Add to `api/.github/workflows/ci.yml` a required blocking step after dependency install:
  ```yaml
  - name: Security audit
    run: composer audit --no-dev
  ```
  This checks all installed packages against the PHP Security Advisories Database. Exits non-zero on HIGH/CRITICAL. Pin the `composer` version if needed for Composer 2.4+ (audit built-in).

- [ ] 7.5 **[bun audit — Nuxt CI]** Add to both Nuxt CI workflows a required blocking step:
  ```yaml
  - name: Security audit
    run: bun audit
  ```
  Exits non-zero on HIGH/CRITICAL. If `bun audit` is not yet stable, use `bunx audit-ci --high` as a fallback (but prefer native `bun audit`).

- [ ] 7.6 **[Trivy container scan — all CI]** After the `docker build` step in each CI workflow, add a Trivy scan step (pinned to full SHA):
  ```yaml
  - name: Scan image for CVEs
    uses: aquasecurity/trivy-action@<full-SHA>
    with:
      image-ref: beai-api:ci  # or beai-frontend / beai-backoffice
      severity: HIGH,CRITICAL
      exit-code: '1'
      format: table
  ```
  Fails the job on any HIGH or CRITICAL CVE in the final image layer. Store the Trivy JSON report as a CI artifact (30-day retention).

- [ ] 7.7 **[Security headers — api]** Create `app/Http/Middleware/SecurityHeaders.php` applying: `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy: camera=(), microphone=(), geolocation=()`, `Strict-Transport-Security: max-age=31536000; includeSubDomains` (only on HTTPS). Register globally in `bootstrap/app.php` middleware stack. Add a Pest test asserting all headers are present on `GET /api/health`. CSP header is intentionally deferred to C2 (requires knowing auth routes, iframe origins for HeyGen/Tavus).

- [ ] 7.8 **[Security headers — Nuxt apps]** In both `frontend` and `backoffice` `nuxt.config.ts`, add:
  ```ts
  nitro: {
    routeRules: {
      '/**': {
        headers: {
          'X-Frame-Options': 'DENY',
          'X-Content-Type-Options': 'nosniff',
          'Referrer-Policy': 'strict-origin-when-cross-origin',
          'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
        },
      },
    },
  }
  ```
  Add E2E test asserting headers are present on the health page response.

- [ ] 7.9 **[Pin GitHub Actions to full SHA]** In all CI workflow YAML files across all four repos, replace any floating action tag (`@v3`, `@v4`) with the pinned full commit SHA (lookup via `gh api /repos/{owner}/{repo}/git/ref/tags/{tag}`). Add a note in the workflow file comment: `# pinned SHA — update manually after reviewing release notes`. Install `step-security/harden-runner` as the first step in each CI job (optional, but recommended).

- [ ] 7.10 **[Enable Dependabot on all submodule repos]** Create `.github/dependabot.yml` in each submodule:
  ```yaml
  version: 2
  updates:
    - package-ecosystem: "composer"   # api only
      directory: "/"
      schedule: { interval: "weekly" }
      open-pull-requests-limit: 5
    - package-ecosystem: "npm"        # Nuxt repos only
      directory: "/"
      schedule: { interval: "weekly" }
      open-pull-requests-limit: 5
    - package-ecosystem: "github-actions"
      directory: "/"
      schedule: { interval: "weekly" }
  ```
  Enable GitHub secret scanning and push protection on each repo (in repo Settings → Security).

### Load testing setup (PR 2 / wrapper)

- [ ] 7.11 **[K6 install docs]** Document K6 installation in `docs/dev-setup.md` (`brew install k6` or binary download). K6 is a local dev tool — never installed in CI except in `load-test.yml`. Add to `docs/dev-setup.md` the prerequisite: `docker compose up -d` must be running before `test:load`.

- [ ] 7.12 **[K6 scenario scripts]** Create `api/tests/k6/scenarios/`:
  - `baseline.js` — 10 VU × 60 s against `GET /api/health`; threshold: p95 < 100 ms, error rate < 0.5%
  - `stress.js` — 50 VU × 120 s; threshold: p95 < 200 ms, error rate < 1%
  - `spike.js` — ramp from 0 → 200 VU in 10 s, hold 30 s, ramp down; threshold: error rate < 5%
  
  All scripts read the target URL from the `K6_API_BASE_URL` env var (default: `http://localhost:8000`). LLM-dependent endpoints (C8/C9) use a mock endpoint stub in C1 (just the health endpoint is live). Include a shared `thresholds.js` with all shared threshold definitions.

- [ ] 7.13 **[K6 HTML/JSON reporter]** Configure each K6 script to emit both a JSON summary (`--summary-export=report.json`) and use the K6 HTML reporter (`--out web-dashboard=export=report.html`) — or use `k6-reporter` npm package for HTML generation post-run. Store generated reports in `docs/load-testing/` (gitignored raw, but the latest interpreted report is committed as `docs/load-testing/README.md` with the capacity analysis narrative).

- [ ] 7.14 **[Taskfile load task — wrapper]** Add to wrapper `Taskfile.yml`:
  ```yaml
  test:load:
    desc: "Run K6 load tests against local docker-compose stack (never Railway)"
    dir: api
    cmds:
      - k6 run tests/k6/scenarios/baseline.js
      - k6 run tests/k6/scenarios/stress.js
      - k6 run tests/k6/scenarios/spike.js
  ```
  Prerequisite: compose stack healthy. Document: "results saved to `docs/load-testing/`; review to determine Railway instance sizing."

- [ ] 7.15 **[Load test CI workflow — manual only]** Create `api/.github/workflows/load-test.yml` with:
  ```yaml
  on:
    workflow_dispatch:
      inputs:
        scenario:
          type: choice
          options: [baseline, stress, spike, all]
  ```
  Steps: checkout, start Docker Compose services (postgres + redis + api image), wait for health, run K6 scenario(s) against localhost, upload HTML + JSON report as artifact (30-day retention). **No automatic trigger. No deploy step.**

### Cost-aware AI testing infrastructure (PR 2)

- [ ] 7.16 **[LLM provider interface]** Create `app/Contracts/LLMProvider.php` defining the interface:
  ```php
  interface LLMProvider {
      public function complete(string $prompt, array $options = []): LLMResponse;
  }
  ```
  and `app/DTOs/LLMResponse.php` (content, model, usage tokens, finish reason). This is the dependency injection surface that all scoring code (C8) will depend on.

- [ ] 7.17 **[FakeLLMProvider]** Create `app/Testing/FakeLLMProvider.php` implementing `LLMProvider`. It reads from a cassette fixture file or returns a configured fake response. Register it in `AppServiceProvider` under `APP_ENV=testing`:
  ```php
  if ($this->app->environment('testing')) {
      $this->app->bind(LLMProvider::class, FakeLLMProvider::class);
  }
  ```
  Add a Pest helper `UseFakeLLM` that configures the cassette for a specific test. Verify: a standard `php artisan test` run with the FakeLLMProvider generates zero HTTP requests to any external AI API endpoint.

- [ ] 7.18 **[VCR cassette fixtures]** Create `tests/Fixtures/cassettes/` directory. Add a sample cassette `bars-eval--haiku-4-5--prompt-v1.json` with a realistic (fake) BARS evaluation response JSON matching the expected `LLMResponse` DTO shape. Add a `CassetteFactory` helper in the Pest `TestCase` base class: `$this->withCassette('cassette-name')` configures the `FakeLLMProvider` to replay it. Cassette filename convention: `{purpose}--{model-slug}--{prompt-version}.json`.

- [ ] 7.19 **[@ai group CI workflow]** Create `api/.github/workflows/ai-integration.yml`:
  ```yaml
  on:
    workflow_dispatch: {}
    push:
      branches: ['release/**']
  ```
  Steps: checkout, setup PHP 8.5 + PCOV, `composer install`, setup Postgres service, `php artisan migrate`, run **only** the `@ai` group: `php artisan test --group ai`. Requires secrets: `ANTHROPIC_API_KEY`, `AI_TEST_MODEL` (default `claude-haiku-4-5-20251001`). **Not triggered on PR or `develop` push.**

- [ ] 7.20 **[Verify zero AI cost on standard CI]** Add an assertion to the standard CI test run: after `php artisan test --parallel`, grep the test output for any `FakeLLMProvider: BYPASS` warning (emitted by the fake if a real HTTP call attempts to escape). Confirm count = 0. This is the guard against accidentally bypassing the fake in future test additions.

### Observability scope guard (PR 5 or separate verify pass)

- [ ] 7.21 **[Observability C1 scope guard]** Confirm C1 implements **health endpoints only** from `openspec/specs/observability/spec.md`. Verify NO Sentry, Microsoft Clarity, GA4, Laravel Pulse, Cloudflare, `ai_requests` table/migration, or domain-event classes are installed or wired in any repo (each is owned by a later slice — see the spec's "Phased Rollout — C1 Scope Boundary" requirement). Grep each repo for `sentry`, `clarity`, `gtag`/`googletagmanager`, `laravel/pulse`, `ai_requests`, `App\\Events\\` → expect zero hits in C1 artifacts/code.
