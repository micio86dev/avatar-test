# Proposal: Project Skeleton & CI Foundation (C1)

## Intent

BEAI rebuilds an Astro avatar demo into a multi-tenant AI voice-interview platform across 12 vertical slices (C2–C13). None can start honestly without a shared, tested foundation. C1 delivers the greenfield monorepo, local dev infra, an end-to-end test harness (proven red→green), i18n scaffolding, documented Git Flow, and CI enforcing an 85% coverage gate. Success = a contributor clones, runs one command, gets both apps + MySQL/Redis, and every push runs lint+tests+coverage on green.

## Scope

### In Scope
- Monorepo: `api/` (Laravel 12 + Eloquent + MySQL 8 + Redis/Horizon), `web/` (Nuxt 4 + Vue 3 + `@nuxtjs/i18n`), demo relocated to `legacy-demo/` as reference.
- `docker-compose` for MySQL 8 + Redis; `.env.example` for both apps.
- Test harness wired end-to-end: Pest (api), Vitest + Vue Test Utils + Playwright (web).
- CI (GitHub Actions) on `develop`/PRs: lint + tests + 85% coverage gate. No deploy (Railway config parked, not activated).
- i18n it/en scaffolding: Laravel `lang/`, `@nuxtjs/i18n`.
- Health-check endpoint per app + one intentionally-failing smoke test each to prove TDD harness (red→green).
- Documented Git Flow branch model (`main`/`develop`, `feature/*`, `release/*`, `hotfix/*`).

### Out of Scope
- Any domain/business logic: tenancy, framework catalog, interview engine, scoring, webhooks (C2+).
- Live deploy / Railway activation; S3 storage; auth providers.
- The 7 open product decisions — none block C1.

## Capabilities

### New Capabilities
- `project-skeleton`: monorepo layout, local dev infra, i18n scaffolding, health-check endpoints.
- `ci-pipeline`: GitHub Actions lint/test/coverage-gate workflow and test-harness contract.

### Modified Capabilities
None (greenfield; no existing specs).

## Approach

- Scaffold `api/` (Laravel 12, Pest, Horizon config) and `web/` (Nuxt 4, Vitest, Playwright) as independent workspaces under one repo root; move Astro demo to `legacy-demo/`.
- `docker-compose.yml` provisions MySQL 8 + Redis; `.env.example` documents wiring.
- Prove the harness per app with a health-check route + a first-failing smoke test, then make it pass — locking the RED→GREEN loop CI depends on.
- One CI workflow with parallel `api`/`web` jobs: install, lint, test, enforce `--min=85`. Railway config committed but gated off.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `api/` | New | Laravel 12 app, Pest, Horizon, `lang/` it/en, health route |
| `web/` | New | Nuxt 4 app, Vitest/Playwright, `@nuxtjs/i18n` it/en, health page |
| `legacy-demo/` | Moved | Existing Astro demo relocated as reference |
| `docker-compose.yml`, `.env.example` | New | MySQL 8 + Redis local dev |
| `.github/workflows/` | New | Lint + test + 85% coverage gate CI |
| `config.yaml`, `docs/` | Modified | Flip test-command statuses; document Git Flow |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Coverage gate blocks trivial skeleton (little real code) | Med | Scope gate to authored code; smoke tests seed meaningful coverage |
| Monorepo CI complexity (2 stacks, path filters) | Med | Separate parallel jobs; keep workflow minimal in C1 |
| Demo relocation breaks references | Low | Move wholesale to `legacy-demo/`; no import from new apps |
| Local infra drift (versions) | Low | Pin MySQL 8 / Redis image tags in compose |

## Rollback Plan

Pure additive scaffolding on a `feature/*` branch. Rollback = revert the feature branch / delete `api/`, `web/`, compose, and workflow files; restore demo to root. No data or production impact (no deploy).

## Dependencies

- None (foundation change). Downstream C2–C13 depend on C1.

## Success Criteria

- [ ] `docker-compose up` brings MySQL 8 + Redis; both apps boot against them.
- [ ] Health endpoints respond 200 in `api/` and `web/`.
- [ ] Smoke test proven red→green in both apps.
- [ ] CI runs lint + tests + 85% coverage gate on PRs to `develop`, green.
- [ ] i18n it/en resolves on both sides; Git Flow documented.
- [ ] `config.yaml` test-command statuses flipped to scaffolded.
