# Delta for framework-catalog

## ADDED Requirements

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
competency gains a BARS entry, a role's BARS file is added, or a role's
`responsibilities` becomes non-empty), the seeder MUST resolve the matching
`framework_gaps` row — updating `status` away from `pending_authoring` (e.g.
to `resolved`) or removing the row — rather than leaving it
`pending_authoring` indefinitely. Gap resolution MUST proceed even while a
`FrameworkVersion` is locked (`framework_gaps` writes are exempt from
lock-guard mutation suppression, consistent with
`FrameworkGap::updateOrCreate` being exempt for new gaps).

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

## MODIFIED Requirements

### Requirement: Data-Gap Authoring Requirements (Tracked, Not Fabricated)

The following domain data MUST NOT be invented or approximated by C3. Each
gap MUST be recorded as an explicit authoring task in the `framework_gaps`
table (a proper migration — see design Schema section) so gaps are
queryable, not silent. The `framework_gaps` table carries: `kind`,
`role_code` (nullable), `competency_code` (nullable), `note` (nullable),
`status` (default `pending_authoring`).

SRX BARS indicators and SRX `responsibilities`, once authored as a
calibrated draft (see Requirement: SRX Role Responsibilities — Authored
Prerequisite and Requirement: Complete Role×Competency BARS Coverage), are
catalogue content authored by this change — not domain data C3 defers to
client/expert authoring. The client/expert-authorship deferral remains only
for MTG/LAT competency definitions and for IT locale translations of the
full catalogue (existing and newly authored anchors alike).

Known gaps at first seed (post-completion):
- MTG and LAT competency definitions and anchors — required for `potential`
  assessment type → `{kind: missing_potential_competency, competency_code:
  MTG|LAT}`
- IT locale translations for all names, definitions, and anchor texts —
  gates non-EN scoring in C9 → `{kind: missing_translation}`. Applies to the
  full 747-anchor catalogue, including the 396 newly authored anchors; an
  `it`-language project scoring against an untranslated anchor is marked
  unscorable with `unscorable_reason = 'anchor_translation_missing'`
  (scoring-engine behavior, unchanged by this change).

The system MUST remain queryable (returning partial data) while gaps
persist. A partial catalog MUST NOT cause API errors or seeder failures.
(Previously: also listed `role_no_bars` for SRX, `missing_role_meta` for
SRX, and 26 `competency_no_bars` entries for FLL/MLL/BUL — all closed by
this change.)

#### Scenario: API responds correctly with a partial catalog (remaining gaps)

- GIVEN the catalog is in a partial state (MTG/LAT absent, some IT
  translations absent)
- WHEN GET /api/framework/roles is called
- THEN the response lists all 5 roles including SRX, with populated
  responsibilities and full BARS coverage
- AND no 500 error or exception is raised

#### Scenario: Gap log is inspectable after seeder run

- GIVEN the seeder has run with the remaining known gaps (MTG/LAT absent,
  IT locale translations absent)
- WHEN the seeder gap log or report is inspected
- THEN it lists each gap with a human-readable description
- AND each gap has a status of "pending authoring"
- AND no competency_no_bars, role_no_bars, or SRX missing_role_meta rows
  appear (all resolved by this change)

---

### Requirement: Idempotent Catalog Seeder (sync delete-stale)

The system MUST provide a `FrameworkCatalogSeeder` that seeds the global
catalog from the split-file JSON shape (`competencies.json` +
`bars/{ROLE}.json`). The seeder MUST be idempotent: running it N times MUST
produce the same database state as running it once. Duplicate rows MUST NOT
be created.

The seeder MUST use natural-key upserts (role code, competency code,
role×competency×indicator position) AND MUST delete stale rows **unless a
locked FrameworkVersion exists** (see guard clause below):
- `framework_role_competency` pivot: use `sync` (not `syncWithoutDetaching`)
  — stale pivots for competencies removed from a role in the JSON are
  deleted.
- `framework_bars_indicators`: after upserting the current set for a (role,
  competency) pair, delete any rows with positions not present in the
  current JSON.

**Seeder lock-guard (added by C4) — FULLY ADDITIVE when locked:** Before
executing any delete-stale or mutation operation against the catalog
tables, the seeder MUST check whether any `FrameworkVersion` record has
`is_locked = true` (query MUST use `withoutGlobalScopes()` — no HTTP
request/tenant is set during artisan seeding). If at least one locked
`FrameworkVersion` exists, the seeder MUST become PURELY ADDITIVE:

1. ALL destructive deletes MUST be skipped (delete-stale calls and
   `sync`-detach operations on `framework_role_competency` pivots and
   `framework_bars_indicators` rows). This includes the
   stale-unassigned-competency delete block inside the BARS loop: when a
   competency is absent from `$currentAssignedIds` (which is JSON-derived —
   NOT DB-pivot-derived), the `BarsIndicator::delete()` MUST be suppressed,
   but the `continue` (which skips BARS processing for that competency)
   MUST be preserved. The existing indicator rows and DB pivot for a
   JSON-removed-but-DB-preserved competency MUST remain byte-for-byte
   untouched.
2. ALL mutations of existing CATALOG rows MUST be skipped —
   `setTranslation()`, the update half of `updateOrCreate()`, and any other
   write that would change an already-persisted row in `framework_roles`,
   `framework_competencies`, `framework_bars_indicators`,
   `framework_role_competency`, or their translation columns MUST be
   bypassed via a per-call-site `$model->exists` gate: if the model already
   exists (`$model->exists === true`), capture the id and skip; only new
   rows (`$model->exists === false`) may be mutated and saved. Existing
   rows MUST remain byte-for-byte unchanged.
3. Only genuinely NEW rows (not yet present by natural key) MAY be
   inserted.
4. The seeder MUST emit a clear, structured signal (log entry and/or gap
   record with `kind: seeder_lock_guard_active`) so the operator is aware
   the guard fired.

**EXEMPT from suppression — `framework_gaps`, `catalog_meta`, and the
lock-guard signal:** `FrameworkGap::updateOrCreate(...)` and
`CatalogMeta::bump()` MUST continue normally even when the lock-guard is
active. These are operational and tracking rows, NOT catalog content. The
suppression applies ONLY to existing catalog rows (roles, competencies,
indicators, pivots, and their translations).

The `seeder_lock_guard_active` signal — emitted as a log entry and/or a
`FrameworkGap` record with `kind: seeder_lock_guard_active` — is ALSO EXEMPT
from mutation-suppression. It is an operational signal (not catalog
content) and MUST be emitted ONCE, immediately after the
`hasLockedVersions()` check returns `true` at the top of `run()`, before any
catalog processing begins. The signal is not suppressed by the guard it is
reporting.

**New-locale suppression (explicit):** While ANY FV is locked, adding a new
locale translation to an EXISTING catalog row IS a mutation of that row. It
is SUPPRESSED (the per-call-site `$model->exists` gate skips the
`setTranslation` call for pre-existing rows). New-translation authoring for
existing catalog rows waits until no FV is locked. Byte-for-byte
preservation of existing rows wins.

**`CatalogMeta::bump()` in additive mode:** `bump()` MUST be called only
when at least one genuinely new row was inserted during this seeder run. If
the seeder ran in additive mode but inserted no new rows,
`CatalogMeta::bump()` MUST NOT be called (no structural change occurred).
This is correct: the bump signals new catalog content arrived, not that
mutations were suppressed.

**Semantic**: an anchor text edit in the source JSON after a FV is locked is
silently IGNORED while any FV is locked. This is correct, intentional
behavior — the locked catalog rows must remain unchanged to preserve C9
scoring determinism. New competencies/indicators added to the JSON are
still inserted (additive). This asymmetry (insert-allowed,
mutate-forbidden) is the core contract.

If no locked `FrameworkVersion` exists, full delete-stale + mutation
behavior MUST proceed as before (existing behavior unchanged).

This delete-stale behavior is INTENTIONAL for a working draft: re-seeding
reflects the JSON exactly, eliminating orphan rows. Snapshots taken at C4
pin time are what remain immutable — not the draft catalog.

For every role that has a BARS file, the seeder MUST compare the role's
assigned competencies (from `framework_role_competency`) against the keys
present in that role's BARS file. Each assigned competency NOT present as a
key in the BARS file MUST be recorded as a gap entry `{kind:
competency_no_bars, role_code: ROLE, competency_code: CODE}`.

The seeder MUST gracefully skip a missing BARS file and MUST log or record
a structured gap entry `{kind: role_no_bars}` flagging the missing data. It
MUST NOT throw an exception or halt for a missing file. After skipping, the
affected role's competency records MUST still be seeded (from
`competencies.json`) if present.

The seeder MUST tolerate a future unified competency object shape (where
competency metadata and BARS anchors are co-located) without requiring code
changes to the split-file path.
(Previously: three real-data scenarios illustrated partial coverage using
BUL/FLL/MLL's actual 2026 gap counts, and the missing/re-seeded-file
scenarios named the real SRX role. All four are consolidated into
fixture-based scenarios below, since post-completion no real declared role
or pair is in a "missing BARS" state.)

#### Scenario: First run seeds roles and competencies from JSON

- GIVEN the JSON files competencies.json and bars/ICO.json are present
- WHEN the FrameworkCatalogSeeder runs for the first time
- THEN roles and competencies matching the JSON are present in the DB
- AND ICO BARS indicators are present with correct anchor text

#### Scenario: Second run produces no duplicates (idempotency)

- GIVEN the seeder has already run once
- WHEN the seeder runs again without any data change
- THEN the row counts for framework_roles, framework_competencies, and
  framework_bars_indicators are identical
- AND no duplicate rows exist

#### Scenario: Missing BARS file for a role is skipped gracefully (fixture)

- GIVEN a fixture role has no bars/{ROLE}.json file on disk (post-completion,
  no real declared role lacks a BARS file — this exercises the defensive
  path only)
- WHEN the FrameworkCatalogSeeder runs
- THEN the seeder does NOT throw an exception
- AND the role's metadata (name, responsibilities) is still seeded from
  roles.json
- AND a role_no_bars gap entry is recorded
- AND framework_bars_indicators contains zero rows for that role

#### Scenario: MTG/LAT absent — potential catalog flagged incomplete

- GIVEN neither competencies.json nor any bars file defines MTG or LAT
- WHEN the FrameworkCatalogSeeder runs
- THEN no MTG or LAT rows are created
- AND a gap entry is recorded flagging "MTG/LAT competencies absent —
  potential assessment type incomplete"
- AND the seeder completes successfully

#### Scenario: Seeder creates indicator rows only for competencies present in a role's BARS file (fixture)

- GIVEN a role's bars/{ROLE}.json fixture defines BARS for a subset of that
  role's assigned competencies (not all)
- WHEN the FrameworkCatalogSeeder runs
- THEN framework_bars_indicators rows are created only for the competencies
  present in the fixture file (3 rows per present competency)
- AND a competency_no_bars gap entry is recorded for each
  assigned-but-absent competency

#### Scenario: Seeded-count correctness — per-role BARS coverage

- GIVEN the seeder has run successfully against the complete catalogue (all
  83 declared pairs anchored)
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
- AND the seeder has run once and a role (e.g. ICO) has a
  `framework_role_competency` pivot for competency X, and
  `framework_bars_indicators` rows for (ICO, X)
- WHEN one competency is removed from that role in the source JSON fixture
- AND the seeder runs again
- THEN the stale `framework_role_competency` pivot row for (ICO, X) is
  DELETED
- AND the stale `framework_bars_indicators` rows for (ICO, X) are DELETED
- AND all other pivot and indicator rows are unchanged
- (This proves `sync`/delete-stale is used, NOT `syncWithoutDetaching`)

#### Scenario: Lock-guard — fully additive when a locked FV exists (delete-stale and mutations suppressed)

- GIVEN FrameworkVersion FV1 has is_locked=true (pinned by at least one
  project; set via explicit property assignment, not mass-assign)
- AND the seeder has run once; competency X is in ICO's
  framework_role_competency and framework_bars_indicators, with anchor text
  "Anchor text original" for indicator at position 1, and competency X has
  name translation "name original" in EN
- WHEN the anchor text for that indicator is EDITED in the JSON fixture to
  "Anchor text MODIFIED"
- AND the EN name for competency X is EDITED in competencies.json to "name
  MODIFIED"
- AND a brand-new competency Z with its indicator rows (not yet in the DB)
  is added to both competencies.json and the ICO bars fixture
- AND the seeder runs again
- THEN the existing anchor row for (ICO, X, position=1) is UNCHANGED —
  anchor text is still "Anchor text original" (mutation suppressed by
  per-call-site $model->exists gate)
- AND the EN name translation for competency X is UNCHANGED — still "name
  original" (new-locale and name-edit mutations suppressed for existing
  rows)
- AND the framework_role_competency pivot for (ICO, X) is PRESERVED
  (delete-stale skipped)
- AND the framework_bars_indicators rows for (ICO, X) are PRESERVED
- AND competency Z IS inserted into framework_competencies (new row —
  additive)
- AND competency Z's indicator rows ARE inserted into
  framework_bars_indicators (new rows — additive; a new competency and its
  indicators must both be inserted, no orphan competency-without-indicators)
- AND the framework_role_competency pivot for (ICO, Z) IS inserted
  (syncWithoutDetaching adds new pivots)
- AND framework_gaps upserts (e.g., missing_translation, competency_no_bars
  for new gaps) STILL OCCUR — not suppressed
- AND a structured signal (log entry or gap record with
  kind=seeder_lock_guard_active) is emitted

#### Scenario: Lock-guard — JSON-removed-but-DB-preserved competency leaves indicators and pivot intact

**Context:** `$currentAssignedIds` in the seeder BARS loop is built from
`array_keys($assignedIds)`, which reflects the CURRENT JSON — NOT the DB
pivot state. In locked mode, `syncWithoutDetaching` preserves pivot rows for
competencies removed from the JSON; such competencies reach the
stale-unassigned branch (not in `$currentAssignedIds`) even though their DB
pivot exists.

- GIVEN FrameworkVersion FV1 has is_locked=true
- AND the seeder has run once; competency W is in ICO's
  framework_role_competency (DB pivot present) and has
  framework_bars_indicators rows for (ICO, W)
- WHEN competency W is REMOVED from ICO's competency list in the source
  JSON (roles.json)
- AND the seeder runs again (in locked mode)
- THEN the stale-unassigned branch is reached for W (W is absent from
  $currentAssignedIds which is JSON-derived)
- AND BarsIndicator::delete() is NOT called — the destructive delete is
  suppressed
- AND the `continue` skips BARS processing for W (no new indicator rows are
  inserted either)
- AND the existing framework_bars_indicators rows for (ICO, W) are
  PRESERVED byte-for-byte
- AND the framework_role_competency pivot for (ICO, W) is PRESERVED
  (syncWithoutDetaching does not detach)
- AND no mutation of any kind is applied to W's existing indicator or pivot
  rows

#### Scenario: Lock-guard — soft-deleted project keeps FV locked; guard still fires

- GIVEN FrameworkVersion FV1 has is_locked=true pinned by Project P1
- WHEN Project P1 is soft-deleted
- AND the seeder runs again
- THEN FV1.is_locked is still true (soft-delete does not unlock)
- AND the seeder still runs in append-only mode (guard fires based on
  is_locked=true, regardless of project soft-delete)
- AND existing catalog rows are PRESERVED

#### Scenario: Lock-guard inactive — normal unlocked re-seed still delete-stales and mutates

- GIVEN no FrameworkVersion has is_locked=true (all FVs are unlocked or none
  exist)
- AND the seeder has run once; competency Y exists in
  framework_role_competency for role FLL, with an anchor row having text
  "Old anchor"
- WHEN competency Y is removed from the FLL JSON fixture
- AND the anchor text for another competency is edited to "New anchor" in
  the JSON
- AND the seeder runs again
- THEN the stale framework_role_competency pivot for (FLL, Y) is DELETED
  (guard inactive)
- AND the anchor row is updated to "New anchor" (mutation proceeds normally
  when no FV is locked)

---

### Requirement: Read-Only Org-Scoped Framework API

The system MUST expose read-only HTTP endpoints (behind `auth:api`
middleware from C2) that serve the framework catalog in the context of the
requesting organization's pinned `FrameworkVersion`. The endpoints MUST be:

- `GET /api/framework/roles` — list all roles for the org's pinned version
- `GET /api/framework/roles/{roleCode}/competencies` — list competencies
  for a role
- `GET /api/framework/roles/{roleCode}/competencies/{competencyCode}/indicators`
  — BARS indicators and anchors for a role×competency pair

The BARS endpoint uses a REST-nested form: the resource is always scoped
under both role and competency. The terminal segment is `/indicators`.

All responses MUST be locale-aware. Locale resolution order: (1) explicit
`?locale=` query param — MUST be validated as a member of
`config('app.supported_locales')` (the key `'supported_locales' =>
['it','en']` MUST be added to `api/config/app.php`); (2) `Accept-Language`
request header — parsed and matched against `supported_locales`; (3)
`config('app.fallback_locale')` (default `en`). Missing translations for
the resolved locale MUST fall back to `en`. The API MUST NOT expose another
organization's framework data.

The `translation_gap` field in BARS indicator responses MUST be set to
`true` when ANY translatable field (`text`, `anchor_5`, `anchor_3`,
`anchor_1`) is missing the IT *authoring* translation — detected by
checking `$model->hasTranslation('field', 'it')` on EACH of the four
fields, NOT just `text`, and NOT by testing whether the returned value is
empty or null. `translation_gap=true` is an authoring-completeness signal
independent of the request's `?locale=` parameter — it means IT content has
not yet been authored, not that the current request failed.
(Previously: the `bars_available` false-case example used the real gap
pair FLL/PRS, and the Definition text claimed all SRX competencies are
`bars_available=false`. Both are corrected by this change.)

#### Scenario: Org A user lists roles and sees their pinned version's data

- GIVEN user in Org A is authenticated (auth:api)
- AND Org A has a pinned FrameworkVersion
- WHEN GET /api/framework/roles is called
- THEN the response returns all 5 global roles (ICO, FLL, MLL, BUL, SRX)
  (C3 serves one shared global catalog; there is no per-version role
  filtering)
- AND Org B data is NOT present in the response

#### Scenario: Cross-tenant isolation — Org B cannot access Org A's framework data

- GIVEN user in Org B is authenticated
- WHEN GET /api/framework/roles is called with Org A's organization_id
  injected
- THEN the response reflects only Org B's pinned framework data
- AND no Org A data leaks

#### Scenario: Requesting competency BARS returns indicators with anchors

- GIVEN role ICO and competency PRS have seeded BARS indicators
- WHEN GET /api/framework/roles/ICO/competencies/PRS/indicators is called
- THEN the response contains each indicator's text and anchor text for
  levels 5, 3, 1

#### Scenario: bars_available flag reflects BARS coverage (fixture example for the false case)

- GIVEN the seeder has run against the complete catalogue and ICO/COM has
  framework_bars_indicators rows
- WHEN GET /api/framework/roles/ICO/competencies is called
- THEN ICO/COM has `bars_available=true`
- GIVEN a role×competency pair with zero framework_bars_indicators rows
  (test fixture — post-completion no real declared pair is in this state)
- WHEN that role's competencies endpoint is called
- THEN the fixture pair has `bars_available=false`

**Definition**: `bars_available` is `true` when the competency has ≥1
`framework_bars_indicators` row scoped to the requested role (i.e. it is
BARS-covered for that role). It is `false` only for a role×competency pair
with no indicator rows — a state no real declared pair is in after this
change; all 83 declared pairs, including all 18 SRX pairs, have
`bars_available=true`.

#### Scenario: All declared pairs report bars_available=true after catalogue completion

- GIVEN the seeder has run against the complete catalogue (83 declared
  pairs, all anchored)
- WHEN GET /api/framework/roles/{roleCode}/competencies is called for each
  of the 5 roles
- THEN every returned competency has `bars_available=true`
- AND no role returns `bars_available=false` for any of its declared
  competencies

#### Scenario: Locale-aware response falls back to EN when IT is absent

- GIVEN a BARS indicator with EN anchor text and no IT anchor text
- WHEN the endpoint is called with locale=it
- THEN the response returns the EN anchor text for that field
- AND the response signals the translation gap (e.g. metadata flag)

#### Scenario: Org with no pinned FrameworkVersion still receives the global catalog → 200

- GIVEN an authenticated organization that has zero `framework_versions`
  rows
- WHEN GET /api/framework/roles is called by a user of that organization
- THEN the response status is 200
- AND the response body lists all 5 roles (ICO, FLL, MLL, BUL, SRX)
- AND no 404 or 500 error is raised
- AND `pin_context` in the response metadata is null (no pinned version
  context)
