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
below MUST be enforced at both the FormRequest validation layer and the model
guard layer.

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

#### Scenario: Valid standard project with correct role and subset

- GIVEN role_code = "ICO" and all competencies in `project_competencies` are standard and in ICO's framework_role_competency rows
- WHEN POST /api/projects is called
- THEN the response is HTTP 201

#### Scenario: standard project with invalid role_code is rejected

- GIVEN assessment_type = "standard" and role_code = "INVALID"
- WHEN POST /api/projects is called
- THEN the response is HTTP 422 with an error on `role_code`

#### Scenario: standard project with out-of-role competency is rejected

- GIVEN role_code = "ICO" and one competency in the subset belongs to MLL but not ICO
- WHEN POST /api/projects is called
- THEN the response is HTTP 422 indicating the competency is not valid for that role

#### Scenario: standard project with a potential-type competency is rejected

- GIVEN assessment_type = "standard" and the competency list includes MTG
- WHEN POST /api/projects is called
- THEN the response is HTTP 422 (type mismatch: mixed types)

#### Scenario: Valid potential project with MTG and LAT

- GIVEN assessment_type = "potential", role_code = null, competencies = [MTG, LAT] (both seeded)
- WHEN POST /api/projects is called
- THEN the response is HTTP 201

#### Scenario: potential project with a non-null role_code is rejected

- GIVEN assessment_type = "potential" and role_code = "ICO"
- WHEN POST /api/projects is called
- THEN the response is HTTP 422 (role_code must be null for potential)

#### Scenario: potential project with a standard competency is rejected

- GIVEN assessment_type = "potential" and competencies include PRS (type=standard)
- WHEN POST /api/projects is called
- THEN the response is HTTP 422 (type mismatch)

#### Scenario: Mixed standard+potential competencies in one project are rejected

- GIVEN competencies include both PRS (standard) and MTG (potential)
- WHEN POST /api/projects is called with either assessment_type
- THEN the response is HTTP 422

---

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
