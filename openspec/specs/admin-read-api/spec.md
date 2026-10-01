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

Transcript access requires lifecycle status `in_corso`, `in_valutazione`,
`completato`, or `errore`; `in_attesa` remains denied. Evaluation access still
requires lifecycle `completato`. Enforced by `App\Support\Admin\LifecycleReadGate`,
invoked from `AdminParticipantReader::read()` after the org filter and RBAC. An
unrecognized status MUST deny for every scope. Denial is `409 Conflict` with a
non-localized, machine-readable body `{error: "lifecycle_not_ready", resource,
current_status, required_status}`; distinct from the `404` cross-tenant case and
the `403` RBAC case.

Extending Transcript access to `errore` MUST NOT alter the ordering semantics
used to compare the other four statuses' progression — `errore` is a
terminal-failure state, not a later point in the interview, and its Transcript
eligibility MUST be expressed independently of that ordering.

| Status | Transcript (read + download) | Evaluation (read + download) |
|---|---|---|
| `in_attesa` | 409 | 409 |
| `in_corso` | 200 | 409 |
| `in_valutazione` | 200 | 409 |
| `completato` | 200 | 200 |
| `errore` | 200 | 409 |
| unrecognized/unknown | 409 | 409 |

#### Scenario: in_attesa still denies transcript access

- GIVEN participant P has status `in_attesa`
- WHEN org A calls `GET /api/participants/{P}/transcript`
- THEN the response is `409` with `error: "lifecycle_not_ready"`

#### Scenario: Transcript readable at in_corso

- GIVEN participant P has status `in_corso`
- WHEN org A calls transcript read and download
- THEN both responses are `200`

#### Scenario: Transcript readable at errore

- GIVEN participant P has status `errore`
- WHEN org A calls transcript read and download
- THEN both responses are `200`

#### Scenario: Evaluation stays denied below completato regardless of the transcript change

- GIVEN participant P has status `in_corso` or `errore`
- WHEN org A calls `GET /api/participants/{P}/evaluation`
- THEN the response is `409` in both cases

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
reproduces `evaluation-report-example.json` (competency mean, `reliability`
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

### Requirement: Evaluation Read Surface Exposes unscorable_reason

`GET /api/participants/{id}/evaluation` and `AdminEvaluationSerializer` MUST expose
each unscorable competency's `unscorable_reason` (`anchor_translation_missing`,
`role_no_bars`, `llm_parse_error`, or `llm_truncated`) instead of returning
`{score: null, reliability: "0%", behaviors: []}` with no explanation. This closes the
gap where an operator sees a bare zero with no indication of whether it is a
candidate-side fact (no assessable evidence) or a system fact (the scorer failed).
`unscorable_reason` is a machine-facing value and MUST NOT be localized or
translated by the API — it is returned literally in every locale, per the
machine-facing-values convention; localization of its label happens in
`admin-backoffice`.

#### Scenario: An unscorable competency's reason is present in the response

- GIVEN a `completato` participant with a competency finalized as
  `unscorable_reason = 'llm_truncated'`
- WHEN `GET /api/participants/{id}/evaluation` is called
- THEN that competency's serialized entry includes `unscorable_reason: "llm_truncated"`

#### Scenario: A scored competency carries no unscorable_reason

- GIVEN a competency that scored normally (no unscorable path taken)
- WHEN the evaluation is serialized
- THEN `unscorable_reason` is absent or null for that competency

#### Scenario: unscorable_reason is identical across locales

- GIVEN the same evaluation fetched once with `Accept-Language: it` and once with `en`
- WHEN both responses are compared
- THEN `unscorable_reason` is byte-identical in both — it is never translated by the API

---

### Requirement: Evaluation Read Surface Exposes Per-Indicator Validation-Failure Reason

`AdminEvaluationSerializer`'s per-indicator `behaviors` entries MUST expose the
indicator's `unassessable_reason` (`model_declared`, `excerpt_unverifiable`,
`score_illegal`, or null) alongside the existing `score`/`explanation`/`excerpts`
fields, whenever `score == -1`. This is a machine-facing value, unlocalized, per the
same convention as `unscorable_reason`. `unassessable_reason` is deliberately named
as the indicator-grain sibling of `unscorable_reason` (competency grain) and
`failure_reason` (`ai_requests` call grain) — three different names for three
different grains, not the same name reused.

#### Scenario: A per-indicator reason accompanies a -1 score

- GIVEN a competency with one indicator persisted `score = -1, unassessable_reason =
  'excerpt_unverifiable'` and two indicators with legal scores
- WHEN the evaluation is serialized
- THEN that indicator's `behaviors` entry includes `unassessable_reason: "excerpt_unverifiable"`
- AND the other two indicators' entries carry `unassessable_reason: null`

#### Scenario: A legally scored indicator's reason is null

- GIVEN an indicator with a legal score in `{1,2,3,4,5}`
- WHEN it is serialized
- THEN its `unassessable_reason` field is `null`

---

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

---

### Requirement: Partial Transcript Disclosure Marker

Every transcript read and download response MUST carry an explicit,
non-localized, machine-readable marker stating whether the transcript is
partial. The marker MUST be present on every response regardless of status —
omission is indistinguishable from "complete" and reintroduces the
concealment failure the lifecycle gate previously produced by denial. It MUST
indicate partial when the participant's lifecycle is below `in_valutazione`,
or when the status is `errore`. It MUST indicate complete only when the
lifecycle is `in_valutazione` or `completato`.

#### Scenario: in_corso read is marked partial

- GIVEN participant P has status `in_corso`
- WHEN org A reads P's transcript
- THEN the response body's partial marker indicates partial

#### Scenario: errore read is marked partial

- GIVEN participant P has status `errore`
- WHEN org A reads P's transcript
- THEN the response body's partial marker indicates partial

#### Scenario: in_valutazione and completato reads are not marked partial

- GIVEN participant P has status `in_valutazione` or `completato`
- WHEN org A reads P's transcript
- THEN the response body's partial marker indicates complete, in both cases

#### Scenario: The download variant carries the same marker as the read variant

- GIVEN participant P has status `in_corso`
- WHEN org A requests the transcript download
- THEN its partial marker matches the value the read endpoint returns for the
  same participant

### Requirement: Turn-by-Turn Transcript Payload Contract

The transcript payload MUST return utterances grouped by session, ordered by
`question_index`, each session's utterances ordered chronologically, with
every utterance attributed to its speaker (avatar or candidate). No speaker
filter MUST be applied — both avatar and candidate turns MUST be present.

#### Scenario: Sessions are ordered by question_index

- GIVEN a participant whose sessions were answered in a non-alphabetical
  question order
- WHEN the transcript is read
- THEN sessions appear ordered by `question_index`, not by any other field

#### Scenario: Both speakers appear, chronologically ordered

- GIVEN a session with interleaved avatar and candidate utterances
- WHEN the transcript is read
- THEN both speakers' utterances are present for that session
- AND they appear in chronological order

### Requirement: Participants List Carries Project Identity

The participants list resource MUST carry the participant's project name
alongside `project_id` for each row, resolved server-side without
introducing a per-row N+1 query.

#### Scenario: Each row exposes its project name

- GIVEN an org with participants across two different projects
- WHEN the participants list is read
- THEN every row carries its own project's name
- AND the list query issues no per-row additional query

### Requirement: Participant Detail Summary Fields

The participant detail resource MUST carry: the lifecycle status as one of
the five literal domain values (`in_attesa`, `in_corso`, `in_valutazione`,
`completato`, `errore`), never a boolean or a completed/not-completed
reduction; session progress as `done` and `total` counts, where `total`
equals `count(project_competencies)` for the participant's project; total
elapsed interview time, aggregated from per-session durations; and a cost
estimate aggregated from per-session estimates, explicitly labeled as an
estimate. Sessions with no cost estimate MUST be excluded from the sum, and
the number of sessions that contributed MUST be disclosed alongside it. When
no session yields an estimate, the total MUST be absent, never zero.

#### Scenario: Status is a literal domain value

- GIVEN a participant at any of the five lifecycle statuses
- WHEN the detail is read
- THEN the status field equals exactly that literal value, never a boolean

#### Scenario: Progress denominator matches the project's competency count

- GIVEN a participant whose project has 15 configured competencies, of which
  6 sessions exist
- WHEN the detail is read
- THEN progress reads `6 / 15`

#### Scenario: Elapsed time sums session durations

- GIVEN a participant with two sessions of durations 300s and 480s
- WHEN the detail is read
- THEN the elapsed time equals 780 seconds

#### Scenario: A partial cost total discloses how many sessions contributed

- GIVEN a participant with 3 sessions, 2 of which yield a cost estimate and
  1 of which does not
- WHEN the detail is read
- THEN the cost field is the sum of the 2 estimated sessions
- AND the response states 2 of 3 sessions contributed

#### Scenario: No session yields an estimate

- GIVEN a participant whose sessions all lack a resolvable cost estimate
- WHEN the detail is read
- THEN the cost field is absent, not zero

### Requirement: Participants List Carries The External Reference

The participants list resource (`GET /api/participants`) MUST carry `external_id`
(integer or null) and `source` (string or null) for every row. Both keys MUST always
be present; an absent value is `null`, never a missing key, `0`, or `""`. `external_id`
MUST be emitted as a JSON number (never a string), which is exact because it is capped
at 9007199254740991.

#### Scenario: A row with both fields

- GIVEN a participant with `external_id = 4471` and `source = "acme-ats"`
- WHEN the list is read
- THEN that row has `external_id = 4471` (number) and `source = "acme-ats"`

#### Scenario: A row with only external_id

- GIVEN a participant with `external_id = 4471` and no source
- WHEN the list is read
- THEN the row has `external_id = 4471` and `source = null`

#### Scenario: A row with only source

- GIVEN a participant with `source = "acme-ats"` and no external_id
- WHEN the list is read
- THEN the row has `source = "acme-ats"` and `external_id = null`

#### Scenario: A row with neither

- GIVEN a participant with no external reference
- WHEN the list is read
- THEN the row contains both keys with `null` values

#### Scenario: The list adds no per-row query

- GIVEN a page of participants
- WHEN the list is read
- THEN exposing the two fields issues no additional query per row

### Requirement: Participant Detail Carries The External Reference

The participant detail resource (`GET /api/participants/{id}`) MUST carry `external_id`
(integer or null) and `source` (string or null), always present, alongside the existing
summary fields. Access rules, the cross-tenant 404, and the lifecycle read-gate are
unchanged.

#### Scenario: Detail exposes the reference

- GIVEN a participant with `external_id = 4471` and `source = "acme-ats"`
- WHEN the detail is read by any authorized role
- THEN the response carries both values

#### Scenario: Detail with no reference

- GIVEN a participant with no external reference
- WHEN the detail is read
- THEN `external_id` and `source` are present and null

#### Scenario: Cross-tenant detail is still not found

- GIVEN a participant of Org B with an external reference
- WHEN an Org A user reads its detail
- THEN HTTP 404 is returned and no field of the record is disclosed

### Requirement: Participants List Search Matches The External Reference

The `q` parameter of `GET /api/participants` MUST match, always inside the caller's
`organization_id`:

- `candidate_ref`, `display_name` and `source`: case-insensitive substring match. The
  `LIKE` wildcards `%` and `_` and the escape character `\` in the term MUST be matched
  literally, never as wildcards (a term of `_` matches only values containing an
  underscore).
- `external_id`: exact numeric equality, applied ONLY when the trimmed term is a whole
  number from 1 to 9007199254740991 (ASCII digits only). A term that is not such a
  number MUST NOT be compared to `external_id` and MUST NOT raise an error, including an
  all-digit term above the cap (no `external_id` comparison; the other fields are still
  evaluated).

The matches are OR-ed with each other, and the OR group remains AND-ed with the `status`
filter and the organization scope (it MUST NOT be able to escape the scope). A
participant with a NULL `source` never matches on `source`.
(Previously, before `candidate-external-reference`: `candidate_ref` and `display_name`
were matched with a case-sensitive, unescaped `LIKE`, so `q=maria` did not find
"Maria Rossi" and a `%` in the term acted as a wildcard. Aligning them is a bug fix made
in the same change so the three text fields behave identically.)

#### Scenario: q matches source case-insensitively and partially

- GIVEN a participant with `source = "Acme ATS"`
- WHEN `q=acme` is searched
- THEN that participant is returned

#### Scenario: q matches candidate_ref and display_name case-insensitively

- GIVEN a participant with `candidate_ref = "EXT-ABC-001"` and another with
  `display_name = "Maria Rossi"`
- WHEN `q=ext-abc` and `q=maria` are searched
- THEN the first and the second participant are returned respectively

#### Scenario: A numeric q matches external_id exactly

- GIVEN participants with `external_id` 4471, 44710, and 14471 (and unrelated sources)
- WHEN `q=4471` is searched
- THEN the participant with `external_id = 4471` is returned
- AND the participants with 44710 and 14471 are not returned by the external_id branch

#### Scenario: A numeric q also matches a source containing the digits

- GIVEN a participant with `source = "job-4471"` and no external_id
- WHEN `q=4471` is searched
- THEN that participant is returned via the `source` match

#### Scenario: A non-numeric q never touches external_id

- GIVEN participants with external ids
- WHEN `q=44x` or `q=acme` is searched
- THEN HTTP 200 is returned without error
- AND no row is returned solely because of an `external_id` comparison

#### Scenario: An all-digit q above the cap does not error

- GIVEN `q=99999999999999999999999`
- WHEN the list is searched
- THEN HTTP 200 is returned without a database error
- AND rows matching on `candidate_ref`, `display_name`, or `source` are still returned

#### Scenario: LIKE wildcards in the term are literal

- GIVEN participants whose values are `abc`, `a_c`, `50%`, and `back\slash`
- WHEN `q=a_c`, `q=_`, `q=%` and `q=\` are searched
- THEN `q=a_c` returns only `a_c` (not `abc`)
- AND `q=_` and `q=%` return only rows containing a literal underscore or percent sign
- AND `q=\` treats the backslash literally
- AND the same holds when the value sits in `source`

#### Scenario: q stays combinable with the status filter

- GIVEN participants matching `q=acme` at different statuses
- WHEN `q=acme&status=in_attesa` is searched
- THEN only matching participants at `in_attesa` are returned

#### Scenario: Search never crosses organizations

- GIVEN Org A and Org B each hold a participant with `source = "acme-ats"` and
  `external_id = 4471`
- WHEN an Org A user searches `q=acme-ats` and `q=4471`
- THEN only Org A's participant is returned

### Requirement: External Reference Fields Are Typed In The OpenAPI Export

Every resource that carries the external reference MUST declare it in a
Scramble-resolvable shape so the export types `external_id` as nullable `integer` and
`source` as nullable `string` — never Scramble's `string` default for `external_id`.
This covers `Admin\ParticipantResource`, `Admin\ParticipantDetailResource`, and the
operator/M2M participant resource `ParticipantEnrolmentResource`. The candidate-facing
participant schema (`App.Http.Resources.ParticipantResource`) MUST NOT contain either
field.

#### Scenario: external_id exports as a nullable integer

- GIVEN a fresh `scramble:export` against PostgreSQL
- WHEN the schema of each carrying resource is inspected
- THEN `external_id` is `integer` with null allowed and `source` is `string` with null
  allowed

#### Scenario: The candidate session schema omits the fields

- GIVEN the same export
- WHEN the schema of the candidate session response is inspected
- THEN neither `external_id` nor `source` appears

#### Scenario: Export drift is detected

- GIVEN `openapi.json` and `openapi.v1.json` committed without the new fields
- WHEN the export-drift check runs after this change
- THEN it fails until the exports are regenerated

### Requirement: Participant List And Detail Carry The Reusable Link Origin

The participants list resource (`GET /api/participants`) and the participant detail resource
(`GET /api/participants/{id}`) MUST carry `reusable_link`, always present: an object
`{"id": "rlk_...", "label": <string|null>}` when the participant was created by a reusable-link
redemption (its `reusable_interview_link_id` is set), and `null` otherwise. `id` is the link's
public id; the internal id, `token_prefix`, `token_hash`, `lang`, counters and any URL MUST NOT
be included. Access rules, the cross-tenant 404 and the lifecycle read-gate are unchanged.

The origin MUST be resolved with ONE eager load of the link (`id`, `public_id` and `label`
only) on the list query and an explicit load on the detail read, never a lazy per-row load, and
the relation is tenant-scoped: a foreign key that points at another organization's link MUST
never resolve that link's label. The detail read loads it on the show path only (the shared
`read()` that also serves the transcript and the evaluation does not).

#### Scenario: A visitor carries the origin on the list

- GIVEN a visitor created by a link labelled `Milan fair stand`
- WHEN the participants list is read
- THEN that row has `reusable_link = {"id": "rlk_...", "label": "Milan fair stand"}`

#### Scenario: A label-less link carries a null label

- GIVEN a visitor created by a link with no label
- WHEN the list or detail is read
- THEN `reusable_link.label` is `null` and `reusable_link.id` is the public id

#### Scenario: An ordinary participant carries null

- GIVEN a participant created by the SSO exchange, the M2M API or the operator entry link
- WHEN the list and detail are read
- THEN the `reusable_link` key is present with value `null`

#### Scenario: Detail exposes the origin to every authorized role

- GIVEN a visitor
- WHEN an `admin`, an `operator` and a `viewer` of its organization read the detail
- THEN each receives the same `reusable_link` object

#### Scenario: Only the two keys are exposed

- GIVEN a visitor's `reusable_link` object
- WHEN its keys are inspected
- THEN they are exactly `id` and `label`

#### Scenario: The list adds no per-row query

- GIVEN a page of participants mixing visitors of different links and ordinary rows
- WHEN the list is read
- THEN exposing `reusable_link` issues the same number of queries as one visitor alone

#### Scenario: Cross-tenant detail is still not found

- GIVEN a visitor of organization B
- WHEN an organization A user reads its detail
- THEN HTTP 404 is returned and no field is disclosed

#### Scenario: A foreign link never resolves

- GIVEN a participant of organization A whose link key points at a link of organization B
- WHEN the list and detail are read
- THEN B's label is never disclosed

#### Scenario: A deleted link degrades to null

- GIVEN a visitor whose link row was deleted (the FK became NULL)
- WHEN the detail is read
- THEN `reusable_link` is `null`

#### Scenario: A real redemption reads back with its origin

- GIVEN a participant created by a real redemption over HTTP
- WHEN an admin reads the list and the detail
- THEN both carry the link's public id and label

### Requirement: The Reusable Link Origin Is Classified And Typed

`reusable_link` is an admin-only field. The exposure catalogue (`T-EXPOSE-001`,
`ExposureCatalogue`) MUST carry entries classifying it as admin-only in the same change that
adds it: the sub-keys `reusable_link.id` and `reusable_link.label` are excluded from the public
Interview resource, with a classification comment (an admin-only origin marker, never on `/v1`,
exports or webhooks; integrators filter on the `rlv_` prefix), and the exposure fixture MUST be
a visitor WITH a link (a null fixture would flatten to a bare `reusable_link` leaf and hide the
shape). No public or export surface MAY carry it. The Scramble export MUST type `reusable_link`
on `Admin\ParticipantResource` and `Admin\ParticipantDetailResource` as a REQUIRED key whose
value is a nullable object with `id` (string) and nullable `label` (string); the candidate-facing
participant schema, the M2M enrolment schema and every `/v1` schema MUST NOT contain it.

#### Scenario: The exposure gate passes with a classified entry

- GIVEN the catalogue entries for `reusable_link.id` and `reusable_link.label` classified
  admin-only and a linked fixture
- WHEN the T-EXPOSE-001 test runs
- THEN it passes

#### Scenario: The gate fails without the entry

- GIVEN the same field without a catalogue entry, or the entry kept with an unlinked fixture
- WHEN the T-EXPOSE-001 test runs
- THEN it fails until the field is classified

#### Scenario: The export types the field and omits it elsewhere

- GIVEN a fresh `scramble:export` against PostgreSQL
- WHEN the schemas are inspected
- THEN `reusable_link` is a required nullable object (`id` string, `label` nullable string) on
  the two admin participant resources and appears in no candidate, M2M or `/v1` schema

#### Scenario: Export drift is detected

- GIVEN `openapi.json` committed without the field
- WHEN the export-drift check runs
- THEN it fails until the export is regenerated

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
