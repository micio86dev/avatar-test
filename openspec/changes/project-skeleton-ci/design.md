# Design: Project Skeleton & CI Foundation (C1)

## Technical Approach

Turn the repo root (currently an Astro demo) into a **wrapper superproject** that
holds `docs/`, `openspec/`, `CLAUDE.md`, `docker-compose.yml`, a wrapper
`Taskfile.yml`/scripts, `.gitmodules`, and a cross-stack CI workflow — plus the
relocated Astro demo in `legacy-demo/` (plain folder, reference). It declares
**three git submodules**, each a standalone repository with its own Git Flow,
toolchain, `.env.example`, test harness, and CI:

- **`api`** — Laravel 13 + PHP 8.5, **API-only** (no Blade). **Scramble** publishes
  `openapi.json`. Pest + PCOV coverage.
- **`frontend`** — Nuxt 4 (Vue 3) **SSR**, `@nuxtjs/i18n` (it/en). Vitest + Vue
  Test Utils + Playwright. Codegens a typed TS client from `api`'s `openapi.json`.
- **`backoffice`** — Nuxt 4 (Vue 3) **SPA** (`ssr: false`), `@nuxtjs/i18n`
  (it/en). Vitest + Vue Test Utils + Playwright. Same codegen.

Each app ships a **multi-stage production-grade Dockerfile** (small final image,
non-root, healthcheck); `docker-compose` (wrapper) provisions PostgreSQL 17
(`pgvector/pgvector:0.8.0-pg17`) + Redis 8 + Mailpit **plus the three app
services** built from those Dockerfiles for local dev. **Railway builds via Docker** so the local image equals prod (Railway config
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
| D3 | API shape | **Laravel 13** + PHP 8.5, **API-only** + Scramble `dedoc/scramble:^0.13` publishing `openapi.json` | Blade/Inertia UI in Laravel; hand-written OpenAPI; API Platform | Stateless API scales horizontally; Scramble derives the spec from routes/types so it stays honest; no server-rendered UI in Laravel |
| D4 | API contract / type sync | Scramble emits `openapi.json`; `frontend` + `backoffice` each run `openapi-typescript` to codegen + commit a typed client | Hand-maintained TS types per repo; shared npm types package; tRPC (not PHP-compatible) | Single source of truth (the API) keeps 3 repos in sync by construction; committed client is diffable and CI-checkable for drift |
| D5 | Submodule wiring | `.gitmodules` pins each repo; wrapper `Taskfile.yml` `init`/`update`/`sync`/`status` tasks; clone/CI `--recursive` | Manual submodule commands only; monorepo; `git subtree` | Explicit tasks reduce detached-HEAD/forgotten-`--recursive` friction; pointer-freshness check catches stale pins in CI |
| D6 | Demo relocation | Move Astro wholesale to `legacy-demo/` as a **plain folder** (not a submodule) | Delete; keep at root; make it a 4th submodule | Kept runnable as a C7 port reference; plain folder avoids submodule overhead for throwaway reference code; isolated so it never pollutes app coverage |
| D7 | Local infra (dev + CI + test DB) | Wrapper `docker-compose.yml`: **`pgvector/pgvector:0.8.0-pg17`** (PostgreSQL 17 + pgVector; named volumes; healthcheck; init script at `/docker-entrypoint-initdb.d/` creates both `beai` dev DB and `beai_test` test DB), `redis:8.0-alpine`, `axllent/mailpit:v1.22`; all tags pinned (see D24 and D25). **Stage/prod: Supabase** (managed PostgreSQL + pgVector native, same major version 17). Local image version MUST match the Supabase project's PostgreSQL major version. | MySQL/MariaDB (no pgVector, different engine from Supabase target — expensive late migration); Sail (Laravel-only, hides config); separate vector DB service (Pinecone/Qdrant — extra infra, extra latency for co-located data); per-repo compose | PostgreSQL is the production engine (Supabase); same engine local↔CI↔stage↔prod eliminates the engine-parity bug class; pgVector is available by default on Supabase and in the `pgvector/pgvector` image — AI features (semantic search, competency embeddings, reportistica) use it without a separate service; Mailpit catches mail without external deps |
| D8 | PHP coverage driver | PCOV in `api` CI (fast line coverage); Xdebug only local | Xdebug in CI | PCOV is markedly faster for the gate |
| D9 | Coverage scoping (per repo) | `api`: Pest `--min=85` over `app/`. Nuxt apps: Vitest `coverage.include` = `app/**`, `components/**`, `composables/**`, `pages/**`, `server/**`; exclude `.nuxt/`, config, and the **generated TS client** | Whole-repo coverage; measuring generated client | Kills the "gate blocks trivial skeleton" risk; the generated client is not authored code and must not inflate or dilute the gate |
| D10 | Env strategy | Per-submodule `.env.example`; wrapper compose exposes services on host; each app's `.env` points at compose service names / host ports | Single root `.env`; committed `.env` | App-local config matches framework norms; submodules stay independently bootable |
| D11 | CI structure | **Per-repo workflows** (each submodule: lint + test + coverage + [OpenAPI or client-codegen check]); **wrapper workflow**: `--recursive` checkout + pointer check + compose smoke | One monorepo workflow with `dorny/paths-filter`; two workflows in one repo | Per-repo CI is the natural fit for submodules — a repo's CI runs only when it changes; no path-filter needed; wrapper CI guards cross-stack integrity |
| D12 | i18n scaffolding | `api`: Laravel `lang/{it,en}`. `frontend` + `backoffice`: `@nuxtjs/i18n` lazy locale files `i18n/locales/{it,en}.json`, default `it`, `strategy: prefix_except_default` | Eager bundles; no default; single shared locale package | Default `it` per domain; lazy = smaller bundles; each Nuxt repo owns its own locale files (DB-translatable content deferred to C3) |
| D13 | Auth model note (JWT, not Sanctum; not built in C1) | **JWT (`tymon/jwt-auth`)** — bearer access + refresh tokens (short expiry, **Redis denylist** for revocation) for backoffice user auth; **short-lived JWT** for the candidate magic-link; **JWT client token / API-key** for external M2M. RBAC via **`spatie/laravel-permission`** in **teams mode** (`team_id = organization_id`). Because JWT is bearer/stateless, **cross-origin is free** — no shared-parent-domain cookie constraint; `backoffice` SPA and `api` may be different origins | **Sanctum** SPA cookies (user dislikes it) + shared-parent-domain cookie constraint (removed); session-based auth | Bearer JWT removes the cookie/domain coupling entirely (the old constraint is gone); Spatie teams mode gives per-org RBAC. ⚠️ Spatie *authorization* roles (admin/operator/viewer) are NOT the BEAI *organizational* roles (ICO/FLL/MLL/BUL/SRX) — keep them separate. Auth is implemented in **C2**; C1 only fixes references |
| D14 | Playwright browser matrix | Both Nuxt apps: Playwright `projects` = **Chromium** (desktop, full suite), **WebKit/Safari** (desktop, full suite), **mobile-viewport** (device descriptor) asserting the **SA-11** unsupported-experience gate only. Best practices: web-first assertions, fixtures, `trace: 'on-first-retry'`, no `waitForTimeout`, fake interview provider for candidate flow | Firefox project (excluded per NFR); full mobile support suite; Chromium-only | Safari is a supported browser (NFR) so it gets full coverage; product is desktop-only so the mobile project only proves the gate, not features; Firefox intentionally out; best practices keep the matrix stable in CI |
| D15 | All test tiers required in CI | Every tier runs as a required, blocking job: Pest (api); Vitest + full Playwright matrix (both Nuxt). Browsers installed + cached (`~/.cache/ms-playwright`). E2E on every push/PR to `develop`, never `continue-on-error`, never schedule-only | E2E nightly-only; E2E optional/`continue-on-error`; split E2E to a separate non-required workflow | Real regressions (incl. Safari + the SA-11 gate) must block merges, not surface a day later; caching keeps the required E2E fast enough |
| D16 | SemVer versioning ×4 | Independent SemVer `M.m.p` per repo, Git-Flow-driven: `release/*` bumps version, `main` tagged `vM.m.p`, merge back to `develop`. SoT: `package.json` `version` (Nuxt apps + wrapper) / `VERSION` file aligned with `composer.json` (api) / `VERSION` (wrapper option). Seed `0.1.0`. Wrapper pins submodules to **released tags** | Single shared version across repos; wrapper floats submodule branch heads; CalVer | Each repo ships independently (different cadences: `frontend` C7/C8, `backoffice` C11, `api` continuously); pinning released tags = reproducible wrapper builds; matches CLAUDE.md |
| D17 | Docker per app + local/Railway parity | **Multi-stage Dockerfile per app** (`api`, `frontend`, `backoffice`): small final image, **non-root** user, `HEALTHCHECK`. Wrapper `docker-compose` runs infra (PostgreSQL 17 + Redis 8 + Mailpit; all tags pinned — see D25) **plus the 3 app services** built from those Dockerfiles for local dev. **Railway builds via Docker** → local image = prod image (Railway config parked, no deploy in C1). CI builds the images | Buildpacks/Nixpacks on Railway (image drift local↔prod); single-stage images (large, root); compose without app services | Same Dockerfile everywhere kills local↔prod drift; multi-stage keeps images small + non-root for security; building in CI catches Dockerfile breakage before it reaches Railway |
| D18 | Bun-hybrid toolchain | **Bun `1.3`** (`oven/bun:1.3`) for install/dev/**build** of both Nuxt apps (+ backoffice SPA static runtime); **Node `24 LTS`** (`node:24-slim`) for the `frontend` **SSR production runtime** (Nitro `node-server` preset) and for the **Vitest/Playwright** runners (officially Node-targeted). `frontend` Dockerfile = build stage on `oven/bun:1.3` → runtime stage on `node:24-slim` serving the Nitro `node-server` output; `backoffice` = Bun build → static serve (`nginx:1.27-alpine`). CI installs deps with Bun `1.3`, runs Vitest/Playwright on Node `24`. Exact patch versions locked in `bun.lock`. | All-Bun (Bun runtime for SSR + Bun test runner — not officially supported by Nuxt SSR/Playwright); all-Node (slower installs); floating `bun:latest` / `node:latest` (silent breaking changes on pull) | User chose hybrid: Bun speeds install/build; Node `24 LTS` is the supported target for Nuxt SSR + Playwright/Vitest; pinned tags (see D25) eliminate hybrid drift |
| D19 | Pre-commit & formatting — Nuxt apps | **Husky v9** + **lint-staged** + **Prettier** in both `frontend` and `backoffice`. Husky wires git hooks via `package.json` `prepare` script — `bun install` triggers it automatically (zero manual steps for new contributors). lint-staged scopes hooks to staged files only (fast local loop). Prettier config committed as `.prettierrc`: `singleQuote: true`, `semi: false`, `trailingComma: "es5"`, `printWidth: 100`, `tabWidth: 2`, `vueIndentScriptAndStyle: false`, `endOfLine: "lf"`. lint-staged runs `eslint --fix` then `prettier --write` on `*.{vue,ts,js,json,css,md}`; if non-auto-fixable errors remain after fix, commit is aborted. CI adds a **required** `prettier --check .` step (after ESLint) to catch drift even when the hook is bypassed. | Lefthook (cross-language binary, extra dep for JS-only repos); `pre-commit` Python framework (extra Python dep); Prettier-via-ESLint-plugin only (no CLI, harder to format JSON/md/CSS) | Husky is the de-facto standard for JS/TS pre-commit; lint-staged limits scope to staged files; committed `.prettierrc` = consistent formatting enforced by editors + CI; auto-fix + re-stage removes "go run formatter manually" friction |
| D20 | Pre-commit — api (Laravel/PHP) | **CaptainHook** (`captainhook/captainhook`) in `api`. Installed as a Composer dev dependency; auto-wires `.git/hooks/pre-commit` via `post-install-cmd` in `composer.json` (`vendor/bin/captainhook install -f -s`). Pre-commit action: `./vendor/bin/pint --dirty` on staged PHP files only. PHP formatting is fully owned by Pint (PSR-12 + Laravel opinionated rules on top of PHP-CS-Fixer) — no separate PHP Prettier needed. | GrumPHP (heavier config surface, same outcome); Lefthook (separate binary install, non-Composer); plain bash `.git/hooks/pre-commit` script (fragile, not tracked in repo, forgotten by new contributors) | CaptainHook auto-wires on `composer install` → zero-friction onboarding; `--dirty` limits Pint to staged files only (fast); Composer-native keeps dep graph in one place; Pint already used in the CI lint step so local hook and CI share the same tool |
| D21 | API test database driver | **Dedicated PostgreSQL `beai_test`** database for all Pest tests. `DB_CONNECTION=pgsql`, `DB_PORT=5432`, `DB_DATABASE=beai_test` overridden in both `.env.testing` (committed) and `phpunit.xml` `<php>` block. `RefreshDatabase` trait wraps each feature test in a transaction and rolls back (fast, stateless between tests). CI adds `services.postgres` (`pgvector/pgvector:0.8.0-pg17`, `POSTGRES_DB=beai_test`) + waits for healthcheck + runs `php artisan migrate` before Pest. docker-compose PostgreSQL init script creates both `beai` (dev) and `beai_test` on first `up`. | SQLite `:memory:` (different engine — masks PostgreSQL-specific type constraints, FK enforcement, jsonb operators, pgVector column types; invalidates a class of integration tests); MySQL/MariaDB (wrong engine; Supabase target is PostgreSQL — migration would be expensive); separate PostgreSQL container in CI (extra overhead without benefit) | Same engine in test as in production (Supabase = PostgreSQL) removes the engine-parity risk class entirely; `pgvector/pgvector:0.8.0-pg17` matches the Supabase PostgreSQL major version; `RefreshDatabase` + transactions keeps the suite fast despite a real DB |
| D22 | Migration standards (established C1, enforced C2–C13) | **Normalize by default (3NF)**; denormalize only with a documented, measurable performance justification written as a comment in the migration. Each migration is atomic (single concern), reversible (`down()` correct), and immutable once deployed. FK columns always indexed. All composite indexes lead with `organization_id` (primary multi-tenant discriminator; most selective filter in every query). Right-sized column types (narrowest that models the domain; prefer `smallint` over `integer` for small enumerations). No redundant data without explicit performance justification. pgVector migrations MUST include `CREATE EXTENSION IF NOT EXISTS vector;` before creating vector columns. | Denormalized-first schema (premature optimization, schema anomalies, hard to evolve); missing `down()` (one-way migrations, no rollback path); bundled migrations (hard to review, conflict-prone); wide column types everywhere | Normalization keeps the schema consistent and anomaly-free; correctness before premature optimization; `organization_id`-first indexes match the dominant access pattern (every tenant-scoped query); reversible migrations keep the rollback path open at all times |
| D23 | Stage/prod database — Supabase + pgVector | **Supabase** (managed PostgreSQL with pgVector native) for stage and prod environments. Supabase provides PostgreSQL 17 + pgVector without a separate vector service. The Supabase project's PostgreSQL major version MUST match the local `pgvector/pgvector:0.8.0-pg17` major version. AI features (semantic search, competency embeddings, reportistica) store and query embeddings in PostgreSQL via pgVector — no separate Pinecone/Qdrant/Weaviate service needed. | Self-hosted PostgreSQL on Railway with a separate pgVector install (extra ops burden; version drift risk); separate vector DB service (Pinecone, Qdrant, Weaviate — extra latency, cost, and infra for co-located data); MySQL/MariaDB on Railway (wrong engine; not pgVector-native) | Supabase is managed — no DB ops burden; pgVector is a first-class extension on Supabase; co-locating vector data with relational data removes a network hop for embedding lookups; same PostgreSQL engine local↔CI↔stage↔prod removes the engine-parity bug class |
| D24 | Environment parity — pinned Docker base image tags | **All Docker base image tags MUST be pinned to the version specified in D25** (no `latest`, no bare majors). The local docker-compose, CI services blocks, and each app's Dockerfile MUST reference the identical tag. Any version bump is a single-line change reviewed by diff; no implicit upgrades allowed. The `pgvector/pgvector:0.8.0-pg17` tag MUST match the Supabase project's PostgreSQL major version (17). | Floating tags (`latest`, `17`, `bun`) — silent breaking changes on pull; environment drift between local, CI, and Railway; "works on my machine" class of bugs | Pinned tags guarantee identical binaries across local, CI, and Railway; catching runtime breakage locally is the goal; version bumps are explicit and reviewable; this rule enforces the BEAI principle that all environments run the exact same versions of everything |
| D25 | Version catalog — pinned baseline (see section below) | Single source of truth for every runtime, framework, library, and Docker image version used in C1. **No `latest` tag, no bare major tag, no version range wider than `^minor`**. Exact patch versions are locked in `composer.lock` and `bun.lock` at apply time; the baseline below is the *minimum accepted minor*. Bumping any entry here is a deliberate, reviewed decision. See the **Version Catalog** section below for the full table. | Per-repo ad-hoc pinning (divergence between `api` and the two Nuxt apps); no pinning at all (constant drift surprises); over-pinning to exact patch in the design doc (makes the design immediately stale on every security release) | One catalog makes drift visible immediately as a diff; `^minor` gives security patches within a minor while blocking unexpected major/minor jumps; `composer.lock` + `bun.lock` are the ultimate patch-level source of truth; the catalog must be updated together with CLAUDE.md when a major version is decided |
| D26 | CSS framework | **Tailwind CSS v4** (`tailwindcss: ^4.0` + `@tailwindcss/vite`) in both `frontend` and `backoffice`. CSS-first via `@import "tailwindcss"` in `assets/css/main.css`; `@tailwindcss/vite` Vite plugin wires JIT. Custom design tokens (colors, typography, spacing) defined in `DESIGN.md` at the wrapper root and wired via CSS `@theme {}` blocks. `@tailwindcss/forms` + `@tailwindcss/typography` installed as addons. Target browsers: Chrome 120+, Edge 120+, Safari 17+ per NFR (Firefox excluded; mobile excluded → unsupported gate SA-11). | Bootstrap (heavier, non-utility); Tailwind v3 with `tailwind.config.js` (legacy, CSS-first v4 is the current stable); custom SCSS without a design system (inconsistent, slow to iterate) | v4 JIT purges dead CSS automatically; CSS-first config plays natively with Vite + Vue SFCs; target browsers fully support all v4 CSS features (CSS custom properties, cascade layers, container queries); design tokens live in plain CSS — no build-tool coupling; `DESIGN.md` is the single source of truth for all design decisions |
| D27 | TypeScript strictness | **`strict: true`** in `tsconfig.json` for both Nuxt apps (covers `noImplicitAny`, `strictNullChecks`, `strictFunctionTypes`, `noImplicitThis`). Additional flags: `noUnusedLocals: true`, `noUnusedParameters: true`, `exactOptionalPropertyTypes: true`. **`any` is banned** — use typed generics, discriminated unions, or Zod-inferred types. **`unknown` acceptable only with an explicit type-narrowing guard** (`instanceof`, `typeof`, or Zod `parse`). CI: **required blocking** `tsc --noEmit` step (via `nuxi typecheck`) in both Nuxt workflows, runs after ESLint + Prettier, before Vitest. Nuxt-generated files (`.nuxt/`) excluded via `tsconfig.app.json` path exclusion. | `strict: false` (hides null-deref and type mismatch bugs); ad-hoc `strict: true` without CI gate (bypass via pre-commit skips); `any` accumulation (spreads type holes silently) | Strict mode catches null-derefs and argument type mismatches at compile time; the generated `openapi-typescript` client is already fully typed — strict makes full use of it; pairing strict tsconfig with a required CI typecheck gate means no `any` escapes even when pre-commit is bypassed |
| D28 | PHP static analysis | **PHPStan `^2.0` + Larastan (`larastan/larastan: ^3.0`)** in the `api` submodule, level **8** baseline. `phpstan.neon` committed at `api/` root including Larastan's preset. CI: **required blocking** `./vendor/bin/phpstan analyse` step in the `api` workflow, runs after Pint lint and before Pest. A `phpstan-baseline.neon` MAY be committed for unavoidable initial Larastan scaffold noise; reviewed and cleared progressively across C2–C4 before reaching zero. | No static analysis (misses null-derefs, wrong return types, missing method signatures that Pest won't catch); Psalm (alternative; Larastan is Laravel-specific and better maintained in the Laravel ecosystem) | PHPStan 8 catches constructor injection mismatches, null-unsafe property accesses, and wrong return types before tests run; Larastan adds Eloquent magic-method and facade inference; wiring in C1 means every subsequent slice starts on a typed-clean PHP foundation |
| D29 | Accessibility + GDPR mandate | **WCAG 2.1 Level AA mandatory** on all pages in both `frontend` and `backoffice`. Requirements: semantic HTML5 landmarks, full keyboard operability, color contrast ≥ 4.5:1 (normal text) / ≥ 3:1 (large text / UI), `alt` on all images, `aria-label` / `aria-describedby` on unlabeled interactive elements, visible focus indicators, `lang` attribute on `<html>`, `aria-live` for dynamic content. All ARIA labels sourced from i18n (never hardcoded). `@axe-core/playwright` integrated into Playwright E2E suite — runs `axe` per page, violations at level AA fail the test. **GDPR**: before interview start, candidate sees a clear privacy notice (data controller, data categories, retention, right to withdraw); explicit consent required for recording/proctoring; backend emits an audit log event for consent; backoffice surfaces a data deletion request flow for candidate records. | Accessibility as best-effort afterthought (legal risk in EU — EN 301 549 / EAA 2025); cookie-banner-only GDPR approach (incomplete for voice/video data); `@axe-core` only in dev mode (regressions escape CI) | WCAG 2.1 AA is the EU legal baseline (EAA 2025 applies to B2B SaaS procurement); `@axe-core/playwright` turns accessibility into a CI gate — regressions surface in tests, not post-launch audits; explicit GDPR consent is legally required for recording voice/video of candidates; both baked in from C1 rather than retrofitted after C7 |
| D30 | noindex policy + Lighthouse targets | **noindex policy**: `backoffice` ALWAYS serves `<meta name="robots" content="noindex, nofollow">` in every environment — admin panel must never be indexed. `frontend`: `noindex, nofollow` on `local` and `staging`; `production` may serve normal robots headers for the public landing/entry page only (the interview itself is private and magic-link-gated). In Nuxt: `useHead` in root layout with `NUXT_PUBLIC_APP_ENV` runtime config (Railway env var) driving the conditional; `nuxt.config.ts` `app.head` sets the production default. **Lighthouse targets** (measured on production-equivalent builds): Performance ≥ 90, Accessibility **100**, Best Practices **100**, SEO ≥ 90 (`frontend` landing page only; `backoffice` excluded). Core Web Vitals: LCP < 2.5 s, CLS < 0.1, INP < 200 ms. Lighthouse CI (`lhci`) added as a **non-blocking advisory** CI step in C1; blocking enforcement deferred to C13. | Indexable admin panel (exposes internal org URLs + data to search engines — security risk); no Lighthouse baseline (perf/a11y regressions invisible until user complaint) | Indexed admin panels are a common security/privacy leak vector; Lighthouse targets set the performance contract early — maintaining 90 is easier than recovering from 40; INP replaces FID as the Core Web Vitals responsiveness metric; critical for the interview flow where every interaction is time-sensitive |
| D31 | i18n mandate + English code policy | **Zero hardcoded text** across all three repos. No string literal in Vue templates, PHP controllers/responses, validation messages, error messages, email bodies, notification payloads, or log messages intended for end users may be inline — all live in `lang/{it,en}.php` (api) or `i18n/locales/{it,en}.json` (both Nuxt apps). Use `$t('key')` in Vue; `__('key')` in PHP. ARIA attributes and meta descriptions also sourced from i18n. **Machine-readable values are exempt** — API status payloads (e.g. `/api/health` → `{"status":"ok"}`), enum values, DB column / API field names, log keys, and HTTP header values are NOT user-facing and are never localized (returned literally in every locale). **English-only code**: all identifiers, class/method/variable names, enum values, database column names, API field names, PHPDoc/TSDoc, comments, migration names, test names, CI step names, and commit messages MUST be in English. No mixed-language source files. Rioplatense Spanish (or any non-English language) is permitted only in i18n locale files (`*.json`, `*.php` translation files) — never in source code, tests, or configs. | Mixed-language source (unmaintainable across multi-lingual engineering teams; breaks static-analysis inference); inline text (untranslatable; fails GDPR language requirements for candidate-facing consent notices) | i18n-first from C1 eliminates retrofitting cost in C7/C8/C11 when the interview ships in multiple languages (it/en mandatory; es/fr/de/pt desirable per CLAUDE.md); English-only source code is the universal engineering lingua franca — readable by any contributor regardless of spoken language |
| D32 | Code quality pipeline — AI-assisted review | **`gentleman-guardian-angel`** (personal Claude Code extension, installed locally) provides automated pre-PR review via 4R lenses (readability, reliability, resilience, risk). **`agent-teams-lite`** provides the multi-agent orchestration protocol used by SDD phases (design, apply, verify, judgment-day). **`gentle-ai`** (CLAUDE.md orchestration layer) is always on. Pipeline: SDD artifacts go through `sdd-*` skills; implementation PRs trigger `review-readability` pre-commit; `judgment-day` adversarial review is strongly recommended after SDD `design` and `apply` phases. **Not committed to any submodule repo** — these are personal Claude Code extensions; each contributor installs their own copy. | Ad-hoc code review (no lens coverage guarantee); no pre-PR AI gate (regressions merge undetected); committing AI tooling to the repo (not appropriate — extensions are credentials-bound to a personal account) | 4R systematic lens coverage catches failure modes orthogonal to human review; SDD + TDD + pre-PR AI review = three independent quality gates before code reaches `develop`; documented in the design so contributors know the pipeline exists and can install their own copy |
| D33 | API versioning contract (backward compatibility) | The `api` MUST maintain **backward compatibility within a major version**. Additive changes (new optional response fields, new endpoints, new optional request params) are non-breaking and ship without forcing `frontend`/`backoffice` to update. Breaking changes (removed fields, renamed endpoints, changed response shapes, breaking auth contracts) MUST bump the major API version prefix (`/api/v2/`). The `openapi.json` committed in `frontend`/`backoffice` MUST carry the API version it was generated from (via Scramble's `info.version`, which equals the `api` `VERSION` file). Each Nuxt repo updates its API client only when its maintainer explicitly pulls a new `openapi.json` snapshot, regenerates the typed client, runs the full test suite green, and releases a new version. The wrapper's submodule pointer is bumped only after all affected repos have been independently tested and released. | Implicit "always latest" dependency (breaks `frontend` silently when `api` adds a field rename); monorepo lock-step releases (defeats the independent-service model); no API versioning (one breaking change shuts down all consumers simultaneously) | Independent service lifecycles require explicit versioning contracts; additive-only changes within a major version allow `api` to ship hotfixes without waiting for the two frontend release cycles; the committed `openapi.json` snapshot + typed client mean the Nuxt repos always work against a known, tested API surface |
| D34 | Independent deploy pipelines (per-service Railway, no cross-service triggering) | Each submodule (`api`, `frontend`, `backoffice`) is a **separate Railway service** monitoring ONLY its own repository's `main` branch. A push to `api`'s `main` triggers ONLY the `api` Railway service deploy — not `frontend` or `backoffice`. A hotfix to `api` can ship without waiting for the frontend release cycles, provided D33 backward compatibility is maintained. The wrapper has no Railway service of its own. CI per-repo is already separated (D11); deploy independence extends that separation to the Railway layer. Railway config (`railway.json`) is committed in each submodule but remains **inert** until an explicit deploy is requested — no CI step triggers Railway in C1 (per CLAUDE.md). | Monolithic deploy (all three services always redeploy together — slow, risky, unnecessary coupling); wrapper-controlled deployment (creates a bottleneck and a single point of failure) | Deploy independence = smaller blast radius per change; `api` hotfixes don't block `frontend` release; cost efficiency (Railway charges per service run — unnecessary rebuilds of `frontend` on an `api` change waste money) |
| D35 | Load testing strategy (K6 — local-only, cost-aware) | **Grafana K6** (open source binary, scripts in JS) for `api` load testing. Runs ONLY against the **local Docker Compose stack** (`docker compose up`) — never against Railway stage/prod to avoid Railway bandwidth/traffic costs. Test scenarios: baseline (10 VU × 60 s), stress (50 VU × 120 s), spike (200 VU × 30 s burst). Thresholds: `GET /api/health` p95 < 100 ms; scoring endpoint (C8) p95 < 10 s; error rate < 1% at baseline and stress. A K6 **HTML + JSON report** is generated locally and stored in `docs/load-testing/latest-report.{html,json}` — that report answers "how many concurrent users can the stack serve." CI: a `workflow_dispatch`-only job (never triggered automatically on PR or push) in `api/.github/workflows/load-test.yml` — operators trigger it manually after a release. LLM provider is **mocked** during load tests (pre-recorded fixture responses); no live AI API calls. K6 scripts live in `api/tests/k6/`; Taskfile task `test:load` runs them locally. | jMeter (heavy Java tooling, poor DX for JS/TS teams); running load tests in prod CI (Railway bandwidth cost, noisy CI, risk of self-DoS); load testing with live AI calls (prohibitive AI API cost at 200 concurrent users) | K6 is lightweight (single binary, JS/TS scripts), has a Grafana ecosystem, and runs locally without cloud dependencies; local-only avoids Railway bandwidth charges entirely; mocked LLM prevents AI API cost explosion at load-test scale; the local report gives a concrete concurrent-user capacity estimate for Railway sizing decisions |
| D36 | AI testing strategy (cost-aware, mock-first) | **Mock-first**: ALL standard unit and integration tests in the `api` Pest suite use a `FakeLLMProvider` implementing the LLM provider interface — zero real AI API calls in the standard test run. Pattern: a `FakeLLMProvider` is registered in the Laravel service container for `APP_ENV=testing`; Pest's `TestCase` base class binds it automatically. For integration tests needing realistic LLM responses: **VCR cassette pattern** — pre-recorded fixture JSONs (committed in `tests/Fixtures/cassettes/`) replayed by the fake provider (`temperature=0` + versioned model + prompt hash in the cassette filename ensure reproducibility). Tests that MUST hit a real LLM API are tagged `->group('ai')`. **`@ai` tests run ONLY** in a dedicated `ai-integration` workflow triggered by `workflow_dispatch` or on `release/*` branches — NEVER on PR or `develop` push. When real LLM calls run in CI, the cheap model (`claude-haiku-4-5-20251001`) is used via `AI_TEST_MODEL` env var — NOT the production model. **The 85% coverage gate counts AI-path code covered by mock-based tests**; real LLM tests are additive, not required. No AI API spend happens on normal development flow. | Real LLM calls on every test run (AI API cost at scale: 85% coverage × daily PRs × developer count = prohibitive); no mocking (non-deterministic tests, rate-limit failures in CI, test suite that cannot run offline); mocking everything without cassettes (no realistic path for scoring accuracy verification) | Mock-first + cassette pattern keeps the standard test suite free of AI costs and non-determinism; cassettes with `temperature=0` + versioned prompt hash give deterministic replay; the `@ai` group with manual CI trigger means real AI is tested only at release time (when it matters most) and never on developer PRs |
| D37 | Dependency resolution policy (autonomous runs) | If any pinned dependency (D25) cannot be installed or resolved — or a required tool (D38) is missing — **STOP and report**. Never downgrade a package, never replace it with an alternative library, never remove or loosen a version constraint, never substitute an unspecified tool. A blocked dependency is an open question for a human, not an implementation decision. | Auto-downgrading to "make it install"; swapping libraries; widening `^minor` to `*`; silently substituting a missing tool | Prevents silent drift off the pinned catalog during unattended loop sessions; keeps `composer.lock` / `bun.lock` authoritative; version conflicts are resolved by a human, not improvised by the agent |
| D38 | Required local development toolchain | Autonomous apply assumes installed on `PATH` (versions per D25): PHP 8.5 + PCOV + `pdo_pgsql`; Composer 2.4+; Bun 1.3; Node 24 LTS; Docker + Docker Compose v2; Playwright browsers Chromium + WebKit (`--with-deps`); go-task; git; k6 (local load tests only). Documented in `docs/dev-setup.md`. A missing required tool triggers D37 (STOP + report — never substitute). | Assuming tools appear on demand; substituting a missing tool; leaving the toolchain implicit | A required-but-absent tool (e.g. WebKit system deps) silently fails an otherwise-green build; an explicit documented toolchain lets the session verify preconditions before building and fail loudly if one is missing |

## Data Flow

    wrapper (this repo)
      docker-compose ── pgvector/pgvector:0.8.0-pg17 ─┐
                     ├─ redis:8.0-alpine ──────────────┤
                     └─ mailpit:v1.22 ────────────────┤
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
| wrapper: `docker-compose.yml` | Create | PostgreSQL 17 (`pgvector/pgvector:0.8.0-pg17`) + Redis 8 (`redis:8.0-alpine`) + Mailpit (`axllent/mailpit:v1.22`) (pinned, named volumes, healthchecks) **+ 3 app services** (`api`, `frontend`, `backoffice`) built from each app's Dockerfile |
| wrapper: `Taskfile.yml` | Create | Submodule `init`/`update`/`sync`/`status` + `up`/`down`/`test:*` orchestration |
| wrapper: `.github/workflows/wrapper-ci.yml` | Create | `--recursive` checkout, pointer check, compose smoke; no deploy |
| wrapper: `railway.json` (or `.toml`) | Create | Committed but gated off (no trigger) |
| wrapper: `docs/git-flow.md` | Create | Git Flow ×4 + SemVer `M.m.p` release flow (`release/*` bump, `vM.m.p` tag, merge back, wrapper pins submodule release tags) + submodule considerations (recursive clone, pointers, merge order) |
| wrapper: `package.json`/`VERSION` | Create | Wrapper SemVer source of truth seeded `0.1.0` |
| wrapper: `openspec/config.yaml` | Modify | Flip `testing.*.status` to `scaffolded`; keep commands |
| `api`: Laravel 13 scaffold (PHP 8.5) | Create | `routes/api.php` health `/api/health`, `HealthController`, `lang/{it,en}`, Pest `^4.0`, `phpunit.xml` coverage filter, `.env.example`, `VERSION` `0.1.0` |
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
| `api`: `captainhook.json` | Create | CaptainHook config: pre-commit action running `./vendor/bin/pint --dirty` on staged PHP files |
| `api`: `composer.json` `scripts.post-install-cmd` | Modify | Add `"vendor/bin/captainhook install -f -s"` to auto-wire the git pre-commit hook on `composer install` |
| `frontend`: `.prettierrc` | Create | Prettier config: `singleQuote: true`, `semi: false`, `trailingComma: "es5"`, `printWidth: 100`, `tabWidth: 2`, `vueIndentScriptAndStyle: false`, `endOfLine: "lf"` |
| `frontend`: `package.json` `scripts.prepare` | Modify | Add `"prepare": "husky"` to auto-install the Husky pre-commit hook on `bun install` |
| `frontend`: `.husky/pre-commit` | Create | Husky pre-commit hook script: `bunx lint-staged` |
| `frontend`: `.lintstagedrc.json` | Create | lint-staged config: `eslint --fix` + `prettier --write` on `*.{vue,ts,js,json,css,md}` |
| `frontend`: `.github/workflows/ci.yml` | Modify | Add required `prettier --check .` step after ESLint (see task 3.16) |
| `backoffice`: `.prettierrc` | Create | Same Prettier config as `frontend` |
| `backoffice`: `package.json` `scripts.prepare` | Modify | Add `"prepare": "husky"` |
| `backoffice`: `.husky/pre-commit` | Create | Same Husky pre-commit hook as `frontend` |
| `backoffice`: `.lintstagedrc.json` | Create | Same lint-staged config as `frontend` |
| `backoffice`: `.github/workflows/ci.yml` | Modify | Add required `prettier --check .` step after lint (see task 4.16) |
| wrapper: `docker-compose.yml` PostgreSQL service | Modify | Add init script (`/docker-entrypoint-initdb.d/init.sql`) that creates both `beai` (dev) and `beai_test` (test) databases with the configured user on first start |
| `api`: `.env.testing` | Create | Committed test-env overrides: `DB_CONNECTION=pgsql`, `DB_PORT=5432`, `DB_DATABASE=beai_test`; no production secrets — other variables inherited from `.env`; enables `php artisan migrate --env=testing` locally |
| `api`: `phpunit.xml` | Modify | Add `<env name="DB_CONNECTION" value="pgsql"/>`, `<env name="DB_PORT" value="5432"/>`, and `<env name="DB_DATABASE" value="beai_test"/>` in `<php>` block to guarantee Pest always targets `beai_test`, never the dev DB |
| `api`: `.github/workflows/ci.yml` | Modify | Add `services.postgres` block (`pgvector/pgvector:0.8.0-pg17`, `POSTGRES_DB=beai_test`, healthcheck on port 5432 via `pg_isready`); add `php artisan migrate` step after `composer install`, before Pest |

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
- Code-quality contract: pre-commit hooks auto-install on `composer install` (api via CaptainHook + `post-install-cmd`) and `bun install` (Nuxt repos via Husky `prepare` script); staged PHP violations are rejected by Pint `--dirty`; staged Vue/TS files are auto-fixed + re-staged by lint-staged (ESLint → Prettier); CI enforces `prettier --check .` (Nuxt) and `pint --test` (api) as required, non-`continue-on-error` steps.

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
| Integration | `docker-compose up` → infra + 3 app services healthy; each app boots against PostgreSQL/Redis | Wrapper compose smoke (CI) + manual |
| Docker build (all 3 apps) | Multi-stage image builds; final image non-root, healthcheck present, reasonably small | CI `docker build` step per app (required); manual `docker run` health probe |
| Toolchain (Bun/Node) | Bun installs/builds; Vitest + Playwright run on Node; `frontend` SSR image runs Nitro node-server on Node | Verified by the app CI (Bun install/build steps + Node test steps both green) |
| Coverage gate | Authored code ≥ 85% each repo (generated client excluded) | PCOV / Vitest v8, scoped includes (D9) |
| Versioning | Each repo seeded `0.1.0`; tag format `vM.m.p` | Manual verification of SoT + tag on first release (D16) |
| Pre-commit hooks | Hooks auto-install on `composer install` / `bun install`; staged PHP violation → commit rejected; staged Vue/TS → auto-fixed + re-staged | Manual trigger (commit a violating file in each repo) + CI `prettier --check .` / `pint --test` required steps (D19, D20) |
| Test database (api) | `beai_test` created in docker-compose init; `.env.testing` + `phpunit.xml` override point to PostgreSQL `beai_test`; CI PostgreSQL service healthy + migrate before Pest | `php artisan test` targeting `beai_test` passes; CI job green with PostgreSQL service; zero SQLite references (D21) |
| Migration standards | N/A in C1 (no domain migrations); standards are established for C2–C13 | Code-review checklist: `down()` correct, `organization_id` first in composites, 3NF, FK indexed, no undocumented redundancy (D22) |

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
- [x] `backoffice` static serve base image — **resolved in D25**: `nginx:1.27-alpine` (stable, non-root capable, well-known).
- [x] Bun + Node version pins — **resolved in D25**: `oven/bun:1.3` + `node:24-slim`; exact patch locked in `bun.lock`.
- [ ] JWT refresh/denylist details (access+refresh TTLs, Redis denylist key shape) — **owned by C2**; C1 only installs the package unwired.
- [ ] Auth is JWT bearer (not Sanctum) → **no shared-domain constraint**; the only cross-origin need is CORS allow-listing the backoffice origin on `api`, which is C2 config, not a DNS/domain blocker.

---

## Version Catalog (D25)

Authoritative reference for all pinned versions used in C1. Update this table when a version is intentionally bumped — no other place should diverge from it. Patch-level locking happens in `composer.lock` / `bun.lock`; the entries below define the **minimum accepted minor version** and the **Docker image tag** used everywhere.

### Docker Base Images

| Image | Tag | Used in |
|-------|-----|---------|
| PostgreSQL + pgVector | `pgvector/pgvector:0.8.0-pg17` | docker-compose, CI services |
| Redis | `redis:8.0-alpine` | docker-compose, CI services |
| Mailpit | `axllent/mailpit:v1.22` | docker-compose |
| PHP-FPM | `php:8.5.8-fpm-alpine` | `api` Dockerfile (build + runtime stage) |
| Bun (build) | `oven/bun:1.3` | `frontend` + `backoffice` Dockerfile build stage; CI install/build |
| Node (SSR runtime) | `node:24-slim` | `frontend` Dockerfile runtime stage; CI Vitest + Playwright runner |
| Nginx (static) | `nginx:1.27-alpine` | `backoffice` Dockerfile runtime stage |

### Runtime & Framework Versions

| Component | Version | Notes |
|-----------|---------|-------|
| PHP | `8.5.8` | Latest stable 8.5.x patch (July 2026); fully compatible with Laravel 13 (`requires php ^8.2`); patch locked via `php:8.5.8-fpm-alpine` Docker image tag and `composer.lock` |
| Laravel | `^13.0` | Major framework version; exact minor locked in `composer.lock` |
| PostgreSQL | `17` | Via `pgvector/pgvector:0.8.0-pg17`; must match Supabase project major |
| pgVector extension | `0.8.x` | Bundled in the Docker image above; also available on Supabase natively |
| Redis | `8.0` | Via `redis:8.0-alpine` |
| Bun | `1.3` | Via `oven/bun:1.3`; patch locked in `bun.lock` |
| Node | `24 LTS` | Via `node:24-slim`; Long-Term Support active |
| Nuxt | `^4.0` | Latest stable 4.x; patch locked in `bun.lock` |
| Docker Compose | v2 | `docker compose` (no hyphen); minimum v2.24 |

### PHP Packages (`composer.json` constraints)

| Package | Constraint | Purpose |
|---------|-----------|---------|
| `laravel/framework` | `^13.0` | Framework (via `laravel/laravel` scaffold) |
| `pestphp/pest` | `^4.0` | Test runner (bumped from `^3.0`: Laravel 13 requires PHPUnit 12, which Pest 3 does not support) |
| `pestphp/pest-plugin-laravel` | `^4.0` | Pest Laravel integration (tracks Pest 4) |
| `dedoc/scramble` | `^0.13` | OpenAPI spec generation (bumped from `^0.12`: 0.12 supports Laravel ≤12 only; 0.13 adds Laravel 13) |
| `tymon/jwt-auth` | `^2.2` | JWT auth (not wired in C1; wired in C2) |
| `spatie/laravel-permission` | `^6.0` | RBAC — teams mode (not wired in C1) |
| `laravel/pint` | `^1.18` | PHP code formatter (CI lint + pre-commit) |
| `captainhook/captainhook` | `^5.24` | PHP pre-commit hook runner |
| `phpstan/phpstan` | `^2.0` | PHP static analysis (required CI step; see D28) |
| `larastan/larastan` | `^3.0` | PHPStan Laravel extension (Eloquent + facade inference; see D28) |

### JS / Bun Packages (`package.json` constraints — both Nuxt apps)

| Package | Constraint | Purpose |
|---------|-----------|---------|
| `nuxt` | `^4.0` | Full-stack framework |
| `@nuxtjs/i18n` | `^9.0` | Internationalisation |
| `openapi-typescript` | `^7.0` | API client codegen from `openapi.json` |
| `vitest` | `^3.0` | Unit test runner (runs on Node) |
| `@vue/test-utils` | `^2.4` | Vue component test utilities |
| `@playwright/test` | `^1.52` | E2E browser test runner (runs on Node) |
| `husky` | `^9.1` | Git hook manager (JS repos) |
| `lint-staged` | `^15.0` | Staged-file pre-commit formatter |
| `prettier` | `^3.5` | Code formatter |
| `eslint` | `^9.0` | Linter (with Nuxt-compatible flat config) |
| `typescript` | `^5.8` | TypeScript compiler |
| `tailwindcss` | `^4.0` | CSS utility framework (see D26) |
| `@tailwindcss/vite` | `^4.0` | Vite plugin for Tailwind v4 JIT (Nuxt uses Vite internally) |
| `@tailwindcss/forms` | `^0.5` | Tailwind forms plugin (resets + styled base for form elements) |
| `@tailwindcss/typography` | `^0.5` | Tailwind prose plugin (rich text formatting) |
| `@axe-core/playwright` | `^4.10` | Accessibility assertions in Playwright E2E (WCAG 2.1 AA; see D29) |

> **Rule**: when any entry in this catalog changes, update this table, D24/D25 rationale, and CLAUDE.md (if it affects the stack description) in the same commit. The SDD version catalog and CLAUDE.md must never diverge.
