# Admin Read API Specification

## Purpose

Admin-authenticated, org-scoped HTTP read surface for participants, transcripts,
evaluations, downloads, and dashboard metrics. Closes the gap verified in the
proposal: `api/app/Http/Controllers/Api/` contains only `FrameworkController`
and `ProjectController` (no admin participant/evaluation/transcript routes exist).
Enforces the binding lifecycle read-gate, which currently has zero enforcement
anywhere (`ParticipantStatusGuard` is candidate-side write gating, not this).

## Requirements

### Requirement: Admin Read Endpoint Surface

The system MUST expose the following endpoints under `auth:api` + `TenantContext`
(mirroring `api/routes/api.php:66-68`), gated by Spatie role (`admin`/`operator`/
`viewer`, per `ProjectPolicy::viewAny` pattern — any authenticated org member may
read):

| Endpoint | Resource gate |
|---|---|
| `GET /api/participants` | RBAC only |
| `GET /api/participants/{id}` | RBAC only |
| `GET /api/participants/{id}/transcript` | lifecycle ≥ `in_valutazione` |
| `GET /api/participants/{id}/evaluation` | lifecycle `completato` |
| `GET /api/participants/{id}/transcript/download` (`text/plain`) | same as transcript |
| `GET /api/participants/{id}/evaluation/download` (`application/json`) | same as evaluation |
| `GET /api/dashboard/metrics` | RBAC only |

#### Scenario: List and detail return only RBAC-gated data

- GIVEN an authenticated admin/operator/viewer user of org A
- WHEN they call `GET /api/participants` or `GET /api/participants/{id}` for an org A participant
- THEN the response is 200 with the participant(s), regardless of lifecycle status

### Requirement: Cross-Tenant Isolation on Every Admin Read Endpoint

Every endpoint above MUST return `404` (never `200`, never leak existence) when
the `{id}` belongs to a different organization than the authenticated user's.
`Participant` is a plain `Model` (`Participant.php:55`, no global scope) — admin
controllers MUST resolve it via `Participant::where('organization_id', $orgId)->findOrFail($id)`
(the pattern proven at `M2m/ParticipantController.php:90,110`), never bare
`Participant::findOrFail($id)`. `Evaluation`/`Utterance`/`InterviewSession` extend
`TenantModel` and rely on the global scope after `TenantContext`.

#### Scenario: Cross-org request returns 404 on every endpoint

- GIVEN participant P belongs to org B; the requester is authenticated as org A
- WHEN org A calls any endpoint in the table above with P's id
- THEN every one of the 7 endpoints returns `404`
- AND no response body contains any field from P's record

#### Scenario: withoutGlobalScopes() is absent from admin HTTP controllers

- GIVEN the admin read controllers under `App\Http\Controllers\Api`
- WHEN their source is inspected
- THEN no `withoutGlobalScopes()` call is present (that pattern is reserved for
  `EvaluationPayloadAssembler`'s queued-job context, never HTTP)

### Requirement: Lifecycle Read-Gate (Fail-Closed)

Transcript access requires lifecycle ≥ `in_valutazione`; evaluation access
requires lifecycle `completato`. Enforced by a policy (`ParticipantPolicy::viewTranscript`
/ `viewEvaluation`) backed by a shared value object stating each threshold once.
An unrecognized status MUST deny. Denial is `403` with a non-localized,
machine-readable `reason` code (consistent with `ParticipantStatusGuard.php:59-64`
and the CLAUDE.md machine-facing-responses rule); this is distinct from the `404`
cross-tenant case.

| Status | Transcript (read + download) | Evaluation (read + download) |
|---|---|---|
| `in_attesa` | 403 | 403 |
| `in_corso` | 403 | 403 |
| `in_valutazione` | 200 | 403 |
| `completato` | 200 | 200 |
| `errore` | 403 | 403 |
| unrecognized/unknown | 403 | 403 |

#### Scenario: Transcript denied before in_valutazione

- GIVEN participant P has status `in_corso` in org A
- WHEN org A calls `GET /api/participants/{P}/transcript`
- THEN the response is `403` with a machine-readable `reason` code

#### Scenario: Evaluation denied at in_valutazione (not yet completato)

- GIVEN participant P has status `in_valutazione`
- WHEN org A calls `GET /api/participants/{P}/evaluation`
- THEN the response is `403`

#### Scenario: Both readable at completato

- GIVEN participant P has status `completato`
- WHEN org A calls transcript and evaluation (read and download variants)
- THEN all four responses are `200`

#### Scenario: Unrecognized status denies (fail-closed)

- GIVEN participant P has a status value not in the known lifecycle enum
- WHEN org A calls transcript or evaluation
- THEN the response is `403`, never `200`

### Requirement: Evaluation Serializer Is Scoped, Not Copied From the Webhook Assembler

The admin evaluation serializer MUST query `Evaluation`/`CompetencyResult`/
`IndicatorScore` under the ambient `TenantContext` scope. It MUST NOT reuse
`EvaluationPayloadAssembler`'s `withoutGlobalScopes()` calls (`:46,48,69,112`),
which are correct only in that job's no-ambient-resolver context. Output shape
reproduces `esempio-report-valutazione.json` (competency mean, `reliability`
percent string, indicator scores, verbatim excerpts).

#### Scenario: Serializer never bypasses the tenant scope

- GIVEN the admin evaluation serializer's implementation
- WHEN inspected
- THEN it contains no `withoutGlobalScopes()` call

### Requirement: Downloadable Artifacts Are Limited to Transcript and Evaluation

Only the transcript (assembled from `Utterance` rows, `text/plain`) and the
evaluation report (`application/json`) are downloadable. Per-question audio
download is explicitly out of scope: audio storage does not exist and is gated
by open product decision #2 (GDPR retention); `InterviewSnapshot` proctoring
artifacts are under the same gate and are never exposed via this API.

#### Scenario: No audio download endpoint exists

- GIVEN the full admin read route table
- WHEN routes are enumerated
- THEN no route serves per-question audio or snapshot binary content

### Requirement: Scramble Documentation Parity

Every new endpoint MUST carry Scramble annotations sufficient to regenerate
`openapi.json` with a resolvable schema (request/response), keeping the
`backoffice` generated client non-stale.

#### Scenario: openapi.json includes every new route

- GIVEN Scramble regenerates `openapi.json` after this change
- WHEN the spec is inspected
- THEN all 7 admin endpoints are present with typed responses
