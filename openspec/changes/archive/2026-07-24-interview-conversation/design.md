# Design: C8 — interview-conversation (conversation / adaptive)

> **Revision R1 (2026-07-23)** — post fresh-context adversarial design review. The core
> **Option A** architecture (proposal KD-1) was VALIDATED and is unchanged. This revision
> applies the review's mandatory corrections: `potential` fully DESCOPED (RV-1, no new
> migration), a NEW role-scoped `BarsIndicatorLoader` instead of a C9 refactor (RV-2),
> provider-contract hardening with a PR-gated payload assertion (RV-3), a new
> `config/conversation.php` (RV-4), the additive `/start` controller + response widening
> (M-3), and determinism/i18n fixtures aligned to the existing hard-fail (M-2).
>
> **Confirmed invariants of this revision:** NO new migration · NO C9 modification ·
> `potential` fully removed from C8.

## Technical Approach

Option A (proposal KD-1). At `/start`, the server composes a deterministic, versioned BEAI
system prompt from the competency's **role-scoped** BARS indicators + role/type + project
language + follow-up budget + `nudge_min_chars`, and injects it into the provider session at
creation. The avatar-native LLM executes all in-competency follow-ups; **no new server LLM
call, no per-turn round-trip** (preserves the <2–3 s NFR). The C7a `/start` control flow
(create-or-resume, provider-call-outside-txn, failure matrix, five-endpoint contract) is
unchanged in *structure* — but two ADDITIVE changes land: `QuestionContext` widens with two
nullable fields, and `InterviewController::start()` composes the prompt and threads it +
`prompt_version` into the context and the `/start` response body (see M-3).

**Scope:** C8 designs the **`standard` adaptive path ONLY**. See "Deferred: `potential`".

## Seam verification

- **C-1 provider contract — INFERRED / UNVERIFIED (RV-3).** The prompt is injected via the
  provider create-body: `system_prompt` for HeyGen `POST /v1/contexts`,
  `conversational_context` (+ `custom_greeting`) for Tavus `POST /v2/conversations`. **These
  field names AND the `https://api.liveavatar.com/v1/contexts` endpoint are inferred from the
  C7a scaffold and are NOT verified against live provider docs.** `HeygenProvider.php:20-22`
  itself flags the endpoint as an open question ("LiveAvatar v1 vs native HeyGen REST …
  Confirm with client before live deploy"). C8 proceeds on these names but treats them as
  provisional: **client confirmation of the real provider contract is required before live
  deploy**, and a PR-gated test seam (below) makes a rename fail fast.
- **C9 has an inline, competency-only query — DO NOT touch (RV-2).** `ScoreEvaluationJob.php:319-323`
  loads indicators via `BarsIndicator::where('competency_id',$id)->orderBy('position')->get()`
  with a documented `TODO(PR3)` to add `role_id` scoping. That job is merged and
  coverage-critical (~95%). C8 does **NOT** extract from, wrap, or modify it. C8 introduces its
  own NEW `BarsIndicatorLoader` (below) that scopes by BOTH `role_id` AND `competency_id`, so
  C8 does not inherit C9's latent cross-role gap.
- **`BarsIndicator` carries both `role_id` and `competency_id`** (`BarsIndicator.php:27,53-54`;
  table `framework_bars_indicators`, GLOBAL / not tenant-scoped). Indicators for the same
  competency exist per-role, so competency-only scoping WOULD mix indicators across roles — the
  role scoping is correctness-relevant, not cosmetic.
- **`nudge_min_chars`** column already exists on `projects` (nullable `unsignedSmallInteger`).
- **Result: C8 needs NO new migration.** (RV-1 removed the only previously-planned table.)

## Architecture Decisions

| Decision | Choice | Rejected | Rationale |
|---|---|---|---|
| Prompt injection point | Widen `QuestionContext` with `systemPrompt: ?string` + `promptVersion: ?string`; adapters put `systemPrompt` in the create-body | New DTO / new endpoint | Smallest additive change; backward-compatible (nullable); one production call site |
| Composition home | New `App\Services\Conversation\SystemPromptComposer` (pure function) | Inline in controller | Testable with zero HTTP; SoC; no new LLM call site |
| Indicator source | NEW `App\Services\Conversation\BarsIndicatorLoader`, scoped by `role_id` AND `competency_id` (RV-2) | Extract/modify C9's inline query; duplicate C9's competency-only query | C9 is merged + coverage-critical — do NOT touch it; role scoping fixes the latent gap C9 left as `TODO(PR3)` |
| `prompt_version` | NEW `config('conversation.prompt_version')` (RV-4), stamped on the composed prompt + on `InterviewSession` | Reuse `config('scoring.prompt_version')` | Distinct lifecycle; conversation versioning must be wired independently of scoring; mirrors C9 discipline (KD-3) |
| Composer determinism / i18n | Reuse existing `PromptBuilder` anchor-translation hard-fail semantics (`PromptBuilder.php:72-73`) → 422 on missing translation (M-2) | Silent fallback to another locale | Deterministic; no partial-language prompt; aligns with C9 evaluation-language rule |
| `/start` widening | `InterviewController::start()` composes prompt, threads `systemPrompt`+`promptVersion` into `QuestionContext`, adds `prompt_version` to the response body (M-3) | Leave controller untouched (earlier framing) | The earlier "no controller change" claim was WRONG — `QuestionContext` is built at `InterviewController.php:98` before composition and `buildSuccessResponse` emits a fixed context with no version |
| Nudge | Prompt-injected `nudge_min_chars` re-prompt instruction; avatar re-asks | Server length interceptor | KD-5; a server gate needs a per-turn round-trip (Option B) |

## Deferred: `potential` (RV-1 — removed from C8)

`potential` is a **future slice**, gated on MTG/LAT authoring (binding open decision #6). It is
NOT designed, seeded, or referenced by C8:

- **No `framework_potential_questions` table, no seeder, no `potential/*.json` catalog.** The
  4-fixed-question data model (former OQ-2) and the fixed-sequence prompt block (former KD-2)
  are deferred.
- MTG/LAT are recorded by `FrameworkCatalogSeeder.php:290-296` as `FrameworkGap` rows with
  `kind = missing_potential_competency`, `status = pending_authoring`. No `potential`
  competency definitions or catalog exist yet, so there is nothing for C8 to compose from.
- Consequence: **C8 requires NO new migration** and adds no `potential` branch to
  `SystemPromptComposer`. When MTG/LAT are authored, the deferred slice designs the
  fixed-then-adaptive flow (SA-08) as its own change, including whether Option A can hold the
  ordering or a server-driven sequence is required.

## Data Flow (standard only)

    InterviewController::start()
       └─ resolve role_id from project.role_code → Role.code (project on participant)
       └─ SystemPromptComposer::compose(competencyCode, roleId, competencyId,
                                        projectLocale, budget, nudgeMinChars)
             └─ BarsIndicatorLoader::forRoleCompetency(roleId, competencyId)
                    → indicators scoped by BOTH role_id AND competency_id, ordered by position
                    → (empty → composition throws before issue(); see Failure modes)
             → composes template sections; stamps config('conversation.prompt_version')
       → QuestionContext{competencyCode, questionIndex, systemPrompt, promptVersion}
       → ProviderSessionService::issue() → adapter create-body
             (HeyGen: system_prompt · Tavus: conversational_context)
       → avatar LLM runs adaptive follow-ups; transcript captured by existing Utterance relation
       → buildSuccessResponse adds prompt_version to the /start response body (M-3)

**Where `role_id` comes from.** `Project` carries `role_code` (ICO/FLL/MLL/BUL/SRX; required
for `standard`, immutable once active — `Project.php:22,63-64`). The participant's `project`
is already loaded in `start()` (`InterviewController.php:81`). `BarsIndicatorLoader` resolves
`project.role_code → Role.code → Role.id` (`Role.php:19,43`), then queries indicators by
`role_id + competency_id`. The composed prompt for a competency under role X therefore contains
**only role-X indicators** — the required correctness property from RV-2.

## Template structure (`SystemPromptComposer`)

Mirrors legacy `composeQuestionPrompt()`, framework-aware, pure function. Sections, all in the
**project language**: (1) role/interview-style instructions; (2) coverage topics = ordered,
role-scoped BARS indicator `text` (internal, never revealed verbatim); (3) follow-up budget
"ask at most N follow-ups only for uncovered topics" (OQ-1 N=2, from `config/conversation.php`);
(4) nudge "if an answer is under `{nudge_min_chars}` chars, re-prompt once — this does NOT
consume a follow-up slot" (OQ-3), omitted when `nudge_min_chars` is null; (5) advance rule
"speak `end_phrase` only after coverage/budget exhausted" (R-5). **No `potential` block.**

The composer stamps `config('conversation.prompt_version')` (RV-4) onto its output so every
interview records which conversation template shaped it — independent of C9's
`scoring.prompt_version`.

## Interfaces

```php
// App\Services\Provider\QuestionContext — WIDENED (two nullable fields, backward-compatible)
readonly class QuestionContext {
  public function __construct(
    public string  $competencyCode,
    public int     $questionIndex,
    public ?string $systemPrompt  = null,   // NEW — null keeps exact C7a behavior
    public ?string $promptVersion = null,   // NEW — traceability
  ) {}
}

// App\Services\Conversation\BarsIndicatorLoader — NEW (C8-owned; does NOT touch C9)
final class BarsIndicatorLoader {
  /** @return Collection<int, BarsIndicator> ordered by position, scoped by role AND competency */
  public function forRoleCompetency(int $roleId, int $competencyId): Collection;
}

// App\Services\Conversation\SystemPromptComposer — NEW (pure function, no LLM, no HTTP)
final class SystemPromptComposer {
  public function compose(
    string $competencyCode, int $roleId, int $competencyId,
    string $projectLocale, int $budget, ?int $nudgeMinChars,
  ): ComposedPrompt; // { text: string, version: string }
}
```

### `config/conversation.php` (NEW — RV-4)

```php
return [
    // Conversation prompt template version, stamped by SystemPromptComposer.
    // Distinct lifecycle from scoring.prompt_version — do NOT reuse config/scoring.php.
    'prompt_version'  => env('CONVERSATION_PROMPT_VERSION', 'conv-2026-07-23'),
    // Default follow-up budget per competency (OQ-1 default; client-ratifiable).
    'followup_budget' => (int) env('CONVERSATION_FOLLOWUP_BUDGET', 2),
];
```

### `InterviewController::start()` change (M-3 — additive)

Currently `QuestionContext` is built at `InterviewController.php:98` with only
`competencyCode`+`questionIndex`, and `buildSuccessResponse` (`InterviewController.php:466-485`)
emits a fixed `question_context` with no `prompt_version`. The additive change:

1. Before building `$ctx`, call `SystemPromptComposer::compose(...)` (role_id resolved from
   `$project->role_code`). A composition failure returns **422** before `issue()` is called
   (see Failure modes) — no provider session is created.
2. Thread `systemPrompt` + `promptVersion` into the `QuestionContext` constructor.
3. Thread the composed `promptVersion` through `buildSuccessResponse` and add
   `'prompt_version'` to the `/start` response body (alongside the existing
   `question_context`). Field name stays literal snake_case (machine-facing).

This is an ADDITIVE C7a controller change; the create-or-resume / provider-outside-txn /
failure-matrix structure is untouched. (The earlier "no controller change" framing was wrong.)

## Testing Strategy

| Layer | What | How |
|---|---|---|
| Unit | `SystemPromptComposer` output: role-scoped coverage topics, budget=N, nudge instruction (present/omitted on null), advance rule, project language, `prompt_version` stamp | Pure fn, zero HTTP; snapshot + field asserts. **Determinism/`it` tests author IT translations via factory** (M-2) — seeded IT anchors do not exist yet (`FrameworkCatalogSeeder.php:298-302`) |
| Unit | `BarsIndicatorLoader::forRoleCompetency` returns ONLY role-X indicators (seed two roles sharing a competency; assert cross-role isolation) + position order | Factory-seeded; asserts the RV-2 correctness property |
| Unit | Missing role-scoped indicators / missing anchor translation for the project locale → composer throws (422 shape) | Reuses `PromptBuilder.php:72-73` `AnchorTranslationMissingException` semantics (M-2) |
| Feature (PR-gated) | Adapter outbound body CONTAINS the composed prompt under the expected key (`system_prompt` for HeyGen, `conversational_context` for Tavus); `systemPrompt=null` → legacy body unchanged | `Http::fake` payload-shape assertion (RV-3) — a missing/renamed field FAILS ON PR, not only in the deferred `@ai` suite |
| Feature | `/start` response includes `prompt_version`; `QuestionContext` carries the two new fields on the one production call site | Standard feature test against the controller (M-3) |
| Integration `@ai` (deferred) | Avatar compliance: ≤N follow-ups, nudge on short answer, `end_phrase` only after coverage | Real provider, `workflow_dispatch`/`release/*` only |

**Determinism/i18n (M-2).** The composer reuses `PromptBuilder`'s `anchor_translation_missing`
hard-fail (`PromptBuilder.php:72-73`) → **HTTP 422** when a translatable field lacks a
translation for the project locale. Because seeded IT anchor translations do NOT exist yet
(the seeder records the gap at `FrameworkCatalogSeeder.php:298-302`), the determinism and `it`
unit tests **must author translations via factory** — they cannot rely on seed data. This 422
failure path aligns with C7a's `/start` failure matrix (a pre-`issue()` failure that leaves the
session `pending`; the participant is NOT flipped to `errore`).

**Cassette:** default Option A adds **no** `LLMProvider` call → no cassette change. Pre-registered
constraint (unchanged): if a composition-time LLM call is ever added, its key MUST be namespaced
(`{competency_code}:conversation`) to avoid clobbering C9's `competency_code` key.

## i18n

Composition selects language from the project/participant language (it/en binding), consistent
with avatar TTS and C9 evaluation language. On a missing translation for that locale, the
composer hard-fails (422, above) rather than emitting a partial-language prompt. **No frontend
contract change** — `end_phrase`/`final_phrase` remain the sole completion signal; the system
prompt lives entirely server→provider. No `StartConfig` addition required.

## Failure modes (extends C7a `/start` matrix — fail fast, pre-`issue()`)

- **Missing role-scoped BARS indicators / unknown competency** → `BarsIndicatorLoader` returns
  empty → composer throws BEFORE `issue()`. Return **422 `composition_error`** (no provider
  session created; session stays `pending`; participant NOT flipped to `errore`). No
  partial/degraded prompt is ever injected — a prompt-less session would silently lose all
  adaptivity.
- **Missing anchor/text translation for the project locale** → `AnchorTranslationMissingException`
  (reused from `PromptBuilder.php:72-73`) → **422** (M-2), before `issue()`.
- **`nudge_min_chars` null** → omit the nudge section (feature-absent, not an error).

All composition failures are pre-`issue()`, so they cannot leave a half-created provider
session — consistent with the C7a "provider call outside txn" invariant.

### Addendum — graceful degradation on resume `in_corso` (added post-verify)

The fail-fast matrix above governs a **fresh** `/start` (participant `in_attesa` →
`issue()` a new provider session): a composition failure there is a 422 with no session
created, because a prompt-less brand-new interview would silently lose all adaptivity.

The **resume** path (participant already `in_corso`, provider session already live) is
different: the session exists and the candidate is mid-interview. Hard-failing 422 here
would strand a candidate who has already started. So on resume, a composition failure is
**degraded, not fatal** — the controller logs a warning and proceeds with a `null`
`systemPrompt` (the provider keeps its previously-issued context; no new prompt is
forwarded). This preserves interview continuity at the cost of adaptivity on the resumed
turn, which is the correct trade-off for an in-flight session.

This behavior was implemented during apply and confirmed by verify (tests 5.6–5.7); it is
recorded here because it extends — rather than contradicts — the fail-fast matrix. Fresh
`/start` = fail fast; resume `in_corso` = degrade and continue.

**`prompt_version` on the degraded path (post-review, FIX C1).** The `/start` 201 contract
requires `prompt_version` to be a non-null, non-empty string on every success response. On the
degraded resume path no fresh prompt is composed, so `system_prompt` stays null — but
`prompt_version` is restored from `config('conversation.prompt_version')` rather than left null,
to honour that invariant. Consequence for C9: a non-null `prompt_version` in the `/start`
response does NOT by itself prove an adaptive prompt was applied on the resumed turn. C9 scoring
does not rely on this field for traceability (it reads `config('scoring.prompt_version')`
independently and records its own versions on the evaluation/`ai_request` rows); the degraded
event is additionally captured by the `Log::warning` in `start()`. If a future consumer needs to
distinguish "prompt applied" from "degraded" purely from the response, that must be an explicit
new field — `prompt_version` alone is insufficient.

## Migration / Rollout

**No schema migration for C8** (RV-1 removed the only planned table). `QuestionContext` change
is backward-compatible (two nullable new fields; single production call site updated).
`config/conversation.php` is a new config file (no DB impact). Provider field names remain
INFERRED (RV-3) — the PR-gated `Http::fake` assertion guards against a silent rename, and
client confirmation of the real provider contract is required before live deploy.

## Open Questions

- [ ] **RV-3** — provider field names (`system_prompt` / `conversational_context`) and the
  `liveavatar.com/v1/contexts` endpoint are INFERRED/unverified; PR-gated payload assertion
  catches renames, but **client confirmation of the live provider contract is required before
  deploy**.
- [ ] OQ-1 budget N=2, OQ-3 nudge-not-consuming — provisional defaults (in `config/conversation.php`),
  client ratification required. (OQ-2 `potential` data model is DEFERRED with `potential`.)
- [ ] R-1 avatar compliance — verified only by the deferred `@ai` suite.
- [ ] `potential` (SA-08) — DEFERRED to a future slice gated on MTG/LAT authoring
  (open decision #6); NOT part of C8.
