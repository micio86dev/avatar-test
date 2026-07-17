# Design: Framework Catalog (C3)

## D37 Dependency Check (report first)

`spatie/laravel-translatable` **is compatible** with Laravel 13 / PHP 8.5.
- Installed `spatie/laravel-permission 6.25.0` already declares `illuminate/* ^13.0` in this exact `api/composer.lock` → the ecosystem resolves against Laravel 13.
- `spatie/laravel-translatable` v6 requires `illuminate/{database,support,contracts}: ...|^13.0` and `php: ^8.2` (satisfied by `^8.5`); no `<8.5` upper bound.
- **Pinned: `spatie/laravel-translatable: ^6.11`** (add to `api/composer.json` `require`).
- Apply phase MUST confirm with `composer require spatie/laravel-translatable:^6.11 --dry-run` in `./api`. If v6 lacks an `^13.0` constraint at apply time → **blocked pinned dependency (D37): STOP + report, do NOT substitute.**

## Technical Approach

Two-layer model (locked). GLOBAL base catalog — `Role`, `Competency`, `BarsIndicator` — as plain `Model` (no `organization_id`, seeded once, orgs cannot mutate). Tenant-scoped `FrameworkVersion` extends `TenantModel` (C2), pinning WHICH catalog version an org uses. Translatable `{it,en}` JSON columns via spatie. Idempotent, graceful `FrameworkCatalogSeeder` reads the binding JSON, seeds EN + present BARS, and records gaps as authoring tasks. Read-only org-scoped API resolves through the org's pinned version.

## Architecture Decisions

### Decision: Version binding = pointer + immutability (not row-versioning)
| Option | Tradeoff | Decision |
|---|---|---|
| Version-tag every catalog row (`version_id` on roles/competencies/bars) | Full snapshot isolation, but duplicates the whole catalog per version, breaks the "shared global base" lock | Rejected |
| `FrameworkVersion` = pointer to a global `catalog_revision` int; immutable once referenced by C4 | Single shared base; a version = a labeled, frozen revision number | **Chosen** |

**Rationale**: The lock says global base + additive future overrides, NOT per-org copies. A `FrameworkVersion` carries `version` tag + `catalog_revision` (monotonic int bumped by the seeder on structural change) + `is_locked`. C4 sets `is_locked=true` on pin; a locked version's `catalog_revision` may never change. Future per-org overrides (out of scope) attach as additive rows keyed by `framework_version_id`, never base mutations.

### Decision: standard vs potential via `competencies.type` enum
`competencies.type ∈ {standard, potential}`. MTG/LAT (absent, non-goal) will be `potential`; the 18 present are `standard`. Rejected a boolean `is_potential` — enum is extensible and self-documenting. Rejected a separate table — same shape, needless join.

### Decision: `role_competency` pivot (not JSON array on role)
Normalized pivot (`role_id`, `competency_id`, `position`) per D22/3NF. Enables `bars_indicators (role_id, competency_id)` FKs and per-role BARS. JSON array rejected — unqueryable, unindexable, no referential integrity.

### Decision: locale read = default `it`, fallback `en`
`config('app.fallback_locale')='en'`, translatable default `it`. Spatie returns requested locale; empty IT transparently falls back to EN. API `?locale=` (validated ∈ configured) overrides request locale. No per-endpoint locale logic — accessor-level.

## Schema / Migrations (D22: 3NF, reversible, indexed)

| Table | Columns | Notes |
|---|---|---|
| `roles` | id, `code` (unique), `name` json, `responsibilities` json, timestamps | translatable name+responsibilities |
| `competencies` | id, `code` (unique), `name` json, `definition` json, `type` (enum), timestamps | translatable name+definition |
| `role_competency` | id, role_id fk, competency_id fk, `position`, unique(role_id,competency_id) | pivot; ordered |
| `bars_indicators` | id, role_id fk, competency_id fk, `text` json, `anchor_5` json, `anchor_3` json, `anchor_1` json, `position`, unique(role_id,competency_id,position) | translatable text+anchors |
| `framework_versions` | id, **organization_id** fk, `version`, `catalog_revision`, `is_locked` bool, `notes`, timestamps | extends TenantModel |

Indexes: `framework_versions` composite **`(organization_id, version)` unique**, org_id-first per C2 convention. `bars_indicators (role_id, competency_id)`. All migrations reversible (`down()` drops in FK order). Translatable columns are `json` (spatie stores `{"it":..,"en":..}`).

## spatie/laravel-translatable wiring
- Install `^6.11`; add `HasTranslations` + `public array $translatable` to `Role`, `Competency`, `BarsIndicator`.
- `Role::$translatable = ['name','responsibilities']`; `Competency = ['name','definition']`; `BarsIndicator = ['text','anchor_5','anchor_3','anchor_1']`.
- Columns cast implicitly by the trait; read via `->name` (current locale) or `->getTranslation('name','en')`.

## Seeder Design — `FrameworkCatalogSeeder`
```
JSON files ─► NormalizerAdapter ─► upsert(by code) ─► GapReport
  roles.json         (split OR unified          idempotent      logs +
  competencies.json   competency shape)          no dupes        framework_gaps
  bars/{ROLE}.json
```
- **Idempotent**: `updateOrCreate(['code'=>..])` for roles/competencies; `role_competency` `syncWithoutDetaching` by (role,competency); `bars_indicators` upsert by (role,competency,position). Re-run = zero dupes.
- **Graceful**: missing `bars/{ROLE}.json` (SRX, MLL-if-absent) → seed role + its `role_competency`, SKIP indicators, record gap, continue. Never throws on missing file.
- **Adapter**: `CompetencyNormalizer` accepts split shape (`competencies.json` + `bars/*`) OR a future unified object; emits a canonical DTO. One switch point tolerates both.
- **EN-only**: writes `name/definition/anchors` to `en`; `it` left null (open decision #6) and flagged.
- **BUL 8/14**: seeds 14 `role_competency` rows; only 8 have BARS → 6 competencies flagged `bars_missing`.
- Runs once via `DatabaseSeeder`; bumps `catalog_revision` only on structural change.

## Data-Gap Tracking
`framework_gaps` table (or seeder-emitted `storage/framework/gaps.json` + `Log::warning`): `{kind: role_no_bars|competency_no_bars|missing_translation|missing_role_meta, ref, detail}`. Seeder populates it so gaps are queryable, not silent. Known seeds: SRX (no bars, empty responsibilities), MTG/LAT (absent, non-goal), BUL 6 competencies (no bars), all IT translations. C9/authoring consume this list.

## Read API (auth:api from C2, org-scoped)
| Method | Route | Returns |
|---|---|---|
| GET | `/api/framework/roles` | roles for org's pinned version |
| GET | `/api/framework/roles/{code}/competencies` | role's competencies (+type, +bars_available) |
| GET | `/api/framework/roles/{code}/competencies/{code}/indicators` | BARS indicators + anchors |

`FrameworkController` resolves the org's `FrameworkVersion` (tenant-scoped) → `catalog_revision` → global rows. `?locale=` validated. `RoleResource`/`CompetencyResource`/`BarsIndicatorResource` return the requested locale (spatie accessor). Read-only (no write endpoints in C3).

## Testing Strategy
| Layer | Test | Approach |
|---|---|---|
| Unit | Normalizer split↔unified | feed both shapes, assert same DTO |
| Feature | Idempotent seed | run seeder ×2, assert counts unchanged (no dupes) |
| Feature | Graceful missing file | remove SRX bars, assert role+pivot seeded, indicators skipped, gap recorded, no throw |
| Feature | Locale fallback | empty `it` → API returns `en`; `?locale=en` honored |
| Feature | Tenant-version isolation | org A pins v1, org B pins v2; each sees only its pinned catalog (bypass off) |
| Feature | Seeded-count correctness | assert role/competency/pivot/indicator counts vs JSON (ICO 15, FLL 18, MLL 18, BUL 14 pivots; BUL 8 bars sets) |

Correctness-critical (catalog integrity) → ~95% coverage.

## Delivery
Forecast ~450–550 changed lines (5 migrations + 4 models + seeder/adapter + gap tracker + controller + 3 resources + routes + ~6 test files).
- **400-line budget risk: Medium**
- **Chained PRs recommended: Yes** — 3 slices: (1) schema + models + spatie install, (2) seeder + adapter + gap tracking, (3) read API + resources + tests.
- **Decision needed before apply: Yes** (confirm chained-PR delivery).

## Out of Scope
Scoring (C9); project→framework_version FK + pin-at-creation (C4); per-org overrides (future); inventing SRX BARS / MTG-LAT / IT translations.

## Open Questions
- [ ] Open decision #3: `catalog_revision` semantics finalized in C4 pin flow.
- [ ] Open decision #6: IT anchor translations pending expert authoring (gates non-EN scoring in C9).
