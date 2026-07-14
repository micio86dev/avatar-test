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
| 2 | `api` | Laravel 12 API-only, health, i18n, Pest smoke red→green (required tier), PCOV coverage, Scramble `openapi.json`, JWT+Spatie packages (unwired), multi-stage Dockerfile, seed `VERSION 0.1.0`, own CI (+ docker build) | PR 2 | `feature/c1-api` (api repo) |
| 3 | `frontend` | Nuxt 4 SSR, health, i18n, Vitest smoke red→green, Playwright 3-project matrix (+ SA-11 gate, best practices), OpenAPI→TS client, Bun-build/Node-SSR Dockerfile, seed `0.1.0`, own CI (all tiers required, Bun install/Node tests, docker build) | PR 3 | `feature/c1-frontend` (frontend repo) |
| 4 | `backoffice` | Nuxt 4 SPA (`ssr: false`), health, i18n, Vitest smoke red→green, Playwright 3-project matrix (+ SA-11 gate), OpenAPI→TS client, Bun-build/static-serve Dockerfile, seed `0.1.0`, own CI (all tiers required, docker build) | PR 4 | `feature/c1-backoffice` (backoffice repo) |
| 5 | wrapper | Wrapper cross-stack CI; bump `.gitmodules` pointers to merged submodule release tags | PR 5 | PR 1 branch (wrapper) |

---

## Phase 1: Wrapper Superproject & Local Infrastructure (PR 1 — wrapper repo)

- [ ] 1.1 Create `feature/c1-skeleton` Git Flow branch from `develop` in the wrapper repo.
- [ ] 1.2 Move all Astro demo files (`src/`, `astro.config.*`, root `package.json`, `tsconfig.json`, `public/`) into `legacy-demo/` (plain folder); update `legacy-demo/package.json` name field to `legacy-demo`.
- [ ] 1.3 Verify `legacy-demo/` is independently bootable (`pnpm install && pnpm dev` inside `legacy-demo/`).
- [ ] 1.4 Create `docker-compose.yml` with `mysql:8.4` (named volume `mysql_data`), `redis:7-alpine` (named volume `redis_data`), `axllent/mailpit` (pinned tag); expose standard ports; add `healthcheck` entries for mysql and redis. Add commented/placeholder `api`, `frontend`, `backoffice` app services (with `build:` context = each submodule path) to be enabled once the submodule Dockerfiles exist (wired in PR 5).
- [ ] 1.5 Install go-task (document in `docs/dev-setup.md` or README). Create wrapper `Taskfile.yml` with tasks: `up`, `down`, `submodules:init`, `submodules:update`, `submodules:sync`, `submodules:status` (pointer freshness), `test:api`, `test:frontend`, `test:backoffice`.
- [ ] 1.6 Create `docs/git-flow.md` documenting Git Flow (`main`, `develop`, `feature/*`, `release/*`, `hotfix/*`) applied to **all four repos**; cover recursive clone, submodule pointer pinning, cross-repo merge ordering, and the hotfix rule (cut from `main`; merge to `main` AND `develop`).
- [ ] 1.7 In `docs/git-flow.md` (or a `docs/versioning.md` sibling) document the **SemVer `M.m.p`** release flow for all four repos: `release/*` bumps the version SoT, `main` is tagged `vM.m.p`, then merged back to `develop`; each repo is versioned independently; the wrapper pins each submodule to a **released `vM.m.p` tag** (not a branch).
- [ ] 1.8 Seed the wrapper's version SoT at `0.1.0` (wrapper `package.json` `version` or a `VERSION` file).
- [ ] 1.9 Create `.gitmodules` declaring `api`, `frontend`, `backoffice` (URLs/paths; pointers filled in PR 5 once submodule repos have release tags).
- [ ] 1.10 Verify: `docker compose up -d` → mysql + redis + mailpit reach healthy status, no crash-restart.
- [ ] 1.11 Commit PR 1 to `feature/c1-skeleton`; confirm `legacy-demo/` present, no Astro files at wrapper root, versioning documented, wrapper seeded `0.1.0`.

## Phase 2: `api` Submodule — Laravel 12 API-only + Scramble (PR 2 — api repo)

- [ ] 2.1 Create the `api` git repository with Git Flow (`main`/`develop`); branch `feature/c1-api` from `develop`. Scaffold Laravel 12 via `composer create-project laravel/laravel .`; remove example migration; keep `routes/`, `app/`, `config/`, `lang/`.
- [ ] 2.2 Configure API-only posture: ensure `routes/api.php` is the surface; no Blade views required for C1.
- [ ] 2.3 Create `api/.env.example` documenting `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`, `REDIS_HOST`, `REDIS_PORT`, `MAIL_HOST` (bound to wrapper compose service names / host ports).
- [ ] 2.4 Create `lang/it/messages.php` (`'welcome' => 'Benvenuto'`) and `lang/en/messages.php` (`'welcome' => 'Welcome'`).
- [ ] 2.5 **[RED]** Write failing Pest feature test `tests/Feature/HealthTest.php`: assert `GET /api/health` returns 200 with `{ "status": "ok" }` — run and confirm it fails (route absent).
- [ ] 2.6 **[GREEN]** Add `routes/api.php` route `GET /api/health` returning `response()->json(['status' => 'ok'])`, no auth middleware. Run Pest → passes.
- [ ] 2.7 **[REFACTOR]** Extract to `app/Http/Controllers/HealthController.php`; update route; re-run Pest → still green.
- [ ] 2.8 Configure `phpunit.xml`: `<coverage>` source `<include><directory>app/</directory></include>`; add `XDEBUG_MODE=off` (PCOV path); `processIsolation="false"`. Add PCOV to dev deps or document CI install; verify `php artisan test --coverage --min=85` passes against `app/`.
- [ ] 2.9 Install **Scramble** (`composer require dedoc/scramble`); publish config; verify `openapi.json` is generated (e.g. `php artisan scramble:export`) and documents `GET /api/health`. Commit `openapi.json` snapshot.
- [ ] 2.10 Install auth packages (unwired, auth is C2): `composer require tymon/jwt-auth spatie/laravel-permission`; publish their configs; enable Spatie **teams mode** in config (`'teams' => true`); do NOT add guards/middleware/routes. Add a `// TODO(C2)` note that Spatie authorization roles (admin/operator/viewer) are NOT BEAI org roles (ICO/FLL/MLL/BUL/SRX).
- [ ] 2.11 Add `.gitignore` entry for `.env` (not `.env.example`); verify `.env` is never committed. (Auth env keys like `JWT_SECRET` documented in `.env.example` as C2 placeholders, unused in C1.)
- [ ] 2.12 Create a multi-stage `api/Dockerfile` (Composer/PHP-FPM build stage → slim runtime), **non-root** user, `HEALTHCHECK` hitting `/api/health`; keep the final image small. Create `api/railway.json`/`railway.toml` selecting the Docker builder (parked, no deploy).
- [ ] 2.13 Verify `docker build -t beai-api api/` succeeds and `docker run` reports the container healthy (health probe green) — locally, no push.
- [ ] 2.14 Seed the `api` version SoT: create `VERSION` file containing `0.1.0` (Composer has no standard app `version` slot; keep `composer.json` aligned if a `version` field is used).
- [ ] 2.15 Create `api/.github/workflows/ci.yml`: triggers on push/PR to `develop` (no `main`); steps: checkout, setup PHP + PCOV, `composer install`, Pint lint (`vendor/bin/pint --test`), **required** Pest tier `php artisan test --parallel`, `php artisan test --coverage --min=85`, `php artisan scramble:export` (assert produced), **`docker build`** the api image (local only, no push); zero deploy steps. No tier is `continue-on-error`.
- [ ] 2.16 Commit PR 2 to `feature/c1-api`; confirm Pest smoke green, `GET /api/health` → 200, `openapi.json` produced, JWT+Spatie installed unwired, Docker image builds + healthy, `VERSION` = `0.1.0`.

## Phase 3: `frontend` Submodule — Nuxt 4 SSR (PR 3 — frontend repo)

- [ ] 3.1 Create the `frontend` git repository with Git Flow; branch `feature/c1-frontend` from `develop`. Scaffold Nuxt 4 via `bunx nuxi@latest init .` (install deps with **Bun**); keep SSR (default); set Nitro preset `node-server` in `nuxt.config.ts` (Node SSR production runtime); remove example page; add `.env.example` documenting `NUXT_PUBLIC_API_BASE`.
- [ ] 3.2 Install `@nuxtjs/i18n` (via `bun add`); configure in `nuxt.config.ts`: `defaultLocale: 'it'`, `strategy: 'prefix_except_default'`, `lazy: true`, `langDir: 'i18n/locales/'`.
- [ ] 3.3 Create `i18n/locales/it.json` (`{"welcome": "Benvenuto"}`) and `i18n/locales/en.json` (`{"welcome": "Welcome"}`).
- [ ] 3.4 **[RED — Vitest]** Install Vitest + Vue Test Utils; create `tests/unit/health.spec.ts` asserting `<HealthPage>` renders text `"ok"` — run and confirm it fails (component absent).
- [ ] 3.5 **[GREEN — Vitest]** Create `pages/health.vue` rendering `<p>ok</p>` (status 200). Run Vitest → passes.
- [ ] 3.6 **[REFACTOR]** Use an i18n key in the health area; add a Vitest test asserting `$t('welcome')` resolves `'Benvenuto'` (it) and `'Welcome'` (en). Run Vitest → all green.
- [ ] 3.7 Wire OpenAPI→TS codegen: add a committed copy of `api`'s `openapi.json`; install `openapi-typescript`; add a `codegen` script emitting a typed client (e.g. `types/api.ts`); commit the generated client.
- [ ] 3.8 **[Client smoke]** Add a Vitest test importing the generated client type for the `health` response and asserting the type/shape is present; run → green.
- [ ] 3.9 Configure `vitest.config.ts` `coverage.include` = `['app/**','components/**','composables/**','pages/**','server/**']`; exclude `.nuxt/`, config, and the generated client (`types/api.ts`). `provider: 'v8'`. Verify `test:unit --coverage` ≥ 85% authored (Vitest runs on **Node**, even though deps installed with Bun).
- [ ] 3.10 Install Playwright with browsers (`pnpm dlx playwright install --with-deps chromium webkit`). Create `playwright.config.ts` with **3 `projects`**: `chromium` (desktop, full suite), `webkit` (desktop Safari, full suite), `mobile` (a device descriptor, e.g. `devices['Pixel 7']`, scoped to the SA-11 gate spec). Apply best practices: `use: { trace: 'on-first-retry' }`, web-first assertions, no `waitForTimeout`. **No Firefox project.**
- [ ] 3.11 Add a **fixtures** file and a **fake interview provider** stub for the candidate flow (Playwright fixture injecting a fake provider), so E2E does not hit real avatar/voice services.
- [ ] 3.12 **[E2E Chromium/WebKit]** Create `tests/e2e/health.spec.ts`: navigate to `/health`, web-first-assert `"ok"`; runs under both desktop projects. Run `pnpm test:e2e --project=chromium --project=webkit` → green.
- [ ] 3.13 **[E2E mobile SA-11]** Create `tests/e2e/unsupported-gate.spec.ts` under the `mobile` project: navigate with the mobile descriptor, assert the **unsupported-experience gate (SA-11)** is shown (NOT full functionality). Run `test:e2e --project=mobile` → green.
- [ ] 3.14 Create a multi-stage `frontend/Dockerfile`: **build stage on `oven/bun`** (Bun install + `nuxi build`) → **runtime stage on `node`** (e.g. `node:22-slim`) running the Nitro `node-server` output (`node .output/server/index.mjs`); **non-root** user, `HEALTHCHECK` hitting `/health`. Create `frontend/railway.json`/`railway.toml` selecting the Docker builder (parked, no deploy).
- [ ] 3.15 Verify `docker build -t beai-frontend frontend/` succeeds and `docker run` reports healthy (SSR served on Node) — locally, no push.
- [ ] 3.16 Create `frontend/.github/workflows/ci.yml`: triggers on push/PR to `develop` (no `main`); steps: checkout, **setup Bun** (`oven-sh/setup-bun`) + **setup Node**, `bun install`, ESLint, client-drift check (regenerate from committed `openapi.json` + `git diff --exit-code`), **required** Vitest + coverage on Node (`test:unit --coverage --coverage.thresholds.lines=85`), install browsers + cache `~/.cache/ms-playwright`, **required** full Playwright matrix on Node (all 3 projects), **`docker build`** the frontend image (local only, no push); zero deploy steps; no step `continue-on-error`/schedule-only.
- [ ] 3.17 Seed the `frontend` version SoT: set `package.json` `version` to `0.1.0`.
- [ ] 3.18 Add `.gitignore` entry for `.env`. Commit PR 3 to `feature/c1-frontend`; confirm Vitest + client smoke + all 3 Playwright projects green (Bun install/Node tests), Docker image builds + healthy (Bun build → Node SSR), version `0.1.0`.

## Phase 4: `backoffice` Submodule — Nuxt 4 SPA (PR 4 — backoffice repo)

- [ ] 4.1 Create the `backoffice` git repository with Git Flow; branch `feature/c1-backoffice` from `develop`. Scaffold Nuxt 4 via `bunx nuxi@latest init .` (install with **Bun**); set `ssr: false` in `nuxt.config.ts` (SPA mode; static build target); remove example page; add `.env.example` documenting `NUXT_PUBLIC_API_BASE`.
- [ ] 4.2 Install `@nuxtjs/i18n` (via `bun add`); configure `defaultLocale: 'it'`, `strategy: 'prefix_except_default'`, `lazy: true`, `langDir: 'i18n/locales/'`.
- [ ] 4.3 Create `i18n/locales/it.json` (`{"welcome": "Benvenuto"}`) and `i18n/locales/en.json` (`{"welcome": "Welcome"}`).
- [ ] 4.4 **[RED — Vitest]** Install Vitest + Vue Test Utils; create `tests/unit/health.spec.ts` asserting `<HealthPage>` renders `"ok"` — confirm it fails.
- [ ] 4.5 **[GREEN — Vitest]** Create `pages/health.vue` rendering `<p>ok</p>`. Run Vitest → passes.
- [ ] 4.6 **[REFACTOR]** Add i18n key usage; assert `$t('welcome')` resolves it/en. Vitest → green.
- [ ] 4.7 Wire OpenAPI→TS codegen (same as frontend): committed `openapi.json` copy + `openapi-typescript` + committed `types/api.ts`.
- [ ] 4.8 **[Client smoke]** Vitest test importing the generated `health` type; run → green.
- [ ] 4.9 Configure `vitest.config.ts` `coverage.include` as in 3.9; exclude generated client. Verify `test:unit --coverage` ≥ 85% authored (Vitest on **Node**; deps installed with Bun).
- [ ] 4.10 Install Playwright with browsers (`chromium webkit`); create `playwright.config.ts` with the same **3 `projects`** as frontend (`chromium` desktop full, `webkit` desktop Safari full, `mobile` device descriptor for SA-11 gate); same best practices (trace-on-retry, web-first assertions, no hard-coded waits); **no Firefox**. Verify it runs against the SPA (`ssr: false`) build.
- [ ] 4.11 Add fixtures for the backoffice E2E (admin flow); the fake interview provider is candidate-flow specific, so include it only if the backoffice E2E exercises it.
- [ ] 4.12 **[E2E Chromium/WebKit]** `tests/e2e/health.spec.ts`: navigate `/health`, web-first-assert `"ok"` under both desktop projects → green.
- [ ] 4.13 **[E2E mobile SA-11]** `tests/e2e/unsupported-gate.spec.ts` under `mobile`: assert the SA-11 unsupported-experience gate is shown → green.
- [ ] 4.14 Create a multi-stage `backoffice/Dockerfile`: **build stage on `oven/bun`** (Bun install + `nuxi generate`/static build) → **runtime stage** serving the static SPA output (e.g. `nginx:alpine` or a minimal node static server), **non-root**, `HEALTHCHECK` hitting `/health`. Create `backoffice/railway.json`/`railway.toml` selecting the Docker builder (parked, no deploy).
- [ ] 4.15 Verify `docker build -t beai-backoffice backoffice/` succeeds and `docker run` reports healthy (static SPA served) — locally, no push.
- [ ] 4.16 Create `backoffice/.github/workflows/ci.yml`: same shape as frontend's — **setup Bun + Node**, `bun install`, lint, client-drift check, **required** Vitest cov on Node, **required** full Playwright matrix on Node (browsers cached), **`docker build`** the backoffice image (local only); zero deploy steps; no `continue-on-error`/schedule-only.
- [ ] 4.17 Seed the `backoffice` version SoT: set `package.json` `version` to `0.1.0`.
- [ ] 4.18 Add `.gitignore` entry for `.env`. Commit PR 4 to `feature/c1-backoffice`; confirm SPA mode, Vitest + client smoke + all 3 Playwright projects green (Bun install/Node tests), Docker image builds + healthy (Bun build → static serve), version `0.1.0`.

## Phase 5: Wrapper Cross-Stack CI & Submodule Pinning (PR 5 — wrapper repo)

- [ ] 5.1 Tag each submodule's first release `v0.1.0` (on `main` after its C1 merge per the Git Flow release step), then pin `.gitmodules` pointers to those **released `v0.1.0` tags** of `api`, `frontend`, `backoffice`; run wrapper `submodules:init` and confirm all three check out cleanly at the tagged commits.
- [ ] 5.2 Enable the three app services in the wrapper `docker-compose.yml` (uncomment/finalize `api`, `frontend`, `backoffice` with `build:` context pointing at each submodule's Dockerfile) now that the submodule Dockerfiles exist; each depends on `mysql`/`redis` health; wire env from each app's `.env`.
- [ ] 5.3 Create wrapper `.github/workflows/wrapper-ci.yml`: triggers on push/PR to `develop`; checkout with `submodules: recursive`; step: submodule pointer-freshness/resolvability check; step: `docker compose up -d --build` full-stack smoke asserting mysql/redis/mailpit **and the 3 app services** reach healthy, then `down`. Local build only — no image push, no deploy.
- [ ] 5.4 Verify wrapper CI contains **zero** deploy steps (build allowed, push/deploy forbidden) and does NOT re-run submodule unit/E2E suites (those belong to each submodule's CI).
- [ ] 5.5 Create `railway.json` (or `railway.toml`) in the wrapper; confirm no CI step (wrapper or submodule) references it (inert). Confirm each app's own `railway.json`/`railway.toml` selects the Docker builder but is parked (no deploy trigger).
- [ ] 5.6 Update `openspec/config.yaml`: flip all `testing.*.status` fields (backend runner, frontend/backoffice unit runners, E2E runner, backend + frontend coverage) from `not-yet-scaffolded` to `scaffolded`.
- [ ] 5.7 **[Versioning verify]** Confirm all four repos carry SemVer `0.1.0` in their SoT and each submodule has a `v0.1.0` tag (format `vM.m.p`); the wrapper's `.gitmodules` pins the `v0.1.0` tags.
- [ ] 5.8 **[Docker/Bun verify]** Confirm each app has a multi-stage non-root healthchecked Dockerfile, the full-stack compose smoke is green, and each app CI builds its image; `frontend` Dockerfile is Bun-build→Node-SSR, `backoffice` Bun-build→static, `api` Composer multi-stage.
- [ ] 5.9 **[Auth reference verify]** Grep all four repos + `openspec/` for `Sanctum` → zero hits in C1 artifacts/code; `api` has `tymon/jwt-auth` + `spatie/laravel-permission` installed (teams mode) but unwired; no shared-domain cookie constraint referenced.
- [ ] 5.10 **[CI smoke]** Push PR 5 branch; open PR targeting wrapper `develop`; confirm wrapper CI runs recursive checkout + pointer check + full-stack compose smoke green, no deploy visible.
- [ ] 5.11 **[Per-repo CI smoke]** Confirm each submodule's PR (PR 2/3/4) triggered only its own repo's CI, ran **all tiers** (Pest / Vitest / 3-project Playwright as applicable) + docker build as required blocking jobs, and passed; verify a repo change never triggers a sibling repo's CI (separate repos, no path filter).
- [ ] 5.12 Merge order across repos: submodule PRs first (`api` → `frontend` → `backoffice`, so the OpenAPI snapshot exists before the Nuxt clients), each into its own `develop`, then release-tag each `v0.1.0` on its `main`; then wrapper PR 1 → PR 5 into wrapper `develop` with pointers pinned to the submodule `v0.1.0` tags.
