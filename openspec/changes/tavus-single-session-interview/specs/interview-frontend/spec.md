# Delta for Interview Frontend

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
   **Tavus advance-on-live-ref branch:** when `POST /start`'s response indicates the existing
   live Tavus conversation is being reused for the new competency (per `interview-session`'s
   advance-on-live-ref path) rather than a freshly issued `provider_token`/`conversation_url`,
   the client MUST NOT tear down or recreate its Tavus call object. Instead it MUST send the
   competency-boundary interaction over the existing Daily data channel and retarget utterance
   attribution to the new competency's `session_id` from the `/start` response — no
   `provider.stop()`/re-`start()` cycle runs for this branch, unlike every other `/start` call
   in this loop.
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
   expires; `ended_reason` MUST be one of `{completed, timeout}`. The Skip control
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

#### Scenario: /end 409 — treated as successful no-op (race condition)

- GIVEN the avatar-completion signal and the per-question timer fire concurrently, causing
  two simultaneous calls to `POST /end`, and the second call returns `409`
- WHEN the client receives the `409` from `POST /end`
- THEN the state machine proceeds exactly as if `/end` returned `200`; no error screen
  is shown; no retry is triggered; the session transitions to `end_of_question` (or `done`
  if on the last competency); this is a successful no-op, not an error

#### Scenario: /end called with ended_reason=completed — transitions to end_of_question

- GIVEN the avatar signals completion via the end phrase
- WHEN `/end` is called with `ended_reason = 'completed'` and returns `200`
- THEN the state machine transitions to `end_of_question`; the End of Question screen is shown
  with progress; the candidate MUST explicitly initiate the next competency (no auto-advance);
  only on candidate action does the next `POST /start` get called

#### Scenario: end_of_question → next /start on candidate action

- GIVEN the `end_of_question` state is active (between competencies; at least one competency remains)
- WHEN the candidate presses the "Next" / "Continue" button
- THEN `POST /start` is called for the next competency; state transitions to `connecting`

#### Scenario: /end on last competency — done screen

- GIVEN the frontend has tracked that `question_index + 1 >= total_competency_count` and `POST /end` returns `200`
- WHEN the state machine evaluates the remaining competency list (from C6 bootstrap) and finds it exhausted
- THEN the done screen is shown directly; no `end_of_question` screen is interposed; no further `/start` call is made; `/end` returned `200` (not `203` — no such variant exists)

#### Scenario: Terminal 403 — redirect to done/terminal screen

- GIVEN the backend returns `403` from any interview endpoint (ParticipantStatusGuard)
- WHEN the client receives the response
- THEN the candidate is redirected to the terminal screen with a localized completion message

#### Scenario: /start response without a fresh provider handle reuses the live Tavus conversation

- GIVEN `POST /start` returns `201` for a competency whose Tavus conversation is already
  live, with the response indicating reuse (no fresh `conversation_url`)
- WHEN the client processes the response
- THEN no new avatar player initialization occurs; the existing call object continues, the
  boundary interaction is sent, and attribution retargets to the new `session_id`

#### Scenario: Every other /start call in this loop is unaffected by the advance-on-live-ref branch

- GIVEN a HeyGen interview, or a Tavus interview's very first competency, or a Tavus
  competency that requires a genuine new conversation (provider session ceiling)
- WHEN `POST /start` is called
- THEN the existing full initialization path (provider player init, timer, proctoring, flush
  intervals) runs exactly as documented above — unchanged by the existence of the
  advance-on-live-ref branch

---

### Requirement: Provider abstraction — provider-neutral behavior

The system MUST implement a provider-neutral `InterviewProvider` interface. The active
provider MUST be selected from the `provider` field of the `/start` response — never
hardcoded. Both HeyGen and Tavus implementations MUST emit the same lifecycle states:
`connecting | ready | listening | speaking | stopped | complete`. Provider SDKs
(`@heygen/liveavatar-web-sdk`, `@daily-co/daily-js`) MUST be imported client-side only;
any SSR import of either SDK MUST be treated as a build error. Neither provider file MAY
import its SDK at module scope — the import MUST be a dynamic `await import()` reached
only from a function guarded by `import.meta.client`, so each SDK lands in its own lazy
chunk and a candidate on one provider never downloads a byte of the other's SDK.

For Tavus specifically, ONE joined Daily call object and its attached `<video>` element
MUST persist across every competency the live conversation covers — creating a new call
object per competency is a regression to the old one-session-per-competency model. HeyGen's
per-competency session and crossfade handover are UNCHANGED by this: HeyGen continues to
obtain a fresh `provider_token` and re-run its existing crossfade for every competency
exactly as before this change; nothing in this delta removes or narrows that path.

The `StartConfig` interface passed to `provider.start()` MUST include typed, named fields for
both provider connection values and completion phrases. The index signature `[k:string]:unknown`
is BANNED (TypeScript strict + exactOptionalPropertyTypes). Explicit API→StartConfig field
mapping: `provider_token` (HeyGen) → `sessionToken`; `conversation_url` (Tavus) →
`conversationUrl`; `question_context.end_phrase` → `endPhrase`; `question_context.final_phrase` → `finalPhrase`.
**`end_phrase` and `final_phrase` are NESTED inside `question_context` in the `/start` response —
they are NOT top-level fields.** Reading them from the top level of the response returns
`undefined`, which triggers the absent-phrase guard and transitions to `terminal`. The
implementation MUST destructure as `response.question_context.end_phrase` (not `response.end_phrase`).

HeyGen completion is detected when the avatar's transcription contains the backend-provided
`end_phrase` or `final_phrase` (accent/case/punctuation-insensitive containment match via
`matchesEndPhrase`). BOTH fields must be present and non-empty; if either field is absent from
the `/start` response, the HeyGen provider MUST emit an `error` event immediately and the state
machine MUST transition to `terminal` (not retryable — retrying `/start` would return the same
absent field; this indicates a version-mismatch or ops error). The terminal screen for
absent-phrase MUST display a distinct localized message: "service temporarily unavailable —
contact support", separate from the `403` terminal message, and MUST include a support-contact
affordance (link or email address).

**Tavus completion is detected primarily via the same spoken-phrase mechanism as HeyGen**: a
`conversation.utterance` app message whose `properties.role === 'replica'` (the avatar, never
the candidate) and whose `properties.speech` contains `end_phrase` or `final_phrase`
(accent/case/punctuation-insensitive, via the same `matchesEndPhrase`). Only the AVATAR's own
speech may end the interview — a candidate who reads the closing line aloud, or is simply
polite, MUST NOT be able to end their own assessment early. A `conversation.tool_call` event
with `name = 'end_interview'` MUST ALSO be honoured as a second, redundant completion path if
it is ever received — it is kept because it costs three lines and would be a more precise
signal the day Tavus registers the tool, but the spoken-phrase path MUST NOT depend on it: a
Tavus session that never receives a `tool_call` message MUST still complete on the spoken
end phrase, exactly as a HeyGen session does. Within a multi-competency conversation, the
spoken-phrase match at a competency's boundary MUST also be capable of being superseded by
the mechanical boundary-detection fallback (see "Mechanical Boundary-Detection Fallback
Independent of LLM Phrase Compliance" below); a competency boundary is not the same event
as the interview-ending completion signal, but both share the same phrase-matching mechanism
and the same paraphrase risk.

**Tavus media path (provider opacity):** the Tavus provider MUST join the conversation as a
Daily call object (`Daily.createCallObject({ audioSource: true, videoSource: false })`), NEVER
via `Daily.createFrame()` or any other mechanism that renders vendor UI into the page. The
call MUST join with the local video track off (`startVideoOff: true`) — the candidate's camera
belongs to the proctoring layer, which owns its own `getUserMedia` stream, and handing the same
device to the conversation SDK as well means two consumers of one camera, which several
browsers simply refuse. Remote media tracks MUST be attached directly to the interview page's
own `<video>` element (never to a vendor-rendered surface), and tracks belonging to the LOCAL
participant (the candidate's own microphone) MUST be ignored — piping the candidate's own audio
back into the avatar's element plays their voice back at them on a delay.

**Tavus microphone control:** `toggleMic()` MUST actually mute and unmute the candidate's
outbound audio via the call object's own audio control (`setLocalAudio`), reflecting the
call object's current state rather than an independently tracked flag that can drift from it.

**HeyGen SDK note (C7b delivered):** The correct SDK class is `LiveAvatarSession` from
`@heygen/liveavatar-web-sdk@0.0.18` (NOT `StreamingAvatar` from the legacy
`@heygen/streaming-avatar` package). Lifecycle: `new LiveAvatarSession(token)` → `start()` →
`attach(el)` → `stop()`. Event names are enum string values: `"avatar.transcription"`,
`"user.transcription"`. Mic: `startListening()` / `stopListening()`. Send: `message(text)`.
Barge-in: `interrupt()`.

#### Scenario: Provider selected from /start response

- GIVEN `/start` returns `{ provider: 'tavus', conversation_url: '...' }`
- WHEN the session starts
- THEN the Tavus provider implementation is initialized; HeyGen SDK is not loaded

#### Scenario: HeyGen completion via end_phrase match

- GIVEN a HeyGen session and `question_context.end_phrase = 'Let us move on.'`
- WHEN the avatar transcription contains "let us move on" (case/accent insensitive)
- THEN the `complete` state is emitted by the HeyGen provider

#### Scenario: HeyGen completion via final_phrase match

- GIVEN a HeyGen session and `question_context.final_phrase = 'Thank you for your time.'`
- WHEN the avatar transcription contains "thank you for your time" (last competency)
- THEN the `complete` state is emitted and `/end` is called with `ended_reason = 'completed'`

#### Scenario: Tavus completes on the avatar's spoken end phrase

- GIVEN a Tavus session and `question_context.end_phrase = 'Passiamo alla prossima domanda.'`
- WHEN a `conversation.utterance` app message arrives with `properties.role = 'replica'` and
  `properties.speech` containing the end phrase
- THEN the `complete` state is emitted — with no `conversation.tool_call` message involved at
  all, since the tool is never registered by Tavus

#### Scenario: Tavus does not complete on the candidate saying the phrase

- GIVEN a Tavus session with a configured end/final phrase
- WHEN a `conversation.utterance` app message arrives with `properties.role = 'user'`
  (the candidate) containing that phrase
- THEN no `complete` state is emitted

#### Scenario: Tavus still honours the tool_call path if it ever arrives

- GIVEN a Tavus session
- WHEN a `conversation.tool_call` event is received with `name = 'end_interview'`
- THEN the `complete` state is emitted and `/end` is called with `ended_reason = 'completed'`
  — a second, redundant path, not the primary one

#### Scenario: The Tavus media path renders no vendor iframe

- GIVEN a mount element containing the page's own `<video>` element
- WHEN a Tavus session starts and joins the call
- THEN `mount.querySelector('iframe')` is null — no vendor-branded surface is ever inserted

#### Scenario: Tavus joins with the camera off

- WHEN a Tavus session starts
- THEN the call object's `join()` is invoked with `startVideoOff: true` — the candidate's
  camera stream is never handed to the conversation SDK

#### Scenario: Remote tracks attach to the page's own video element

- GIVEN a Tavus session has started
- WHEN a remote (non-local) track arrives via `track-started`
- THEN the page's own `<video>` element's `srcObject` carries that track

#### Scenario: The candidate's own microphone track is never attached

- GIVEN a Tavus session has started
- WHEN a track arrives via `track-started` for the LOCAL participant
- THEN the page's `<video>` element's `srcObject` is not set from it

#### Scenario: toggleMic actually mutes and unmutes the Tavus call

- GIVEN an active Tavus session with the microphone on
- WHEN `toggleMic()` is called
- THEN the call object's audio control is invoked to turn the microphone off, and calling it
  again turns it back on

#### Scenario: SSR build succeeds without provider SDKs

- GIVEN the Nuxt SSR build process executes
- WHEN both provider implementations are present in the source tree
- THEN the build completes without importing `@heygen/liveavatar-web-sdk` or
  `@daily-co/daily-js` in the server bundle

#### Scenario: A second competency within a live Tavus conversation reuses the existing call object

- GIVEN an active Tavus call object already joined for competency CSF
- WHEN the interview advances to competency INN within the same conversation
- THEN no new `Daily.createCallObject()` call is made and no new `<video>` element attachment
  occurs; the existing call object and its attached element continue serving INN

#### Scenario: HeyGen's per-competency session and crossfade are unaffected

- GIVEN a HeyGen interview advancing from one competency to the next
- WHEN the transition occurs
- THEN a fresh `provider_token` is obtained and the existing crossfade handover runs exactly
  as before this change — HeyGen never reuses a session across competencies

---

## ADDED Requirements

### Requirement: Utterance Attribution Retargets at a Competency Boundary Without a Race Window

The client's utterance-to-session attribution (the id closed over by the transcript
handler and posted with every `/utterance` call) MUST be retargeted to the new
competency's `InterviewSession` id no later than the moment the avatar begins speaking that
competency's content. No utterance spoken about the new competency MUST be attributable to
the prior competency's session, and no utterance still describing the prior competency
MUST be attributable to the new one. This is an outcome guarantee, not a timing guarantee
about when retargeting code runs — the boundary-detection signal (verbal, mechanical
fallback, or both) and the retargeting write MUST be ordered so that no window exists in
which an utterance can be posted under the wrong session id.

#### Scenario: An utterance spoken before the boundary attributes to the outgoing competency

- GIVEN a live Tavus conversation mid-way through competency CSF, about to advance to INN
- WHEN the candidate's last CSF-related utterance is ingested
- THEN it is persisted against CSF's `InterviewSession` row, never INN's

#### Scenario: An utterance spoken after the boundary attributes to the incoming competency

- GIVEN the boundary from CSF to INN has fired
- WHEN the candidate's first INN-related utterance is ingested
- THEN it is persisted against INN's `InterviewSession` row, never CSF's — including the
  case where it arrives within the same second as the boundary interaction

#### Scenario: No utterance is ever double-counted or dropped across the boundary

- GIVEN a full transcript spanning a CSF→INN boundary
- WHEN every ingested utterance for that participant's conversation is summed across both
  sessions
- THEN the total equals the number of utterances actually spoken; none appear on both
  sessions and none are missing from both

### Requirement: Mechanical Boundary-Detection Fallback Independent of LLM Phrase Compliance

Boundary detection MUST NOT depend solely on the avatar reproducing an instructed phrase
verbatim. A mechanical, server-or-transport-asserted signal MUST also be capable of firing
the boundary — independent of whether the spoken-phrase match (`matchesEndPhrase`)
succeeds — so that a paraphrased closing line still advances the interview and still
triggers attribution retargeting, rather than stalling the conversation on a competency
that has, in substance, already been answered.

#### Scenario: A paraphrased closing line still advances the interview

- GIVEN the avatar concludes a competency with wording that does not literally match the
  instructed end phrase
- WHEN the mechanical fallback signal fires
- THEN the interview advances to the next competency and utterance attribution retargets,
  exactly as it would on a literal phrase match

#### Scenario: The literal phrase match still fires the boundary when it succeeds

- GIVEN the avatar speaks the instructed end phrase verbatim
- WHEN boundary detection runs
- THEN the boundary fires via the phrase match; the mechanical fallback is not needed to
  force it

#### Scenario: A stalled boundary with no mechanical fallback would misattribute every later utterance (the defect this closes)

- GIVEN a hypothetical boundary-detection path with no mechanical fallback and a
  paraphrased closing line
- WHEN later utterances about the next competency are spoken
- THEN — absent this requirement — they would continue attributing to the stale
  competency; this requirement exists specifically to make that outcome impossible

### Requirement: Provider Session Ceiling Handover Extends to Tavus

When a live Tavus conversation approaches `TAVUS_MAX_SECONDS`, the client MUST hand over to
a genuinely new Tavus conversation using the same crossfade mechanism already shipped for
HeyGen's per-competency handover, ungated from the `handle.providerName === 'heygen'`
check. The candidate MUST NOT perceive a break in the interview across this handover: the
avatar view crossfades exactly as it does for a HeyGen transition, and the competency in
progress at the moment of handover continues without losing its place, its utterances, or
its accumulated attribution.

#### Scenario: Approaching the ceiling triggers a crossfade handover for Tavus

- GIVEN a live Tavus conversation approaching `TAVUS_MAX_SECONDS`
- WHEN the ceiling is approached mid-interview
- THEN the client crossfades to a new Tavus conversation using the existing handover
  mechanism, not a hard cut or a visible reconnect

#### Scenario: The competency in progress survives the ceiling handover

- GIVEN the ceiling handover fires while competency DRV is in progress
- WHEN the new conversation takes over
- THEN DRV's `InterviewSession` row, its utterances so far, and its progress are preserved —
  the handover creates a new provider ref, not a new competency

#### Scenario: HeyGen's existing ceiling/crossfade behavior is unaffected

- GIVEN a HeyGen session reaching its own session-length limit
- WHEN its crossfade handover fires
- THEN it behaves exactly as before this change — the ungating adds a new eligible
  provider, it does not alter HeyGen's own path
