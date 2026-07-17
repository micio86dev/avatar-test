# Tasks: Framework Catalog (C3)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | 450–550 |
| 400-line budget risk | Medium |
| Chained PRs recommended | Yes |
| Suggested split | PR1 → PR2 → PR3 (feature-branch-chain) |
| Delivery strategy | ask-on-risk |
| Chain strategy | pending |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: pending
400-line budget risk: Medium

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Schema + models + spatie install | PR1 | Base = `feature/framework-catalog`; ~150–180 lines |
| 2 | Seeder + adapter + gap tracking | PR2 | Base = PR1 branch; ~170–200 lines |
| 3 | Read API + resources + tests | PR3 | Base = PR2 branch; ~150–180 lines |

> Chain strategy must be confirmed (stacked-to-main or feature-branch-chain) before `sdd-apply` starts.

---

## Phase 1: D37 Dependency Check (blocking — do first)

- [ ] 1.1 In `./api`, run `composer require spatie/laravel-translatable:^6.11 --dry-run`; if L13 constraint fails → STOP and report; do NOT substitute or loosen the pin.
- [ ] 1.2 If dry-run passes, add `"spatie/laravel-translatable": "^6.11"` to `api/composer.json` `require` and run `composer require` for real; commit lock file.

---

## Phase 2: Schema + Migrations (PR1)

- [ ] 2.1 Create migration `create_roles_table`: columns `id`, `code` (unique), `name` (json), `responsibilities` (json), timestamps. No `organization_id`. Reversible `down()`.
- [ ] 2.2 Create migration `create_competencies_table`: columns `id`, `code` (unique), `name` (json), `definition` (json), `type` (enum `standard|potential`), timestamps. No `organization_id`. Reversible `down()`.
- [ ] 2.3 Create migration `create_role_competency_table`: pivot with `role_id` FK, `competency_id` FK, `position`; unique constraint on `(role_id, competency_id)`. Reversible.
- [ ] 2.4 Create migration `create_bars_indicators_table`: `id`, `role_id` FK, `competency_id` FK, `text` (json), `anchor_5` (json), `anchor_3` (json), `anchor_1` (json), `position`; unique `(role_id, competency_id, position)`; composite index `(role_id, competency_id)`. Reversible.
- [ ] 2.5 Create migration `create_framework_versions_table`: `id`, `organization_id` FK, `version` (string), `catalog_revision` (int), `is_locked` (bool default false), `notes` (text nullable), timestamps; unique composite index `(organization_id, version)` with `organization_id` first. Reversible.

---

## Phase 3: Eloquent Models (PR1)

- [ ] 3.1 Create `api/app/Models/Role.php`: extends plain `Model` (NOT TenantScoped); `HasTranslations`; `$translatable = ['name', 'responsibilities']`; `$fillable` set.
- [ ] 3.2 Create `api/app/Models/Competency.php`: extends plain `Model`; `HasTranslations`; `$translatable = ['name', 'definition']`; cast `type` as enum.
- [ ] 3.3 Create `api/app/Models/BarsIndicator.php`: extends plain `Model`; `HasTranslations`; `$translatable = ['text', 'anchor_5', 'anchor_3', 'anchor_1']`; belongs-to `Role`, belongs-to `Competency`.
- [ ] 3.4 Create `api/app/Models/FrameworkVersion.php`: extends `TenantModel` (C2); `$fillable` includes `version`, `catalog_revision`, `is_locked`, `notes`; add `immutabilityGuard()` — blocks delete/update when `is_locked = true` (use model `deleting` event or policy); hasMany relationship to future C4 `Project`.

---

## Phase 4: RED tests — schema + models (PR1, TDD)

- [ ] 4.1 **RED** `tests/Unit/Models/GlobalTablesHaveNoOrgIdTest.php`: assert `roles`, `competencies`, `bars_indicators` tables have no `organization_id` column (schema inspection). Refs spec: "Global tables carry no organization_id".
- [ ] 4.2 **RED** `tests/Unit/Models/FrameworkVersionCompositeIndexTest.php`: assert `framework_versions` primary lookup index leads with `organization_id`. Refs spec: "FrameworkVersion composite index leads with organization_id".
- [ ] 4.3 **RED** `tests/Feature/Models/FrameworkVersionImmutabilityTest.php`: attempt delete of a locked `FrameworkVersion`; assert rejection + record intact. Refs spec: "A referenced FrameworkVersion cannot be deleted".
- [ ] 4.4 **RED** `tests/Unit/Models/TranslatableLocaleTest.php`: set `it` + `en` on a `Competency`; assert `->name` returns the active locale; assert fallback to `en` when `it` empty. Refs spec: locale fallback scenarios.

---

## Phase 5: GREEN — make Phase 4 tests pass (PR1)

- [ ] 5.1 Run `php artisan migrate` on test DB; verify Phases 2–3 implementations satisfy 4.1–4.4; fix until green.

---

## Phase 6: CompetencyNormalizer Adapter (PR2)

- [ ] 6.1 Create `api/app/Services/FrameworkCatalog/DTO/CompetencyDTO.php` + `IndicatorDTO.php`: canonical DTOs carrying code, translations, type, BARS anchors.
- [ ] 6.2 Create `api/app/Services/FrameworkCatalog/CompetencyNormalizer.php`: accepts split shape (`competencies.json` array entry + separate BARS array) OR unified shape (single entry with embedded BARS); auto-detects shape by key presence; emits `CompetencyDTO`. Single switch-point; no config flag.

---

## Phase 7: FrameworkCatalogSeeder (PR2)

- [ ] 7.1 Create `api/database/seeders/FrameworkCatalogSeeder.php`:
  - Read `docs/app_description/02-domain/framework/roles.json` + `competencies.json`.
  - `updateOrCreate(['code' => ...])` for `Role` (writes EN translations to `name`, `responsibilities`).
  - `updateOrCreate(['code' => ...])` for `Competency` (writes EN `name`, `definition`; sets `type = standard` for the 18).
  - `syncWithoutDetaching` for `role_competency` pivot per role (ICO 15, FLL 18, MLL 18, BUL 14, SRX competencies).
  - Iterate `bars/{ROLE}.json` for ICO, FLL, MLL, BUL; upsert `bars_indicators` by `(role_id, competency_id, position)`.
  - Missing `bars/SRX.json` → skip indicators for SRX, log `Log::warning`, record gap row `{kind: role_no_bars, ref: SRX, ...}`.
  - BUL competencies in `roles.json` but absent from `bars/BUL.json` → record gap `{kind: competency_no_bars, ref: BUL.{code}}` for each (expected: 6 gaps).
  - MTG/LAT absent in all JSON → record gap `{kind: missing_potential_competency, ref: MTG}` + `{..., ref: LAT}`.
  - All IT translations left null; record gap `{kind: missing_translation, ref: *, detail: it locale}`.
  - Bump `catalog_revision` only when structural rows are added/changed.
- [ ] 7.2 Create `api/database/migrations/create_framework_gaps_table.php`: `id`, `kind` (string), `ref` (string), `detail` (text nullable), `status` (default `pending_authoring`), timestamps. Referenced by seeder.
- [ ] 7.3 Register `FrameworkCatalogSeeder` in `api/database/seeders/DatabaseSeeder.php`.

---

## Phase 8: RED tests — seeder + adapter (PR2, TDD)

- [ ] 8.1 **RED** `tests/Feature/Seeders/IdempotentSeedTest.php`: run seeder ×2; assert `Role::count()`, `Competency::count()`, `RoleCompetency::count()`, `BarsIndicator::count()` identical after both runs. Refs spec: "Second run produces no duplicates".
- [ ] 8.2 **RED** `tests/Feature/Seeders/GracefulMissingFileTest.php`: fake `bars/SRX.json` absent; run seeder; assert no exception thrown, SRX `Role` exists, `BarsIndicator` for SRX = 0, a gap row with `ref=SRX` exists. Refs spec: "Missing bars/SRX.json is skipped gracefully".
- [ ] 8.3 **RED** `tests/Feature/Seeders/SeededCountCorrectnessTest.php`: assert `Role::count() == 5`; `Competency::count() == 18`; pivot rows: ICO=15, FLL=18, MLL=18, BUL=14, SRX= role competencies from `roles.json`. Refs spec: "First run seeds roles and competencies from JSON".
- [ ] 8.4 **RED** `tests/Feature/Seeders/MtgLatAbsentGapTest.php`: after seed, assert no `Competency` with code `MTG` or `LAT`; assert gap rows for both exist. Refs spec: "MTG/LAT absent — potential catalog flagged incomplete".
- [ ] 8.5 **RED** `tests/Feature/Seeders/BulPartialBarsGapTest.php`: after seed, assert `BarsIndicator` rows for BUL = 8 sets; assert 6 gap rows with `kind=competency_no_bars` and `ref` starting with `BUL.`. Refs spec: "BUL BARS file seeds only present competencies".
- [ ] 8.6 **RED** `tests/Unit/Services/CompetencyNormalizerTest.php`: feed split shape → assert DTO; feed unified shape → assert same DTO. Refs spec: "Split-file shape" + "Unified shape produces the same DB state".
- [ ] 8.7 **RED** `tests/Feature/Seeders/ReseedAfterGapFixTest.php`: seed once with SRX missing; add a fake `bars/SRX.json`; reseed; assert SRX indicators inserted, total counts for other roles unchanged. Refs spec: "Re-seeding after correcting a gap adds the missing rows".

---

## Phase 9: GREEN — make Phase 8 tests pass (PR2)

- [ ] 9.1 Run all Phase 8 tests; fix seeder and adapter until fully green; no shortcuts on idempotency.

---

## Phase 10: Read API — Controller + Resources (PR3)

- [ ] 10.1 Create `api/app/Http/Controllers/Api/FrameworkController.php`:
  - `index()` — resolve `FrameworkVersion` for auth org (TenantScoped); use `catalog_revision` to serve global roles; return `RoleResource::collection`.
  - `roleCompetencies(string $roleCode)` — list competencies for role + `bars_available` flag + `type`.
  - `competencyBars(string $roleCode, string $competencyCode)` — list `BarsIndicator` rows for the pair.
  - `?locale=` param: validate against `config('app.supported_locales')`; call `App::setLocale()`; spatie accessor handles fallback.
- [ ] 10.2 Create `api/app/Http/Resources/RoleResource.php`: `code`, `name` (current locale), `responsibilities`, `competency_count`.
- [ ] 10.3 Create `api/app/Http/Resources/CompetencyResource.php`: `code`, `name`, `definition`, `type`, `bars_available`.
- [ ] 10.4 Create `api/app/Http/Resources/BarsIndicatorResource.php`: `position`, `text`, `anchor_5`, `anchor_3`, `anchor_1`; include `translation_gap` flag if `it` requested but missing.
- [ ] 10.5 Register routes in `api/routes/api.php` under `auth:api` middleware group:
  - `GET /framework/roles`
  - `GET /framework/roles/{roleCode}/competencies`
  - `GET /framework/roles/{roleCode}/competencies/{competencyCode}/indicators`

---

## Phase 11: RED tests — Read API + tenant isolation (PR3, TDD)

- [ ] 11.1 **RED** `tests/Feature/Api/FrameworkRolesListTest.php`: authenticated org-A user calls `GET /api/framework/roles`; assert 200, all 5 roles returned, no org-B data. Refs spec: "Org A user lists roles".
- [ ] 11.2 **RED** `tests/Feature/Api/CrossTenantIsolationTest.php`: org-B user with org-A `organization_id` injected; assert response reflects org-B pinned version only. Refs spec: "Cross-tenant isolation".
- [ ] 11.3 **RED** `tests/Feature/Api/TenantVersionIsolationTest.php`: org A pins v1 catalog_revision, org B pins v2; each `GET /api/framework/roles` call returns correct version-scoped data. Refs design testing strategy: "tenant-version isolation".
- [ ] 11.4 **RED** `tests/Feature/Api/FrameworkBarsEndpointTest.php`: ICO × PRS call; assert response contains indicators with non-null `anchor_5`, `anchor_3`, `anchor_1`. Refs spec: "Requesting competency BARS returns indicators".
- [ ] 11.5 **RED** `tests/Feature/Api/LocaleFallbackApiTest.php`: seed EN-only indicator; call `?locale=it`; assert response returns EN text; assert `translation_gap=true` in response. Refs spec: "Locale-aware response falls back to EN when IT is absent".
- [ ] 11.6 **RED** `tests/Feature/Api/PartialCatalogApiTest.php`: catalog in partial state (SRX BARS absent); call `GET /api/framework/roles`; assert 200, SRX listed, no 500. Refs spec: "API responds correctly with partial catalog".

---

## Phase 12: GREEN — make Phase 11 tests pass (PR3)

- [ ] 12.1 Run all Phase 11 tests; fix controller, resources, routes until fully green.

---

## Phase 13: Cleanup + PR Readiness

- [ ] 13.1 Run full Pest suite (`php artisan test`); fix any regressions; confirm ~95% coverage on correctness-critical paths (seeder + API).
- [ ] 13.2 Run `php artisan migrate:rollback` on test DB; verify all `down()` methods restore pre-C3 schema cleanly.
- [ ] 13.3 Add authoring-task note to `openspec/changes/framework-catalog/` (or `docs/`) listing known gaps: `bars/SRX.json`, MTG/LAT defs, IT translations, BUL 6 competencies — each with status `pending_authoring`.
- [ ] 13.4 Confirm `FrameworkVersion` is listed in the OpenAPI spec via Scramble (no extra effort if routes are registered; just verify).
