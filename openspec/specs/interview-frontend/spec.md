# Interview Frontend Specification

## Purpose

Defines the candidate-facing Nuxt 4 SSR interview application delivered by C7b:
browser support gate (SA-11), pre-join device check, live avatar interview loop
(per-competency sessions, proctoring collection, integrity/snapshot flush), provider
abstraction consuming the C7a contract, localized flow screens, and the Permissions-Policy
fix required to unblock camera/microphone access on the interview route.

One session = one competency question played in the fixed C4 `project_competencies.position`
order. Adaptivity (C8), BARS scoring (C9), webhook delivery (C10), and admin review (C11)
are explicitly out of scope.

---

## Non-Goals

- Adaptive question selection or AI follow-ups within a competency (C8)
- BARS scoring computation or display; `summarizeIntegrity()` trigger (C9)
- Outbound webhook delivery (C10)
- Backoffice / admin review dashboards (C11)
- GDPR media retention TTL — storage policy is a backend/ops concern (open decision #2)
- Server-enforced `pause_every_n_competencies` — no backend column exists; C7b implements
  pause/resume with client-side state only
- Firefox and mobile browsers are unsupported (not a non-goal — they MUST be gated; see SA-11)

---

## Requirements

### Requirement: Browser Support Gate (SA-11)

The system MUST prevent unsupported browsers from reaching the interview experience.
This gate is a **Firefox-denylist**: Firefox is explicitly rejected; Chrome, Edge, Opera,
and Safari are supported. Detection is split across two layers:

**Server layer** (`useRequestHeaders(['user-agent'])` — SSR only): detects Firefox UA (predicate:
`/Firefox\//i`) and known-mobile UA strings (predicate: `/Mobi|Android|iPhone|iPad/i`). Viewport
width is NOT server-detectable from HTTP headers — pass `Infinity` as the `width` argument to
`isSupportedBrowser` on the server side to skip the width check; only the UA predicates apply.

**Client layer** (`import.meta.client`): detects Firefox UA (`navigator.userAgent`) AND viewport
width `window.innerWidth < 1024` (per DESIGN.md §6: 768–1023 px = tablet = unsupported; ≥1024 px
= desktop). A reactive `window.resize` listener MUST be attached — **this listener lives INSIDE
`useInterviewSession`** (which owns the `provider` instance), NOT in `browser-gate.global.ts`
(a router guard with no provider access). The composable attaches and owns the resize listener.
On resize-triggered redirect, the composable MUST flush integrity (`sendBeacon`) + call
`provider.stop()` BEFORE navigating to `/unsupported`. The resize listener MUST be removed on
transition to `done`/`terminal`/`error` to avoid calling `provider.stop()` on an already-stopped
provider. `provider.stop()` errors during resize teardown are logged and suppressed (non-fatal).
The `browser-gate.global.ts` middleware handles only route-entry gating (SSR UA + client initial
load) — it never directly calls provider methods.

Both layers redirect to the existing `/unsupported` route. The middleware MUST NOT apply its
redirect to `/unsupported` itself (check: `to.path.endsWith('/unsupported')` to cover both
`/unsupported` and `/en/unsupported`, preventing a redirect loop on the non-default locale path).
The gate logic is extracted into the pure testable function
`isSupportedBrowser(ua: string, width: number): boolean` (see D5).

**iPadOS 13+ Safari note:** iPadOS 13+ sends a Mac-like desktop UA string by default
(`Macintosh; Intel Mac OS X`), not `iPad`. Server-side UA detection alone will NOT identify
iPadOS as a mobile/tablet device. The client-side `window.innerWidth < 1024` viewport check is
the authoritative tablet gate and correctly catches iPadOS devices whose UA passes the
server-side filter.

#### Scenario: Firefox redirected to /unsupported (SSR)

- GIVEN an HTTP request with a UA string matching `/Firefox\//i`
- WHEN Nuxt SSR processes any route other than `/unsupported`
- THEN the response is a redirect to `/unsupported`; the interview page is not rendered

#### Scenario: Mobile viewport redirected to /unsupported (client navigation)

- GIVEN a browser with `window.innerWidth` < 1024 px (mobile or tablet)
- WHEN the user navigates to `/interview/[token]`
- THEN the client-side middleware redirects to `/unsupported` before the page mounts

#### Scenario: Tablet viewport (900 px) redirected to /unsupported

- GIVEN a browser with `window.innerWidth` = 900 px (tablet range: 768–1023 px)
- WHEN the user navigates to `/interview/[token]`
- THEN `isSupportedBrowser(ua, 900)` returns `false` and the middleware redirects to `/unsupported`
  (DESIGN.md §6: 768–1023 px is tablet = unsupported)

#### Scenario: Mid-session viewport narrowing triggers gate

- GIVEN an active interview session on a supported desktop viewport (≥ 1024 px)
- WHEN the user resizes the browser window to `window.innerWidth` < 1024 px
- THEN the reactive resize listener flushes the integrity batch via `sendBeacon` and calls
  `provider.stop()` BEFORE redirecting to `/unsupported`; no integrity events are lost

#### Scenario: Supported desktop browser — Chrome — reaches interview page

- GIVEN a Chrome UA on a desktop viewport (width ≥ 1024 px)
- WHEN the user navigates to `/interview/[token]`
- THEN `isSupportedBrowser(ua, width)` returns `true`; the middleware does not redirect

#### Scenario: Supported desktop browser — Edge UA — passes gate

- GIVEN a UA string containing `Edg/` (Chromium-based Edge) on width ≥ 1024 px
- WHEN `isSupportedBrowser(ua, width)` is called
- THEN it returns `true` (Edge is supported; not matched by the Firefox denylist predicate)

#### Scenario: Supported desktop browser — Opera UA — passes gate

- GIVEN a UA string containing `OPR/` (Opera) on width ≥ 1024 px
- WHEN `isSupportedBrowser(ua, width)` is called
- THEN it returns `true` (Opera is supported)

#### Scenario: /unsupported route exempt from middleware redirect (default locale)

- GIVEN a Firefox user-agent
- WHEN the user is already on `/unsupported`
- THEN the middleware early-returns (`to.path.endsWith('/unsupported')`) and does not redirect

#### Scenario: /en/unsupported route exempt from middleware redirect (non-default locale)

- GIVEN a Firefox user-agent
- WHEN the user is already on `/en/unsupported` (i18n-prefixed path)
- THEN the middleware early-returns (`to.path.endsWith('/unsupported')`) and does not redirect
  (exact-match on `to.path === '/unsupported'` would NOT catch this path and cause a loop)

---

### Requirement: Permissions-Policy per-route override

The interview route MUST carry a `Permissions-Policy: camera=(self) microphone=(self)`
response header AND MUST retain all security headers set by the global `/**` rule. All other
routes MUST carry `Permissions-Policy: camera=(), microphone=(), geolocation=()`. This is
implemented as Nitro `routeRules` overrides.

**Nitro header override semantics (critical):** a more-specific route entry **replaces** (does
NOT merge with) less-specific entries. Therefore the interview-route entry MUST explicitly set
ALL headers that `/**` sets, or those headers are silently dropped on interview routes. The
four required headers (exact values matching `frontend/nuxt.config.ts`) are:
- `Permissions-Policy: camera=(self) microphone=(self)` (interview-specific override)
- `X-Frame-Options: DENY`
- `X-Content-Type-Options: nosniff`
- `Referrer-Policy: strict-origin-when-cross-origin`

The override MUST cover BOTH the default-locale path (no prefix, `strategy: prefix_except_default`,
`defaultLocale: 'it'`) AND all non-default-locale prefixed paths. With the current `locales`
configuration (`it`, `en`), the required patterns are `/interview/**` and `/en/interview/**`.
If additional locale codes are added, their `/[locale]/interview/**` patterns MUST be added too.

#### Scenario: Default-locale interview route allows camera and microphone

- GIVEN a GET request to `/interview/[token]` (Italian default, no prefix)
- WHEN the server responds
- THEN the `Permissions-Policy` response header equals `camera=(self) microphone=(self) geolocation=()`;
  `X-Frame-Options` equals `DENY`; `X-Content-Type-Options` equals `nosniff`;
  `Referrer-Policy` equals `strict-origin-when-cross-origin`

#### Scenario: Non-default-locale interview route allows camera and microphone

- GIVEN a GET request to `/en/interview/[token]` (English locale prefix)
- WHEN the server responds
- THEN the `Permissions-Policy` response header equals `camera=(self) microphone=(self) geolocation=()`;
  `X-Frame-Options` equals `DENY`; `X-Content-Type-Options` equals `nosniff`;
  `Referrer-Policy` equals `strict-origin-when-cross-origin`

#### Scenario: Interview routes include explicit geolocation=() directive

- GIVEN a GET request to `/interview/[token]` or `/en/interview/[token]`
- WHEN the server responds
- THEN the `Permissions-Policy` response header contains `geolocation=()` explicitly
  (Nitro replaces headers rather than merging them; an omitted directive is dropped
  entirely, reverting to the browser's permissive same-origin default for geolocation)

#### Scenario: Non-interview routes deny camera, microphone, and geolocation

- GIVEN a GET request to any route outside `/interview/**` or `/en/interview/**`
- WHEN the server responds
- THEN the `Permissions-Policy` response header contains `camera=()`, `microphone=()`,
  AND `geolocation=()`

---

### Requirement: Pre-join device check

Before entering the live interview, the system MUST present a device-check gate that:
(a) acquires a camera and microphone stream via a single `getUserMedia` call,
(b) verifies the camera produces a live video track,
(c) verifies the microphone produces audio above an RMS threshold after the candidate speaks,
(d) hands the camera stream to the proctoring collector without issuing a second
`getUserMedia`. A candidate MUST NOT be able to proceed to fullscreen until both checks pass.
All device-check UI copy MUST be i18n-keyed.

#### Scenario: Both devices confirmed — proceed allowed

- GIVEN a supported browser with camera and microphone available
- WHEN the candidate completes the device check (video track live + mic RMS above threshold)
- THEN the "continue" control is enabled and the single shared camera stream is passed
  to the proctoring collector without a second `getUserMedia` call

#### Scenario: Camera unavailable — proceed blocked

- GIVEN `getUserMedia` throws `NotFoundError` or returns no video track
- WHEN the device check runs
- THEN the camera error state is shown; the proceed control remains disabled

#### Scenario: Microphone RMS never exceeds threshold — proceed blocked

- GIVEN a live video track is present but the candidate does not speak above threshold
- WHEN the device check timer expires without passing the mic test
- THEN the mic error state is shown and the proceed control remains disabled

---

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
5. `POST /end` — called when the avatar signals completion, the per-question timer expires,
   or the candidate skips; `ended_reason` MUST be one of `{completed, timeout, skipped}`.
   A `409` response from `POST /end` MUST be treated as a successful no-op: the session
   was already ended (e.g. avatar-completion and timer-expiry race). The state machine
   MUST proceed exactly as if `/end` returned `200` — no error, no retry. This is
   DISTINCT from the `/utterance` `409` silent-drop: same treatment, different semantic.

A `403` response from any endpoint MUST redirect the candidate to the terminal screen.
A `502` or unexpected error response MUST show the error+retry screen.

**Between-competency flow:** after `POST /end` returns `200` (the only success status — there is
no `203` variant), the state machine transitions to `end_of_question`. The candidate sees the
End of Question screen (progress, next-competency prompt). The candidate initiates the next
competency by an explicit action (button press). Only then is `POST /start` called for the next
competency. The client does NOT auto-call `/start` immediately after `/end`.

**Last-competency detection (client-side):** the frontend tracks the ordered competency list
obtained from the C6 candidate-session bootstrap (project competencies in C4
`project_competencies.position` order). After each `/end` returns `200`, the composable
compares the `question_index` from the preceding `/start` `question_context` (0-based ordinal)
against the total competency count. When `question_index + 1 >= total_competency_count`, no
competencies remain and the state transitions directly to `done` (no `end_of_question` screen
is interposed). The backend does NOT return a special HTTP status for the last competency.

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

---

### Requirement: Provider abstraction — provider-neutral behavior

The system MUST implement a provider-neutral `InterviewProvider` interface. The active
provider MUST be selected from the `provider` field of the `/start` response — never
hardcoded. Both HeyGen and Tavus implementations MUST emit the same lifecycle states:
`connecting | ready | listening | speaking | stopped | complete`. Provider SDKs
(`@heygen/liveavatar-web-sdk`, `@daily-co/daily-js`) MUST be imported client-side only;
any SSR import of either SDK MUST be treated as a build error.

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
affordance (link or email address). Tavus completion is detected via a `conversation.tool_call`
event with `name = 'end_interview'`.

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

#### Scenario: Tavus completion via tool_call

- GIVEN a Tavus session
- WHEN a `conversation.tool_call` event is received with `name = 'end_interview'`
- THEN the `complete` state is emitted and `/end` is called with `ended_reason = 'completed'`

#### Scenario: SSR build succeeds without provider SDKs

- GIVEN the Nuxt SSR build process executes
- WHEN both provider implementations are present in the source tree
- THEN the build completes without importing `@heygen/liveavatar-web-sdk` or
  `@daily-co/daily-js` in the server bundle

---

### Requirement: Localized completion-phrase consumption

The frontend MUST NOT hardcode any completion-signal phrases. The `end_phrase` and
`final_phrase` fields from the `/start` `question_context` payload (the C7a addendum)
are the sole source of completion phrases. The frontend MUST apply
accent/case/punctuation-insensitive containment matching against these backend-provided
strings. If `end_phrase` or `final_phrase` is absent from the response, the HeyGen
provider MUST treat completion detection as unavailable and expose that via the
`InterviewProvider` error state.

#### Scenario: Backend-provided phrase matched case-insensitively

- GIVEN `question_context.end_phrase = 'Passiamo alla prossima domanda.'` (it project)
- WHEN the avatar says "passiamo alla prossima domanda" (lowercased, no trailing period)
- THEN the match succeeds and `complete` is emitted

#### Scenario: Backend-provided phrase matched for en project

- GIVEN `question_context.end_phrase = 'Let us move on to the next question.'` (en project)
- WHEN the avatar says "Let us move on to the next question"
- THEN the match succeeds without any Italian fallback string being evaluated

#### Scenario: Absent end_phrase surfaces as terminal provider error (not retryable)

- GIVEN `/start` returns `question_context` without `end_phrase` (contract violation or
  pre-addendum backend version)
- WHEN the HeyGen provider initializes
- THEN the provider emits an `error` state with a descriptive reason; the **terminal** screen is
  shown (no retry control); the terminal message is DISTINCT from the `403` message and reads
  "service temporarily unavailable — contact support" with a support-contact affordance; the
  error is classified as a version-mismatch / ops error — retrying the same `/start` would return
  the same absent field, so retry cannot recover this condition

#### Scenario: Absent final_phrase also surfaces as terminal (same path as absent end_phrase)

- GIVEN `/start` returns `question_context` with `end_phrase` present but `final_phrase` absent
  (or empty string)
- WHEN the HeyGen provider initializes
- THEN the provider emits an `error` state; the terminal screen is shown with the same
  "service temporarily unavailable — contact support" message; BOTH phrases are required before
  `matchesEndPhrase` may be called

---

### Requirement: Proctoring collection — 13 integrity kinds

The system MUST collect all 13 integrity event kinds during a live session:
`tab_hidden`, `focus_lost`, `second_monitor`, `face_absent`, `looking_away`,
`looking_down`, `too_far`, `multiple_faces`, `fullscreen_exit`, `clipboard_copy`,
`clipboard_paste`, `second_voice`, `phone_detected`. Events MUST be batched and flushed
via `POST /integrity` every `FLUSH_INTERVAL_MS` (10 000 ms). Snapshots MUST be captured
and sent via `POST /snapshot` every `SNAPSHOT_INTERVAL_MS` (10 000 ms) and on snapshot
integrity events. On `pagehide`, the pending batch MUST be flushed via
`navigator.sendBeacon`. APIs that are undefined in a given browser (e.g.
`screen.isExtended` on WebKit) MUST be gracefully guarded (no thrown exception; no-op).
The proctoring collector MUST be implemented as a composable returning an object (not
module-scope singletons) to enable isolation in unit tests.

**phone_detected / ObjectDetector:** The `phone_detected` kind is implemented via MediaPipe
`ObjectDetector` (model: `efficientdet_lite0.tflite`). If the model asset is absent at runtime,
`ensureObjectDetector` catches the initialization error and degrades gracefully — phone detection
is skipped silently; all other 12 integrity kinds continue normally. The `.tflite` asset is
deferred from the initial C7b delivery and MUST be committed in a follow-up (see Known Deferred
Items). The graceful-degradation path is covered by unit tests.

#### Scenario: Integrity batch flushed every 10s

- GIVEN an active session with 3 accumulated integrity events
- WHEN 10 000 ms elapse since the last flush
- THEN `POST /integrity` is called with the 3 events; the batch is cleared

#### Scenario: Snapshot sent every 10s

- GIVEN an active session
- WHEN 10 000 ms elapse since the last snapshot
- THEN the camera frame is captured as JPEG base64 and `POST /snapshot` is called

#### Scenario: pagehide triggers sendBeacon flush with absolute URL and correct Content-Type

- GIVEN an active session with pending integrity events and `runtimeConfig.public.apiBase = 'https://api.example.com'`
- WHEN the `pagehide` event fires (browser closes or navigates away)
- THEN `navigator.sendBeacon('https://api.example.com/api/candidate/interview/integrity', blob)` is
  called where `blob` is a `Blob` constructed with `type: 'application/json'`; the Content-Type
  of the beacon request is `application/json`; no events are lost silently

#### Scenario: screen.isExtended undefined — no-op (WebKit)

- GIVEN a WebKit browser where `screen.isExtended` is `undefined`
- WHEN the proctoring collector initializes
- THEN `second_monitor` detection is skipped without throwing; all other integrity kinds
  continue to be collected

---

### Requirement: Flow screens — localized states

The system MUST present the following named screens, each with all copy i18n-keyed
(locale from the candidate JWT language claim, minimum it/en):

**State machine:** `idle → device_check → connecting → live → end_of_question → paused → done | error | terminal`

**`terminal` vs `error` distinction:**
- `terminal` (no exit, no retry): `403` from any endpoint; absent/empty `end_phrase` or `final_phrase` (version mismatch / ops error). Shows a static localized screen; no retry control.
- `error` (retryable): `502`, network failure, or 3× `provider_busy`. Shows an error+retry screen; retry resets the attempt counter.

| Screen | State machine state | Entry trigger | Exit trigger |
|---|---|---|---|
| Consent | `idle` | Page mount; consent not yet accepted | Candidate accepts consent → `device_check` |
| Device Check | `device_check` | Consent accepted | Both camera + mic confirmed → `connecting` |
| Live Interview | `live` | `/start` returns `201` and provider is `ready` | Avatar signals completion / timer expires / skip → `end_of_question`; `403` → `terminal`; `502` → `error` |
| End of Question | `end_of_question` | `/end` returns `200` (only status) and competencies remain | Candidate presses Next → `connecting` (next `/start`); Candidate presses Pause → `paused` |
| Pause / Resume | `paused` | Candidate presses Pause from `end_of_question` | Candidate presses Resume → `end_of_question` |
| Done | `done` | `/end` returns `200` and no competencies remain (client-side last-competency detection) | Terminal (no exit) |
| Error + Retry | `error` | `502`, network failure, or 3× `provider_busy` | Candidate presses Retry → `connecting` (retry counter reset) |
| Terminal — 403 | `terminal` | `403` from any endpoint | No exit — terminal; localized message: session authorization expired / closed |
| Terminal — absent phrase | `terminal` | `end_phrase` or `final_phrase` absent from `/start` response | No exit — terminal; DISTINCT localized message: "service temporarily unavailable — contact support"; MUST include support-contact affordance |
| Unsupported | — | SSR/client browser gate fires (Firefox, mobile UA, or viewport < 1024 px) | — (existing `/unsupported` page) |

**`paused` state — scoped to client-side only:** no backend call is made on entry to or exit
from `paused`. The `paused` state is entered from `end_of_question` when the candidate
explicitly chooses to pause between competencies. No server-enforced `pause_every_n_competencies`
column exists (per the Non-Goals above); pause is purely client-side state. On resume, the
candidate returns to `end_of_question` and then initiates the next `/start` explicitly.

No literal strings MAY appear in Vue component templates or scripts. Every user-visible
string MUST be an i18n key resolved at runtime.

#### Scenario: Consent screen shown on first load

- GIVEN a candidate navigating to `/interview/[token]` for the first time
- WHEN the page mounts (consent not yet accepted)
- THEN the consent screen is displayed with localized copy; the device check is NOT initiated

#### Scenario: Done screen shown after all competencies

- GIVEN all competency sessions have been ended with `ended_reason ∈ {completed, timeout, skipped}`
- WHEN the last `/end` returns `200` and the session state machine detects completion
- THEN the done screen is displayed with localized copy; no further API calls are made

#### Scenario: Error screen shown on 502

- GIVEN `POST /start` returns `502`
- WHEN the client processes the response
- THEN the error+retry screen is shown with a localized error message and a retry control

#### Scenario: All copy served in project language

- GIVEN a candidate JWT with `language = 'en'`
- WHEN any interview screen is rendered
- THEN all UI labels, button text, status messages, and captions are in English

---

### Requirement: API client typed from generated openapi.json

The frontend MUST consume the five interview endpoints exclusively through a
TypeScript client generated from the C7a-merged `api/develop` `openapi.json`. Hand-authored
request/response types for the interview endpoints are prohibited. The `openapi.json`
MUST be regenerated from the C7a-merged API before any interview endpoint is called
from TypeScript.

#### Scenario: Interview endpoint types present in generated client

- GIVEN `openapi.json` regenerated from C7a-merged `api/develop`
- WHEN `bun run codegen` executes
- THEN `types/api.ts` contains typed definitions for all five `/api/candidate/interview/*`
  endpoints including `question_context` with `end_phrase` and `final_phrase` fields

---

### Requirement: Color token reconciliation

All six brand color tokens in `frontend/app/assets/css/main.css` MUST be reconciled to the
DESIGN.md §3.1 normative values. The font token MUST also be reconciled. Additionally, two
supporting brand tokens (`--color-lavender` and `--color-bg-gradient`) from DESIGN.md §3.1
MUST be present in the reconciled `main.css`. Current `main.css` values are WRONG
(navy/teal/Inter); the DESIGN.md §4 example block that shows those same wrong values is itself
a documentation defect and MUST NOT be followed. The correction of DESIGN.md's own example
block is a C7b deliverable (see D9).

All interview UI components MUST reference semantic tokens (`bg-primary`, `text-muted-foreground`,
etc.) — no raw hex color values in component files.

| Token | Current (WRONG) | Normative (DESIGN.md §3.1) |
|---|---|---|
| `--color-primary` | `#1e3a5f` | `#771AAF` |
| `--color-primary-light` | `#2d5282` | `#C222D3` |
| `--color-primary-dark` | `#132740` | `#4F1AAF` |
| `--color-accent` | `#0d9488` | `#E45526` |
| `--color-accent-light` | `#14b8a6` | `#F19823` |
| `--color-accent-dark` | `#0f766e` | `#B8431E` |
| `--font-sans` | `'Inter', ...` | `"Open Sans", ...` |
| `--color-lavender` | absent | `#8373D2` (supporting secondary — subtle highlights, badges) |
| `--color-bg-gradient` | absent | `linear-gradient(135deg, #FAF7FD 0%, #F6F1FC 45%, #FDF4EF 100%)` (page background gradient; supersedes flat `--color-neutral-50`) |

#### Scenario: Primary color token set to DESIGN.md value

- GIVEN `main.css` is loaded
- WHEN `getComputedStyle(document.documentElement).getPropertyValue('--color-primary')` is read
- THEN the value equals `#771AAF`

#### Scenario: Primary-light color token reconciled

- GIVEN `main.css` is loaded
- WHEN `--color-primary-light` is read
- THEN the value equals `#C222D3`

#### Scenario: Primary-dark color token reconciled

- GIVEN `main.css` is loaded
- WHEN `--color-primary-dark` is read
- THEN the value equals `#4F1AAF`

#### Scenario: Accent color token reconciled

- GIVEN `main.css` is loaded
- WHEN `--color-accent` is read
- THEN the value equals `#E45526`

#### Scenario: Accent-light color token reconciled

- GIVEN `main.css` is loaded
- WHEN `--color-accent-light` is read
- THEN the value equals `#F19823`

#### Scenario: Accent-dark color token reconciled

- GIVEN `main.css` is loaded
- WHEN `--color-accent-dark` is read
- THEN the value equals `#B8431E`

#### Scenario: Font-sans token reconciled to Open Sans

- GIVEN `main.css` is loaded
- WHEN `--font-sans` is read
- THEN the value starts with `"Open Sans"` (not `'Inter'`)

#### Scenario: Lavender color token present

- GIVEN `main.css` is loaded
- WHEN `--color-lavender` is read
- THEN the value equals `#8373D2`

#### Scenario: Background gradient token present

- GIVEN `main.css` is loaded
- WHEN `--color-bg-gradient` is read
- THEN the value equals `linear-gradient(135deg, #FAF7FD 0%, #F6F1FC 45%, #FDF4EF 100%)`

---

## Coverage Note

The ~95% Vitest threshold applies ONLY to the correctness-critical **pure units**:
- `isSupportedBrowser(ua, width)` — Firefox UA rejected, Edge/Opera/Chrome/Safari accepted;
  width < 1024 rejected; Infinity passes for server-side UA-only check
- `useInterviewSession` state machine — all transitions including `terminal`, `429` retry/backoff,
  `409` drop (both `/utterance` and `/end`), `403` terminal redirect, resume-on-remount
- `matchesEndPhrase` — accent/case/punctuation variants; absent phrase → guard fires before call

The following are **NOT** in the Vitest ~95% threshold — they are covered by the **Playwright/E2E
+ CI-build tier** instead:
- `sendBeacon` flush on `pagehide` (needs a real browser context)
- SSR build isolation (no SDK in server bundle — verified by the Nitro CI build succeeding)
- Device-check happy path + camera/mic failure paths (require real `getUserMedia` / Playwright)

The `browser-gate.global.ts` **middleware wrapper** is EXCLUDED from the Vitest 95% threshold.
The middleware integrates the SSR request-headers path (`useRequestHeaders`) — an integration
concern only testable with a real Nuxt request context. SSR-path coverage for the middleware
wrapper is Playwright's responsibility (the chromium/webkit full-flow project navigates with
various UA strings via `browser.newContext({ userAgent })` or a custom fixture).

Playwright projects: chromium + webkit full flow; mobile project asserts the unsupported gate
only (viewport < 1024 px → `/unsupported`). CI SHOULD assert the `routeRules` locale-pattern
count matches the non-default `i18n.locales` count (guards future es/fr/de/pt locale additions).

---

## Known Deferred Items (not blocking archive)

- **`efficientdet_lite0.tflite`**: ObjectDetector model for `phone_detected` not committed in
  C7b delivery. Code degrades gracefully via `ensureObjectDetector` try/catch. Must be committed
  as a follow-up before production (requires Git LFS for `.tflite` files).
- **HeyGen `attach` runtime QA**: `LiveAvatarSession.attach(el)` only callable in a real browser
  context with a valid session token. Runtime behavior needs a real-provider integration test
  environment (no mock can cover this).
- **`useInterviewSession` branch coverage**: settled at 82.71% (dead-code ceiling at lines
  198-202 — unreachable sendSnapshot no-op path). The ~95% spec target was not fully reached
  for this unit specifically; all critical paths are covered.
- **`~/app/` path alias shim**: 23 import sites use `~/app/utils/...` (semantically wrong for
  Nuxt 4 where `~` = `app/`). A regex alias shim in `vitest.config.ts` and `nuxt.config.ts`
  compensates. Should be cleaned up in a follow-up (replace with `~/utils/...` etc.).
