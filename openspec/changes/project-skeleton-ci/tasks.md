# Tasks: Project Skeleton & CI Foundation (C1)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~1 000 – 1 400 additions (Laravel scaffold + Nuxt scaffold + CI yml + tests + docs) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → PR 2 → PR 3 → PR 4 (feature-branch-chain) |
| Delivery strategy | ask-on-risk |
| Chain strategy | pending |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: pending
400-line budget risk: High

### Open Questions Resolved

- **go-task vs Makefile** (design open item): **Decided — go-task** (`Taskfile.yml`). Design D3 chose it; Makefile rejected. No further action needed.
- **Playwright CI placement** (design open item): **Decided — Playwright runs as a step inside the `web` CI job**, after Vitest, with `actions/cache` on `~/.cache/ms-playwright`. Accepts browser-download cost (~130 MB, cached after first run). No separate job needed.

### Suggested Work Units (feature-branch-chain)

| Unit | Goal | Likely PR | Base boundary |
|------|------|-----------|---------------|
| 1 | Monorepo structure: relocate Astro, workspace, Taskfile, compose, docs | PR 1 | `feature/c1-skeleton` tracker branch |
| 2 | Laravel `api/` bootstrap: health, i18n, Pest smoke red→green, coverage config | PR 2 | PR 1 branch |
| 3 | Nuxt `web/` bootstrap: health page, i18n, Vitest smoke red→green, Playwright smoke | PR 3 | PR 2 branch |
| 4 | GitHub Actions CI workflow + openspec/config.yaml update | PR 4 | PR 3 branch |

---

## Phase 1: Monorepo Structure & Local Infrastructure (PR 1)

- [ ] 1.1 Create `feature/c1-skeleton` Git Flow branch from `develop`.
- [ ] 1.2 Move all Astro demo files (`src/`, `astro.config.*`, root `package.json`, `tsconfig.json`, `public/`) into `legacy-demo/`; update `legacy-demo/package.json` name field to `legacy-demo`.
- [ ] 1.3 Verify `legacy-demo/` is independently bootable (`pnpm install && pnpm dev` inside `legacy-demo/`).
- [ ] 1.4 Create root `pnpm-workspace.yaml` listing `web` and `legacy-demo` packages.
- [ ] 1.5 Create root `package.json` with `"packageManager": "pnpm@..."` and convenience scripts (`dev:api`, `dev:web`, `test:api`, `test:web`) that delegate to sub-apps.
- [ ] 1.6 Install go-task (document in `docs/dev-setup.md` or README). Create `Taskfile.yml` at repo root with tasks: `up`, `down`, `test`, `test:api`, `test:web`, `lint`.
- [ ] 1.7 Create `docker-compose.yml` with `mysql:8.4` (named volume `mysql_data`), `redis:7-alpine` (named volume `redis_data`), `axllent/mailpit` (pinned tag); expose standard ports; add `healthcheck` entries for mysql and redis.
- [ ] 1.8 Create `docs/git-flow.md` documenting `main`, `develop`, `feature/*`, `release/*`, `hotfix/*` — purposes, merge targets, and the hotfix rule (cut from `main`; merge to `main` AND `develop`).
- [ ] 1.9 Verify: `docker compose up -d` → mysql + redis reach healthy status, no crash-restart.
- [ ] 1.10 Commit PR 1 to tracker branch; confirm `legacy-demo/` present, no Astro files at repo root.

## Phase 2: Laravel `api/` Bootstrap (PR 2)

- [ ] 2.1 Scaffold Laravel 12 into `api/` via `composer create-project laravel/laravel api`; remove example migration; keep `routes/`, `app/`, `config/`, `lang/`.
- [ ] 2.2 Create `api/.env.example` documenting `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`, `REDIS_HOST`, `REDIS_PORT`, `MAIL_HOST` (bound to compose service names).
- [ ] 2.3 Create `api/lang/it/messages.php` with ≥1 key (e.g. `'welcome' => 'Benvenuto'`) and `api/lang/en/messages.php` with matching key (e.g. `'welcome' => 'Welcome'`).
- [ ] 2.4 **[RED]** Write failing Pest feature test `api/tests/Feature/HealthTest.php`: assert `GET /up` returns 200 — run and confirm test fails (route absent).
- [ ] 2.5 **[GREEN]** Add `routes/api.php` route `GET /up` returning `response()->json(['status' => 'ok'])` with no auth middleware. Run Pest → test passes.
- [ ] 2.6 **[REFACTOR]** Extract health logic to `app/Http/Controllers/HealthController.php`; update route; re-run Pest → still green.
- [ ] 2.7 Configure `phpunit.xml`: set `<coverage>` source to `<include><directory>app/</directory></include>`; add `XDEBUG_MODE=off` env (PCOV path); set `processIsolation="false"`.
- [ ] 2.8 Add `PCOV` extension requirement to `api/composer.json` dev dependencies (or document CI install step); verify `php artisan test --coverage --min=85` passes locally against the authored `app/` scope.
- [ ] 2.9 Add `api/.gitignore` entry for `.env` (not `.env.example`). Verify `api/.env` is never committed.
- [ ] 2.10 Commit PR 2 to PR 1 branch; confirm Pest smoke green + `GET /up` → 200.

## Phase 3: Nuxt 4 `web/` Bootstrap (PR 3)

- [ ] 3.1 Scaffold Nuxt 4 into `web/` via `pnpm dlx nuxi@latest init web`; remove example page; add `web/.env.example` documenting `NUXT_PUBLIC_API_BASE`.
- [ ] 3.2 Install `@nuxtjs/i18n` in `web/`; configure in `nuxt.config.ts`: `defaultLocale: 'it'`, `strategy: 'prefix_except_default'`, `lazy: true`, `langDir: 'i18n/locales/'`.
- [ ] 3.3 Create `web/i18n/locales/it.json` with ≥1 key (e.g. `{"welcome": "Benvenuto"}`) and `web/i18n/locales/en.json` (e.g. `{"welcome": "Welcome"}`).
- [ ] 3.4 **[RED — Vitest]** Install Vitest + Vue Test Utils in `web/`; create `web/tests/unit/health.spec.ts` asserting a `<HealthPage>` component renders text `"ok"` — run and confirm test fails (component absent).
- [ ] 3.5 **[GREEN — Vitest]** Create `web/pages/health.vue` rendering `<p>ok</p>` and returning status 200. Run Vitest → test passes.
- [ ] 3.6 **[REFACTOR]** Add i18n key usage to `HealthPage` or a sibling component; add Vitest test asserting `$t('welcome')` resolves to `'Benvenuto'` (it) and `'Welcome'` (en). Run Vitest → all green.
- [ ] 3.7 Configure `vitest.config.ts` `coverage.include` to `['app/**', 'components/**', 'composables/**', 'pages/**', 'server/**']`; exclude `.nuxt/`, `legacy-demo/`. Set `provider: 'v8'`.
- [ ] 3.8 Verify `pnpm test:unit --coverage` in `web/` reports ≥85% for authored files.
- [ ] 3.9 Install Playwright (`pnpm dlx playwright install --with-deps chromium`); create `web/tests/e2e/health.spec.ts`: navigate to `/health`, assert page contains `"ok"`.
- [ ] 3.10 Run Playwright locally: `pnpm test:e2e` → `/health` page returns 200, smoke passes.
- [ ] 3.11 Add `web/.gitignore` entry for `.env`. Commit PR 3 to PR 2 branch; confirm Vitest + Playwright green.

## Phase 4: GitHub Actions CI Workflow (PR 4)

- [ ] 4.1 Create `.github/workflows/ci.yml`; set `on: [push: branches: [develop], pull_request: branches: [develop]]`; set `on.push.branches` to `develop` only (no `main` trigger).
- [ ] 4.2 Add `paths-filter` step using `dorny/paths-filter@v3` to detect `api/**` and `web/**` changes; expose outputs `api` and `web`.
- [ ] 4.3 Add `php` job: `if: needs.filter.outputs.api == 'true'`; steps: checkout, setup PHP + PCOV, `composer install --no-dev --optimize-autoloader`, PHP Pint lint (`vendor/bin/pint --test`), `php artisan test --parallel`, `php artisan test --coverage --min=85`.
- [ ] 4.4 Add `node` job: `if: needs.filter.outputs.web == 'true'`; steps: checkout, setup pnpm + Node, `pnpm install`, ESLint (`pnpm lint`), Vitest + coverage (`pnpm test:unit --coverage --reporter=default --coverage.thresholds.lines=85`), Playwright (`pnpm test:e2e`) with `~/.cache/ms-playwright` cached.
- [ ] 4.5 Add per-job caches: `~/.composer/cache` for php; `~/.pnpm-store` for node; `~/.cache/ms-playwright` for Playwright.
- [ ] 4.6 Verify workflow file contains **zero** deploy steps, no Railway CLI, no registry push, no webhook call.
- [ ] 4.7 Create `railway.json` (or `railway.toml`) committed to repo; confirm no CI step references it (inert).
- [ ] 4.8 Update `openspec/config.yaml`: flip all five `testing.*.status` fields from `not-yet-scaffolded` to `scaffolded`.
- [ ] 4.9 **[CI Smoke]** Push PR 4 branch to remote; open PR targeting `develop`; confirm: both `php` and `node` jobs triggered (both `api/**` + `web/**` touched in this PR chain), jobs pass, no deploy step visible.
- [ ] 4.10 **[Path-filter smoke]** Create a scratch commit touching only `api/README.md`; confirm only `php` job runs. Create one touching only `web/README.md`; confirm only `node` job runs.
- [ ] 4.11 Commit PR 4 to PR 3 branch. When all four PRs reviewed, merge in order: PR 1 → PR 2 → PR 3 → PR 4 into tracker branch, then tracker → `develop`.
