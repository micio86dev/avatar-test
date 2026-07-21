# Design: Interview Session Mechanics Backend (C7a)

## Technical Approach

Deliver the candidate-facing interview backend as an additive slice on `develop`
(C1–C6). Four new `TenantModel`s persist sessions/utterances/proctoring/snapshots,
five endpoints run inside the existing C6 candidate route group
(`auth:api-candidate` → `TenantContextCandidate` → `SubstituteBindings`,
`withoutMiddleware(TenantContext)`), and a `ProviderSessionService` issues HeyGen/Tavus
tokens server-side. One avatar session = one competency, delivered in
`project_competencies.position` order (C4). Scoring/adaptivity stay out (C8/C9).

Grounding: `Participant` lifecycle guard (`api/app/Models/Participant.php`),
`TenantScoped` creating-stamp (`api/app/Models/Concerns/TenantScoped.php`),
resolver stamp (`api/app/Http/Middleware/TenantContextCandidate.php`), route group
(`api/routes/api.php:125`), legacy REST calls (`legacy-demo/src/pages/api/interview/{start,end}.ts`),
proctor taxonomy (`legacy-demo/src/lib/proctor-config.ts`), schema to evolve
(`legacy-demo/src/lib/db.ts`).

## Architecture Decisions

| Decision | Choice | Alternatives rejected | Rationale |
|---|---|---|---|
| Provider secret handling | Secret keys live only in `config/interview.php` (env). Service returns HeyGen `session_token` / Tavus `conversation_url` + `provider_session_ref`; keys NEVER serialized. Mirrors legacy `start.ts` (secrets read server-side only). | Return keys to client; keys in JWT | Named security invariant, same class as `webhook_secret` hidden/encrypted in `Project`. |
| Provider selection | `env('INTERVIEW_PROVIDER','heygen')` default, overridable by an additive nullable `projects.provider_override` column (immutable-post-active, like `role_code`). Falls back to env when null. **FIX-6: canonical column name is `provider_override`** (not `provider`) — it reads as an override of the tenant/global default and avoids collision with any future non-override `provider` semantics. | Config map keyed by org; hardcode | Per-project override is a real product need (open #7); a column is tenant-scoped + auditable and matches C4 project-config conventions. |
| Provider abstraction | `ProviderSessionService` interface + `HeygenProvider`/`TavusProvider` impls behind it, resolved by name — mirrors legacy `InterviewProvider` split. `Http::fake`-able. | One fat service with `if provider` | Isolation, testability, clean C8 extension. |
| `in_valutazione` transition | Async `FinalizeInterview` job (Redis/Horizon) dispatched via ATOMIC CAS (see `/end` flow) on last-question `/end`, NOT inline. | Inline in `/end` | `/end` already does provider REST reconciliation; keep the response fast + retryable. Job is the seam C9 scoring listens on. |
| Transcript reconciliation | At `/end`: HeyGen authoritative server transcript REPLACES live rows (delete all utterances for session + insert server transcript, wrapped in a transaction holding a SELECT ... FOR UPDATE lock on the session row); Tavus keeps best-effort live `/utterance` rows (NO reconcile step). Mirrors legacy `replaceUtterances`. | Trust live only; async reconcile | HeyGen FULL has no live client transcript; its REST transcript is source of truth. A session-level lock prevents a concurrent `/utterance` from interleaving between DELETE and INSERT. |
| Last-question detection | Count this participant's ended `InterviewSession`s (status ∈ {completed, timeout, skipped}) filtered by BOTH `participant_id` AND `project_id` vs. `project_competencies` count for THIS project; equal ⇒ last. Each `Participant` row belongs to exactly ONE project (a human candidate participating in multiple projects gets a distinct `participant_id` per project, per C6); `participant_id` already implies project scope. The `project_id` filter on the count is kept as a denormalized safety guard and must remain. | Client-sent `isLast` flag | Server-authoritative; client flag is forgeable (candidate JWT non-revocable). |
| Status guard | `ParticipantStatusGuard` middleware after `TenantContextCandidate`: `status ∈ {completato,errore}` → 403. **FIX-7: the guard MUST be applied ONLY to the 5 interview sub-routes (`/start`, `/end`, `/utterance`, `/integrity`, `/snapshot`) in a NESTED route group — NOT to the parent C6 candidate route group.** Applying it to the parent would 403 a terminal candidate calling `GET /api/candidate/session` (a read endpoint, reasonable to allow even after completion). The guard revealing the candidate's OWN terminal status is acceptable (they already know it). Cross-org session EXISTENCE is never leaked — `resolveOwnedSession` returns 404 for any non-owned session regardless of the caller's own terminal status. | Controller checks | Single choke point for all 5 interview sub-routes; does not affect the existing /session read endpoint. |
| Snapshot storage | base64 JPEG → validate ENCODED length before decoding (reject if encoded length > ~2.7 MB, i.e. decoded > ~2 MB → 413) → validate JPEG magic bytes / content-type (else 422) → `Storage::disk('s3')->put()` → `s3_key`. No TTL (flag C13). | DB blob; local disk | S3 config already present (`config/filesystems.php`); GDPR retention is open #2. |
| S3 key scheme | Server-generated only: `{organization_id}/{participant_id}/{session_id}/{snapshot_uuid}.jpg` using INTEGER ids + a UUID uniqueness component (the `InterviewSnapshot` UUID or a fresh `Str::uuid()`). `taken_at` is server-set. NO client-supplied path segments, NO timestamp-collision risk, NO path traversal. | `{org}/{participant}/{session}/{ts}.jpg` | Timestamps can collide under burst; client-supplied segments enable path traversal. |
| Session ownership resolver | Shared helper `resolveOwnedSession(int $id): InterviewSession` = `InterviewSession::where('participant_id', auth()->id())->findOrFail($id)`. `TenantScoped` adds the `organization_id` filter automatically; `participant_id` is the ADDITIONAL required constraint. Returns 404 for any non-owned, cross-org, or nonexistent session. ALL session-scoped endpoints (/end, /utterance, /integrity, /snapshot) MUST use this resolver. **WARNING-4:** because the resolver is called from 4 different controllers, it MUST be implemented as a shared unit (a trait `ResolvesOwnedSession`, a base controller, or a small service) — NOT as a `private` controller method (which cannot be shared across classes). MUST be invoked FIRST in each session-scoped endpoint, before any DB mutation. | Per-controller ad-hoc checks | Single named security invariant, consistent 404 oracle, no cross-participant leakage. |
| `started_at` stamping | `started_at` is NOT in `Participant.$fillable`. It MUST be set via direct property assignment: `$participant->started_at = now(); $participant->status = 'in_corso'; $participant->save();` — NOT via mass-assign `update([...])` which silently drops it. | `$participant->update(['started_at' => now(), ...])` | `$fillable` guard makes mass-assign silently discard `started_at`. |
| Provider error log redaction | `HeygenProvider`/`TavusProvider` MUST catch provider HTTP errors and re-throw a domain exception (`ProviderException`) with the raw provider response body REDACTED. The raw HeyGen/Tavus HTTP response (which may echo the API key or contain internal endpoints) MUST NEVER reach the Laravel log or Sentry. | Log raw response | API key material in logs is a named security breach. |
| `framework_version_id` | Copied from `project.framework_version_id` at session creation time; never re-derived at read time. | Re-query project at read | Immutability: the session records which framework version scored it, independent of future project changes. |

## Locked Status Enum

`InterviewSession.status` is LOCKED to this set:

| Value | Meaning |
|---|---|
| `pending` | Transient pre-provider state; row created, provider call not yet made |
| `in_corso` | Provider session successfully issued; interview is live |
| `completed` | Ended normally (`ended_reason = 'completed'`) |
| `timeout` | Ended by time-out (`ended_reason = 'timeout'`) |
| `skipped` | Ended by skip (`ended_reason = 'skipped'`) |
| `error` | Provider hard-failure; `ended_reason = 'error'` |

Default at creation: `pending`. Transitions: `pending → in_corso` (after provider success);
`in_corso → completed | timeout | skipped` (via `/end`); `pending | in_corso → error`
(provider hard-failure or DB rollback compensation).

**"Ended" for last-question count** = `status ∈ {completed, timeout, skipped}`. Status `error`
is NOT counted as ended — a failed session does not consume a competency slot.

`ended_reason ∈ {completed, timeout, skipped, error}`.

"Active" wording is REPLACED throughout — use `in_corso` (the locked enum value).

## Data Flow

### /start — explicit numbered sequence (provider call OUTSIDE any DB transaction)

```
(1) UNIQUE-CONSTRAINT-AWARE competency resolution:
    SELECT the lowest project_competencies.position whose InterviewSession for
    this participant is ABSENT or NOT in a terminal-completed state
    (i.e. status NOT IN {completed, timeout, skipped}).
    A session with status = pending | in_corso → RESUME it (return existing session,
    do NOT create a duplicate). Mirrors legacy getNextQuestionIndex
    (min index where status != completed).

    CONCURRENT DOUBLE /start (WARNING-7): if two concurrent /start requests race,
    the second INSERT will hit the UNIQUE(participant_id, competency_code) constraint.
    The implementation MUST catch Illuminate\Database\UniqueConstraintViolationException
    (SQLSTATE 23505) on the INSERT and recover by re-querying the existing session
    (→ RESUME path below), NOT surface it as a 500.

(2) DB write (short txn):
    INSERT InterviewSession(status='pending', competency_code, question_index,
    framework_version_id [copied from project], provider, participant_id, organization_id).
    UNIQUE constraint on (participant_id, competency_code) makes this idempotent:
    a unique-violation means a session already exists → RESUME that session.

    question_index = position - 1   (0-based; position is 1-based from project_competencies)

(3) ProviderSessionService.issue() ← OUTSIDE ANY DB TRANSACTION
    HeyGen /contexts + /sessions/token  |  Tavus /v2/conversations
    This is a network call; holding a DB transaction open across it risks
    connection starvation and deadlock. It MUST NOT be inside a BEGIN...COMMIT block.

    CRITICAL-2 — RESUME token protocol:
    When step (1) returns an existing session (RESUME path), the implementation MUST
    re-issue a FRESH provider token before returning — never return a stale stored one.
    Two sub-cases:

    RESUME in_corso (session already has a provider_session_ref):
      Re-call ProviderSessionService.issue() to mint a FRESH provider token.
      The provider call is OUTSIDE any DB transaction (same invariant as the create path).

      OLD-SESSION TEARDOWN — FIX-1: before (or immediately after) issuing the fresh
      token, TEAR DOWN the OLD provider session using the persisted
      $session->provider_session_ref (which IS non-null in this sub-case — unlike the
      DB-failure compensation path in step 4d where the ref was never persisted).
      Recommended ordering:
        (a) Call ProviderSessionService.issue() OUTSIDE any transaction → obtain fresh token.
        (b) On issue() success: best-effort call ProviderSessionService.teardown() with
            a ProviderToken constructed from the OLD ref via
            ProviderToken::fromRef($session->provider, $session->provider_session_ref).
            (F1: pass $session->provider so teardown routes to the correct provider client;
            an empty provider would route to no branch → silent orphan.)
            A teardown failure on the OLD ref is LOGGED but NON-FATAL — the candidate
            needs the fresh session; the orphaned old session is cleaned up by the reaper.
        (c) Persist the new provider_session_ref to the DB (UPDATE session row).
      This prevents leaking a billable HeyGen session-minute / Tavus concurrency slot
      on every candidate reconnect (browser refresh, network drop, etc.).

      RECONCILE WITH WARNING-6 — the two teardown contexts are DISTINCT:
        (a) COMPENSATION path (step 4d): DB failed before provider_session_ref was ever
            persisted → pass the IN-MEMORY ProviderToken returned by issue(), NOT
            $session->provider_session_ref (which is null → silent no-op → orphan).
        (b) RESUME in_corso path (this sub-case): the OLD ref IS already persisted and
            non-null → wrap it via ProviderToken::fromRef($session->provider, $session->provider_session_ref)
            and pass the resulting ProviderToken to teardown().
      teardown() ALWAYS takes a ProviderToken — there is no raw-string overload.
      Never confuse the two: the RESUME teardown wraps the OLD persisted ref;
      the compensation teardown passes the NEW in-memory token from issue().

      Apply the SAME failure matrix as the create path (see steps 4a–4d below):
        - Provider 429 → provider_busy (do NOT flip participant to errore)
        - Provider 5xx/timeout → participant → errore (per CRITICAL-1 map) + 502 +
          teardown of the freshly-issued ref (if any); old ref teardown is skipped
          (no fresh session was issued)
        - DB failure on ref update → teardown of the NEW in-memory token + 500
          (use the in-memory ProviderToken per WARNING-6, not $session->provider_session_ref
          which at this point still holds the OLD ref value)
      On success: UPDATE provider_session_ref with the new ref before returning.

    RESUME pending (session created but provider issue never succeeded, e.g. after
    a prior 429 left the session in status='pending' with no provider_session_ref):
      Retry ProviderSessionService.issue() with the SAME failure matrix.
      On success: persist the new provider_session_ref and flip status to 'in_corso'.

    In both RESUME sub-cases, the response MUST contain a fresh, currently-valid token
    — never a stale stored provider_session_ref.

(4a) Provider SUCCESS → short txn (FIX-8: BOTH DB writes inside ONE transaction):
     BEGIN short DB transaction:
       UPDATE InterviewSession SET status='in_corso', provider_session_ref=<ref>
       On the FIRST competency (position = 1, i.e. participant.status = 'in_attesa'):
         $participant->started_at = now();
         $participant->status = 'in_corso';
         $participant->save();
         (Direct property assignment — NOT mass-assign — because started_at is NOT in $fillable.)
     COMMIT.
     FIX-8 rationale: without a surrounding transaction, a failure between the two writes
     leaves session `in_corso` but participant `in_attesa` (inconsistent state). Wrapping
     both in ONE short transaction ensures they commit or roll back together.
     Recovery on partial failure: the transaction is rolled back, leaving the session
     `pending` (or the previous state) — the RESUME pending path in step (3) re-issues
     the token on the next `/start` call. The step-4d teardown compensation ALSO covers a
     failure of EITHER write inside this transaction: if the transaction fails after the
     provider call succeeded, call ProviderSessionService.teardown($token) with the
     in-memory ProviderToken (WARNING-6) and return HTTP 500.
     Return HTTP 201 { session_id, provider, provider_token|conversation_url, question_context }

(4b) Provider HARD-FAILURE (5xx / timeout) → compensation:
     UPDATE InterviewSession SET status='error', ended_reason='error'
     Transition participant → errore (if not already terminal)
     [Allowed by CRITICAL-1 map: in_attesa→errore and in_corso→errore are both valid]
     Return HTTP 502

(4c) Provider 429 / concurrency → retryable:
     Leave session as status='pending' (or delete it, implementation choice)
     Do NOT transition participant → errore (429 is retryable)
     Return HTTP 429 { error: 'provider_busy' }

(4d) DB FAILURE AFTER provider success → compensation:
     Call ProviderSessionService.teardown(token) to release the provider session,
     passing the in-memory ProviderToken returned by issue() — NOT $session->provider_session_ref
     (which may not yet be persisted). See WARNING-6 below.
     Return HTTP 500
     NOTE: the teardown call itself may fail (network); log the failure for
     manual cleanup. Do NOT suppress the original DB error.
```

**Invariant:** the provider HTTP call (`ProviderSessionService.issue()`) is NEVER
inside a DB transaction. Violating this invariant is a correctness defect.

**WARNING-6 — `teardown()` ref source:** `teardown()` ALWAYS takes a `ProviderToken` — there
is NO raw-string overload. Two distinct teardown contexts require different token sources:

- **COMPENSATION path (step 4d):** DB failed before `provider_session_ref` was persisted →
  `$session->provider_session_ref` is null → pass the IN-MEMORY `ProviderToken` returned
  directly by `issue()`. Passing the session model would silently no-op (null ref → orphan).
- **RESUME in_corso path (step 3b):** the OLD ref IS persisted and non-null → construct a
  ProviderToken via `ProviderToken::fromRef($session->provider, $session->provider_session_ref)`
  and pass it. (F1: the provider name is required so teardown routes to the correct client.)

```php
// CORRECT (compensation) — pass the in-memory token returned by issue():
$token = ProviderSessionService::issue($session, $ctx);
// ... DB update fails ...
ProviderSessionService::teardown($token);  // ref comes from $token, never from $session

// CORRECT (RESUME) — wrap the old persisted ref + provider as a ProviderToken:
$oldToken = ProviderToken::fromRef($session->provider, $session->provider_session_ref);
ProviderSessionService::teardown($oldToken);

// WRONG — session may not have provider_session_ref persisted yet (null → silent no-op):
// ProviderSessionService::teardown($session);

// WRONG — teardown() does not accept a raw string:
// ProviderSessionService::teardown($session->provider_session_ref);
```

### /end — atomic CAS single-winner FinalizeInterview dispatch

```
(1) Resolve session via resolveOwnedSession($session_id) → 404 if not owned

(2) Validate ended_reason ∈ {completed, timeout, skipped}
    [FIX-11: 'error' MUST be explicitly rejected here with 422 — it is a server-set value,
    never a valid client-submitted ended_reason. Validation MUST enumerate only
    {completed, timeout, skipped} as accepted values.]

(3) BEGIN EXPLICIT DB TRANSACTION  ← CRITICAL-3 atomicity boundary
    SELECT ... FOR UPDATE on the InterviewSession row:

    FIX-3 — IDEMPOTENCY GUARD (inside the FOR UPDATE lock, before any mutation):
    if session.status !== 'in_corso' → ROLLBACK transaction → return 409 Conflict
    (do NOT re-stamp ended_at; do NOT re-run the CAS; do NOT re-dispatch FinalizeInterview)
    This makes /end a no-op on an already-ended session and prevents re-firing step (4).

    HeyGen: replaceUtterances — DELETE all utterances for session + INSERT server transcript
    (The FOR UPDATE lock on the session row prevents a concurrent /utterance from
    interleaving between DELETE and INSERT.)
    Tavus: no reconciliation step (live /utterance rows are kept as-is).
    Note: the FOR UPDATE lock scope MUST cover step (4) — the session-status UPDATE
    runs inside this SAME transaction.

(4) UPDATE InterviewSession SET status=ended_reason, ended_at=now()
    [INSIDE the transaction opened in step 3]

(5) Count ended sessions scoped to THIS participant AND THIS project:
    $endedCount = InterviewSession::where('participant_id', $pid)
                                  ->where('project_id', $projectId)
                                  ->whereIn('status', ['completed','timeout','skipped'])
                                  ->count();
    $totalCompetencies = ProjectCompetency::where('project_id', $projectId)->count();
    [INSIDE the transaction opened in step 3]

(6) If $endedCount === $totalCompetencies (last question):
    ATOMIC CAS — compare-and-set on participant:
      $won = Participant::where('id', $pid)
                        ->where('status', 'in_corso')
                        ->update(['status' => 'in_valutazione']);
    ONLY if $won === 1:
      FinalizeInterview::dispatch($pid)->afterCommit();
      // afterCommit() attaches to THIS explicit transaction: the job is enqueued
      // only after the transaction in step (3) commits successfully.
    If $won === 0 (a concurrent /end already transitioned):
      Skip dispatch — no double dispatch.
    [INSIDE the transaction opened in step 3]

    COMMIT  ← steps (4), (5), (6) commit atomically

(7) Return HTTP 200
```

**CRITICAL-3 atomicity guarantee:** steps (4) session-status UPDATE, (5) ended-count, and (6)
last-question CAS are wrapped in ONE explicit DB transaction (opened in step 3). If the process
crashes BEFORE commit, the session-status UPDATE is rolled back — the session remains `in_corso`
and is resumable/re-endable (recoverable on retry). `FinalizeInterview::dispatch()->afterCommit()`
is attached to this explicit transaction, so the job is enqueued only after the commit succeeds.
There is NO crash window between a committed session-status update and a missing job dispatch.

**FinalizeInterview job:**
- ONLY emits the C9 scoring trigger (the `→in_valutazione` transition already happened via the CAS in step 6).
- MUST be idempotent: re-check participant status on execution; if already past `in_valutazione`, no-op.
- `->afterCommit()` ensures the job is dispatched ONLY after the DB transaction commits, so it never reads stale participant state.
- **FIX-4 — retry-safe C9 trigger dedup (exactly-once guarantee under Laravel queue retries):**
  The re-check "if already past `in_valutazione`, no-op" does NOT protect against a failed+retried job
  re-emitting the C9 scoring trigger while the participant is still `in_valutazione` (which is the
  expected state until C9 completes). Concurrent `/end` is protected by the CAS above; job retry is
  NOT. The C9 trigger emission MUST therefore use its own dedup mechanism:
    Option A — Redis sentinel (recommended): before emitting, atomically acquire a Redis lock keyed
      on `finalize:<participant_id>` using `SET ... NX PX <ttl>`. Only if the key was set
      (returned 1) emit the C9 trigger; if the key already exists (returned 0) → no-op.
      Choose a TTL long enough to outlast the maximum job retry window.
    Option B — Persisted marker: set a `scoring_queued_at` timestamp or boolean column on the
      `Participant` row atomically (e.g. via `UPDATE ... WHERE scoring_queued_at IS NULL`)
      BEFORE emitting the C9 trigger. Only if 1 row was updated → emit. If 0 rows updated → no-op.
  Either option is acceptable. The C9 consumer (out of C7a scope) must also be idempotent, but
  the trigger-emission dedup is C7a's responsibility. Document the chosen option in the job class.

### live ingestion

```
/utterance, /integrity, /snapshot ─► resolveOwnedSession → verify session status → append rows (best-effort)
```

**WARNING-5 / FIX-2 — `/utterance` TOCTOU window — ATOMIC guard required:**
A plain `SELECT status WHERE status = 'in_corso'` check followed by a separate `INSERT` is a
TOCTOU race: a concurrent `/end` can commit `completed` between the check and the INSERT (this
window is fully open for Tavus; for HeyGen the `/end` FOR UPDATE lock does NOT block the
`/utterance` plain SELECT, so the window exists there too).

The guard MUST be ATOMIC. Use ONE of these patterns:
  (a) **Conditional insert**: `INSERT INTO utterances (...) SELECT ... FROM interview_sessions
      WHERE id = ? AND status = 'in_corso'` — if 0 rows are inserted, the session was not
      `in_corso` at insertion time; treat as rejected.
  (b) **Shared lock**: acquire `SELECT ... FOR SHARE` on the session row INSIDE a short
      transaction, re-check status, then INSERT in the same transaction.

Response contract (CANONICAL — design and spec MUST agree):
- `/utterance` is a best-effort/202 endpoint. An utterance that arrives after the session is
  no longer `in_corso` is atomically dropped (0 rows inserted) and the endpoint returns
  **409 Conflict** WITHOUT throwing an exception.
- Do NOT use plain check-then-insert (non-atomic); do NOT silently swallow the rejection
  with a 202 (misleading); do NOT throw a 500 (user-visible error for a best-effort endpoint).
- 409 is the single canonical signal for "session no longer in_corso"; the client MUST
  treat 409 as a no-op (the interview has ended).

## File Changes

| File | Action | Description |
|---|---|---|
| `api/database/migrations/*_create_interview_sessions_table.php` | Create | id, org FK, participant FK cascade, project FK `restrictOnDelete` (belt-and-suspenders against accidental hard-delete; see FIX-9 note), question_index (0-based), competency_code, framework_version_id FK (copied from project at creation), status enum default `pending` ∈ {pending,in_corso,completed,timeout,skipped,error}, provider, provider_session_ref?, ended_reason?, started_at/ended_at timestampTz?, timestamps; UNIQUE(participant_id, competency_code); idx (org_id,participant_id),(org_id,status) |
| `api/database/migrations/*_create_utterances_table.php` | Create | session FK cascade, org, speaker enum, text, ts timestampTz; idx (org_id,session_id) |
| `api/database/migrations/*_create_integrity_events_table.php` | Create | session FK, org, kind, payload jsonb, ts; idx (org_id,session_id) |
| `api/database/migrations/*_create_interview_snapshots_table.php` | Create | session FK, org, s3_key, taken_at (server-set); idx (org_id,session_id) |
| `api/app/Models/{InterviewSession,Utterance,IntegrityEvent,InterviewSnapshot}.php` | Create | TenantModels; relations, casts, enums |
| `api/app/Http/Controllers/Candidate/InterviewController.php` | Create | start + end endpoints |
| `api/app/Http/Controllers/Candidate/UtteranceController.php` | Create | /utterance endpoint |
| `api/app/Http/Controllers/Candidate/IntegrityController.php` | Create | /integrity endpoint |
| `api/app/Http/Controllers/Candidate/SnapshotController.php` | Create | /snapshot endpoint |
| `api/app/Http/Middleware/ParticipantStatusGuard.php` | Create | 403 on completato/errore |
| `api/app/Services/Provider/{ProviderSessionService,HeygenProvider,TavusProvider}.php` | Create | Server-side token issuance; provider errors REDACT raw response before re-throw |
| `api/app/Jobs/FinalizeInterview.php` | Create | Emits C9 scoring trigger; idempotent; dispatched via CAS + afterCommit |
| `api/config/interview.php` | Create | env keys, provider defaults, snapshot limits (max encoded base64 ~2.7 MB → decoded cap ~2 MB) |
| `api/app/Models/Participant.php` | Modify | Update `$allowedTransitions` to the COMPLETE map below; stamp `started_at` via direct property assignment on `in_corso` (NOT mass-assign) |
| `api/routes/api.php` | Modify | `/api/candidate/interview/*` sub-routes + guard |

**CRITICAL: Complete `$allowedTransitions` map for `Participant.php` (CRITICAL-1)**

C7a adds two `errore` outbound edges that are currently BLOCKED by the C6 map. Both
`in_attesa → errore` (hard-fail on the FIRST competency `/start`) and
`in_corso → errore` (hard-fail on a subsequent competency) must be allowed, or the
provider hard-failure path will throw `ParticipantTransitionException` (422) instead
of the correct 502. The updated map MUST be:

```php
private static array $allowedTransitions = [
    'in_attesa'      => ['in_corso', 'errore'],
    'in_corso'       => ['in_valutazione', 'errore'],
    'in_valutazione' => ['completato', 'errore'],
    'completato'     => [],   // terminal — no outbound transitions (FIX-5)
    'errore'         => [],   // terminal — no outbound transitions
];
```

Constraints:
- BOTH terminal states are explicit: `$allowedTransitions['completato'] = []` and
  `$allowedTransitions['errore'] = []`. Neither may fall through to the `?? []` default.
  The `?? []` fallback exists only as a defensive last resort for states not in the map;
  known terminal states MUST appear explicitly so the intent is visible and auditable.
- Do NOT add any new transitions beyond those listed.
- Do NOT weaken existing transitions (e.g. do not remove `in_valutazione → completato`).
- Both the `completato` and `errore` keys MUST be present explicitly so the guard never
  falls through to the `?? []` default for transitions FROM either terminal state.

Additionally, add `ResolvesOwnedSession` trait (or equivalent shared unit — see WARNING-4 in Interfaces section) as a new file, used by the four session-scoped controllers.

**FIX-9 — FK cascade rationale (corrected):** The `interview_sessions.project_id` FK uses
`restrictOnDelete` as belt-and-suspenders against accidental hard-deletes of a project row.
This FK policy does NOT protect against project SOFT-deletes and was never intended to.
Laravel `SoftDeletes` executes an UPDATE (`deleted_at = now()`), not a SQL DELETE — so the FK
constraint is never triggered by a soft-delete. Sessions survive a project soft-delete
automatically because no SQL DELETE fires. The `restrictOnDelete` is a correctness guard only
for hard-delete scenarios, which are blocked at the application layer but may occur in tests or
emergency operations. Do NOT rely on this FK for soft-delete protection (it provides none).

The migration for `interview_sessions` also adds a new file:
| `api/database/migrations/*_add_provider_override_to_projects.php` | Create | additive nullable `projects.provider_override` column — nullable, falls back to env default when null (FIX-6) |

Note: 5 endpoints span 4 controllers — `InterviewController` handles `/start` and `/end`;
`UtteranceController`, `IntegrityController`, and `SnapshotController` each handle one endpoint.

## Interfaces / Contracts

```php
/**
 * Provider-neutral token payload returned by issue().
 * NEVER carries secret keys.
 *
 * Fields:
 *   provider           — e.g. 'heygen' | 'tavus'
 *   token              — ephemeral session token (HeyGen); null for Tavus
 *   conversation_url   — conversation URL (Tavus); null for HeyGen
 *   provider_session_ref — opaque ref used to identify/teardown the provider session
 *
 * Static factory for teardown of an already-persisted session ref (RESUME path):
 *   ProviderToken::fromRef(string $provider, string $ref): self
 *   — creates a minimal ProviderToken carrying the provider name + provider_session_ref
 *     (other fields null). The provider name is REQUIRED (F1): teardown dispatch is
 *     provider-routed (HeyGen vs Tavus), so a token with an empty provider would route to
 *     no branch and silently orphan the old session — defeating FIX-1. Always pass
 *     $session->provider (the session row carries the resolved provider).
 *   Use this when tearing down the OLD provider session during RESUME in_corso so that
 *   teardown() always receives a typed ProviderToken, never a raw string.
 */
readonly class ProviderToken
{
    public function __construct(
        public string  $provider,
        public ?string $token              = null,
        public ?string $conversation_url  = null,
        public ?string $provider_session_ref = null,
    ) {}

    public static function fromRef(string $provider, string $ref): self
    {
        return new self(provider: $provider, provider_session_ref: $ref);
    }
}

interface ProviderSessionService {
    // Returns provider-neutral token payload; NEVER exposes secret keys.
    // Called OUTSIDE any DB transaction.
    public function issue(InterviewSession $s, QuestionContext $ctx): ProviderToken;

    // HeyGen only: fetch server transcript, return Utterance[] for REPLACE reconciliation.
    // Tavus: returns [] (no reconciliation).
    public function reconcileTranscript(InterviewSession $s): array;

    // Release the provider session. ALWAYS takes a ProviderToken — no raw-string overload.
    // Compensation path (step 4d): pass the in-memory ProviderToken returned by issue().
    // RESUME in_corso path (step 3b): pass ProviderToken::fromRef($session->provider, $session->provider_session_ref).
    // DO NOT pass the session model or a raw string — null/missing ref → silent no-op → orphan.
    // See WARNING-6 for the two distinct teardown contexts.
    public function teardown(ProviderToken $token): void;
}
```

```php
// Shared resolver — used by ALL session-scoped endpoints (/end, /utterance, /integrity, /snapshot).
// WARNING-4: this helper is invoked from 4 different controllers; it CANNOT be a private
// controller method (private methods are not accessible across classes). It MUST be implemented
// as a shared unit — either a trait (e.g. ResolvesOwnedSession) used by all four controllers,
// a base controller they extend, or a small dedicated service class. Any of these options is
// valid; the key constraint is that the logic is defined ONCE and reused everywhere.
//
// TenantScoped adds the organization_id filter automatically (global scope).
// participant_id is the ADDITIONAL required constraint.
// Returns 404 for any non-owned, cross-org, or nonexistent session.
// MUST be invoked FIRST in each session-scoped endpoint, before any DB mutation.
trait ResolvesOwnedSession  // or equivalent shared mechanism
{
    protected function resolveOwnedSession(int $id): InterviewSession
    {
        return InterviewSession::where('participant_id', auth()->id())->findOrFail($id);
    }
}
```

`/start` returns HTTP **201** → `{ session_id, provider, provider_token|conversation_url, question_context }`.

Failure matrix:
- Provider 5xx/timeout → 502 (session `status='error'`, participant →errore)
- Provider 429/concurrency → 429 `provider_busy` (retryable; participant NOT →errore)
- DB failure after provider success → 500 + `ProviderSessionService.teardown()` compensation

## Testing Strategy (target ~95%)

| Layer | What | Approach |
|---|---|---|
| Feature | start/end/utterance/integrity/snapshot happy paths; 403 status guard; cross-tenant isolation (A cannot touch B); cross-participant isolation (same-org X cannot touch Y's session via resolveOwnedSession); provider secret never in response or logs; last-question→`in_valutazione` (CAS single-winner); position ordering; 422 on bad transition; 413 on oversized snapshot; 422 on invalid JPEG magic; concurrent /end does NOT double-dispatch FinalizeInterview | `Http::fake` provider, `Storage::fake('s3')`, `Queue::fake` |
| Unit | lifecycle guard (allowed/rejected sets); `ProviderSessionService` per-provider (mocked HTTP, secret redaction — assert NO key material in re-thrown exception message or logs); integrity-kind validation (13 kinds); last-question count logic (scoped to participant+project); snapshot encoded-length cap + JPEG magic validation; resolveOwnedSession 404 for non-owner | Pest unit, mocked HTTP |

Provider error redaction test note: assert that when the provider returns a 5xx containing
the API key string, the re-thrown `ProviderException` message and any Laravel log entry do
NOT contain the raw key material.

**FIX-12 — `afterCommit()` incompatibility with wrapping-transaction test modes:**
`FinalizeInterview::dispatch()->afterCommit()` defers job dispatch until the OUTERMOST
transaction commits. If the test runs inside a wrapping transaction that is never committed
(e.g. `DatabaseTransactions`, which rolls back at tear-down), the `afterCommit` callback
never fires → the job is never dispatched → dispatch assertions silently fail in ways that
do not reflect production behaviour.

**Why `Queue::fake()` solves it:** `Queue::fake()` replaces the real queue transport with
an in-memory recorder. Its `push()` records the job IMMEDIATELY and bypasses
`shouldDispatchAfterCommit()` / the `db.transactions` manager entirely — it does NOT wait
for any transaction to commit. This is precisely why the assertion works: the fake makes
afterCommit transaction-awareness irrelevant by recording dispatches synchronously at the
point of the `dispatch()` call.

**`RefreshDatabase` vs `DatabaseTransactions`:** the rolled-back wrapping-transaction
behaviour belongs to `DatabaseTransactions` (each test is wrapped in a transaction that is
rolled back at tear-down). `RefreshDatabase` is migrate-based (re-migrates the DB between
tests); when combined with `Queue::fake()` for CAS/dispatch tests, the controller's own
explicit transaction commits for real, so `afterCommit()` fires in production-like fashion
AND `Queue::fake()` records the dispatch.

Tests that assert `FinalizeInterview` is dispatched MUST NOT rely on `DatabaseTransactions`
for that assertion. Required approach:
- Use `Queue::fake()` with `RefreshDatabase` (not `DatabaseTransactions`) for the CAS/dispatch
  tests, and assert `Queue::assertPushed(FinalizeInterview::class)` after the HTTP call.
  `Queue::fake()` records dispatches synchronously regardless of transaction state — the
  `afterCommit` dead zone is bypassed entirely.
- Do NOT use `$this->app['db']->commit()` to force-commit a wrapping test transaction —
  this leaves the DB in a dirty state between tests.

## Migration / Rollout

Additive. Rollback = drop 4 tables + `projects.provider_override` column, revert Participant guard + route group. No changes to C1–C6 schema beyond the additive column and guard extension; both reversible without data loss.

## Delivery Forecast

4 migrations + 1 alter, 4 models, ~4 controllers, 3 provider classes, 1 job, 1 middleware, 1 config, 2 model/route edits. Est. ~900–1100 LOC incl. tests.
- **400-line budget risk: High**
- **Chained PRs recommended: Yes**
- **Decision needed before apply: Yes**

Suggested slices: **PR1** schema + 4 models + Participant guard (+tenant/lifecycle tests); **PR2** routes + status guard + utterance/integrity/snapshot ingestion + S3; **PR3** ProviderSessionService + `/start`/`/end` + `FinalizeInterview` + reconciliation.

## Open Questions

- [ ] **HeyGen/Tavus REST contract (proposal under-specified).** Legacy uses LiveAvatar (`api.liveavatar.com/v1/contexts` + `/sessions/token`, `X-API-KEY`, FULL mode) and Tavus (`tavusapi.com/v2/conversations`, `x-api-key`). Confirm C7a targets the SAME endpoints/vendor (LiveAvatar vs native HeyGen) before implementing `issue()`.
- [ ] **Tavus concurrency (open #7).** Orphaned-provider-session risk: a candidate who abandons after `/start` leaks a Tavus slot. A reaper job is acknowledged as follow-up but NOT required in C7a. Tavus 429 → 429 `provider_busy` (retryable, NOT →errore); Tavus hard 5xx → →errore.
- [ ] **`question_context` shape** the client needs from `/start` (prompt/greeting/time-limit) is C7b's contract — confirm the minimal fields C7a must return.
- [x] **`errore` is a TERMINAL state** — `$allowedTransitions['errore'] = []`. RESOLVED by CRITICAL-1: the complete `$allowedTransitions` map (including `in_attesa→errore`, `in_corso→errore`, explicit `errore→[]`) is now stated in the File Changes section.
