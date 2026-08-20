# Delta for interview-session

## MODIFIED Requirements

### Requirement: POST /start question_context — prompt_version, server-side system_prompt injection (C8 addendum)

`POST /api/candidate/interview/start` MUST include `prompt_version` as an additive field in
the `question_context` response object, alongside the existing `end_phrase` and
`final_phrase` fields (C7a addendum).

- `prompt_version`: a non-null, non-empty string uniquely identifying the prompt template
  version used for this session (sourced from `config/conversation.php`). Used by C9 for
  traceability — aligns with `Evaluation.prompt_version` (scoring-engine spec).

`prompt_version` is NESTED inside `question_context`, not top-level. Backward-compatible
addition; the five-endpoint contract, C7a failure matrix, and other `question_context`
fields are unchanged.

**SECURITY — the composed system prompt content MUST NOT appear in the `/start` response.**
It embeds BARS indicator anchors used for scoring; exposing it to the candidate client
would leak the scoring rubric. The composed content is delivered ONLY server-to-server,
under whichever wire field name the target provider actually accepts (`prompt` for HeyGen
`POST /v1/contexts`, `conversational_context` for Tavus `POST /v2/conversations`) — **NOT**
under a literal `system_prompt` key on either provider's body; that key does not exist in
either contract. The candidate client receives only `prompt_version`.
(Previously: asserted the composed prompt appears under a literal `system_prompt` wire key.)

#### Scenario: /start returns question_context.prompt_version for standard session
- GIVEN a project with assessment_type='standard', language='en', a competency with BARS indicators
- WHEN `POST /api/candidate/interview/start` returns HTTP 201
- THEN `question_context.prompt_version` is a non-null, non-empty string

#### Scenario: /start response never exposes the composed system_prompt (anti-leak)
- GIVEN a project with language='it', competency PRS with Italian BARS indicators
- WHEN `POST /start` returns HTTP 201
- THEN the response body contains `question_context.prompt_version` and no BARS anchor content
- AND the composed prompt content IS present in the outbound provider request, under that
  provider's own field name — server-to-server only

#### Scenario: Composition failure returns 422 — no session created
- GIVEN language='it' and competency INN has missing Italian anchor translations
- WHEN `POST /start` is called
- THEN HTTP 422; no `InterviewSession` row; no provider call; error carries `anchor_translation_missing`

#### Scenario: Failure matrix unchanged for a genuine provider 5xx
- GIVEN a provider 5xx hard-failure during `/start`
- WHEN `ProviderSessionService::issue()` receives the extended `QuestionContext`
- THEN session status = 'error', participant → errore, HTTP 502 — identical to pre-C8 behavior

#### Scenario: A malformed-request 4xx does not reuse the 5xx failure matrix
- GIVEN `HeygenProvider::issue()` sends a body the provider rejects with a 4xx
  (`client_contract_error`, see the dedicated requirement below)
- WHEN `ProviderSessionService::issue()` receives that rejection
- THEN the participant status is left UNCHANGED (not `errore`) and HTTP 500 is returned, not 502

---

### Requirement: POST /start merges the organization's active avatar template into the provider payload

When issuing a provider session (`ProviderSessionService::issue()`, `HeygenProvider` and
`TavusProvider`), the system MUST resolve the organization's active `AvatarTemplate` (via
`ActiveTemplateResolver`) and merge its config into the outbound provider request(s), using
the `avatar-templates` mapping (`TemplatePayload::heygen()` / `::tavus()`).

For HeyGen, avatar-identity fields (`avatar_id`, `avatar_persona.voice_id`,
`avatar_persona.language`, `interactivity_type`, `video_settings.*`) MUST be merged into
`POST /v1/sessions/token` — NEVER into `POST /v1/contexts`, which accepts only
`{name, prompt, opening_text}` and has no concept of avatar identity. For Tavus, the
template's fields MUST be merged into the single `POST /v2/conversations` body.

Template fields MUST be merged as the BASE, with the composed prompt and opening greeting
applied ON TOP; the template MUST NOT be able to override either. Resolving/mapping the
template MUST NOT be able to fail `/start` — errors degrade to an empty payload fragment.

This is purely additive to the C7a/C8 `/start` contract: create-or-resume, the failure
matrix, and the response shape are unchanged.
(Previously: merged avatar identity into `/contexts` and named the interview-specific
fields as `competency_code`/`question_index`/`system_prompt` — none are real wire fields.)

#### Scenario: An organization's active template configures the HeyGen token call
- GIVEN org O has an active template with `provider='heygen'`, `config={avatarId, voiceId}`
- WHEN a candidate of O calls `POST /start`
- THEN `POST /sessions/token` carries `avatar_id` and `avatar_persona.voice_id`
- AND `POST /contexts` carries none of these fields

#### Scenario: An organization's active template configures the Tavus session
- GIVEN org O has an active template with `provider='tavus'`, `config={faceId, palId, llmModel}`
- WHEN a candidate of O calls `POST /start`
- THEN `POST /v2/conversations` carries the mapped face/PAL/LLM settings alongside
  `conversational_context` and `custom_greeting`

#### Scenario: An organization with no active template sends only interview content
- GIVEN org O has no active template
- WHEN a candidate of O calls `POST /start`
- THEN `/contexts` contains only `{name, prompt, opening_text}`; the Tavus body contains
  only `{replica_id, persona_id, conversational_context, custom_greeting, properties}`

#### Scenario: Template resolution error degrades to empty config
- GIVEN `ActiveTemplateResolver::resolve()` throws
- WHEN `POST /start` is called
- THEN the exception is caught; `/start` succeeds; no template config is sent

#### Scenario: Template mapping error degrades to empty config
- GIVEN an active template's config cannot be mapped (unrecognized provider type)
- WHEN `POST /start` is called
- THEN the mapping error is caught; `/start` succeeds with provider account defaults

#### Scenario: Interview content is never overridden by template
- GIVEN a malformed template config attempts to set `prompt` or `conversational_context`
- WHEN `POST /start` is called
- THEN the outbound request carries BEAI's own composed prompt/greeting, not the override

---

## ADDED Requirements

### Requirement: HeyGen Context Creation Wire Contract

`POST https://api.liveavatar.com/v1/contexts` MUST be called with a body containing EXACTLY
`{name, prompt, opening_text}` — no other keys. The context id MUST be read from `data.id`.
The body MUST NOT contain `competency_code`, `question_index`, `system_prompt`, or any
avatar-identity field.

#### Scenario: /contexts body is the exact three-field shape
- GIVEN a candidate starting a HeyGen interview
- WHEN `HeygenProvider::issue()` builds the `/contexts` request
- THEN the body is exactly `{name, prompt, opening_text}`

#### Scenario: Context id is read from data.id
- GIVEN LiveAvatar returns `{data: {id: 'ctx_123'}}`
- WHEN the response is parsed
- THEN the extracted context id is `'ctx_123'`; a response without `data.id` fails parsing
  rather than yielding an empty id

---

### Requirement: HeyGen Context Name Is Unique and PII-Free

`name` on `POST /v1/contexts` MUST be unique per LiveAvatar account and MUST NOT carry
candidate-identifying information beyond BEAI's opaque `candidate_ref`. `name` MUST be
keyed on `interview_session_id`.

#### Scenario: Two consecutive interviews on the same account both succeed
- GIVEN two candidates each start an interview against the same LiveAvatar account
- WHEN each calls `POST /start`
- THEN each `name` is distinct, derived from its own `interview_session_id`; neither collides

#### Scenario: name carries no PII
- GIVEN a candidate identified only by an opaque `candidate_ref`
- WHEN `name` is built
- THEN it contains `interview_session_id` and no email, display name, or free text

---

### Requirement: Avatar Identity Belongs to the Session-Token Call

`POST https://api.liveavatar.com/v1/sessions/token` MUST carry `mode`, `avatar_id`,
`is_sandbox`, `video_settings`, `interactivity_type`, and
`avatar_persona{voice_id, context_id, language}`. These fields MUST NOT appear on
`POST /v1/contexts`.

#### Scenario: Token call carries full avatar configuration
- GIVEN a HeyGen session with an existing `context_id`
- WHEN `HeygenProvider::issue()` builds `/sessions/token`
- THEN the body carries `mode`, `avatar_id`, `is_sandbox`, `video_settings`,
  `interactivity_type`, `avatar_persona.{voice_id, context_id, language}`

#### Scenario: /contexts never carries avatar identity
- GIVEN any HeyGen `/start` call, with or without an active avatar template
- WHEN the outbound `/contexts` body is inspected
- THEN it contains no `avatar_id`, `voice_id`, `video_settings`, or `interactivity_type` key

---

### Requirement: Transcript Parsing from the Real Provider Response Shape

`GET /v1/sessions/{ref}/transcript` MUST be parsed as `data.transcript_data`, rows keyed
`role`/`transcript`. `reconcileTranscript()` MUST NOT read `data` directly or the key
`content`. A response missing `data.transcript_data` or with malformed rows MUST fail
loudly (throw) rather than silently yield an empty transcript — this feeds C9 scoring, a
~95%-coverage zone.

#### Scenario: A non-empty transcript is parsed correctly
- GIVEN LiveAvatar returns `{data:{transcript_data:[{role:'user',transcript:'Hello'},
  {role:'avatar',transcript:'Hi there'}]}}`
- WHEN `reconcileTranscript()` processes the response
- THEN two `Utterance` rows are produced with correct `role` and text

#### Scenario: A shape mismatch fails loudly
- GIVEN a response without `data.transcript_data` (e.g. legacy `data:[...]`, or a row
  missing `transcript`)
- WHEN `reconcileTranscript()` processes it
- THEN it throws rather than returning zero `Utterance` rows silently

---

### Requirement: Tavus Conversation Wire Contract

`POST https://tavusapi.com/v2/conversations` MUST be called with
`{replica_id, persona_id, conversational_context, custom_greeting, properties}` — no
`competency_code`/`question_index`. The conversation id/URL MUST be read from the
TOP-LEVEL `conversation_id`/`conversation_url`, not nested under `data`. Teardown MUST be
`POST /v2/conversations/{id}/end`, never `DELETE`.

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

---

### Requirement: Tavus Concurrency Self-Heal Before Surfacing 429

On a Tavus concurrency-limit rejection, `TavusProvider` MUST retry creation up to 3
times, 2 seconds apart, BEFORE returning 429. Only after all retries are exhausted
MUST the request degrade to a client-facing 429 `provider_busy`.

`TavusProvider` MUST NOT reap (list-and-end) another active Tavus conversation to make
room for this request. BEAI is multi-tenant; an account-wide "end every active
conversation" self-heal — as legacy-demo's single-tenant `endActiveTavusConversations()`
performed — would terminate another tenant's in-flight interview. That is cross-tenant
data destruction disguised as resilience, and a direct violation of tenant isolation.
Retry-with-backoff is ported; the reap is deliberately, permanently rejected (design D8).

#### Scenario: A concurrency rejection self-heals via retry
- GIVEN a concurrency-limit rejection on the first attempt
- WHEN `TavusProvider::issue()` handles the rejection
- THEN it retries (no reap, no cross-tenant call); a successful retry returns 201, no 429

#### Scenario: Exhausted retries degrade to 429
- GIVEN 3 retries, 2 seconds apart, all still hit the limit
- WHEN `TavusProvider::issue()` gives up
- THEN `/start` returns HTTP 429 `provider_busy`

#### Scenario: No other tenant's conversation is ever queried or ended
- GIVEN any concurrency-limit rejection, retried or not
- WHEN `TavusProvider::issue()` handles it
- THEN no `GET /v2/conversations?status=active` (or any conversation-listing) call is made, and no conversation other than this request's own is ever ended

---

### Requirement: Provider 4xx Is a Client Contract Error, Not a Provider Failure

A provider rejection caused by a malformed BEAI-originated request (HTTP 4xx, excluding
429) MUST be classified as a distinct `client_contract_error`, separate from the existing
retryable (429) and hard-5xx buckets. `InterviewController::handleProviderFailure()` MUST
respond HTTP 500 (not 502 `provider_error`) and MUST leave the participant's status
UNCHANGED (not `errore`). This requirement governs only classification and the immediate
response; it does NOT define recovery — that belongs to `participant-error-recovery`,
sequenced to land after this change.

#### Scenario: A 4xx from a malformed body is not a provider_error
- GIVEN HeyGen rejects `/contexts` with HTTP 422 due to a BEAI-side invalid field
- WHEN `handleProviderFailure()` handles the exception
- THEN the response is HTTP 500, not 502; the participant's status is unchanged

#### Scenario: A genuine 5xx still uses the pre-existing hard-failure path
- GIVEN HeyGen returns HTTP 503
- WHEN `handleProviderFailure()` handles the exception
- THEN session status='error', participant→`errore`, HTTP 502 — unchanged from today

---

### Requirement: Redaction Preserves the Provider's Diagnostic Message

On a provider failure, the exception message and log context MUST include the provider's
own complaint, extracted as `message ?? error ?? data.message`. The extracted string MUST
have the API key stripped via a targeted `str_replace`, not the whole body discarded. The
API key MUST NEVER appear in a log line, exception message, or Sentry event.

#### Scenario: A rejected-field message reaches the log
- GIVEN LiveAvatar responds 422 with `{message:"prompt is required"}`
- WHEN the failure is logged and raised
- THEN both the log context and exception message contain "prompt is required"

#### Scenario: The API key never reaches diagnostics even if echoed
- GIVEN a response body synthetically contains the API key inside `message`
- WHEN the error is extracted and logged
- THEN the text contains `[REDACTED]` in place of the key; the raw key appears nowhere

---

### Requirement: Provider Wire Contracts Are Pinned Against Recorded Real Responses

Tests asserting HeyGen/Tavus request or response shape MUST be backed by a committed
fixture captured from a real provider response (or explicitly documented as
provider-docs-verified) — not a hand-authored stub of BEAI's own assumed shape. A test
built entirely from an invented `Http::fake` response proves only that the parser agrees
with itself; it MUST NOT be cited as evidence the provider accepts the outbound request.

#### Scenario: A fixture-backed test proves parsing, not acceptance
- GIVEN a committed fixture recorded from a real (or docs-verified) response
- WHEN a test asserts the adapter parses it correctly
- THEN the test proves response-shape parsing ONLY — it makes no claim about whether the
  provider accepts BEAI's outbound request body

#### Scenario: A hand-authored stub test is not a substitute for the fixture layer
- GIVEN a test stubs `Http::fake` with a response invented by the test author
- WHEN that test is reviewed against this requirement
- THEN it MUST NOT be cited as evidence of correct wire-contract shape; only the
  fixture-backed layer or the gated live smoke check may be cited for that claim
