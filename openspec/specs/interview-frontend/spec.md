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
(a) acquires exactly one live camera and microphone stream at a time, re-acquired via a
fresh `getUserMedia` call with `deviceId: { exact }` constraints whenever the candidate
switches camera or microphone, always stopping every track of the previous stream before
the replacement becomes active — never two live streams concurrently, never a camera left
hot after a switch,
(b) verifies the camera produces a live video track,
(c) verifies the microphone produces audio above an RMS threshold after the candidate speaks,
(d) after confirmation, hands the camera stream to the proctoring collector without issuing a
second `getUserMedia`. A candidate MUST NOT be able to proceed to fullscreen until both checks
pass. All device-check UI copy MUST be i18n-keyed.

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

#### Scenario: Device switch releases the previous stream before acquiring the replacement

- GIVEN an active device-check stream from a prior `getUserMedia` acquisition
- WHEN the candidate switches the camera or microphone via the device picker
- THEN every track of the previous stream reports `readyState !== 'live'` before the
  replacement stream's `getUserMedia` call resolves — release-before-replace is an
  ordering, not a race

#### Scenario: Switch fails mid-flight — nothing left hot, pickers stay usable

- GIVEN a device switch is in flight
- WHEN the replacement `getUserMedia` call rejects
- THEN nothing is left live (the previous stream was already released), an actionable
  error is shown, and the device pickers remain usable so the candidate can choose a
  different device instead of being stuck

#### Scenario: Stale deviceId on switch — OverconstrainedError ladder

- GIVEN the candidate selects a device whose id is no longer valid (e.g. unplugged
  between enumeration and selection)
- WHEN the switch's `getUserMedia` call rejects with `OverconstrainedError`
- THEN the system retries once with the constraint dropped (unconstrained), and on
  success reconciles the active selection to the device actually obtained

#### Scenario: Two rapid switches — only the latest stream survives

- GIVEN the candidate switches devices twice in rapid succession, before the first
  switch's `getUserMedia` call has resolved
- WHEN both acquisitions eventually resolve
- THEN only the stream from the LATEST switch becomes active; the superseded stream's
  tracks are stopped and it never becomes the active stream

#### Scenario: Unmount during a switch — the late-arriving stream is stopped, never activated

- GIVEN a device switch is in flight when the device-check screen unmounts
- WHEN the switch's `getUserMedia` call resolves after the unmount
- THEN the late-arriving stream is stopped immediately and never becomes the active
  stream — the only mechanism that stops a stream that did not exist when the unmount
  ran

#### Scenario: Microphone unavailable — recoverable, not a dead end

- GIVEN the acquired stream has no audio track, or `AudioContext` construction throws
- WHEN the device check evaluates the microphone
- THEN the system reports a `micUnavailable` state instead of leaving the check
  permanently unresolved; an explicit Retry (release then re-check) reopens it

---

### Requirement: Device preview geometry

The device-check camera preview MUST fill the full width of its content column and
render at the camera's MEASURED native aspect ratio — never a hardcoded ratio, never
cropped. The ratio MUST be clamped to `[3/4, 21/9]` so a portrait camera cannot produce
an overlong box. Before the ratio is known, the preview MUST hold a placeholder rather
than shift after first paint.

#### Scenario: Ratio unknown before metadata — no layout shift

- GIVEN the device-check screen has just mounted and no video track geometry is known yet
- WHEN the preview renders
- THEN a placeholder holds the expected space; once the track's geometry resolves, the
  common case renders without a visible shift

#### Scenario: Ratio changes on device switch — no crop

- GIVEN an active preview at one camera's aspect ratio
- WHEN the candidate switches to a camera with a different native aspect ratio
- THEN the preview updates to the new ratio without cropping the image

#### Scenario: Portrait camera — clamped, letterboxed not cropped

- GIVEN a camera whose native aspect ratio is narrower than `3/4` (e.g. a 9:16 portrait
  camera)
- WHEN the preview renders
- THEN the container is clamped to the `3/4` floor and the video letterboxes rather than
  being cropped or producing an overlong box

---

### Requirement: Live microphone level meter

The device-check screen MUST expose a live, numeric microphone level (not merely a
pass/fail boolean) with a non-visual equivalent for screen-reader users.

#### Scenario: Visible level moves as the candidate speaks

- GIVEN the device check is evaluating the microphone
- WHEN the candidate speaks
- THEN a visible level indicator moves in response, before the pass state is reached

#### Scenario: Screen reader gets one status announcement, not a continuous live region

- GIVEN a screen-reader user on the device-check screen
- WHEN the microphone level first crosses the pass threshold
- THEN exactly ONE status announcement fires (not a continuously updating live region,
  which would be a screen-reader denial of service), and a static instruction tells the
  candidate to speak

---

### Requirement: Camera and microphone device selection

The device-check screen MUST let the candidate select which camera and microphone to
use, populated from `enumerateDevices()` and kept current on the `devicechange` event.

#### Scenario: Device labels populate only post-grant

- GIVEN the candidate has not yet granted camera/microphone permission
- WHEN the device pickers are populated
- THEN entries with a blank platform label render a numbered fallback name (e.g.
  "Camera 1"), and remain selectable

#### Scenario: Picker list updates live on plug/unplug

- GIVEN the device-check screen is open
- WHEN a camera or microphone is connected or disconnected
- THEN the corresponding picker's option list updates without a page reload

#### Scenario: Denied permission still renders selectable fallback labels

- GIVEN the candidate has denied camera/microphone permission
- WHEN the device pickers render
- THEN they still show numbered fallback labels and remain selectable (selecting one
  does not itself grant permission, but the control is not disabled or hidden)

---

### Requirement: Device preference persistence

The system MUST persist the candidate's device selection in a cookie readable across
every interview locale path (the cookie MUST NOT be scoped to a path narrower than `/`,
since `strategy: 'prefix_except_default'` puts the English locale on
`/en/interview/...`, which a `/interview`-scoped cookie would not cover). A stored
device id that no longer exists MUST fall back to the system default, never a dead end,
and the stored preference MUST be rewritten to whatever was actually obtained.

#### Scenario: Returning candidate gets the same device

- GIVEN a candidate previously selected a specific camera and microphone
- WHEN they return to the device-check screen on a later visit (same locale path)
- THEN the same devices are pre-selected and acquired

#### Scenario: Stored device id gone — falls back to default, preference rewritten

- GIVEN a stored device id that is no longer present on the system
- WHEN the device check runs
- THEN it falls back to the system default device without dead-ending, and the stored
  preference is rewritten to the device actually obtained

#### Scenario: Preference honored regardless of locale path segment

- GIVEN a candidate has a stored device preference set while on one locale's interview
  path
- WHEN they open the interview on a different locale path (e.g. `/en/interview/...`
  after `/interview/...`)
- THEN the same stored preference is honored — the cookie is not scoped to a single
  locale's path segment

---

### Requirement: Instructional and permission-recovery copy

Every step of the device-check screen MUST carry instructional copy, and a denied
permission state MUST show a browser-neutral recovery path — no user-agent-specific
instructions. Zero literal strings: every string MUST be i18n-keyed in both `it` and
`en`.

#### Scenario: Denied-state recovery copy shown

- GIVEN the candidate has denied camera or microphone permission
- WHEN the device-check screen renders the failure state
- THEN browser-neutral recovery guidance is shown (anchored on the address-bar
  permission control every supported browser exposes), along with a Retry control — no
  failure state on this screen is terminal

#### Scenario: Full-screen i18n-key coverage across every state

- GIVEN any device-check state (default, error, confirmed)
- WHEN the rendered output is inspected
- THEN every visible string resolves through an i18n key present in both `it.json` and
  `en.json` — zero literal strings

---

### Requirement: Device-check accessibility

The device-check screen MUST be operable and understandable via assistive technology:
pickers MUST be labelled, the microphone meter MUST have a non-visual equivalent, and
all instructional copy MUST be reachable by a screen reader.

#### Scenario: Picker accessible name and selection announced on focus

- GIVEN a screen-reader user focuses a device picker
- WHEN the picker receives focus
- THEN its accessible name (e.g. "Camera" / "Microphone") and current selection are
  announced

#### Scenario: Zero axe violations across default/error/confirmed states

- GIVEN the device-check screen in its default, error, and confirmed states
- WHEN an automated WCAG 2.1 AA accessibility scan runs against each state
- THEN it reports zero violations, in both Chromium and WebKit

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
any SSR import of either SDK MUST be treated as a build error. Neither provider file MAY
import its SDK at module scope — the import MUST be a dynamic `await import()` reached
only from a function guarded by `import.meta.client`, so each SDK lands in its own lazy
chunk and a candidate on one provider never downloads a byte of the other's SDK.

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
end phrase, exactly as a HeyGen session does.

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

---

### Requirement: Provider opacity — the candidate cannot learn which service is behind the face

Nothing in the shipped product MUST name a specific avatar provider (`HeyGen`,
`LiveAvatar`, `Tavus`, `Daily`/`daily.co`, or `LiveKit`) anywhere a candidate
can read it: not a rendered UI string, not an i18n locale entry, not an error
message surfaced to the candidate, not a code comment inside a candidate-facing
component (a comment ships in nothing rendered, but a developer copying a
nearby line does), and not a DOM element the application itself creates (its id,
class, or attributes).

This is a scoped guarantee, not an absolute one: the provider SDK executes in
the candidate's own browser, so a candidate who opens devtools can still see a
network host such as `daily.co`, a global such as `window._daily`, or a LiveKit
signalling connection the SDK itself establishes. Proxying every media and
signalling host is a different, much larger change. What IS guaranteed is that
nothing the PRODUCT itself renders, sends as copy, or labels reveals the
vendor — a candidate simply taking an interview never learns it, and nobody
learns it by accident from the application's own text or markup.

Provider SDK errors reaching the `InterviewProvider`'s `error` event MUST carry
a stable, provider-independent `code`, never the raw error text
(`String(err)` or equivalent) from the SDK — that text routinely names the
vendor and can echo connection details (a room URL, a host). Any diagnostic
`message` accompanying the code MUST also be scrubbed of vendor identifiers
before being emitted, on the basis that a message which exists is a message
something will eventually render.

#### Scenario: Neither locale file names a provider

- WHEN `i18n/locales/it.json` or `i18n/locales/en.json` is inspected
- THEN neither file contains `heygen`, `liveavatar`, `tavus`, `daily.co` /
  `dailyco`, or `livekit`, case-insensitively

#### Scenario: The interview page and avatar player render no vendor name

- WHEN the source of `app/pages/interview/[token].vue` or
  `app/components/AvatarPlayer.client.vue` is inspected
- THEN neither contains any of the provider vendor names, in code, comments, or
  template markup

#### Scenario: A Tavus SDK failure reports a stable code, not the vendor's error text

- GIVEN the Tavus call-object loader rejects with an error whose message names
  Daily and a `daily.co` room URL
- WHEN the `InterviewProvider` emits its `error` event
- THEN the emitted payload's `code` is a stable value (`sdk_error`) and no
  serialisation of the emitted payload matches a vendor name

#### Scenario: A HeyGen SDK failure reports a stable code, not the vendor's error text

- GIVEN the HeyGen SDK loader rejects with an error naming LiveAvatar
- WHEN the `InterviewProvider` emits its `error` event
- THEN no serialisation of the emitted payload matches a vendor name

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

## ADDED Requirements (C10)

### Requirement: Exit redirect at interview completion (C10)

When the candidate reaches the `done` state (all competency sessions ended — see the
existing Flow Screens requirement), the frontend MUST resolve the project's
`exit_redirect_url` and, if it is a non-null, non-empty string, redirect the browser to
that URL. `exit_redirect_url` is already exposed by the API on the candidate session
resource (`ParticipantResource.project.exit_redirect_url`,
`api/app/Http/Resources/ParticipantResource.php:58`, populated from
`Project.exit_redirect_url`, validated at `StoreProjectRequest.php:74`) — this addendum
consumes it for the first time; no backend change is required.

If `exit_redirect_url` is null or empty, the existing inline `done` branch in
`frontend/app/pages/interview/[token].vue` MUST be shown unchanged — "no further API
calls" per its existing doc comment. (`frontend/app/pages/interview/done.vue` is
unreachable dead code — no `navigateTo('/interview/done')` call exists anywhere in
`frontend/` — and is not the rendered surface; see design.md S15.) The redirect MUST fire regardless of the resulting
`Evaluation` status (`completed` or `pending`, per C9): evaluation is asynchronous and
NOT yet known at redirect time (per
`docs/app_description/04-integration-surface/04-uscita-utente.md` — "la valutazione non
è sincrona con il redirect"), and the frontend MUST NOT wait for it or poll for it before
redirecting.

**Scope note (D8):** this requirement covers ONLY the normal-completion `done` path.
Redirecting from `error`/`terminal` states to a distinct configurable error landing page
is explicitly OUT OF SCOPE for C10 (not requested by the proposal; the binding doc's
"Errore tecnico in intervista → redirect a pagina errore configurabile" case is
unimplemented and remains a future gap).

**Implementation dependency (flagged for design, not a spec requirement):** as of C7b,
no frontend code path calls `GET /api/candidate/session` —
`frontend/app/pages/interview/[token].vue:212-216` hardcodes an empty competency list
with the comment "In production, competency list comes from the C6 bootstrap endpoint."
Delivering this requirement therefore requires the design phase to wire a source for
`exit_redirect_url` (the bootstrap call or an equivalent) into the `done` state path;
this is a design-time concern, not a change to this requirement's observable contract.

#### Scenario: exit_redirect_url set — candidate redirected on done

- GIVEN a project with `exit_redirect_url = "https://hr.acme.com/beai/done?ref=acme-672"`
- WHEN the candidate's session reaches the `done` state (all competencies ended)
- THEN the browser is redirected to `https://hr.acme.com/beai/done?ref=acme-672`
- AND no evaluation-status check or poll precedes the redirect

#### Scenario: exit_redirect_url null — static done page shown, no redirect

- GIVEN a project with `exit_redirect_url = null`
- WHEN the candidate's session reaches the `done` state
- THEN the existing inline `done` branch in `frontend/app/pages/interview/[token].vue` is displayed unchanged
- AND no redirect navigation occurs and no further API calls are made

#### Scenario: Redirect fires identically for a pending evaluation

- GIVEN a project with `exit_redirect_url` set, and the candidate's evaluation will later resolve to `status = pending` (insufficient competency coverage)
- WHEN the candidate's session reaches the `done` state
- THEN the redirect fires exactly as in the completed case — the frontend has no visibility into evaluation status at redirect time and does not differentiate

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

<!-- promoted from frontend-root-landing -->

### Requirement: Root route is an informational dead end

`GET /` MUST render a static, localized orientation screen. It MUST NOT return
404.

The screen MUST tell the visitor exactly one thing: that access to an interview
happens through the link they were sent. That is the whole content, because it
is the only true and actionable statement BEAI can make to somebody standing at
the root — the platform does not know who they are, cannot look them up, and
holds no contact data for them.

The page MUST NOT contain:

- any `<input>`, `<form>`, or `<button>` that submits
- any link or affordance suggesting login, sign-up, or "request access"
- any support contact (email, phone, chat)

These prohibitions are requirements, not guidance. BEAI has no candidate
account, enrolment belongs to the calling system, and BEAI is not the
candidate's support channel — a support address here would route confused people
to the wrong party and imply BEAI can identify them. The absence is asserted by
test, because an absence nobody tests is an absence nobody maintains.

The page MUST make no API call and hold no reactive state.

#### Scenario: A visitor reaches the root

- WHEN `GET /` is requested with a supported desktop browser
- THEN HTTP 200 is returned
- AND the rendered document contains the orientation message
- AND the document contains no form control and no login or sign-up affordance

#### Scenario: The root is not indexed

- WHEN `GET /` is rendered
- THEN the document declares `<meta name="robots" content="noindex, nofollow">`

Consistent with every other candidate-facing route: nothing in this application
should appear in a search result, and a page inviting orientation is exactly the
one a search engine would otherwise surface to the wrong audience.

#### Scenario: The root is localized

- GIVEN the active locale is `it`
- WHEN `GET /` is rendered
- THEN the orientation message is the Italian copy
- AND GIVEN the active locale is `en`, the English copy is rendered instead

#### Scenario: The root has a non-empty document title

- WHEN `GET /` is rendered
- THEN `<title>` is non-empty

WCAG 2.4.2 (Page Titled), the same obligation `/unsupported` already carries.

#### Scenario: The root passes the accessibility gate

- WHEN `GET /` is rendered
- THEN an `axe` scan reports no WCAG 2.1 Level AA violation

#### Scenario: An unsupported browser never sees the root

- GIVEN a Firefox user agent, or a viewport narrower than 1024px
- WHEN `GET /` is requested
- THEN the visitor is redirected to `/unsupported`

The existing global browser gate already produces this: it skips only paths
ending in `/unsupported`, so the root is gated like any other route. Asserted
here so a future change to the gate's skip list cannot silently expose the root
to a device the product does not support — and because telling a phone user to
switch device is more actionable than orientation copy they cannot use yet.

---

## ADDED Requirements (C15)

### Requirement: Failed interviews return the candidate to the calling system

When the interview reaches `error` or `terminal` and the project has a non-empty
`error_redirect_url`, the frontend MUST redirect the browser there.

This closes the gap this spec already records as open, and it matters more than
the success redirect it mirrors. On completion the candidate is finished; on
failure they are stranded on a BEAI screen, on a domain they have no account on,
belonging to a company they have no relationship with. The calling system is the
only party that can tell them whether the interview will be re-issued, who to
contact, or whether their application is affected — BEAI can answer none of
those and must not imply otherwise.

The redirect MUST NOT append an error code, reason or any query parameter. The
binding doc places the query-string format out of scope; inventing one would be
a contract nobody agreed to and no caller reads.

When `error_redirect_url` is null or empty the existing inline screen MUST be
shown unchanged, including its retry affordance. This requirement adds a route
out; it never removes the one that already exists.

#### Scenario: A configured project redirects on error

- GIVEN a project with a non-empty `error_redirect_url`
- WHEN the interview reaches the `error` state
- THEN the browser is redirected to that URL

#### Scenario: The terminal state redirects identically

- GIVEN the same project
- WHEN the interview reaches `terminal` for any reason
- THEN the browser is redirected to the same URL

The candidate's need is identical in both: they cannot continue and they need to
get back to whoever sent them. Splitting the destinations would ask the operator
to configure a distinction their candidates cannot perceive.

#### Scenario: An unconfigured project keeps the inline screen

- GIVEN a project whose `error_redirect_url` is null
- WHEN the interview reaches `error`
- THEN the existing inline error screen is rendered, with its retry button

#### Scenario: The redirect carries no diagnostic payload

- WHEN the redirect fires
- THEN the target URL is used verbatim, with no appended query string

### Requirement: Single-use entry-route exchange

The system MUST expose `/interview/{token}` as an entry route that performs the
sso-link exchange **at most once** and renders no durable UI of its own.

On mount, the entry route MUST, in order:
1. Read the stored candidate session, if any. If it exists, is unexpired, and its
   `candidate_ref` + `project_id` claims match the sso-link's own claims, the exchange
   MUST be skipped and the candidate MUST be navigated directly to the session route.
2. Otherwise call `GET /api/sso/exchange` exactly once, persist the returned candidate
   JWT, and `navigateTo` the token-free session route with `replace: true`.

The session route MUST carry no token in its URL. Refreshing the entry route after
step 2 has completed, or refreshing the session route at any point, MUST NOT trigger a
second exchange call.

`useInterviewSession` MUST NOT read the route token itself; it accepts only
`{ competencies, getPendingIntegrityEvents, onIntegrityEventsFlushed }`. No comment,
code, or documentation MAY claim it reads the token internally.

#### Scenario: First visit exchanges once and lands on a token-free URL

- GIVEN a candidate with no stored session opens a fresh, unspent `/interview/{token}` link
- WHEN the entry route mounts
- THEN exactly one `GET /api/sso/exchange` request is made, the returned JWT is
  persisted, and the browser is navigated to the session route with the sso-link
  token no longer present in the URL or browser history entry

#### Scenario: Refresh after exchange does not burn the link

- GIVEN a candidate has already exchanged and is on the token-free session route
- WHEN the candidate refreshes the page
- THEN no additional `GET /api/sso/exchange` request is made and the interview session survives

#### Scenario: A valid stored session skips the exchange entirely

- GIVEN a candidate has a stored, unexpired candidate session whose `candidate_ref`
  and `project_id` claims match a freshly opened sso-link
- WHEN the entry route mounts
- THEN no `GET /api/sso/exchange` request is made; the candidate is routed directly
  to resume (see Resume on entry)

#### Scenario: useInterviewSession does not read the route token

- WHEN the source of `useInterviewSession` is inspected
- THEN its exported factory accepts only `{ competencies, getPendingIntegrityEvents,
  onIntegrityEventsFlushed }`, and no call to `useRoute()` or a route-token read
  exists inside it
- AND no comment in `frontend/app/pages/interview/[token].vue` or in
  `useInterviewSession` claims the composable reads the token internally

---

### Requirement: Candidate session persistence

The system MUST persist the candidate JWT returned by the exchange in `localStorage`,
bounded by the interview's lifecycle rather than the browser's:
- Cleared on reaching `done`, on reaching `terminal`, on any `401` response from a
  candidate call, and immediately before an exit or error redirect fires.
- Purged on read when the token's `exp` claim has already passed — an abandoned
  session self-cleans on next load without a network round-trip.

The composable MUST expose store, read, clear, and expiry-check operations; no other
module MAY read or write the candidate token directly.

#### Scenario: Token persists across a tab close and reopen

- GIVEN a candidate has an unexpired persisted candidate session
- WHEN the tab is closed and the app is reopened at the session route
- THEN the stored token is still present and is used to resume (see Resume on entry)

#### Scenario: Token cleared on terminal

- GIVEN an active candidate session
- WHEN the session reaches `terminal` for any reason
- THEN the stored candidate token is cleared before any redirect fires

#### Scenario: Token cleared on 401

- GIVEN an active candidate session
- WHEN any candidate API call returns `401`
- THEN the stored candidate token is cleared

#### Scenario: Expired token purged on read

- GIVEN a stored candidate token whose `exp` claim is in the past
- WHEN the composable reads the stored session
- THEN the stored value is discarded and reading returns "no session", without a network call

---

### Requirement: Every candidate request is authenticated

Every request the frontend makes to a candidate-scoped endpoint — the five interview
endpoints (`/start`, `/utterance`, `/integrity`, `/snapshot`, `/end`),
`GET /api/candidate/session`, and the `pagehide` integrity flush — MUST carry
`Authorization: Bearer <candidate JWT>`. No candidate request MAY be issued without
it. A missing or expired stored session MUST prevent the call from being attempted at
all, rather than being sent unauthenticated.

Satisfying this requirement makes two already-specified behaviors reachable for the
first time: the `done`-state exit redirect and the `error`/`terminal`-state error
redirect both depend on `GET /api/candidate/session` succeeding; today that call is
unauthenticated, returns `401`, and is swallowed as non-fatal, so neither redirect has
ever fired in production.

#### Scenario: /start carries the Authorization header

- GIVEN a persisted candidate session
- WHEN the session machine calls `POST /api/candidate/interview/start`
- THEN the request carries `Authorization: Bearer <token>` and does not receive
  `401` for that reason

#### Scenario: No candidate request is ever issued without the header

- WHEN every call site that issues a candidate-scoped request is inspected
- THEN each one is routed through the single authenticated request path; none
  constructs a candidate request without attaching the header

#### Scenario: /candidate/session succeeds and the exit redirect fires

- GIVEN a persisted candidate session and a project with a non-empty `exit_redirect_url`
- WHEN the candidate reaches `done`
- THEN `GET /api/candidate/session` is called with the Authorization header,
  succeeds, and the exit redirect fires (previously unreachable — the call 401'd
  and was swallowed)

#### Scenario: Unauthenticated call never silently succeeds

- GIVEN no stored candidate session
- WHEN a candidate-scoped endpoint is called
- THEN the call is either not attempted, or attempted and the resulting `401` is
  handled by the `401` state (see Honest failure states) — the UI never treats it
  as success

---

### Requirement: pagehide integrity flush is authenticated or its failure is visible

The end-of-session `pagehide` integrity flush MUST deliver the proctoring evidence
batch to the server authenticated, or its failure MUST be surfaced rather than
silently dropped. `navigator.sendBeacon` cannot set request headers, so the
authentication mechanism for this specific call is a design-time decision; this
requirement constrains only the observable outcome.

#### Scenario: pagehide flush reaches the server

- GIVEN pending integrity events at the moment `pagehide` fires
- WHEN the flush is sent
- THEN the server records the batch against the correct candidate session — not a
  silent `401`

#### Scenario: A failed pagehide flush is not silently lost

- GIVEN the pagehide flush cannot be delivered (network failure, rejected auth)
- WHEN the failure occurs
- THEN it is observable (logged, retried, or surfaced) rather than indistinguishable
  from a successful flush

---

### Requirement: Resume on entry via /start

Reaching the session route with a valid stored candidate session MUST trigger a call
to `POST /api/candidate/interview/start` and MUST render a determinate loading state
while the response is pending — never a blank screen. The response governs whether a
session resumes at the persisted `question_index` (backend `RESUME in_corso` path) or
a new competency session is created; the frontend MUST NOT infer or guess this
outcome client-side.

#### Scenario: Reopening after a tab close resumes at the persisted competency

- GIVEN a candidate with a stored, unexpired session who paused mid-interview and
  closed the tab
- WHEN the candidate reopens the app and lands on the session route
- THEN `POST /start` is called, a loading state is shown while it is pending, and
  the interview resumes at the `question_index` the backend returns
- AND the candidate is never shown a blank screen while resuming

#### Scenario: A brand-new candidate proceeds to device check, not resume

- GIVEN a freshly exchanged candidate session with no prior competency progress
- WHEN the session route is reached
- THEN the existing consent/device-check flow governs entry as before; no
  resume-specific screen is shown

---

### Requirement: Honest failure states, including for a paused candidate who cannot be rescued

The system MUST map failure conditions to distinct, honest screens; no condition MAY
produce a silently broken page.

| Condition | Screen |
|---|---|
| Spent link, no stored session (`401` from exchange) | Terminal, no retry — retry cannot succeed |
| Gate or status refusal (`403` from exchange) | Terminal, generic message — no gate detail disclosed |
| Stored session expired (`401` from any candidate call) | Terminal, distinct "session expired" copy |
| Provider / `502` / network | Unchanged — existing retryable `error` |

`401` MUST be a distinct, non-retryable state in the session machine; it MUST NOT
fall into the retryable `error` state and MUST NOT retry indefinitely.

**A newly minted replacement link does NOT rescue a paused candidate.** The
exchange's pre-flight read only proceeds when the participant's status is
`in_attesa`; a paused candidate's status is `in_corso`, so any new, valid, unspent
sso-link presented for that candidate is refused with a generic `403` at the
exchange, identical to any other blocked status. Combined with the 120-minute
candidate JWT and no revocation mechanism, a candidate whose stored session expires
after pausing has no self-serve path back into the interview from this change. The
expired-session terminal screen MUST state this honestly and MUST NOT suggest that
requesting or receiving a new link will help.

**`error_redirect_url` routing is scoped to terminals reached AFTER a candidate JWT
exists — it is structurally impossible before one does.** `GET /api/candidate/session`
(the endpoint `error_redirect_url` is resolved from) requires an authenticated
candidate JWT (`auth:api-candidate` guard), and this proposal's backend-unchanged
constraint (see Proposal, "Out of Scope") forbids adding an unauthenticated variant
of it. Concretely:

- **CAN route through `error_redirect_url`**: terminals reached via `session.vue`'s
  state machine while a candidate JWT is (or very recently was) valid — the existing
  `403`-from-`/start`-or-`/end` path, `absent_phrase`, `malformed_response`, and a
  mid-session `session_expired` (a live `401` on an authenticated call). For all of
  these, `useExitRedirect.fetchSession()` already resolved `error_redirect_url` once,
  authenticated, at page mount — the redirect uses that already-cached value; it does
  not need a new authenticated call at the moment of failure.
- **CANNOT route through `error_redirect_url`**, by construction, not by omission:
  - The entry route's own exchange failures — spent link (`401`) and gate/status
    refusal (`403`). No candidate JWT has ever existed for this attempt; there is
    nothing to authenticate `GET /api/candidate/session` with.
  - The `candidate-session` middleware's gate on `/interview/session` (no valid
    stored session — absent or already expired). By definition, no valid candidate
    JWT exists at this exact point either.

  Both cases show the static, honest terminal screen (`terminal.vue`, keyed by the
  `reason` query param) with no external-redirect capability. This is the correct,
  final behavior for this proposal, not a gap to close later.

#### Scenario: Spent link with no stored session shows terminal, no retry

- GIVEN a candidate opens an already-spent sso-link and has no stored candidate session
- WHEN the exchange returns `401`
- THEN the terminal screen is shown with no retry control

#### Scenario: Gate refusal discloses no detail

- GIVEN the exchange returns `403` for any gate or status reason
- WHEN the terminal screen is shown
- THEN its copy is the generic message; it does not name the specific gate or
  status that blocked it

#### Scenario: Expired stored session is distinct from a spent link

- GIVEN a stored candidate session whose token has expired
- WHEN a candidate call returns `401`
- THEN a terminal screen distinct from the spent-link terminal is shown, with
  "session expired" copy

#### Scenario: 401 does not retry indefinitely

- GIVEN any candidate call returns `401`
- WHEN the session machine processes the response
- THEN it transitions to the non-retryable `401`/terminal state, not to the
  retryable `error` state, and no automatic retry is attempted

#### Scenario: A paused candidate's fresh replacement link is refused, not honored

- GIVEN a candidate whose status is `in_corso` (paused mid-interview, stored
  session since expired)
- WHEN a newly minted, unspent sso-link is exchanged for that same candidate
- THEN the exchange returns `403` with the generic body, exactly as any other
  non-`in_attesa` status; the candidate is not re-admitted

#### Scenario: The expired-session terminal screen does not imply a new link will help

- GIVEN a candidate reaches the expired-session terminal screen, by any path
- WHEN its copy is inspected
- THEN it does not instruct the candidate to request or use a new link

#### Scenario: A mid-session expired terminal (candidate JWT existed) routes through error_redirect_url

- GIVEN a candidate's session was valid when `session.vue` mounted (so
  `useExitRedirect.fetchSession()` already resolved `error_redirect_url`, if
  configured) and the candidate JWT subsequently expires or is rejected mid-session
- WHEN the session machine reaches the `session_expired` terminal
- THEN the candidate is routed through the already-cached `error_redirect_url`
  when configured, and shown the inline expired-session screen otherwise

#### Scenario: A pre-authentication expired/spent terminal does NOT route through error_redirect_url

- GIVEN a candidate reaches `/interview/session` with no valid stored session
  (the `candidate-session` middleware gate), OR the entry route's own exchange
  returns `401` (spent link) or `403` (gate refusal)
- WHEN the terminal screen is shown
- THEN it is the static `terminal.vue` screen with no external-redirect
  capability — no `GET /api/candidate/session` call is attempted, because no
  candidate JWT exists to authenticate it with, and none MAY be attempted
  unauthenticated

---

### Requirement: Genuine authentication is exercised by tests, not mocked

At least one test MUST exercise the full genuine chain — minting an sso-link,
exchanging it for a candidate JWT, and making an authenticated candidate call —
without mocking ANY step of that chain. **This test lives in the api Pest suite**
(`MintExchangeAuthenticatedCallTest.php`), not in the frontend E2E suite — see
"Where the ownership splits" below for why, decided and recorded here rather than
left as an unstated contradiction between this spec and the frontend test files.

**Where the ownership splits.** `frontend/playwright.config.ts`'s `webServer` boots
the Nuxt app alone — no PHP, no Postgres, no Redis (a real API is a named, costed,
NOT-built-here follow-up: standing one up here means new service containers, new
migrations, a seeded org/project, an artisan mint command, and a new class of CI
flake, for a suite that currently has none). There is therefore no real `/api/sso/exchange`
endpoint for the frontend E2E suite to call unmocked; `page.route()` stubs it in
every scenario. This is not a partial implementation of this requirement — it is
the deliberate, permanent shape: **the api Pest test owns the genuine,
end-to-end, nothing-mocked chain; the frontend E2E suite owns the browser-side
half that Pest cannot reach — does the client actually attach the header, and
does a refresh re-exchange — proven via REQUEST-side assertions that a stubbed
RESPONSE does not weaken:** the exchange is called exactly once across a reload
or a stored-session revisit, and the very next candidate call carries
`Authorization: Bearer <the token the stub returned>`. The one residual seam (the
field name on the wire, `access_token`) is covered separately by
`scripts/check-client-drift.sh`.

#### Scenario: The genuine chain is exercised end to end (api Pest)

- GIVEN a minted sso-link
- WHEN it is exchanged and the returned token is used to call a candidate endpoint
- THEN the call succeeds using the real backend chain, with no endpoint in this
  chain intercepted or faked — verified in `MintExchangeAuthenticatedCallTest.php`,
  not in the frontend E2E suite

#### Scenario: The frontend E2E suite proves request-side behavior against a stubbed exchange response

- GIVEN the frontend E2E suite's `webServer` has no real backend to exchange
  against, and `GET /api/sso/exchange` is stubbed via `page.route()` in every
  scenario that needs to get past the entry route
- WHEN the entry route exchanges and the first `POST /candidate/interview/start`
  request is inspected
- THEN it carries `Authorization: Bearer <the token the stub's response
  returned>` — proving the token is genuinely propagated from the exchange
  response into the next authenticated call, not merely that the stub was
  reachable
- AND a reload or a stored-session revisit of the entry URL triggers no more
  than the expected number of exchange calls, asserted by an exchange-call
  counter that is provably sensitive to disabling the stored-session-match
  guard (a test that cannot fail on the thing it names is not kept)

---

## ADDED Requirements (participant-error-recovery)

### Requirement: Error State Copy Never Promises An Unconditional Resume

`interview.error.body` MUST NOT promise that retrying will always succeed. It MUST
state that the interview can be retried now, and that if the problem persists an
operator must re-open the assessment. This is because the underlying failure is
genuinely retryable in some cases (`ClientError`/`Throttle`, which never mark the
participant) and genuinely terminal in others (`Upstream`, which writes `errore` and
requires operator recovery); the copy MUST be true in both cases and MUST NOT
contradict the terminal-403 screen the candidate may hit next.

The existing structural i18n guard
(`frontend/tests/unit/i18n-interview-keys.spec.ts`, the pattern already applied to
`session_expired`) MUST be extended to the `error` state: `interview.error.body` MUST
be added to `REQUIRED_KEYS`, and a locale-specific assertion MUST fail if the body
matches an unconditional-resume pattern — `it: /riprender|dal punto in cui/i`,
`en: /resume|where you left off/i`.

#### Scenario: interview.error.body is required to exist

- GIVEN the i18n structural guard runs
- WHEN `interview.error.body` is missing from either locale
- THEN the test fails, naming the missing key

#### Scenario: An unconditional resume promise fails the guard

- GIVEN a locale's `interview.error.body` matches that locale's resume-promise
  pattern
- WHEN the structural guard runs
- THEN the test fails

#### Scenario: The corrected copy passes the guard

- GIVEN `interview.error.body` states the interview can be retried now and, if the
  problem persists, must be re-opened by an operator
- WHEN the structural guard runs
- THEN it passes in both `it` and `en`
