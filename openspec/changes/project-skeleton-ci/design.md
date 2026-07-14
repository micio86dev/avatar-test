# Design: Project Skeleton & CI Foundation (C1)

## Technical Approach

Restructure the repo root (currently an Astro demo) into a monorepo with three siblings: `api/` (Laravel 12), `web/` (Nuxt 4), `legacy-demo/` (relocated Astro). Two independent toolchains (Composer for PHP, pnpm for JS) coexist; a root `Taskfile`/`package.json` script layer offers one-command orchestration. `docker-compose` provisions MySQL 8 + Redis + Mailpit. Each app ships a health endpoint and a deliberately-failing smoke test proven red→green. One GitHub Actions workflow runs path-filtered PHP and Node jobs in parallel, each enforcing an 85% coverage gate scoped to authored code. No deploy. Realizes proposal capabilities `project-skeleton` and `ci-pipeline`; aligns with the parallel spec's scenarios.

## Architecture Decisions

| # | Decision | Choice | Alternatives rejected | Rationale |
|---|---|---|---|---|
| D1 | Monorepo layout | Sibling dirs `api/`, `web/`, `legacy-demo/`; each self-contained with its own lockfile | Nested `apps/`, git submodules, split repos | Flat matches proposal & CLAUDE.md target dirs; no cross-import so no shared build graph needed |
| D2 | JS package mgmt | pnpm workspace with root `pnpm-workspace.yaml` listing `web` + `legacy-demo` | npm/yarn; no workspace | pnpm is the config-declared runner (`pnpm test:*`); workspace enables root scripts + shared cache |
| D3 | Task orchestration | Root `Taskfile.yml` (go-task) wrapping `up`, `test`, `test:api`, `test:web`, `lint` | Makefile; root npm-only scripts (can't drive Composer cleanly) | One entrypoint spanning PHP+JS+docker; readable, cross-shell |
| D4 | Demo relocation | Move Astro wholesale to `legacy-demo/` (own `package.json`, `node_modules`, config) | Delete; keep at root; extract into `web/` | Kept runnable as C7 port reference; isolated so it never pollutes `web` or CI-authored coverage |
| D5 | Local infra | `docker-compose.yml`: `mysql:8.4`, `redis:7-alpine`, `axllent/mailpit`; pinned tags, named volumes | Sail (Laravel-only), Postgres, real SMTP | Pinned tags fight infra drift (proposal risk); Mailpit catches mail without external deps |
| D6 | PHP coverage driver | PCOV in CI (fast, line coverage); Xdebug only local for debugging | Xdebug in CI | PCOV is markedly faster for the gate; Xdebug reserved for step-debug |
| D7 | Coverage scoping | Restrict to authored code: Pest `--min=85` over `app/` (exclude generated scaffolding); Vitest `coverage.include` = `app/**`, `components/**`, `composables/**`, `pages/**`, `server/**`, excluding `.nuxt/`, config, `legacy-demo/` | Whole-repo coverage | Kills the "gate blocks trivial skeleton" risk; measures real logic only |
| D8 | Env strategy | Per-app `.env.example` (`api/.env.example`, `web/.env.example`); compose injects DB/Redis host = service name | Single root `.env`; committed `.env` | App-local config matches framework norms; service-name networking connects both apps to infra |
| D9 | CI structure | One workflow, two path-filtered jobs (`paths: api/**` vs `web/**`) via `dorny/paths-filter`, run in parallel; per-language caches | Two workflows; monolithic job | Parallelism + skip-untouched-stack = fast PRs; single file simpler to reason about |
| D10 | i18n scaffolding | Laravel `lang/{it,en}`; `@nuxtjs/i18n` lazy locale files `web/i18n/locales/{it,en}.json`, default `it`, `strategy: prefix_except_default` | Eager bundles; no default | Default `it` per domain; lazy = smaller bundles; DB-translatable content (C3) anticipated by keeping UI strings in files, DB text out of scope now |

## Data Flow

    docker-compose ── mysql:8.4 ─┐
                   ├─ redis:7 ───┤
                   └─ mailpit ───┤
                                 ▼
    api/ (Laravel) ──/up──▶ 200        web/ (Nuxt) ──/health──▶ 200
        │  Pest + PCOV                     │  Vitest + Playwright
        └────────────┐        ┌────────────┘
                     ▼        ▼
    GitHub Actions: paths-filter → [php job | node job] ∥ → coverage --min=85 (no deploy)

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `src/`, `astro.config.*`, root `package.json` | Move | Relocate Astro demo into `legacy-demo/` |
| `api/` | Create | Laravel 12 app: `routes` health `/up`, `lang/{it,en}`, Pest, `phpunit.xml` coverage filter, `.env.example` |
| `web/` | Create | Nuxt 4 app: `/health` page, `@nuxtjs/i18n` `{it,en}`, Vitest + Playwright config, `.env.example` |
| `docker-compose.yml` | Create | MySQL 8 + Redis + Mailpit, pinned, named volumes |
| `pnpm-workspace.yaml`, `Taskfile.yml` | Create | JS workspace + root task orchestration |
| `.github/workflows/ci.yml` | Create | Parallel path-filtered PHP/Node jobs, caches, 85% gate, no deploy |
| `railway.json` (or `.toml`) | Create | Committed but gated off (no trigger) |
| `openspec/config.yaml` | Modify | Flip `testing.*.status` to `scaffolded`; keep commands |
| `docs/git-flow.md` | Create | Document Git Flow branch model + protections (informational) |

## Interfaces / Contracts

- Health: `GET /up` (api) and `GET /health` (web) → `200` with `{ "status": "ok" }`.
- Test-harness contract (per app): `lint` → `test` → `test --coverage --min=85`, all green post-C1.
- CI gate contract: PR to `develop` fails if either job's authored-code coverage < 85%.

## Testing Strategy

| Layer | What to Test | Approach |
|-------|-------------|----------|
| Unit (api) | Health route returns 200 | Pest feature test; first written failing (red→green) |
| Unit (web) | Health page + i18n key resolves `it`/`en` | Vitest + Vue Test Utils; first failing then pass |
| E2E (web) | App boots, `/health` reachable | Playwright smoke |
| Integration | `docker-compose up` → both apps boot, connect to MySQL/Redis | Manual/CI service containers |
| Coverage gate | Authored code ≥ 85% both stacks | PCOV / Vitest c8, scoped includes (D7) |

## Migration / Rollout

Pure additive scaffolding on a `feature/*` branch. No data migration. Rollback = revert branch (delete `api/`, `web/`, compose, workflow; restore demo to root). Railway config committed but inert until explicitly requested.

## Open Questions

- [ ] Root task runner: go-task (`Taskfile.yml`) assumed — confirm vs Makefile if go-task not desired as a dev dependency.
- [ ] Playwright in CI (browser download cost) vs unit+E2E split across jobs — resolve in sdd-tasks.
