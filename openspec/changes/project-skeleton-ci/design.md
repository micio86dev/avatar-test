# Design: Project Skeleton & CI Foundation (C1)

## Technical Approach

Turn the repo root (currently an Astro demo) into a **wrapper superproject** that
holds `docs/`, `openspec/`, `CLAUDE.md`, `docker-compose.yml`, a wrapper
`Taskfile.yml`/scripts, `.gitmodules`, and a cross-stack CI workflow — plus the
relocated Astro demo in `legacy-demo/` (plain folder, reference). It declares
**three git submodules**, each a standalone repository with its own Git Flow,
toolchain, `.env.example`, test harness, and CI:

- **`api`** — Laravel 12, **API-only** (no Blade). **Scramble** publishes
  `openapi.json`. Pest + PCOV coverage.
- **`frontend`** — Nuxt 4 (Vue 3) **SSR**, `@nuxtjs/i18n` (it/en). Vitest + Vue
  Test Utils + Playwright. Codegens a typed TS client from `api`'s `openapi.json`.
- **`backoffice`** — Nuxt 4 (Vue 3) **SPA** (`ssr: false`), `@nuxtjs/i18n`
  (it/en). Vitest + Vue Test Utils + Playwright. Same codegen.

Each app ships a **multi-stage production-grade Dockerfile** (small final image,
non-root, healthcheck); `docker-compose` (wrapper) provisions MySQL 8 + Redis +
Mailpit **plus the three app services** built from those Dockerfiles for local
dev. **Railway builds via Docker** so the local image equals prod (Railway config
parked, no deploy). The toolchain is **Bun-hybrid**: Bun for install/dev/build of
both Nuxt apps, Node for the `frontend` SSR production runtime (Nitro
`node-server`) and for the Vitest/Playwright runners. Each app ships a health
endpoint and a deliberately-failing smoke test proven red→green. **CI is
per-repo**: each submodule owns a workflow (lint + all test tiers + 85% gate +
Docker image build); the wrapper owns a cross-stack workflow (recursive clone +
pointer check + compose smoke). Because the stacks live in separate repos,
monorepo path-filtering is gone — replaced by per-repo CI. No deploy. **Auth is
JWT (`tymon/jwt-auth`) + `spatie/laravel-permission` teams mode, not Sanctum** —
referenced/noted here but implemented in C2. Realizes proposal capabilities
`project-skeleton` and `ci-pipeline`; aligns with the parallel specs' scenarios.

## Architecture Decisions

| # | Decision | Choice | Alternatives rejected | Rationale |
|---|---|---|---|---|
| D1 | Repo topology | Wrapper superproject + 3 git submodules (`api`, `frontend`, `backoffice`); `legacy-demo/` plain folder | Single monorepo (old plan); split repos with no wrapper; nested `apps/` | CLAUDE.md/ROADMAP.md make the wrapper+submodules authoritative; independent Git Flow ×4, independent deploy units later, clean per-repo CI |
| D2 | Two Nuxt apps | `frontend` = SSR (candidate); `backoffice` = SPA `ssr: false` (admin); both `@nuxtjs/i18n` it/en | One combined Nuxt app with route groups | Different render modes + auth models (candidate magic-link JWT vs admin bearer JWT — see D13); separate repos keep bundles and CI isolated (C7/C8 land in `frontend`, C11 in `backoffice`) |
| D3 | API shape | Laravel 12 **API-only** + Scramble `dedoc/scramble` publishing `openapi.json` | Blade/Inertia UI in Laravel; hand-written OpenAPI; API Platform | Stateless API scales horizontally; Scramble derives the spec from routes/types so it stays honest; no server-rendered UI in Laravel |
| D4 | API contract / type sync | Scramble emits `openapi.json`; `frontend` + `backoffice` each run `openapi-typescript` to codegen + commit a typed client | Hand-maintained TS types per repo; shared npm types package; tRPC (not PHP-compatible) | Single source of truth (the API) keeps 3 repos in sync by construction; committed client is diffable and CI-checkable for drift |
| D5 | Submodule wiring | `.gitmodules` pins each repo; wrapper `Taskfile.yml` `init`/`update`/`sync`/`status` tasks; clone/CI `--recursive` | Manual submodule commands only; monorepo; `git subtree` | Explicit tasks reduce detached-HEAD/forgotten-`--recursive` friction; pointer-freshness check catches stale pins in CI |
| D6 | Demo relocation | Move Astro wholesale to `legacy-demo/` as a **plain folder** (not a submodule) | Delete; keep at root; make it a 4th submodule | Kept runnable as a C7 port reference; plain folder avoids submodule overhead for throwaway reference code; isolated so it never pollutes app coverage |
| D7 | Local infra | Wrapper `docker-compose.yml`: `mysql:8.4`, `redis:7-alpine`, `axllent/mailpit`; pinned tags, named volumes, healthchecks | Sail (Laravel-only); Postgres; per-repo compose | One infra for all apps at the wrapper level; pinned tags fight drift; Mailpit catches mail without external deps |
| D8 | PHP coverage driver | PCOV in `api` CI (fast line coverage); Xdebug only local | Xdebug in CI | PCOV is markedly faster for the gate |
| D9 | Coverage scoping (per repo) | `api`: Pest `--min=85` over `app/`. Nuxt apps: Vitest `coverage.include` = `app/**`, `components/**`, `composables/**`, `pages/**`, `server/**`; exclude `.nuxt/`, config, and the **generated TS client** | Whole-repo coverage; measuring generated client | Kills the "gate blocks trivial skeleton" risk; the generated client is not authored code and must not inflate or dilute the gate |
| D10 | Env strategy | Per-submodule `.env.example`; wrapper compose exposes services on host; each app's `.env` points at compose service names / host ports | Single root `.env`; committed `.env` | App-local config matches framework norms; submodules stay independently bootable |
| D11 | CI structure | **Per-repo workflows** (each submodule: lint + test + coverage + [OpenAPI or client-codegen check]); **wrapper workflow**: `--recursive` checkout + pointer check + compose smoke | One monorepo workflow with `dorny/paths-filter`; two workflows in one repo | Per-repo CI is the natural fit for submodules — a repo's CI runs only when it changes; no path-filter needed; wrapper CI guards cross-stack integrity |
| D12 | i18n scaffolding | `api`: Laravel `lang/{it,en}`. `frontend` + `backoffice`: `@nuxtjs/i18n` lazy locale files `i18n/locales/{it,en}.json`, default `it`, `strategy: prefix_except_default` | Eager bundles; no default; single shared locale package | Default `it` per domain; lazy = smaller bundles; each Nuxt repo owns its own locale files (DB-translatable content deferred to C3) |
| D13 | Auth model note (JWT, not Sanctum; not built in C1) | **JWT (`tymon/jwt-auth`)** — bearer access + refresh tokens (short expiry, **Redis denylist** for revocation) for backoffice user auth; **short-lived JWT** for the candidate magic-link; **JWT client token / API-key** for external M2M. RBAC via **`spatie/laravel-permission`** in **teams mode** (`team_id = organization_id`). Because JWT is bearer/stateless, **cross-origin is free** — no shared-parent-domain cookie constraint; `backoffice` SPA and `api` may be different origins | **Sanctum** SPA cookies (user dislikes it) + shared-parent-domain cookie constraint (removed); session-based auth | Bearer JWT removes the cookie/domain coupling entirely (the old constraint is gone); Spatie teams mode gives per-org RBAC. ⚠️ Spatie *authorization* roles (admin/operator/viewer) are NOT the BEAI *organizational* roles (ICO/FLL/MLL/BUL/SRX) — keep them separate. Auth is implemented in **C2**; C1 only fixes references |
| D14 | Playwright browser matrix | Both Nuxt apps: Playwright `projects` = **Chromium** (desktop, full suite), **WebKit/Safari** (desktop, full suite), **mobile-viewport** (device descriptor) asserting the **SA-11** unsupported-experience gate only. Best practices: web-first assertions, fixtures, `trace: 'on-first-retry'`, no `waitForTimeout`, fake interview provider for candidate flow | Firefox project (excluded per NFR); full mobile support suite; Chromium-only | Safari is a supported browser (NFR) so it gets full coverage; product is desktop-only so the mobile project only proves the gate, not features; Firefox intentionally out; best practices keep the matrix stable in CI |
| D15 | All test tiers required in CI | Every tier runs as a required, blocking job: Pest (api); Vitest + full Playwright matrix (both Nuxt). Browsers installed + cached (`~/.cache/ms-playwright`). E2E on every push/PR to `develop`, never `continue-on-error`, never schedule-only | E2E nightly-only; E2E optional/`continue-on-error`; split E2E to a separate non-required workflow | Real regressions (incl. Safari + the SA-11 gate) must block merges, not surface a day later; caching keeps the required E2E fast enough |
| D16 | SemVer versioning ×4 | Independent SemVer `M.m.p` per repo, Git-Flow-driven: `release/*` bumps version, `main` tagged `vM.m.p`, merge back to `develop`. SoT: `package.json` `version` (Nuxt apps + wrapper) / `VERSION` file aligned with `composer.json` (api) / `VERSION` (wrapper option). Seed `0.1.0`. Wrapper pins submodules to **released tags** | Single shared version across repos; wrapper floats submodule branch heads; CalVer | Each repo ships independently (different cadences: `frontend` C7/C8, `backoffice` C11, `api` continuously); pinning released tags = reproducible wrapper builds; matches CLAUDE.md |
| D17 | Docker per app + local/Railway parity | **Multi-stage Dockerfile per app** (`api`, `frontend`, `backoffice`): small final image, **non-root** user, `HEALTHCHECK`. Wrapper `docker-compose` runs infra (MySQL 8 + Redis + Mailpit) **plus the 3 app services** built from those Dockerfiles for local dev. **Railway builds via Docker** → local image = prod image (Railway config parked, no deploy in C1). CI builds the images | Buildpacks/Nixpacks on Railway (image drift local↔prod); single-stage images (large, root); compose without app services | Same Dockerfile everywhere kills local↔prod drift; multi-stage keeps images small + non-root for security; building in CI catches Dockerfile breakage before it reaches Railway |
| D18 | Bun-hybrid toolchain | **Bun** for install/dev/**build** of both Nuxt apps (+ backoffice SPA static runtime); **Node** for the `frontend` **SSR production runtime** (Nitro `node-server` preset) and for the **Vitest/Playwright** runners (officially Node-targeted). `frontend` Dockerfile = build stage on `oven/bun` → runtime stage on `node` serving the Nitro `node-server` output; `backoffice` = Bun build → static serve. CI installs deps with Bun, runs Vitest/Playwright on Node | All-Bun (Bun runtime for SSR + Bun test runner — not officially supported by Nuxt SSR/Playwright); all-Node (slower installs) | User chose hybrid: Bun speeds install/build; Node is the supported target for Nuxt SSR + Playwright/Vitest, so those run on Node to avoid unsupported-runtime bugs |

## Data Flow

    wrapper (this repo)
      docker-compose ── mysql:8.4 ─┐
                     ├─ redis:7 ───┤
                     └─ mailpit ───┤
                                   ▼
      ┌─────────────── api (submodule, Laravel API-only) ──/api/health──▶ 200 (JSON)
      │                     │  Pest + PCOV
      │                     └─ Scramble ──▶ openapi.json ──┐
      │                                                    │ openapi-typescript codegen
      │                                   ┌────────────────┴───────────────┐
      ▼                                   ▼                                ▼
    frontend (submodule, Nuxt SSR)     typed TS client (committed)     backoffice (submodule, Nuxt SPA)
      /health ──▶ 200                                                    /health ──▶ 200
      Vitest + Playwright                                                Vitest + Playwright

    CI (per repo):  api → lint+Pest+cov+openapi+docker-build   |   frontend/backoffice → lint+client-check+Vitest(Node)+cov+Playwright(Node)+docker-build (Bun install/build)
    CI (wrapper):   checkout --recursive → pointer check → compose smoke   (no deploy anywhere)

## File Changes

| Repo / File | Action | Description |
|------|------|------|
| wrapper: `src/`, `astro.config.*`, root `package.json` | Move | Relocate Astro demo into `legacy-demo/` (plain folder) |
| wrapper: `.gitmodules` | Create | Declare `api`, `frontend`, `backoffice` submodules |
| wrapper: `docker-compose.yml` | Create | MySQL 8 + Redis + Mailpit (pinned, named volumes, healthchecks) **+ 3 app services** (`api`, `frontend`, `backoffice`) built from each app's Dockerfile |
| wrapper: `Taskfile.yml` | Create | Submodule `init`/`update`/`sync`/`status` + `up`/`down`/`test:*` orchestration |
| wrapper: `.github/workflows/wrapper-ci.yml` | Create | `--recursive` checkout, pointer check, compose smoke; no deploy |
| wrapper: `railway.json` (or `.toml`) | Create | Committed but gated off (no trigger) |
| wrapper: `docs/git-flow.md` | Create | Git Flow ×4 + SemVer `M.m.p` release flow (`release/*` bump, `vM.m.p` tag, merge back, wrapper pins submodule release tags) + submodule considerations (recursive clone, pointers, merge order) |
| wrapper: `package.json`/`VERSION` | Create | Wrapper SemVer source of truth seeded `0.1.0` |
| wrapper: `openspec/config.yaml` | Modify | Flip `testing.*.status` to `scaffolded`; keep commands |
| `api`: Laravel 12 scaffold | Create | `routes/api.php` health `/api/health`, `HealthController`, `lang/{it,en}`, Pest, `phpunit.xml` coverage filter, `.env.example`, `VERSION` `0.1.0` |
| `api`: Scramble | Create | Install `dedoc/scramble`; publish `openapi.json`; export command wired |
| `api`: JWT + RBAC packages | Create | `composer require tymon/jwt-auth spatie/laravel-permission` (installed + config published, **not wired** — auth is C2); Spatie teams mode config flag noted |
| `api`: `Dockerfile` | Create | Multi-stage (Composer/PHP-FPM), non-root, `HEALTHCHECK`; small final image; same image local↔Railway |
| `api`: `.github/workflows/ci.yml` | Create | Lint + Pest (required) + coverage `--min=85` + openapi generate + docker build; no deploy |
| `frontend`: Nuxt 4 SSR scaffold | Create | `/health` page, `@nuxtjs/i18n` `{it,en}`, Vitest + Playwright config (3 projects), Nitro `node-server` preset, `.env.example`, `package.json` version `0.1.0` |
| `frontend`: `Dockerfile` | Create | Multi-stage: build on `oven/bun` → runtime on `node` serving Nitro `node-server` output; non-root, `HEALTHCHECK` |
| `frontend`: `playwright.config.ts` | Create | 3 `projects` (Chromium desktop, WebKit desktop, mobile-viewport SA-11 gate); web-first assertions, fixtures, trace-on-failure, fake interview provider |
| `frontend`: `openapi-typescript` codegen | Create | Script + committed typed client + smoke consuming `health` type |
| `frontend`: `.github/workflows/ci.yml` | Create | Bun install + build; client-drift check; Vitest cov (Node, required) + Playwright matrix (Node, all 3 projects, required, browsers cached); docker build; no deploy |
| `backoffice`: Nuxt 4 SPA scaffold (`ssr: false`) | Create | `/health` page, `@nuxtjs/i18n` `{it,en}`, Vitest + Playwright (3 projects), `.env.example`, `package.json` version `0.1.0` |
| `backoffice`: `Dockerfile` | Create | Multi-stage: build on `oven/bun` → static serve (e.g. `nginx`/`node` static); non-root, `HEALTHCHECK` |
| `backoffice`: `playwright.config.ts` | Create | Same 3-project matrix + best practices as `frontend` |
| `backoffice`: `openapi-typescript` codegen | Create | Script + committed typed client + smoke consuming `health` type |
| `backoffice`: `.github/workflows/ci.yml` | Create | Bun install + build; client-drift check; Vitest cov (Node, required) + Playwright matrix (Node, all 3 projects, required, browsers cached); docker build; no deploy |
| each app: `railway.json`/`railway.toml` | Create | Docker builder pointing at the app Dockerfile; committed but parked (no deploy trigger) |

## Interfaces / Contracts

- Health: `GET /api/health` (api) → `200` JSON `{ "status": "ok" }`; `/health` page (frontend, backoffice) → `200`.
- OpenAPI contract: `api` publishes `openapi.json` (Scramble) covering at least `/api/health`; `frontend` and `backoffice` each codegen a typed client from it (`openapi-typescript`) and commit it; CI fails on client drift.
- Playwright matrix contract (both Nuxt apps): 3 `projects` — `chromium` (desktop, full suite), `webkit` (desktop Safari, full suite), `mobile` (device descriptor, asserts SA-11 unsupported gate only); no Firefox; best practices encoded (web-first assertions, fixtures, trace-on-failure, no hard-coded waits, fake interview provider).
- Test-harness contract (per submodule): `lint` → `test` → `test --coverage --min=85` (+ full Playwright matrix for Nuxt, + openapi generate for api), all green post-C1; **every tier is a required, blocking CI job** (Pest / Vitest / Playwright never optional, `continue-on-error`, or schedule-only).
- Versioning contract (per repo): SemVer `M.m.p` source of truth (`package.json` / `VERSION`), seeded `0.1.0`; `release/*` bumps it; `main` tagged `vM.m.p`; wrapper pins submodules to released tags.
- Docker contract (per app): a multi-stage Dockerfile producing a small, non-root, healthchecked image; the wrapper `docker-compose` builds and runs all three as services alongside infra; Railway builds the same Dockerfile (parked, no deploy); CI builds each image.
- Toolchain contract (Bun-hybrid): deps install + Nuxt build via **Bun**; `frontend` SSR production runtime + Vitest + Playwright run on **Node**; `backoffice` build via Bun → static serve.
- CI gate contract: a submodule PR to its `develop` fails if authored-code coverage < 85%, lint fails, any test tier fails, the Docker build fails, or (Nuxt) the committed client is stale.
- Wrapper CI contract: recursive checkout succeeds, pinned pointers resolve (to released tags), compose services reach healthy — no deploy step present.

## Auth Model Note (JWT + Spatie; built in C2, NOT Sanctum)

Auth is **JWT (`tymon/jwt-auth`), not Sanctum**. Because JWT is **bearer/stateless**,
`backoffice` (SPA) and `api` can be **separate origins freely** — the old
Sanctum shared-parent-domain cookie constraint is **gone** (no `SESSION_DOMAIN`,
no `SANCTUM_STATEFUL_DOMAINS`, no same-site cookie coupling). Model (implemented
in **C2**, only referenced here):

- **Backoffice user auth:** bearer JWT with **access + refresh** tokens, short
  access expiry; revocation via a **Redis denylist** (logout / rotate).
- **Candidate magic-link:** a **short-lived JWT** (carries candidateRef / project /
  role / lang / exp), replacing the earlier "signed-token guard" phrasing.
- **External M2M:** a **JWT client token or API-key**, org-scoped.
- **RBAC:** `spatie/laravel-permission` in **teams mode**, `team_id =
  organization_id`, so permissions are per-organization.

⚠️ **Caveat:** Spatie *authorization* roles (e.g. admin / operator / viewer) are
**NOT** the BEAI *organizational* roles (ICO / FLL / MLL / BUL / SRX). They live in
different layers and must never be conflated. In C1 the `api` repo only installs
`tymon/jwt-auth` + `spatie/laravel-permission` (config published, **not wired**);
the actual guards, middleware, denylist, and RBAC are **C2**.

## Testing Strategy

| Layer | What to Test | Approach |
|-------|-------------|----------|
| Unit (api) | Health route returns 200 | Pest feature test; first written failing (red→green) |
| OpenAPI (api) | `openapi.json` generates and includes `/api/health` | Scramble export step; assert document produced |
| Unit (frontend) | Health page renders "ok"; i18n key resolves it/en | Vitest + Vue Test Utils; first failing then pass |
| Unit (backoffice) | Health page renders "ok"; i18n key resolves it/en; SPA mode | Vitest + Vue Test Utils; first failing then pass |
| Client codegen (frontend, backoffice) | Generated client contains `health` type; committed client not stale | Codegen script + drift diff in CI; smoke consumes the type |
| E2E Chromium (frontend, backoffice) | App boots, `/health` reachable — full suite | Playwright `chromium` desktop project (required in CI) |
| E2E WebKit/Safari (frontend, backoffice) | Same full suite on Safari (supported browser) | Playwright `webkit` desktop project (required in CI) |
| E2E mobile gate (frontend, backoffice) | Mobile viewport shows SA-11 unsupported-experience gate (not full features) | Playwright `mobile` device-descriptor project asserting the gate (required in CI) |
| Integration | `docker-compose up` → infra + 3 app services healthy; each app boots against MySQL/Redis | Wrapper compose smoke (CI) + manual |
| Docker build (all 3 apps) | Multi-stage image builds; final image non-root, healthcheck present, reasonably small | CI `docker build` step per app (required); manual `docker run` health probe |
| Toolchain (Bun/Node) | Bun installs/builds; Vitest + Playwright run on Node; `frontend` SSR image runs Nitro node-server on Node | Verified by the app CI (Bun install/build steps + Node test steps both green) |
| Coverage gate | Authored code ≥ 85% each repo (generated client excluded) | PCOV / Vitest v8, scoped includes (D9) |
| Versioning | Each repo seeded `0.1.0`; tag format `vM.m.p` | Manual verification of SoT + tag on first release (D16) |

## Migration / Rollout

Pure additive scaffolding. Each submodule is created as its own repo on a
`feature/*` branch; the wrapper pins them on a `feature/*` branch. No data
migration. Rollback = discard submodule feature branches and revert the wrapper
feature branch (drop `.gitmodules` entries + pointers); restore demo to root if
needed. Railway config committed but inert until explicitly requested.

## Open Questions

- [ ] Wrapper task runner: go-task (`Taskfile.yml`) assumed — confirm vs Makefile if go-task is undesired as a dev dependency.
- [ ] OpenAPI availability at codegen time: does CI in `frontend`/`backoffice` pull `openapi.json` from a committed artifact in `api`, generate it live from an `api` checkout, or fetch a published spec? Resolve in sdd-tasks (C1 uses a committed `openapi.json` snapshot; a live pipeline can come later).
- [ ] Playwright browser download/run cost in the required E2E job — mitigated by caching `~/.cache/ms-playwright`; confirm CI runner has WebKit deps (`--with-deps`).
- [ ] Mobile device descriptor choice for the SA-11 project (e.g. `Pixel 7` vs `iPhone 14`) and exactly what the gate assertion checks — resolve in sdd-tasks / align with C7's unsupported-browser gate.
- [ ] `api` version SoT: standalone `VERSION` file vs a custom `composer.json` field — confirm in sdd-tasks (Composer has no standard app `version` slot).
- [ ] `backoffice` static serve base image: `nginx:alpine` vs a minimal `node` static server — pick in sdd-tasks (both non-root capable).
- [ ] Bun + Node version pins (e.g. `oven/bun:1` + `node:22-slim`) — pin exact tags in sdd-tasks to avoid hybrid drift.
- [ ] JWT refresh/denylist details (access+refresh TTLs, Redis denylist key shape) — **owned by C2**; C1 only installs the package unwired.
- [ ] Auth is JWT bearer (not Sanctum) → **no shared-domain constraint**; the only cross-origin need is CORS allow-listing the backoffice origin on `api`, which is C2 config, not a DNS/domain blocker.
