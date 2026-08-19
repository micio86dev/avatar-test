# Framework Catalog Specification

## Purpose

Defines the queryable, versioned, translatable, tenant-pinnable data layer
for BEAI's binding domain catalog: 5 roles, 18 standard competencies, and
per-role BARS indicators with reference anchors {5, 3, 1}. C4 pins a
framework version per project by taking an immutable snapshot of the catalog
at pin time (snapshot-at-pin, designed and built in C4). C9 reads anchors
to score. C3 stores and serves — it does NOT evaluate.

The C3 global catalog is a **mutable WORKING DRAFT** — freely re-seedable.
The seeder uses `sync` (delete-stale) for `framework_role_competency` pivots and
delete-stale for `framework_bars_indicators`, so re-seeding reflects the JSON exactly
and eliminates orphan rows. This is intentional draft behavior; snapshots
taken at C4 pin time are what remain immutable.

---

## Requirements

### Requirement: Global Base Catalog Schema

The system MUST provide three GLOBAL (non-tenant-scoped) tables — `framework_roles`,
`framework_competencies`, and `framework_bars_indicators` — that together represent the binding
domain catalog. None of these tables SHALL carry an `organization_id` column.

`framework_roles` MUST record: code (ICO/FLL/MLL/BUL/SRX), translatable name,
translatable responsibilities. `framework_competencies` MUST record: code (PRS…INC),
translatable name, translatable definition. `framework_bars_indicators` MUST record:
role_code, competency_code, display order, translatable indicator text, and
three translatable anchor text fields for scores 5, 3, 1.

Migrations MUST be reversible (`down()` restores pre-C3 schema) and follow
D22 conventions (3NF, indexed).

#### Scenario: Global tables carry no organization_id

- GIVEN the `framework_roles`, `framework_competencies`, and `framework_bars_indicators` migrations
- WHEN the schema is inspected
- THEN none of those tables has an `organization_id` column
- AND each table has the required code and translatable columns

#### Scenario: BarsIndicator stores anchors at three fixed levels

- GIVEN a `framework_bars_indicators` row for ICO × PRS
- WHEN the record is read
- THEN it carries non-null anchor text for levels 5, 3, and 1
- AND the indicator text field is non-null

---

### Requirement: Tenant-Scoped FrameworkVersion Pin

The system MUST provide a `framework_versions` table that extends the C2
`TenantModel` pattern, scoped per organization via `organization_id`. The
table MUST record: `organization_id`, a catalog `version` identifier, a
`label` (human display name for the draft, nullable string), `is_locked`
(bool, default false), and timestamps.

In C3, `FrameworkVersion` is a **DRAFT label** — `is_locked` is a
forward-looking flag that C4 activates on pin. C3 does NOT enforce
immutability; the `is_locked=true` guard is built and activated by C4
when it takes the immutable snapshot at pin time.

The composite index on `framework_versions` MUST lead with `organization_id`
(per D22 multi-tenancy convention).

A `FrameworkVersion` record MUST become immutable once it is referenced by
any downstream record (project → framework_version_id, set by C4). The system
MUST NOT permit deletion or mutation of a locked `FrameworkVersion`. The
`immutabilityGuard()` on the model provides the enforcement hook; C4 sets
`is_locked=true` and the guard becomes active.

**Exception type (required C4 fix):** The `deleting` and `updating` hooks in `FrameworkVersion.booted()`
currently throw a bare `RuntimeException`, which produces HTTP 500 on API paths. C4 MUST replace
these with a `LockedFrameworkVersionException` (a domain exception implementing `Renderable` or
with a `render()` method) that returns HTTP 422 or HTTP 403. This mirrors the `ImmutableProjectException`
pattern. API attempts to mutate or delete a locked FV MUST return the HTTP code specified in the
spec scenario below, NOT HTTP 500.

**Relation wired by C4 (added by C4):** `FrameworkVersion` MUST expose a
`projects()` `hasMany(Project::class)` relation returning all projects that
have pinned this version. The C3 placeholder (empty or stub `projects()`) MUST
be replaced by a real Eloquent `hasMany`. This relation is used by the seeder
lock-guard and by any downstream query that needs to enumerate projects per
locked version.

C4 wires the project → `framework_version_id` FK and takes the catalog snapshot;
C9 reads anchor text via that FK. These are downstream concerns and are OUT OF SCOPE for C3.

#### Scenario: Two organizations pin different framework versions

- GIVEN organization A has pinned framework version "v1"
- AND organization B has pinned framework version "v2"
- WHEN org A's framework version is fetched
- THEN it returns version "v1"
- AND fetching org B's framework version returns "v2"
- AND no cross-org data leaks

#### Scenario: FrameworkVersion composite index leads with organization_id

- GIVEN the `framework_versions` migration
- WHEN the index definitions are inspected
- THEN the primary lookup index starts with `organization_id`

#### Scenario: A referenced FrameworkVersion cannot be deleted

- GIVEN a FrameworkVersion record that C4 has associated with a project
- WHEN a delete is attempted on that FrameworkVersion
- THEN the delete is rejected (constraint or guard)
- AND the FrameworkVersion record remains intact

#### Scenario: projects() relation returns pinning projects

- GIVEN FrameworkVersion FV1 is locked and two projects (P1, P2) reference it
- WHEN FV1.projects() is called
- THEN the relation returns a collection containing P1 and P2
- AND no projects from other FrameworkVersions are included

---

### Requirement: Complete Role×Competency BARS Coverage

Every role×competency pair declared in `roles.json` MUST have exactly 3
anchored indicators (levels 5, 3, 1) in its role's `bars/{ROLE}.json` file —
83 pairs, 249 indicators, 747 anchor texts across ICO/FLL/MLL/BUL/SRX.
`bars/SRX.json` MUST ship as one complete file (18 competencies, 54
indicators) in the same commit that removes the `SRX` line from
`scripts/framework-known-gaps.txt`; a partial SRX file is not a valid
gap-exempt state. `scripts/framework-known-gaps.txt` and
`scripts/framework-competency-gaps.txt` MUST contain zero entries once this
catalogue lands, and the wrapper catalog gate (`wrapper-ci.yml` step d) MUST
pass in both directions (no undeclared gap, and no stale exemption for a
now-covered pair).

#### Scenario: All 83 declared pairs seed with complete BARS coverage

- GIVEN roles.json declares 83 role×competency pairs and every role's
  bars/{ROLE}.json defines all of that role's assigned competencies
- WHEN FrameworkCatalogSeeder runs
- THEN framework_bars_indicators contains exactly 3 rows (non-null anchor_5,
  anchor_3, anchor_1) for each of the 83 pairs
- AND zero competency_no_bars or role_no_bars gap rows remain pending

#### Scenario: CI gap-control files pass empty in both directions

- GIVEN scripts/framework-known-gaps.txt and
  scripts/framework-competency-gaps.txt contain zero entries
- WHEN the wrapper catalog gate runs
- THEN it passes (no role or pair is undeclared-and-uncovered)
- AND it would fail if any covered pair were re-listed in either file (the
  reverse-direction check)

---

### Requirement: Behavioural, Role-Specific Anchor Differentiation

Newly authored anchor texts (levels 5/3/1) for each of the 132 new
indicators MUST differ across levels by a distinct observable action or
object, not solely by a degree-of-frequency adverb ("rarely / sometimes /
consistently" applied to an otherwise identical sentence) — `ICO/PRS`
indicator 1 (surface symptoms → differentiates problem from symptom → uses
symptoms as clues to causes) is the binding pattern; `ICO/STG` #1,
`ICO/INN` #1, and `ICO/ITG` #3 are the counter-example this standard rejects
for new content. Anchors for the same competency MUST differ across roles by
the object of the behaviour, its horizon, or its unit of accountability
drawn from that role's `roles.json` responsibilities — e.g. STG for ICO
reads "Understand the short- and medium-term consequences of own actions"
while FLL reads "Have a plan to achieve own team's goals"; new anchors MUST
NOT be one role's text with the role name swapped. This standard applies to
the 132 newly authored indicators; the existing 39 pairs are NOT
retroactively rewritten by this change and remain a recorded, separate
inconsistency (76% of level-3 anchors carry a hedge marker; ICO alone is
89%).

#### Scenario: Levels differ by behaviour, not by adverb alone

- GIVEN a newly authored indicator's three anchor texts (levels 5, 3, 1)
- WHEN each anchor is stripped of degree/frequency adverbs (occasional, may,
  generally, most, some, rarely, consistently)
- THEN the three texts still describe three distinguishable actions or
  objects, not one sentence with the adverb removed three times

#### Scenario: Reworded-copy across roles is a detectable failure

- GIVEN competency STG is anchored for both FLL and MLL
- WHEN FLL:STG's and MLL:STG's anchor text at the same level is compared
- THEN the object, horizon, or accountability unit differs (e.g. FLL: own
  team's goals over weeks/months; MLL: unit plans aligned to strategy over
  about a year)
- AND a per-competency scope-shift table row exists per role showing that
  difference before the anchor prose was written

#### Scenario: Mechanical cross-role check finds no identical strings

- GIVEN all five bars/*.json files (ICO, FLL, MLL, BUL, SRX)
- WHEN the cross-role duplicate-detection script runs over indicator and
  anchor strings grouped by competency
- THEN it reports zero identical strings across roles for the same
  competency
- AND any pair above the similarity threshold has a recorded human
  adjudication

---

### Requirement: SRX Role Responsibilities — Authored Prerequisite

`roles.json`'s SRX role MUST carry a non-empty `responsibilities` value,
calibrated against the ICO→BUL seniority ladder (ICO: daily-to-weekly, own
area; FLL: weekly-to-monthly, small department, manages people; MLL: about
a year, small country, aligns unit plans to strategy; BUL: one-to-two
years, whole country/region, full P&L), before any SRX BARS indicator is
authored. No SRX anchor MAY be calibrated against a blank `responsibilities`
field.

#### Scenario: SRX responsibilities is non-empty and ladder-consistent

- GIVEN roles.json
- WHEN the SRX role entry is read
- THEN responsibilities is a non-empty string
- AND it describes a horizon, scope, and accountability unit one tier beyond
  BUL's (~1-2 years, country/region or broader, full P&L), consistent with
  the ICO→BUL progression

#### Scenario: Seeder lands SRX responsibilities on first (unlocked) run

- GIVEN roles.json SRX.responsibilities is now authored (non-empty)
- AND no FrameworkVersion has is_locked=true
- WHEN FrameworkCatalogSeeder runs
- THEN the SRX Role's responsibilities EN translation matches the authored
  text
- AND the missing_role_meta gap for SRX no longer appears pending

#### Scenario: Locked FrameworkVersion suppresses the SRX responsibilities update — must be resolved explicitly

- GIVEN a locked FrameworkVersion exists
- AND the SRX Role row already exists in the DB with responsibilities empty
  (pre-change production state)
- WHEN the seeder runs with the newly authored non-empty SRX responsibilities
  in roles.json
- THEN the SRX Role's responsibilities translation is NOT updated by the
  seeder (suppressed by the per-call-site $model->exists gate)
- AND the deployment MUST NOT be considered complete until a targeted update
  (seeder-side resolution or a documented one-off fix) sets SRX
  responsibilities explicitly

---

### Requirement: Gap Row Reconciliation on Seeded Content

When previously-recorded content becomes present in the source JSON (a
competency gains a BARS entry, a role's BARS file is added, a role's
`responsibilities` becomes non-empty, or a translatable field gains an `it`
value for a locale it previously lacked), the seeder MUST resolve the
matching `framework_gaps` row — updating `status` away from
`pending_authoring` (e.g. to `resolved`) or removing the row — rather than
leaving it `pending_authoring` indefinitely. Gap resolution MUST proceed even
while a `FrameworkVersion` is locked (`framework_gaps` writes are exempt from
lock-guard mutation suppression, consistent with
`FrameworkGap::updateOrCreate` being exempt for new gaps).

For the `missing_translation` gap specifically, resolution MUST be evaluated
at role×competency PAIR granularity, not per string: a pair's 12 strings
(3 indicators × {text, anchor_5, anchor_3, anchor_1}) must ALL carry an `it`
translation before that pair counts as translated (mirrors the scoring-engine
per-competency hard-fail unit — 11 of 12 is worth the same as 0). The seeder
MUST NOT mark `missing_translation` resolved for scope that is only
partially translated, and MUST resolve (in full, or by narrowing to the
still-untranslated remainder) as each pair's 12 strings become complete.
(Previously: this requirement's trigger list did not include translation
completion, so `missing_translation` had no resolution path and would stay
`pending_authoring` forever even once fully translated.)

#### Scenario: competency_no_bars gap resolves once the pair is anchored

- GIVEN a framework_gaps row exists with kind=competency_no_bars,
  role_code=FLL, competency_code=PRS, status=pending_authoring
- AND bars/FLL.json now defines a PRS entry
- WHEN the FrameworkCatalogSeeder runs
- THEN that gap row's status is no longer pending_authoring (resolved or
  removed)
- AND no framework_gaps row remains pending for (FLL, PRS)

#### Scenario: role_no_bars and missing_role_meta resolve once SRX is authored

- GIVEN framework_gaps rows exist with kind=role_no_bars (role_code=SRX) and
  kind=missing_role_meta (role_code=SRX), both status=pending_authoring
- AND bars/SRX.json now exists and roles.json SRX.responsibilities is
  non-empty
- WHEN the seeder runs
- THEN both gap rows are no longer pending_authoring
- AND zero framework_gaps rows referencing SRX remain pending

#### Scenario: Gap resolution proceeds even under a locked FrameworkVersion

- GIVEN a locked FrameworkVersion exists
- AND a pending competency_no_bars gap row exists for a pair that is now
  anchored in the JSON
- WHEN the seeder runs in additive-only (lock-guard) mode
- THEN the gap row is still resolved (framework_gaps writes are exempt from
  mutation suppression)
- AND catalog content rows for pre-existing pairs remain byte-for-byte
  unchanged per the lock-guard

#### Scenario: missing_translation resolves once a full role×competency pair's 12 strings are translated

- GIVEN ICO×PRS has all 3 indicators' text and all 3 anchors' texts (12
  strings) present in `it` in the source JSON
- WHEN the seeder runs
- THEN the missing_translation gap coverage for (ICO, PRS) is no longer
  pending_authoring
- AND a sibling pair (e.g. ICO×COL) still missing even one of its 12 strings
  remains pending_authoring

#### Scenario: missing_translation stays pending when 11 of 12 strings are translated

- GIVEN ICO×STG has 11 of its 12 required IT strings present and one
  anchor_1 text still missing IT
- WHEN the seeder runs
- THEN the missing_translation gap coverage for (ICO, STG) remains
  pending_authoring (11 of 12 is treated as zero, consistent with the
  scoring-engine per-competency hard-fail)

---

### Requirement: Calibrated Draft Pending Specialist Sign-Off

The 132 newly authored indicators (396 anchor texts) and SRX's
`responsibilities` are a calibrated draft — extrapolated from the complete
ICO file, the 24 existing leader pairs, `competencies.json` definitions, and
the `roles.json` seniority ladder. An assessment specialist MUST review and
sign off this content before it scores a real candidate; sign-off is a
release gate, not a follow-up. The 8 pairs / 24 indicators with zero
catalogue precedent ({FLL,MLL,BUL,SRX} × {JDG,TMG}) MUST be flagged for
priority review.

#### Scenario: Specialist sign-off gates production scoring of new content

- GIVEN the 132 newly authored indicators have been seeded to production
- WHEN scoring is enabled for real candidates against any newly anchored
  pair
- THEN an assessment specialist's recorded sign-off exists for that content
- AND scoring of real candidates against unsigned-off new pairs does not
  proceed

#### Scenario: JDG and TMG are flagged for priority review

- GIVEN JDG and TMG have zero worked precedent across all four pre-existing
  bars files
- WHEN the {FLL,MLL,BUL,SRX} × {JDG,TMG} content is authored and seeded
- THEN those 8 pairs / 24 indicators carry an explicit priority-review
  marker distinct from standard sign-off

---

### Requirement: Translatable Content Columns

The system MUST store role names, role responsibilities, competency names,
competency definitions, BARS indicator text, and all three anchor texts as
translatable JSON columns supporting at minimum `it` and `en` locales, using
`spatie/laravel-translatable`. Adding further locales (es, fr, de, pt) MUST
require no schema migration.

When a locale is requested and that locale's translation exists, the system
MUST return it. When the requested locale is missing for a field, the system
MUST fall back to `en` and MUST flag the gap (e.g. via a response metadata
field or log entry). The system MUST NOT return null or an empty string when
the `en` fallback is present.

Spatie locale fallback is NOT automatic from `config('app.fallback_locale')`
alone. The implementation MUST publish `config/translatable.php` (via
`php artisan vendor:publish --tag=translatable`) and set
`'fallback_locale' => 'en'`, or call `useFallbackLocale('en')` on each model.

Translation gap detection (e.g. the `translation_gap` flag in API responses)
MUST use `$model->hasTranslation('field', 'it')` to check real presence —
NOT by testing whether the returned value is empty or null (an empty-string IT
translation would otherwise be mistaken for a gap). `translation_gap=true` signals
a missing IT *authoring* translation (an authoring-completeness signal for the
content team) — NOT a failure for the current request locale. An `?locale=en`
consumer that receives `translation_gap=true` should understand that IT content
has not yet been authored, not that its own request failed.

The seeder MUST call `setTranslation('field', $locale, $value)` per field, per
locale present in the source JSON's nested locale key for that field (see
Requirement: Locale Dimension Uses Nested Keys) — NOT bulk `updateOrCreate` on
the raw JSON column — so that a manually-added translation in any locale
persists across a re-seed. The seeder MUST continue to call
`setTranslation('field', 'en', $value)` at every existing call site, and MUST
additionally call `setTranslation('field', 'it', $value)` wherever that
field's nested source value carries an `it` key. A field with no `it` key in
the source MUST be left untouched — the seeder MUST NOT write an empty-string
or null `it` translation to manufacture the appearance of coverage.
(Previously: the seeder called `setTranslation('field','en',$value)` only;
no source field carried an `it` value.)

#### Scenario: Requesting EN locale returns EN content

- GIVEN a Competency with EN name "Problem Solving"
- WHEN the competency is fetched with locale=en
- THEN the name field is "Problem Solving"

#### Scenario: Requesting IT locale when IT translation is absent falls back to EN

- GIVEN a BarsIndicator whose anchor_5 has EN text but no IT text
- WHEN the indicator is fetched with locale=it
- THEN anchor_5 returns the EN text (fallback)
- AND the response or log indicates a translation gap for that field

#### Scenario: Requesting IT locale when IT translation exists returns IT

- GIVEN a Competency with both IT and EN names populated
- WHEN the competency is fetched with locale=it
- THEN the name field returns the IT value

#### Scenario: Re-seeding preserves manually-added IT translations

- GIVEN the seeder has run once (EN translations seeded)
- AND an IT translation has been manually added to a Competency
- WHEN the seeder runs again
- THEN the IT translation is still present on that Competency
- AND the EN translation reflects the current JSON value

#### Scenario: Seeder writes an IT translation from a nested-locale source field

- GIVEN a BarsIndicator's `anchor_5` source value carries a nested
  `{"en": "...", "it": "..."}` object
- WHEN FrameworkCatalogSeeder runs (no locked FrameworkVersion)
- THEN `setTranslation('anchor_5', 'it', ...)` is called with the source's
  `it` value
- AND `$model->hasTranslation('anchor_5', 'it')` is true after the run

#### Scenario: Seeder leaves IT untouched when the source has no IT value

- GIVEN a field's source value carries only an `en` key, no `it` key
- WHEN FrameworkCatalogSeeder runs
- THEN no `it` translation is written for that field
- AND `$model->hasTranslation('field', 'it')` remains false (a real,
  un-manufactured gap)

---

### Requirement: Idempotent Catalog Seeder (sync delete-stale)

The system MUST provide a `FrameworkCatalogSeeder` that seeds the global
catalog from the split-file JSON shape (`competencies.json` + `bars/{ROLE}.json`).
The seeder MUST be idempotent: running it N times MUST produce the same
database state as running it once. Duplicate rows MUST NOT be created.

The seeder MUST use natural-key upserts (role code, competency code,
role×competency×indicator position) AND MUST delete stale rows **unless a
locked FrameworkVersion exists** (see guard clause below):
- `framework_role_competency` pivot: use `sync` (not `syncWithoutDetaching`) — stale
  pivots for competencies removed from a role in the JSON are deleted.
- `framework_bars_indicators`: after upserting the current set for a (role, competency)
  pair, delete any rows with positions not present in the current JSON.

**Seeder lock-guard (added by C4) — FULLY ADDITIVE when locked:** Before executing any delete-stale
or mutation operation against the catalog tables, the seeder MUST check whether any `FrameworkVersion`
record has `is_locked = true` (query MUST use `withoutGlobalScopes()` — no HTTP request/tenant is
set during artisan seeding). If at least one locked `FrameworkVersion` exists, the seeder MUST
become PURELY ADDITIVE:

1. ALL destructive deletes MUST be skipped (delete-stale calls and `sync`-detach operations on
   `framework_role_competency` pivots and `framework_bars_indicators` rows). This includes the
   stale-unassigned-competency delete block inside the BARS loop: when a competency is absent from
   `$currentAssignedIds` (which is JSON-derived — NOT DB-pivot-derived), the `BarsIndicator::delete()`
   MUST be suppressed, but the `continue` (which skips BARS processing for that competency) MUST be
   preserved. The existing indicator rows and DB pivot for a JSON-removed-but-DB-preserved competency
   MUST remain byte-for-byte untouched.
2. ALL mutations of existing CATALOG rows MUST be skipped — `setTranslation()`, the update half of
   `updateOrCreate()`, and any other write that would change an already-persisted row in
   `framework_roles`, `framework_competencies`, `framework_bars_indicators`, `framework_role_competency`,
   or their translation columns MUST be bypassed via a per-call-site `$model->exists` gate:
   if the model already exists (`$model->exists === true`), capture the id and skip; only new rows
   (`$model->exists === false`) may be mutated and saved. Existing rows MUST remain byte-for-byte
   unchanged.
3. Only genuinely NEW rows (not yet present by natural key) MAY be inserted.
4. The seeder MUST emit a clear, structured signal (log entry and/or gap record with
   `kind: seeder_lock_guard_active`) so the operator is aware the guard fired.

**EXEMPT from suppression — `framework_gaps`, `catalog_meta`, and the lock-guard signal:**
`FrameworkGap::updateOrCreate(...)` and `CatalogMeta::bump()` MUST continue normally even when the
lock-guard is active. These are operational and tracking rows, NOT catalog content. The suppression
applies ONLY to existing catalog rows (roles, competencies, indicators, pivots, and their
translations).

The `seeder_lock_guard_active` signal — emitted as a log entry and/or a `FrameworkGap` record with
`kind: seeder_lock_guard_active` — is ALSO EXEMPT from mutation-suppression. It is an operational
signal (not catalog content) and MUST be emitted ONCE, immediately after the `hasLockedVersions()`
check returns `true` at the top of `run()`, before any catalog processing begins. The signal is not
suppressed by the guard it is reporting.

**New-locale suppression (explicit):** While ANY FV is locked, adding a new locale translation to
an EXISTING catalog row IS a mutation of that row. It is SUPPRESSED (the per-call-site `$model->exists`
gate skips the `setTranslation` call for pre-existing rows). New-translation authoring for existing
catalog rows waits until no FV is locked. Byte-for-byte preservation of existing rows wins. This
suppression MUST NOT be silent: the same `seeder_lock_guard_active` signal (log entry and/or
`framework_gaps` record) required above MUST fire, and it MUST be inspectable that IT strings
present in the source JSON were NOT written because of an active lock — an operator re-running the
seeder against a locked FV MUST be able to tell, without reading source code, that translation
authoring did not take effect.

**`CatalogMeta::bump()` in additive mode:** `bump()` MUST be called only when at least one genuinely
new row was inserted during this seeder run. If the seeder ran in additive mode but inserted no new
rows, `CatalogMeta::bump()` MUST NOT be called (no structural change occurred). This is correct:
the bump signals new catalog content arrived, not that mutations were suppressed.

**Semantic**: an anchor text edit in the source JSON after a FV is locked is silently IGNORED while
any FV is locked. This is correct, intentional behavior — the locked catalog rows must remain
unchanged to preserve C9 scoring determinism. New competencies/indicators added to the JSON are
still inserted (additive). This asymmetry (insert-allowed, mutate-forbidden) is the core contract.

If no locked `FrameworkVersion` exists, full delete-stale + mutation behavior MUST proceed as
before (existing behavior unchanged).

This delete-stale behavior is INTENTIONAL for a working draft: re-seeding
reflects the JSON exactly, eliminating orphan rows. Snapshots taken at C4
pin time are what remain immutable — not the draft catalog.

For every role that has a BARS file, the seeder MUST compare the role's
assigned competencies (from `framework_role_competency`) against the keys present in
that role's BARS file. Each assigned competency NOT present as a key in the
BARS file MUST be recorded as a gap entry `{kind: competency_no_bars,
role_code: ROLE, competency_code: CODE}`.

The seeder MUST gracefully skip a missing BARS file and MUST log or record
a structured gap entry `{kind: role_no_bars}` flagging the missing data. It
MUST NOT throw an exception or halt for a missing file. After skipping, the
affected role's competency records MUST still be seeded (from `competencies.json`)
if present.

The seeder MUST tolerate a future unified competency object shape (where
competency metadata and BARS anchors are co-located) without requiring code
changes to the split-file path.

#### Scenario: First run seeds roles and competencies from JSON

- GIVEN the JSON files competencies.json and bars/ICO.json are present
- WHEN the FrameworkCatalogSeeder runs for the first time
- THEN roles and competencies matching the JSON are present in the DB
- AND ICO BARS indicators are present with correct anchor text

#### Scenario: Second run produces no duplicates (idempotency)

- GIVEN the seeder has already run once
- WHEN the seeder runs again without any data change
- THEN the row counts for framework_roles, framework_competencies, and framework_bars_indicators are identical
- AND no duplicate rows exist

#### Scenario: Missing BARS file for a role is skipped gracefully (fixture)

- GIVEN a fixture role has no bars/{ROLE}.json file on disk (post-completion, no real declared role lacks a BARS file — this exercises the defensive path only)
- WHEN the FrameworkCatalogSeeder runs
- THEN the seeder does NOT throw an exception
- AND the role's metadata (name, responsibilities) is still seeded from roles.json
- AND a role_no_bars gap entry is recorded
- AND framework_bars_indicators contains zero rows for that role

#### Scenario: MTG/LAT absent — potential catalog flagged incomplete

- GIVEN neither competencies.json nor any bars file defines MTG or LAT
- WHEN the FrameworkCatalogSeeder runs
- THEN no MTG or LAT rows are created
- AND a gap entry is recorded flagging "MTG/LAT competencies absent — potential assessment type incomplete"
- AND the seeder completes successfully

#### Scenario: BUL BARS file seeds only present competencies (8 of 14)

- GIVEN bars/BUL.json defines BARS for 8 of BUL's 14 assigned competencies
- WHEN the FrameworkCatalogSeeder runs
- THEN framework_bars_indicators rows are created only for competencies present in bars/BUL.json (8 competencies × 3 = 24 rows)
- AND 6 gap entries are recorded with kind=competency_no_bars and role_code=BUL

#### Scenario: FLL BARS file seeds only present competencies (8 of 18)

- GIVEN bars/FLL.json defines BARS for 8 of FLL's 18 assigned competencies
- WHEN the FrameworkCatalogSeeder runs
- THEN framework_bars_indicators rows are created only for competencies present in bars/FLL.json (8 competencies × 3 = 24 rows)
- AND 10 gap entries are recorded with kind=competency_no_bars and role_code=FLL

#### Scenario: MLL BARS file seeds only present competencies (8 of 18)

- GIVEN bars/MLL.json defines BARS for 8 of MLL's 18 assigned competencies
- WHEN the FrameworkCatalogSeeder runs
- THEN framework_bars_indicators rows are created only for competencies present in bars/MLL.json (8 competencies × 3 = 24 rows)
- AND 10 gap entries are recorded with kind=competency_no_bars and role_code=MLL

#### Scenario: Seeded-count correctness — per-role BARS coverage

- GIVEN the seeder has run successfully against the complete catalogue (all 83 declared pairs anchored)
- WHEN framework_bars_indicators are counted per role
- THEN ICO has 45 rows (15 competencies × 3 indicators)
- AND FLL has 54 rows (18 competencies × 3 indicators)
- AND MLL has 54 rows (18 competencies × 3 indicators)
- AND BUL has 42 rows (14 competencies × 3 indicators)
- AND SRX has 54 rows (18 competencies × 3 indicators)

#### Scenario: Re-seeding after a previously-missing BARS file is authored adds the missing rows (fixture)

- GIVEN a fixture role's bars/{ROLE}.json was absent on the first seed run
- AND the file is subsequently authored and placed on disk
- WHEN the seeder runs again
- THEN the role's BARS indicators are inserted
- AND no existing rows are duplicated

#### Scenario: Delete-stale — removing a competency from a role removes stale pivot and indicator rows (no locked FV)

- GIVEN no FrameworkVersion with is_locked=true exists
- AND the seeder has run once and a role (e.g. ICO) has a `framework_role_competency` pivot for competency X, and `framework_bars_indicators` rows for (ICO, X)
- WHEN one competency is removed from that role in the source JSON fixture
- AND the seeder runs again
- THEN the stale `framework_role_competency` pivot row for (ICO, X) is DELETED
- AND the stale `framework_bars_indicators` rows for (ICO, X) are DELETED
- AND all other pivot and indicator rows are unchanged
- (This proves `sync`/delete-stale is used, NOT `syncWithoutDetaching`)

#### Scenario: Lock-guard — fully additive when a locked FV exists (delete-stale and mutations suppressed)

- GIVEN FrameworkVersion FV1 has is_locked=true (pinned by at least one project; set via explicit property assignment, not mass-assign)
- AND the seeder has run once; competency X is in ICO's framework_role_competency and framework_bars_indicators,
  with anchor text "Anchor text original" for indicator at position 1,
  and competency X has name translation "name original" in EN
- WHEN the anchor text for that indicator is EDITED in the JSON fixture to "Anchor text MODIFIED"
- AND the EN name for competency X is EDITED in competencies.json to "name MODIFIED"
- AND a brand-new competency Z with its indicator rows (not yet in the DB) is added to both competencies.json
  and the ICO bars fixture
- AND the seeder runs again
- THEN the existing anchor row for (ICO, X, position=1) is UNCHANGED — anchor text is still "Anchor text original"
  (mutation suppressed by per-call-site $model->exists gate)
- AND the EN name translation for competency X is UNCHANGED — still "name original"
  (new-locale and name-edit mutations suppressed for existing rows)
- AND the framework_role_competency pivot for (ICO, X) is PRESERVED (delete-stale skipped)
- AND the framework_bars_indicators rows for (ICO, X) are PRESERVED
- AND competency Z IS inserted into framework_competencies (new row — additive)
- AND competency Z's indicator rows ARE inserted into framework_bars_indicators (new rows — additive; a new competency and its indicators must both be inserted, no orphan competency-without-indicators)
- AND the framework_role_competency pivot for (ICO, Z) IS inserted (syncWithoutDetaching adds new pivots)
- AND framework_gaps upserts (e.g., missing_translation, competency_no_bars for new gaps) STILL OCCUR — not suppressed
- AND a structured signal (log entry or gap record with kind=seeder_lock_guard_active) is emitted

#### Scenario: Lock-guard — JSON-removed-but-DB-preserved competency leaves indicators and pivot intact

**Context:** `$currentAssignedIds` in the seeder BARS loop is built from `array_keys($assignedIds)`,
which reflects the CURRENT JSON — NOT the DB pivot state. In locked mode, `syncWithoutDetaching`
preserves pivot rows for competencies removed from the JSON; such competencies reach the
stale-unassigned branch (not in `$currentAssignedIds`) even though their DB pivot exists.

- GIVEN FrameworkVersion FV1 has is_locked=true
- AND the seeder has run once; competency W is in ICO's framework_role_competency (DB pivot present)
  and has framework_bars_indicators rows for (ICO, W)
- WHEN competency W is REMOVED from ICO's competency list in the source JSON (roles.json)
- AND the seeder runs again (in locked mode)
- THEN the stale-unassigned branch is reached for W (W is absent from $currentAssignedIds which is JSON-derived)
- AND BarsIndicator::delete() is NOT called — the destructive delete is suppressed
- AND the `continue` skips BARS processing for W (no new indicator rows are inserted either)
- AND the existing framework_bars_indicators rows for (ICO, W) are PRESERVED byte-for-byte
- AND the framework_role_competency pivot for (ICO, W) is PRESERVED (syncWithoutDetaching does not detach)
- AND no mutation of any kind is applied to W's existing indicator or pivot rows

#### Scenario: Lock-guard — soft-deleted project keeps FV locked; guard still fires

- GIVEN FrameworkVersion FV1 has is_locked=true pinned by Project P1
- WHEN Project P1 is soft-deleted
- AND the seeder runs again
- THEN FV1.is_locked is still true (soft-delete does not unlock)
- AND the seeder still runs in append-only mode (guard fires based on is_locked=true, regardless of project soft-delete)
- AND existing catalog rows are PRESERVED

#### Scenario: Lock-guard inactive — normal unlocked re-seed still delete-stales and mutates

- GIVEN no FrameworkVersion has is_locked=true (all FVs are unlocked or none exist)
- AND the seeder has run once; competency Y exists in framework_role_competency for role FLL,
  with an anchor row having text "Old anchor"
- WHEN competency Y is removed from the FLL JSON fixture
- AND the anchor text for another competency is edited to "New anchor" in the JSON
- AND the seeder runs again
- THEN the stale framework_role_competency pivot for (FLL, Y) is DELETED (guard inactive)
- AND the anchor row is updated to "New anchor" (mutation proceeds normally when no FV is locked)

#### Scenario: Locked FV suppresses new IT translation — explicit signal, not a silent no-op

- GIVEN FrameworkVersion FV1 has is_locked=true
- AND ICO×PRS indicator rows already exist in the DB with only EN translations
- AND the source JSON now carries `it` values for all 12 of ICO×PRS's strings
- WHEN the seeder runs
- THEN none of ICO×PRS's existing rows gain an `it` translation
  (`$model->hasTranslation('field', 'it')` remains false for all 12 strings)
- AND the `seeder_lock_guard_active` signal (log entry and/or `framework_gaps`
  record) is emitted
- AND an operator inspecting the seeder's output can determine, without
  reading source, that IT authoring for ICO×PRS exists in the source JSON but
  was NOT applied because a FrameworkVersion is locked

---

### Requirement: Read-Only Org-Scoped Framework API

The system MUST expose read-only HTTP endpoints (behind `auth:api` middleware
from C2) that serve the framework catalog in the context of the requesting
organization's pinned `FrameworkVersion`. The endpoints MUST be:

- `GET /api/framework/roles` — list all roles for the org's pinned version
- `GET /api/framework/roles/{roleCode}/competencies` — list competencies for a role
- `GET /api/framework/roles/{roleCode}/competencies/{competencyCode}/indicators` — BARS indicators and anchors for a role×competency pair

The BARS endpoint uses a REST-nested form: the resource is always scoped under
both role and competency. The terminal segment is `/indicators`.

All responses MUST be locale-aware. Locale resolution order: (1) explicit `?locale=`
query param — MUST be validated as a member of `config('app.supported_locales')`
(the key `'supported_locales' => ['it','en']` MUST be added to `api/config/app.php`);
(2) `Accept-Language` request header — parsed and matched against `supported_locales`;
(3) `config('app.fallback_locale')` (default `en`). Missing translations for the
resolved locale MUST fall back to `en`. The API MUST NOT expose another
organization's framework data.

The `translation_gap` field in BARS indicator responses MUST be set to `true`
when ANY translatable field (`text`, `anchor_5`, `anchor_3`, `anchor_1`) is
missing the IT *authoring* translation — detected by checking
`$model->hasTranslation('field', 'it')` on EACH of the four fields, NOT just
`text`, and NOT by testing whether the returned value is empty or null.
`translation_gap=true` is an authoring-completeness signal independent of the
request's `?locale=` parameter — it means IT content has not yet been authored,
not that the current request failed.

#### Scenario: Org A user lists roles and sees their pinned version's data

- GIVEN user in Org A is authenticated (auth:api)
- AND Org A has a pinned FrameworkVersion
- WHEN GET /api/framework/roles is called
- THEN the response returns all 5 global roles (ICO, FLL, MLL, BUL, SRX)
  (C3 serves one shared global catalog; there is no per-version role filtering)
- AND Org B data is NOT present in the response

#### Scenario: Cross-tenant isolation — Org B cannot access Org A's framework data

- GIVEN user in Org B is authenticated
- WHEN GET /api/framework/roles is called with Org A's organization_id injected
- THEN the response reflects only Org B's pinned framework data
- AND no Org A data leaks

#### Scenario: Requesting competency BARS returns indicators with anchors

- GIVEN role ICO and competency PRS have seeded BARS indicators
- WHEN GET /api/framework/roles/ICO/competencies/PRS/indicators is called
- THEN the response contains each indicator's text and anchor text for levels 5, 3, 1

#### Scenario: bars_available flag reflects BARS coverage (fixture example for the false case)

- GIVEN the seeder has run against the complete catalogue and ICO/COM has framework_bars_indicators rows
- WHEN GET /api/framework/roles/ICO/competencies is called
- THEN ICO/COM has `bars_available=true`
- GIVEN a role×competency pair with zero framework_bars_indicators rows (test fixture — post-completion no real declared pair is in this state)
- WHEN that role's competencies endpoint is called
- THEN the fixture pair has `bars_available=false`

**Definition**: `bars_available` is `true` when the competency has ≥1 `framework_bars_indicators` row scoped to the requested role (i.e. it is BARS-covered for that role). It is `false` only for a role×competency pair with no indicator rows — a state no real declared pair is in after this change; all 83 declared pairs, including all 18 SRX pairs, have `bars_available=true`.

#### Scenario: All declared pairs report bars_available=true after catalogue completion

- GIVEN the seeder has run against the complete catalogue (83 declared pairs, all anchored)
- WHEN GET /api/framework/roles/{roleCode}/competencies is called for each of the 5 roles
- THEN every returned competency has `bars_available=true`
- AND no role returns `bars_available=false` for any of its declared competencies

#### Scenario: Locale-aware response falls back to EN when IT is absent

- GIVEN a BARS indicator with EN anchor text and no IT anchor text
- WHEN the endpoint is called with locale=it
- THEN the response returns the EN anchor text for that field
- AND the response signals the translation gap (e.g. metadata flag)

#### Scenario: Org with no pinned FrameworkVersion still receives the global catalog → 200

- GIVEN an authenticated organization that has zero `framework_versions` rows
- WHEN GET /api/framework/roles is called by a user of that organization
- THEN the response status is 200
- AND the response body lists all 5 roles (ICO, FLL, MLL, BUL, SRX)
- AND no 404 or 500 error is raised
- AND `pin_context` in the response metadata is null (no pinned version context)

---

### Requirement: Split-File and Unified-Shape Adapter Tolerance

The seeder MUST read the current split-file shape without requiring a flag or
configuration switch. The seeder adapter MUST also accept a future unified
competency object shape (where a single JSON entry carries both competency
metadata and its BARS indicators). When the unified shape is detected, the
seeder MUST parse it correctly and produce the same DB state as the split-file
path would for the same data.

#### Scenario: Split-file shape produces correct DB state

- GIVEN competencies.json and bars/ICO.json are present in split-file format
- WHEN the seeder runs
- THEN roles, competencies, and bars_indicators are populated correctly

#### Scenario: Unified shape produces the same DB state

- GIVEN a unified competency object (competency metadata + BARS co-located)
- WHEN the seeder adapter processes it
- THEN the resulting roles, competencies, and bars_indicators match what split-file seeding would produce

---

### Requirement: Data-Gap Authoring Requirements (Tracked, Not Fabricated)

The following domain data MUST NOT be invented or approximated by C3. Each
gap MUST be recorded as an explicit authoring task in the `framework_gaps` table
(a proper migration — see design Schema section) so gaps are queryable, not
silent. The `framework_gaps` table carries: `kind`, `role_code` (nullable),
`competency_code` (nullable), `note` (nullable), `status` (default `pending_authoring`).

SRX BARS indicators and SRX `responsibilities`, once authored as a
calibrated draft (see Requirement: SRX Role Responsibilities — Authored
Prerequisite and Requirement: Complete Role×Competency BARS Coverage), are
catalogue content authored by this change — not domain data C3 defers to
client/expert authoring. The same is now true of `it` translations for any
role×competency pair within an agreed, shipped scope (see
`framework-catalog-it-translations`): once a pair's 12 strings are translated
and seeded, that pair is catalogue content, not a client-deferred gap. The
client/expert-authorship deferral remains for MTG/LAT competency definitions,
and for `it` translations of pairs that fall OUTSIDE the agreed scope of any
landed translation change.

Known gaps at first seed (post-completion):
- MTG and LAT competency definitions and anchors — required for `potential`
  assessment type → `{kind: missing_potential_competency, competency_code:
  MTG|LAT}`
- IT locale translations for role×competency pairs outside the agreed,
  shipped translation scope — gates non-EN scoring in C9 for those pairs only
  → `{kind: missing_translation}`. An `it`-language project scoring against
  an untranslated pair is marked unscorable with `unscorable_reason =
  'anchor_translation_missing'` (scoring-engine behavior, unchanged by this
  change). Pairs within the shipped scope are NOT in this gap list once
  translated (see Requirement: Gap Row Reconciliation on Seeded Content).

The system MUST remain queryable (returning partial data) while gaps
persist. A partial catalog MUST NOT cause API errors or seeder failures.
(Previously: the client/expert-authorship deferral for IT translations
covered the entire catalogue unconditionally, with no notion of a shipped
translation scope; this reverses that deferral for translated pairs.)

#### Scenario: API responds correctly with a partial catalog (remaining gaps)

- GIVEN the catalog is in a partial state (MTG/LAT absent, some IT
  translations absent outside the shipped scope)
- WHEN GET /api/framework/roles is called
- THEN the response lists all 5 roles including SRX, with populated
  responsibilities and full BARS coverage
- AND no 500 error or exception is raised

#### Scenario: Gap log is inspectable after seeder run

- GIVEN the seeder has run with the remaining known gaps (MTG/LAT absent,
  out-of-scope IT locale translations absent)
- WHEN the seeder gap log or report is inspected
- THEN it lists each gap with a human-readable description
- AND each gap has a status of "pending authoring"
- AND no competency_no_bars, role_no_bars, or SRX missing_role_meta rows
  appear (all resolved by earlier catalogue completion)
- AND no missing_translation entry appears for a pair that has all 12 of its
  strings translated in `it`

---

### Requirement: Locale Dimension Uses Nested Keys, Visible to Every Content Guard

The catalogue JSON's locale dimension MUST be represented as a nested key
inside each existing translatable field's value (e.g.
`{"en": "...", "it": "..."}`), inside the existing per-role and per-domain
files. Sibling per-locale files or directories (e.g. `bars/it/{ROLE}.json`)
and filename-suffixed locale variants (e.g. `bars/{ROLE}.it.json`) MUST NOT
be used, because every non-parity CI content guard enumerates catalogue files
non-recursively and derives the role from the filename — either scheme makes
IT content invisible to, or misidentified by, those guards. No locale MAY be
invisible to any content guard by virtue of file layout or naming.

Every existing CI content guard (malformed-entry, overlong-anchor,
cross-role-duplicate, and both completeness gates) MUST be updated to read
the nested-locale shape and MUST be proven to run its checks against
non-`en` locale content via a self-test in the wrapper CI step (f) — the
guard function under test MUST be the SAME function the real gate invokes,
and the self-test fixture MUST include a deliberately broken `it` value that
the guard is asserted to catch.

#### Scenario: A content guard demonstrably fails on broken Italian content

- GIVEN a step (f) self-test fixture where an `it` anchor value exceeds the
  configured word-count ceiling
- WHEN `catalog_overlong_bars_anchors` (the same function the real gate
  calls) runs against the fixture
- THEN the guard reports a failure
- AND the failure is attributed to the `it` value, not silently skipped

#### Scenario: Cross-role duplicate detection reads Italian strings, not phantom roles

- GIVEN two roles share identical `it` anchor text for the same competency
  in the nested-locale shape
- WHEN the cross-role duplicate-detection script runs
- THEN it reports the Italian duplicate under the two real role codes
- AND no phantom role (e.g. `ICO.it`) appears in its output

---

### Requirement: Per-Locale Anchor Length Ceiling, Measured Not Inherited

Each supported locale MUST have its own blocking word-count ceiling and
advisory word-count floor for BARS anchor text, calibrated by measuring a
representative sample of that locale's OWN authored content. A locale's
ceiling and floor MUST NOT default to another locale's numeric threshold and
MUST NOT be invented without a recorded measurement. The measurement basis
(what was measured, how many samples, and the resulting distribution) MUST
be recorded alongside the configured value, mirroring the existing English
ceiling's own recorded basis.

#### Scenario: Italian anchors are checked against a calibrated Italian ceiling

- GIVEN the Italian anchor-length ceiling has been calibrated from a
  measured pilot competency and recorded
- WHEN a CI content guard checks Italian anchor word counts
- THEN it compares against the Italian-specific ceiling, not the English
  ceiling value

#### Scenario: An un-measured locale ceiling is rejected at config time

- GIVEN a locale's ceiling configuration has no recorded measurement basis
- WHEN the CI guard configuration is validated
- THEN the missing basis is flagged rather than silently defaulting to
  another locale's number

---

### Requirement: Italian Authoring Standard Precedes Content

A sibling Italian-language authoring standard document MUST exist and be
committed before any Italian BARS, competency, or role content is merged. It
MUST specify, at minimum: the Italian indicator form, the Italian anchor
form, register (professional/neutral business Italian — never regional), an
Italian deficit-verb inventory for level 1 that carries equivalent force to
the English inventory without inventing severity the English does not
express, and orthography conventions (accents, apostrophes). The standard
MUST be reviewed by a native Italian speaker with assessment-domain
competence.

#### Scenario: A content PR without a preceding authoring standard is blocked

- GIVEN no Italian authoring standard document exists in the repository
- WHEN an Italian content PR is opened
- THEN the PR cannot be merged under the documented process (the standard is
  a stated prerequisite, checked at review)

#### Scenario: The standard specifies non-regional professional register

- GIVEN the Italian authoring standard document
- WHEN its register section is read
- THEN it states professional/neutral business Italian and explicitly
  excludes regional or colloquial variants

---

### Requirement: Partial IT-Coverage Control File (Both-Direction Doctrine)

When Italian content ships in slices (e.g. role by role) rather than as one
complete landing, a NEW control file — distinct from
`scripts/framework-known-gaps.txt` and
`scripts/framework-competency-gaps.txt`, which answer different questions and
MUST NOT absorb this one — MUST track role×competency pairs still pending
`it` translation. It MUST be enforced in both directions, matching the
doctrine of the two existing control files: a role×competency pair that is
NOT fully translated (all 12 strings) AND is NOT listed in this control file
MUST fail CI; a pair LISTED in this control file that IS now fully
translated MUST also fail CI (stale exemption). If and when the entire
agreed scope ships as one landing with no partial state, this file MUST be
empty, exactly like the other two control files.

#### Scenario: An untranslated, unlisted pair fails CI

- GIVEN role×competency pair BUL×STG is not fully translated to `it`
- AND BUL×STG is NOT listed in the IT-coverage control file
- WHEN the wrapper catalog gate runs
- THEN it fails, naming BUL×STG as an undeclared translation gap

#### Scenario: A stale exemption for a now-translated pair fails CI

- GIVEN ICO×PRS is listed in the IT-coverage control file as a pending
  exemption
- AND ICO×PRS now has all 12 strings translated to `it`
- WHEN the wrapper catalog gate runs
- THEN it fails, naming ICO×PRS as a stale exemption that must be removed
  from the control file

#### Scenario: The control file is empty once the full agreed scope ships

- GIVEN every role×competency pair in the agreed scope is fully translated
- WHEN the wrapper catalog gate runs
- THEN the IT-coverage control file contains zero entries and the gate
  passes

---

### Requirement: Locale Merge Semantics — Adding Is Idempotent-Safe, Removing Is Not

`setTranslation('field', $locale, $value)` MERGES into the existing JSON
translation column; it MUST NOT be relied upon to remove a locale. Removing
an `it` value from the source JSON and re-seeding MUST NOT be expected to
remove the corresponding `it` translation from the database — the seeder
provides no delete-locale path via normal seeding. Removing a locale from
the database, when required, MUST be performed by a targeted, explicit
operation (e.g. a `forgetTranslation('it')` pass over the affected rows) —
NOT by editing the source JSON and re-running the seeder.

#### Scenario: Re-seeding after removing IT from the source does not remove it from the DB

- GIVEN a BarsIndicator has both `en` and `it` translations persisted
- AND the `it` value is removed from the field's source JSON
- WHEN the seeder runs again (no locked FrameworkVersion)
- THEN the `it` translation is still present on the model
  (`hasTranslation('field', 'it')` remains true)
- AND the `en` translation is updated to reflect the current source value

#### Scenario: Locale removal requires an explicit targeted operation

- GIVEN an operator needs to remove a mistakenly-seeded `it` translation
- WHEN the removal is performed
- THEN it is performed via a dedicated `forgetTranslation('it')`-style
  operation targeting the specific rows, documented as distinct from a
  normal seeder re-run

---

## Non-Goals (Explicit)

The following are OUT OF SCOPE for C3 and MUST NOT be implemented here:

- **Scoring engine** — LLM invocation, indicator scoring, competency mean calculation (C9)
- **Project → framework_version FK and pin-at-creation** — C4 wires this FK after C3 creates the `framework_versions` table
- **Per-org BARS overrides or customization** — future additive capability; C3 base is global (working draft); immutability is achieved at C4 pin time via snapshot-at-pin
- **MTG/LAT scoring flow** — blocked pending authoring; flagged but not implemented
- **Inventing missing domain data** — MTG/LAT competency definitions remain client/expert artifacts; C3 records the gap only. IT locale translations for translated role×competency pairs are catalogue content (handled by `framework-catalog-it-translations`), not client-deferred domain data. SRX BARS indicators and SRX `responsibilities` are NOT in this list: the `bars-catalogue-completion` change authored them as a calibrated draft — catalogue content, not client-deferred domain data — extrapolated from the complete ICO file, the existing leader-role pairs, `competencies.json`, and the `roles.json` seniority ladder. That draft is pending assessment-specialist sign-off before it scores a real candidate; sign-off is a release gate, not a follow-up
