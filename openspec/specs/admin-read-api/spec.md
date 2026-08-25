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
| `GET /api/dashboard/activity` | RBAC only |
| `GET /api/participants/{id}/sessions` | RBAC only |
| `GET /api/interview-sessions/{id}/review` | RBAC only |

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
requires lifecycle `completato`. Enforced by `App\Support\Admin\LifecycleReadGate`
(a shared value object stating each threshold once), invoked from the mandatory
`AdminParticipantReader::read()` (D1) after the org filter and RBAC. An
unrecognized status MUST deny. Denial is `409 Conflict` with a non-localized,
machine-readable body `{error: "lifecycle_not_ready", resource, current_status,
required_status}` (D4 — reversing this delta's earlier tentative `403`: the
caller is an authorized admin of the owning organization and the resource
exists; the denial is temporal and self-resolving, which `403` cannot express
and which the `ParticipantStatusGuard.php:59-64` precedent does not actually
support, since that guard blocks *terminal* statuses, the exact inverse of
this gate's *pre-terminal* blocking); this is distinct from the `404`
cross-tenant case and the `403` RBAC case.

| Status | Transcript (read + download) | Evaluation (read + download) |
|---|---|---|
| `in_attesa` | 409 | 409 |
| `in_corso` | 409 | 409 |
| `in_valutazione` | 200 | 409 |
| `completato` | 200 | 200 |
| `errore` | 409 | 409 |
| unrecognized/unknown | 409 | 409 |

#### Scenario: Transcript denied before in_valutazione

- GIVEN participant P has status `in_corso` in org A
- WHEN org A calls `GET /api/participants/{P}/transcript`
- THEN the response is `409` with body `{error: "lifecycle_not_ready", resource:
  "transcript", current_status: "in_corso", required_status: "in_valutazione"}`

#### Scenario: Evaluation denied at in_valutazione (not yet completato)

- GIVEN participant P has status `in_valutazione`
- WHEN org A calls `GET /api/participants/{P}/evaluation`
- THEN the response is `409` with body `{error: "lifecycle_not_ready", resource:
  "evaluation", current_status: "in_valutazione", required_status: "completato"}`

#### Scenario: Both readable at completato

- GIVEN participant P has status `completato`
- WHEN org A calls transcript and evaluation (read and download variants)
- THEN all four responses are `200`

#### Scenario: Unrecognized status denies (fail-closed)

- GIVEN participant P has a status value not in the known lifecycle enum
- WHEN org A calls transcript or evaluation
- THEN the response is `409` with `error: "lifecycle_not_ready"`, never `200`

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

### Requirement: Evaluation Read Surface Exposes Its Scoring Regime

`GET /api/participants/{id}/evaluation` and `AdminEvaluationSerializer` MUST
expose the Evaluation's `prompt_version` (at minimum) so a consumer can
distinguish an evaluation scored under the discrete `{1,3,5}` domain
(`prompt_version 1.0.0`) from one scored under the widened `{1,2,3,4,5}`
domain (`prompt_version 2.0.0` and later). Nothing new is computed — the
`Evaluation` model already persists `prompt_version`, `model_version`, and
`framework_version_id`; this requirement only obligates exposing them at this
read surface, where today none of the three appears. `prompt_version` and
`model_version` are machine-facing values and MUST NOT be localized or
translated — they are returned literally in every locale, per the
machine-facing-values convention.

#### Scenario: The evaluation response carries prompt_version

- GIVEN a `completato` participant with a persisted Evaluation
- WHEN `GET /api/participants/{id}/evaluation` is called
- THEN the response includes that Evaluation's `prompt_version` value,
  unchanged across locales

#### Scenario: Two evaluations under different prompt_version values are distinguishable

- GIVEN participant A's Evaluation has `prompt_version 1.0.0` and participant
  B's has `prompt_version 2.0.0`
- WHEN each evaluation is fetched
- THEN the two responses carry their own distinct `prompt_version` values

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

Every endpoint's response resource MUST carry a Scramble-resolvable schema
whose field types reflect the resource's actual runtime types — never
Scramble's `string` default for a field type it cannot infer. A local
`/** @var X $y */` PHPDoc annotation inside a resource's `toArray()` is NOT
sufficient: Scramble does not read it, and a resource relying on it alone
silently exports every field as `string`. A resource field that is a genuine
integer MUST declare a `@scramble-return`/`@return` shape typing it `int`; a
field that is a bounded/enum-like value (e.g. `status`, `role_code`) MUST be
typed as its real union; a field that is a translatable attribute (e.g.
`Competency.name`, `Role.responsibilities`, `BarsIndicator.text`/`anchor_*`)
MUST be typed as `string`, never as an object or array.

**Why `string`, not an object**: these fields are backed by
`Spatie\Translatable\HasTranslations`, whose `getAttributeValue()` intercepts
every `$model->name`-style property read and returns
`getTranslation($key, $locale)` — a scalar string — bypassing the `array`
cast Scramble's static analysis sees on the underlying column. The `array`
shape is only ever produced by `$model->toArray()`
(`mutateAttributeForArray()`), which none of the ten resources call — each is
an explicit whitelist built from direct property fetches. An apply-phase
falsifiability check (`expect($json['data'][0]['name'])->toBeString()`
against a live endpoint) confirmed this empirically before any annotation
was written: the runtime value was already a string on every one of the ten
resources. Typing these fields as an object would have been a NEW lie in the
opposite direction — this requirement's original text had it backwards; see
`design.md` D1 ("Translatable fields — a correction to the direction") for
the full evidence trail.

This governs, by name, ten resources currently defaulting to `string` for at
least one non-string field: `Admin/OrganizationResource`,
`Admin/ParticipantDetailResource`, `Admin/ParticipantResource`,
`Admin/UserResource`, `BarsIndicatorResource`, `CompetencyResource`,
`FrameworkVersionResource`, `ParticipantResource`, `ProjectResource`,
`RoleResource`. `ApiClientResource` and `AvatarTemplateResource` are the
working precedent: both already declare a `@scramble-return` shape with zero
runtime change, and Scramble already resolves both correctly.

(Previously: required Scramble annotations for new endpoints only; silent on
the ten resources whose `@var`-only annotations Scramble ignores, producing
the `string` default across the board. An earlier draft of THIS delta also
claimed translatable fields must be typed as an object — that claim was
itself wrong, in the same direction as the original defect, and is corrected
above.)

#### Scenario: openapi.json includes every new route

- GIVEN Scramble regenerates `openapi.json` after this change
- WHEN the spec is inspected
- THEN all 7 admin endpoints are present with typed responses

#### Scenario: An integer field exports as integer, not string

- GIVEN `ParticipantResource`'s `toArray()` returns an integer `id`
- WHEN a fresh `scramble:export` runs
- THEN `openapi.json`'s schema for that resource types `id` as `integer`, not `string`

#### Scenario: An enum-like field exports as its real union

- GIVEN a resource returns `status` or `role_code`, each a bounded set of known values
- WHEN a fresh `scramble:export` runs
- THEN the exported schema types that field as a string-literal union of its known values, not a bare `string`

#### Scenario: A translatable field exports as a string, never an object

- GIVEN a resource returns a translatable attribute (`HasTranslations`,
  backed by an `array` cast at the column level)
- WHEN a fresh `scramble:export` runs
- THEN the exported schema types that field as `string` — matching what
  `HasTranslations::getAttributeValue()` actually returns on property
  read — never as an object or array

#### Scenario: A @var-only resource is a defect, not a supported pattern

- GIVEN a resource whose `toArray()` relies solely on `/** @var X $y */` with no `@scramble-return` annotation
- WHEN `scramble:export` runs
- THEN Scramble ignores the local `@var` hint and defaults every field to `string` — this is the condition this requirement forbids on the ten named resources

### Requirement: Dashboard exposes a recent-activity feed

The system MUST provide `GET /api/dashboard/activity`, returning the
participants of the caller's organization ordered by `updated_at` descending,
each row carrying `candidate_ref`, `display_name`, `status`, `project_name` and
`updated_at`.

It MUST read through the same tenant-safe, RBAC-safe path as the participant
list, so the feed can never surface a row that `GET /api/participants` would
refuse. It is a view of that data, not a wider one.

The response MUST be capped server-side. The endpoint answers "what just
happened"; an uncapped feed is a second participant list without pagination,
and the payload would grow with the tenant.

`project_name` MUST be resolved server-side. The feed is read at a glance, and
a row that requires a second lookup to be understood has failed its purpose.

#### Scenario: Most recently updated first

- GIVEN an org with participants updated at different times
- WHEN an admin calls `GET /api/dashboard/activity`
- THEN the response is 200
- AND rows appear ordered by `updated_at` descending

#### Scenario: A row is readable without a second request

- GIVEN a participant belonging to a project named "Retail Managers"
- WHEN the feed is read
- THEN that row carries `project_name` = "Retail Managers"

#### Scenario: Cross-tenant isolation

- GIVEN organizations A and B, each with participants
- WHEN an authenticated user of org A reads the feed
- THEN only org A participants appear, regardless of which org updated last

#### Scenario: The feed is capped

- GIVEN an org with 25 participants
- WHEN the feed is read
- THEN at most 10 rows are returned

#### Scenario: An empty organization is a valid state

- GIVEN an org with no participants
- WHEN the feed is read
- THEN the response is 200 with an empty `data` array, never an error

#### Scenario: Same RBAC as the participant list

- GIVEN an authenticated operator of the org
- WHEN they read the feed
- THEN the response is 200

#### Scenario: Authentication is required

- WHEN the feed is requested without a token
- THEN the response is 401

### Requirement: Admin session review endpoint

The system MUST provide `GET /api/participants/{id}/sessions` and
`GET /api/interview-sessions/{id}/review`, both org-scoped and behind
`auth:api`, returning for a session: provider, provider session ref, status,
ended reason, `started_at`, `ended_at`, computed duration, the integrity
timeline, the risk score with its band, the timed snapshot list, and the cost
estimates.

Integrity scoring MUST be computed server-side and returned with the payload.
Two implementations of a weighted score drift, and the figure an operator acts
on must be the one the API can defend.

Snapshot references MUST be returned as short-lived signed URLs, never as raw
object keys. A raw key implies either a public bucket holding identifiable
webcam frames or a disclosed storage layout; both are refused.

Cost MUST be returned as an estimate of avatar provider minutes, and MUST be
labelled as an estimate.

LLM token cost is NOT returned. `ai_requests` records organization, provider,
model and tokens but carries no `interview_session_id`, so token spend cannot be
attributed to one session without inventing the link — and a plausible number
with no basis is worse than an absent one. Attributing it needs that column,
which belongs to whoever owns the writer side.

#### Scenario: A session review returns timing, integrity and snapshots

- GIVEN a completed interview session with integrity events and snapshots
- WHEN an admin of the owning organization reads its review
- THEN the response is 200 carrying duration, the event timeline, the risk score
  and band, and the snapshot list

#### Scenario: Snapshots are signed and expiring

- WHEN a session review is read
- THEN each snapshot carries a signed URL with a short expiry
- AND no raw storage key appears anywhere in the response

#### Scenario: Cost is an avatar-minutes estimate, explicitly flagged

- WHEN a session review is read
- THEN the avatar estimate is present and marked as an estimate
- AND no LLM figure is reported, because none can be attributed to a session

#### Scenario: An unpriceable session reports no cost rather than zero

- GIVEN a session that never ended, or one on an unrecognised provider
- WHEN its review is read
- THEN the estimate is absent
- AND it is not reported as zero, which would claim the session was free

#### Scenario: Cross-tenant isolation

- GIVEN a session belonging to organization B
- WHEN an authenticated user of organization A requests its review
- THEN the response is 404

#### Scenario: Candidates can never read the review

- GIVEN a valid candidate token for the session
- WHEN it is used against the review endpoint
- THEN the request is refused
- AND no candidate-guard route exposes integrity events or snapshots

The last scenario is a standing constraint, not a one-off check: the integrity
taxonomy is a list of behaviours being counted, and disclosing it to the person
being measured defeats the measurement.
