# Delta: interview-frontend — provider opacity, Tavus media path, and completion detection

Two shipped defects this delta corrects, both found by reading
`frontend/app/providers/tavus.ts` rather than the original design intent.

The product already promises a candidate a neutral experience — nothing should
reveal which avatar vendor is behind the face. The Tavus implementation broke
that promise in the most visible way possible: `Daily.createFrame()` embedded a
VISIBLE `daily.co` iframe, carrying the vendor's own chrome, directly into the
interview page. Not a subtle tell — the vendor's UI, on screen, in front of the
candidate, named by every DOM inspection.

Separately, Tavus completion was detected SOLELY via a `conversation.tool_call`
app message naming `end_interview` — a tool that is never registered, so the
message never arrives and a Tavus interview ran until timeout instead of
completing. A session that never completes is never scored.

## MODIFIED Requirements

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

## ADDED Requirements

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
