# Design: LiveAvatar / Tavus Contract Alignment

## Technical Approach

Replace every inferred provider wire field with the one `legacy-demo/` proved against the live API,
and make the *next* drift loud instead of silent. Three axes, in this order of priority:

1. **Diagnosability first** — the provider's own complaint reaches the log with the key stripped, and
   our own 4xx stops burning the candidate. Ships before any wire change, so if a later slice is
   still wrong, the provider tells us why in one line instead of a Railway log dive.
2. **Wire correction** — `/contexts` becomes `{name, prompt, opening_text}` reading `data.id`;
   `/sessions/token` receives the avatar-identity block that C14 built and C7a posted to the wrong
   endpoint; Tavus drops invented keys and gains `custom_greeting`.
3. **Drift detection** — a four-layer verification ladder that is explicit about what each layer
   proves and, more importantly, what it cannot.

`TemplatePayload.php` is **not modified**. The exploration confirmed the mapper is correct; only its
call site is wrong. Keeping that ~180-line file out of the diff is a design constraint, not an
accident — it keeps the review focused on the call sites that actually lied.

---

## Findings that changed the design

Two things were verified during design that neither the exploration nor the proposal had:

**F1 — `replaceUtterances()` DELETEs before it checks for empty.**
`InterviewController.php:715` runs `DB::table('utterances')->...->delete()` *unconditionally*, and
the `if (empty($transcript)) return;` guard is at `:717` — **after** the delete. So the transcript
parsing bug (D7) does not merely "return an empty transcript". On every HeyGen `/end` it **destroys
every live utterance row already persisted** and inserts nothing. The candidate's transcript is
gone, C9 scores nothing, and the completion gate emits `pending` with no visible cause. This
escalates D7 from a correctness bug to data destruction and is why it fails loud rather than
degrading.

**F2 — the frontend already maps 500 to the retryable `error` state.**
`frontend/app/composables/useInterviewSession.ts:515-516`: `// 502 or any other error → retryable
error` → `transitionTo('error')`. The 502→500 change in D4 therefore needs **no frontend change**
and no frontend PR. Better: because D4 leaves the participant untouched, the existing copy
*"you will resume where you left off"* (`interview.error.body`) becomes **true** for this class —
today it is a lie that the next request converts into a 403 dead end.

**F3 — `handleResumeInCorso()` calls `issue()` again for the same session.**
`InterviewController.php:485`. So `beai-{interview_session_id}` alone **collides on every resume** —
the exact failure mode `start.ts:250-252` documents. D3 needs a per-issue suffix, not just a
per-session identifier.

---

## Architecture Decisions

### D1 — The wire contract stays inline, but every field carries provenance

Named private builder/reader methods on each provider (`buildContextBody()`,
`buildSessionTokenBody()`, `readContextId()`), each with a `@wire-source` docblock citing the exact
`legacy-demo` file:line — or, where no demo evidence exists, saying so in those words.

| Option | Verdict |
|---|---|
| Request/response DTO classes (`HeygenContextRequest`, …) | **Rejected.** A DTO verifies nothing. It adds a third place each field name is spelled (`TemplatePayload` → DTO → wire) and would have shipped the invented names just as confidently. The defect was unverified provenance, not unstructured arrays. |
| A shared `ProviderWireContract` abstraction across both providers | **Rejected.** HeyGen splits across two calls with different bodies; Tavus is one call. The common supertype would be a union of everything, i.e. no contract at all. |
| **Named builders + `@wire-source` provenance (chosen)** | Puts the field names in one readable block per call, and makes "where did this name come from?" answerable in review — which is the question nobody asked on the C7a PR. |

**Implementation invariant — the merge is recursive, not shallow.**
`TemplatePayload::heygen()` emits `avatar_persona.voice_id` and `avatar_persona.language`. The
provider owns `avatar_persona.context_id`. Today's `array_merge()` (`HeygenProvider.php:80`) is
**shallow**: at the token call site it would replace the whole `avatar_persona` node and silently
drop voice and language — reintroducing C14's "operator sets a voice, hears no difference" failure
at a new address. Use `array_replace_recursive(TemplatePayload::heygen($cfg), $providerOwned)`, and
pin it with a test asserting all three of `avatar_persona.{voice_id, language, context_id}` survive
together.

### D2 — Unproven token fields are opt-in per field, default off

`TemplatePayload::heygen()` emits three groups with **no demonstrated-working call behind them** —
`voice_settings.*` (5 keys), `video_settings.encoding`, `max_session_duration`. They came from
`avatar-tester`, a testbed. `start.ts:206-221` sends only
`{mode, avatar_id, is_sandbox, video_settings.quality, interactivity_type, avatar_persona.*}`.

**Chosen: a dot-path allowlist applied at the call site.**
`HeygenProvider::TOKEN_FIELD_ALLOWLIST` = the demo-proven set, unioned with
`config('interview.heygen.extra_token_fields', [])` (default `[]`, env-driven). The mapper keeps
emitting everything; the provider sends only what is allowlisted.

| Option | Cost of being wrong |
|---|---|
| Send them all | **Total outage.** A second 422 on every `/start`, another production debug cycle — the exact defect being fixed. |
| Drop them from `TemplatePayload` | Puts the ~180-line correct file into the diff, and discards a mapping that is probably right, just unproven. |
| **Allowlist, default off (chosen)** | A C14 cosmetic knob is inert until D10's smoke check widens the config. No deploy needed to widen — a config change, verified per field. |

The asymmetry is decisive: outage versus an inert voice-speed slider. **This is a known, recorded
behaviour delta, not a silent one** — the backoffice is unchanged in this change, and the delta must
be carried into the spec so the next operator complaint is answerable in seconds.

### D3 — Context name: `beai-{interview_session_id}-{ulid}`

Generated in `HeygenProvider::buildContextBody()` — not in the controller, not in `QuestionContext`.
The name exists only to satisfy a LiveAvatar uniqueness constraint; it is wire concern, and the
controller has no business knowing the provider has one.

- `beai-` — namespaces the LiveAvatar console when an account is shared.
- `{interview_session_id}` — opaque internal id, **not** `candidate_ref`, not `participant_id`.
  Carries zero PII (ratified decision #8: BEAI holds no candidate contact data) and makes a console
  row traceable back to one BEAI session, which is what the next incident will need.
- `{ulid}` — required, per **F3**: resume re-issues against the same session id, so a
  session-scoped name collides on the second call exactly as the demo's stable name did. ULID over
  the demo's `Date.now()` because two resumes in the same millisecond are possible and a ULID is
  monotonic anyway.

Rejected: `{organization_id}-{participant_id}-{competency_code}-…` — four ids where one suffices,
and `participant_id` correlates across sessions for no gain.

### D4 — Three-way provider failure taxonomy

`ProviderException` gains a `ProviderFailureClass` backed enum. `isRetryable()` **stays** as a
derived accessor (`$this->class === Throttle`) so no caller — including the pending
`participant-error-recovery` work — breaks on this change.

| Class | Trigger | HTTP | Session | Participant |
|---|---|---|---|---|
| `Throttle` | 429 | 429 `provider_busy` | unchanged (`pending`) | **untouched** |
| `ClientError` | any other 4xx (400, 401, 403, 404, 409, 415, **422**) | **500** `provider_error` | `error` | **untouched** |
| `Upstream` | 5xx, timeout, malformed/unparseable success body | 502 `provider_error` | `error` | → `errore` *(unchanged)* |

**Why 500 and not 502.** 502 Bad Gateway asserts the upstream failed. Here the upstream worked
perfectly — it correctly rejected a request *we* malformed. Blaming the provider for our own bug is
how this defect spent an afternoon looking like a HeyGen incident.

**Why the error code stays `provider_error`.** Per **F2** the frontend maps any non-403/429 status to
the retryable `error` state, so 500 needs no frontend change; and a new code would need a frontend
handler this change does not own. The status carries the new information; the body stays stable.

**401/403 are folded into `ClientError`, deliberately.** They are a credential misconfiguration, not
a contract error — but the *handling decision* is identical (don't blame upstream, don't burn the
candidate), and a fourth enum case with byte-identical behaviour is a distinction without a
difference. D6's extracted message plus the status in the log is what distinguishes them
operationally.

### D5 — The seam with `participant-error-recovery`, stated by file region

Both changes touch two files. Ownership is drawn so neither has to guess:

| File / region | Owner | Contract |
|---|---|---|
| `ProviderException.php` — the enum, named constructors, `isRetryable()` accessor | **this change** | `participant-error-recovery` consumes it; it does not edit this file. |
| `InterviewController::handleProviderFailure()` — the **classification switch** (which class → which status + session write) | **this change** | The switch is created here and is not re-shaped there. |
| A new private `markParticipantFailed(Participant $p): void`, extracted verbatim from the current `:609-617` block and called **only** from the `Upstream` branch | **`participant-error-recovery`** | This change *creates* the method and moves the existing body into it, unchanged. That change edits **only inside** it (recoverable status, audit log, admin retry). |

**Sequencing: this change lands first.** It is an active outage; the other is resilience over a state
this change makes far rarer. `participant-error-recovery` then rebases onto the three-way
classification instead of inventing its own — and inherits a `markParticipantFailed()` that is
already called from exactly one place.

Out of scope here, restated so it is unambiguous: the terminal-`errore` state machine,
`$allowedTransitions`, admin retry endpoints, `ParticipantStatusGuard`, `EntryLinkMinter`.

### D6 — Redaction that keeps the diagnosis and loses the key

New `App\Support\Provider\ProviderErrorMessage` — pure, unit-testable, used by **both** providers.
Two copies of security-critical redaction is two places to get it wrong.

`extract(ResponseInterface|array|string $body, string $apiKey): ?string`, in order:

1. Read `message` ?? `error` ?? `data.message` (mirrors `start.ts:260-263`).
2. **Scalars only.** A non-scalar value returns `null`. A nested structure is precisely where an
   echoed request — and therefore the key — would hide.
3. Truncate to 300 chars. Bounds the log line and bounds any accidental blob.
4. `str_replace($apiKey, '[REDACTED]', $s)` when `$apiKey !== ''`.
5. **Assert-and-drop**: if the result still contains `$apiKey`, return `null`. Fail closed.

`null` falls back to today's exact `"… (HTTP {status}) — provider response redacted"` message.
The raw body is **never** logged, in any branch.

The existing worst-case test — which synthetically forces the key into a 5xx body — must pass
**unchanged**, and becomes the regression guard for the new path. Per the proposal's success
criterion, one test asserts *both* halves: the provider's message is present **and** the key is
absent. Asserting them separately is how one of them quietly stops being true.

### D7 — Transcript parsing fails loud on drift, stays soft on transport

Two failure modes that today collapse into the same `return []` — and per **F1**, that empty array
deletes the candidate's transcript.

| Condition | Behaviour | Why |
|---|---|---|
| HTTP non-2xx on the transcript fetch | **unchanged**: `Log::warning`, return `[]` | Transient, and the live `/utterance` rows are a real fallback. |
| 2xx, `data.transcript_data` absent or not an array | **throw** `ProviderTranscriptShapeException` | No fallback interpretation exists. Per F1 the alternative is a `DELETE` of the real transcript. |
| A row missing `role` or `transcript`, or a non-string `transcript` | **throw** | Same. |
| `role` outside `{user, candidate}` → candidate, `{assistant, avatar, agent}` → avatar | **throw** on anything else | Today `$row['role'] === 'user' ? 'candidate' : 'avatar'` misattributes *every* unknown role to the avatar — candidate speech silently reassigned, straight into a ~95%-coverage scoring zone. |
| `time_ms` absent | **tolerate**, fall back to `now()` | Genuinely optional: `end.ts:76-84` never reads it. Marked `@wire-source none — inferred`. |

The exception extends `ProviderException` with class `Upstream`, so `/end` returns 502, the session
is untouched, and the utterances already in the database are **not** deleted. Loud, non-destructive,
and retryable.

Note the deliberate asymmetry with D6: required fields fail loud, optional-and-unverified fields
degrade. That line is drawn by demo evidence, not by convenience.

### D8 — Tavus: align the contract now, port the self-heal narrowly and last

**Corrected create body** — `{replica_id, persona_id, conversational_context, custom_greeting,
properties:{…}}`. Drop the invented `competency_code` / `question_index`. `conversational_context` is
**already correct** (matches the demo) — `TavusProviderPayloadTest` passes for the right reason and
must not be "made consistent" with the HeyGen fix. Teardown becomes
`POST /v2/conversations/{id}/end` (`end.ts:59-62`): wrong method *and* wrong path today.

**The concurrency self-heal is ported in half, and the discarded half matters more.**

| Demo behaviour | Ported? |
|---|---|
| Retry create 3× with 2s backoff before surfacing 429 | **Yes** — `TavusConcurrencyGuard`, a collaborator, not inline in `issue()`. |
| `GET /v2/conversations?status=active` then `POST …/end` on **every** active conversation | **NO — rejected outright.** |

The demo was single-tenant. In BEAI, a blind account-wide reap **ends another tenant's in-flight
interview** to make room for this one. That is a cross-tenant data-destruction bug wearing a
resilience feature's clothes, and CLAUDE.md's tenant-isolation constraint forbids it. If reaping is
ever wanted, it may only end conversations whose id matches an `interview_sessions.provider_session_ref`
already terminal in *our* database — a materially different design, out of scope here.

Two constraints on the retry: it costs up to **6s of wall time inside a candidate-facing request**,
so the count and backoff are config-driven (`interview.tavus.concurrency_retries` / `_backoff_ms`,
defaults 3 / 2000) and can be set to zero. And it depends on D6 — the demo matches
`/maximum concurrent conversations/i` against the *extracted message*, which does not exist until
PR 1 lands. That dependency is why this is the last slice, not merely the droppable one.

### D9 — Interim greeting: a sibling composer, lang files, shared version

Per the ratified decision: a locale-keyed template on `competency.name`, versioned with
`prompt_version`.

**Composed in `App\Services\Conversation\OpeningTextComposer`** — a sibling of
`SystemPromptComposer`, never inside it. `SystemPromptComposer` is a pure function over BARS
indicator text with an i18n hard-fail; the opener is a pure function over `competency.name` and must
**never** reach indicator or anchor text (the anti-leak rule at `interview-session/spec.md:341-349`).
Folding them together puts anchor strings within lexical reach of the one string spoken aloud.
Returns `ComposedOpening{text, version}` — a new value object, because `ComposedPrompt`'s invariants
are about a prompt.

**Templates live in `api/lang/{it,en}/interview.php`**, keyed `opening.first` / `opening.next` /
`opening.resume`, with a `:competency` placeholder.

| Option | Verdict |
|---|---|
| `config/conversation.php` (the proposal's suggestion) | **Rejected.** Config is not this project's i18n surface, `config:cache` freezes it, and it forks locale resolution away from `resolveCompletionPhrases()` — the `Lang::` + platform-default fallback chain living **two methods away in the same controller** for `end_phrase`/`final_phrase`, which is the identical problem: institutional UX chrome, per locale, not tenant content. |
| Lang files (chosen) | Reuses the established precedent verbatim. Adding es/fr/de/pt is a file, not a code change. |

**Version**: the existing `config('conversation.prompt_version')`, shared with the system prompt. One
version, not two: both strings ship together, both are heard by the same candidate, and a second
version string is a second thing to forget to bump. Any wording change to *either* bumps it — that
is intentional.

**Variant selection is the controller's**, composition is the composer's. The controller already
computes `$isFirst` (`:177`) and already branches on the resume path (`:168`).

**Threading**: `QuestionContext` gains a trailing `?string $openingText = null` — the same additive
widening C8 used for `systemPrompt`/`promptVersion`. `null` ⇒ the key is **omitted** from the wire
body, per `TemplatePayload`'s "unset means absent, never null" rule. The provider composes nothing.

**The replaceability invariant** (the point of the ratified decision): `opening_text` /
`custom_greeting` carry an opaque string, and `OpeningTextComposer` is the only code that knows how
it is built. Replacing the greeting later — a real intro, a per-competency script, an LLM-authored
opener — is a change to that class and the lang files plus a `prompt_version` bump. **It is not a
wire-contract change and touches no provider.**

**Locale source: `$project->language`**, matching what `SystemPromptComposer` receives — an opener in
a different language from the prompt the avatar is executing is incoherent. Note that
`resolveCompletionPhrases()` uses `$participant->language`; whether those two can diverge is an
**open question** below, not something this design resolves silently.

### D10 — Drift detection: four layers, and what each one cannot prove

Mocks caused this. `Http::fake` asserts our code agrees with our own guess; it is structurally
incapable of disagreeing. Layering, in recommended order:

| # | Layer | Where | Proves | **Cannot prove** |
|---|---|---|---|---|
| L1 | Response fixtures | `api/tests/Fixtures/Provider/{liveavatar,tavus}/*.json` → `tests/Feature/C7a/ProviderContractFixtureTest.php` | Response **parsing**. Catches `context_id` vs `id`, and `transcript_data` | **Nothing** about the outbound body. LiveAvatar can 422 while this stays green |
| L2 | Outbound golden body | `assertEqualsCanonicalizing` against a committed JSON, header-commented with the `legacy-demo` file:line it was verified against | The body has not **changed** since a human last checked it | That it is **correct**. It converts silent drift into a visible review diff — nothing more |
| L3 | Gated live smoke | `php artisan interview:smoke-check --provider=heygen`, refuses to run unless `INTERVIEW_SMOKE_ENABLED=true` + a real key; **never** in normal CI (costs credits) | The outbound request is **accepted**. The only layer that could have caught the original 422 | That *production's* key / avatar / template combination works |
| L4 | Post-deploy canary | The L3 command as a Railway release step, synthetic `/start` + immediate teardown | The **deployed configuration** works end to end | Anything before merge — it fails after the fact |

**L2 is new relative to the proposal and its claim is deliberately small.** A golden body proves
stability, not correctness. But it is exactly what would have put the invented
`{competency_code, question_index, system_prompt}` in front of a C7a reviewer as literal JSON
instead of buried in an array literal.

**Highest value per unit of cost is L4** — this defect reached live candidates because nothing ever
exercised the real provider after a deploy. Honest caveat: **no staging environment is confirmed to
exist** for this project. If there is none, L4 degrades to "run L3 manually against production
immediately after deploy, before any candidate link is issued" — which is weaker, and must be
written down as weaker rather than checked off as a canary.

**Revoking the old claim is mandatory, not cosmetic.** `HeygenProviderPayloadTest` /
`TavusProviderPayloadTest` keep their real job (failure matrix, redaction, classification), but
their docblocks must state in words that they assert **our** body and prove nothing about the
provider's contract, pointing at L2/L3. A test that quietly implies more than it proves is what made
a green suite compatible with a total outage.

### D11 — Slice boundaries (revised from 5 to 5, re-cut)

The proposal's boundaries are **validated with one re-cut**: its PR 2 fused the HeyGen wire rewrite,
the greeting, and three spec deltas at ~300 estimated lines — realistically 350-400+, i.e. at or over
budget on the riskiest slice in the change.

| PR | Content | Decisions | Est. |
|---|---|---|---|
| **1** | `ProviderFailureClass` enum, `ProviderErrorMessage`, both `throwRedacted()`, the classification switch + `markParticipantFailed()` seam | D4, D5, D6 | ~150 |
| **2** | HeyGen `/contexts` + `/sessions/token` rewrite, merge site moved (recursive), unique name, field allowlist; `opening_text` sent as **null/omitted**; 3 spec deltas | D1, D2, D3 | ~200 |
| **3** | `OpeningTextComposer`, lang keys, `ComposedOpening`, `QuestionContext` widening, controller variant selection; fills `opening_text` **and** Tavus `custom_greeting` | D9 | ~130 |
| **4** | `reconcileTranscript()` → `transcript_data` with fail-loud parsing + the L1/L2/L3 verification layer | D7, D10 | ~180 |
| **5** | Tavus: drop invented keys, `POST …/end` teardown | D8 (partial) | ~90 |
| **6** | *(droppable)* Tavus retry-with-backoff. **No blind reap.** | D8 | ~90 |

~750 lines over PRs 1-5, ~840 with 6. Every slice under 400. `Decision needed before apply: Yes`;
`Chained PRs recommended: Yes`; `400-line budget risk: Low` **per slice** once cut this way.

**PR 2 ships `opening_text` omitted, and that is a real risk, stated:** if LiveAvatar *requires* the
field, PR 2 alone does not end the outage and PR 3 becomes part of the fix rather than a follow-up.
L3's smoke check (PR 4) is what settles it — so if the outage must end at PR 2, run L3 manually
against the PR 2 branch first. Do not guess.

**Strict TDD — tests that must be CORRECTED (RED) before implementation, per slice:**

| PR | Correct first | Why it currently defends the bug |
|---|---|---|
| 1 | `tests/Unit/C7a/HeygenProviderTest.php` failure-matrix cases; `tests/Feature/C7a/InterviewStartTest.php:323` (5xx — assert it is **unchanged**); `ProviderSecretTest.php` | Pin 4xx → 502 + participant `errore`. A new 4xx case must go RED first. The 5xx case is the guard that D4 did not over-reach |
| 2 | `tests/Unit/C7a/HeygenProviderTest.php:34` (`data.context_id`); `tests/Feature/C8/HeygenProviderPayloadTest.php:56-87` and `:89-117` (`system_prompt`) | Fake the invented response key and assert the invented request field |
| 3 | `tests/Feature/C8/InterviewStartCompositionTest.php`; `tests/Feature/C7a/InterviewStartPhrasesTest.php` | Audit only — may assert unrelated concerns; enumerate exhaustively in `sdd-tasks` |
| 4 | `tests/Unit/C7a/HeygenProviderTest.php` transcript cases | Assert `data` rows keyed `role`/`content`. Add an F1 regression test: **shape drift must not delete existing utterances** |
| 5 | `tests/Feature/C8/TavusProviderPayloadTest.php:56-87`, `:89-117` | Assert `conversational_context` **correctly** — change only the invented keys, add `custom_greeting`. Do not "align with HeyGen" |

---

## Data Flow

```
POST /candidate/interview/start
  │
  ├─ SystemPromptComposer.compose()  ──→ ComposedPrompt {text, version}
  ├─ OpeningTextComposer.compose()   ──→ ComposedOpening {text, version}   [D9]
  │     (competency.name + project.language + variant: first|next|resume)
  │
  └─ QuestionContext {competencyCode, questionIndex, systemPrompt, promptVersion, openingText}
        │
        └─ HeygenProvider::issue()                             [outside any DB txn]
             │
             ├─ POST /v1/contexts
             │    body {name: beai-{sid}-{ulid}, prompt, opening_text}      [D1 D3 D9]
             │    read  data.id                                             [D1]
             │
             └─ POST /v1/sessions/token
                  body array_replace_recursive(                             [D1]
                          allowlist(TemplatePayload::heygen(cfg)),          [D2]
                          {mode, is_sandbox, avatar_persona.context_id})
                  read  data.access_token, data.session_id

  on non-2xx ─→ ProviderErrorMessage::extract(body, key)                    [D6]
                ProviderException(class, message)                           [D4]
                   │
                   ├─ Throttle    → 429  · session pending · participant untouched
                   ├─ ClientError → 500  · session error   · participant untouched
                   └─ Upstream    → 502  · session error   · markParticipantFailed()  ⟵ owned by
                                                                participant-error-recovery  [D5]

POST /candidate/interview/end   (HeyGen only)
  └─ reconcileTranscript()  data.transcript_data[] {role, transcript}       [D7]
       ├─ transport failure → warn, return []      (utterances survive: the DELETE never runs)
       └─ shape drift       → THROW                (F1: an empty return would DELETE them)
```

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Exceptions/ProviderException.php` | Modify | `ProviderFailureClass` enum; `isRetryable()` kept as derived accessor (D4) |
| `api/app/Enums/ProviderFailureClass.php` | Create | `Throttle` \| `ClientError` \| `Upstream` (D4) |
| `api/app/Support/Provider/ProviderErrorMessage.php` | Create | Shared extract-and-redact, pure (D6) |
| `api/app/Services/Provider/HeygenProvider.php` | Modify | Both call bodies, `data.id`, allowlist, name, fail-loud transcript (D1 D2 D3 D7) |
| `api/app/Services/Provider/TavusProvider.php` | Modify | Invented keys out, `custom_greeting`, `POST …/end` (D8) |
| `api/app/Services/Provider/TavusConcurrencyGuard.php` | Create *(PR 6)* | Retry+backoff only — no reap (D8) |
| `api/app/Services/Provider/QuestionContext.php` | Modify | Trailing `?string $openingText = null` (D9) |
| `api/app/Services/Conversation/OpeningTextComposer.php` | Create | Locale-keyed opener on `competency.name` (D9) |
| `api/app/DTOs/Conversation/ComposedOpening.php` | Create | `{text, version}` (D9) |
| `api/app/Http/Controllers/Candidate/InterviewController.php` | Modify | Classification switch, `markParticipantFailed()` seam, opener variant selection (D4 D5 D9) |
| `api/lang/{it,en}/interview.php` | Modify | `opening.first` / `.next` / `.resume` (D9) |
| `api/config/interview.php` | Modify | `heygen.extra_token_fields`, `tavus.concurrency_*` (D2 D8) |
| `api/app/Console/Commands/ProviderSmokeCheck.php` | Create | Env-gated live check (D10 L3) |
| `api/tests/Fixtures/Provider/**` | Create | Recorded response fixtures (D10 L1) |
| `api/app/Support/AvatarTemplates/TemplatePayload.php` | **Unchanged** | Mapper is correct; only its call site moves (D1) |
| `frontend/**` | **Unchanged** | Per **F2**, 500 already maps to the retryable `error` state |
| `openspec/specs/interview-session/spec.md` `:326-376`, `:930-1004` | Delta | Ratified text names `system_prompt` and puts avatar identity on `/contexts` |
| `openspec/specs/avatar-templates/spec.md` `:248-252` | Delta | Names the merge target by its invented field list |

---

## Testing Strategy

| Layer | What | How |
|---|---|---|
| Unit | `ProviderErrorMessage`: extraction order, non-scalar rejection, truncation, assert-and-drop | Pure, no HTTP |
| Unit | `OpeningTextComposer`: locale, variant, `:competency` substitution, **no anchor text reachable** | Pure |
| Unit | Allowlist filtering; recursive merge keeps `avatar_persona.{voice_id,language,context_id}` | Pure, on the built body |
| Feature | Failure matrix per `ProviderFailureClass` — status, session status, **participant status unchanged** for `ClientError` and `Throttle` | `Http::fake`; claim scoped to *our* behaviour |
| Feature | Message present **and** key absent — one test, both assertions | `Http::fake` with key forced into the body |
| Feature | Two consecutive `/start` calls, plus a resume, produce **distinct** context names (F3) | `Http::assertSent` capture |
| Contract (L1) | Provider parsing against committed fixtures | `ProviderContractFixtureTest` |
| Contract (L2) | Outbound golden body diff | Committed JSON + provenance comment |
| Regression (F1) | Transcript shape drift **does not delete** existing utterances | DB assertion after a drifted `/end` |
| Smoke (L3) | Live acceptance | Artisan command, env-gated, never in CI |
| Canary (L4) | Deployed config | Post-deploy release step (see D10 caveat) |

Coverage: the transcript path is a scoring-adjacent correctness zone — hold it to ~95% per CLAUDE.md.

---

## Migration / Rollout

**No migrations, no schema, no data.** Nothing to un-write.

Reverting restores a payload that 422s on every call — rollback returns the product to a total
outage, so **roll-forward is the only real recovery**. Each slice is sized to be fixable forward.
Sessions created while a slice is live carry no incompatible state: `provider_session_ref` is opaque
to us either way. Spec deltas revert with their PR.

---

## Open Questions

- [ ] **Is `opening_text` required by LiveAvatar?** Settles whether PR 2 ends the outage alone (D11).
      Answerable only by L3 (D10). Do not guess.
- [ ] **`project.language` vs `participant.language`** — D9 uses the project language for the opener,
      `resolveCompletionPhrases()` uses the participant's. Can they diverge, and if so which one is
      the avatar actually speaking? Flagged, not silently resolved.
- [ ] **Should a resumed interview be re-greeted at all?** D9 provides an `opening.resume` variant;
      whether it should be spoken, or empty, is product.
- [ ] **Does a staging environment exist?** Determines whether D10 L4 is a canary or a manual
      post-deploy step. Do not record it as a canary if it is not one.
- [ ] **Railway `HEYGEN_API_KEY` / `INTERVIEW_PROVIDER`** — inferred from a 422 (auth passed, body
      rejected), never directly confirmed. Confirm during `sdd-apply`.
- [ ] **`HeygenProvider::teardown()`** stays `DELETE /v1/sessions/{ref}` with **zero** demo evidence.
      Deliberately out of scope — do not swap one inference for another — but it is still an
      unverified call in the shipped code and should be labelled as such.
