# Delta for Admin Read API

## ADDED Requirements

### Requirement: Evaluations Index Endpoint

The system MUST expose `GET /api/evaluations`: an org-scoped, paginated,
cross-participant list under the same `auth:api` + `TenantContext` + RBAC
gate as the rest of `admin-read-api`. It MUST support filters `project_id`,
`assessment_type`, `role_code`, `status`, a completion date range, and
`reliability` ≥ a threshold. Each row MUST carry: participant reference,
project, assessment type, role code, `completed_at`, completion status
(`completed`/`pending` per the ≥90% valid-competencies gate), and
`reliability` rendered verbatim as a percentage (product decision 1 — no
High/Medium/Low bands).

#### Scenario: Index returns only same-org rows

- GIVEN org A and org B each have completed evaluations
- WHEN org A calls `GET /api/evaluations`
- THEN every row belongs to an org A participant, none to org B

#### Scenario: Reliability renders as a verbatim percentage

- GIVEN a completed evaluation with `reliability = 0.83`
- WHEN it appears in the index
- THEN the row shows `83%` (or equivalent numeric percentage), never a
  High/Medium/Low label

### Requirement: Evaluations Summary Endpoint

The system MUST expose `GET /api/evaluations/summary`, aggregating over the
same filter set as the index: counts by completion status, and the mean
competency score per competency code across the filtered set (product
decision 4).

#### Scenario: Summary computes mean per competency code

- GIVEN 3 org A participants at `completato` with a `COL` competency score
  each
- WHEN `GET /api/evaluations/summary` is called with no filters
- THEN the response includes a `COL` entry equal to the mean of those 3
  competency scores

### Requirement: Lifecycle Read-Gate Applies To The Evaluations Index And Summary

Structured evaluation data (scores, reliability, competency means) MUST
appear only for participants at `completato`. Participants below that
lifecycle status MUST either be excluded from score-bearing fields or listed
with status only — never with scores. This inherits `admin-read-api`'s
Lifecycle Read-Gate and Cross-Tenant Isolation requirements verbatim.

#### Scenario: A non-completato participant never leaks a score

- GIVEN an org A participant at `in_valutazione` with an in-progress
  evaluation
- WHEN `GET /api/evaluations` is called
- THEN that participant's row (if present) carries no `reliability` or
  competency score field
- AND `GET /api/evaluations/summary` excludes that participant from every
  mean computation

#### Scenario: Cross-org filter never leaks foreign rows

- GIVEN a `project_id` filter value that belongs to org B
- WHEN an org A admin calls `GET /api/evaluations?project_id={org B project}`
- THEN the response is `200` with an empty result set, never org B's data

### Requirement: Scramble Documentation Parity For New Endpoints

`GET /api/evaluations` and `GET /api/evaluations/summary` MUST carry Scramble
annotations sufficient to regenerate `openapi.json` with resolvable request
and response schemas.

#### Scenario: openapi.json includes both new routes

- GIVEN Scramble regenerates `openapi.json` after this change
- WHEN the spec is inspected
- THEN both endpoints are present with typed responses
