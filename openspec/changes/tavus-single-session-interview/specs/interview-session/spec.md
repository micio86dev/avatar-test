# Delta for Interview Session

## MODIFIED Requirements

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
6. **Advance-on-live-ref (Tavus only):** when the next competency's provider is Tavus AND a
   live `provider_session_ref` already exists on another one of this participant's
   `InterviewSession` rows within the same Tavus conversation, `/start` MUST NOT call
   `ProviderSessionService.issue()` again. Instead it MUST insert the new competency's
   `InterviewSession` row (`status='in_corso'`, `provider_session_ref` = the SAME existing
   ref, `question_index`/`competency_code` for the new competency) in one short DB
   transaction, and return HTTP 201 with a steering payload directing the client to send the
   competency-boundary interaction over the EXISTING conversation instead of a fresh
   `provider_token`/`conversation_url`. This is the ONLY path that shares a
   `provider_session_ref` across two `InterviewSession` rows; every other creation path —
   including every HeyGen path, and the Tavus path when no reusable live ref exists (first
   competency, or the provider's session-length ceiling reached) — issues a fresh,
   session-scoped ref exactly as before.
   (Previously: `/start` unconditionally called `ProviderSessionService.issue()` for every
   competency, for every provider — one provider session per competency, with no reuse path.)

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
      provider name into a typed token so teardown routes to the correct provider client (F1)),
      UNLESS that ref is still depended on by another live sibling competency (see "Resume
      Teardown Is Scoped to Refs No Other Live Competency Depends On"). A teardown failure is
      logged but non-fatal — the candidate needs the fresh session.
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

#### Scenario: Second competency within a live Tavus conversation advances without a new provider session

- GIVEN a Tavus conversation is already live for this participant's competency CSF
  (`provider_session_ref` set, `status = 'in_corso'`)
- WHEN `POST /start` is called for the next competency INN
- THEN `ProviderSessionService.issue()` is NOT called; a new `InterviewSession` row for INN
  is inserted sharing the SAME `provider_session_ref` as CSF, and HTTP 201 is returned with a
  steering payload rather than a fresh `conversation_url`

#### Scenario: HeyGen is unaffected — issue() still called on every competency

- GIVEN a HeyGen interview with an already-live session for a prior competency
- WHEN `POST /start` is called for the next competency
- THEN `ProviderSessionService.issue()` IS called, exactly as before this change; no
  `InterviewSession` row ever shares a `provider_session_ref` with another HeyGen row

#### Scenario: Approaching the provider's session ceiling produces a genuine new conversation

- GIVEN a Tavus conversation whose live period is approaching the provider's session-length
  ceiling and cannot accept further competencies
- WHEN `POST /start` is called for the next competency
- THEN the advance-on-live-ref path is bypassed; `ProviderSessionService.issue()` is called
  and creates a genuinely new conversation ref, exactly as the create path already does for
  a first competency

---

### Requirement: Tavus Conversation Wire Contract

`POST https://tavusapi.com/v2/conversations` MUST be called with
`{replica_id, persona_id, conversational_context, custom_greeting, properties}` — no
`competency_code`/`question_index`. When a project's session spans several competencies in
one conversation, `conversational_context` MUST carry the FULL composed context for every
competency the conversation will cover, composed server-side before the request is sent —
never a partial context extended later by a client-supplied addition. The conversation
id/URL MUST be read from the TOP-LEVEL `conversation_id`/`conversation_url`, not nested
under `data`. Teardown MUST be `POST /v2/conversations/{id}/end`, never `DELETE`.

At a competency boundary within a live conversation, the client sends a
`conversation.overwrite_llm_context`-shaped interaction over the Daily data channel naming
only the next competency's code and an advance instruction — this interaction is part of
this wire contract, governed by the "Outbound Interaction Payload Carries No Scoring
Content" requirement below. It MUST NOT replace or re-send `conversational_context`.
(Previously: `conversational_context` held a single competency's composed prompt; the
multi-competency case and the boundary interaction did not exist.)

#### Scenario: /conversations body is the real shape
- GIVEN a candidate starting a Tavus interview
- WHEN `TavusProvider::issue()` builds the request
- THEN the body contains `replica_id`, `persona_id`, `conversational_context`,
  `custom_greeting`, `properties`, and no `competency_code`/`question_index`

#### Scenario: Response ids are read top-level
- GIVEN Tavus returns `{conversation_id:'conv_1', conversation_url:'https://...'}`
- WHEN the response is parsed
- THEN both values are extracted from the top level

#### Scenario: Teardown ends, does not delete
- GIVEN an active Tavus conversation
- WHEN `TavusProvider::teardown()` is called
- THEN it issues `POST /v2/conversations/{id}/end`; no `DELETE` is made

#### Scenario: A multi-competency conversation ships every covered competency's context at creation

- GIVEN a project whose Tavus session will cover competencies [CSF, INN, DRV] in one conversation
- WHEN `TavusProvider::issue()` builds the FIRST `POST /v2/conversations` request for this
  conversation
- THEN `conversational_context` contains the composed content for all three competencies;
  no later request adds context for a competency omitted here

#### Scenario: A competency-boundary interaction never re-sends conversational_context

- GIVEN a live conversation advancing from CSF to INN
- WHEN the client sends the boundary interaction
- THEN the outbound payload contains no `conversational_context` key or equivalent full-context
  field — only the competency code and advance instruction

---

## ADDED Requirements

### Requirement: Outbound Interaction Payload Carries No Scoring Content

Every interaction the candidate's browser sends over the Tavus data channel at a
competency boundary MUST be structurally restricted to a competency code and a fixed,
enumerated advance instruction — it MUST NOT be a free-text field capable of carrying
prose. The payload's instruction content MUST be validated against a closed, versioned set
of literal advance-instruction templates, and the ONLY variable substituted into a template
MUST be the competency code — a short, enumerated value drawn from
`project_competencies.competency_code`. No BARS indicator name, anchor text
(`anchor_5`/`anchor_3`/`anchor_1`), or composed prompt fragment MUST ever be assignable to
that template's variable slot or appended to the payload by any code path.

Verification MUST assert this structurally, not by substring search for a competency code
inside free text: a test MUST assert (a) the interaction payload's total serialized length
does not exceed the fixed template length plus the competency code's own length, and (b)
the payload, once the template's literal wrapper text is stripped, equals EXACTLY one value
from the project's enumerated competency-code set — an assertion that could not be
satisfied by an indicator name or anchor sentence merely containing that code as a
substring. A naive `payload.includes(code)` check MUST NOT be used as the sole leak
detector, since a code that is also a substring of an ordinary word (e.g. `INN` inside
"INNOVATION") produces a false positive.

#### Scenario: A competency-boundary payload contains only the code and the fixed instruction

- GIVEN a live Tavus conversation and a boundary from competency CSF to competency INN
- WHEN the client sends the boundary interaction
- THEN the payload matches the fixed advance-instruction template with `INN` as its only
  variable, and stripping the template's wrapper text leaves exactly `INN` — nothing else

#### Scenario: No BARS anchor or indicator text can reach the payload (structural, not substring)

- GIVEN a competency whose anchor text or indicator description happens to contain the
  substring of another competency's code inside a longer word
- WHEN the boundary interaction is constructed for an unrelated transition
- THEN the payload is still validated by exact-match against the enumerated competency-code
  set, not by substring containment, so the coincidental substring in unrelated anchor text
  neither produces a false pass nor is capable of leaking into the payload

#### Scenario: An oversized or freeform payload fails the anti-leak assertion

- GIVEN a hypothetical payload carrying an extra field or free-text content beyond the fixed
  template and the competency code
- WHEN the anti-leak test runs
- THEN the length/shape assertion fails — a payload carrying anything beyond the template
  and the code cannot pass

#### Scenario: The composed multi-competency context, not the boundary payload, carries the anchors

- GIVEN a live multi-competency Tavus conversation
- WHEN the full request history between server and Tavus is inspected
- THEN every BARS anchor and indicator text appears only in the server-to-Tavus
  `conversational_context` sent at `POST /v2/conversations` creation, never in any
  client-to-Tavus data-channel message

### Requirement: A Competency Boundary Requires a Server Round Trip Even When the Provider Conversation Does Not Change

Advancing to a new competency within a live Tavus conversation MUST still go through the
server: the server remains the sole source of truth for competency completion, the running
completion tally, the pause cadence (`pause_every_n_competencies`), and the progress
webhook trigger. The absence of a new provider session or a new room MUST NOT be read as
license to skip or shortcut the existing `/end` → `/start` round trip; a shared conversation
changes only which provider call is made, never which server state transitions occur.

#### Scenario: Completion tally still advances correctly on a shared-conversation boundary
- GIVEN a project with 5 competencies in one live Tavus conversation; 2 already ended
- WHEN the 3rd competency ends via `POST /end`
- THEN `ended_competencies` reads 3 exactly as it would across separate conversations, and
  `next_action` is computed by the same rule as today

#### Scenario: A scheduled pause still fires inside a shared conversation
- GIVEN `pause_every_n_competencies = 3` and a live Tavus conversation spanning 5 competencies
- WHEN the 3rd competency ends
- THEN `next_action = 'pause'` is returned exactly as it would be for a per-competency-conversation
  Tavus session or a HeyGen session

#### Scenario: A progress webhook still fires per competency
- GIVEN a live multi-competency Tavus conversation
- WHEN any competency within it ends via `POST /end`
- THEN one `progress` event is dispatched after that commit, exactly as the existing
  addendum requires — the shared conversation does not merge or suppress this event

### Requirement: Resume Teardown Is Scoped to Refs No Other Live Competency Depends On

`handleResumeInCorso`'s teardown of the persisted `provider_session_ref` MUST NOT fire when
that ref is still referenced by another `InterviewSession` row belonging to the same
participant that is itself still live (`status = 'in_corso'`, not yet ended). A resume on
one competency sharing a Tavus conversation with a still-live sibling competency MUST reuse
the existing live ref rather than tearing it down and issuing a fresh one.

#### Scenario: Resume on a shared-ref competency does not tear down the conversation a sibling depends on
- GIVEN two `InterviewSession` rows for the same participant, both `status='in_corso'`,
  sharing one `provider_session_ref` (a multi-competency Tavus conversation)
- WHEN the candidate reconnects mid-way through one of them and `handleResumeInCorso` runs
- THEN `provider->teardown()` is NOT called against that shared ref; the resume reuses the
  existing live conversation

#### Scenario: Resume on a single-competency (unshared) ref still tears down and reissues, as today
- GIVEN a session whose `provider_session_ref` is not shared with any other live
  `InterviewSession` row
- WHEN the candidate reconnects
- THEN the existing teardown-and-reissue behavior (CRITICAL-2 + FIX-1) is unchanged

#### Scenario: A ref is torn down once its last dependent competency ends
- GIVEN a shared ref backing two competencies, one already `completed` and the other still
  `in_corso`
- WHEN the remaining `in_corso` competency itself later needs teardown (e.g. its own resume
  path, once no sibling still depends on the ref)
- THEN teardown is permitted — the guard blocks teardown only while at least one dependent
  competency remains live
