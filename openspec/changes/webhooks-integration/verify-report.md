# Verify Report: webhooks-integration (C10)

Phase: `sdd-verify`. Fresh, independent verification — adversarial, not confirmatory.
Verified: 2026-07-28. Verifier did not implement this change.

## Verdict: **PARTIAL** — 1 CRITICAL, 2 WARNING, 0 blocking SUGGESTION

All quality gates (tests, static analysis, lint, typecheck, coverage) are GREEN on both
submodules, with real numbers reproduced fresh in this session (not trusted from the
implementer's report). Source-level review of every named hard rule (signature/body
coupling, delivery state machine, retry classification, rollback ordering, tenancy,
secret non-leakage, D8 frontend target correction, scope-creep justification) confirms
the implementation is correct and disciplined. However, one spec scenario
("Advancement progress payload reflects cumulative state" — the "2 responses" case) is
**not satisfiable by the delivered code and has no covering test**, which is a genuine
CRITICAL per the spec-scenario-must-have-a-passing-test rule. Two test-quality WARNINGs
were found via mutation testing (see below).

---

## 1. Task Completeness Table (tasks.md, PR0–PR7)

| PR | Scope | `[x]` claim | Evidence checked | Verdict |
|---|---|---|---|---|
| PR0 | Branch prerequisite (tenancy dep) | 0.1–0.4 [x] | `git log` on `feat/c10-pr6-progress-seams` shows `TenantContextScope`/`TenantScoped::creating` present (from merged `queued-job-tenancy`) | Genuine |
| PR1 | Migrations + enums | 1.1–3.4, 3.6 [x]; 3.5 (open PR) correctly `[ ]` | Migration file read (CHECK constraints, indexes); `WebhookSkipReason` enum has exactly 3 cases; `WebhookDeliveriesMigrationTest.php` hardening (3.6) claim plausible from code, not independently re-verified | Genuine |
| PR2 | Model + config + project req/resource | 4.1–5.6 [x]; 5.7 (open PR) `[ ]` | `WebhookDelivery` model read (extends `TenantModel`, `organization_id` excluded from `$fillable`); `ProjectController::store()` `refresh()` fix (5.4b) read and confirmed minimal/justified | Genuine |
| PR3 | Payload assembly + signing | 6.1–7.6 [x]; 7.7 diff-size flag [x]; 7.8 (open PR) `[ ]` | `WebhookSigner`, `SecretRedactor`, `EvaluationPayloadAssembler`, `ProgressPayloadAssembler` all read in full | Genuine, but see CRITICAL #1 below on the progress payload's scenario coverage |
| PR4 | `WebhookDeliveryRecorder` | 8.1–9.4 [x]; 9.5 (open PR) `[ ]` | Recorder read in full — 4-step gate order (Δ1) matches spec exactly; savepoint-transaction gotcha (9.1) is real and correctly reasoned; coverage 100% reproduced fresh | Genuine |
| PR5 | `DeliverWebhookJob` + listeners | 10.0–11.8 [x]; 11.9 (open PR) `[ ]` | Job read in full; arch-guard hardening (10.0) fixture-proof exists and reviewed; mutation-tested (see §4) | Genuine, with WARNING #1/#2 (test-quality gaps, not code defects) |
| PR6 | Progress event seams | 12.1–13.10 [x]; 13.11 (open PR) `[ ]` | `SsoExchangeController.php` and `InterviewController.php` diffs read line-for-line — both purely additive, zero SQL/closure-body changes | Genuine |
| PR7 | Frontend exit redirect | 14.1–15.7 [x]; 15.8 (open PR) `[ ]` | `useExitRedirect.ts`, `[token].vue` diff, `isMock()` fix, `factory.ts` hook, `playwright.config.ts` all read; unit (339/339) and E2E (69/69, and the new spec's 6/6 re-run in isolation) reproduced fresh | Genuine |

All "Open PR N" tasks are correctly left unchecked per the explicit orchestrator
instruction (no push, no PR opened) — not flagged.

---

## 2. Verbatim Gate Outputs

### api submodule (checked out `feat/c10-pr6-progress-seams`, tip `1b30155`)

**Full Pest suite:**
```
{"tool":"pest","result":"passed","tests":1066,"passed":1063,"assertions":2298,"duration_ms":63676,"skipped":3}
```
(3 skips are pre-existing, unrelated to C10 — matches implementer's claim.)

**PHPStan (2G memory limit):**
```
{"tool":"phpstan","result":"passed","errors":0}
```
(develop baseline is 0 errors per instruction — this is 0 as well, so no new C10 errors.)

**Pint, scoped to the 51 files changed in `develop..feat/c10-pr6-progress-seams`:**
```
{"tool":"pint","result":"passed"}
```

**Aggregate repo-wide coverage (`pest --coverage`, PCOV) — Success Criterion 7, the
number the implementer explicitly flagged as never measured as one figure:**
```
Total: 94.4 %
```
Well above the 85% overall gate. Every C10 correctness-critical file individually
measured 100.0%: `WebhookSigner`, `SecretRedactor`, `RetryClassifier`,
`WebhookDeliveryRecorder`, `DeliverWebhookJob`, `EvaluationPayloadAssembler`,
`ProgressPayloadAssembler`. `SendEvaluationWebhook`/`SendProgressWebhook`/new `Events`:
100.0%. `WebhookDelivery` model: 85.7% (uncovered lines are relation accessors, not
correctness-critical logic). All ≥95% for the correctness-critical zone.

### frontend submodule (`feat/c10-pr7-exit-redirect`, tip `07c5a00`)

**`bunx nuxi prepare` then `bun run typecheck`:** exit 0, 0 errors (pre-existing
shadcn-vue duplicate-component-name warnings are cosmetic and unrelated to C10).

**`bun run test:unit`:**
```
Test Files  22 passed (22)
     Tests  339 passed (339)
```

**`bun run test:unit:coverage`:**
```
All files          |   96.87 |    87.76 |   95.37 |   96.87
useExitRedirect.ts |     100 |      100 |     100 |     100
```

**Playwright E2E, new spec re-run in isolation (chromium+webkit):**
```
6 passed (25.1s)
```

**Playwright E2E, full suite (chromium+webkit+mobile):**
```
69 passed (39.9s)
```
Zero regressions to `interview-flow.spec.ts` or `unsupported-gate.spec.ts`. The
`mobile` project is pre-existing-scoped to `unsupported-gate.spec.ts` only
(`playwright.config.ts:48`), matching CLAUDE.md's NFR — the new exit-redirect spec
correctly never runs there.

---

## 3. Deep-Dive Verification (per orchestrator's numbered checklist)

**1. Signature/body coupling — CORRECT in code, WARNING on test discriminating power.**
`api/app/Jobs/DeliverWebhookJob.php:128-142`: `$rawBody = $signer->encode($delivery->payload)`
is the exact variable passed to both `$signer->sign($timestamp, $rawBody, $secret)` and
`->withBody($rawBody, 'application/json')->post($delivery->target_url)` — never
`Http::post($url, $array)`. Confirmed correct by source read. See §4 for the mutation-test
finding that the *test* claiming to prove this at the HTTP boundary has a fixture gap.

**2. Delivery state machine — CORRECT and well-tested.** Four ordered gate branches
(`api/app/Services/Webhooks/WebhookDeliveryRecorder.php:143-162`): null `webhook_url` →
`no_webhook_url`; secret null → `no_webhook_secret`; event type disabled →
`event_type_disabled`; otherwise `pending` — matches spec's exact 4-step order
(`specs/webhooks-integration/spec.md:82-94`). `WebhookDeliveryGateTest.php` has one test
per branch plus a distinguishability test (all 5 tests read). Dead-lettering terminality:
`DeliverWebhookJob::handle()` line 101 (`if ($delivery->status !== Pending) return;`) is
the FIRST action, before any HTTP call — proven by
`DeliverWebhookJobTest.php:269-283` (terminal-row idempotency guard, `Http::assertNothingSent()`)
against a `Delivered` row, and by the exhaustion test (`:115-148`) asserting
`release()->never()` on the 6th/final attempt. Minor gap: no test re-invokes an
already-`Dead` row specifically (see WARNING #2).

**3. Retry classification — CORRECT, mutation-verified.** `RetryClassifier.php:26-54`:
2xx→Delivered; 408/429→Retryable (explicit exception carve-out); 5xx→Retryable;
null (timeout/connection)→Retryable; any other 4xx→FailedPermanent; defensively
Retryable for 1xx/3xx/unmodeled. Boundary cases match the spec table exactly. Mutation
test (removing 408 from the retryable list) caused an immediate, hard test failure
in `RetryClassifierTest.php` — genuinely discriminating (see §4).

**4. Emission-on-rollback ordering — CORRECT, additive-only diffs confirmed.**
`SsoExchangeController.php` diff: `event(new ParticipantCreated(...))` inserted after the
reload+null-check (`:172-178` in the new file), zero characters changed inside the
`:137-158` `DB::statement()` upsert block — confirmed via `git diff`, 2 additive hunks
only. `InterviewController.php` diff: `$progress = null` declared before the closure,
captured by reference, set only on the closure's success-path last statement, emitted
AFTER `DB::transaction()` returns — zero statements inside the closure modified except
the `use(...)` clause gaining `&$progress` and one new assignment appended at the end.
Both `abort()` calls (`:225`, `:231` in the original file) still throw past the emission
point. Confirmed the SSO raw-SQL atomicity was NOT weakened — the diff is purely additive.

**5. Tenancy — CORRECT, arch guard genuinely hardened.**
`DeliverWebhookJob` and `WebhookDeliveryRecorder` both reference `TenantContextScope::`
in source (confirmed by read). `tests/Fixtures/ArchGuardFixtures/Jobs/Nested/NonCompliantNestedJob.php`
exists (confirmed via `fd`), AND a dedicated proof test
(`QueuedJobTenantContextArchTest.php:120-135`) explicitly asserts the recursive scanner
`toContain`s this nested fixture as a violation and does NOT flag the compliant/non-job
fixtures — this is a genuine discriminating proof, not just fixture existence. Diff of
this test file vs `develop` shows the assertion was *strengthened* (whole-`app/`
recursive walk replacing a `Jobs/`-only non-recursive glob, plus an added
`isInstantiable()` guard), never weakened.

**6. Secret non-leakage — CORRECT, all 4 surfaces tested.**
(a) Row: `WebhookDeliveryTenancyTest.php:82-90` (`webhook_secret never appears in the
persisted delivery row`) and `DeliverWebhookJobTest.php:305-306`.
(b) Log: `DeliverWebhookJobTest.php:294-314` (`Log::listen` across every emitted line,
receiver echoing the secret in a 500 body).
(c) API response: `ProjectWebhookEventsTest.php:109-127` (`webhook_secret` absent from
`GET /api/projects/{id}`).
(d) Exception: `WebhookDeliveryTenancyTest.php:92+` (project-not-found exception never
contains the secret). All four surfaces independently covered.

**7. "The tests would FAIL if reverted" — mutation-tested, see §4. One of two spot-checks
genuinely failed to discriminate; documented as WARNING #1, not silently passed over.**

**8. No weakened assertions.** Only two pre-existing test-adjacent files were modified
(not newly created): `tests/Pest.php` (pure addition, new registration blocks, zero
deletions) and `tests/Arch/Tenancy/QueuedJobTenantContextArchTest.php` (strengthened, see
#5). Every other C10 test file is new. No weakening found.

**9. D8 frontend correctness — CONFIRMED.** `frontend/app/pages/interview/done.vue` is
NOT in the PR7 diff (`git diff --name-only` — 8 files changed, `done.vue` absent).
`rg` over `frontend/app` finds zero `navigateTo('/interview/done')` calls anywhere,
confirming it remains unreachable. The real seam,
`frontend/app/pages/interview/[token].vue`'s inline `done` branch, is where
`useExitRedirect` was wired (diff read in full — additive only, existing `done` markup
untouched, only imports/lifecycle hooks/a `watch` added).

**10. Task completeness — see §1 table above. All checked tasks are genuinely done.**

**11. Scope creep (PR7) — JUSTIFIED.** `isMock()` fix
(`useInterviewSession.ts:97-105`): confirmed genuine — `nuxt.config.ts:97` defaults
`interviewProviderMock: ''` (empty string), and Nuxt/Nitro's `destr` coercion means a
real deployed server would expose `true` (boolean) once the env var is set for E2E,
which the old `=== 'true'` string check would never match. This is a real, narrowly
targeted bug fix with its own RED→GREEN regression test
(`use-interview-session.spec.ts`). `factory.ts`'s `exposeMockProviderForE2E()`
(`:118-134`) is confirmed inert in production: it is called ONLY inside the `if (mock)`
branch of `createProvider()` (`:32-40`), and `mock` is `isMock()`'s return value, which
is `false` by default (`nuxt.config.ts:97` ships `''`, `production` builds never set
`NUXT_PUBLIC_INTERVIEW_PROVIDER_MOCK`). `playwright.config.ts`'s env addition is
test-config-only, never shipped to production. Both are the smallest change that makes
the explicitly-assigned Playwright task deliverable — justification holds.

---

## 4. Mutation-Testing Evidence (Check #7)

Two spot-checks performed, per the orchestrator's instruction. Both mutations were made
directly in the working tree, run, then restored via `git checkout --` with `git status
--short` confirming a byte-identical clean tree before continuing.

**Spot-check A — Retry classification boundary (RetryClassifier.php).**
Mutated `in_array($statusCode, [408, 429], true)` → `in_array($statusCode, [429], true)`
(silently dropping 408 from the retryable set). Result: **immediate, hard failure**:
```
RetryClassifierTest.php::408_and_429_classify_as_Retryable ... FAILED
Expected: Retryable(...)  Actual: FailedPermanent(...)
```
Genuinely discriminating. Restored; suite green again (22/22).

**Spot-check B — Signature/body coupling (DeliverWebhookJob.php).**
Mutated `->withBody($rawBody, 'application/json')->post($delivery->target_url)` →
`->asJson()->post($delivery->target_url, $delivery->payload)` (the exact forbidden
pattern design.md D6 names). Result: **the targeted test still PASSED**:
```
{"tool":"pest","result":"passed","tests":1,...}  // "the exact transmitted body is what was signed"
```
Root cause, confirmed by direct `php -r` comparison: the test's fixture payload
(`c10PendingDelivery()`, `DeliverWebhookJobTest.php:45-67` — keys `version`, `event`,
`delivery_id`, `candidate_ref`, `data.status`, no slashes or non-ASCII characters) encodes
to byte-identical JSON under `JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE` vs default
`json_encode()` flags, because there is nothing in it for those flags to affect. The test
recomputes its expected hex from whatever bytes were actually transmitted, so it can only
ever fail if the transmitted bytes diverge from the canonically-encoded bytes for THIS
SPECIFIC payload — which they never do here, regardless of which encoder sent them.
Restored the file (`git diff --stat` empty, `git status --short` clean); re-ran the test,
confirmed still green as the untouched baseline.

**Conclusion:** production code is correct (confirmed independently by source read — the
signing and transmission genuinely share one `$rawBody` variable). The unit-level
`WebhookSignerTest.php:88-106` DOES prove the encoder divergence, but only in isolation
on `WebhookSigner` itself (using a payload WITH a slash and a unicode character). The
wiring-level "HTTP boundary" test does not currently have equivalent discriminating power.
This is a genuine test-quality gap, not a shipped defect — see WARNING #1.

---

## 5. Issues

### CRITICAL

**C1 — "Advancement progress payload reflects cumulative state" spec scenario is not
satisfiable by the delivered implementation and has no covering test.**
`specs/webhooks-integration/spec.md:294-298`:
> GIVEN a participant has completed competency INN (2 responses) ... THEN INN shows
> 2 responses ...

`ProgressPayloadAssembler::assemble()` (`api/app/Services/Webhooks/ProgressPayloadAssembler.php:62-77`)
derives at most ONE `answers` entry per competency, from a single LEFT-JOINed
`interview_sessions` row keyed on `(participant_id, competency_code)`. Confirmed via the
migration's own doc comment
(`api/database/migrations/2026_07_20_100002_create_interview_sessions_table.php:14`:
"One row per competency attempt per participant. One session = one competency.") and via
`question_index`'s definition (`:47`: "0-based ordinal (position - 1) from
project_competencies.position" — the COMPETENCY's static position in the project, NOT a
per-question counter; confirmed no other code path increments it —
`rg question_index app/` shows it is set once at session creation
(`InterviewController.php:408,416,450`) and never mutated). The `utterances` table
(`api/database/migrations/2026_07_20_100003_create_utterances_table.php`) has no
`question_id` column either — it stores raw speaker turns, not discretized Q&A pairs.
The delivered code therefore cannot produce "2 responses" for one competency under any
input; `ProgressPayloadAssemblerTest.php:106-125` only tests the 0-or-1-entry case
("advancement case: cumulative state across competencies"), never 2. This also traces to
a binding-doc requirement
(`docs/app_description/04-integration-surface/03-webhook-eventi.md:33-34`: "Risposte:
Elenco risposte date: id domanda, timestamp" / "Caso avanzamento: competenze con una o
più risposte registrate") that anticipates a genuine per-question list.

This looks like a **pre-existing spec-authoring gap** (the `sdd-spec` phase apparently
wrote a scenario the C7a domain model cannot satisfy — `tasks.md`'s own "Spec ↔ Design
Reconciliation" pass (Δ1–Δ5) did not catch it) rather than a C10 coding defect: the
one-entry-per-competency-completion model the code actually implements is a reasonable,
internally-consistent reading of "competency completion is the domain-meaningful boundary"
(D2's own stated rationale for choosing the `/end` seam over `UtteranceController`). But
as written, the spec scenario is unproven and per sdd-verify's own decision gate ("Spec
scenario has no passing covering test → CRITICAL"), this blocks a clean pass.

**Recommended resolution (either, human/product decision):**
(a) Correct the spec scenario's wording to describe the delivered one-entry-per-
completed-competency model (drop the "2 responses" framing, or redefine "response" as
"competency completion event" project-wide, and reconcile the binding doc's "Elenco
risposte" plural wording as a documentation looseness), or
(b) extend `interview_sessions`/`utterances` to track individual question-level answers
before promoting this spec, which is materially larger scope than C10 delivered.
This is a `sdd-spec`-level fix, not an `sdd-apply` code fix — the code correctly
implements what the design phase actually decided; the disagreement is between the spec
scenario's literal text and the domain model both design and proposal reasoned from.

### WARNING

**W1 — HTTP-boundary "independent recomputation" test does not discriminate the
regression it claims to guard against**, for the reason and with the mutation evidence
in §4 Spot-check B. Recommend adding a slash or non-ASCII character (e.g. to
`candidate_ref` in the `c10PendingDelivery()` fixture,
`tests/Feature/C10/DeliverWebhookJobTest.php:45-67`) so
`the exact transmitted body is what was signed` genuinely fails if `Http::withBody()` is
ever replaced by `Http::post($url, $array)`.

**W2 — Dead-letter terminality is proven for `Delivered` but not directly for `Dead`.**
`DeliverWebhookJobTest.php:269-283` ("terminal-row idempotency guard") only forces the
row to `Delivered` before re-invoking `handle()`. The exhaustion test (`:115-148`) proves
`release()` is never called again on the 6th attempt, but no test re-invokes `handle()`
a 7th time against an already-`Dead` row to directly exercise the same idempotency guard
from that specific terminal state. Low risk (single shared guard,
`!== WebhookDeliveryStatus::Pending`), but worth a parametrized test covering all 4
terminal statuses (`Delivered`, `FailedPermanent`, `Dead`, `Skipped`) rather than one
representative.

### SUGGESTION

None beyond the above — code quality, documentation discipline, and TDD evidence
throughout PR0–PR7 are high.

---

## 6. Submodule State (restored exactly as found)

**api**: `git status --short` → (empty, clean). Branch: `feat/c11-a1-reader-gate` (the
branch it was checked out to at verify start; temporarily switched to
`feat/c10-pr6-progress-seams` for review, restored after).

**frontend**: `git status --short` → (empty, clean). Branch: `feat/c10-pr7-exit-redirect`
(unchanged throughout — this was already the correct branch to review at verify start).

Both submodules match the wrapper's `git submodule status` recorded pointers; no commits,
stashes, or uncommitted changes were left behind by this verification session.
