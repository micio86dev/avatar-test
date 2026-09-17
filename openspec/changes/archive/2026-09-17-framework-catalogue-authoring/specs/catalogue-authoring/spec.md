# Catalogue Authoring Specification

## Purpose

The platform-superadmin write surface over the framework catalogue: revision
lifecycle (draft → published, immutable once published), CRUD over
competencies/roles/BARS indicators, catalogue-level default questions, the
`catalogue.manage` ability, and write-time invariant enforcement that mirrors
what `scripts/ci-guards.sh` proves over the baseline JSON trees. This surface
is platform-global, never tenant-scoped. See `framework-catalog` for how a
revision is resolved and pinned by a project, and `project-config` for how a
default question is copied into `project_questions`.

Out of scope: retargeting a live project to a newer revision (`CLAUDE.md`
ruling 3), per-tenant catalogue authoring, and deleting content referenced by
a published revision.

## Requirements

### Requirement: Catalogue Revisions Are The Snapshot A Pin Points At

A `framework_catalog_revisions` row MUST be the platform-global unit of
catalogue content. Every catalogue-content table
(`framework_roles`, `framework_competencies`, `framework_bars_indicators`,
catalogue default questions) MUST carry `revision_id`. A revision has exactly
two states: `draft` (mutable) and `published` (immutable, no exceptions,
including additive inserts — stricter than the pre-existing seeder
lock-guard). The seeder owns the **baseline** revision (`is_baseline=true`); a
superadmin write opens or continues a separate draft.

#### Scenario: A superadmin edit opens a draft revision
- GIVEN no open draft revision exists
- WHEN a superadmin edits any catalogue field
- THEN a new `draft` revision is created for the edit, leaving the baseline
  or any published revision untouched

#### Scenario: Publishing freezes every row, including future inserts
- GIVEN a draft revision with edited rows
- WHEN the superadmin publishes it
- THEN its state becomes `published`
- AND any later write to a row of that revision — update, delete, or a new
  insert — is rejected

### Requirement: Superadmin CRUD Over Competencies, Roles, And BARS Indicators

Superadmins MUST be able to create, update, reorder, and (pre-publish only)
delete competencies, roles, the `framework_role_competency` pivot, and BARS
indicators, scoped to the currently open draft revision. Creating a sixth
role MUST be rejected. Each BARS indicator write MUST enforce exactly 3
indicators per role×competency pair with anchors at levels `{5,3,1}`, at the
FormRequest and DB-constraint layer, not only at seed time.

#### Scenario: A sixth role is refused
- GIVEN five roles already exist in the open draft
- WHEN a superadmin submits a new role
- THEN the request is rejected with HTTP 422

#### Scenario: A fourth indicator for a pair is refused
- GIVEN a role×competency pair already has 3 indicators in the open draft
- WHEN a superadmin submits a fourth
- THEN the request is rejected with HTTP 422

#### Scenario: Deleting content referenced by a published revision is refused
- GIVEN a BARS indicator belongs to a published revision
- WHEN a superadmin attempts to delete it
- THEN the request is rejected with HTTP 422 — removal requires a later draft
  that omits it, published separately

### Requirement: Catalogue-Level Default Questions Per Competency

A `framework_default_questions` table MUST let a superadmin author, order,
and dual-locale (`{en,it}`) a set of default questions per competency,
scoped to the open draft revision. These are a template to copy from — never
read directly at interview time (see `project-config`).

#### Scenario: A default question is authored in both locales
- GIVEN a competency in the open draft
- WHEN a superadmin adds a default question with `en` and `it` text and a
  position
- THEN it persists and is orderable among that competency's other defaults

#### Scenario: A default missing a required locale is rejected
- WHEN a superadmin submits a default question with only `en` text
- THEN the request is rejected with HTTP 422

### Requirement: Superadmin-Only, 403 Visible In Every Action

Every catalogue-write controller action MUST repeat
`abort_unless($this->isSuperadmin($request), 403)` inline, following
`PlatformUserController`'s precedent — a shared helper hides the 403 from
Scramble's OpenAPI inference. The `catalogue.manage` ability gates backoffice
rendering only; it is never the access control.

#### Scenario: An org admin gets 403, not a hidden nav entry
- GIVEN an authenticated org `admin` who is not a platform superadmin
- WHEN they call any catalogue-write endpoint directly
- THEN the response is HTTP 403

#### Scenario: The 403 is visible in the generated OpenAPI document
- GIVEN any catalogue-write controller action
- WHEN Scramble generates `openapi.json`
- THEN that action's documented responses include 403

### Requirement: Read-Only Revision Export

A console command MUST render any revision back to the split-file JSON shape,
for human review as a diff and for deliberately refreshing the baseline
trees in a reviewed PR. It MUST NOT write to any repository file or commit.

#### Scenario: Exporting a revision never touches the repository tree
- WHEN the export command runs against a revision
- THEN it prints/returns JSON and makes no write to
  `docs/app_description/02-domain/framework/` or `api/database/framework/`

#### Scenario: An exported published revision matches its stored rows exactly
- GIVEN a published revision
- WHEN it is exported
- THEN the resulting JSON's role×competency×indicator content matches the
  stored rows byte-for-byte
