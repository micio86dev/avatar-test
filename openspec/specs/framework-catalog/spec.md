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

The seeder MUST use `setTranslation('field', 'en', $value)` per field (NOT
bulk `updateOrCreate` on the raw JSON column), so that a manually-added IT
translation persists across a re-seed.

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
catalog rows waits until no FV is locked. Byte-for-byte preservation of existing rows wins.

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

#### Scenario: Missing bars/SRX.json is skipped gracefully

- GIVEN bars/SRX.json does not exist on disk
- WHEN the FrameworkCatalogSeeder runs
- THEN the seeder does NOT throw an exception
- AND SRX role metadata (name) is still seeded from roles.json
- AND a gap entry is recorded flagging "SRX BARS indicators missing"
- AND framework_bars_indicators contains zero rows for SRX

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

- GIVEN the seeder has run successfully
- WHEN framework_bars_indicators are counted per role
- THEN ICO has 45 rows (15 competencies × 3 indicators)
- AND FLL has 24 rows (8 competencies × 3 indicators)
- AND MLL has 24 rows (8 competencies × 3 indicators)
- AND BUL has 24 rows (8 competencies × 3 indicators)
- AND SRX has 0 rows

#### Scenario: Re-seeding after correcting a gap adds the missing rows

- GIVEN bars/SRX.json was absent on the first seed run
- AND bars/SRX.json is subsequently authored and placed on disk
- WHEN the seeder runs again
- THEN SRX BARS indicators are inserted
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

#### Scenario: bars_available flag is true for BARS-covered competencies and false for gap competencies

- GIVEN the seeder has run and ICO/COM has framework_bars_indicators rows; FLL/PRS has no framework_bars_indicators rows for FLL
- WHEN GET /api/framework/roles/ICO/competencies is called
- THEN ICO/COM has `bars_available=true`
- WHEN GET /api/framework/roles/FLL/competencies is called
- THEN FLL/PRS has `bars_available=false`

**Definition**: `bars_available` is `true` when the competency has ≥1 `framework_bars_indicators` row scoped to the requested role (i.e. it is BARS-covered for that role). It is `false` for gap competencies (those present in `framework_role_competency` but absent from the role's BARS file). All SRX competencies have `bars_available=false` because SRX has no BARS file.

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

Known gaps at first seed:
- `bars/SRX.json` — BARS indicators for Senior Executive role (missing file) → `{kind: role_no_bars, role_code: SRX}`
- SRX `responsibilities` is empty string in roles.json → `{kind: missing_role_meta, role_code: SRX}` — seeded as-is; client to provide text
- FLL 10 BARS gaps — competencies assigned but absent from bars/FLL.json (PRS, JDG, DRV, SLF, TMG, COM, COL, NET, ITG, INC) → 10 × `{kind: competency_no_bars, role_code: FLL, competency_code: CODE}`
- MLL 10 BARS gaps — competencies assigned but absent from bars/MLL.json (same 10 as FLL) → 10 × `{kind: competency_no_bars, role_code: MLL, competency_code: CODE}`
- BUL 6 BARS gaps — competencies assigned but absent from bars/BUL.json (PRS, JDG, DRV, TMG, COL, NET) → 6 × `{kind: competency_no_bars, role_code: BUL, competency_code: CODE}`
- MTG and LAT competency definitions and anchors — required for `potential` assessment type → `{kind: missing_potential_competency, competency_code: MTG|LAT}`
- IT locale translations for all names, definitions, and anchor texts — gates non-EN scoring in C9 → `{kind: missing_translation}`

The system MUST remain queryable (returning partial data) while gaps persist.
A partial catalog MUST NOT cause API errors or seeder failures.

#### Scenario: API responds correctly with partial catalog

- GIVEN the catalog is in a partial state (SRX BARS absent, MTG/LAT absent)
- WHEN GET /api/framework/roles is called
- THEN the response lists all 5 roles including SRX
- AND SRX competencies are listed (from roles.json)
- AND no 500 error or exception is raised

#### Scenario: Gap log is inspectable after seeder run

- GIVEN the seeder has run with known gaps (SRX.json missing, MTG/LAT absent)
- WHEN the seeder gap log or report is inspected
- THEN it lists each gap with a human-readable description
- AND each gap has a status of "pending authoring"

---

## Non-Goals (Explicit)

The following are OUT OF SCOPE for C3 and MUST NOT be implemented here:

- **Scoring engine** — LLM invocation, indicator scoring, competency mean calculation (C9)
- **Project → framework_version FK and pin-at-creation** — C4 wires this FK after C3 creates the `framework_versions` table
- **Per-org BARS overrides or customization** — future additive capability; C3 base is global (working draft); immutability is achieved at C4 pin time via snapshot-at-pin
- **MTG/LAT scoring flow** — blocked pending authoring; flagged but not implemented
- **Inventing missing domain data** — SRX BARS, MTG/LAT defs, IT translations are client/expert artifacts; C3 records the gap only
