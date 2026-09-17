# Delta for Framework Catalog

## MODIFIED Requirements

### Requirement: Tenant-Scoped FrameworkVersion Pin

The system MUST provide a `framework_versions` table that extends the C2
`TenantModel` pattern, scoped per organization via `organization_id`. The
table MUST record: `organization_id`, a catalog `version` identifier, a
`label` (human display name, nullable), `is_locked` (bool, default false),
`revision_id` (FK to `framework_catalog_revisions`, set when the version is
resolved), and timestamps.

`FrameworkVersion` MUST resolve to a `framework_catalog_revisions` row rather
than standing alone as a flag. `is_locked` remains the one-way toggle a
project pin flips (unchanged); `revision_id` is what scoring and the
composer actually read to reach catalogue rows. A `FrameworkVersion` MUST NOT
be creatable or resolvable against a `draft` revision — only a `published`
revision may be pinned, so a pin never points at content that can still
change under it.

The composite index on `framework_versions` MUST lead with `organization_id`.
A `FrameworkVersion` record MUST become immutable once referenced by any
downstream record (project → `framework_version_id`). The system MUST NOT
permit deletion or mutation of a locked `FrameworkVersion`.

`FrameworkVersion` MUST expose a `projects()` `hasMany(Project::class)`
relation.

(Previously: `FrameworkVersion` was a bare `is_locked` flag with no reference
to what content it actually pinned; scoring read the single live catalogue
directly. This is the correctness gap D1 exists to close — an evaluation's
recorded `framework_version` is now re-derivable to exact anchor text.)

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

- GIVEN a FrameworkVersion record associated with a project
- WHEN a delete is attempted on that FrameworkVersion
- THEN the delete is rejected (constraint or guard)
- AND the FrameworkVersion record remains intact

#### Scenario: projects() relation returns pinning projects

- GIVEN FrameworkVersion FV1 is locked and two projects (P1, P2) reference it
- WHEN FV1.projects() is called
- THEN the relation returns a collection containing P1 and P2
- AND no projects from other FrameworkVersions are included

#### Scenario: A FrameworkVersion resolves to a specific revision's rows

- GIVEN FrameworkVersion FV1 has `revision_id = R1` (published)
- WHEN a scoring job or the interview composer resolves FV1's catalogue rows
- THEN it reads competencies, roles, and BARS indicators scoped to `R1` only
- AND a later published revision R2 has no effect on FV1's resolution

#### Scenario: Pinning a draft revision is rejected

- GIVEN revision R2 is still `draft`
- WHEN a project creation attempts to pin a FrameworkVersion against R2
- THEN the request is rejected — only a `published` revision may be pinned

#### Scenario: A pre-migration evaluation still resolves its exact anchor text

- GIVEN an evaluation scored before this change recorded `framework_version`
  against the pre-revision schema
- WHEN the baseline revision migration runs
- THEN that evaluation's `framework_version` resolves, via the baseline
  revision, to byte-identical anchor text as before the migration

## MODIFIED Requirements

### Requirement: Idempotent Catalog Seeder (sync delete-stale)

The system MUST provide a `FrameworkCatalogSeeder` that seeds the **baseline
revision** from the split-file JSON shape. The seeder MUST be idempotent:
running it N times against a `draft` baseline MUST produce the same database
state as running it once, using natural-key upserts and delete-stale
(`sync` for the `framework_role_competency` pivot; delete-stale for
`framework_bars_indicators` positions no longer present in the JSON).

**Revision immutability supersedes the prior per-row lock-guard (D2).** The
seeder MUST check whether the baseline revision is `published`. If it is
`draft`, full delete-stale and mutation proceeds as before. If it is
`published`, the seeder MUST perform **zero writes** — no additive insert, no
gap-row update — and MUST emit a `seeder_lock_guard_active`-equivalent
structured signal so an operator knows the run was a no-op. `framework_gaps`
and `catalog_meta` bookkeeping are unaffected by this gate (they are not
catalogue content).

(Previously: the seeder checked a platform-wide `is_locked=true` flag on any
`FrameworkVersion` and, if present, ran in a nuanced per-row ADDITIVE mode —
new rows inserted, existing rows and mutations suppressed via a per-call-site
`$model->exists` gate, with over a dozen scenarios covering pivot
preservation, stale-unassigned competencies, and new-locale suppression. That
nuance is replaced entirely: a `published` revision now accepts NO writes at
all, additive or otherwise, because immutability is enforced per-revision
rather than inferred from any FrameworkVersion being locked anywhere on the
platform.)

#### Scenario: First run seeds roles and competencies into the draft baseline

- GIVEN the JSON files competencies.json and bars/ICO.json are present
- AND the baseline revision is `draft`
- WHEN the FrameworkCatalogSeeder runs for the first time
- THEN roles and competencies matching the JSON are present, scoped to the
  baseline revision

#### Scenario: Second run against a draft baseline produces no duplicates

- GIVEN the seeder has already run once against a `draft` baseline
- WHEN the seeder runs again without any data change
- THEN row counts are identical and no duplicate rows exist

#### Scenario: Delete-stale removes a competency's pivot and indicators (draft only)

- GIVEN the baseline revision is `draft` and a role has a pivot and BARS rows
  for competency X
- WHEN X is removed from that role in the source JSON and the seeder runs
- THEN the stale pivot and BARS rows for (role, X) are deleted

#### Scenario: A published baseline accepts zero seeder writes

- GIVEN the baseline revision is `published`
- WHEN the anchor text for an existing indicator is edited in the JSON, and a
  brand-new competency is added to the JSON, and the seeder runs
- THEN NEITHER the edit NOR the new competency is written — no additive
  insert occurs
- AND the structured `seeder_lock_guard_active`-equivalent signal is emitted

#### Scenario: Seeded-count correctness — per-role BARS coverage

- GIVEN the seeder has run successfully against the complete catalogue (all
  83 declared pairs anchored) in the draft baseline
- WHEN `framework_bars_indicators` are counted per role, scoped to that
  revision
- THEN ICO has 45 rows, FLL has 54, MLL has 54, BUL has 42, SRX has 54

#### Scenario: Gap reconciliation is unaffected by revision state

- GIVEN a `framework_gaps` row for a now-anchored pair
- WHEN the seeder runs against either a draft or published baseline
- THEN the gap row is still resolved — `framework_gaps` is not catalogue
  content and is never gated by revision state
