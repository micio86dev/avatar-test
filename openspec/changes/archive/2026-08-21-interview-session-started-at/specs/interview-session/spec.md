# Delta for Interview Session

## MODIFIED Requirements

### Requirement: InterviewSession tenant model — LOCKED status enum

The system MUST persist one `InterviewSession` row per competency attempt,
belonging to exactly one `Participant` and one `Organization`. The row MUST
carry: `question_index` (0-based ordinal; MUST equal `project_competencies.position`
of that session's competency within the session's project — never `position - 1`),
`competency_code`, `framework_version_id` (copied from `project.framework_version_id`
at creation time — NEVER re-derived at read time), `status` ∈
`{pending, in_corso, completed, timeout, skipped, error}` (default `pending`;
`in_corso` after provider success), `provider` (string), `provider_session_ref`
(nullable), `ended_reason` (nullable) ∈ `{completed, timeout, skipped, error}`,
`started_at` / `ended_at` (timestampTz, nullable). The primary composite index
MUST lead with `organization_id`. The table MUST carry a UNIQUE constraint on
`(participant_id, competency_code)`.

The first competency of a project (`position = 0`) MUST therefore persist
`question_index = 0`, never a negative value.
(Previously: `question_index` was defined as `position - 1` against a `position`
column described as 1-based. `position` has always been 0-based at every writer,
so the subtraction produced `-1` for the first competency of every project.)

A session's recorded start MUST be set only at the moment it first becomes
live — the `in_corso` transition — never at row creation. A session that
never leaves `pending` consumed no provider time and MUST NOT record a
start; it remains absent, never `0` or any other placeholder.
(Previously: `started_at` was declared nullable and server-set, but no
requirement stated WHEN it is written. The real interview path never wrote
it at either `in_corso` site, so every production session recorded an
interval with no beginning.)

**WARNING-8 — UNIQUE constraint domain:** each `Participant` row belongs to exactly ONE project
(a human candidate participating in multiple projects gets a distinct `participant_id` per project,
per C6). Therefore `UNIQUE(participant_id, competency_code)` is correct and sufficient; adding
`project_id` would be redundant. The `project_id` column on `interview_sessions` is retained as a
denormalized convenience for query scoping (and kept in the ended-count query as a safety guard),
but it does NOT belong in the UNIQUE index.

**INFO — `project_id` FK cascade policy (FIX-9: corrected rationale):** The
`interview_sessions.project_id` foreign key uses `restrictOnDelete` as belt-and-suspenders
against accidental hard-deletes of a project row. This FK policy does NOT protect against
project SOFT-deletes and was never intended to. Laravel `SoftDeletes` executes an UPDATE
(`deleted_at = now()`), not a SQL DELETE — so the FK constraint is never triggered by a
soft-delete. Session records survive a project soft-delete automatically because no SQL DELETE
fires. The `restrictOnDelete` is a correctness guard only for hard-delete scenarios, which are
blocked at the application layer but may occur in tests or emergency operations. Hard-delete of
a project is blocked at the application layer.

**LOCKED enum values (do NOT use "active" or "ended" as status values):**

| Value | Meaning |
|---|---|
| `pending` | Row created; provider call not yet made (also: a re-offered session, reset from `error`) |
| `in_corso` | Provider session successfully issued; interview is live |
| `completed` | Ended normally (`ended_reason = 'completed'`) |
| `timeout` | Ended by time-out (`ended_reason = 'timeout'`) |
| `skipped` | Ended by skip (`ended_reason = 'skipped'`) — historical/non-candidate paths only (Decision 1) |
| `error` | Provider hard-failure (`ended_reason = 'error'`) |

"Ended" for last-question count = `status ∈ {completed, timeout, skipped}`, PLUS a
`status = 'error'` row whose single re-offer bound (Decisions 4 & 5 — see "Bounded single
re-offer of an `error` competency") is exhausted. A first-occurrence `error` — one still
eligible for re-offer — is NOT counted as ended; it does not yet consume a competency slot.

`errore` is a TERMINAL participant state: `$allowedTransitions['errore'] = []`.

#### Scenario: Row created on /start

- GIVEN a valid candidate JWT for org O and a project with competency PRS at
  `position = 0` (the project's first competency)
- WHEN `POST /api/candidate/interview/start` is called
- THEN an `InterviewSession` row is persisted with `competency_code = 'PRS'`,
  `question_index = 0` (equal to `position`, not negative), `status = 'pending'`
  initially with no recorded start, then `'in_corso'` after provider success
  with its start recorded at that moment (never at insertion), `organization_id = O`,
  `framework_version_id` copied from the project record, and a non-null
  `participant.started_at` (set via direct property assignment, NOT mass-assign)

#### Scenario: First competency's question_index is never negative

- GIVEN a project whose first competency (PRS) is at `position = 0` and has no
  prior session for this participant
- WHEN `POST /start` resolves and persists that competency's session
- THEN `question_index` is persisted as `0`, never `-1`

#### Scenario: A session that never leaves pending records no start

- GIVEN a `POST /start` call whose provider request fails before any session
  reaches `in_corso` (e.g. a `429 provider_busy`, leaving the row `pending`)
- WHEN that session's recorded start is read
- THEN it is absent — never a timestamp and never `0`

#### Scenario: Tenant isolation at query level

- GIVEN sessions from org A and org B exist in the DB
- WHEN any query scoped to org A is executed
- THEN sessions belonging to org B are never returned (TenantScoped global scope)

### Requirement: Session cost is derived from stored timings, not recorded

The system MUST derive an avatar-provider cost estimate for a session from its
RECORDED LIVE DURATION — the sum of every closed `interview_session_live_periods`
row — and a configured per-provider rate, with the rates overridable by
environment without a code change.
(Previously: this requirement derived cost from the `started_at`/`ended_at`
DURATION — the wall-clock span. That span may include an abandonment gap
across a resume and is no longer read as a duration anywhere; see "Recorded
duration is accumulated live time, not wall-clock span" below. Archive
hygiene: this wording supersedes the archived spec's phrasing so it does not
teach the span again — the exact "the comment outlived the defect" failure
already paid for once on `question_index`.)

The estimate MUST NOT be persisted on the session. Rates change, and a stored
figure computed under an old rate becomes a number nobody can reproduce or
explain; deriving it at read time keeps the calculation inspectable.

Neither supported provider exposes a per-session billed amount through an API,
so the value MUST be treated and labelled as an estimate everywhere it surfaces.

The configured defaults are RATIFIED (2026-08-13): BEAI and `quint-avatar-tester`
run on the same provider accounts and API keys, so the same contracts apply —
HeyGen 2 credits/min at $0.10/credit, Tavus $0.37/min. This ratifies the RATE,
not the reconciliation: a correct rate on a measured duration is still not an
invoice line. The values stay env-overridable so a plan change is a config
change, not a release.

#### Scenario: Cost follows the configured rate

- GIVEN a session with a known recorded live duration and a configured
  provider rate
- WHEN its review is read
- THEN the returned estimate equals that recorded live duration × rate for
  that provider

#### Scenario: An unfinished session has no cost estimate

- GIVEN a session with no closed live period
- WHEN its review is read
- THEN the estimate is absent rather than computed from a partial duration

## ADDED Requirements

### Requirement: A live session records when it became live, at both sites that grant it

`POST /api/candidate/interview/start` MUST record when a session becomes
live at BOTH sites where the base "POST /start" requirement's step 4 flips a
session to `in_corso`: the plain issue-pending case, and the RESUME case (the
"Resume existing in_corso session" scenario, which issues a fresh provider
session for a row that already carries a prior live stretch). This is an
addition to step 4's existing writes, not a change to the failure matrix,
the RESUME token/teardown behavior, or any other write already specified
there.

#### Scenario: The plain issue-pending case records a start

- GIVEN a session with no prior live stretch
- WHEN `POST /start` succeeds and the session flips to `in_corso`
- THEN that moment is recorded as part of the session's live time

#### Scenario: A resume records a new stretch beginning, not a reset

- GIVEN a session already carries a recorded live stretch from a prior
  `in_corso` period
- WHEN `POST /start` resumes it — issuing a fresh provider session per the
  existing RESUME scenario — THEN the moment of the fresh `in_corso` is
  recorded as the start of a NEW live stretch; the prior stretch's record is
  preserved, not overwritten

### Requirement: Recorded duration is accumulated live time, not wall-clock span

A session's recorded duration MUST equal the sum of the time it spent live
with a provider, across every stretch a resume may produce, and MUST NOT
include any interval during which the session held no live provider
session. Neither leaving the original stretch's boundary open (which would
span an abandonment gap) nor discarding a completed stretch on resume
(which would erase billed time) satisfies this requirement.

The system CANNOT observe the exact moment an abandoned stretch's provider
session stopped being live — no signal exists between the candidate's last
activity and the next request the system receives, which may be hours
later. A stretch that is still open when a resume or an error is detected
MUST therefore close at the LESSER of the moment of detection and the
provider's own contractual session ceiling (per-provider, or a lower value
if the organization's active configuration set one for that provider) —
never at raw detection time alone, which would record a span that could not
physically have occurred as billed time. A stretch that closes normally,
well inside that ceiling, MUST record its real observed duration
unchanged — the ceiling is a bound on the pathological case, never a floor
applied to an ordinary one.

A stretch whose recorded length equals the provider ceiling is therefore a
disclosed UPPER ESTIMATE of an abandoned interval, not a claim that the
candidate was observed active for that whole span.

#### Scenario: Two live stretches sum; the gap between them does not, and the abandoned stretch is capped at the provider's ceiling

- GIVEN a session live for 4 minutes, then abandoned for 3 hours with no
  live provider session, then resumed and live for 6 more minutes before
  ending
- WHEN the session's recorded duration is read
- THEN it equals the resolved provider ceiling for the first (abandoned)
  stretch plus 6 minutes for the second — never approximately 3 hours 10
  minutes (the full gap counted at raw detection time), and never 6 minutes
  (the first stretch discarded entirely)

#### Scenario: A stretch closed well inside the provider ceiling records its real duration, uncapped

- GIVEN a session live for 7 minutes, then ended normally through `/end`,
  with the provider's ceiling far larger than 7 minutes
- WHEN the session's recorded duration is read
- THEN it equals exactly 7 minutes — the ceiling never inflates a stretch
  that closed on its own before ever approaching it

#### Scenario: An interval with no live provider session is never counted

- GIVEN a session with a completed first stretch and a not-yet-started
  second stretch (candidate has not resumed yet)
- WHEN the recorded duration is read at that moment
- THEN it equals exactly the first stretch's length — the elapsed gap since
  it ended contributes nothing

### Requirement: An absent recorded duration is never coerced to zero

A session that never became live carries no recorded duration, and this
absence MUST be observable as absent by every consumer — never rendered or
computed as `0`. This mirrors the already-shipped rule that a participant's
total elapsed time is absent, not zero, when no session contributes a
duration (`admin-read-api` — "Participant Detail Summary Fields").

#### Scenario: An unstarted session's duration is absent, not zero

- GIVEN a session with `status = 'pending'` that never became live
- WHEN any consumer (cost estimate, elapsed-time aggregation, session
  review) reads its recorded duration
- THEN the value is absent — never `0`

### Requirement: Ordering by recorded start remains deterministic when the value is absent

Any ordering of `InterviewSession` rows by their recorded start MUST remain
deterministic even when some or all rows have no recorded start. Rows with
an absent value MUST fall back to a stable secondary key — the row's own
identifier — so repeated reads of the same data return the same order.

#### Scenario: Sessions with no recorded start remain in a stable order

- GIVEN two sessions that never became live, both with an absent recorded
  start
- WHEN they are ordered by recorded start
- THEN their relative order is identical across repeated reads

#### Scenario: A mix of recorded and absent starts orders deterministically

- GIVEN three sessions — two with a recorded start, one absent
- WHEN they are ordered by recorded start
- THEN the result is fully deterministic across repeated reads, with the
  absent-start row's position fixed by the identifier tiebreaker

### Requirement: Test fixtures must not synthesize a start production would not write

Any factory or fixture that builds an `InterviewSession` row MUST agree with
the production write path: it MUST NOT default a recorded start for a
`pending` (never-live) session, and MUST only supply one for a session
whose fixture also reflects having gone live. A fixture-provided default
MUST NOT be the reason a test asserting duration, cost, or ordering passes
independently of the code path that actually records a start.

#### Scenario: A factory-built pending session has no recorded start

- GIVEN a test builds an `InterviewSession` via its factory in the default
  `pending` state
- WHEN the built row is inspected
- THEN it carries no recorded start, matching production

#### Scenario: A duration assertion cannot pass on the fixture default alone

- GIVEN a test asserts a session's duration, cost, or start-ordering
- WHEN that session was never taken through the `in_corso` transition
- THEN the assertion cannot be satisfied by a fixture-injected start value;
  it MUST exercise the transition that actually records one
