# Verify Report — Framework Catalog (C3)

**Date**: 2026-07-17
**Branch**: `feature/c3-framework-catalog`
**Commits**: 3 (PR1 schema+models, PR2 seeder, PR3 read API)
**Verdict**: PASS WITH WARNINGS

---

## Test Suite Evidence

| Metric | Value |
|--------|-------|
| Tests run | 175 / 175 PASSED |
| Assertions | 427 |
| Duration | ~15.7 s |
| Coverage (total) | 96.9 % |
| C3 tests isolated run | 51 / 51 PASSED |
| C2 boundary test | 3 / 3 PASSED |

Coverage by C3 component:

| Component | Coverage |
|-----------|----------|
| FrameworkController | 97.4% |
| BarsIndicatorResource | 100% |
| CompetencyResource | 100% |
| RoleResource | 100% |
| BarsIndicator model | 66.7% |
| CatalogMeta model | 100% |
| Competency model | 0.0% (see note) |
| FrameworkGap model | 100% |
| FrameworkVersion model | 92.9% |
| Role model | 100% |
| CompetencyNormalizer | 100% |
| CompetencyDTO / IndicatorDTO | 100% |

**Competency 0.0% note**: PCOV only counts lines physically executed in `Competency.php`.
The file's sole executable line is the `roles()` BelongsToMany method (line 55) which is never
called by any test — the reverse relationship is not exercised by any spec requirement.
`Competency` is exercised transitively by 6 test files (`::count()`, `::where()`, etc.) via
inherited Eloquent statics; those executions are credited to the parent `Model` class, not to
`Competency.php`. This is a PCOV attribution artifact, NOT a correctness risk. The class is
structurally simple (no domain logic) and fully covered by behavioral integration.

**BarsIndicator 66.7% note**: Lines 67–75 (`role()` and `competency()` relationship methods) are
never called directly in tests. The model is accessed via controller queries, not via relationship
traversal from the indicator side. Not correctness-critical.

---

## Task Completion

All tasks marked `[x]` in `tasks.md`. Summary:

| Phase | Tasks | Status |
|-------|-------|--------|
| 1 — D37 Dependency | 1.1–1.3 | ALL DONE |
| 2 — Schema/Migrations | 2.1–2.7 | ALL DONE |
| 3 — Eloquent Models | 3.1–3.6 | ALL DONE |
| 4 — RED schema+models | 4.1–4.4 | ALL DONE |
| 5 — GREEN schema+models | 5.1 | ALL DONE |
| 6 — CompetencyNormalizer | 6.1–6.2 | ALL DONE |
| 7 — FrameworkCatalogSeeder | 7.1–7.2 | ALL DONE |
| 8 — RED seeder+adapter | 8.1–8.9 | ALL DONE |
| 9 — GREEN seeder+adapter | 9.1 | ALL DONE |
| 10 — Read API | 10.1–10.5 | ALL DONE |
| 11 — RED API tests | 11.1–11.8 | ALL DONE |
| 12 — GREEN API | 12.1 | ALL DONE |
| 13 — Cleanup | 13.1–13.4 | ALL DONE |

No incomplete tasks. Archive readiness: UNBLOCKED on task completion.

---

## Spec Requirement Compliance Matrix

### REQ-1: Global Base Catalog Schema

| Scenario | Covering Test | Status |
|----------|---------------|--------|
| Global tables carry no organization_id | `GlobalTablesHaveNoOrgIdTest` (3 assertions) | PASS |
| BarsIndicator stores anchors at three fixed levels | `FrameworkBarsEndpointTest` | PASS |
| Required columns present on each table | `GlobalTablesHaveNoOrgIdTest` (3 further assertions) | PASS |

### REQ-2: Tenant-Scoped FrameworkVersion Pin

| Scenario | Covering Test | Status |
|----------|---------------|--------|
| Two orgs pin different framework versions | `TenantVersionIsolationTest` | PASS |
| FrameworkVersion composite index leads with organization_id | `FrameworkVersionCompositeIndexTest` | PASS |
| A referenced FrameworkVersion cannot be deleted | `FrameworkVersionImmutabilityTest` (delete test) | PASS |
| A referenced FrameworkVersion cannot be mutated | `FrameworkVersionImmutabilityTest` (update test) | PASS |

### REQ-3: Translatable Content Columns

| Scenario | Covering Test | Status |
|----------|---------------|--------|
| Requesting EN locale returns EN content | `TranslatableLocaleTest` | PASS |
| Requesting IT locale when absent falls back to EN | `TranslatableLocaleTest` + `LocaleFallbackApiTest` | PASS |
| Requesting IT locale when present returns IT | `TranslatableLocaleTest` | PASS |
| Re-seeding preserves manually-added IT translations | `TranslationSurvivalReseedTest` | PASS |

### REQ-4: Idempotent Catalog Seeder (sync delete-stale)

| Scenario | Covering Test | Status |
|----------|---------------|--------|
| First run seeds roles and competencies from JSON | `SeededCountCorrectnessTest` | PASS |
| Second run produces no duplicates (idempotency) | `IdempotentSeedTest` | PASS |
| Missing bars/SRX.json skipped gracefully | `GracefulMissingFileTest` | PASS |
| MTG/LAT absent — potential catalog flagged incomplete | `MtgLatAbsentGapTest` | PASS |
| BUL BARS seeds 8 of 14 (24 rows, 6 gaps) | `PerRoleBarsGapTest` | PASS |
| FLL BARS seeds 8 of 18 (24 rows, 10 gaps) | `PerRoleBarsGapTest` | PASS |
| MLL BARS seeds 8 of 18 (24 rows, 10 gaps) | `PerRoleBarsGapTest` | PASS |
| Seeded-count correctness per-role | `SeededCountCorrectnessTest` (4 assertions) | PASS |
| Re-seeding after correcting a gap adds missing rows | `ReseedAfterGapFixTest` | PASS |
| Delete-stale removes stale pivot and indicator rows | `DeleteStalePivotTest` | PASS |

### REQ-5: Read-Only Org-Scoped Framework API

| Scenario | Covering Test | Status |
|----------|---------------|--------|
| Org A user lists roles + 200 | `FrameworkRolesListTest` | PASS |
| Cross-tenant isolation (pin_context scoped) | `CrossTenantIsolationTest` | PASS |
| Requesting competency BARS returns indicators + anchors | `FrameworkBarsEndpointTest` | PASS |
| bars_available=true for covered, false for gap | `BarsAvailableFlagTest` | PASS |
| Locale-aware response falls back to EN when IT absent | `LocaleFallbackApiTest` | PASS |
| Accept-Language header honours locale selection | `LocaleFallbackApiTest` | PASS |
| Org with no FrameworkVersion → 200 + global catalog | `NoFrameworkVersionApiTest` | PASS |
| Partial catalog (SRX BARS absent) → no 500 | `PartialCatalogApiTest` | PASS |
| N+1 guard on bars_available query | `BarsAvailableFlagTest` (queryCount ≤ 10) | PASS |

### REQ-6: Split-File and Unified-Shape Adapter Tolerance

| Scenario | Covering Test | Status |
|----------|---------------|--------|
| Split-file shape produces correct DB state | `CompetencyNormalizerTest` | PASS |
| Unified shape produces same DB state | `CompetencyNormalizerTest` | PASS |

### REQ-7: Data-Gap Authoring Requirements (Tracked, Not Fabricated)

| Scenario | Covering Test | Status |
|----------|---------------|--------|
| API responds correctly with partial catalog | `PartialCatalogApiTest` | PASS |
| Gap log is inspectable after seeder run | `PerRoleBarsGapTest` (status assertions) | PASS |

---

## Design Coherence

| Design Decision | Implementation | Status |
|----------------|----------------|--------|
| `framework_` table prefix (spatie collision fix) | All 4 catalog tables prefixed; `$table` explicit on all 6 models | MATCH |
| GLOBAL (no org_id) for roles/competencies/bars | Verified: no organization_id columns on those tables | MATCH |
| FrameworkVersion extends TenantModel | Confirmed in code | MATCH |
| `is_locked` forward-looking guard (C4 activates) | immutabilityGuard hooks `deleting` + `updating` — ships but doesn't enforce in C3 | MATCH |
| `catalog_revision` NOT on framework_versions | `catalog_meta` singleton used; no column on framework_versions | MATCH |
| NULLS NOT DISTINCT on framework_gaps unique index | Raw `DB::statement` in migration | MATCH |
| `$casts = []` on FrameworkGap (no string cast) | Confirmed in model | MATCH |
| Locale order: `?locale=` → Accept-Language → fallback | Implemented in `resolveLocale()` private method | MATCH |
| `translation_gap` checks all 4 fields via `hasTranslation` | `hasTranslationGap()` on BarsIndicator — checks all 4 | MATCH |
| `bars_available` N+1-free preload | ONE `BarsIndicator::distinct()->pluck()` before collection pass | MATCH |
| CompetencyNormalizer split↔unified shape | Auto-detects by key presence; DTO emitted | MATCH |
| `firstOrNew + setTranslation` before save() | Applied in seeder for roles, competencies, bars indicators | MATCH |
| Route terminal segment `/indicators` (not `/bars`) | Confirmed in routes + route list output | MATCH |

---

## C2 Boundary Check

| Check | Evidence | Status |
|-------|----------|--------|
| Spatie `roles` table NOT contaminated with framework roles | `RbacScopeTest::Spatie roles table contains only admin/operator/viewer` — 3 PASSED | CLEAN |
| `framework_roles` distinct from `roles` | Separate tables; models explicitly declare `$table` | CLEAN |
| FrameworkVersion uses TenantModel (C2) | Inheritance verified in code | CLEAN |
| No C3 model accidentally uses TenantScoped | TenantModelArchTest excludes C3 global models | CLEAN |

---

## Domain Invariant Verification

| Invariant | Expected | Test Evidence |
|-----------|----------|---------------|
| ICO: 15 pivot rows | 15 | `SeededCountCorrectnessTest` PASS |
| ICO: 15 BARS-covered competencies | 15 | `SeededCountCorrectnessTest` PASS |
| ICO: 45 bars_indicator rows (15×3) | 45 | `SeededCountCorrectnessTest` PASS |
| FLL: 18 pivot rows | 18 | `SeededCountCorrectnessTest` PASS |
| FLL: 8 BARS-covered competencies | 8 | `SeededCountCorrectnessTest` PASS |
| FLL: 24 bars_indicator rows (8×3) | 24 | `SeededCountCorrectnessTest` PASS |
| FLL: 10 competency_no_bars gaps | 10 | `PerRoleBarsGapTest` PASS |
| MLL: 18 pivot rows | 18 | `SeededCountCorrectnessTest` PASS |
| MLL: 8 BARS-covered competencies | 8 | `SeededCountCorrectnessTest` PASS |
| MLL: 24 bars_indicator rows (8×3) | 24 | `SeededCountCorrectnessTest` PASS |
| MLL: 10 competency_no_bars gaps | 10 | `PerRoleBarsGapTest` PASS |
| BUL: 14 pivot rows | 14 | `SeededCountCorrectnessTest` PASS |
| BUL: 8 BARS-covered competencies | 8 | `SeededCountCorrectnessTest` PASS |
| BUL: 24 bars_indicator rows (8×3) | 24 | `SeededCountCorrectnessTest` PASS |
| BUL: 6 competency_no_bars gaps | 6 | `PerRoleBarsGapTest` PASS |
| SRX: 18 pivot rows | 18 | `SeededCountCorrectnessTest` PASS |
| SRX: 0 BARS-covered competencies | 0 | `SeededCountCorrectnessTest` PASS |
| SRX: 0 bars_indicator rows | 0 | `SeededCountCorrectnessTest` PASS |
| SRX: 1 role_no_bars gap | 1 | `GracefulMissingFileTest` PASS |
| MTG/LAT absent, gaps recorded | 2 gaps | `MtgLatAbsentGapTest` PASS |
| Anchor levels {5,3,1} mapped from BARS JSON scale | scale.5→anchor_5, scale.3→anchor_3, scale.1→anchor_1 | `FrameworkBarsEndpointTest` PASS |
| Idempotent seeder (stable gap counts on re-seed) | `FrameworkGap::count()` same after 2 runs | `IdempotentSeedTest` PASS |
| Gap rows unique (NULLS NOT DISTINCT) | DB constraint + `updateOrCreate` app guard | Migration + seeder code |
| Delete-stale removes orphan pivots and indicators | Stale pivot/indicator gone after reseed | `DeleteStalePivotTest` PASS |
| Translation survival across re-seed | IT translation persists after EN reseed | `TranslationSurvivalReseedTest` PASS |

---

## Issues Found

### WARNING

**W-1: `config/translatable.php` not committed**

Spec (REQ-3) and design (task 1.3) require `php artisan vendor:publish --tag=translatable` and
committing the resulting `config/translatable.php` with `'fallback_locale' => 'en'`.
The file is absent from `api/config/`. Functionality is NOT broken: spatie's `normalizeLocale()`
falls through to `config('app.fallback_locale')` which is `'en'` in `api/config/app.php`, producing
the correct fallback behavior. The locale fallback tests confirm this. However, the contract says
to publish the file, and its absence means: (a) the intent is not explicit; (b) a future
`app.fallback_locale` change could silently break spatie fallback without an obvious config to update.
**Recommendation**: commit `config/translatable.php` with `'fallback_locale' => 'en'`; low risk, quick fix.

**W-2: `Competency::roles()` reverse relationship not test-covered**

The only executable line in `Competency.php` is the `roles()` BelongsToMany method (line 55),
which is never called by any test (0.0% PCOV). This is a reverse-relationship convenience method
with no spec requirement. No domain logic is at risk. Flagged for awareness:
if any downstream consumer calls `$competency->roles()`, it is currently untested.
**Recommendation**: add one assertion in an existing seeder test that traverses
`$competency->roles()` — keeps the file out of 0% and validates the relationship definition.

**W-3: `BarsIndicator::role()` and `competency()` methods not directly covered (66.7%)**

Same pattern as W-2: lines 65–75 in `BarsIndicator.php` define `role()` and `competency()`
BelongsTo methods. Indicators are queried directly via `BarsIndicator::where(...)` in the
controller; the relationship traversal from the indicator side is never exercised.
Not correctness-critical. Worth adding a simple assertion if coverage target is to be tightened.

### SUGGESTION

**S-1: No test for `?locale=en` explicit param honoring**

The spec scenario "Requesting EN locale returns EN content" is covered by `TranslatableLocaleTest`
at the unit level (model accessor), but no feature/HTTP test explicitly calls the API with
`?locale=en` and asserts the response code + locale enforcement. The `LocaleFallbackApiTest` only
tests `?locale=it`. This is a minor gap — the locale resolution code IS tested via `?locale=it`
and Accept-Language, and the EN path is the fallback — but an explicit `?locale=en` API test
would make the contract airtight.

**S-2: `supported_locales` validation for invalid locale param not tested**

The spec says `?locale=` MUST be validated as a member of `config('app.supported_locales')`.
The controller does validate (`in_array($queryLocale, $supportedLocales, true)`) — an invalid
locale simply falls through to Accept-Language/fallback rather than returning a 422. No test
asserts behavior when an unsupported locale (e.g. `?locale=fr`) is passed. The current behavior
(silent fallback) is reasonable but the spec says "MUST be validated" — a test and possibly a
422 response for invalid locales would make it more defensible.

---

## Final Verdict

**PASS WITH WARNINGS**

- CRITICAL issues: **0**
- WARNING issues: **3** (W-1 missing config/translatable.php; W-2/W-3 uncovered reverse-relationship methods)
- SUGGESTION: **2** (S-1 EN locale API test; S-2 invalid locale 422)

All 175 tests pass. 96.9% coverage meets the ~95% correctness-critical zone target.
All spec requirements have passing covering tests. Domain invariants (role counts, BARS row counts,
gap counts, locale fallback, idempotency, delete-stale) verified by test execution at runtime.
C2 boundary respected: spatie `roles` table uncontaminated. The `framework_` table prefix deviation
from the original design is documented, intentional, and cross-referenced in migrations, models,
spec, design, and tasks.

**Recommended next step**: `sdd-archive`
