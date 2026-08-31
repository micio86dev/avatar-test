# API — required capabilities (outline)

A **functional** list of the operations the platform must expose to external systems or admin automations. The supplier will decide REST/GraphQL, authentication and the data schema.

## Authentication (generic requirement)

- Authenticated server-to-server communication;
- Credentials per tenant or environment (secret key, client credentials, etc.);
- Rejection of unauthenticated or unauthorized requests.

---

## Area: Organizations (tenants)

| Operation | Description |
|------------|-------------|
| List | All organizations accessible to the caller |
| Detail | A single organization, optionally with nested projects |
| Create | A new customer organization |
| Update | Metadata changes (name, configuration) |
| Delete | Removal, cascading to dependent data (projects, candidates, assessments) |

**Business note:** some system entities (e.g. the default organization/project) may be protected from deletion.

---

## Area: Projects (assessment campaigns)

| Operation | Description |
|------------|-------------|
| List | All projects, or filtered by organization |
| Detail | Full configuration: role, competencies, assessment type, UX options |
| Create | A new project with `company_id`, role, competencies, type, language, pauses, nudges |
| Update | Changes to the permitted fields (assessment type and competency set: immutable after go-live is recommended) |
| Delete | Removal of the project and the associated candidate data |

**Conceptual project fields:**
- the owning organization;
- the target role;
- the competency list;
- the assessment type (standard / potential);
- the language;
- UX options (pause every N competencies, short-answer nudge threshold).

---

## Area: Candidates

| Operation | Description |
|------------|-------------|
| List | All candidates, or filtered by project |
| Detail | Status, metadata, interview link where applicable |
| Create | A new candidate with identifier, project, role, language |
| Update | Changes to the permitted metadata |
| Delete | Removal of the candidate and the assessment data |

---

## Area: Reading results (after the interview)

| Operation | Description | Gate |
|------------|-------------|------|
| Transcript | The full conversation text | Candidate status ≥ "under evaluation" |
| Evaluation | The structured scoring output | Candidate status = "completed" |
| Progress | Advancement per competency | During or after the interview |

The **status gates** prevent partial data from being exposed before the pipeline allows it.

---

## Area: Interview link generation

| Operation | Description |
|------------|-------------|
| Generate SSO link | Produces a secure URL for a candidate (an alternative or a complement to ingress from the calling portal) |

---

## Multi-tenancy

- Every operation is scoped to the authenticated caller's organization;
- A project belongs to exactly one organization (non-reassignable is recommended);
- A candidate belongs to exactly one project.

---

## What the supplier must deliver

- An OpenAPI specification (or equivalent) with request/response, error codes, pagination;
- An authentication guide;
- A sandbox environment for integration testing.
