# Tasks: LiveAvatar / Tavus Contract Alignment

> Strict TDD. Several existing tests defend the invented contract (the bug) —
> each is corrected (RED) **before** the implementation task it guards, per PR.
> `/api/candidate/interview/start` is down in production; PR1 ships first
> because it makes the *next* drift diagnosable even if nothing else lands.

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | ~750 (PR1-5) / ~840 with droppable PR6 |
| 400-line budget risk | Low **per slice** (design re-cut PR2 from the proposal's ~300 to ~200 specifically to clear budget); High for the change as a whole |
| Chained PRs recommended | Yes |
| Suggested split | PR1 → PR2 → PR3 → PR4 → PR5 → PR6 (droppable) |
| Delivery strategy | ask-on-risk |
| Chain strategy | **feature-branch-chain** (ratified by the user) |

Decision needed before apply: No — resolved (feature-branch-chain)
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Low

Two independent reasons a decision is needed before `sdd-apply`: (1) the chain
strategy itself, and (2) Decision 1 (`opening_text` source) is ratified as an
interim default but its **necessity** is unconfirmed until PR2's live smoke
check runs (task 2.9).

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|---|---|---|---|
| 1 | Diagnosability: `ProviderFailureClass`, `ProviderErrorMessage`, classification switch, `markParticipantFailed()` seam | PR1 | Independently valuable even alone; ships first |
| 2 | HeyGen wire rewrite: `/contexts`, `/sessions/token`, name, allowlist, merge-site move | PR2 | Depends on PR1 (`ClientError`, redaction) |
| 3 | `OpeningTextComposer` + lang keys + Tavus `custom_greeting` | PR3 | Depends on PR2 (`QuestionContext.openingText` wired through) |
| 4 | `reconcileTranscript()` fail-loud + L1/L2/L3 verification layer | PR4 | Independent of PR2/3; can run parallel to PR3 |
| 5 | Tavus wire correction: drop invented keys, `POST …/end` teardown | PR5 | Independent of PR2-4 |
| 6 *(droppable)* | Tavus concurrency retry (no reap) | PR6 | Depends on PR1's `ProviderErrorMessage` (message-pattern match) |

---

## PR1 — Diagnosability first (~150 lines)

**Correct first (RED, defends the bug today):**
- [x] 1.1 `tests/Unit/C7a/HeygenProviderTest.php` failure-matrix cases — currently pin 4xx → 502 + participant `errore`. Rewrite to expect `ClientError` → 500, participant untouched; add a **new** 4xx case (must go RED before the enum exists).
- [x] 1.2 `tests/Feature/C7a/InterviewStartTest.php:323` — assert the 5xx path is **unchanged** (502, participant → `errore`). This is the guard that D4 does not over-reach into `Upstream`. (Confirmed unchanged/green — no edit needed; also added symmetric 4xx acceptance tests for HeyGen + Tavus in this file.)
- [x] 1.3 `tests/Feature/C7a/ProviderSecretTest.php` — audit against the new `ProviderErrorMessage::extract()`; the existing worst-case (key forced into a 5xx body) must still pass unchanged. (Audited, green, no edit needed.)

**Implement (GREEN):**
- [x] 1.4 Create `api/app/Enums/ProviderFailureClass.php` — `Throttle | ClientError | Upstream`.
- [x] 1.5 Modify `api/app/Exceptions/ProviderException.php` — add the class; keep `isRetryable()` as a derived accessor (`class === Throttle`) so no caller breaks.
- [x] 1.6 Create `api/app/Support/Provider/ProviderErrorMessage.php` — pure `extract()`: `message ?? error ?? data.message`, scalars only, truncate 300 chars, `str_replace($apiKey, '[REDACTED]', ...)`, assert-and-drop if the key survives.
- [x] 1.7 Update both providers' `throwRedacted()` to use `ProviderErrorMessage::extract()`.
- [x] 1.8 Modify `InterviewController::handleProviderFailure()` (`:590-620`) — classification switch: `Throttle` → 429/pending/untouched, `ClientError` → 500/error/untouched, `Upstream` → 502/error/`errore`.
- [x] 1.9 Extract `markParticipantFailed(Participant $p): void` **verbatim** from `:609-617`, called only from the `Upstream` branch. **Seam note**: this method is the boundary with `participant-error-recovery` — that change edits only *inside* it (recoverable status, audit log, admin retry). Do not restructure the switch beyond this extraction; leave it minimal so the other change rebases cleanly.
- [x] 1.10 Test: message present **and** key absent — one test, both assertions (per proposal Success Criteria).

**Status**: DONE. Committed on `feature/liveavatar-contract-alignment-pr1-diagnosability` (off tracker `feature/liveavatar-contract-alignment`). Full suite green. Actual size: 9 files, +526/-38 (564 changed lines) — over the ~150 estimate (see apply-progress risk note); not split further because PR1 is one coherent, independently-shippable work unit per this table.

**Acceptance:** a 4xx from either provider yields HTTP 500, session `error`, participant status unchanged. A 5xx behaves exactly as before (502, `errore`). Provider message readable in logs/Sentry; API key never appears in either, in the same test.

---

## PR2 — HeyGen wire correction (~200 lines)

**Correct first (RED, defends the bug today):**
- [x] 2.1 `tests/Unit/C7a/HeygenProviderTest.php:34` — fakes `['data' => ['context_id' => 'ctx-abc']]`. Rewrite to `['data' => ['id' => 'ctx-abc']]`, assert `data.id` is read.
- [x] 2.2 `tests/Feature/C8/HeygenProviderPayloadTest.php:56-87` and `:89-117` — assert `toHaveKey('system_prompt')` on the `/contexts` body. Rewrite: `/contexts` body is exactly `{name, prompt, opening_text}` (`opening_text` null/omitted this PR, per D11); assert `prompt` carries the composed system prompt. (Also corrected `tests/Feature/C8/InterviewStartCompositionTest.php` 5.5/5.7's `system_prompt` → `prompt` assertions — a necessary consequence of this same rename, not deferrable to PR3; PR3's own audit of this file, for the opening-text widening, is unaffected and still pending.)

**Implement (GREEN):**
- [x] 2.3 Modify `api/app/Services/Provider/HeygenProvider.php` — `buildContextBody()`: `{name, prompt, opening_text}` with `@wire-source legacy-demo/.../start.ts:246-267` docblock. Read response via `data.id`. (`opening_text` omitted this PR — no data source until PR3.)
- [x] 2.4 Same file — `buildSessionTokenBody()`: `array_replace_recursive(allowlist(TemplatePayload::heygen($cfg)), {mode, is_sandbox, avatar_persona.context_id})`. Test: `avatar_persona.{voice_id, language, context_id}` all survive the merge together (regression for the shallow-merge bug D1 flags).
- [x] 2.5 Same file — `TOKEN_FIELD_ALLOWLIST` = demo-proven set, unioned with `config('interview.heygen.extra_token_fields', [])` (default `[]`). Config key added to `api/config/interview.php`.
- [x] 2.6 Context `name`: `beai-{interview_session_id}-{ulid}` (per F3 — `handleResumeInCorso()` re-issues `issue()` for the same session, so a session-id-only name collides on resume exactly like `start.ts:250-252`). Test: two consecutive `/start` calls, plus a resume, produce **distinct** names.
- [x] 2.7 Move the `TemplatePayload::heygen()` merge call site from `/contexts` (`HeygenProvider.php:80-83`) to `/sessions/token`. `TemplatePayload.php` itself is **not modified** (confirmed: zero diff on that file).
- [x] 2.8 Delta spec: amend `openspec/specs/interview-session/spec.md:326-376` ... `avatar-templates/spec.md:248-252`. **Already satisfied**: the delta spec files (`openspec/changes/liveavatar-contract-alignment/specs/{interview-session,avatar-templates,interview-conversation}/spec.md`) were authored during `sdd-spec` and already describe this exact corrected contract (verified by reading them in this apply batch). No further edit needed; base-spec merge is an archive-phase action, out of scope for apply.
- [ ] 2.9 **Gated live check, before merge**: run the LiveAvatar `/contexts` call manually (real key, `artisan tinker` or `curl`) against this branch to determine whether `opening_text` is required when null/omitted. **NOT DONE — cannot be performed in this sandboxed apply environment** (no real `HEYGEN_API_KEY`, no live network egress). This is an explicit, human-owned pre-merge gate: do not merge PR2 alone as "outage ended" until someone runs this manually and records the finding. Do not guess (per design D11/Open Questions).

**Acceptance:** `POST /candidate/interview/start` returns 201 against the live provider (contingent on task 2.9's finding — UNVERIFIED, see above). `/contexts` body exactly `{name, prompt}` this PR (`opening_text` arrives in PR3); id read from `data.id` — verified by tests. Avatar identity fields appear on `/sessions/token` and no other call — verified. Two consecutive interviews on the same account both succeed (name uniqueness) — verified.

**Status**: DONE except task 2.9 (requires a real provider key; explicit human gate before merge). Committed on `feature/liveavatar-contract-alignment-pr2-heygen-wire` (off `feature/liveavatar-contract-alignment-pr1-diagnosability`). Full suite green (1836 tests, 1831 passed, 5 pre-existing skips, 0 failures); `pint --test` clean; `phpstan analyse` (level 8, whole `app/`) clean.

---

## PR3 — Opening greeting composer (~130 lines)

**Correct first (audit — may assert unrelated concerns, do not blanket-rewrite):**
- [x] 3.1 `tests/Feature/C8/InterviewStartCompositionTest.php` — audited against `QuestionContext.openingText` widening. No assertion needed correction: the file's `prompt`-key assertions (5.5/5.7) are unaffected by the additive `openingText` field (default null preserves prior behavior in unit-level provider tests; the integration path now always composes a non-null opening, but no test in this file forbids or asserts on `opening_text`, so nothing broke). Full suite re-run confirms all cases in this file still GREEN after PR3 wiring landed.
- [x] 3.2 `tests/Feature/C7a/InterviewStartPhrasesTest.php` — audited against the new opener variant selection. This file only asserts `end_phrase`/`final_phrase` (a separate, pre-existing localization concern unrelated to the opening greeting); `assertJsonStructure` does not forbid extra keys, so no edit needed. Confirmed GREEN.

**Implement (GREEN):**
- [x] 3.3 Create `api/app/DTOs/Conversation/ComposedOpening.php` — `{text, version}`.
- [x] 3.4 Create `api/app/Services/Conversation/OpeningTextComposer.php` — sibling of `SystemPromptComposer`, never inside it. Locale-keyed template on `competency.name`, `$project->language`, variant `first|next|resume`. Never reaches BARS anchor/indicator text (anti-leak rule, `interview-session/spec.md:341-349`) — holds by construction, no BARS dependency exists on this class at all.
- [x] 3.5 Test: no anchor/indicator text is reachable from `OpeningTextComposer` (pure unit test on the composer's inputs/outputs). `tests/Unit/Services/Conversation/OpeningTextComposerTest.php` (7 cases: determinism, shared version, variant distinctness, locale fallback, anti-leak, fail-loud on unknown variant).
- [x] 3.6 Add `api/lang/{it,en}/interview.php` keys `opening.first` / `opening.next` / `opening.resume` with a `:competency` placeholder.
- [x] 3.7 Modify `api/app/Services/Provider/QuestionContext.php` — trailing `?string $openingText = null` (additive widening, matches C8's `systemPrompt`/`promptVersion` pattern).
- [x] 3.8 Modify `InterviewController` — variant selection using the existing `$isFirst` (hoisted earlier so it's available before `QuestionContext` construction — was previously computed only just before `handleIssuePending()`) and `$isResumeInCorso`; pass into `HeygenProvider` (`opening_text` on `/contexts`) and `TavusProvider` (`custom_greeting` on `/conversations`).
- [x] 3.9 Version: reuse `config('conversation.prompt_version')` — no second version string (confirmed: `OpeningTextComposer::compose()` reads the same config key `SystemPromptComposer::compose()` does).
- [x] 3.10 Delta spec: add `interview-conversation` capability "QuestionContext Carries a Composed Opening Greeting" — **already satisfied**, same as PR2's task 2.8: the delta spec file (`openspec/changes/liveavatar-contract-alignment/specs/interview-conversation/spec.md`) already contains this ADDED requirement from the `sdd-spec` phase (verified by reading it during `sdd-design`'s exploration). No further edit needed; base-spec merge remains an archive-phase action.

**Acceptance:** `opening_text`/`custom_greeting` populated per variant and locale — verified by `tests/Feature/C8/HeygenProviderPayloadTest.php` (6.5/6.6) and `tests/Feature/C8/TavusProviderPayloadTest.php` (6.7/6.8). `prompt_version` bump on any wording change (shared config key, verified). No anchor/indicator text reachable (verified, anti-leak test).

**Status**: DONE (all 10 tasks — 3.1/3.2 were audits with no edit required, not skips). Committed on `feature/liveavatar-contract-alignment-pr3-opening-greeting` (off `feature/liveavatar-contract-alignment-pr2-heygen-wire`). Full suite green (1850 tests, 1845 passed, 5 pre-existing skips, 0 failures); `pint --test` (whole repo) clean; `phpstan analyse` (level 8, whole `app/`) clean.

**Actual size**: 9 modified + 3 new files, ≈460 changed lines (243 tracked diff + 217 in new files) vs the ~130 estimate — same driver as PR1/PR2: strict-TDD test depth (7 pure unit tests on the composer alone, plus 4 new provider-wiring tests) and `@wire-source`-style provenance docblocks (D1). Not split further — PR3 is one coherent, independently-shippable work unit (opening greeting, end-to-end) per the design's own table; splitting the composer from its wiring would leave either half unshippable alone.

---

## PR4 — Transcript fail-loud + verification layer (~180 lines)

**Correct first (RED, defends the bug today):**
- [x] 4.1 `tests/Unit/C7a/HeygenProviderTest.php` transcript cases — assert `data` rows keyed `role`/`content`. Rewrote to `data.transcript_data` keyed `role`/`transcript`; added role-mapping, genuinely-empty, absent-shape-throws, missing-row-throws, unknown-role-throws, and `time_ms`-fallback cases. **Necessary consequence, disclosed** (same pattern as PR2's task 2.2 fallout): 3 pre-existing tests in `tests/Feature/C7a/InterviewEndTest.php` (timeout, skipped, atomicity) and 1 in `tests/Feature/C10/InterviewEndProgressSeamTest.php` used the OLD invented `{data: []}` shorthand for "no transcript" — corrected to the real `{data: {transcript_data: []}}` empty-but-valid shape (a genuinely-empty transcript must NOT throw). Also corrected the `replaceUtterances` HeyGen test's fixture rows from `role`/`content` to `role`/`transcript`, and 2 blanket `Http::fake()` calls (non-last/last-question tests) that reach a heygen `in_corso` session needed an explicit transcript fake added (Laravel's default empty fake response is not valid JSON, which now correctly throws instead of silently returning `[]`).
- [x] 4.2 **F1 regression test (new, not a correction)**: seed persisted utterance rows, call `/end` with a drifted/shape-mismatched transcript response (`{"data": []}` — no `transcript_data` key), assert the rows **still exist** and the session stays `in_corso` (502 returned). Confirmed RED against pre-fix code (the guard sat after the unconditional delete at the then-current `InterviewController.php:759`/`:761` — line numbers shifted from the design's `:715`/`:717` citation due to PR1-3 edits, but the bug was byte-for-byte identical: unconditional DELETE, guard after).

**Implement (GREEN):**
- [x] 4.3 Modify `HeygenProvider::reconcileTranscript()` — read `data.transcript_data`, keyed `role`/`transcript`. `role` mapping: `{user, candidate}` → candidate, `{assistant, avatar, agent}` → avatar; **throw** on anything else (today misattributes every unknown role to avatar).
- [x] 4.4 Create `ProviderTranscriptShapeException extends ProviderException` (class `Upstream`) — thrown when `data.transcript_data` is absent/not-array, or a row is missing `role`/`transcript`, or `transcript` is non-string. HTTP non-2xx stays soft (`Log::warning`, return `[]`).
- [x] 4.5 Fix `InterviewController::replaceUtterances()` — moved the `if (empty($transcript)) return;` guard **before** the `DB::table('utterances')->delete()` call. **Chose reordering over a new nested transaction** (reasoned in the method's docblock): `reconcileTranscript()` now throws on any shape mismatch instead of ever returning a "silently empty" `[]` for that reason, so by the time control reaches `replaceUtterances()`, an empty `$transcript` is ALWAYS legitimate (transport failure or a genuinely-empty-but-valid transcript) — never a parsing bug in disguise. That invariant makes the guard-before-delete reordering sufficient for the atomic-replace property (DELETE and INSERT only ever run together); a nested transaction would be redundant since this method already runs inside `/end`'s explicit transaction + `FOR UPDATE` lock. Also wrapped the `DB::transaction()` call in `end()` in a `try/catch (ProviderException)` returning 502 `provider_error` — without this, the thrown exception would surface as an unhandled 500, not the fail-loud 502 the delta spec requires.
- [x] 4.6 `time_ms` absent → tolerate, fall back to `now()` (marked `@wire-source none — inferred`). Verified by a dedicated test.
- [x] 4.7 Create `api/tests/Fixtures/Provider/{liveavatar,tavus}/*.json` — **docs-verified** (not recorded-live; no real credentials in this sandboxed environment) response fixtures (L1): `context_create_response.json`, `session_token_response.json`, `transcript_response.json`, `conversation_create_response.json`.
- [x] 4.8 Create `tests/Feature/C7a/ProviderContractFixtureTest.php` — parses fixtures through the real provider code (`HeygenProvider::issue()`, `::reconcileTranscript()`, `TavusProvider::issue()`); docblock states explicitly it proves parsing, not provider acceptance.
- [x] 4.9 Add outbound golden-body test (L2) — `$this->assertEqualsCanonicalizing()` against `tests/Fixtures/Provider/liveavatar/contexts_request_golden.json`, header-commented with the `legacy-demo` file:line it was verified against. The per-request unique `name` field (ULID) is asserted separately by regex and excluded from the golden comparison (documented as a deliberate scope narrowing — the golden fixture covers the STATIC part of the body only). Scoped to HeyGen only this PR: a Tavus golden-body test is deferred to PR5, since Tavus's body still carries the invented `competency_code`/`question_index` keys PR5 removes — asserting a golden body we know is still wrong would be encoding the bug.
- [x] 4.10 Create `api/app/Console/Commands/ProviderSmokeCheck.php` (L3) — `php artisan interview:smoke-check --provider=heygen|tavus`, refuses to run unless `config('interview.smoke_enabled')` (backed by `INTERVIEW_SMOKE_ENABLED` env, added to `config/interview.php` — a direct `env()` call outside `config/` fails PHPStan's Larastan rule) + a real key are present; never wired into normal CI (no Pest test invokes it). **Created but NOT executed** — confirmed it correctly refuses to run in this sandboxed environment (`php artisan interview:smoke-check --provider=heygen` → "Refusing to run" with exit code 1, no HTTP call made) since no real credentials/network egress are available here. A human must run this manually before treating PR2/PR3's HeyGen wire correction as closing the production outage (per design D11).
- [x] 4.11 Revoke the old claim: added a docblock to `HeygenProviderPayloadTest.php` / `TavusProviderPayloadTest.php` stating they assert **our** body only and prove nothing about provider acceptance (point at L1/L2/L3 by name).

**Acceptance:** `reconcileTranscript()` returns non-empty, correctly-attributed rows from a fixture payload — verified. A drifted `/end` response leaves existing utterances untouched and returns 502 — verified (F1 regression test). Coverage on this path held to ~95% (scoring-adjacent, per CLAUDE.md) — 13 new/corrected tests across unit + feature + fixture layers on this exact code path.

**Status**: DONE (all 11 tasks; L3 created but deliberately not executed per the batch's explicit instruction — no real credentials/network egress available in this environment). Committed on `feature/liveavatar-contract-alignment-pr4-transcript-fail-loud` (off `feature/liveavatar-contract-alignment-pr3-opening-greeting`). Full suite green (1861 tests, 1856 passed, 5 pre-existing skips, 0 failures); `pint --test` (whole repo) clean; `phpstan analyse` (level 8, whole `app/`) clean.

**Actual size**: 8 modified + 8 new files (1 exception class, 1 console command, 1 test file, 4 JSON fixtures, plus the 1 config addition already counted in "modified"), ≈840 changed lines (459 tracked diff + 381 in new files) vs the ~180 estimate. Same driver as PR1-3 (strict-TDD test depth) PLUS this slice uniquely bundles the entire D10 four-layer verification scaffold (L1 fixtures + L1 parsing test + L2 golden body + L3 gated command) on top of the F1 data-destruction fix itself — neither was optional per the batch instructions, and splitting the verification layer from the fix it verifies would leave the fix unverified in its own PR. Note: a meaningful fraction of `InterviewController.php`'s diff (`+165/-84` tracked) is Pint-driven reindentation of the untouched inner closure body, mechanically required by wrapping it in `try {}` — not new logic.

---

## PR5 — Tavus wire correction (~90 lines)

**Correct first (RED where wrong; DO NOT rewrite what is already right):**
- [x] 5.1 `tests/Feature/C8/TavusProviderPayloadTest.php:56-87` and `:89-117` — `conversational_context` and `custom_greeting` assertions were already correct/present (from PR3). Added negative assertions (`not->toHaveKey('competency_code')`, `not->toHaveKey('question_index')`) to both cases — confirmed RED against pre-fix code, then GREEN after 5.2. Also added a new `TavusProviderTest.php` case asserting teardown uses `POST .../end`, not `DELETE` — confirmed RED, then GREEN after 5.3.

**Implement (GREEN):**
- [x] 5.2 Modified `api/app/Services/Provider/TavusProvider.php` — dropped `competency_code`/`question_index` from the `/conversations` body. `custom_greeting` was already wired in PR3 (not duplicated here, per batch instruction). Create-call response parsing (top-level `conversation_id`/`conversation_url`) verified — confirmed already correct, untouched.
- [x] 5.3 Same file — teardown now `POST /v2/conversations/{id}/end` (was `DELETE /v2/conversations/{id}` — wrong method **and** wrong path).
- [x] 5.4 Added the deferred Tavus L2 golden-body test (`tests/Feature/C7a/ProviderContractFixtureTest.php`, PR4 explicitly scoped this out since the body still carried the invented keys). New fixture `tests/Fixtures/Provider/tavus/conversations_request_golden.json`.

**Acceptance:** `TavusProviderPayloadTest` still passes for its original correct reason (`conversational_context`) plus the new `custom_greeting` assertion, plus negative assertions on the removed invented keys — verified. No behavior change to response reads (`conversation_id`/`conversation_url` already correct, top-level) — verified. Teardown method/path corrected — verified.

**Status**: DONE (all tasks). Committed on `feature/liveavatar-contract-alignment-pr5-tavus-wire` (off `feature/liveavatar-contract-alignment-pr4-transcript-fail-loud`). Full suite green (1863 tests, 1858 passed, 5 pre-existing skips, 0 failures); `pint --test` (whole repo) clean; `phpstan analyse` (level 8, whole `app/`) clean.

---

## PR6 — Tavus concurrency self-heal (droppable, ~90 lines)

Depends on PR1 (`ProviderErrorMessage`, message-pattern match against `/maximum concurrent conversations/i`).

- [x] 6.1 Created `api/app/Services/Provider/TavusConcurrencyGuard.php` — retries the create call up to `interview.tavus.concurrency_retries` times, `_backoff_ms` apart (defaults 3 / 2000), ONLY when the rejection is specifically a concurrency-limit case (`isConcurrencyLimited()`: 4xx, never 5xx/success, message matches `/maximum concurrent conversations/i` via `ProviderErrorMessage::extract()`). Settable to zero via config to disable retrying entirely. Wired into `TavusProvider::issue()`: on exhausted/disabled retries the request is forced to `Throttle` classification (429 `provider_busy`) regardless of the raw HTTP status Tavus returned for that specific rejection reason — any other 4xx/5xx keeps the existing PR1 classification unchanged.
- [x] 6.2 **Explicitly rejected, NOT ported**: `endActiveTavusConversations()` (`start.ts:270-361`'s blind reap via `GET /v2/conversations?status=active` + `POST …/end` on every active conversation). In multi-tenant BEAI this would end another tenant's live interview — cross-tenant data destruction wearing a resilience feature's clothes, forbidden by CLAUDE.md tenant isolation. Recorded in `TavusConcurrencyGuard`'s class docblock so nobody "restores" it later from the demo. Only the retry-with-backoff is ported.
- [x] 6.3 Tests: `tests/Unit/C7a/TavusConcurrencyGuardTest.php` (8 cases — retry-then-succeed, exhausted-retries, retries=0 disables, non-concurrency 4xx not retried, 5xx not retried, success not retried, pattern-match case-insensitivity, grep-based negative test for the reap using a comment-stripped AST scan so the class's own explanatory docblock doesn't false-positive) + 2 integration cases in `tests/Unit/C7a/TavusProviderTest.php` (`issue()` self-heals via retry then succeeds; `issue()` exhausts retries and surfaces 429 `provider_busy`, not 500/502).
- [x] 6.4 Delta spec: `interview-session` — "Tavus Concurrency Self-Heal Before Surfacing 429" **corrected during this batch**: the spec text authored in `sdd-spec` still said "MUST reap active conversations and retry", carrying forward the proposal's original (pre-design-D8) language. Design D8 explicitly rejected the reap for multi-tenant safety, and the batch's explicit instruction restated the constraint — the ratified spec text conflicted with the ratified design decision. Corrected `openspec/changes/liveavatar-contract-alignment/specs/interview-session/spec.md`'s "Tavus Concurrency Self-Heal Before Surfacing 429" requirement + scenarios to retry-only, and added a third scenario ("No other tenant's conversation is ever queried or ended") matching the D8 language. Flagged as a deviation below, not silently changed.

**Acceptance:** a simulated concurrency-limit 4xx retries 3× before 429 — verified (unit + integration). No other tenant's conversation is ever queried or ended — verified (grep-based negative test, comment-stripped).

**Status**: DONE (all 4 tasks). Committed on `feature/liveavatar-contract-alignment-pr6-tavus-concurrency` (off `feature/liveavatar-contract-alignment-pr5-tavus-wire`). Full suite green; `pint --test` (whole repo) clean; `phpstan analyse` (level 8, whole `app/`) clean.

---

## Out of Scope (restated, do not re-open)

- Participant recovery state machine, `$allowedTransitions`, admin retry — `participant-error-recovery`; consumes `markParticipantFailed()` (task 1.9) unchanged.
- `HeygenProvider::teardown()` `DELETE /sessions/{ref}` — zero demo evidence, left as-is, flagged.
- CLAUDE.md open "retry semantics" decision (#4) — untouched.
- `device-check-preview-and-device-selection` — untouched.

## Gates (every PR)

`cd api && ./vendor/bin/pest` (green, no skipped provider tests) · `./vendor/bin/pint --test` · `phpstan analyse` where configured. PR4's transcript path held to ~95% coverage per CLAUDE.md.
