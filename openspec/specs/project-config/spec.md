# Project Configuration Specification

## Purpose

Defines the org-scoped `Project` entity, the framework-version reference-pin,
assessment-type/role/competency invariants, RBAC-gated CRUD API, and the
status lifecycle. This is a correctness-critical slice (cross-tenant isolation,
type invariants, pin lock) — coverage target ~95%.

---

## Requirements

### Requirement: Org-Scoped Project Entity

The system MUST provide a `projects` table that extends the C2 `TenantModel`
pattern, scoped per organization via `organization_id`. `organization_id` MUST
be stamped on creation and MUST NOT be user-fillable (not in `$fillable`).

The table MUST record: `name` (string, required), `slug` (string, unique per
org), `assessment_type` (enum: `standard` | `potential`), `role_code` (nullable
string, constrained by invariants), `framework_version_id` (FK to
`framework_versions`, set on create), `language` (enum including `it` and `en`),
`pause_every_n_competencies` (nullable int), `nudge_min_chars` (nullable int),
`exit_redirect_url` (nullable string), `webhook_url` (nullable string),
`webhook_secret` (nullable string), `status` (enum: `draft` | `active` |
`archived`), `goes_live_at` (nullable datetime), `deadline_at` (nullable
datetime), and timestamps.

A `project_competencies` normalized pivot table MUST exist with columns
`project_id`, `competency_id`, and `position` (int). Composite indexes on `projects`
MUST lead with `organization_id` per D22. `project_competencies` is EXEMPT from D22's
`organization_id`-first requirement because it is accessed only through the tenant-scoped
`Project` parent relationship — see the design for the explicit rationale.

#### Scenario: Project created with organization_id stamp

- GIVEN an authenticated admin in org A
- WHEN POST /api/projects is called with valid payload
- THEN a Project row is created with `organization_id` equal to org A's id
- AND the returned resource reflects `organization_id` from auth context, not from the request body

#### Scenario: Slug is unique per org but may repeat across orgs

- GIVEN org A already has a project with slug "q4-assessment"
- WHEN org A attempts to create another project with slug "q4-assessment"
- THEN the response is HTTP 422 with a slug uniqueness error
- WHEN org B creates a project with slug "q4-assessment"
- THEN the response is HTTP 201 (different org, no conflict)

#### Scenario: organization_id is not fillable

- GIVEN an attacker sends a POST /api/projects payload containing `organization_id` of org B
- WHEN the request is processed
- THEN the created project has `organization_id` equal to the authenticated user's org, not org B

---

### Requirement: Framework-Version Reference-Pin

When a project is created, the system MUST set `framework_version_id` to the
specified `FrameworkVersion` belonging to the same organization. On creation,
the system MUST flip `FrameworkVersion.is_locked` from `false` to `true` if it
is currently `false`. Multiple projects MAY share one `FrameworkVersion`; the
lock is a one-way toggle — once `is_locked=true`, it stays `true`. Only a
superadmin MAY reset `is_locked=false` (escape hatch; out of normal API scope).

Once a `FrameworkVersion` is locked (`is_locked=true`), the C3 immutability
guard MUST reject any update or delete of that record.

#### Scenario: Creating first project pins and locks the FrameworkVersion

- GIVEN org A has FrameworkVersion FV1 with `is_locked=false`
- WHEN POST /api/projects is called referencing FV1
- THEN the project is created with `framework_version_id = FV1.id`
- AND FV1.`is_locked` is now `true`

#### Scenario: Second project reusing a locked FrameworkVersion succeeds

- GIVEN FV1 is already locked (`is_locked=true`) from a prior project
- WHEN POST /api/projects is called referencing FV1
- THEN the project is created successfully (HTTP 201)
- AND FV1.`is_locked` remains `true` (no double-flip error)

#### Scenario: Attempt to update a locked FrameworkVersion is blocked

- GIVEN FV1 is locked (`is_locked=true`)
- WHEN PATCH /api/framework/versions/{FV1.id} is attempted
- THEN the response is HTTP 422 or HTTP 403 (immutability guard)
- AND FV1 is unchanged

#### Scenario: Attempt to delete a locked FrameworkVersion is blocked

- GIVEN FV1 is locked and referenced by at least one project
- WHEN DELETE /api/framework/versions/{FV1.id} is attempted
- THEN the response is HTTP 422 or HTTP 403
- AND FV1 remains in the database

#### Scenario: Cross-org pin rejection — cannot pin another org's FrameworkVersion

- GIVEN org A's user attempts to create a project referencing FV owned by org B
- WHEN POST /api/projects is called
- THEN the response is HTTP 422 (FV not found in org scope)
- AND no project is created and no lock is flipped

---

### Requirement: assessment_type Invariants

Assessment type MUST be one of `standard` or `potential`. The invariants
below MUST be enforced at both the FormRequest validation layer and the
model guard layer.

**standard** invariants:
- `role_code` MUST be present and MUST be one of `{ICO, FLL, MLL, BUL, SRX}`.
- All competencies in `project_competencies` MUST have `type = 'standard'`.
- Every competency in `project_competencies` MUST exist in
  `framework_role_competency` for the given `role_code` (subset constraint).
- No `type = 'potential'` competency MAY appear.

**potential** invariants:
- `role_code` MUST be `null`.
- All competencies in `project_competencies` MUST have `type = 'potential'`
  and their code MUST be in `{MTG, LAT}`.
- No `type = 'standard'` competency MAY appear.

Mixing `standard` and `potential` competencies in a single project MUST be
rejected (HTTP 422).

Selecting or deselecting a competency, at any point the set is still
mutable, MUST trigger the catalogue-defaults auto-fill and
soft-delete/restore lifecycle described above; this applies uniformly to
`standard` and `potential` competency selection.

(Previously: silent on any question-related side effect of competency
selection — `project_questions` did not exist as a specified concept.)

#### Scenario: Valid standard project with correct role and subset

- GIVEN role_code = "ICO" and all competencies in `project_competencies` are
  standard and in ICO's framework_role_competency rows
- WHEN POST /api/projects is called
- THEN the response is HTTP 201

#### Scenario: standard project with invalid role_code is rejected

- GIVEN assessment_type = "standard" and role_code = "INVALID"
- WHEN POST /api/projects is called
- THEN the response is HTTP 422 with an error on `role_code`

#### Scenario: Valid potential project with MTG and LAT

- GIVEN assessment_type = "potential", role_code = null, competencies =
  [MTG, LAT] (both seeded)
- WHEN POST /api/projects is called
- THEN the response is HTTP 201

#### Scenario: Selecting a competency on project creation auto-fills its defaults

- GIVEN competency PRS has 1 catalogue default question
- WHEN POST /api/projects is called with PRS in the competency set
- THEN the created project has 1 `project_questions` row for PRS, copied
  from the default
### Requirement: potential Catalog Prerequisite Guard

When creating a `potential` project, the system MUST verify that BOTH MTG and
LAT competencies are seeded in the catalog by checking
`Competency::whereIn('code', ['MTG', 'LAT'])->count() < 2`. A partial catalog
(only MTG seeded, or only LAT, or neither) MUST be treated as incomplete. If
either is absent, the system MUST return HTTP 422 with error code
`POTENTIAL_CATALOG_INCOMPLETE`. The check MUST use a code-based lookup
(`whereIn('code', ['MTG', 'LAT'])`) — NOT a type-count check
(`where('type', 'potential')`), which cannot distinguish which specific codes
are present and would incorrectly pass if a different `type='potential'` code
were seeded instead.

This catalog-prerequisite check MUST run BEFORE the competency-subset cross-field
validation. A missing catalog returns the specific `POTENTIAL_CATALOG_INCOMPLETE` error
rather than a generic subset-mismatch error, so clients can distinguish "catalog not
ready" from "competency subset invalid".

**HTTP 422 response shape for `POTENTIAL_CATALOG_INCOMPLETE`:**
```json
{
  "message": "Potential catalog incomplete: MTG/LAT competencies are not seeded.",
  "code": "POTENTIAL_CATALOG_INCOMPLETE"
}
```
This follows the `{"message": "..."}` JSON envelope established in C2/C3, extended with a `"code"`
field for machine-readable error discrimination. API clients MUST check the `"code"` field to
distinguish this error from other 422 validation errors.

#### Scenario: potential project blocked when MTG/LAT not in catalog

- GIVEN neither MTG nor LAT exists in `framework_competencies`
- WHEN POST /api/projects is called with assessment_type = "potential"
- THEN the response is HTTP 422
- AND the response body is `{"message": "...", "code": "POTENTIAL_CATALOG_INCOMPLETE"}`
- AND no project is created

#### Scenario: potential project blocked when only one of MTG/LAT is seeded (partial catalog)

- GIVEN only MTG exists in `framework_competencies` (LAT is absent)
- WHEN POST /api/projects is called with assessment_type = "potential"
- THEN the response is HTTP 422 with code `POTENTIAL_CATALOG_INCOMPLETE`
- AND no project is created
- (A partial catalog — only one of the two required codes — is treated as incomplete)

#### Scenario: potential project succeeds when MTG and LAT are seeded

- GIVEN both MTG and LAT exist in `framework_competencies` with type='potential'
- WHEN POST /api/projects is called with assessment_type = "potential"
- THEN the response is HTTP 201

---

### Requirement: assessment_type and Immutable-Field Enforcement

`framework_version_id` is set at project creation and is IMMUTABLE THEREAFTER. Any PATCH request
that includes `framework_version_id` — regardless of project status (draft or active), and regardless
of whether the submitted value equals the current pin — MUST be rejected with HTTP 422. This field is
blanket-prohibited in all PATCH requests. It is set only at creation via `StoreProjectRequest`
(which still applies org-scoped `Rule::exists` at create time — that validation is unchanged).

Once a project reaches `status = 'active'` OR `status = 'archived'` (either already in that status,
or being set to that status in the same request), `assessment_type` and `role_code` MUST be immutable.
Any attempt to CHANGE these fields (submit a value different from the persisted value) when the
resulting project status is `active` or `archived` MUST be rejected with HTTP 422. Submitting the
SAME value as already persisted is NOT a change and MUST be accepted. The check MUST key off the
FINAL intended state: a single PATCH that simultaneously sets `status = 'active'` and changes an
immutable field MUST be rejected.

Enforcement is at the `UpdateProjectRequest` layer (primary — uses value-comparison, not key-presence)
and the model's `updating` guard (backstop for non-HTTP paths, uses `isDirty()`). Both layers agree:
an unchanged value is not flagged by either. The model guard MUST throw a domain exception
(`ImmutableProjectException`) that renders as HTTP 422, NOT a bare `RuntimeException` (which would
yield HTTP 500).

**`framework_version_id` integer cast (required):** `Project.$casts` MUST include
`'framework_version_id' => 'integer'`. Without this cast, `pdo_pgsql` returns the bigint column as
a PHP string, which would cause `isDirty()` false-positives in the model guard. The FormRequest no
longer has a value-comparison for FV (it is blanket-prohibited), but the cast must remain to ensure
correct model behavior.

**Slug uniqueness on update:** `UpdateProjectRequest` MUST validate slug uniqueness using a
self-ignoring, soft-delete-aware rule:
`Rule::unique('projects','slug')->where('organization_id',...)->whereNull('deleted_at')->ignore($project->id)`.
A PATCH that sends the project's own existing slug MUST NOT be rejected. `StoreProjectRequest` uses
the non-ignore org-scoped unique rule, also with `->whereNull('deleted_at')`.

**Slug soft-delete policy:** A slug belonging to a soft-deleted project IS reusable. The uniqueness
check on BOTH Store and Update MUST exclude soft-deleted rows (`->whereNull('deleted_at')`). Once a
project is soft-deleted, its slug is logically retired from the active namespace; a new or updated
project in the same org MAY claim that slug.

The status lifecycle MUST also be enforced: `draft → active → archived` is the only valid forward
path. Reverse transitions (`active → draft`, `archived → active`, `archived → draft`) MUST be
rejected with HTTP 422. This applies at both the FormRequest layer and the model guard.

#### Scenario: assessment_type change on already-active project is rejected

- GIVEN a project with status = "active" and assessment_type = "standard"
- WHEN PATCH /api/projects/{id} is called with assessment_type = "potential"
- THEN the response is HTTP 422 with an immutability error on `assessment_type`
- AND the project's assessment_type remains "standard"

#### Scenario: Simultaneous status=active + immutable field change is rejected

- GIVEN a project with status = "draft" and assessment_type = "standard"
- WHEN PATCH /api/projects/{id} is called with BOTH status = "active" AND assessment_type = "potential"
- THEN the response is HTTP 422 (the resulting status is active; immutable field cannot change)
- AND the project's status remains "draft" and assessment_type remains "standard"

#### Scenario: assessment_type change on draft project is accepted

- GIVEN a project with status = "draft"
- WHEN PATCH /api/projects/{id} is called with a different assessment_type (and valid invariants)
- THEN the response is HTTP 200 and the type is updated

#### Scenario: PATCH with unchanged immutable field value on active project is accepted

- GIVEN a project with status = "active", assessment_type = "standard", role_code = "ICO"
- WHEN PATCH /api/projects/{id} is called with BOTH status = "active" AND role_code = "ICO" (same value, no change)
- THEN the response is HTTP 200 (same value is not a change; immutability gate does not fire)

#### Scenario: Direct model update (non-HTTP) triggers guard with 422-equivalent exception

- GIVEN a project with status = "active"
- WHEN $project->assessment_type = "potential"; $project->save() is called directly (e.g. in a test or job)
- THEN an ImmutableProjectException is thrown (not RuntimeException)
- AND the exception renders as HTTP 422 when surfaced via the API

#### Scenario: Slug PATCH with same slug is accepted (self-ignore)

- GIVEN a project with slug = "q4-assessment"
- WHEN PATCH /api/projects/{id} is called with slug = "q4-assessment" (same value)
- THEN the response is HTTP 200 (self-ignore unique rule; no false uniqueness rejection)

#### Scenario: Slug PATCH with another project's slug is rejected

- GIVEN org A has project P1 with slug "q4-assessment" and project P2 with slug "summer-eval"
- WHEN PATCH /api/projects/{P2.id} is called with slug = "q4-assessment"
- THEN the response is HTTP 422 with a slug uniqueness error

#### Scenario: Slug from a soft-deleted project is reusable

- GIVEN org A had project P1 with slug "q4-assessment" and P1 has been soft-deleted
- WHEN POST /api/projects is called with slug = "q4-assessment" in org A
- THEN the response is HTTP 201 (soft-deleted row is excluded from uniqueness check)
- AND the new project carries slug "q4-assessment"

#### Scenario: PATCH with framework_version_id is always rejected (immutable from creation)

- GIVEN any project P1 in any status (draft or active)
- WHEN PATCH /api/projects/{P1.id} is called with framework_version_id set to ANY value
  (even the same value as the current pin, even a valid same-org FV)
- THEN the response is HTTP 422 (framework_version_id is prohibited in all PATCH requests)
- AND the project's framework_version_id is unchanged
- (framework_version_id is set only at creation via StoreProjectRequest; UpdateProjectRequest
  uses the 'prohibited' rule when the field is present — no org-scoped Rule::exists is needed
  because the field is rejected before any existence check)

#### Scenario: POST (create) with framework_version_id from another org is rejected (org-scoped FV validation)

- GIVEN org A's user attempts to create a project referencing FV owned by org B
- WHEN POST /api/projects is called with framework_version_id = FV_B.id
- THEN the response is HTTP 422 (FV not found in org A scope — org-scoped Rule::exists fires)
- AND no project is created and no lock is flipped
- (StoreProjectRequest still enforces org-scoped Rule::exists for framework_version_id at creation)

---

### Requirement: CRUD API — Projects Resource

The system MUST expose the following endpoints behind `auth:api` middleware
(C2) and `TenantContext`:

- `GET /api/projects` — list all projects for the authenticated org
- `POST /api/projects` — create a project
- `GET /api/projects/{id}` — get a single project (org-scoped)
- `PATCH /api/projects/{id}` — update a project (subject to immutability guards)
- `DELETE /api/projects/{id}` — delete a project

Additionally, `GET /api/framework/versions` MUST list the `FrameworkVersion`
records available to the org (for use when pinning on create).

All endpoints MUST enforce cross-tenant isolation: an org-A user MUST receive
HTTP 404 for any project or FrameworkVersion belonging to org B.

#### Scenario: Listing projects returns only own-org records

- GIVEN org A has 3 projects and org B has 2 projects
- WHEN org A's user calls GET /api/projects
- THEN the response lists exactly 3 projects (all org A's)
- AND no org B project appears

#### Scenario: Cross-tenant GET /api/projects/{id} returns 404

- GIVEN project P belongs to org B
- WHEN org A's user calls GET /api/projects/{P.id}
- THEN the response is HTTP 404

#### Scenario: Cross-tenant PATCH returns 404

- GIVEN project P belongs to org B
- WHEN org A's user calls PATCH /api/projects/{P.id}
- THEN the response is HTTP 404

#### Scenario: Cross-tenant DELETE returns 404

- GIVEN project P belongs to org B
- WHEN org A's user calls DELETE /api/projects/{P.id}
- THEN the response is HTTP 404

#### Scenario: GET /api/framework/versions lists only own-org versions

- GIVEN org A has 2 FrameworkVersions and org B has 1
- WHEN org A's user calls GET /api/framework/versions
- THEN the response lists exactly 2 versions (org A's)

---

### Requirement: RBAC Gates

RBAC MUST be enforced via Spatie/laravel-permission in teams mode, scoped
per organization. The permitted operations per role are:

| Role | Projects | Notes |
|------|----------|-------|
| admin | full CRUD | all org projects |
| operator | full CRUD | all org projects (no owner_id filter) |
| viewer | read-only (GET) | 403 on POST/PATCH/DELETE |

#### Scenario: viewer cannot create a project

- GIVEN a user with role "viewer" in org A
- WHEN POST /api/projects is called
- THEN the response is HTTP 403

#### Scenario: operator can create and update any org project

- GIVEN a user with role "operator" in org A
- WHEN POST /api/projects is called with valid payload
- THEN the response is HTTP 201
- WHEN PATCH /api/projects/{id} is called on any org A project
- THEN the response is HTTP 200

#### Scenario: admin has full CRUD

- GIVEN a user with role "admin" in org A
- WHEN DELETE /api/projects/{id} is called on an org A project
- THEN the response is HTTP 204 No Content (soft-delete)

#### Scenario: viewer can read projects

- GIVEN a user with role "viewer" in org A
- WHEN GET /api/projects is called
- THEN the response is HTTP 200

---

### Requirement: Project Status Lifecycle

Project status MUST follow the lifecycle: `draft` → `active` → `archived`.
Reverse transitions (e.g., `active` → `draft`, `archived` → `active`) MUST be
rejected with HTTP 422. `goes_live_at` and `deadline_at` are stored config
fields; scheduled behavior based on these timestamps is OUT OF SCOPE.

#### Scenario: draft → active transition is valid

- GIVEN a project with status = "draft"
- WHEN PATCH /api/projects/{id} is called with status = "active"
- THEN the response is HTTP 200 and status is now "active"

#### Scenario: active → archived transition is valid

- GIVEN a project with status = "active"
- WHEN PATCH /api/projects/{id} is called with status = "archived"
- THEN the response is HTTP 200 and status is now "archived"

#### Scenario: active → draft reverse transition is rejected

- GIVEN a project with status = "active"
- WHEN PATCH /api/projects/{id} is called with status = "draft"
- THEN the response is HTTP 422 with a lifecycle error

#### Scenario: archived → active reverse transition is rejected

- GIVEN a project with status = "archived"
- WHEN PATCH /api/projects/{id} is called with status = "active"
- THEN the response is HTTP 422 with a lifecycle error

#### Scenario: archived → draft reverse transition is rejected

- GIVEN a project with status = "archived"
- WHEN PATCH /api/projects/{id} is called with status = "draft"
- THEN the response is HTTP 422 with a lifecycle error

---

## Non-Goals (Explicit)

The following are OUT OF SCOPE for C4 and MUST NOT be implemented here:

- **Candidate/SSO ingress** — C6 wires candidates to projects; candidate lifecycle is not part of C4
- **M2M auth / API-key management** — C5
- **Webhook delivery, HMAC signing, retry/backoff** — C10 (C4 only stores `webhook_url` and `webhook_secret`)
- **Interview and conversation engine** — C7/C8
- **Scoring, 90%-gate, BARS evaluation** — C9
- **Backoffice UI** — C11
- **MTG/LAT competency authoring** — C3 gap; C4 reads catalog as-is
- **Data-copy snapshot (Option B)** — C13; C4 uses reference-pin, not copy tables
- **Deadline / goes_live_at scheduled jobs** — C12/C13; C4 stores the timestamps only
- **Superadmin is_locked reset API** — escape hatch documented but out of normal API scope

---

## ADDED Requirements (C10)

### Requirement: webhook_events — enabled event types per project (C10 addendum)

The `projects` table MUST gain a `webhook_events` column: NOT NULL, persisting the set
of enabled webhook event types for that project, drawn from the closed enum
`{progress, evaluation}`. Verified absent today: no `webhook_events`/`enabled_events`/
`event_types` column exists in any migration under `api/database/migrations/` (only
`webhook_url` and `webhook_secret` exist,
`2026_07_17_200001_create_projects_table.php:44-45`).

The column MUST default to BOTH event types enabled, for both existing rows (via the
migration's default) and newly created projects. Rationale: C10 is the first webhook
delivery implementation ever shipped (verified: no outbound delivery code exists in
`api/app` prior to this change) — there is no prior delivery history to preserve, so a
project that has a `webhook_url` configured at all is presumed to want both events per
the binding contract (`docs/app_description/04-integration-surface/03-webhook-events.md`).

`StoreProjectRequest` and `UpdateProjectRequest` MUST validate any submitted
`webhook_events` value against the closed `{progress, evaluation}` set — an unknown
value MUST be rejected with HTTP 422. `ProjectResource` MUST expose `webhook_events` in
API responses (the field is not sensitive — unlike `webhook_secret`, which remains
excluded).

#### Scenario: Existing and new projects default to both event types enabled

- GIVEN a project row created before this migration, and a project created after it via `POST /api/projects` with no `webhook_events` in the payload
- WHEN either row is inspected
- THEN `webhook_events` is NOT NULL and contains both `progress` and `evaluation`

#### Scenario: Unknown event type rejected at validation

- GIVEN a `POST /api/projects` or `PATCH /api/projects/{id}` request with `webhook_events` containing an unrecognized value (e.g. `"unknown_event"`)
- WHEN the request is validated
- THEN the response is HTTP 422 and no project is created/updated with the invalid value

#### Scenario: webhook_events exposed in API response, webhook_secret still excluded

- GIVEN a project with `webhook_events = ['progress']` and a configured `webhook_secret`
- WHEN `GET /api/projects/{id}` is called
- THEN the response body contains `webhook_events: ['progress']`
- AND the response body contains NO `webhook_secret` field (unchanged from existing behavior)

#### Scenario: PATCH narrows the enabled event set

- GIVEN a project with `webhook_events = ['progress', 'evaluation']`
- WHEN `PATCH /api/projects/{id}` is called with `webhook_events = ['evaluation']`
- THEN the response is HTTP 200 and the project's `webhook_events` is now `['evaluation']` only

---

## ADDED Requirements (C15)

### Requirement: Projects carry a configurable error redirect URL

A `Project` MUST accept an optional `error_redirect_url`, validated on the same
terms as `exit_redirect_url`: nullable, a well-formed URL, at most 2048
characters.

It MUST be exposed on the candidate session resource, because the party that
needs it is the browser recovering from a failed interview, and that browser has
only a candidate token.

Per-project, never global. The binding integration doc states the return URL is
"configurabile per progetto (non globale unico)", and an error destination has
no reason to be more centralised than a success one — different clients route
failures to different places.

#### Scenario: A project accepts an error redirect URL

- WHEN a project is created or updated with a valid `error_redirect_url`
- THEN it is persisted and returned on subsequent reads

#### Scenario: A malformed error redirect URL is rejected

- WHEN a project is submitted with an `error_redirect_url` that is not a URL
- THEN validation fails with HTTP 422

#### Scenario: The field is optional

- WHEN a project is created without `error_redirect_url`
- THEN it persists as null and the interview keeps its current inline behaviour

Absence is a supported configuration, not a missing setting: a client that wants
BEAI to handle its own failures is making a legitimate choice.
### Requirement: Project Questions Layer

A `project_questions` table MUST exist, org+project scoped, with:
`competency_id` (FK `restrictOnDelete`), `text` (JSON locale map `{en,it}`),
`position` (int), soft deletes, and a partial unique index on
`(project_id, competency_id, position) WHERE deleted_at IS NULL`. CRUD is
exposed via index/store/update/reorder/destroy endpoints, RBAC-gated
identically to the `projects` resource.

The per-competency count MUST be validated against
`PlatformSettings::maxQuestionsPerCompetency()` (default
`{standard: 1, potential: 4}`) as a **maximum only** — zero questions for a
competency is always legal, at any assessment type.

#### Scenario: A potential project is savable with zero questions for a competency

- GIVEN a `potential` project competency with zero `project_questions` rows
- WHEN the project is saved
- THEN the save succeeds — zero is legal, the cap is a ceiling not a floor

#### Scenario: Exceeding the cap is rejected

- GIVEN a `potential` competency already has 4 questions (the default max)
- WHEN a 5th is submitted
- THEN the request is rejected with HTTP 422

### Requirement: Catalogue Defaults Auto-Fill On Competency Selection

Every time an operator selects competencies on a project — at creation or on
a later update, while the competency set is still mutable — the system MUST
copy the catalogue's default questions (see `catalogue-authoring`) for each
**newly selected** competency into `project_questions`, in the defaults'
authored order. A competency already carrying `project_questions` rows
(including soft-deleted, restorable rows — see below) MUST NOT be re-copied.
A catalogue default whose competency is outside the project's competency set
is never copied.

#### Scenario: Selecting a new competency copies its defaults

- GIVEN competency COL has 2 catalogue default questions
- WHEN an operator adds COL to a project's competency set
- THEN 2 `project_questions` rows are created for COL, matching the
  defaults' text and order

#### Scenario: A competency with no catalogue defaults yields zero rows

- GIVEN competency STG has zero catalogue default questions
- WHEN STG is selected on a project
- THEN zero `project_questions` rows are created for STG — this is not an
  error

#### Scenario: Re-saving an unchanged competency set does not duplicate rows

- GIVEN a project already has COL selected with its defaults copied
- WHEN the project is saved again with the same competency set
- THEN no additional `project_questions` rows are created for COL

### Requirement: A Catalogue Default Is Copied As A Snapshot; It Never Propagates

**RATIFIED by the product owner:** "in quel caso restano ferme le domande
sui progetti, non si aggiornano."

When a catalogue default question is copied into `project_questions` (on
competency selection — see above), that copy is a SNAPSHOT, frozen at the
moment of copy. A LATER edit to the catalogue default MUST NOT reach any
project that already has a copy — not an operator-modified row, and not an
untouched one either. A catalogue edit affects only projects that select
that competency AFTER the edit; every project that already selected it
keeps exactly the text it received at copy time, forever.

This is the SAME principle `CLAUDE.md` ruling 3 already ratifies for
`framework_version`: pinned at project creation, never retargeted by a later
catalogue revision. The copy made at competency selection is that same kind
of pin, at the question level instead of the anchor level, and a snapshot
that silently changes underneath a configured project is exactly what
ruling 3 exists to prevent. One rule now governs every catalogue write: it
never reaches a project that already exists.

**This has no propagation mechanism, by design — not a deferred one.**
There is no "find the untouched copies" query at edit time, no background
job, and no ordering hazard between a superadmin catalogue edit and a
concurrent project configuration, because a catalogue edit never writes to
`project_questions` at all. Editing a default is scoped entirely to the
catalogue's own draft revision (see `catalogue-authoring`); it has no
side-effect on any project.

The provenance flag introduced by this requirement's sibling copy-tracking
still exists, but it carries exactly two jobs, both already specified above:
(1) the auto-fill rule never overwrites a row flagged operator-modified, and
(2) restoring a deselected-then-reselected competency returns the operator's
own rewritten row, never a fresh default. Provenance carries NEITHER
propagation NOR a "should this follow the catalogue" decision — there is no
third job, because there is nothing left for a flag to gate once the
catalogue never reaches back into a project's copies at all.

#### Scenario: An untouched copy does not change when the catalogue default changes

- GIVEN a project's copy of a default has never been edited by an operator
- WHEN the superadmin later changes that default's text in the catalogue
- THEN the project's copy keeps the text it had at copy time, unchanged —
  no read, write, or comparison against the project's copy occurs as a
  result of the catalogue edit

#### Scenario: An operator-modified copy is equally unaffected

- GIVEN a project's copy of a default has been rewritten by an operator
- WHEN the superadmin later changes that same default's text in the
  catalogue
- THEN the project's copy still keeps the operator's rewritten text —
  provenance state does not change which projects a catalogue edit reaches;
  it reaches none

#### Scenario: A catalogue edit reaches only projects that select the competency afterward

- GIVEN a superadmin edits a competency's default question text
- WHEN a DIFFERENT project selects that competency for the first time,
  AFTER the edit
- THEN that project's new copy carries the edited text — the edit is
  visible only to selections made after it, never to selections made before

#### Scenario: The first operator edit sets the provenance flag

- GIVEN an untouched copy of a catalogue default
- WHEN an operator edits its text
- THEN the row's provenance flag is now "operator-modified"

### Requirement: Deselecting A Competency Soft-Deletes Its Questions; Reselecting Restores Them

Deselecting a competency MUST soft-delete its `project_questions` rows.
Reselecting the SAME competency later MUST restore exactly those rows —
including their provenance flag and any operator-rewritten text — and MUST
NOT re-copy the catalogue defaults over them.

#### Scenario: Reselection restores the operator's own edited text

- GIVEN a competency's questions were operator-edited, then the competency
  was deselected (soft-deleted)
- WHEN the operator reselects that competency
- THEN the same rows are restored with the operator's edited text — the
  catalogue defaults are NOT copied again

#### Scenario: Reselection restores an untouched copy without re-copying

- GIVEN a competency's questions were never edited, then deselected
- WHEN the operator reselects that competency
- THEN the same (untouched) rows are restored, not a fresh copy of the
  current catalogue defaults

### Requirement: Automation Never Overwrites An Operator-Modified Row

No automated write path — auto-fill on selection, or restore on
reselection — MAY overwrite a `project_questions` row whose provenance flag
indicates operator modification.

#### Scenario: Restore never re-copies over an operator-modified row

- GIVEN a restored row's provenance flag is "operator-modified"
- WHEN the same reselection event runs
- THEN the row's text is exactly what the operator last saved — never
  replaced by the catalogue default's current text

### Requirement: A Single Interviewability Predicate Gates Every Interview Entry Point

**RATIFIED by the product owner:** "tramite SSO bisogna applicare la stessa
logica, l'utente non può fare interviste su progetti che non sono in stato
completato di configurazione con almeno 1 domanda per ogni competenza."

A project IS INTERVIEWABLE only while every currently selected competency
has at least one LIVE (non-soft-deleted) `project_questions` row. This is a
property of the PROJECT, defined exactly once (e.g. `Project::isInterviewable()`
or an equivalent single service), and EVERY route capable of starting or
continuing an interview MUST consume that one definition — none may
reimplement its own check. Three independent checks that must agree is
three things that drift: this repo has already paid for that shape twice
(`AGENTS.md` living as a copy of `CLAUDE.md` instead of a symlink, and a
guard asserting an indicator count that disagreed with the spec and the
data). This requirement exists precisely so a fourth instance of that shape
does not ship.

The predicate is evaluated against current soft-delete state: a competency
deselected (its rows soft-deleted) is no longer a SELECTED competency and is
out of scope for the check entirely; only currently-selected competencies
with zero live rows make a project non-interviewable.

**Every entry point MUST consume the predicate:**

| Entry point | Route | Audience | Refusal behavior |
|---|---|---|---|
| Entry-link mint | `POST /api/entry-links`, `EntryLinkController::store` | Operator (authenticated, backoffice) | HTTP 422, machine-readable code `PROJECT_NOT_INTERVIEWABLE` — reaches someone who can fix it |
| SSO exchange | `GET /api/sso/exchange`, `SsoExchangeController::exchange` | Candidate (public, unauthenticated) | Refused **at the moment of exchange**, never a raw error — the candidate is redirected to the project's configured `error_redirect_url`, since they cannot fix a configuration problem |
| M2M enrolment | `POST /api/m2m/participants` and `POST /api/m2m/sso-link`, `App\Http\Controllers\M2m\ParticipantController::store` / `SsoLinkController::store` | Calling system (M2M API-key) | HTTP 422, machine-readable code `PROJECT_NOT_INTERVIEWABLE` — the earliest point the calling system can be told, strictly kinder than failing at the candidate's door |

**Timing — the check belongs at the moment of use, not only at mint.** A
project can become non-interviewable AFTER an entry link is minted or an SSO
token is issued but BEFORE the candidate arrives (a competency was
deselected, or its last live question was removed). Mint-time and use-time
are DISTINCT evaluations of the same predicate: minting an entry link or an
SSO token MUST check interviewability at that moment, and the SSO exchange
and any `/start` call for a competency not yet begun MUST check it again at
the moment of use — a token minted while interviewable is not a permanent
exemption.

**In-flight sessions are protected, not severed.** Once a competency
session has reached `in_corso`, a LATER configuration change that makes the
project non-interviewable MUST NOT retroactively fail, pause, or terminate
that session. The predicate gates the START of a new attempt (a fresh
`/start` for a competency with no prior session), never a session already
running. This choice is deliberate: a candidate mid-interview has no way to
know the operator changed the project underneath them, and severing them
converts a configuration mistake into a data-loss incident for a candidate
who did nothing wrong.

#### Scenario: Entry-link mint is refused for a non-interviewable project

- GIVEN a project with competencies [PRS, COL] selected, PRS has 1 live
  question, COL has zero live questions
- WHEN `POST /api/entry-links` is called for that project
- THEN the response is HTTP 422 with code `PROJECT_NOT_INTERVIEWABLE`
- AND no entry link is minted

#### Scenario: SSO exchange is refused for a non-interviewable project and routes to the error redirect

- GIVEN a project is non-interviewable and has a configured `error_redirect_url`
- WHEN a candidate's `GET /api/sso/exchange` request resolves to that project
- THEN the candidate is redirected to `error_redirect_url`, never shown a raw
  error page
- AND no `InterviewSession` or participant progress is created

#### Scenario: M2M enrolment is refused at the API boundary, before any candidate exists

- GIVEN a project is non-interviewable
- WHEN a calling system calls `POST /api/m2m/participants` (or subsequently
  `POST /api/m2m/sso-link`) for that project
- THEN the response is HTTP 422 with code `PROJECT_NOT_INTERVIEWABLE`
- AND no participant row and no SSO link are created — the calling system
  learns this before any candidate is ever invited

#### Scenario: A project that becomes non-interviewable after mint is still refused at use

- GIVEN an entry link (or SSO token) was minted while the project was
  interviewable
- AND the operator subsequently deselects a competency, or deletes its last
  live question, making the project non-interviewable
- WHEN the candidate then uses that link/token
- THEN the use-time check refuses it exactly as if it had never been
  interviewable — the mint-time check is not treated as a standing exemption

#### Scenario: An already in_corso participant is not severed by a later configuration change

- GIVEN a candidate has an `in_corso` competency session already underway
- WHEN the operator makes the project non-interviewable (deselects another
  competency, or empties a different competency's questions)
- THEN the candidate's already-running session continues uninterrupted
- AND the predicate only blocks a NEW session start, not the one in progress

#### Scenario: Once a participant has any session on the project, a later competency's own emptying gates only itself

**Interpretation decided (Z9, framework-catalogue-authoring, REQUIRED BEFORE
ARCHIVE):** the WHOLE-PROJECT gate (every currently-selected competency has
a live question) applies only at a participant's TRUE first `/start` — no
`InterviewSession` exists anywhere on the project for that participant yet.
Once at least one session exists (mid-interview), each competency's OWN
fresh start is gated only by ITS OWN live-question state, never by the rest
of the project. The alternative — re-checking the whole project on every
competency transition — was tried and rejected: it would strand a candidate
who already finished competency 1 and is moving to competency 2 solely
because competency 5, not yet reached, later lost its only question.

- GIVEN a candidate already has an `InterviewSession` for competency PRS on
  a project selecting [PRS, COL, SLF]
- AND the operator later empties competency SLF's questions (SLF has not
  been reached yet), making the PROJECT as a whole non-interviewable
- WHEN the candidate finishes PRS and starts a fresh session for COL, which
  still has a live question
- THEN the COL start succeeds — COL's own live-question state is satisfied,
  and SLF's emptied state does not block it
- AND only when the candidate later reaches SLF does its own fresh start
  refuse with `PROJECT_NOT_INTERVIEWABLE`

#### Scenario: Minting succeeds once the project is interviewable

- GIVEN the same project, with a question then added back to COL
- WHEN `POST /api/entry-links` is called again
- THEN the response is HTTP 201 and an entry link is minted

#### Scenario: A deselected competency's soft-deleted questions do not count against interviewability

- GIVEN a project previously had competency STG selected with questions,
  then STG was deselected (its rows soft-deleted) and is no longer in the
  project's competency set
- WHEN interviewability is evaluated for any of the three entry points
- THEN STG's soft-deleted rows are not evaluated at all — only currently
  selected competencies are checked

#### Scenario: Interviewability reflects soft-delete state, not raw row count

- GIVEN a competency has 2 `project_questions` rows, both soft-deleted, and
  the competency is still selected on the project
- WHEN the predicate is evaluated
- THEN the competency counts as having zero LIVE questions, and the project
  is non-interviewable

