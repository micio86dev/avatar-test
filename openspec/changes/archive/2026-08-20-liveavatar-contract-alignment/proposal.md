# Proposal: LiveAvatar / Tavus Contract Alignment

> **Status of the system today**: `POST /api/candidate/interview/start` fails on **every**
> attempt in production. This is not a degradation — the interview product is down.

## Intent

The C7a/C8 port to Laravel **invented** the LiveAvatar provider contract instead of copying the
one `legacy-demo/` had already proven against the live API. LiveAvatar answers **422** — it is
rejecting our request body. The provider is healthy; our payload is wrong.

The port knew this. `HeygenProvider.php:57-60` says so in its own words:

> `'system_prompt'` field name and the `liveavatar.com/v1/contexts` endpoint are **INFERRED**
> from the C7a scaffold and are **NOT verified** against live provider docs. Client
> confirmation of the real provider contract is **required before live deploy**.

It shipped without that confirmation. The same caveat sits at `TavusProvider.php:50-53`.

**This change replaces every inferred field with the contract the demo actually ran against.**

## Verified current state

Read from the code on 2026-08-19, not from documentation. Every row below was confirmed at the
cited line, in both trees.

### The HeyGen wire contract, demo → port

`legacy-demo/src/pages/api/interview/start.ts:240-268` (`createHeygenContext`) is the ground truth.

| `POST /v1/contexts` | Demo (works) | Port (`HeygenProvider.php:61-92`) |
|---|---|---|
| `name` | required, **unique per account** (`start.ts:250-253`) | **missing** |
| `prompt` | the composed system prompt | renamed `system_prompt` (invented) |
| `opening_text` | the avatar's first spoken line | **missing** |
| `competency_code` / `question_index` | never sent | invented; unknown to LiveAvatar |
| response id | `data.id` (`start.ts:265`) | reads `data.context_id` (invented) |

### The structural bug: avatar identity is posted to the wrong endpoint

This is worse than a set of renamed fields. `start.ts:204-221` is explicit:

> FULL mode: HeyGen provides ASR + LLM + TTS. **All avatar/voice/quality/language config lives
> in the token request.**

The real `POST /v1/sessions/token` body is
`{mode, avatar_id, is_sandbox, video_settings, interactivity_type, avatar_persona:{voice_id, context_id, language}}`.

The port sends `{context_id}` and **nothing else** (`HeygenProvider.php:95-98`), and merges
`TemplatePayload::heygen()` — avatar_id, `avatar_persona.voice_id`, `avatar_persona.language`,
`interactivity_type`, `video_settings.*` — into the **`/contexts`** call instead
(`HeygenProvider.php:80-83`). The mapper is correct; **the merge site is wrong**. Every knob C14
built for operators is being posted to an endpoint that has no concept of an avatar.

### The silent bug that survives the 422 fix

`reconcileTranscript()` (`HeygenProvider.php:151-161`) reads `data` rows keyed `role`/`content`.
The real shape is `data.transcript_data` keyed `role`/`transcript` (`legacy-demo/.../end.ts:76-84`).

Fix the 422 and this one is still there, returning **HTTP 200 with an empty transcript**. C9 would
then score nothing, and the completion gate would emit `pending` evaluations with no visible
cause. Scoring is a ~95%-coverage zone per CLAUDE.md; shipping the visible fix while leaving this
one is how a second, quieter incident gets created.

### One defect, two wrong verdicts

`ProviderException::isRetryable()` is a binary flag set by `$retryable = $status === 429`
(`HeygenProvider.php:199`). Every other status — 400, 401, 422, 500, 503 — lands in the same
bucket. `InterviewController::handleProviderFailure()` (`:590-620`) then:

1. returns **502 Bad Gateway** — which blames the upstream for a request **we** malformed; and
2. flips the participant to **`errore`**, which is terminal (`Participant.php:115` → `[]`), so
   `ParticipantStatusGuard` 403s every later attempt and `EntryLinkMinter` refuses to re-mint.

So a payload bug in our own code **permanently burns the candidate**, on the first attempt, with
no operator path back. See `interview/participant-terminal-errore-trap`.

### Why this needed a production log dive

`throwRedacted()` logs a status code and discards the body (`HeygenProvider.php:197-212`) to keep
`HEYGEN_API_KEY` out of Sentry. The demo instead surfaces
`payload.message ?? payload.error ?? payload.data.message` (`start.ts:260-263`) with this comment:

> a 400 here is almost always a **rejected field** (prompt/opening_text), and the body says which.

Full-body redaction is the right default. Discarding the provider's own one-line complaint is not
— it turned a five-minute diagnosis into a Railway log excavation.

### The tests and the specs defend the bug

- `api/tests/Unit/C7a/HeygenProviderTest.php:34` fakes `['data' => ['context_id' => 'ctx-abc']]`.
- `api/tests/Feature/C8/HeygenProviderPayloadTest.php:56-117` asserts `toHaveKey('system_prompt')`.
- `openspec/specs/interview-session/spec.md:962-965` **ratifies** "the outbound HeyGen
  `POST /contexts` request body carries `avatar_id` … and `avatar_persona.voice_id`". The spec
  codifies the wrong endpoint.
- `openspec/specs/interview-session/spec.md:326-376` uses `system_prompt` as the literal wire name.
- **Newly found, beyond the exploration**: `openspec/specs/avatar-templates/spec.md:248-252`
  ratifies the merge target as "the existing `competency_code` / `question_index` /
  `system_prompt` body". A third spec block encodes the invented contract.

The suite was green the whole time, because every test faked our own invention. That is the real
lesson of this incident and it drives the Verification Strategy below.

## Scope

### In Scope

| # | Deliverable |
|---|---|
| 1 | HeyGen `POST /contexts` body → `{name, prompt, opening_text}`; response read → `data.id` |
| 2 | HeyGen `POST /sessions/token` body → full real shape; **`TemplatePayload::heygen()` merge site moves here** |
| 3 | Unique, PII-free context `name` strategy (see Decision 2) |
| 4 | `reconcileTranscript()` → `data.transcript_data`, keyed `role`/`transcript` |
| 5 | Tavus: drop invented `competency_code`/`question_index`; add `custom_greeting`; teardown → `POST /v2/conversations/{id}/end` |
| 6 | A third error class for **client-side 4xx** — not 502, not terminal `errore` (see Boundary) |
| 7 | Redaction that preserves the provider's message field with the API key stripped from it |
| 8 | Correct the tests that pin the invented shape — **RED first**, per strict TDD |
| 9 | Delta spec amending **three** ratified blocks: `interview-session` (2), `avatar-templates` (1) |
| 10 | A contract-fixture test layer + a gated live smoke check (see Verification Strategy) |

### Out of Scope

- **Redesigning participant recovery.** Making `errore` recoverable, admin retry endpoints, and
  widening `$allowedTransitions` belong to **`participant-error-recovery`** (explored,
  `sdd/participant-error-recovery/explore`). See Boundary — both changes touch the same two files.
- **`device-check-preview-and-device-selection`** — separately explored, untouched here.
- **Tavus concurrency self-heal** (`endActiveTavusConversations` + 3×2s retry, `start.ts:270-361`).
  Real, absent, and worth porting — but it is a Tavus free-tier resilience feature, not the HeyGen
  outage. Deliberately deferred to its own slice (PR 5, droppable).
- **HeyGen `teardown()`.** `DELETE /v1/sessions/{ref}` has **zero demo evidence** — the demo has no
  REST teardown at all. Replacing an unverified inference with a *different* unverified inference
  buys nothing. Leave as-is, flagged; it is best-effort and non-fatal today.
- **CLAUDE.md's open "retry semantics" decision** (product decision #4). Untouched.

## Boundary with `participant-error-recovery`

Both changes touch `handleProviderFailure()` and `ProviderException`. The split:

| This change | `participant-error-recovery` |
|---|---|
| Make our own 4xx stop happening | Decide what happens after a **genuine** provider failure |
| Add a `client_contract_error` class → 500, session `error`, participant **untouched** | Decide whether `errore` is recoverable at all, and how |
| Preserve the diagnostic message so drift is caught in minutes | Operator/candidate recovery paths, admin retry |

**Sequencing recommendation: this change lands first.** It is a live outage; the other is a
resilience improvement over a state this change makes far rarer. `participant-error-recovery` then
rebases onto the three-way classification rather than inventing its own.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- **`interview-session`** — the C8 addendum (`:326-376`) must stop naming `system_prompt` as the
  wire field; the `avatar-provider-templates` ADDED requirement (`:930-1004`) must move avatar
  identity from `/contexts` to `/sessions/token` and drop `competency_code`/`question_index` from
  every scenario. The failure-matrix scenario at `:371-375` ("provider 5xx → participant errore,
  502") stays true for 5xx and gains a **4xx** counterpart.
- **`avatar-templates`** — `:248-252` names the merge target by its invented field list; the
  byte-identical-when-empty guarantee survives verbatim, only the call site changes. The
  `TemplatePayload` mapping requirements (`:284-329`) are **unchanged and correct**.
- **`interview-conversation`** — only if Decision 1 puts `opening_text` composition next to
  `SystemPromptComposer`. Confirm in `sdd-spec`.

## Decisions

### Decision 1 — Where does `opening_text` come from? *(OPEN — needs sign-off)*

**This is the one genuine product decision in the change, and it must not be buried.**

BEAI has no source for the avatar's first spoken line. `QuestionContext` carries
`competencyCode`, `questionIndex`, `systemPrompt`, `promptVersion` — nothing else.
`SystemPromptComposer::compose()` emits instruction-only text and explicitly says the BARS
coverage topics must not be revealed verbatim. The demo had `greeting = intro + q.text` from a
fixed `questions.json`; BEAI's interview is **adaptive and multi-indicator per competency**, so
there is no `q.text` to speak.

Three hard constraints on any answer:

1. **It is spoken to the candidate.** It MUST NOT contain BARS anchor or indicator text — the same
   anti-leak rule `interview-session/spec.md:341-349` already imposes on the response body.
2. **It must respect the project locale** (`it`/`en` mandatory per CLAUDE.md).
3. **Fresh start and resume differ.** The demo had `intro` vs `resumeGreeting`. BEAI's
   create-or-resume path currently has no equivalent; a resumed session would re-greet from zero.

**Proposed interim default, for approval — not adopted silently:** a locale-keyed template string
in `config/conversation.php`, versioned alongside `prompt_version`, rendered with
`competency.name` — e.g. `it`: *"Parliamo di {competency}."*, `en`: *"Let's talk about
{competency}."* — with a distinct first-question variant carrying a one-line interview intro and a
distinct resume variant. Cheap, locale-correct, leaks nothing, and traceable through the existing
`prompt_version` field.

**A prior question design must answer first: is `opening_text` actually required?** If LiveAvatar
accepts the context without it, omitting it is the smallest correct fix — but the avatar may then
sit silent in front of a candidate, which is worse than a generic opener. Determine this from the
live API before choosing.

**Recommendation to the orchestrator: put this question to the user before `sdd-design` closes.**

### Decision 2 — The context `name` *(recommendation stated; design confirms)*

Must be unique per LiveAvatar account (a stable name collided on every interview after the first,
`start.ts:250-252`) and must carry **no candidate PII** — BEAI holds only an opaque
`candidate_ref` (ratified decision #8) and has no contact data at all.

**Recommendation: `beai-{interview_session_id}`.** Already globally unique, already opaque,
already monotonic, and — unlike the demo's `Date.now()` suffix — it makes the LiveAvatar console
row traceable back to one BEAI session, which is exactly what the next incident will need.
A resume reuses the session, so add a per-attempt suffix **only if** the design keeps creating a
fresh context on resume.

### Decision 3 — Redaction keeps the message, loses the key *(taken here)*

Extract `message ?? error ?? data.message` mirroring `start.ts:262`, run
`str_replace($apiKey, '[REDACTED]', $extracted)` over it, and put the result in both the
`ProviderException` message and the log context. The existing worst-case test — which synthetically
forces the key into a 5xx body to prove redaction — must keep passing unchanged, and becomes the
regression guard for the new path.

## Approach

Fix the whole contract in one change, but land it as a **chained PR series** ordered so the
diagnosability fix ships **first** — so if a later slice is still wrong, the provider tells us why
in the log instead of hiding behind a status code.

| PR | Content | Est. lines |
|---|---|---|
| 1 | Redaction-with-diagnostics + `client_contract_error` class (both providers, `ProviderException`, `handleProviderFailure`) | ~140 |
| 2 | HeyGen `/contexts` + `/sessions/token` rewrite, template merge site moved, unique `name`, `opening_text`; corrected tests RED-first; the three spec deltas | ~300 |
| 3 | `reconcileTranscript()` → `transcript_data`/`transcript` + the fixture/contract test layer | ~150 |
| 4 | Tavus alignment: drop invented keys, `custom_greeting`, `POST …/end` teardown | ~130 |
| 5 | *(droppable)* Tavus concurrency self-heal | ~130 |

Every slice is independently shippable and independently valuable. PR 1 improves production the
day it lands even if nothing follows it.

### Changed-line forecast

```
400-line budget risk: High
Chained PRs recommended: Yes
Decision needed before apply: Yes
```

**~850 lines across PRs 1–4** (~980 with PR 5), against a 400-line budget. Roughly 45% is test
code: three files pin the invented shape, four more (`InterviewStartTest`,
`InterviewStartPhrasesTest`, `InterviewStartCompositionTest`, `ProviderSecretTest`) need auditing
against the corrected contract, and the new fixture layer is net-new. Single-PR delivery is not
viable. `Decision needed before apply` is **Yes** for two independent reasons: the slice plan
above, and Decision 1.

## Verification Strategy

**Mocks caused this defect.** `Http::fake(['*liveavatar*/contexts*' => Http::response(['data' =>
['context_id' => …]])])` asserts that our code agrees with our own guess. It cannot disagree.
The suite was green while production was 100% broken, and no amount of additional `Http::fake`
tests would have changed that. Four layers, and **none is sufficient alone**:

| Layer | Proves | Does **not** prove |
|---|---|---|
| **Fixture/contract tests** — a committed real (or docs-verified) LiveAvatar/Tavus response, asserted through the provider parser | Response **parsing** is right. Would have caught `context_id` vs `id` and `transcript_data` | Nothing about the **outbound** body. LiveAvatar can still 422 while this test stays green |
| **Gated live smoke check** — real key, real call, env-flagged, never in normal CI (it costs provider credits) | The outbound request is **accepted**. The only layer that can prove this, and the only one that would have caught the original 422 | That *production's* key/avatar/template combination works — a different account can still fail |
| **Staging canary** — post-deploy synthetic `/start` against the real provider in the deployed environment | The **deployed configuration** works end to end. Would have caught this on the first deploy, before any candidate | Nothing about code correctness; it fails after the fact, not before merge |
| **Existing `Http::fake` unit tests** | Failure-matrix, redaction, and retryable classification — their actual job | Request **shape**. That claim must be revoked from them explicitly |

**Highest value for the least cost: the staging canary.** This defect reached live candidates
because nothing ever exercised the real provider after deploy. Recommend it as a hard requirement
of this change, not a nice-to-have.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Services/Provider/HeygenProvider.php` | Modified | `issue()` rewritten across both calls; transcript parsing; redaction |
| `api/app/Services/Provider/TavusProvider.php` | Modified | Invented keys removed, `custom_greeting`, teardown, redaction |
| `api/app/Services/Provider/QuestionContext.php` | Modified | Carries the opening line (shape per Decision 1) |
| `api/app/Services/Conversation/SystemPromptComposer.php` | Modified? | Only if Decision 1 sites composition here |
| `api/app/Exceptions/ProviderException.php` | Modified | Third classification beyond retryable/hard |
| `api/app/Http/Controllers/Candidate/InterviewController.php:590-620` | Modified | 4xx → 500, participant untouched |
| `api/app/Support/AvatarTemplates/TemplatePayload.php` | **Unchanged** | Mapping is correct; only its call site moves |
| `api/tests/{Unit/C7a,Feature/C7a,Feature/C8}/…` | Modified | 3 pinning the bug + 4 to audit; RED first |
| `openspec/specs/interview-session/spec.md:326-376, 930-1004` | Delta | Ratified text encodes the wrong contract |
| `openspec/specs/avatar-templates/spec.md:248-252` | Delta | Merge target named by invented fields |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| 1. `opening_text` has no BEAI source — Decision 1 blocks PR 2 | **Certain** | Surface to the user now; interim default proposed above; establish first whether the field is required at all |
| 2. Amending **three ratified spec blocks** needs sign-off, not a silent overwrite | Certain | Delta specs authored explicitly in `sdd-spec`; the amendment is itself reviewable |
| 3. The corrected `/sessions/token` body still 422s on fields the demo never sent — `voice_settings.*`, `video_settings.encoding`, `max_session_duration` come from `avatar-tester`, **not** from the proven demo call | **Med-High** | The gated live smoke check is the only thing that can settle this. Consider sending only demo-proven fields until smoke-verified |
| 4. Collision with `participant-error-recovery` on the same two files | **High** | Explicit boundary above; this change sequenced first |
| 5. `HeygenProvider::teardown()` stays unverified | Med | Out of scope, flagged, non-fatal today. Do not swap one inference for another |
| 6. Tavus tests pass for the right reason *and* the wrong one simultaneously | Med | `TavusProviderPayloadTest` correctly asserts `conversational_context`; a blanket "make Tavus match the HeyGen fix" would break it. Fix only what is wrong |
| 7. Railway `HEYGEN_API_KEY` / `INTERVIEW_PROVIDER` presence was **inferred** from a 422 (auth succeeded, body rejected), never directly confirmed | Med | Confirm via Railway tooling during `sdd-apply` |
| 8. An org with no C14 template now sends no `language` to Tavus, where the demo hardcoded `italian` | Low | Behaviour delta, not a defect — C14 ratified "empty config → empty payload". Record, do not fix here |

## Rollback Plan

PRs 1–5 are independent commits touching disjoint concerns; revert any slice alone.

**No migrations, no schema, no data.** Nothing to un-write. Reverting restores a provider payload
that 422s on every call — i.e. rollback returns the product to a total outage, which makes
roll-**forward** the only real recovery path. Size each slice so it can be fixed forward.

The spec deltas revert with their PR. Sessions created while a slice was live carry no incompatible
state: `provider_session_ref` is opaque to us either way.

## Dependencies

- C7a, C8, C14 — all delivered.
- **Decision 1 sign-off** blocks PR 2, and only PR 2. PRs 1, 3, 4 proceed without it.
- A real LiveAvatar API key for the gated smoke check.
- Railway confirmation of `HEYGEN_API_KEY` / `INTERVIEW_PROVIDER` (Risk 7).

## Success Criteria

- [ ] `POST /api/candidate/interview/start` returns **201** against the live provider, and a
      candidate reaches the avatar.
- [ ] The `/contexts` body is exactly `{name, prompt, opening_text}`; the context id is read from
      `data.id`.
- [ ] `avatar_id`, `avatar_persona.voice_id`, `avatar_persona.language`, `interactivity_type` and
      `video_settings` appear on `POST /sessions/token` — and on **no** other call.
- [ ] Two consecutive interviews on the same LiveAvatar account both succeed (proves the uniqueness
      fix; the collision only appeared from the second interview onward).
- [ ] `reconcileTranscript()` returns non-empty, correctly-attributed rows from a real transcript
      payload — asserted against a committed fixture, not a hand-written fake.
- [ ] A provider **4xx** yields HTTP 500 and leaves the participant's status **unchanged**; a
      provider **5xx** behaves exactly as before.
- [ ] A provider error message is readable in the log and in Sentry, **and** the API key does not
      appear anywhere in either — both asserted, in the same test.
- [ ] No test asserts a provider field name that is not backed by the demo, a fixture, or provider
      documentation. Where a name is still inferred, it is labelled as such in the code.
- [ ] The three amended spec blocks describe the shipped contract, with the amendment signed off.

## Proposal Question Round

Not asked interactively — execution mode is `automatic`. Each of these is a product decision the
spec and design phases must **not** answer alone.

1. **What should the avatar say first?** Decision 1. Confirm the interim generic opener, or name a
   different source. Note the prior question: establish whether `opening_text` is required by
   LiveAvatar at all — if it is optional, "say nothing" is a real option, with the cost that the
   candidate meets a silent avatar.
2. **Should a resumed interview be re-greeted?** The demo distinguished `intro` from
   `resumeGreeting`; BEAI's create-or-resume path has no equivalent, so today a resume would open
   as if it were a fresh start.
3. **Do we accept a gated live smoke check that consumes real provider credits?** It is the only
   layer that can prove an outbound request is accepted. Declining it means accepting that this
   class of defect can only be caught in production again.
4. **Ship PR 1 alone as an immediate hotfix?** It does not fix the outage, but it makes the next
   contract failure diagnosable in minutes instead of a log dive — and it stops burning candidates
   permanently for our own bugs. Fastest independent value in the series.
5. **Confirm the sequencing against `participant-error-recovery`.** This change first, that one
   rebased onto the new classification — or the reverse, which would mean waiting out an active
   production outage.
