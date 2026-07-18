# Delta for Framework Catalog

> **Type**: MODIFICATION to the promoted spec at
> `openspec/specs/framework-catalog/spec.md`
>
> This delta is driven by **C4 (project-config)**. It encodes only the
> requirements that C4 changes. All other requirements from the promoted spec
> remain valid and unchanged.

---

## MODIFIED Requirements

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

(Previously: the seeder always performed delete-stale unconditionally. C4 adds
the lock-guard that suppresses destructive deletes when any FV is locked.)

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
- AND the seeder has run once and ICO has a framework_role_competency pivot for competency X, and framework_bars_indicators rows for (ICO, X)
- WHEN one competency is removed from that role in the source JSON fixture
- AND the seeder runs again
- THEN the stale framework_role_competency pivot row for (ICO, X) is DELETED
- AND the stale framework_bars_indicators rows for (ICO, X) are DELETED
- AND all other pivot and indicator rows are unchanged

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

### Requirement: Tenant-Scoped FrameworkVersion Pin

The system MUST provide a `framework_versions` table that extends the C2
`TenantModel` pattern, scoped per organization via `organization_id`. The
table MUST record: `organization_id`, a catalog `version` identifier, a
`label` (human display name for the draft, nullable string), `is_locked`
(bool, default false), and timestamps.

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

(Previously: C3 noted `projects()` as a forward-looking placeholder; C4
wires the real hasMany relation.)

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

## Non-Goals (Explicit for this delta)

The following are OUT OF SCOPE for this delta and for C4:

- **Scoring engine** — C9
- **Per-org BARS overrides or customization** — future capability
- **MTG/LAT competency authoring** — C3 authoring gap; C4 reads catalog as-is
- **Inventing missing domain data** — SRX BARS, IT translations are client artifacts; gap records only
- **Data-copy snapshot Option B** — C13; C4 uses reference-pin
- **Deadline/goes_live_at scheduled jobs** — C12/C13
