# Delta for interview-session

## ADDED Requirements

### Requirement: POST /start question_context — total_competencies (interview-continuous-flow addendum)

`POST /api/candidate/interview/start` MUST include `total_competencies` as an additive,
non-null positive integer field in the `question_context` response object, alongside the
existing `end_phrase`, `final_phrase`, and `prompt_version` fields. `total_competencies`
MUST equal `ProjectCompetency::where('project_id', $projectId)->count()` for the
candidate's own project — the same count `POST /end` already computes to drive the
`in_valutazione` CAS. This is a backward-compatible addition; the five-endpoint contract,
the failure matrix, and all other `question_context` fields are unchanged.

#### Scenario: /start returns the real competency total

- GIVEN a project with 5 `project_competencies` rows
- WHEN `POST /start` returns `201`
- THEN `question_context.total_competencies` equals `5`

#### Scenario: total_competencies is stable across the interview

- GIVEN a project with 4 competencies
- WHEN `POST /start` is called for the 1st and later for the 3rd competency
- THEN `question_context.total_competencies` equals `4` on every call

#### Scenario: total_competencies never reflects another organization's project

- GIVEN org A's project has 5 competencies and org B's project has 3
- WHEN a candidate of org A calls `POST /start`
- THEN `total_competencies` equals `5`, never `3` — the count is scoped by the candidate's
  own tenant-scoped `project_id`

---

### Requirement: POST /end response body — next_action directive (interview-continuous-flow addendum)

`POST /api/candidate/interview/end` MUST return a JSON body on success — replacing
today's empty `response()->json(null, 200)` — carrying `ended_competencies` (int),
`total_competencies` (int), and `next_action` ∈ `{continue, pause, done}`. These values
MUST be derived from the SAME counters the base "POST /end" requirement's step 4 already
computes inside its explicit transaction — no new query.

`next_action` MUST be computed as:

| Condition | `next_action` |
|---|---|
| `ended_competencies === total_competencies` (last question) | `done` |
| Not done, AND `project.pause_every_n_competencies` is non-null AND `ended_competencies % pause_every_n_competencies === 0` | `pause` |
| Otherwise | `continue` |

`done` MUST take precedence over `pause`: a pause is never signalled on the final
competency, regardless of the modulo. A `null` `pause_every_n_competencies` MUST NEVER
produce `pause`.

`ended_reason = 'skipped'` remains a valid, accepted value for `POST /end` (Decision 1) —
this addendum does not remove or restrict the enum; only the paired `interview-frontend`
delta stops the candidate UI from ever producing it.

This is purely additive: HTTP 200 on success, the CAS single-winner semantics, the FIX-3
409 idempotency guard, and the FIX-11 422 rejection of a client-submitted
`ended_reason = 'error'` are all unchanged.

#### Scenario: next_action=continue when not due for a pause and not last

- GIVEN a project with `pause_every_n_competencies = 3` and 8 competencies; 1 of 8 just completed
- WHEN `POST /end` returns `200`
- THEN the body is `{ended_competencies: 1, total_competencies: 8, next_action: 'continue'}`

#### Scenario: next_action=pause on the scheduled competency

- GIVEN the same project; the 3rd of 8 competencies just completed
- WHEN `POST /end` returns `200`
- THEN `next_action = 'pause'`

#### Scenario: null pause_every_n_competencies never pauses

- GIVEN a project with `pause_every_n_competencies = null` and 8 competencies
- WHEN any non-final `POST /end` returns `200`
- THEN `next_action` is always `'continue'`, never `'pause'`

#### Scenario: done wins over a pause due on the same competency

- GIVEN a project with `pause_every_n_competencies = 4` and exactly 4 competencies
- WHEN the 4th (last) `POST /end` returns `200`
- THEN `next_action = 'done'`, not `'pause'`, even though `4 % 4 === 0`

#### Scenario: Response counters never leak another organization's project

- GIVEN org A's project has 8 competencies and org B's project has 5
- WHEN a candidate of org A calls `POST /end`
- THEN `total_competencies` in the response equals `8`; org B's counters never appear —
  the same `resolveOwnedSession` + tenant scoping already governing this endpoint

#### Scenario: ended_reason=skipped remains a valid, accepted value (Decision 1)

- GIVEN `POST /end` is called with `ended_reason = 'skipped'` (a historical or
  non-candidate path)
- WHEN validation runs
- THEN the request is accepted exactly as today; `skipped` is NOT removed from the enum

#### Scenario: The FIX-3 409 idempotency guard is unaffected

- GIVEN a session `S` already `completed`
- WHEN `POST /end` is called again for `S`
- THEN HTTP 409 is returned exactly as before; no counters are recomputed for the
  duplicate call

---

### Requirement: Bounded single re-offer of an `error` competency (Decisions 4 & 5)

A competency session that ends in `error` MUST be re-offered to the candidate exactly
once, and MUST be counted toward completion once that single re-offer is exhausted. This
requirement refines `resolveNextCompetency()`'s competency-selection rule for the `error`
status specifically — a case the base "POST /start" requirement's step 1 does not
otherwise address.

`resolveNextCompetency()` MUST treat a session at `status = 'error'` as follows:

- **First `error`** (no prior re-offer recorded): the competency IS selected again on the
  next `/start` for this participant, at its original `project_competencies.position`.
  Per the UNIQUE `(participant_id, competency_code)` constraint, this MUST reset the
  EXISTING row — never insert a second — mirroring
  `RecoverFailedParticipant` (`api/app/Actions/Participant/RecoverFailedParticipant.php:117-128`):
  `status` → `pending`, `provider_session_ref` / `ended_reason` / `ended_at` → `null`, and
  its `Utterance` rows DELETED (the same rule ratified at
  `participant-sso/spec.md:892-897`). The reset MUST persist a durable indicator that a
  re-offer has been consumed, surviving the reset to `pending` — a re-offered `pending`
  session MUST be distinguishable from a never-attempted one (the exact column/shape is a
  design decision, not specified here).
- **Second `error`** (a re-offer already consumed): the competency is TERMINAL. It is
  NEVER selected again, and its `error` status MUST be included in the completion count
  that step 4 of "POST /end" computes, alongside `{completed, timeout, skipped}` — so
  `ended_competencies` can reach `total_competencies` and `in_valutazione` remains
  reachable.

The utterance deletion at re-offer time MUST happen regardless of whether the failed
attempt's provider transcript was retrievable. This closes the case where a second attempt
against a still-degraded provider returns an empty transcript at `/end` time: because the
first attempt's `Utterance` rows are already deleted at re-offer time — not at `/end`
time — an empty-transcript `/end` on the second attempt cannot resurrect stale
first-attempt data via the existing `replaceUtterances()` empty-guard.

This requirement does NOT change how `resolveNextCompetency()` treats
`{completed, timeout, skipped}` rows, nor the reset already performed by
`RecoverFailedParticipant` for an operator-initiated recovery — both continue to resume,
not restart (`participant-sso/spec.md:909-914`, unaffected by this change).

Every reset performed under this requirement MUST be scoped to the requesting
participant's own `organization_id` and `participant_id`, exactly like every other
session-scoped mutation in this domain (`resolveOwnedSession`).

#### Scenario: A first-time error is re-offered, not skipped

- GIVEN a session for competency `COL` ends in `error` (first occurrence)
- WHEN the candidate calls `POST /start` again
- THEN `COL` is selected again at its original position; the SAME session row is reset to
  `pending` — no second row is created, respecting the UNIQUE constraint

#### Scenario: Re-offer deletes the first attempt's utterances

- GIVEN the errored `COL` session has 4 ingested `Utterance` rows
- WHEN the re-offer reset runs
- THEN all 4 `Utterance` rows for that session are deleted before the candidate re-attempts

#### Scenario: Re-offer closes the empty-transcript hole on the second attempt

- GIVEN `COL` was re-offered once (first-attempt utterances already deleted at reset time)
  and the second attempt's provider transcript comes back empty at `/end`
- WHEN `replaceUtterances()` exits early on the empty-transcript guard
- THEN no first-attempt utterances survive to be scored as the second attempt's answer —
  they were already removed at re-offer, not left for `/end` to clean up

#### Scenario: A second error is terminal and counts toward completion

- GIVEN `COL` was already re-offered once and ends in `error` again
- WHEN `resolveNextCompetency()` runs
- THEN `COL` is never selected again, its `status` remains `error`, and the `/end`
  completion count for this participant includes it

#### Scenario: An exhausted re-offer makes in_valutazione reachable

- GIVEN a project with 3 competencies; competency 2 has exhausted its single re-offer
  (terminal `error`); competencies 1 and 3 are `completed`
- WHEN the 3rd `/end` commits
- THEN `ended_competencies === total_competencies === 3`, the CAS transitions the
  participant to `in_valutazione`, and `FinalizeInterview` is dispatched exactly once

#### Scenario: A participant stranded before this change can now complete (regression)

- GIVEN a participant with an unresolved `error` session predating the bounded re-offer,
  currently unreachable for `in_valutazione`
- WHEN this requirement is applied and the participant's remaining flow runs to
  completion, including one re-offer of the stranded competency
- THEN the participant reaches `in_valutazione`

#### Scenario: The attempt bound is durable across the reset

- GIVEN a re-offered session sitting at `status = 'pending'`
- WHEN it is compared against a never-attempted `pending` session for a different
  competency
- THEN the two are distinguishable by the durable attempt indicator — `status` alone
  cannot tell them apart

#### Scenario: A re-offer reset never touches another organization's session

- GIVEN an `error` session belonging to org B
- WHEN a candidate of org A calls `POST /start`
- THEN org B's session is not read, reset, or otherwise mutated

#### Scenario: Operator recovery still resumes correctly after this change (regression)

- GIVEN a participant recovered via `POST /participants/{id}/recover`
  (`participant-sso/spec.md:884-921`) — its errored session reset by that action, not by
  this requirement
- WHEN the candidate re-enters and `resolveNextCompetency()` runs
- THEN the recovered competency is returned and no already-answered competency is
  re-asked — `participant-sso/spec.md:909-914` ("Resume, not restart") holds verbatim

---

## MODIFIED Requirements

### Requirement: InterviewSession tenant model — LOCKED status enum

The system MUST persist one `InterviewSession` row per competency attempt,
belonging to exactly one `Participant` and one `Organization`. The row MUST
carry: `question_index` (0-based ordinal, = `position - 1`), `competency_code`,
`framework_version_id` (copied from `project.framework_version_id` at creation time —
NEVER re-derived at read time), `status` ∈ `{pending, in_corso, completed, timeout, skipped, error}`
(default `pending`; `in_corso` after provider success), `provider` (string),
`provider_session_ref` (nullable), `ended_reason` (nullable) ∈ `{completed, timeout, skipped, error}`,
`started_at` / `ended_at` (timestampTz, nullable). The primary composite index
MUST lead with `organization_id`. The table MUST carry a UNIQUE constraint on
`(participant_id, competency_code)`.

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
(Previously: `error` was never counted as ended under any condition, which made completion
permanently unreachable for a participant whose only failure was never resolved.)

`errore` is a TERMINAL participant state: `$allowedTransitions['errore'] = []`.

#### Scenario: Row created on /start

- GIVEN a valid candidate JWT for org O and a project with competency PRS at position 1
- WHEN `POST /api/candidate/interview/start` is called
- THEN an `InterviewSession` row is persisted with `competency_code = 'PRS'`, `question_index = 0` (= position 1 - 1), `status = 'pending'` initially then `'in_corso'` after provider success, `organization_id = O`, `framework_version_id` copied from the project record, and a non-null `participant.started_at` (set via direct property assignment, NOT mass-assign)

#### Scenario: Tenant isolation at query level

- GIVEN sessions from org A and org B exist in the DB
- WHEN any query scoped to org A is executed
- THEN sessions belonging to org B are never returned (TenantScoped global scope)

---

### Requirement: POST /end — finalization, transcript REPLACE, and CAS last-question detection (CRITICAL-3 atomicity)

`POST /api/candidate/interview/end` MUST:

1. Accept `{ session_id, ended_reason }` where `ended_reason` ∈ `{completed, timeout, skipped}`.
   Resolve the session via `resolveOwnedSession($session_id)` → 404 if not owned.
   **FIX-11: `ended_reason = 'error'` MUST be explicitly rejected with HTTP 422** — `error` is a
   server-set value, never a valid client-submitted `ended_reason`. Validation MUST enumerate only
   `{completed, timeout, skipped}` as accepted values; any other value (including `'error'`) returns 422.
2. **Transcript reconciliation (HeyGen only — REPLACE semantics):** open an **EXPLICIT DB
   TRANSACTION** and acquire a `SELECT ... FOR UPDATE` lock on the session row.
   **FIX-3 — IDEMPOTENCY GUARD (inside the FOR UPDATE lock, before any mutation):**
   if `session.status !== 'in_corso'` → ROLLBACK → return **409 Conflict** (no-op; do NOT
   re-stamp `ended_at`; do NOT re-run the CAS; do NOT re-dispatch `FinalizeInterview`).
   This prevents a second `/end` call on an already-ended session from re-firing downstream steps.
   Within the same transaction (continuing only if status IS `in_corso`): DELETE all existing
   `Utterance` rows for the session and INSERT the server-authoritative transcript returned by
   the provider. The FOR UPDATE lock prevents a concurrent `/utterance` from interleaving between
   DELETE and INSERT. **Tavus:** keep live `/utterance` rows as-is (no reconciliation step), but
   still open the explicit transaction (and apply the status guard) for steps 3–4.
3. **[INSIDE THE SAME TRANSACTION]** Set `session.status = ended_reason`, `session.ended_at = now()`.
   The FOR UPDATE lock scope MUST cover this status UPDATE.
4. **[INSIDE THE SAME TRANSACTION]** Count ended sessions scoped to THIS participant AND THIS
   project, now ALSO including an `error` row whose single re-offer bound is exhausted
   (interview-continuous-flow addendum — see "Bounded single re-offer of an `error`
   competency"):
   `InterviewSession::where('participant_id', $pid)->where('project_id', $projectId)->where(fn ($q) => $q->whereIn('status', ['completed','timeout','skipped'])->orWhere(fn ($q2) => $q2->where('status', 'error')->{exhausted-re-offer condition}))->count()`.
   If count equals `ProjectCompetency::where('project_id', $projectId)->count()` (last question):
   perform an **ATOMIC CAS** on the participant:
   `$won = Participant::where('id', $pid)->where('status', 'in_corso')->update(['status' => 'in_valutazione']);`
   ONLY if `$won === 1`: dispatch `FinalizeInterview::dispatch($pid)->afterCommit();`
   — `afterCommit()` MUST be attached to THIS explicit transaction, ensuring the job is
   enqueued only after the transaction commits.
   If `$won === 0` (a concurrent `/end` already transitioned): skip dispatch — no double dispatch.
   **COMMIT** the explicit transaction.
   (Previously: the count strictly enumerated `{completed, timeout, skipped}` and excluded
   every `error` row unconditionally, which made completion unreachable for any participant
   whose sole re-offer had also failed.)
5. `FinalizeInterview` job MUST be idempotent (re-check participant status on execution;
   if already past `in_valutazione`, no-op) and MUST only emit the C9 scoring trigger
   (the `→in_valutazione` transition already happened via the CAS).
   **FIX-4 — retry-safe C9 trigger dedup:** the "already past `in_valutazione`" check does NOT
   protect against a failed+retried job emitting the C9 trigger while the participant is still
   `in_valutazione` (that is the expected state until C9 completes). The C9 trigger emission
   MUST use its own exactly-once dedup mechanism that survives Laravel queue retries:
   - **Redis sentinel (recommended):** before emitting the C9 trigger, atomically set a key
     `finalize:<participant_id>` using `SET ... NX` (set if not exists). Only if the key was
     newly set → emit the trigger. If the key already exists → no-op (retry detected).
     TTL must outlast the maximum job retry window.
   - **Persisted marker:** alternatively, set a `scoring_queued_at` column (or boolean) on the
     `Participant` row atomically (`UPDATE ... WHERE scoring_queued_at IS NULL`) before emitting.
     Only if 1 row was updated → emit; if 0 → no-op.
   Either option satisfies the invariant. The C9 consumer (out of C7a scope) must also be
   idempotent, but trigger-emission dedup is C7a's responsibility.
6. If NOT the last competency: leave `participant.status = 'in_corso'`.
7. Return HTTP 200, with the response body widened by the "POST /end response body —
   next_action directive" addendum above (`ended_competencies`, `total_competencies`,
   `next_action`); this requirement's own scope (transaction atomicity, CAS, idempotency)
   is otherwise unchanged.

**CRITICAL-3 atomicity guarantee:** steps 3 (session-status UPDATE), 4a (ended-count), and 4b
(last-question CAS) are wrapped in ONE explicit DB transaction opened in step 2. A crash BEFORE
commit rolls back the session-status update — the session remains `in_corso` and is resumable
(recoverable on retry). There is NO crash window between a committed status update and a missing
`FinalizeInterview` dispatch.

Last-question detection MUST be derived from `project_competencies` count scoped to BOTH
`participant_id` AND `project_id`. Each `Participant` belongs to exactly one project (a human
candidate in multiple projects gets a distinct `participant_id` per project, per C6), so
`participant_id` already implies project scope — the `project_id` filter is retained as a
denormalized safety guard. It MUST NOT use a counter field.

#### Scenario: Non-last question — participant stays in_corso

- GIVEN a project with 3 competencies; sessions for positions 1 and 2 are active; session for position 3 is still pending
- WHEN `POST /end` is called for position 2 with `ended_reason = 'completed'`
- THEN session.status = 'completed', participant.status remains 'in_corso', and FinalizeInterview is NOT dispatched

#### Scenario: Last question — FinalizeInterview dispatched exactly once

- GIVEN a project with K competencies; K-1 sessions already finalized; the K-th session is in_corso
- WHEN `POST /end` is called for the K-th session
- THEN session.status = 'completed', FinalizeInterview job is dispatched EXACTLY ONCE,
  and participant.status = 'in_valutazione'

#### Scenario: Concurrent /end does NOT double-dispatch FinalizeInterview

- GIVEN two concurrent `POST /end` requests arrive for the last question simultaneously
- WHEN both requests execute the CAS `Participant::where('status','in_corso')->update(...)`
- THEN exactly ONE request gets `$won === 1` and dispatches `FinalizeInterview`; the other
  gets `$won === 0` and skips dispatch — FinalizeInterview is dispatched at most once

#### Scenario: Timeout end reason

- GIVEN an active session
- WHEN `POST /end` is called with `ended_reason = 'timeout'`
- THEN session.status = 'timeout' and session.ended_at is set

#### Scenario: HeyGen transcript REPLACE at /end

- GIVEN an active HeyGen session with 2 locally ingested Utterance rows
- WHEN `POST /end` is called and the provider server transcript contains 5 utterances
- THEN ALL existing Utterance rows for the session are DELETED and the 5 server utterances
  are INSERTED (REPLACE, not dedup-merge); the session is marked completed

#### Scenario: Tavus transcript kept as-is at /end

- GIVEN an active Tavus session with live-ingested Utterance rows
- WHEN `POST /end` is called
- THEN existing Utterance rows are kept unchanged (no DELETE/INSERT reconciliation for Tavus)

#### Scenario: End on an already-ended session → 409 (FIX-3)

- GIVEN a session S with `status = 'completed'` (i.e. `/end` was already called successfully)
- WHEN `POST /end` is called again for session S with any valid `ended_reason`
- THEN HTTP 409 is returned; `session.ended_at` is NOT re-stamped; `FinalizeInterview` is NOT
  dispatched again; the participant status is NOT mutated

#### Scenario: Reject client-submitted ended_reason='error' → 422 (FIX-11)

- GIVEN an active session S with `status = 'in_corso'`
- WHEN `POST /end` is called with `ended_reason = 'error'`
- THEN HTTP 422 is returned (validation error); session status is NOT changed; no downstream
  mutation occurs. `'error'` is a server-set value and MUST NOT be accepted from the client.
