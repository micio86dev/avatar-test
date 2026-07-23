# Tasks: C8 — interview-conversation (standard adaptive)

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | 420–560 (new files dominate; 2 existing files modified) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → Foundation + Core (config, DTO, loader, composer, unit tests) · PR 2 → Integration (controller wiring, adapter forwarding, feature tests) |
| Delivery strategy | ask-on-risk |
| Chain strategy | pending |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: pending
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | config + DTO + BarsIndicatorLoader + SystemPromptComposer + unit tests (zero HTTP) | PR 1 | Base = `feature/assessment-engine`; self-contained; ~230–300 lines |
| 2 | QuestionContext widening + InterviewController + HeyGen/Tavus adapter forwarding + feature tests | PR 2 | Base = PR 1 branch; depends on composer from Unit 1; ~200–260 lines |

---

## Phase 1: Foundation (config, value objects)

- [x] 1.1 **RED** — Write failing unit test: `config('conversation.prompt_version')` returns a non-empty string and `config('conversation.followup_budget')` returns an int (asserts file does not yet exist).
- [x] 1.2 Create `api/config/conversation.php` with `prompt_version` (env `CONVERSATION_PROMPT_VERSION`, default `conv-2026-07-23`) and `followup_budget` (env `CONVERSATION_FOLLOWUP_BUDGET`, default `2`). Make 1.1 green.
- [x] 1.3 **RED** — Write failing unit test: `ComposedPrompt` holds `text: string` and `version: string`; construction with empty string throws or asserts non-empty (per design contract).
- [x] 1.4 Create `api/app/DTOs/Conversation/ComposedPrompt.php` — readonly value object `{text: string, version: string}`. Make 1.3 green.

---

## Phase 2: BarsIndicatorLoader (role + competency scoped)

> Spec: REQ BarsIndicatorLoader · Scenarios: cross-role isolation, position order.

- [x] 2.1 **RED** — Write failing unit test `BarsIndicatorLoaderTest`: seed two roles (FLL, MLL) sharing competency COL with disjoint indicator sets via factories; assert `forRoleCompetency(fll_role_id, col_competency_id)` returns only FLL indicators; assert MLL indicator id not present; assert ordering by `position`.
- [x] 2.2 **RED** — Add scenario: `forRoleCompetency(mll_role_id, col_competency_id)` returns only MLL indicators (disjoint from FLL result).
- [x] 2.3 **RED** — Add scenario: `forRoleCompetency()` with a role that has no indicators for the given competency returns an empty `Collection`.
- [x] 2.4 Create `api/app/Services/Conversation/BarsIndicatorLoader.php` — `final class`, single public method `forRoleCompetency(int $roleId, int $competencyId): Collection` querying `framework_bars_indicators` scoped by both columns, ordered by `position`. Make 2.1–2.3 green.
- [x] 2.5 **REFACTOR** — Ensure `BarsIndicatorLoader` is bound in `AppServiceProvider` (or auto-resolved) and does NOT reference `ScoreEvaluationJob` or C9 code.

---

## Phase 3: SystemPromptComposer (pure function)

> Spec: REQ System-Prompt Composition · REQ SA-02 · REQ SA-03 · REQ i18n hard-fail.

- [x] 3.1 **RED** — Write failing unit test `SystemPromptComposerTest::determinism`: call `compose()` twice with identical inputs; assert identical `text` and `version` strings; assert `version` equals `config('conversation.prompt_version')`.
- [x] 3.2 **RED** — Add scenario: composed prompt contains all 3 indicator `text` values (FLL-COL; English factory translations).
- [x] 3.3 **RED** — Add scenario: composed `text` contains `budget=2` / "at most 2 follow-up" language and an `end_phrase` advance-rule instruction.
- [x] 3.4 **RED** — Add scenario: `nudge_min_chars = 100` → composed text contains "100" and a re-prompt instruction; `nudge_min_chars = null` (or 0) → no nudge section present.
- [x] 3.5 **RED** — Add scenario: missing Italian anchor translation → `AnchorTranslationMissingException` thrown (factory-authored EN indicators only; request locale `it`).
- [x] 3.6 **RED** — Add scenario: `project_locale = 'it'` with factory-authored IT translations → composed text contains Italian anchor texts; no English anchor text appears.
- [x] 3.7 **RED** — Add scenario: empty indicator collection (loader returns empty) → composer throws a `CompositionException` (new, distinct from `AnchorTranslationMissingException`).
- [x] 3.8 Create `api/app/Exceptions/Conversation/CompositionException.php` — extends `\RuntimeException`; used for empty-indicator and unresolvable-role failures.
- [x] 3.9 Create `api/app/Services/Conversation/SystemPromptComposer.php` — `final class`; constructor injects `BarsIndicatorLoader`; `compose(string $competencyCode, int $roleId, int $competencyId, string $projectLocale, int $budget, ?int $nudgeMinChars): ComposedPrompt`. Reuses `AnchorTranslationMissingException` semantics from `PromptBuilder.php:72-73` (check each of `text`, `anchor_5`, `anchor_3`, `anchor_1`). No LLM call, no HTTP. Make 3.1–3.7 green.
- [x] 3.10 **REFACTOR** — Extract template sections into private methods; ensure no hardcoded tenant text; add docblock citing spec REQ.

---

## Phase 4: QuestionContext widening (backward-compatible DTO)

> Spec: REQ QuestionContext Carries Composed Prompt · delta spec C7a addendum.

- [x] 4.1 **RED** — Write failing unit test: construct `QuestionContext` with four args (`competencyCode`, `questionIndex`, `systemPrompt`, `promptVersion`); assert both new fields are accessible; construct with two args → new fields default to `null`.
- [x] 4.2 Widen `api/app/Services/Provider/QuestionContext.php` — add `public ?string $systemPrompt = null` and `public ?string $promptVersion = null` as nullable named constructor parameters with defaults. Make 4.1 green. Confirm all existing `QuestionContext` instantiation sites still pass (single call site at `InterviewController.php:98`).

---

## Phase 5: InterviewController — compose and thread (M-3)

> Spec: REQ QuestionContext Carries Composed Prompt · delta spec /start response shape.

- [x] 5.1 **RED** — Write failing feature test `InterviewStartCompositionTest` (Http::fake for provider): `/start` with valid candidate JWT + project with `standard` type + EN competency → HTTP 201 → `question_context.prompt_version` is non-null non-empty string → `question_context.system_prompt` is non-null non-empty string.
- [x] 5.2 **RED** — Add feature test scenario: missing IT anchor translation (factory-seeded IT-missing competency) → HTTP 422 → error body carries `anchor_translation_missing` → no `InterviewSession` row created → no provider HTTP call made (Http::fake assertNothingSent on provider URL).
- [x] 5.3 **RED** — Add feature test scenario: empty indicator set (role has zero BARS for that competency) → HTTP 422 `composition_error` → no provider call → session stays `pending`.
- [x] 5.4 **RED** — Add feature test scenario: provider 5xx failure matrix unchanged after QuestionContext widening → session `error`, participant `errore`, HTTP 502 (regression coverage for C7a invariant).
- [x] 5.5 Inject `SystemPromptComposer` into `InterviewController` via constructor. In `start()`, before building `$ctx` at line 98, call `SystemPromptComposer::compose(...)` (resolve `role_id` via `$project->role_code → Role::where('code')->first()->id`); catch `CompositionException` and `AnchorTranslationMissingException` → return `422` with matching error key; do NOT call `issue()` on failure. Thread `systemPrompt` and `promptVersion` into `QuestionContext`.
- [x] 5.6 Update `buildSuccessResponse()` to accept `?string $promptVersion` and add `'prompt_version' => $promptVersion` (and `'system_prompt' => $systemPrompt` per delta spec) inside `question_context`. Pass both from the call sites in `handleIssuePending` and `handleResumeInCorso`. Make 5.1–5.4 green.
- [x] 5.7 **REFACTOR** — Confirm `resolveProvider` binding allows injecting mock `SystemPromptComposer` in tests; add service binding in `AppServiceProvider` if needed.

---

## Phase 6: Provider adapters — forward system_prompt

> Spec: REQ Provider Payload Contract (C-1) · RV-3 PR-gated assertion.

- [x] 6.1 **RED** — Write failing feature test `HeygenProviderPayloadTest` (Http::fake): `HeygenProvider::issue()` called with a `QuestionContext` where `systemPrompt = 'TEST_PROMPT'` → intercepted `POST /v1/contexts` body CONTAINS `'system_prompt' => 'TEST_PROMPT'` (non-null, non-empty). Failure of this assertion must fail the PR suite.
- [x] 6.2 **RED** — Add scenario: `QuestionContext::systemPrompt = null` → HeyGen create-body does NOT include `system_prompt` key (legacy unchanged shape).
- [x] 6.3 **RED** — Write failing feature test `TavusProviderPayloadTest` (Http::fake): `TavusProvider::issue()` called with `systemPrompt = 'TEST_PROMPT'` → intercepted `POST /v2/conversations` body CONTAINS `'conversational_context' => 'TEST_PROMPT'`.
- [x] 6.4 **RED** — Add scenario: `QuestionContext::systemPrompt = null` → Tavus create-body does NOT include `conversational_context` key.
- [x] 6.5 Update `HeygenProvider::issue()` — in the `/contexts` POST body, conditionally add `'system_prompt' => $ctx->systemPrompt` when non-null. Make 6.1–6.2 green.
- [x] 6.6 Update `TavusProvider::issue()` — in the `/conversations` POST body, conditionally add `'conversational_context' => $ctx->systemPrompt` when non-null. Make 6.3–6.4 green.
- [x] 6.7 **REFACTOR** — Verify both adapter tests run in the standard Pest `--group=feature` suite (no `@ai` tag); add `@group feature` annotation; confirm Http::fake isolates all external calls.

---

## Phase 7: Deferred @ai integration tests (stub, not PR-gated)

> Spec: REQ Testability Split · @ai suite.

- [x] 7.1 Create `api/tests/Integration/Conversation/AvatarBehavioralComplianceTest.php` — stub test class marked `@group ai`; test methods for (a) ≤N follow-ups trigger `end_phrase`, (b) coverage-before-budget fires early, (c) nudge does not consume a follow-up slot. Each method uses `$this->markTestSkipped('Deferred @ai — requires live provider; run on workflow_dispatch/release/*')`. Do NOT add `@group feature` or `@group unit`.

---

## Phase 8: Quality gate

- [x] 8.1 Run `./vendor/bin/pest --group=unit` — all unit tests pass; confirm new tests cover `BarsIndicatorLoader` and `SystemPromptComposer` at ~95%.
- [x] 8.2 Run `./vendor/bin/pest --group=feature` — all feature tests pass including `Http::fake` payload assertions (6.1–6.4) and controller tests (5.1–5.4).
- [x] 8.3 Run `./vendor/bin/phpstan analyse` — no new errors; `SystemPromptComposer`, `BarsIndicatorLoader`, and `ComposedPrompt` are covered by PHPStan 8 strict mode.
- [x] 8.4 Confirm no `ScoreEvaluationJob` file was modified (`git diff --name-only | grep ScoreEvaluationJob` returns empty).
- [x] 8.5 Confirm no migration files were added for C8 (`git diff --name-only | grep database/migrations` returns empty for C8-related files).

---

## Parallelism notes

- Phases 1–2 are independent and can be worked in parallel.
- Phase 3 depends on Phase 1 (config) and Phase 2 (loader).
- Phase 4 is independent of Phases 2–3; can overlap with Phase 3.
- Phase 5 depends on Phases 3 and 4.
- Phase 6 depends on Phase 4 only (adapters consume `QuestionContext`; can start before Phase 5 completes).
- Phase 7 is a stub and can be written at any point after Phase 3 tests define the behavioral contract.
- Phase 8 is sequential gating at the end of each PR slice.

---

## Open question (surface before apply)

Delivery strategy is `ask-on-risk` and budget risk is **High**. Before `sdd-apply`, confirm the chain strategy:
- **Feature-branch chain** (recommended): PR 1 bases on `feature/assessment-engine`; PR 2 bases on PR 1's branch. Only the tracker branch merges to `develop`.
- **Stacked to main / develop**: each PR merges to `develop` in order.
- **size:exception**: single PR with maintainer approval.
