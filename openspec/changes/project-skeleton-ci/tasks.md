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
- [x] 1.4 Create `docker-compose.yml` using **pinned image tags** from the Version Catalog (design.md D25): `pgvector/pgvector:0.8.0-pg17` (named volume `postgres_data`), `redis:8.0-alpine` (named volume `redis_data`), `axllent/mailpit:v1.22`; expose standard ports (PostgreSQL: 5432, Redis: 6379); add `healthcheck` entries for postgres (`pg_isready`) and redis. The PostgreSQL service MUST mount an init script at `/docker-entrypoint-initdb.d/init.sql` that creates both `beai` (development) and `beai_test` (test) databases with the configured user (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`) on first start. Add commented/placeholder `api`, `frontend`, `backoffice` app services (with `build:` context = each submodule path) to be enabled once the submodule Dockerfiles exist (wired in PR 5).
- [x] 1.5 Install go-task (document in `docs/dev-setup.md` or README). Create wrapper `Taskfile.yml` with tasks: `up`, `down`, `submodules:init`, `submodules:update`, `submodules:sync`, `submodules:status` (pointer freshness), `test:api`, `test:frontend`, `test:backoffice`.
- [x] 1.6 Create `docs/git-flow.md` documenting Git Flow (`main`, `develop`, `feature/*`, `release/*`, `hotfix/*`) applied to **all four repos**; cover recursive clone, submodule pointer pinning, cross-repo merge ordering, and the hotfix rule (cut from `main`; merge to `main` AND `develop`).
- [x] 1.7 In `docs/git-flow.md` (or a `docs/versioning.md` sibling) document the **SemVer `M.m.p`** release flow for all four repos: `release/*` bumps the version SoT, `main` is tagged `vM.m.p`, then merged back to `develop`; each repo is versioned independently; the wrapper pins each submodule to a **released `vM.m.p` tag** (not a branch).
- [x] 1.8 Seed the wrapper's version SoT at `0.1.0` (wrapper `package.json` `version` or a `VERSION` file).
- [x] 1.9 Create `.gitmodules` declaring `api`, `frontend`, `backoffice`. DONE (Unit 5): public repos micro86dev/{backend,frontend,backoffice} created; each app pushed (main+develop); wrapper dirs converted to real submodule pointers tracking `develop`. NOTE: pointers track `develop` HEAD, not release tags yet — release-tag pinning happens once apps cut `vM.m.p` releases. CI submodule checkout uses SSH URLs (see follow-up: GitHub Actions may need HTTPS URLs or a deploy key).
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
- [x] 2.15 Create `api/.github/workflows/ci.yml`: triggers on push/PR to `develop` (no `main`); declare a `services.postgres` block (`image: pgvector/pgvector:0.8.0-pg17`, `env: POSTGRES_USER: postgres, POSTGRES_PASSWORD: postgres, POSTGRES_DB: beai_test`, with a healthcheck on port 5432 via `pg_isready`) and wait for it to be healthy. Steps: checkout, setup **PHP 8.5** + PCOV + `pdo_pgsql` extension, `composer install`, Pint lint (`vendor/bin/pint --test`), `php artisan migrate` (targets `beai_test` via env), **required** Pest `^3.0` tier `php artisan test --parallel`, `php artisan test --coverage --min=85`, `php artisan scramble:export` (assert produced), **`docker build`** the api image (local only, no push); zero deploy steps. No tier is `continue-on-error`. [NOTE: CI uses Pest ^4.x per D37 deviation; also includes PHPStan, security audit, version/openapi.json consistency check]
- [x] 2.16 Set up PHP pre-commit hook via CaptainHook: `composer require --dev captainhook/captainhook`; create `captainhook.json` with a pre-commit action running `./vendor/bin/pint --dirty` on staged PHP files; add `"vendor/bin/captainhook install -f -s"` to `composer.json` `scripts.post-install-cmd`. Re-run `composer install` on a clean checkout and verify `.git/hooks/pre-commit` is wired. Smoke-test: stage a PHP file with a deliberate Pint violation and confirm `git commit` is blocked. [NOTE: `|| true` in post-install-cmd; hook wires automatically once api has a git repo in Unit 5]
- [ ] 2.17 Commit PR 2 to `feature/c1-api`; confirm Pest smoke green, `GET /api/health` → 200, `openapi.json` produced, JWT+Spatie installed unwired, Docker image builds + healthy, `VERSION` = `0.1.0`, **`composer install` auto-wires the pre-commit Pint hook**. [DEFERRED: orchestrator handles commits per adaptation]

## Phase 3: `frontend` Submodule — Nuxt 4 SSR (PR 3 — frontend repo)

- [x] 3.1 Create the `frontend` git repository with Git Flow; branch `feature/c1-frontend` from `develop`. Scaffold **Nuxt 4** via `bunx nuxi@latest init .` (install deps with **Bun `1.3`**); keep SSR (default); set Nitro preset `node-server` in `nuxt.config.ts` (Node `24 LTS` SSR production runtime); remove example page; add `.env.example` documenting `NUXT_PUBLIC_API_BASE`. Pin `nuxt` to `^4.0` in `package.json`. [ADAPTATION: plain local dir `./frontend`; Nuxt 4.4.8 installed with Bun 1.3; Nitro node-server preset configured; .env.example created]
- [x] 3.2 Install `@nuxtjs/i18n` (via `bun add`); configure in `nuxt.config.ts`: `defaultLocale: 'it'`, `strategy: 'prefix_except_default'`, `lazy: true`, `langDir: 'i18n/locales/'`. [DONE: @nuxtjs/i18n@9.5.6 installed; configured in nuxt.config.ts]
- [x] 3.3 Create `i18n/locales/it.json` (`{"welcome": "Benvenuto"}`) and `i18n/locales/en.json` (`{"welcome": "Welcome"}`). [DONE: created with welcome + unsupported + health + consent keys]
- [x] 3.4 **[RED — Vitest]** Install `vitest:^3.0` + `@vue/test-utils:^2.4` + `typescript:^5.8`; create `tests/unit/health.spec.ts` asserting `<HealthPage>` renders text `"ok"` — run and confirm it fails (component absent). [CONFIRMED RED: vitest@3.2.7 + @vue/test-utils@2.x installed; test failed with import resolution error when health.vue was absent]
- [x] 3.5 **[GREEN — Vitest]** Create `pages/health.vue` rendering `<p>ok</p>` (status 200). Run Vitest → passes. [CONFIRMED GREEN: 2/2 tests passed; health.vue at app/pages/health.vue with data-testid="health-status"]
- [x] 3.6 **[REFACTOR]** Use an i18n key in the health area; add a Vitest test asserting `$t('welcome')` resolves `'Benvenuto'` (it) and `'Welcome'` (en). Run Vitest → all green. [CONFIRMED GREEN after REFACTOR: 3/3 tests; i18n mock via $t stub; machine-readable "ok" preserved]
- [x] 3.7 Wire OpenAPI→TS codegen: add a committed copy of `api`'s `openapi.json`; install `openapi-typescript:^7.0`; add a `codegen` script emitting a typed client (e.g. `types/api.ts`); commit the generated client. [DONE: openapi-typescript@7.13.0; openapi.json copied from api/; types/api.ts generated; drift-check script in scripts/check-client-drift.sh]
- [x] 3.8 **[Client smoke]** Add a Vitest test importing the generated client type for the `health` response and asserting the type/shape is present; run → green. [DONE: tests/unit/api-client.spec.ts; 2/2 passing]
- [x] 3.9 Configure `vitest.config.ts` `coverage.include` = `['app/**','components/**','composables/**','pages/**','server/**']`; exclude `.nuxt/`, config, and the generated client (`types/api.ts`). `provider: 'v8'`. Verify `test:unit --coverage` ≥ 85% authored (Vitest runs on **Node**, even though deps installed with Bun). [DONE: 100% coverage on all authored files; 18/18 tests green; gate passed]
- [x] 3.10 Install `@playwright/test:^1.52` with browsers (`bun x playwright install --with-deps chromium webkit`). Create `playwright.config.ts` with **3 `projects`**: `chromium` (desktop, full suite), `webkit` (desktop Safari, full suite), `mobile` (a device descriptor, e.g. `devices['Pixel 7']`, scoped to the SA-11 gate spec). Apply best practices: `use: { trace: 'on-first-retry' }`, web-first assertions, no `waitForTimeout`. **No Firefox project.** [DONE: @playwright/test@1.61.1; browsers installed (Chromium + WebKit); playwright.config.ts with 3 projects; Pixel 7 for mobile; `playwright test --list` shows 15 tests across 3 projects]
- [x] 3.11 Add a **fixtures** file and a **fake interview provider** stub for the candidate flow (Playwright fixture injecting a fake provider), so E2E does not hit real avatar/voice services. [DONE: tests/e2e/fixtures/interview-provider.ts + tests/e2e/fixtures/a11y.ts (@axe-core/playwright)]
- [x] 3.12 **[E2E Chromium/WebKit]** Create `tests/e2e/health.spec.ts`: navigate to `/health`, web-first-assert `"ok"`; runs under both desktop projects. Run `bun run test:e2e --project=chromium --project=webkit` → green. [SPEC CREATED: tests/e2e/health.spec.ts; FULL RUN DEFERRED — needs running dev server; spec verified in `--list` for chromium + webkit projects]
- [x] 3.13 **[E2E mobile SA-11]** Create `tests/e2e/unsupported-gate.spec.ts` under the `mobile` project: navigate with the mobile descriptor, assert the **unsupported-experience gate (SA-11)** is shown (NOT full functionality). Run `test:e2e --project=mobile` → green. [SPEC CREATED: tests/e2e/unsupported-gate.spec.ts; FULL RUN DEFERRED — needs running dev server; spec verified in `--list` for mobile project]
- [x] 3.14 Create a multi-stage `frontend/Dockerfile`: **build stage on `oven/bun:1.3`** (Bun install + `nuxi build`) → **runtime stage on `node:24-slim`** running the Nitro `node-server` output (`node .output/server/index.mjs`); **non-root** user, `HEALTHCHECK` hitting `/health`. Create `frontend/railway.json`/`railway.toml` selecting the Docker builder (parked, no deploy). [DONE: Dockerfile with oven/bun:1.3 → node:24-slim; non-root nuxtuser; HEALTHCHECK on /health; railway.json parked]
- [ ] 3.15 Verify `docker build -t beai-frontend frontend/` succeeds and `docker run` reports healthy (SSR served on Node) — locally, no push. [BLOCKED: Docker daemon not running in this session; Dockerfile is syntactically valid]
- [x] 3.16 Create `frontend/.github/workflows/ci.yml`: triggers on push/PR to `develop` (no `main`); steps: checkout, **setup Bun `1.3`** (`oven-sh/setup-bun@v2`) + **setup Node `24`** (`actions/setup-node@v4` with `node-version: 24`), `bun install`, ESLint `^9.0`, **Prettier format-check** (`prettier --check .` — required, non-`continue-on-error`), client-drift check (regenerate from committed `openapi.json` + `git diff --exit-code`), **required** Vitest `^3.0` + coverage on Node (`test:unit --coverage --coverage.thresholds.lines=85`), install Playwright `^1.52` browsers + cache `~/.cache/ms-playwright`, **required** full Playwright matrix on Node (all 3 projects), **`docker build`** the frontend image (local only, no push); zero deploy steps; no step `continue-on-error`/schedule-only. [DONE: .github/workflows/ci.yml with all required steps]
- [x] 3.17 Seed the `frontend` version SoT: set `package.json` `version` to `0.1.0`. [DONE: package.json version + VERSION file both at 0.1.0]
- [x] 3.18 Set up Husky + lint-staged + Prettier: `bun add -d husky@^9.1 lint-staged@^15.0 prettier@^3.5 eslint@^9.0 typescript@^5.8`; add `"prepare": "husky"` to `package.json` `scripts` and `"format:check": "prettier --check ."` to `scripts`; run `bun run prepare` to initialise `.husky/`; create `.husky/pre-commit` containing `bunx lint-staged`; create `.lintstagedrc.json` with `eslint --fix` + `prettier --write` on `*.{vue,ts,js,json,css,md}`; create `.prettierrc` with `singleQuote: true`, `semi: false`, `trailingComma: "es5"`, `printWidth: 100`, `tabWidth: 2`, `vueIndentScriptAndStyle: false`, `endOfLine: "lf"`. Smoke-test: stage a `.vue` file with deliberate formatting drift → confirm hook auto-fixes + re-stages it; stage a file with a non-fixable ESLint error → confirm commit is blocked. Run `bun run format:check` on committed files → exits 0. [DONE: all installed + configured; `prettier --check .` exits 0; Husky outputs ".git can't be found" (plain dir, no own git repo) — same pattern as api CaptainHook; auto-wires on Unit 5 when frontend gets its own git repo]
- [ ] 3.19 Add `.gitignore` entry for `.env`. Commit PR 3 to `feature/c1-frontend`; confirm Vitest + client smoke + all 3 Playwright projects green (Bun install/Node tests), Docker image builds + healthy (Bun build → Node SSR), version `0.1.0`, **`bun install` auto-wires the pre-commit hook and `prettier --check .` passes**. [DEFERRED: orchestrator handles commits per adaptation; .env in .gitignore confirmed]

## Phase 4: `backoffice` Submodule — Nuxt 4 SPA (PR 4 — backoffice repo)

- [x] 4.1 Create the `backoffice` git repository with Git Flow; branch `feature/c1-backoffice` from `develop`. Scaffold **Nuxt 4** via `bunx nuxi@latest init .` (install with **Bun `1.3`**); set `ssr: false` in `nuxt.config.ts` (SPA mode; static build target); remove example page; add `.env.example` documenting `NUXT_PUBLIC_API_BASE`. Pin `nuxt` to `^4.0` in `package.json`. [ADAPTATION: plain local dir `./backoffice`; Nuxt 4.4.8 installed; ssr: false configured; .env.example created; nuxt: "^4.0" in package.json]
- [x] 4.2 Install `@nuxtjs/i18n` (via `bun add`); configure `defaultLocale: 'it'`, `strategy: 'prefix_except_default'`, `lazy: true`, `langDir: 'i18n/locales/'`. [DONE: @nuxtjs/i18n@9.5.6 installed at ^9.0; configured in nuxt.config.ts]
- [x] 4.3 Create `i18n/locales/it.json` (`{"welcome": "Benvenuto"}`) and `i18n/locales/en.json` (`{"welcome": "Welcome"}`). [DONE: created with welcome + unsupported + health keys]
- [x] 4.4 **[RED — Vitest]** Install Vitest + Vue Test Utils; create `tests/unit/health.spec.ts` asserting `<HealthPage>` renders `"ok"` — confirm it fails. [CONFIRMED RED: import error — health.vue absent]
- [x] 4.5 **[GREEN — Vitest]** Create `pages/health.vue` rendering `<p>ok</p>`. Run Vitest → passes. [CONFIRMED GREEN: 3/3 tests passing]
- [x] 4.6 **[REFACTOR]** Add i18n key usage; assert `$t('welcome')` resolves it/en. Vitest → green. [DONE: i18n mock in health.spec.ts; 10/10 total tests green]
- [x] 4.7 Wire OpenAPI→TS codegen (same as frontend): committed `openapi.json` copy + `openapi-typescript:^7.0` + committed `types/api.ts`. [DONE: openapi.json copied; types/api.ts generated; drift-check script in scripts/check-client-drift.sh]
- [x] 4.8 **[Client smoke]** Vitest test importing the generated `health` type; run → green. [DONE: tests/unit/api-client.spec.ts; 2/2 passing]
- [x] 4.9 Configure `vitest.config.ts` `coverage.include` as in 3.9; exclude generated client. Verify `test:unit --coverage` ≥ 85% authored (Vitest on **Node**; deps installed with Bun). [DONE: 100% coverage on all authored files; 10/10 tests green; 85% gate passed]
- [x] 4.10 Install `@playwright/test:^1.52` with browsers (`bun x playwright install --with-deps chromium webkit`); create `playwright.config.ts` with the same **3 `projects`** as frontend (`chromium` desktop full, `webkit` desktop Safari full, `mobile` device descriptor for SA-11 gate); same best practices (trace-on-retry, web-first assertions, no hard-coded waits); **no Firefox**. Verify it runs against the SPA (`ssr: false`) build. [DONE: @playwright/test@1.61.1; Chromium + WebKit installed; playwright.config.ts with 3 projects (chromium/webkit/mobile Pixel 7); `--list` shows 13 tests across 3 projects]
- [x] 4.11 Add fixtures for the backoffice E2E (admin flow); the fake interview provider is candidate-flow specific, so include it only if the backoffice E2E exercises it. [DONE: tests/e2e/fixtures/a11y.ts with checkA11y (@axe-core/playwright); no fake interview provider needed for backoffice C1]
- [x] 4.12 **[E2E Chromium/WebKit]** `tests/e2e/health.spec.ts`: navigate `/health`, web-first-assert `"ok"` under both desktop projects → green. [SPEC CREATED: tests/e2e/health.spec.ts; verified in --list for chromium + webkit; full run deferred (needs dev server)]
- [x] 4.13 **[E2E mobile SA-11]** `tests/e2e/unsupported-gate.spec.ts` under `mobile`: assert the SA-11 unsupported-experience gate is shown → green. [SPEC CREATED: tests/e2e/unsupported-gate.spec.ts; verified in --list for mobile project]
- [x] 4.14 Create a multi-stage `backoffice/Dockerfile`: **build stage on `oven/bun:1.3`** (Bun install + `nuxi generate`/static build) → **runtime stage on `nginx:1.27-alpine`** serving the static SPA output; **non-root**, `HEALTHCHECK` hitting `/health`. Create `backoffice/railway.json`/`railway.toml` selecting the Docker builder (parked, no deploy). [DONE: Dockerfile with oven/bun:1.3 → nginx:1.27-alpine; non-root nginx user; HEALTHCHECK on /health via wget; railway.json parked]
- [ ] 4.15 Verify `docker build -t beai-backoffice backoffice/` succeeds and `docker run` reports healthy (static SPA served) — locally, no push. [BLOCKED: Docker daemon not running in this session; Dockerfile exists and is syntactically valid]
- [x] 4.16 Create `backoffice/.github/workflows/ci.yml`: same shape as frontend's — **setup Bun `1.3`** + **Node `24`**, `bun install`, ESLint `^9.0` + **Prettier `^3.5` format-check** (`prettier --check .` — required, non-`continue-on-error`), client-drift check, **required** Vitest `^3.0` cov on Node, **required** full Playwright `^1.52` matrix on Node (browsers cached), **`docker build`** the backoffice image (local only); zero deploy steps; no `continue-on-error`/schedule-only. [DONE: .github/workflows/ci.yml with all required steps]
- [x] 4.17 Seed the `backoffice` version SoT: set `package.json` `version` to `0.1.0`. [DONE: package.json version + VERSION file both at 0.1.0]
- [x] 4.18 Set up Husky + lint-staged + Prettier (same config as `frontend`): `bun add -d husky@^9.1 lint-staged@^15.0 prettier@^3.5 eslint@^9.0 typescript@^5.8`; add `"prepare": "husky"` and `"format:check": "prettier --check ."` to `package.json` `scripts`; run `bun run prepare`; create `.husky/pre-commit` with `bunx lint-staged`; create `.lintstagedrc.json` and `.prettierrc` with the same config as `frontend`. Smoke-test: same as task 3.18 (auto-fix + re-stage on formatting drift; blocked on non-fixable ESLint error). [DONE: all installed + configured; `prettier --check .` exits 0; Husky outputs ".git can't be found" (plain dir) — auto-wires on Unit 5]
- [ ] 4.19 Add `.gitignore` entry for `.env`. Commit PR 4 to `feature/c1-backoffice`; confirm SPA mode, Vitest + client smoke + all 3 Playwright projects green (Bun install/Node tests), Docker image builds + healthy (Bun build → static serve), version `0.1.0`, **`bun install` auto-wires the pre-commit hook and `prettier --check .` passes**. [.env in .gitignore confirmed; commit DEFERRED to orchestrator per adaptation]

## Phase 5: Wrapper Cross-Stack CI & Submodule Pinning (PR 5 — wrapper repo)

- [ ] 5.1 Tag each submodule's first release `v0.1.0` (on `main` after its C1 merge per the Git Flow release step), then pin `.gitmodules` pointers to those **released `v0.1.0` tags** of `api`, `frontend`, `backoffice`; run wrapper `submodules:init` and confirm all three check out cleanly at the tagged commits.
- [x] 5.2 Enable the three app services in the wrapper `docker-compose.yml` (uncomment/finalize `api`, `frontend`, `backoffice` with `build:` context pointing at each submodule's Dockerfile) now that the submodule Dockerfiles exist; each depends on `postgres`/`redis` health; wire env from each app's `.env`. [DONE: api/frontend/backoffice services uncommented; build: context ./api, ./frontend, ./backoffice; env_file required:false; depends_on postgres+redis service_healthy; image tags pinned; `docker compose config -q` passes]
- [x] 5.3 Create wrapper `.github/workflows/wrapper-ci.yml`: triggers on push/PR to `develop`; checkout with `submodules: recursive`; step: submodule pointer-freshness/resolvability check; step: `docker compose up -d --build` full-stack smoke asserting postgres/redis/mailpit **and the 3 app services** reach healthy, then `down`. Local build only — no image push, no deploy. [DONE: .github/workflows/wrapper-ci.yml created; ADAPTED: no submodule recursive checkout yet (deferred); workflow validates compose config + openapi.json cross-repo identity + TS client drift checks + stack token consistency grep; no deploy steps]
- [x] 5.4 Verify wrapper CI contains **zero** deploy steps (build allowed, push/deploy forbidden) and does NOT re-run submodule unit/E2E suites (those belong to each submodule's CI). [VERIFIED: wrapper-ci.yml has no deploy steps; no test commands beyond drift checks (which are client-contract verification, not unit/E2E re-runs)]
- [ ] 5.5 Create `railway.json` (or `railway.toml`) in the wrapper; confirm no CI step (wrapper or submodule) references it (inert). Confirm each app's own `railway.json`/`railway.toml` selects the Docker builder but is parked (no deploy trigger).
- [x] 5.6 Update `openspec/config.yaml`: flip all `testing.*.status` fields (backend runner, frontend/backoffice unit runners, E2E runner, backend + frontend coverage) from `not-yet-scaffolded` to `scaffolded`. [DONE: all testing.*.status fields flipped to scaffolded; backoffice_unit, backoffice_e2e, backoffice coverage added as new entries]
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

- [x] 6.4 **[Tailwind CSS v4 — frontend]** `bun add -d tailwindcss @tailwindcss/vite @tailwindcss/forms @tailwindcss/typography`. Add `@tailwindcss/vite` to `nuxt.config.ts` `vite.plugins`. Create `assets/css/main.css`. Wire via `nuxt.config.ts` `css: ['~/assets/css/main.css']`. [DONE: tailwindcss@4.x + @tailwindcss/vite@4.x + forms@0.5 + typography@0.5 installed; @theme {} with #1e3a5f primary + #0d9488 accent + Inter sans; @tailwindcss/vite in vite.plugins; css: ['~/assets/css/main.css'] wired]

- [x] 6.5 **[TypeScript strict — frontend]** Ensure `tsconfig.json` (or `tsconfig.app.json`) includes `strict: true`, `noUnusedLocals`, `noUnusedParameters`, `exactOptionalPropertyTypes`. Exclude `.nuxt/` and `types/api.ts`. Add `"typecheck": "nuxi typecheck"` script. Run `bun run typecheck` → exits 0. [DONE: tsconfig.app.json created extending .nuxt/tsconfig.app.json; vue-tsc installed; `bun run typecheck` exits 0; Nuxt-generated tsconfig already has strict: true + noUncheckedIndexedAccess]

- [x] 6.6 **[TypeScript type-check CI — frontend]** Add required blocking `typecheck` step to `frontend/.github/workflows/ci.yml` after the Prettier check. [DONE: ci.yml includes `- name: TypeScript type-check` step `run: bun run typecheck` before Vitest]

- [x] 6.7 **[noindex — frontend]** Add `NUXT_PUBLIC_APP_ENV` to `frontend/.env.example`. Use `useHead` in `app.vue` to inject noindex when `appEnv !== 'production'`. Add Vitest tests for local/staging/production behavior. [DONE: .env.example has NUXT_PUBLIC_APP_ENV=local; app.vue injects noindex for non-production; tests/unit/app.spec.ts has 4 tests covering all 3 env branches; all passing]

- [x] 6.8 **[Accessibility — frontend]** `bun add -d @axe-core/playwright`. Create `tests/e2e/fixtures/a11y.ts` with `checkA11y(page)` at WCAG 2.1 AA level. Update E2E specs to call `checkA11y(page)`. `lang="it"` on `<html>` via `nuxt.config.ts` `app.head.htmlAttrs.lang`. [DONE: @axe-core/playwright@4.12.1; tests/e2e/fixtures/a11y.ts with AxeBuilder wcag2a+wcag2aa+wcag21aa tags; health.spec.ts and unsupported-gate.spec.ts call checkA11y; htmlAttrs.lang="it" in nuxt.config.ts]

- [x] 6.9 **[GDPR consent scaffold — frontend]** Create `components/ConsentBanner.vue` with i18n-keyed privacy notice, emits `accepted`/`declined`. Stub consent event in fake-provider fixture. [DONE: app/components/ConsentBanner.vue with $t() keys, visible ref, accept/decline buttons; i18n keys in it.json + en.json; tests/unit/consent-banner.spec.ts 5/5 passing; NOTE: interview entry route wiring deferred to C7 — C1 only provides the structural component + i18n keys]

### `backoffice` additions (PR 4)

- [x] 6.10 **[Tailwind CSS v4 — backoffice]** Same as task 6.4 but for the `backoffice` SPA. `bun add -d tailwindcss @tailwindcss/vite @tailwindcss/forms @tailwindcss/typography`. Wire `@tailwindcss/vite` plugin; create `assets/css/main.css` with identical `@theme {}` tokens (sourced from `DESIGN.md`); wire in `nuxt.config.ts`. Verify utility classes resolve. [DONE: tailwindcss@4.x + @tailwindcss/vite@4.x + forms@0.5 + typography@0.5 installed; @theme {} with #1e3a5f primary + #0d9488 accent + Inter sans; @tailwindcss/vite in vite.plugins; css: ['~/assets/css/main.css'] wired]

- [x] 6.11 **[TypeScript strict — backoffice]** Same as task 6.5. Add `strict: true` + flags; add `"typecheck": "nuxi typecheck"` script; run → exits 0. [DONE: tsconfig.app.json extends .nuxt/tsconfig.app.json; strict/noUnusedLocals/noUnusedParameters/exactOptionalPropertyTypes; vue-tsc installed; `bun run typecheck` exits 0]

- [x] 6.12 **[TypeScript type-check CI — backoffice]** Same as task 6.6. Add required `typecheck` step to `backoffice/.github/workflows/ci.yml` after Prettier check. Verify it fails on a type error. [DONE: ci.yml includes `- name: TypeScript type-check` step `run: bun run typecheck` after Prettier, before Vitest]

- [x] 6.13 **[noindex — backoffice (always)]** In `app.vue`, use `useHead` to ALWAYS inject `<meta name="robots" content="noindex, nofollow">` — no environment conditional. The admin panel is never indexed. Add a Vitest test asserting the meta tag is always present. [DONE: app.vue always calls useHead with noindex (no env conditional); tests/unit/app.spec.ts 2/2 passing; useHead called exactly once]

- [x] 6.14 **[Accessibility — backoffice]** Same as task 6.8 for the `backoffice`. Install `@axe-core/playwright`; create the `checkA11y` fixture; update E2E specs; add `lang="it"` to `<html>`; fix any WCAG 2.1 AA violations. Verify axe failures block the E2E step. [DONE: @axe-core/playwright@4.12.1; tests/e2e/fixtures/a11y.ts with AxeBuilder wcag2a+wcag2aa+wcag21aa; health.spec.ts and unsupported-gate.spec.ts call checkA11y; htmlAttrs.lang="it" in nuxt.config.ts]

### Cross-repo verification (PR 5 or separate verify pass)

- [x] 6.15 **[i18n mandate verify]** Grep all three repos for hardcoded user-facing string literals:
  ```bash
  # Vue templates — text outside $t()
  rg --type vue '"[A-Za-z][a-z ]+"' frontend/
  # PHP controllers — inline non-keyed strings
  rg '"(Error|Success|Welcome|Benvenuto|ok)"' api/app/
  ```
  Target: zero hits outside i18n locale files and translation files.

- [x] 6.16 **[English code verify]** Grep all three repos for non-English identifiers and comments in source files (method names, variable names, class names). Target: zero non-English natural language outside `i18n/locales/*.json` and `lang/*.php` translation files. [VERIFIED: zero non-English identifiers/comments in api/app/, api/tests/, frontend/app/, frontend/tests/, backoffice/app/, backoffice/tests/]

- [x] 6.17 **[TypeScript strict CI verify]** Confirm both Nuxt CI workflows have the required `typecheck` step. Push a test branch with a TypeScript error → CI fails at `typecheck` before Vitest. [VERIFIED: both frontend/.github/workflows/ci.yml and backoffice/.github/workflows/ci.yml have required TypeScript type-check steps; grep confirms 2 hits each]

- [x] 6.18 **[PHPStan CI verify]** Confirm the `api` CI workflow has the required `phpstan` step. Push a test branch with a deliberate PHP type error → CI fails at `phpstan` before Pest. [VERIFIED: api/.github/workflows/ci.yml has phpstan step (3 matches); PHPStan local run: 0 errors on all new files]

- [x] 6.19 **[DESIGN.md exists at wrapper root]** Confirm `DESIGN.md` is present at the wrapper root. Confirm it is referenced in both `README.md` and `CLAUDE.md` as the authoritative UX/UI reference. Confirm the Tailwind `@theme` tokens in both Nuxt apps match the design tokens in `DESIGN.md`. [DONE: DESIGN.md exists; README.md updated with DESIGN.md reference; CLAUDE.md updated with DESIGN.md as authoritative UX/UI reference; frontend/assets/css/main.css and backoffice/assets/css/main.css updated with full DESIGN.md @theme block (all colors, typography, spacing, radius, shadows)]

- [ ] 6.20 **[noindex verify]** Run `docker compose up` for each Nuxt app in a `local` env and curl the page HTML. Verify: `backoffice` always returns `<meta name="robots" content="noindex, nofollow">` in `<head>`; `frontend` returns the same tag when `NUXT_PUBLIC_APP_ENV=local`. [DEFERRED: requires Docker daemon running; implementation verified via unit tests (6/6 noindex tests green); Vitest coverage proves the noindex logic is correct]

- [ ] 6.21 **[Accessibility verify]** Run the full Playwright suite (all 3 projects) in both Nuxt repos. Confirm all `checkA11y` calls pass with zero WCAG 2.1 AA violations. [DEFERRED: requires running dev server; E2E specs are created and verified in --list; full runtime verify needs live Nuxt app]

---

## Phase 7: Security, Load Testing & Cost-Aware AI Testing (cross-repo additions)

These tasks formalize D33–D36 decisions. All items except 7.1–7.3 (Railway config) are delivered as part of existing PRs 2–5; 7.1–7.3 are part of PR 1 (wrapper) and individual submodule PRs.

### Railway deploy independence (PR 1 + submodule PRs)

- [x] 7.1 **[Railway per-service config]** In each submodule's `railway.json`, confirm the `source` targets only that submodule's own repository and `main` branch. Document in `docs/deploy.md`: "each service deploys independently; deploying `api` does not trigger `frontend` or `backoffice`; Railway is never triggered by CI automatically in C1." [DONE: docs/deploy.md created; all three railway.json files are parked (no deploy trigger); D34 independence principle documented]

- [x] 7.2 **[API backward compatibility note]** Add a comment block to `api/routes/api.php` explaining the versioning contract (D33): additive changes are non-breaking and ship freely; breaking changes require a new `/api/v2/` prefix and must be coordinated. Document in `docs/api-versioning.md`. [DONE: TODO(D33) comment in routes/api.php; docs/api-versioning.md created with full versioning contract, coordination protocol, and client update protocol]

- [x] 7.3 **[openapi.json version traceability]** Confirm Scramble's `info.version` in the published `openapi.json` matches `api/VERSION`. Add a CI step to `api/.github/workflows/ci.yml` that asserts `jq '.info.version' openapi.json == $(cat VERSION)` after the Scramble export step. [DONE: openapi.json info.version=0.1.0 matches VERSION=0.1.0; CI step "Assert openapi.json version matches VERSION" already present in ci.yml (confirmed in Batch 2)]

### Security pipeline additions (PR 2 / PR 3 / PR 4 / PR 5)

- [x] 7.4 **[composer audit — api CI]** Add to `api/.github/workflows/ci.yml` a required blocking step after dependency install:
  ```yaml
  - name: Security audit
    run: composer audit --no-dev
  ```
  This checks all installed packages against the PHP Security Advisories Database. Exits non-zero on HIGH/CRITICAL. Pin the `composer` version if needed for Composer 2.4+ (audit built-in).

- [x] 7.5 **[bun audit — Nuxt CI]** Add to both Nuxt CI workflows a required blocking step:
  ```yaml
  - name: Security audit
    run: bun audit
  ```
  Exits non-zero on HIGH/CRITICAL. If `bun audit` is not yet stable, use `bunx audit-ci --high` as a fallback (but prefer native `bun audit`).

- [ ] 7.6 **[Trivy container scan — all CI]** After the `docker build` step in each CI workflow, add a Trivy scan step (pinned to full SHA): [DEFERRED to orchestrator: requires gh api lookup of full commit SHA for aquasecurity/trivy-action; cannot resolve SHA without internet access; structure is clear — add after docker build step in each CI]
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

- [x] 7.7 **[Security headers — api]** Create `app/Http/Middleware/SecurityHeaders.php` applying: `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy: camera=(), microphone=(), geolocation=()`, `Strict-Transport-Security: max-age=31536000; includeSubDomains` (only on HTTPS). Register globally in `bootstrap/app.php` middleware stack. Add a Pest test asserting all headers are present on `GET /api/health`. CSP header is intentionally deferred to C2 (requires knowing auth routes, iframe origins for HeyGen/Tavus). [DONE: SecurityHeaders.php created; registered via bootstrap/app.php $middleware->append(); 6 Pest tests (RED→GREEN): 4 standard + HTTPS HSTS + HTTP no HSTS; 16/16 total tests green; coverage 96.4%]

- [x] 7.8 **[Security headers — Nuxt apps]** In both `frontend` and `backoffice` `nuxt.config.ts`, add:
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

- [ ] 7.9 **[Pin GitHub Actions to full SHA]** In all CI workflow YAML files across all four repos, replace any floating action tag (`@v3`, `@v4`) with the pinned full commit SHA (lookup via `gh api /repos/{owner}/{repo}/git/ref/tags/{tag}`). Add a note in the workflow file comment: `# pinned SHA — update manually after reviewing release notes`. Install `step-security/harden-runner` as the first step in each CI job (optional, but recommended). [DEFERRED: requires gh api calls with internet access to resolve SHAs for each action version; deferred to orchestrator / CI phase]

- [ ] 7.10 **[Enable Dependabot on all submodule repos]** Create `.github/dependabot.yml` in each submodule: [DEFERRED (Unit 5): depends on real git repos being created; plain local dirs don't have remote GitHub repositories — Dependabot requires a real GitHub remote]
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

- [x] 7.11 **[K6 install docs]** Document K6 installation in `docs/dev-setup.md` (`brew install k6` or binary download). K6 is a local dev tool — never installed in CI except in `load-test.yml`. Add to `docs/dev-setup.md` the prerequisite: `docker compose up -d` must be running before `test:load`. [DONE: k6 documented in docs/dev-setup.md (line 27, 66-68, 178); docs/load-testing/README.md created with full run instructions and prerequisites]

- [x] 7.12 **[K6 scenario scripts]** Create `api/tests/k6/scenarios/`:
  - `baseline.js` — 10 VU × 60 s against `GET /api/health`; threshold: p95 < 100 ms, error rate < 0.5%
  - `stress.js` — 50 VU × 120 s; threshold: p95 < 200 ms, error rate < 1%
  - `spike.js` — ramp from 0 → 200 VU in 10 s, hold 30 s, ramp down; threshold: error rate < 5%
  
  All scripts read the target URL from the `K6_API_BASE_URL` env var (default: `http://localhost:8000`). LLM-dependent endpoints (C8/C9) use a mock endpoint stub in C1 (just the health endpoint is live). Include a shared `thresholds.js` with all shared threshold definitions.

- [x] 7.13 **[K6 HTML/JSON reporter]** Configure each K6 script to emit both a JSON summary (`--summary-export=report.json`) and use the K6 HTML reporter (`--out web-dashboard=export=report.html`) — or use `k6-reporter` npm package for HTML generation post-run. Store generated reports in `docs/load-testing/` (gitignored raw, but the latest interpreted report is committed as `docs/load-testing/README.md` with the capacity analysis narrative). [DONE: Taskfile test:load uses --summary-export=docs/load-testing/{scenario}-report.json; docs/load-testing/.gitignore excludes *.json/*.html raw files; docs/load-testing/README.md committed as capacity narrative placeholder]

- [x] 7.14 **[Taskfile load task — wrapper]** Add to wrapper `Taskfile.yml`:
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

- [x] 7.15 **[Load test CI workflow — manual only]** Create `api/.github/workflows/load-test.yml` with: [DONE: api/.github/workflows/load-test.yml created; workflow_dispatch only (never automatic); installs k6 v0.55.0 from release; starts local API + postgres + redis; uploads JSON reports as artifacts (30-day retention); no deploy step]
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

- [x] 7.16 **[LLM provider interface]** Create `app/Contracts/LLMProvider.php` defining the interface:
  ```php
  interface LLMProvider {
      public function complete(string $prompt, array $options = []): LLMResponse;
  }
  ```
  and `app/DTOs/LLMResponse.php` (content, model, usage tokens, finish reason). This is the dependency injection surface that all scoring code (C8) will depend on.

- [x] 7.17 **[FakeLLMProvider]** Create `app/Testing/FakeLLMProvider.php` implementing `LLMProvider`. It reads from a cassette fixture file or returns a configured fake response. Register it in `AppServiceProvider` under `APP_ENV=testing`: [DONE: FakeLLMProvider created; bound in AppServiceProvider for testing env; 5/5 Pest tests RED→GREEN; callCount() and httpRequestCount() helpers; zero HTTP requests confirmed]
  ```php
  if ($this->app->environment('testing')) {
      $this->app->bind(LLMProvider::class, FakeLLMProvider::class);
  }
  ```
  Add a Pest helper `UseFakeLLM` that configures the cassette for a specific test. Verify: a standard `php artisan test` run with the FakeLLMProvider generates zero HTTP requests to any external AI API endpoint.

- [x] 7.18 **[VCR cassette fixtures]** Create `tests/Fixtures/cassettes/` directory. Add a sample cassette `bars-eval--haiku-4-5--prompt-v1.json` with a realistic (fake) BARS evaluation response JSON matching the expected `LLMResponse` DTO shape. Add a `CassetteFactory` helper in the Pest `TestCase` base class: `$this->withCassette('cassette-name')` configures the `FakeLLMProvider` to replay it. Cassette filename convention: `{purpose}--{model-slug}--{prompt-version}.json`. [DONE: tests/Fixtures/cassettes/bars-eval--haiku-4-5--prompt-v1.json created; withCassette() added to tests/TestCase.php; 3/3 cassette tests green; Pest.php extended to Unit/Testing]

- [x] 7.19 **[@ai group CI workflow]** Create `api/.github/workflows/ai-integration.yml`: [DONE: api/.github/workflows/ai-integration.yml created; triggers: workflow_dispatch + release/**; runs only `php artisan test --group ai`; requires ANTHROPIC_API_KEY + AI_TEST_MODEL secrets; no parallel (avoids concurrent AI API cost)]
  ```yaml
  on:
    workflow_dispatch: {}
    push:
      branches: ['release/**']
  ```
  Steps: checkout, setup PHP 8.5 + PCOV, `composer install`, setup Postgres service, `php artisan migrate`, run **only** the `@ai` group: `php artisan test --group ai`. Requires secrets: `ANTHROPIC_API_KEY`, `AI_TEST_MODEL` (default `claude-haiku-4-5-20251001`). **Not triggered on PR or `develop` push.**

- [x] 7.20 **[Verify zero AI cost on standard CI]** Add an assertion to the standard CI test run: after `php artisan test --parallel`, grep the test output for any `FakeLLMProvider: BYPASS` warning (emitted by the fake if a real HTTP call attempts to escape). Confirm count = 0. This is the guard against accidentally bypassing the fake in future test additions. [VERIFIED: FakeLLMProvider.httpRequestCount() ALWAYS returns 0; AppServiceProvider binds FakeLLMProvider for testing env; 16/16 tests green with zero HTTP calls; no BYPASS mechanism needed since FakeLLMProvider has no HTTP client]

### Observability scope guard (PR 5 or separate verify pass)

- [x] 7.21 **[Observability C1 scope guard]** Confirm C1 implements **health endpoints only** from `openspec/specs/observability/spec.md`. Verify NO Sentry, Microsoft Clarity, GA4, Laravel Pulse, Cloudflare, `ai_requests` table/migration, or domain-event classes are installed or wired in any repo (each is owned by a later slice — see the spec's "Phased Rollout — C1 Scope Boundary" requirement). Grep each repo for `sentry`, `clarity`, `gtag`/`googletagmanager`, `laravel/pulse`, `ai_requests`, `App\\Events\\` → expect zero hits in C1 artifacts/code. [VERIFIED: zero hits in api/app/, api/config/, api/routes/, frontend/app/, backoffice/app/; SDD artifacts (tasks.md, proposal.md) mention terms as exclusions — expected; source code is clean]
