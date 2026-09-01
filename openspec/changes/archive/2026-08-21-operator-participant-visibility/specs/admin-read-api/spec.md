# Delta for Admin Read API

## MODIFIED Requirements

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

(Previously: Transcript required lifecycle ≥ `in_valutazione`; `errore` was
denied outright as a status absent from the ordered progression list.)

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

## ADDED Requirements

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
