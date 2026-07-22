# Interview Session Specification

## Purpose

Defines the backend interview-session mechanics for C7a: tenant-scoped data
models, five candidate-facing endpoints, server-side provider token issuance,
and the `in_attesa → in_corso → in_valutazione` participant lifecycle transitions.
One session = one competency, delivered in fixed `project_competencies.position`
order. Adaptivity (C8), BARS scoring (C9), and the Nuxt avatar UI (C7b) are
explicitly out of scope.

---

## Non-Goals

- Frontend / avatar UI / browser gate (C7b)
- Proctoring **detection** (MediaPipe / WebAudio) — C7b; C7a only **ingests**
- Adaptive question selection or AI follow-ups (C8)
- BARS scoring, `summarizeIntegrity()`, `in_valutazione → completato` gate (C9)
- Outbound webhooks (C10); dashboards / review panels (C11)
- GDPR media retention / S3 TTL (open decision #2, flagged for C13)
- `pause_every_n_competencies` UX gate (C7b)

---

## Data Model Requirements

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
| `pending` | Row created; provider call not yet made |
| `in_corso` | Provider session successfully issued; interview is live |
| `completed` | Ended normally (`ended_reason = 'completed'`) |
| `timeout` | Ended by time-out (`ended_reason = 'timeout'`) |
| `skipped` | Ended by skip (`ended_reason = 'skipped'`) |
| `error` | Provider hard-failure (`ended_reason = 'error'`) |

"Ended" for last-question count = `status ∈ {completed, timeout, skipped}`. Status `error`
is NOT counted as ended — a failed session does not consume a competency slot.

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

### Requirement: Utterance, IntegrityEvent, InterviewSnapshot tenant models

The system MUST persist `Utterance` (speaker, text, ts), `IntegrityEvent` (kind,
payload jsonb, ts), and `InterviewSnapshot` (s3_key, taken_at) rows, each
belonging to exactly one `InterviewSession` and inheriting `organization_id`.
All three MUST use org_id-first composite indexes.

#### Scenario: Utterance linked to session

- GIVEN an active session S in org O
- WHEN `POST /utterance` submits `{speaker, text, ts}`
- THEN an `Utterance` row is persisted with `interview_session_id = S` and `organization_id = O`

---

## Endpoint Requirements

### Requirement: Status guard — block terminal participants (FIX-7: nested sub-route scope only)

All five `/api/candidate/interview/*` endpoints MUST be protected by a
`ParticipantStatusGuard` middleware. If `participant.status` ∈ `{completato, errore}`,
the middleware MUST return HTTP 403 before any controller logic executes.

**FIX-7 — route scope:** the guard MUST be applied ONLY to the 5 interview sub-routes
(`/start`, `/end`, `/utterance`, `/integrity`, `/snapshot`) in a NESTED route group inside
the C6 candidate route group. It MUST NOT be applied to the parent C6 route group itself —
doing so would 403 a terminal candidate calling `GET /api/candidate/session` (a read
endpoint that is reasonable to allow even after completion).

#### Scenario: Guard blocks completato participant

- GIVEN a candidate whose `participant.status = 'completato'`
- WHEN they call any `/api/candidate/interview/*` endpoint
- THEN the response is HTTP 403 and no DB mutation occurs

#### Scenario: Guard allows in_attesa participant

- GIVEN a candidate whose `participant.status = 'in_attesa'`
- WHEN they call `POST /start`
- THEN the guard passes and the controller executes normally

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
2. INSERT `InterviewSession(status='pending', question_index = position - 1,
   framework_version_id copied from project, ...)` in a SHORT DB transaction.
3. Call the configured provider (HeyGen or Tavus) REST API server-side using secret
   keys stored only in environment/config — NEVER returned to the client.
   **The provider HTTP call (`ProviderSessionService.issue()`) MUST be outside any DB
   transaction.** Holding a DB transaction open across a network call risks connection
   starvation and deadlock.
4. On provider SUCCESS: wrap BOTH of the following writes in ONE short DB transaction (FIX-8):
   - UPDATE session `status='in_corso'`, `provider_session_ref`.
   - On the **first** competency (position = 1, i.e. `participant.status = 'in_attesa'`):
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

### Requirement: POST /start question_context — localized completion phrases (C7b addendum)

`POST /api/candidate/interview/start` MUST include `end_phrase` and `final_phrase` fields
in the `question_context` response object. Both strings MUST be the completion-signal
phrases the avatar will speak at the end of an intermediate question and at the end of the
final question, respectively, localized to the project language. The frontend consumes
these fields as the SOLE source for completion-signal detection; it MUST NOT contain
hardcoded phrase strings. If the project language is unavailable for a phrase, the backend
MUST fall back to the platform default language and MUST include the fallback phrase in the
response (an absent field is a contract violation).

This addendum is a backward-compatible addition to the existing `/start` response shape.
The five-endpoint contract and all other `question_context` fields are unchanged.
`POST /end` continues to return `200` on success — there is NO `203` variant. Last-competency
detection is performed client-side by the frontend (tracking `question_index` against the
total competency count from the C6 bootstrap); the backend does not signal "last question"
via a distinct HTTP status.

**Frontend consumption contract:** `end_phrase` and `final_phrase` are NESTED inside
`question_context` — they are NOT top-level fields of the `/start` response. The frontend
MUST destructure as `response.question_context.end_phrase` / `response.question_context.final_phrase`.
Reading from the top level returns `undefined` and triggers the absent-phrase terminal guard.
BOTH fields must be non-empty; an absent or empty value causes the HeyGen provider to emit an
`error` event immediately (a terminal, non-retryable condition).

**Delivery note:** this requirement was merged to `api/develop` as a C7a follow-up PR (#10)
before C7b apply. The `openapi.json` and `types/api.ts` in the frontend were regenerated
from the merged api/develop to include these fields.

#### Scenario: /start returns end_phrase in project language (it)

- GIVEN a project with `language = 'it'`
- WHEN `POST /start` returns `201`
- THEN `question_context.end_phrase` is a non-empty string in Italian (the inter-question
  completion phrase) and `question_context.final_phrase` is a non-empty string in Italian
  (the closing thank-you phrase)

#### Scenario: /start returns end_phrase in project language (en)

- GIVEN a project with `language = 'en'`
- WHEN `POST /start` returns `201`
- THEN `question_context.end_phrase` and `question_context.final_phrase` are non-empty
  English strings; no Italian phrase is present in either field

#### Scenario: end_phrase and final_phrase are never absent

- GIVEN any valid project language
- WHEN `POST /start` returns `201`
- THEN `question_context.end_phrase` and `question_context.final_phrase` are both present
  and non-null in the response body

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
4. **[INSIDE THE SAME TRANSACTION]** Count ended sessions scoped to THIS participant AND THIS project:
   `InterviewSession::where('participant_id', $pid)->where('project_id', $projectId)->whereIn('status', ['completed','timeout','skipped'])->count()`.
   If count equals `ProjectCompetency::where('project_id', $projectId)->count()` (last question):
   perform an **ATOMIC CAS** on the participant:
   `$won = Participant::where('id', $pid)->where('status', 'in_corso')->update(['status' => 'in_valutazione']);`
   ONLY if `$won === 1`: dispatch `FinalizeInterview::dispatch($pid)->afterCommit();`
   — `afterCommit()` MUST be attached to THIS explicit transaction, ensuring the job is
   enqueued only after the transaction commits.
   If `$won === 0` (a concurrent `/end` already transitioned): skip dispatch — no double dispatch.
   **COMMIT** the explicit transaction.
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
7. Return HTTP 200.

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

---

### Requirement: POST /utterance — best-effort live transcript ingestion

`POST /api/candidate/interview/utterance` MUST accept `{ session_id, speaker, text, ts }` and persist an `Utterance` row linked to the specified session. The endpoint MUST return HTTP 202 on success (session is `in_corso` at insertion time); MUST return HTTP 409 when the session is no longer `in_corso` (utterance atomically dropped, 0 rows inserted). It MUST NOT block the interview flow on failure.

**WARNING-5 / FIX-2 — TOCTOU window — ATOMIC guard required:**
A plain `SELECT + check status` followed by a separate `INSERT` is a TOCTOU race: a
concurrent `/end` can commit `completed` between the check and the INSERT (open for both
HeyGen and Tavus — the HeyGen `/end` FOR UPDATE lock does NOT block `/utterance`'s
plain SELECT). The status guard MUST be ATOMIC.

Required: use a conditional insert pattern (e.g. `INSERT ... WHERE EXISTS (SELECT 1 FROM
interview_sessions WHERE id = ? AND status = 'in_corso')`) OR acquire `SELECT ... FOR SHARE`
inside a short transaction and re-check before inserting. Do NOT use plain check-then-insert.

Response contract (CANONICAL):
- An utterance arriving when the session is no longer `in_corso` is atomically dropped (0 rows
  inserted) and the endpoint MUST return **409 Conflict** WITHOUT throwing.
- Do NOT return 202 for a dropped utterance (misleading). Do NOT throw 500 (user-visible error
  for a best-effort endpoint). 409 is the single canonical signal; the client treats it as no-op.

#### Scenario: Valid utterance ingested

- GIVEN a session S owned by the authenticated candidate with `status = 'in_corso'`
- WHEN `POST /utterance` is called with valid fields
- THEN HTTP 202 is returned and an Utterance row is persisted

#### Scenario: Utterance rejected into completed session (WARNING-5)

- GIVEN a session S owned by the authenticated candidate with `status = 'completed'`
  (i.e. `/end` was already called)
- WHEN `POST /utterance` is called
- THEN HTTP 409 is returned and no Utterance row is persisted

#### Scenario: session_id belongs to another candidate

- GIVEN session S2 belonging to candidate B
- WHEN candidate A calls `POST /utterance` with `session_id = S2`
- THEN HTTP 404 is returned and no Utterance is persisted

---

### Requirement: POST /integrity — batch integrity-event ingestion

`POST /api/candidate/interview/integrity` MUST accept `{ session_id, events: [{kind, payload, ts}] }`. Each `kind` MUST be validated against the 13 canonical types from `proctor-config.ts`: `tab_hidden`, `focus_lost`, `second_monitor`, `face_absent`, `looking_away`, `looking_down`, `too_far`, `multiple_faces`, `fullscreen_exit`, `clipboard_copy`, `clipboard_paste`, `second_voice`, `phone_detected`. An unknown `kind` MUST return HTTP 422. Valid events MUST be persisted as `IntegrityEvent` rows. Returns HTTP 202 on success.

#### Scenario: Valid integrity events ingested

- GIVEN an active session and a batch of 3 events with valid kinds
- WHEN `POST /integrity` is called
- THEN HTTP 202 is returned and 3 IntegrityEvent rows are persisted with correct `kind`, `payload`, `ts`

#### Scenario: Unknown integrity kind rejected

- GIVEN an active session
- WHEN `POST /integrity` is called with `kind = 'unknown_event'`
- THEN HTTP 422 is returned and no IntegrityEvent rows are persisted

#### Scenario: Mixed batch — all-or-nothing validation

- GIVEN a batch containing 1 valid kind and 1 unknown kind
- WHEN `POST /integrity` is called
- THEN HTTP 422 is returned and no IntegrityEvent rows are persisted for that request

---

### Requirement: POST /snapshot — base64 JPEG to S3 with size and content-type validation

`POST /api/candidate/interview/snapshot` MUST accept `{ session_id, image_base64 }` (JPEG).
Validation MUST happen in this order BEFORE decoding:

1. **Encoded-length cap**: validate the BASE64-ENCODED string length BEFORE decoding.
   Reject with HTTP **413** if the encoded length exceeds ~2.7 MB (corresponding to a decoded
   size of ~2 MB). Never attempt to decode an oversized payload.
2. **JPEG magic bytes / content-type check**: after decoding, verify that the first bytes
   are the JPEG magic bytes (`FF D8 FF`). Reject with HTTP 422 if the check fails.
3. On passing both checks: persist to S3 via `Storage::disk('s3')->put()`.

**S3 key scheme (server-generated only):**
`{organization_id}/{participant_id}/{session_id}/{snapshot_uuid}.jpg`
— using INTEGER ids and a UUID uniqueness component (the `InterviewSnapshot` UUID or
`Str::uuid()`). `taken_at` is server-set. NO client-supplied path segments.
This scheme prevents timestamp collisions and path traversal attacks.

Record an `InterviewSnapshot` row with the resulting `s3_key` and server-set `taken_at`.
Returns HTTP 202. No retention TTL is set in C7a (flagged for C13).

#### Scenario: Snapshot uploaded to S3

- GIVEN a valid base64 JPEG under the size limit and an active session
- WHEN `POST /snapshot` is called
- THEN the image is written to S3 with a server-generated key of form
  `{org_id}/{participant_id}/{session_id}/{uuid}.jpg`, an InterviewSnapshot row is
  persisted with a non-null `s3_key` and server-set `taken_at`, and HTTP 202 is returned

#### Scenario: Oversized snapshot rejected with 413

- GIVEN a base64-encoded string whose length exceeds ~2.7 MB
- WHEN `POST /snapshot` is called
- THEN HTTP 413 is returned WITHOUT decoding the payload and no S3 write or DB insert occurs

#### Scenario: Invalid JPEG magic bytes rejected with 422

- GIVEN a base64 payload that decodes to non-JPEG bytes (e.g. PNG or arbitrary data)
- WHEN `POST /snapshot` is called
- THEN HTTP 422 is returned and no S3 write or DB insert occurs

#### Scenario: session_id from different org is rejected

- GIVEN session S_B belonging to org B
- WHEN candidate from org A calls `POST /snapshot` with `session_id = S_B`
- THEN HTTP 404 is returned and no S3 write or DB insert occurs

---

## Lifecycle Requirements

### Requirement: Participant lifecycle guard — allowed transitions only (CRITICAL-1)

The system MUST enforce that C7a fires ONLY the transitions in the COMPLETE
`$allowedTransitions` map below. The C6 map is INSUFFICIENT for C7a: it blocks
`in_attesa → errore` and `in_corso → errore`, which are required for provider
hard-failure on the first and subsequent competencies respectively. Both transitions
MUST be added or the provider failure path throws `ParticipantTransitionException` (422)
instead of the correct 502.

**REQUIRED complete `$allowedTransitions` map:**

| From | To (allowed) |
|---|---|
| `in_attesa` | `in_corso`, `errore` |
| `in_corso` | `in_valutazione`, `errore` |
| `in_valutazione` | `completato`, `errore` |
| `completato` | _(none — terminal)_ |
| `errore` | _(none — terminal)_ |

Constraints:
- **FIX-5: BOTH terminal states are explicit.** `completato` is terminal: `$allowedTransitions['completato'] = []`
  (explicit empty array). `errore` is terminal: `$allowedTransitions['errore'] = []`.
  Neither may fall through to the `?? []` defensive default — both MUST appear in the map so
  intent is visible and auditable.
- `completato → errore` MUST NOT be added.
- Both the `completato` and `errore` keys MUST be present explicitly.

C7a fires these specific transitions:
- `in_attesa → in_corso` (first `/start`)
- `in_corso → in_valutazione` (last `/end` via `FinalizeInterview` CAS)
- `in_attesa → errore` (provider hard-failure on the FIRST competency `/start`)
- `in_corso → errore` (provider hard-failure on a subsequent competency `/start`)

Any attempt to trigger an illegal transition (e.g., `in_valutazione → in_corso`) MUST raise `ParticipantTransitionException`, which MUST be caught and returned as HTTP 422.

#### Scenario: Illegal transition rejected

- GIVEN participant.status = 'in_valutazione'
- WHEN the system attempts to transition to 'in_corso'
- THEN ParticipantTransitionException is raised and HTTP 422 is returned

#### Scenario: Provider failure on first competency (in_attesa) → errore

- GIVEN participant.status = 'in_attesa' (first `/start`, no session yet in_corso)
- WHEN the provider returns a 5xx/timeout hard-failure
- THEN participant.status transitions to 'errore' (in_attesa → errore, now an allowed transition) and HTTP 502 is returned

#### Scenario: Provider failure on subsequent competency (in_corso) → errore

- GIVEN participant.status = 'in_corso' (at least one competency already finished) and a fatal provider REST error during `/start`
- WHEN the error is caught and cannot be retried
- THEN participant.status transitions to 'errore' (in_corso → errore, allowed transition) and HTTP 502 is returned

---

## Cross-Tenant and Cross-Participant Security Requirements

### Requirement: Session ownership enforced at every session-scoped endpoint via resolveOwnedSession

ALL session-scoped endpoints (`/end`, `/utterance`, `/integrity`, `/snapshot`) MUST resolve
the session via the shared `resolveOwnedSession` helper:

```php
// WARNING-4: this is invoked from 4 different controllers — it MUST be a shared unit
// (trait ResolvesOwnedSession, base controller, or small service), NOT a private method.
// A private method is not accessible across classes.
protected function resolveOwnedSession(int $id): InterviewSession
{
    return InterviewSession::where('participant_id', auth()->id())->findOrFail($id);
}
```

`TenantScoped` adds the `organization_id` filter automatically (global scope).
`participant_id` is the ADDITIONAL required constraint. The helper returns 404 for any
non-owned, cross-org, or nonexistent session — providing a consistent 404 oracle with no
cross-participant information leakage.

The resolver MUST be implemented as a shared unit — a trait (e.g. `ResolvesOwnedSession`)
used by all four session-scoped controllers, OR a base controller they extend, OR a small
dedicated service class. The logic MUST be defined ONCE and reused.

A same-org candidate MUST NOT be able to read or mutate another participant's session even
if they share the same `organization_id`. Any request referencing a session owned by a
different `participant_id` MUST return HTTP 404 (not 403) to avoid existence oracle.

**Status-guard 404-before-403 ordering:** `resolveOwnedSession` is invoked FIRST and
returns 404 for any non-owned session regardless of that session's terminal status. The
`ParticipantStatusGuard` (403 on `completato`/`errore`) governs the candidate's OWN
interview access and runs separately — it NEVER reveals whether a foreign session exists.

#### Scenario: Cross-tenant session_id returns 404

- GIVEN session S_B belonging to org B participant B
- WHEN candidate A (org A) calls `POST /end` with `session_id = S_B`
- THEN HTTP 404 is returned; session S_B is not modified

#### Scenario: Same-org, different-participant session returns 404

- GIVEN session S_X belonging to participant X within org O
- WHEN participant Y (also org O) calls `POST /utterance` with `session_id = S_X`
- THEN HTTP 404 is returned (resolveOwnedSession: participant_id mismatch); no Utterance is persisted

#### Scenario: Cross-org valid-session probe returns 404 regardless of terminal status

- GIVEN session S_B belonging to org B (status = 'completed')
- WHEN candidate from org A calls `POST /end` with `session_id = S_B`
- THEN HTTP 404 is returned (resolveOwnedSession: organization_id + participant_id mismatch);
  the terminal status of S_B is never disclosed

---

## Provider Secret Key Requirement

### Requirement: Provider API secrets never exposed to the client

Provider secret keys (HeyGen API key, Tavus API key) MUST be stored exclusively
in server-side environment/config. No response body, header, or log entry accessible
to the client MUST contain a raw provider secret. The `/start` response MUST contain
only the ephemeral session token or conversation URL issued by the provider.

#### Scenario: Response body contains no secret key

- GIVEN HEYGEN_API_KEY = 'sk-secret' in server env
- WHEN `POST /start` returns HTTP 201
- THEN the response body does not contain 'sk-secret' or any substring matching the raw key pattern; it contains only `provider_token` (ephemeral)

---

## Ordering Requirement

### Requirement: Competency sessions created in project_competencies.position order

`POST /start` MUST select the lowest `position` value among project competencies
that do not yet have a finalized `InterviewSession` for this participant. The order
is fixed and deterministic.

#### Scenario: Third /start creates third-position competency

- GIVEN a project with competencies [PRS@1, STG@2, INN@3]; sessions for positions 1 and 2 are finalized
- WHEN `POST /start` is called
- THEN the new session has `competency_code = 'INN'` and `question_index = 2` (= position 3 - 1; 0-based)

---

## Coverage Note

Given the correctness and security criticality of this slice, the following areas
MUST be held to ~95% test coverage: session status transitions (LOCKED enum only —
{pending, in_corso, completed, timeout, skipped, error}), last-question detection,
tenant isolation (cross-org and cross-participant via resolveOwnedSession),
status guard (403 for completato/errore), provider secret non-exposure,
lifecycle guard (422 on illegal transitions), integrity-kind validation,
FinalizeInterview CAS single-dispatch under concurrent /end, snapshot encoded-length
cap (413) + JPEG magic validation (422), REPLACE transcript semantics (HeyGen),
and UNIQUE(participant_id, competency_code) resume behavior.
