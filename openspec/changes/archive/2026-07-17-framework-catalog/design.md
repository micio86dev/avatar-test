# Design: Framework Catalog (C3)

## D37 Dependency Check (report first)

`spatie/laravel-translatable` **is compatible** with Laravel 13 / PHP 8.5.
- Installed `spatie/laravel-permission 6.25.0` already declares `illuminate/* ^13.0` in this exact `api/composer.lock` → the ecosystem resolves against Laravel 13.
- `spatie/laravel-translatable` v6 requires `illuminate/{database,support,contracts}: ...|^13.0` and `php: ^8.2` (satisfied by `^8.5`); no `<8.5` upper bound.
- **Pinned: `spatie/laravel-translatable: ^6.11`** (add to `api/composer.json` `require`).
- Apply phase MUST confirm with `composer require spatie/laravel-translatable:^6.11 --dry-run` in `./api`. If v6 lacks an `^13.0` constraint at apply time → **blocked pinned dependency (D37): STOP + report, do NOT substitute.**

## Technical Approach

Two-layer model (locked). GLOBAL base catalog — `Role`, `Competency`, `BarsIndicator` — as plain `Model` (no `organization_id`, seeded once, orgs cannot mutate). In C3 the global catalog is a **mutable WORKING DRAFT** — freely re-seedable. Tenant-scoped `FrameworkVersion` extends `TenantModel` (C2), pinning WHICH catalog version an org uses. TRUE immutability (snapshot isolation) is achieved in **C4** when a `FrameworkVersion` is pinned to a project by taking an immutable snapshot of the catalog at that moment; the snapshot mechanism is designed and built in C4 — out of C3 scope. Translatable `{it,en}` JSON columns via spatie. Idempotent, graceful `FrameworkCatalogSeeder` reads the binding JSON, seeds EN + present BARS, and records gaps as authoring tasks. Read-only org-scoped API resolves through the org's pinned version.

## Architecture Decisions

### Decision: Version binding = SNAPSHOT-AT-PIN (C4); C3 catalog is a WORKING DRAFT
| Option | Tradeoff | Decision |
|---|---|---|
| Version-tag every catalog row (`version_id` on roles/competencies/bars) | Full snapshot isolation, but duplicates the whole catalog per version, breaks the "shared global base" lock | Rejected |
| `FrameworkVersion` in C3 is a DRAFT label; C4 takes an immutable snapshot at pin time | Single shared mutable base in C3; isolation guaranteed at C4 pin by snapshot | **Chosen** |

**Rationale**: The C3 global catalog is a WORKING DRAFT — freely re-seedable (sync delete-stale is intentional). `FrameworkVersion` in C3 is a draft label carrying `version` (tag), `is_locked` (bool, default false), and optionally `label`. `catalog_revision` is an **informational monotonic marker only** — a `catalog_meta` singleton row bumped by the seeder when structural data changes, used for cache-busting / "catalog changed" signalling; it is NOT a per-version row discriminator and does NOT deliver immutability. TRUE immutability is achieved in **C4** by taking an immutable snapshot of the catalog at pin time (designed and built in C4, out of C3 scope). C4 sets `is_locked=true` on pin; once locked, the version is a forward-looking guard reference — C4 activates it, C3 does NOT enforce immutability. Future per-org overrides (out of scope) attach as additive rows keyed by `framework_version_id`, never base mutations.

### Decision: standard vs potential via `competencies.type` enum
`competencies.type ∈ {standard, potential}`. MTG/LAT (absent, non-goal) will be `potential`; the 18 present are `standard`. Rejected a boolean `is_potential` — enum is extensible and self-documenting. Rejected a separate table — same shape, needless join.

### Decision: `framework_role_competency` pivot (not JSON array on role)
Normalized pivot (`role_id`, `competency_id`, `position`) per D22/3NF. Enables `framework_bars_indicators (role_id, competency_id)` FKs and per-role BARS. JSON array rejected — unqueryable, unindexable, no referential integrity.

### Decision: locale resolution order — `?locale=` → `Accept-Language` → `fallback_locale` (`en`)
`config('app.fallback_locale')='en'`. Effective locale resolution order for all read endpoints: (1) `?locale=` query param — validated ∈ `config('app.supported_locales')`; (2) `Accept-Language` request header — parsed and matched against `supported_locales`; (3) `config('app.fallback_locale')` = `en`. When no `?locale=` and no matchable `Accept-Language` header is present, the effective default locale is **`en`** (via `fallback_locale`), NOT `it`. IT is the primary **authoring** locale (the one content is authored in first), which is distinct from the effective request default. Spatie fallback is NOT automatic from `config('app.fallback_locale')` alone — publish `config/translatable.php` (`php artisan vendor:publish --tag=translatable`) and set `translatable.fallback_locale = 'en'` (or call `useFallbackLocale('en')` on each model) to activate the spatie-level locale fallback. `App::setLocale()` is called once per request after resolution; spatie accessor handles the per-field fallback transparently. No per-endpoint locale logic — accessor-level.

## Schema / Migrations (D22: 3NF, reversible, indexed)

> **Prefix note**: Catalog tables are prefixed `framework_` to avoid collision with spatie/laravel-permission's `roles` table (C2); Eloquent models set `$table` explicitly.

| Table | Columns | Notes |
|---|---|---|
| `framework_roles` | id, `code` (unique), `name` json, `responsibilities` json, timestamps | translatable name+responsibilities |
| `framework_competencies` | id, `code` (unique), `name` json, `definition` json, `type` (enum), timestamps | translatable name+definition |
| `framework_role_competency` | id, role_id fk, competency_id fk, `position`, unique(role_id,competency_id) | pivot; ordered |
| `framework_bars_indicators` | id, role_id fk, competency_id fk, `text` json, `anchor_5` json, `anchor_3` json, `anchor_1` json, `position`, unique(role_id,competency_id,position) | translatable text+anchors |
| `framework_versions` | id, **organization_id** fk, `version`, `is_locked` bool default false, `label` (string nullable), timestamps | extends TenantModel; `label` = human display name for this version draft |
| `catalog_meta` | id, `revision` (unsignedBigInteger default 0), timestamps | singleton cache-busting counter; bumped by seeder on structural changes; no per-version discriminator role |
| `framework_gaps` | id, `kind` (string), `role_code` (string nullable), `competency_code` (string nullable), `note` (text nullable), `status` (string default `pending_authoring`), timestamps; unique `(kind, role_code, competency_code)` **`NULLS NOT DISTINCT`** (Postgres 15+/17) — role-level gaps (`role_no_bars`, `missing_role_meta`) have null `competency_code`; `missing_translation` has both null; `missing_potential_competency` has null `role_code`; `NULLS NOT DISTINCT` ensures these NULL-containing rows ARE treated as equal and cannot duplicate at the DB level | seeder-populated gap registry; queryable authoring task list; seeder uses `updateOrCreate` on the natural key (belt-and-suspenders app-layer guard) — NOT blind insert |

Indexes: `framework_versions` composite **`(organization_id, version)` unique**, org_id-first per C2 convention. `framework_bars_indicators (role_id, competency_id)`. `framework_gaps (kind, role_code)` plus **unique `(kind, role_code, competency_code)` `NULLS NOT DISTINCT`** (idempotency key; declared `NULLS NOT DISTINCT` so NULL `role_code` or `competency_code` values are treated as equal — without this, PostgreSQL standard unique indexes treat NULLs as distinct, allowing duplicate gap rows). All migrations reversible (`down()` drops in FK order). Translatable columns are `json` (spatie stores `{"it":..,"en":..}`).

> **`catalog_revision` note**: there is no `catalog_revision` column on `framework_versions`. Cache-busting / "catalog changed" detection is handled via a separate `catalog_meta` singleton table (a single row with a monotonic `revision` int bumped by the seeder on structural changes). `framework_versions` does NOT need to track revision because immutability is snapshot-at-pin (C4), not revision-locking.

## spatie/laravel-translatable wiring
- Install `^6.11`; run `php artisan vendor:publish --tag=translatable` to publish `config/translatable.php`; set `'fallback_locale' => 'en'` in that config (or call `useFallbackLocale('en')` on each model).
- Add `HasTranslations` + `public array $translatable` to `Role`, `Competency`, `BarsIndicator`.
- `Role::$translatable = ['name','responsibilities']`; `Competency = ['name','definition']`; `BarsIndicator = ['text','anchor_5','anchor_3','anchor_1']`.
- Columns cast implicitly by the trait; read via `->name` (current locale) or `->getTranslation('name','en')`.
- Translation gap detection uses `$model->hasTranslation('field', 'it')` (a real presence check), NOT testing whether the value is empty — empty-string IT would otherwise produce false negatives.

## Seeder Design — `FrameworkCatalogSeeder`
```
JSON files ─► NormalizerAdapter ─► upsert(by code) ─► GapReport
  roles.json         (split OR unified          idempotent      logs +
  competencies.json   competency shape)          no dupes        framework_gaps
  bars/{ROLE}.json
```
- **Idempotent + delete-stale (sync)**: `updateOrCreate(['code'=>..])` for roles/competencies; `framework_role_competency` pivot uses `sync` (not `syncWithoutDetaching`) — removes stale pivots when roles.json removes a competency from a role; `framework_bars_indicators` upsert by (role,competency,position) AND deletes rows no longer in the JSON for that (role,competency) pair. This is INTENTIONAL draft behavior: re-seeding reflects the JSON exactly, eliminating orphan rows. (Snapshots taken at C4 pin time are what remain immutable.)
- **Graceful**: missing `bars/{ROLE}.json` (SRX has no file) → seed role + its `framework_role_competency`, SKIP indicators, record gap `{kind: role_no_bars}`, continue. Never throws on missing file.
- **BARS coverage per-role**: for every role that HAS a BARS file, the seeder compares the role's assigned competencies (from `framework_role_competency`) against the keys present in its BARS file. Each competency assigned but absent from the BARS file is flagged `{kind: competency_no_bars, role_code: ROLE, competency_code: CODE}`. Known gaps at first seed: FLL 10 gaps, MLL 10 gaps, BUL 6 gaps (see Data-Gap Tracking below).
- **Adapter**: `CompetencyNormalizer` accepts split shape (`competencies.json` + `bars/*`) OR a future unified object; emits a canonical DTO. One switch point tolerates both.
- **EN-only**: writes `name/definition/anchors` to `en` via `setTranslation('field', 'en', value)` (NOT bulk `updateOrCreate` on the JSON column). A re-seed merges the EN translation without overwriting manually-added translations in other locales (e.g. IT added between seeds survives). `it` left null initially (open decision #6) and flagged.
- **Per-role BARS coverage summary**: ICO 15/15, FLL 8/18, MLL 8/18, BUL 8/14, SRX 0/18.
- Runs once via `DatabaseSeeder`; bumps `catalog_meta.revision` only on structural change.

## Data-Gap Tracking
`framework_gaps` **table** (a proper migration — see Schema section): columns `kind`, `role_code` (nullable), `competency_code` (nullable), `note` (nullable), `status` (default `pending_authoring`). Seeder populates it so gaps are queryable, not silent. NOT a storage/*.json file.

Known gaps at first seed:
- SRX: `{kind: role_no_bars, role_code: SRX}` — no bars file exists
- SRX: `{kind: missing_role_meta, role_code: SRX}` — `responsibilities` is empty string in roles.json; seeder seeds it as-is (empty string is not a BARS error) and records this gap as an authoring task (client to provide responsibilities text). Do NOT flag as a BARS gap — it is a metadata authoring gap.
- FLL: 10 × `{kind: competency_no_bars, role_code: FLL, competency_code: CODE}` for PRS, JDG, DRV, SLF, TMG, COM, COL, NET, ITG, INC
- MLL: 10 × `{kind: competency_no_bars, role_code: MLL, competency_code: CODE}` for PRS, JDG, DRV, SLF, TMG, COM, COL, NET, ITG, INC
- BUL: 6 × `{kind: competency_no_bars, role_code: BUL, competency_code: CODE}` for PRS, JDG, DRV, TMG, COL, NET
- MTG/LAT: `{kind: missing_potential_competency, competency_code: MTG|LAT}` — absent from all JSON (non-goal for C3)
- All IT translations: `{kind: missing_translation, note: it locale not yet authored}`

C9/authoring consume this list.

## Read API (auth:api from C2, org-scoped)
| Method | Route | Returns |
|---|---|---|
| GET | `/api/framework/roles` | roles for org's pinned version |
| GET | `/api/framework/roles/{roleCode}/competencies` | role's competencies (+type, +bars_available); `bars_available` = true when the competency has ≥1 `framework_bars_indicators` row for that role (i.e. it is BARS-covered for that role); false for gap competencies (e.g. FLL/PRS, all SRX) |
| GET | `/api/framework/roles/{roleCode}/competencies/{competencyCode}/indicators` | BARS indicators + anchors |

Standard REST-nested form: the BARS resource is always scoped under both role and competency. The terminal segment is `/indicators` (not `/bars`). `FrameworkController` serves the global catalog for ANY authenticated org — a `FrameworkVersion` row is NOT required to exist. In C3 the catalog is a shared global working draft; version pinning enforcement is C4. The controller MUST NOT `firstOrFail()` on `FrameworkVersion`. If a `FrameworkVersion` row exists it MAY be surfaced as `pin_context` in the response metadata; if absent, the response is **200 with the global catalog** and `pin_context: null`. NEVER return 404 or 500 when no `FrameworkVersion` row exists. Locale resolution order: (1) explicit `?locale=` param — validated to be a member of `config('app.supported_locales')` (see prerequisite below); (2) `Accept-Language` request header — parsed and matched against `supported_locales`; (3) `config('app.fallback_locale')` (`en`). `App::setLocale()` is called once after resolution; spatie accessor handles the fallback transparently. `RoleResource`/`CompetencyResource`/`BarsIndicatorResource` return the resolved locale. `translation_gap` flag in `BarsIndicatorResource` is detected via `$model->hasTranslation('field', 'it')` on ALL four translatable fields — `text`, `anchor_5`, `anchor_3`, `anchor_1` — so that ANY missing locale translation on any field raises the flag (NOT just `text`, NOT by testing empty value). **`translation_gap=true` signals a missing IT *authoring* translation** (an authoring-completeness signal for the content team), NOT a failure for the current request locale — an `?locale=en` consumer receiving `translation_gap=true` should understand it means IT content is not yet authored, not that the request failed. Read-only (no write endpoints in C3).

**Prerequisite — `supported_locales` config**: the `?locale=` validation and Accept-Language matching require a `'supported_locales' => ['it', 'en']` key in `api/config/app.php`. This key does not exist in a stock Laravel install — it MUST be added before implementing the locale validation logic. This is a doc-only instruction; the apply phase adds it.

## Testing Strategy
| Layer | Test | Approach |
|---|---|---|
| Unit | Normalizer split↔unified | feed both shapes, assert same DTO |
| Feature | Idempotent seed | run seeder ×2, assert counts unchanged (no dupes) |
| Feature | Delete-stale (sync) | seed, remove a competency from a role in JSON, reseed, assert stale pivot gone; same for framework_bars_indicators |
| Feature | Translatable re-seed survival | seed EN → add IT manually → re-seed → assert IT translation survives |
| Feature | Graceful missing file | remove SRX bars, assert role+pivot seeded, indicators skipped, gap recorded, no throw |
| Feature | Locale fallback | missing `it` detected via `hasTranslation('it')` → API returns `en`; `?locale=en` honored |
| Feature | Tenant-version isolation | org A and org B each create their own `FrameworkVersion` row (`'v1'`/`'v2'`); assert row-level TenantScoped isolation on `framework_versions` (each org reads ONLY its own row); assert BOTH orgs see the SAME global roles/competencies (single shared draft catalog — no per-org content scoping in C3) |
| Feature | Seeded-count correctness | assert pivot counts: ICO=15, FLL=18, MLL=18, BUL=14, SRX=18; assert BARS-covered competency counts: ICO=15, FLL=8, MLL=8, BUL=8, SRX=0; assert total bars_indicator rows: ICO=45, FLL=24, MLL=24, BUL=24, SRX=0 |
| Feature | Per-role BARS gap assertion | assert gap rows: FLL 10 + MLL 10 + BUL 6 competency_no_bars entries + 1 SRX role_no_bars |

Correctness-critical (catalog integrity) → ~95% coverage.

## Delivery
Forecast ~450–550 changed lines (7 migrations: framework_roles, framework_competencies, framework_role_competency, framework_bars_indicators, framework_versions, catalog_meta, framework_gaps + 6 models: Role, Competency, BarsIndicator, FrameworkVersion, FrameworkGap, CatalogMeta [framework_role_competency is a pivot, not a model] + seeder/adapter + gap tracker + controller + 3 resources + routes + ~6 test files).
- **400-line budget risk: Medium**
- **Chained PRs recommended: Yes** — 3 slices: (1) schema + models + spatie install, (2) seeder + adapter + gap tracking, (3) read API + resources + tests.
- **Decision needed before apply: Yes** (confirm chained-PR delivery).

## Out of Scope
Scoring (C9); project→framework_version FK + pin-at-creation (C4); per-org overrides (future); inventing SRX BARS / MTG-LAT / IT translations.

## Open Questions
- [ ] Open decision #3: snapshot-at-pin mechanism designed and built in C4; `catalog_meta.revision` used in C3 for cache-busting only.
- [ ] Open decision #6: IT anchor translations pending expert authoring (gates non-EN scoring in C9).
- [ ] SRX `responsibilities` empty string: seed as-is and flag `missing_role_meta`; client to provide text (not a C3 blocker).
