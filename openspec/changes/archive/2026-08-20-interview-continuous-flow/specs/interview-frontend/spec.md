# Delta for interview-frontend

## Non-Goals Correction

(Reason: `interview-frontend/spec.md:24-25` asserts "no backend column exists" for
`pause_every_n_competencies` — factually false. The column has existed since
`api/database/migrations/2026_07_17_200001_create_projects_table.php:41`.)

- REMOVE the Non-Goals bullet: "Server-enforced `pause_every_n_competencies` — no backend
  column exists; C7b implements pause/resume with client-side state only."
- The gate becomes genuinely server-enforced by the requirements below; it is no longer a
  non-goal.

## ADDED Requirements

### Requirement: Continuous auto-advance directed by the server's `next_action`

Between competencies, the client MUST branch exclusively on the `next_action` field of
the `POST /end` response body (`interview-session` addendum) — it MUST NOT compute
"is this the last competency" or "is a pause due" itself from any client-side count or
list.

| `next_action` | Client behaviour |
|---|---|
| `continue` | No interstitial screen. `POST /start` is called immediately for the next competency. |
| `pause` | State transitions to `end_of_question` (rendered as the SA-04 pause screen). `POST /start` is NOT called until the candidate presses Resume. |
| `done` | State transitions to `done`. No further API calls are made. |

#### Scenario: next_action=continue — no screen, immediate next /start
- GIVEN `POST /end` returns `200` with `next_action = 'continue'`
- WHEN the client processes the response
- THEN no interstitial screen is rendered and `POST /start` is called immediately for the
  next competency

#### Scenario: next_action=pause — SA-04 screen shown, waits for Resume
- GIVEN `POST /end` returns `200` with `next_action = 'pause'`
- WHEN the client processes the response
- THEN the state machine transitions to `end_of_question` (the SA-04 pause screen);
  `POST /start` is NOT called until the candidate explicitly presses Resume

#### Scenario: next_action=done — done screen, no further calls
- GIVEN `POST /end` returns `200` with `next_action = 'done'`
- WHEN the client processes the response
- THEN the state machine transitions to `done`; no further `/start` call is made

#### Scenario: A missing next_action degrades to today's behaviour, not a crash
- GIVEN `POST /end` returns `200` with no `next_action` field (older `api` deploy, per the
  Dependencies ordering constraint)
- WHEN the client processes the response
- THEN it falls back to the pre-change `end_of_question` interstitial rather than
  throwing — deploying `frontend` ahead of `api` degrades gracefully

### Requirement: Skip control removed from the live interview UI

No Skip control MUST exist anywhere in the interview UI. The candidate's only two ways
to end a `live` question remain the avatar's own completion signal
(`ended_reason = 'completed'`) and the 5-minute per-question timer
(`ended_reason = 'timeout'`, ratified — unchanged).

#### Scenario: Skip control absent from the live interview screen
- GIVEN the live interview screen in any state
- WHEN its rendered controls are inspected
- THEN no Skip control exists, and `interview.live.skip` is absent from both `it.json`
  and `en.json`

### Requirement: Progress indicator reflects the server-reported competency total

The progress indicator MUST source its denominator from `total_competencies`
(`question_context`, `POST /start` addendum), never from a client-side competency array
or list. The numerator MUST be `question_index + 1` (1-based).

#### Scenario: Progress reads N/N with the real total, never x/0
- GIVEN `/start` returns `question_context.total_competencies = 5` and `question_index = 2`
- WHEN the interview screen renders the progress indicator
- THEN it displays `3/5`; the denominator is never `0`

#### Scenario: Progress total is stable across the whole session
- GIVEN `total_competencies = 4` established on the session's first `/start`
- WHEN later competencies are reached
- THEN the denominator stays `4` throughout, never recomputed from a client-side list

### Requirement: Candidate is informed when a competency is re-offered

When a competency is re-offered after a bounded single re-offer (Decisions 4 & 5,
`interview-session` delta), the interview UI MUST render the `reoffer` opening variant
(`interview-conversation` delta) rather than the copy used for a first attempt, so the
candidate understands they are re-attempting this competency, not being asked something
new for the second time with no explanation.

#### Scenario: A re-offered competency shows re-attempt copy
- GIVEN a competency whose prior session ended in `error` and has now been reset to
  `pending` (re-offer)
- WHEN the candidate reaches the `connecting`/`live` screen for that competency
- THEN the rendered opening copy is the `reoffer` variant, distinct from first-attempt
  copy, in the candidate's project language (it/en minimum)

#### Scenario: A first-time competency never shows re-attempt copy
- GIVEN a competency with no prior `error` session
- WHEN the candidate reaches it
- THEN standard first/next/resume opening copy is shown, never the `reoffer` variant

### Requirement: Live per-question timer suspends and resumes across a mute-pause

The per-question timer's remaining time MUST be preserved across the ratified
candidate-initiated mute-pause (`live → paused`): pausing stops the countdown; resuming
(`paused → live`) continues it from the same remaining value, never re-arming the full
5-minute limit. A new competency's timer always starts from the full limit, keyed on the
`InterviewSession` id, independent of any pause activity on a prior competency.

(This corrects a severe defect: with the countdown owned by a component the pause
unmounted, every resume re-armed a full five minutes, so a candidate who paused
repeatedly could extend a single question indefinitely. Fixed and released as `frontend`
v0.6.4.)

#### Scenario: Pausing suspends the countdown
- GIVEN a live question with 3 minutes 12 seconds remaining
- WHEN the candidate presses Pause
- THEN the countdown stops advancing and holds at 3:12

#### Scenario: Resuming continues from the same remaining value
- GIVEN the countdown was suspended at 3:12 by a mute-pause
- WHEN the candidate presses Resume
- THEN the countdown resumes counting down from 3:12, not from the full 5-minute limit

#### Scenario: A new competency always starts from the full limit
- GIVEN the previous competency's timer was paused and resumed one or more times
- WHEN the candidate advances to a new competency (a new `InterviewSession` id)
- THEN its timer starts fresh at the full 5-minute limit, independent of the prior
  competency's pause history

#### Scenario: Repeated pausing cannot extend a question indefinitely (regression)
- GIVEN a candidate pauses and resumes a live question multiple times
- WHEN the cumulative live time (excluding paused intervals) reaches 5 minutes
- THEN the question times out with `ended_reason = 'timeout'` — pausing never grants
  additional time beyond the original 5-minute limit

## MODIFIED Requirements

### Requirement: Interview session loop — endpoint call order

The system MUST drive the per-competency interview session by calling the five C7a endpoints
in the order mandated by the backend contract:

1. `POST /start` — called on entering each competency; on `429 provider_busy` the client
   MUST retry with a 3-second backoff. Retry budget: **at most 3 total attempts** (1 initial
   call + 2 retries). If all 3 attempts return `429`, the retryable error+retry screen is shown.
   The retry counter resets when the user initiates a retry from the error screen (user-initiated
   retry = a fresh attempt sequence, not a continuation of the previous count). After 3 consecutive
   `429` failures the session remains `pending` (backend side); the user can retry from the error
   screen which resets the counter and starts a new attempt sequence.
2. `POST /utterance` — called best-effort on every provider transcript event; a `409`
   response MUST be silently dropped.
3. `POST /integrity` — called every `FLUSH_INTERVAL_MS` (10 000 ms); also flushed via
   `navigator.sendBeacon` on `pagehide`. The `pagehide` flush MUST use an **absolute URL**
   built from `runtimeConfig.public.apiBase` (to work cross-origin in production) and MUST
   send a `Blob` with `type: 'application/json'`.
4. `POST /snapshot` — called every `SNAPSHOT_INTERVAL_MS` (10 000 ms) and on snapshot
   integrity events; `413` and `422` responses MUST be logged but MUST NOT interrupt the
   session.
5. `POST /end` — called when the avatar signals completion or the per-question timer
   expires; `ended_reason` MUST be one of `{completed, timeout, skipped}`. The Skip control
   has been removed from the UI, so the candidate-facing client only ever produces
   `completed` or `timeout` — `skipped` remains a valid, accepted value for historical rows
   and non-candidate paths (Decision 1; unchanged on the backend). A `409` response from
   `POST /end` MUST be treated as a successful no-op: the session was already ended (e.g.
   avatar-completion and timer-expiry race). The client already holds the outcome supplied
   by the winning concurrent call's `200` response (including its `next_action`); the losing
   call's `409` requires no separate handling. This is DISTINCT from the `/utterance` `409`
   silent-drop: same treatment, different semantic.
   (Previously: `ended_reason` also included the candidate's own skip action; that trigger
   no longer exists.)

A `403` response from any endpoint MUST redirect the candidate to the terminal screen.
A `502` or unexpected error response MUST show the error+retry screen.

**Between-competency flow (server-directed):** after `POST /end` returns `200`, the client
branches exclusively on the response body's `next_action` — see the "Continuous
auto-advance directed by the server's `next_action`" requirement above for the full
behaviour. The client MUST NOT compute this decision itself.
(Previously: the candidate always saw the `end_of_question` screen after every competency
and had to press an explicit button before the next `/start` was called — an unconditional
interstitial with no relation to `pause_every_n_competencies`.)

**Next-step detection (server-directed, not client-computed):** `total_competencies`
(`/start`'s `question_context`) is used ONLY to render the progress indicator. Whether the
interview continues, pauses, or is done is determined EXCLUSIVELY by `next_action` on the
`/end` response — never re-derived from `question_index`/total comparisons on the client,
and never from an ordered competency list (none is, or will be, shipped to the browser —
see `interview-session`'s Decision 3).
(Previously: last-competency detection compared `question_index + 1` against a total
sourced from "the C6 candidate-session bootstrap" — a list that never shipped, which is
why `session.vue` carried an empty `competencies` array and every interview ended after one
competency.)

**Resume-on-remount guard:** before calling `POST /start` on re-mount (reconnect / browser
refresh), the composable checks an in-flight flag (`isResuming`). If `isResuming` is true,
the second re-mount is skipped (prevents concurrent double-start). When re-mounting,
`provider.stop()` is called on the existing provider instance before issuing a new `/start`.

#### Scenario: Provider busy on /start — retry with backoff (at most 3 total attempts)

- GIVEN the backend returns `429 { error: 'provider_busy' }` for `POST /start`
- WHEN the client receives the response
- THEN the client waits 3 seconds and retries; after 3 total attempts (1 initial + 2 retries)
  all returning `429`, the retryable error+retry screen is shown

#### Scenario: Provider busy — user-initiated retry resets attempt counter

- GIVEN the error+retry screen is shown after 3 consecutive `429` responses
- WHEN the user presses Retry
- THEN a new attempt sequence begins with attempt count reset to 0; up to 3 new total attempts

#### Scenario: /start succeeds — session loop begins

- GIVEN `POST /start` returns `201` with
  `{ session_id, provider, provider_token, question_context }` (HeyGen: `provider_token`)
  or `{ session_id, provider, conversation_url, question_context }` (Tavus: `conversation_url`)
- WHEN the client receives the response
- THEN the avatar player is initialized using the `provider` field and the corresponding
  `provider_token` or `conversation_url`; the timer, proctoring, and flush intervals start

#### Scenario: /utterance 409 — silently dropped

- GIVEN the backend returns `409` for `POST /utterance`
- WHEN the client receives the response
- THEN no error is shown; the session continues uninterrupted

#### Scenario: /snapshot 413 — logged, session continues

- GIVEN the backend returns `413` for `POST /snapshot`
- WHEN the client receives the response
- THEN the error is logged; no user-visible error; the snapshot interval continues

#### Scenario: /snapshot 422 — logged, session continues

- GIVEN the backend returns `422` for `POST /snapshot`
- WHEN the client receives the response
- THEN the error is logged; no user-visible error; the snapshot interval continues
  (same treatment as 413 — malformed payload, not a fatal session error)

#### Scenario: /end 409 — treated as successful no-op, resolved via the winning call's body

- GIVEN the avatar-completion signal and the per-question timer fire concurrently, causing
  two simultaneous calls to `POST /end`, and the second call returns `409`
- WHEN the client receives the `409` from `POST /end`
- THEN the state machine proceeds exactly as directed by the winning concurrent call's
  `200` response and its `next_action`; no error screen is shown; no retry is triggered;
  this is a successful no-op, not an error

#### Scenario: /end's between-competency behaviour is superseded by next_action

(Superseded — see "Continuous auto-advance directed by the server's `next_action`" under
ADDED Requirements for the full, corrected scenario set: `continue` auto-advances with no
screen and no candidate action; `pause` renders the SA-04 screen; `done` shows the done
screen. The prior scenario asserting "the candidate MUST explicitly initiate the next
competency (no auto-advance)" no longer holds.)

#### Scenario: Terminal 403 — redirect to done/terminal screen

- GIVEN the backend returns `403` from any interview endpoint (ParticipantStatusGuard)
- WHEN the client receives the response
- THEN the candidate is redirected to the terminal screen with a localized completion message

---

### Requirement: Flow screens — localized states

The system MUST present the following named screens, each with all copy i18n-keyed
(locale from the candidate JWT language claim, minimum it/en):

**State machine:** `idle → device_check → connecting → live ⇄ paused → end_of_question → done | error | terminal`
(Previously: this line omitted `paused` entirely, contradicting the claim elsewhere in
this delta that the ratified live mute-pause is unaffected — that pause **is** the
`paused` state in shipped code (`useInterviewSession.ts:573-595`, `frontend` v0.6.3).
Corrected per design decision **D13**: `paused` survives, with `live` as its sole entry
AND exit — `live → paused` (Pause) and `paused → live` (Resume, now unconditional). What
is actually removed is narrower than previously stated: only the
**between-competency, candidate-optional** pause — the `end_of_question → paused` edge
and the `paused → end_of_question` fallback (the `pausedFrom` bookkeeping it required) are
deleted, because `end_of_question` becomes the SA-04 scheduled-pause screen and a Pause
control on a pause screen is meaningless. The `live ⇄ paused` edges themselves are
untouched by this change.)

**`terminal` vs `error` distinction:**
- `terminal` (no exit, no retry): `403` from any endpoint; absent/empty `end_phrase` or `final_phrase` (version mismatch / ops error). Shows a static localized screen; no retry control.
- `error` (retryable): `502`, network failure, or 3× `provider_busy`. Shows an error+retry screen; retry resets the attempt counter.

| Screen | State machine state | Entry trigger | Exit trigger |
|---|---|---|---|
| Consent | `idle` | Page mount; consent not yet accepted | Candidate accepts consent → `device_check` |
| Device Check | `device_check` | Consent accepted | Both camera + mic confirmed → `connecting` |
| Live Interview | `live` | `/start` returns `201` and provider is `ready` | Avatar signals completion / timer expires → `next_action` decides the destination; `403` → `terminal`; `502` → `error`; candidate presses Pause → `paused` |
| Pause (live mute) | `paused` | Candidate presses Pause during `live`; mic muted, provider session kept alive | Candidate presses Resume → `live`, mic unmuted (sole destination) |
| End of Question (SA-04 pause screen) | `end_of_question` | `/end` returns `200` with `next_action = 'pause'` — scheduled pause only, never candidate-optional | Candidate presses Resume → `connecting` (next `/start`) |
| Done | `done` | `/end` returns `200` with `next_action = 'done'` | Terminal (no exit) |
| Error + Retry | `error` | `502`, network failure, or 3× `provider_busy` | Candidate presses Retry → `connecting` (retry counter reset) |
| Terminal — 403 | `terminal` | `403` from any endpoint | No exit — terminal; localized message: session authorization expired / closed |
| Terminal — absent phrase | `terminal` | `end_phrase` or `final_phrase` absent from `/start` response | No exit — terminal; DISTINCT localized message: "service temporarily unavailable — contact support"; MUST include support-contact affordance |
| Unsupported | — | SSR/client browser gate fires (Firefox, mobile UA, or viewport < 1024 px) | — (existing `/unsupported` page) |

**`continue` produces no screen:** when `next_action = 'continue'`, the client does not
enter `end_of_question` at all — it calls `POST /start` immediately and transitions
straight to `connecting`.

(Previously: the table's `End of Question` row entry trigger was "`/end` returns `200`...
and competencies remain," i.e. every non-final competency, and this note claimed the
`Pause / Resume` row was removed outright. Corrected per **D13**: the interstitial is
conditional on the server's scheduled-pause directive, not on "competencies remain" — that
part still holds. But the row removal claim was too broad and is narrowed here: only the
**between-competency** Pause/Resume row (`end_of_question → paused → end_of_question`) is
removed. The live mute-pause row (`Pause (live mute)`, above) is retained, with a single
entry edge from `live` and Resume returning unconditionally to `live`.)

No literal strings MAY appear in Vue component templates or scripts. Every user-visible
string MUST be an i18n key resolved at runtime.

#### Scenario: Consent screen shown on first load

- GIVEN a candidate navigating to `/interview/[token]` for the first time
- WHEN the page mounts (consent not yet accepted)
- THEN the consent screen is displayed with localized copy; the device check is NOT initiated

#### Scenario: Done screen shown when the server directs done

- GIVEN `/end` returns `200` with `next_action = 'done'`
- WHEN the client processes the response
- THEN the done screen is displayed with localized copy; no further API calls are made
  (Previously: detection relied on client-side comparison against a competency list/total
  that was never delivered to the browser.)

#### Scenario: Error screen shown on 502

- GIVEN `POST /start` returns `502`
- WHEN the client processes the response
- THEN the error+retry screen is shown with a localized error message and a retry control

#### Scenario: All copy served in project language

- GIVEN a candidate JWT with `language = 'en'`
- WHEN any interview screen is rendered
- THEN all UI labels, button text, status messages, and captions are in English

#### Scenario: A project with pause_every_n_competencies=null runs fully continuous

- GIVEN a project with `pause_every_n_competencies = null`
- WHEN the candidate completes every competency end to end
- THEN `end_of_question` is never entered — every `/end` returns `next_action = 'continue'`
  until the last, which returns `'done'` — zero candidate clicks occur between competencies

#### Scenario: A project with pause_every_n_competencies=3 pauses exactly on schedule (SA-04)

- GIVEN a project with `pause_every_n_competencies = 3` and 8 competencies
- WHEN the candidate completes competencies 1 through 8 in order
- THEN `end_of_question` (the SA-04 pause screen) is entered after the 3rd and 6th
  competency, and at no other point

#### Scenario: The ratified live mute-pause is untouched by this change (D13 regression guard)

- GIVEN a candidate on a `live` question
- WHEN the candidate presses Pause
- THEN the microphone is muted and the provider session stays alive (state transitions to
  `paused`, never through `end_of_question`); pressing Resume unmutes the microphone and
  returns unconditionally to `live`

#### Scenario: Pause from end_of_question is a no-op (edge removed)

- GIVEN the candidate is on the `end_of_question` (SA-04 pause) screen
- WHEN any residual Pause affordance is invoked
- THEN nothing happens — the `end_of_question → paused` edge no longer exists; the only
  way to leave `end_of_question` is Resume → `connecting`

#### Scenario: paused implies avatarMounted — the in-avatar resume control is always reachable

- GIVEN the candidate is in the `paused` state
- WHEN the screen is inspected
- THEN the avatar player remains mounted and the resume control is reachable from within
  it; no separate, unreachable "standalone paused" surface exists
