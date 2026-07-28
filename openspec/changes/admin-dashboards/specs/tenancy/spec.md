# Delta for Tenancy (admin-dashboards — C11)

Modifies: `openspec/specs/tenancy/spec.md`

C11 introduces the first HTTP admin reads of a **non-`TenantModel`** entity
(`Participant` — plain `Model`, no global scope, `Participant.php:23-25`). This
delta generalizes the pattern already proven at `M2m/ParticipantController.php:90,110`
into a standing tenancy rule, so future slices reading other plain-`Model`
entities do not rediscover the trap documented in the proposal (D1): applying
`findOrFail()` alone to `Participant` applies **no scope at all**.

---

## ADDED Requirements

### Requirement: Explicit Org Filter for Non-TenantModel HTTP Reads

Any HTTP controller under `App\Http\Controllers` reading a model that does
**not** extend `TenantModel` (i.e. carries no `TenantScoped` global scope)
MUST apply an explicit `->where('organization_id', $orgId)` filter, with
`$orgId` sourced from the resolved `TenantContext`/`TenantContextM2m`/
`TenantContextCandidate` state — never from request input. `withoutGlobalScopes()`
MUST NOT be used in `App\Http` context; it is reserved for queued-job contexts
with no ambient tenant resolver (e.g. `EvaluationPayloadAssembler`).

#### Scenario: Plain-Model admin read applies explicit filter

- GIVEN a controller action reading `Participant` (plain `Model`) after `TenantContext`
- WHEN the query is built
- THEN it includes `->where('organization_id', $resolvedOrgId)` before `findOrFail()`
- AND a cross-org id returns `404`

#### Scenario: Bare findOrFail() on a non-TenantModel is a defect

- GIVEN a controller calls `Participant::findOrFail($id)` with no org filter
- WHEN a cross-org id is requested
- THEN the record IS returned with `200` (no scope applied)
- AND this construction MUST NOT appear in any admin controller (violates this requirement)

#### Scenario: No withoutGlobalScopes() in HTTP controllers

- GIVEN all classes under `App\Http\Controllers`
- WHEN their source is inspected
- THEN no `withoutGlobalScopes()` call is present
- AND this is verifiable by a static grep-based test in CI
