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
  initially then `'in_corso'` after provider success, `organization_id = O`,
  `framework_version_id` copied from the project record, and a non-null
  `participant.started_at` (set via direct property assignment, NOT mass-assign)

#### Scenario: First competency's question_index is never negative

- GIVEN a project whose first competency (PRS) is at `position = 0` and has no
  prior session for this participant
- WHEN `POST /start` resolves and persists that competency's session
- THEN `question_index` is persisted as `0`, never `-1`

#### Scenario: Tenant isolation at query level

- GIVEN sessions from org A and org B exist in the DB
- WHEN any query scoped to org A is executed
- THEN sessions belonging to org B are never returned (TenantScoped global scope)

---

### Requirement: POST /start — session creation, duplicate prevention, and provider token issuance

`POST /api/candidate/interview/start` MUST:

1. Resolve the next competency from `project_competencies.position` ASC: the lowest
   position whose `InterviewSession` for this participant is ABSENT or whose status is
   NOT in `{completed, timeout, skipped}`. A session with `status = pending | in_corso`
   → RESUME it (return the existing session; do NOT create a duplicate). The UNIQUE
   constraint on `(participant_id, competency_code)` enforces idempotency at the DB
   level: a unique-violation means a session already exists → RESUME that session.
   **WARNING-7 (concurrent double /start):** if two concurrent `/start` requests race,
   the second INSERT will raise `Illuminate\Database\UniqueConstraintViolationException`
   (SQLSTATE 23505). The implementation MUST catch this exception and recover by
   re-querying the existing session (→ RESUME path), NOT surface it as a 500.
2. INSERT `InterviewSession(status='pending', question_index = position,
   framework_version_id copied from project, ...)` in a SHORT DB transaction.
   `question_index` MUST equal `project_competencies.position` for that competency —
   never `position - 1`.
   (Previously: `question_index = position - 1`, which produced `-1` for a project's
   first competency because `position` is 0-based, not 1-based.)
3. Call the configured provider (HeyGen or Tavus) REST API server-side using secret
   keys stored only in environment/config — NEVER returned to the client.
   **The provider HTTP call (`ProviderSessionService.issue()`) MUST be outside any DB
   transaction.** Holding a DB transaction open across a network call risks connection
   starvation and deadlock.
4. On provider SUCCESS: wrap BOTH of the following writes in ONE short DB transaction (FIX-8):
   - UPDATE session `status='in_corso'`, `provider_session_ref`.
   - On the **first** competency (`position = 0`, i.e. `participant.status = 'in_attesa'`):
     set `participant.started_at` via **direct property assignment** (NOT mass-assign,
     because `started_at` is NOT in `$fillable`): `$p->started_at = now(); $p->status = 'in_corso'; $p->save();`
   **FIX-8 rationale:** without a surrounding transaction, a failure between the two writes leaves
   the session `in_corso` but the participant `in_attesa` (inconsistent state). Wrapping both
   writes in ONE atomic short transaction ensures they commit or roll back together. On rollback,
   the session reverts to `pending` and is resumable via the RESUME-pending path on next `/start`.
   The step-4d compensation (teardown + 500) covers failure of EITHER write inside this transaction.
5. Return HTTP **201** with `{ session_id, provider, provider_token|conversation_url, question_context }`.

The response body MUST NOT contain any provider API secret key.

**Failure matrix:**

| Failure | Status | Participant | HTTP |
|---|---|---|---|
| Provider 5xx / timeout (hard-failure) | `status='error'`, `ended_reason='error'` | → `errore` (if not already terminal) | 502 |
| Provider 429 / concurrency (retryable) | `status='pending'` (or delete row) | NO transition to `errore` | 429 `{ error: 'provider_busy' }` |
| DB failure AFTER provider success | `teardown(token)` provider session to avoid orphan — pass the in-memory `ProviderToken` returned by `issue()` directly (WARNING-6: the ref may not yet be persisted; do NOT use `$session->provider_session_ref` — null ref → silent no-op → orphaned provider session; do NOT pass a raw string — teardown() only accepts a ProviderToken) | — | 500 |

Note: the `teardown()` call on DB-failure may itself fail (network); log the teardown
failure for manual cleanup. Do NOT suppress the original DB error.

#### Scenario: First question — in_attesa → in_corso

- GIVEN participant.status = 'in_attesa' and the project has 3 competencies
- WHEN `POST /start` is called
- THEN HTTP 201 is returned, `participant.status` = 'in_corso', `participant.started_at` is set
  (via direct property assignment), and the response body contains `session_id` and
  `provider_token` (or `conversation_url`) but NOT a secret key

#### Scenario: Second question — status unchanged

- GIVEN participant.status = 'in_corso' (first competency already finished)
- WHEN `POST /start` is called for the second competency
- THEN HTTP 201 is returned and `participant.status` remains 'in_corso' (no redundant transition)

#### Scenario: Resume existing in_corso session — fresh token issued, old session torn down (CRITICAL-2 + FIX-1)

- GIVEN a session for competency PRS exists with `status = 'in_corso'` for this participant
  (e.g. candidate reconnected after a network drop or browser refresh)
- WHEN `POST /start` is called again
- THEN HTTP 201 is returned with the EXISTING session (no duplicate row created; UNIQUE
  constraint on (participant_id, competency_code) enforces this), AND:
  (a) A FRESH provider token is issued (re-calling `ProviderSessionService.issue()`) — NOT
      the stale stored `provider_session_ref`. The response contains a currently-valid token.
  (b) The OLD provider session referenced by the currently-persisted `provider_session_ref`
      IS TORN DOWN (best-effort `ProviderSessionService.teardown()` called with
      `ProviderToken::fromRef($session->provider, $session->provider_session_ref)` — teardown()
      always takes a ProviderToken, never a raw string; fromRef() wraps the persisted ref +
      provider name into a typed token so teardown routes to the correct provider client (F1)).
      A teardown failure is logged but non-fatal — the candidate needs the fresh session.
  (c) The session row is updated with the NEW `provider_session_ref`.
  This prevents leaking a billable HeyGen session-minute or Tavus concurrency slot on reconnect.
  NOTE: the teardown in this RESUME path wraps the OLD persisted ref via ProviderToken::fromRef()
  — this is DISTINCT from the step-4d compensation teardown which passes the NEW in-memory
  ProviderToken directly from issue() (WARNING-6). teardown() always takes a ProviderToken.

#### Scenario: Resume pending session (prior 429 left no token) — fresh token issued (CRITICAL-2)

- GIVEN a session for competency PRS exists with `status = 'pending'` and no `provider_session_ref`
  (e.g. a prior `/start` returned 429 `provider_busy` and left the session tokenless)
- WHEN `POST /start` is called again
- THEN `ProviderSessionService.issue()` is retried; on success: `provider_session_ref` is
  persisted, `status` is flipped to `'in_corso'`, and HTTP 201 is returned with a fresh token.
  The failure matrix is identical to the create path (provider 429 → `provider_busy` NOT →errore;
  provider 5xx → →errore + 502; DB failure → teardown + 500).

#### Scenario: Provider hard-failure → 502 and errore

- GIVEN `Http::fake` returns a 503 for the provider endpoint
- WHEN `POST /start` is called
- THEN HTTP 502 is returned, session `status = 'error'`, and `participant.status = 'errore'`

#### Scenario: Provider 429 → retryable, participant NOT marked errore

- GIVEN `Http::fake` returns a 429 for the provider endpoint
- WHEN `POST /start` is called
- THEN HTTP 429 is returned with `{ "error": "provider_busy" }`, session remains
  `status = 'pending'`, and `participant.status` is NOT transitioned to `'errore'`

#### Scenario: DB failure after provider success → teardown + 500

- GIVEN the provider returns success but the subsequent DB UPDATE fails
- WHEN `POST /start` is called
- THEN `ProviderSessionService.teardown()` is called to release the provider session,
  and HTTP 500 is returned

#### Scenario: Provider selected via env

- GIVEN `INTERVIEW_PROVIDER=heygen` in environment config
- WHEN `POST /start` is called
- THEN the session `provider` field = 'heygen' and the HeyGen REST API is called for the token

#### Scenario: Provider overridden at project level (FIX-6: canonical column = `provider_override`)

- GIVEN the project record carries `provider_override = 'tavus'` (nullable additive column;
  falls back to env `INTERVIEW_PROVIDER` when null — FIX-6: `provider_override` is the
  canonical column name, not `provider`, to avoid collision with future non-override semantics)
- WHEN `POST /start` is called
- THEN the session `provider` field = 'tavus' and the Tavus REST API is called

#### Scenario: Concurrent double /start recovers via RESUME (WARNING-7)

- GIVEN no existing session for competency PRS for this participant
- WHEN two concurrent `POST /start` requests race and the second INSERT hits the
  UNIQUE(participant_id, competency_code) constraint
- THEN `UniqueConstraintViolationException` (23505) is caught; the second request
  re-queries the existing session and proceeds as a RESUME — HTTP 201 is returned;
  no 500 is surfaced

#### Scenario: No unstarted competency remaining

- GIVEN all competencies for the project have sessions with status ∈ {completed, timeout, skipped}
- WHEN `POST /start` is called
- THEN the response is HTTP 422 (no next competency available)

---

### Requirement: Competency sessions created in project_competencies.position order

`POST /start` MUST select the lowest `position` value among project competencies
that do not yet have a finalized `InterviewSession` for this participant. The order
is fixed and deterministic. Selection order MUST NOT be affected by the `question_index`
correction — `question_index` is a label persisted on the selected row, not an input
to selection.

#### Scenario: Third /start creates third-position competency

- GIVEN a project with competencies [PRS@0, STG@1, INN@2]; sessions for positions 0
  and 1 are finalized
- WHEN `POST /start` is called
- THEN the new session has `competency_code = 'INN'` and `question_index = 2`
  (equal to `position`)
  (Previously: described as `= position 3 - 1` against a 1-based `position` that
  never existed.)

#### Scenario: Delivery and read order is unchanged by the question_index correction

- GIVEN a participant with 3 finalized sessions, ordered by `question_index` today
- WHEN the same sessions are read after the corrected `question_index` values are
  in place
- THEN they are returned in the identical relative order — the correction is a
  monotonic relabeling, not a reordering

---

## ADDED Requirements

### Requirement: question_index backfill recomputes from position and never shifts

Any migration or maintenance process that corrects a persisted `question_index` MUST
recompute the value from that session's competency's current
`project_competencies.position` — joined by project and competency — and MUST NOT
apply a uniform arithmetic shift (e.g. `+1`) to the existing column. A row whose
`question_index` already equals its competency's `position` MUST be left
byte-identical: no column on that row changes value, including timestamps. Running
the process a second time MUST change nothing.

#### Scenario: An already-correct row is left untouched

- GIVEN an `InterviewSession` row whose `question_index` already equals its
  competency's `project_competencies.position`
- WHEN the backfill process runs
- THEN every column on that row, including `updated_at`, is unchanged

#### Scenario: An incorrect row is corrected to the current position

- GIVEN an `InterviewSession` row whose `question_index` is `-1` for a competency
  now at `position = 0`
- WHEN the backfill process runs
- THEN the row's `question_index` becomes `0`

#### Scenario: Running the backfill twice changes nothing on the second run

- GIVEN the backfill process has already run once against the full dataset
- WHEN it is run again
- THEN no row's `question_index` changes on the second run

### Requirement: Downstream question numbering derived from question_index starts at 1

Any consumer that renders a 1-based question number from `question_index` (e.g. a
transcript download) MUST render `1` for the first competency of a project, because
`question_index = 0` for that competency after the correction. This is a consequence
of the corrected value, not a new consumer-side rule.

#### Scenario: Transcript download numbers the first competency as 1

- GIVEN a participant whose first competency's session has `question_index = 0`
- WHEN the transcript download renders that competency's question number
- THEN it prints question `1`, never `0`
