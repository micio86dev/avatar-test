# Interview Conversation Specification

## Purpose

Defines the adaptive conversation layer (C8): server-side system-prompt composition from
BARS indicator data, coverage-driven adaptive follow-up questioning for `standard` sessions
(SA-02), nudge enforcement on short answers (SA-03), and a PR-gated payload-shape contract
for the provider session. All behavior is injected at `/start` via the extended
`QuestionContext`; no per-turn server round-trip is introduced. Additive to C7a's
five-endpoint contract.

---

## Out of Scope

- **`potential` / SA-08 flow** — deferred to a future slice. MTG/LAT competency definitions
  and their 4 fixed questions are currently `pending_authoring` in the framework catalog
  (open decision #6 — non-English BARS anchor authoring). C8 delivers the `standard`
  adaptive path ONLY. No `potential`, no `framework_potential_questions` model, no
  fixed-sequence block.

---

## Non-Goals

- BARS scoring or `Evaluation` persistence (C9)
- Outbound webhook delivery (C10)
- Provider token issuance, session lifecycle, teardown, transcript reconcile (C7a)
- Admin dashboards or interview monitoring UI (C11)
- Domain retry (RT-B) and time-limit/deadline logic (open product decisions #4/#5)
- Per-turn server LLM inference (Option B)
- Hardcoded per-tenant question or anchor text
- Refactoring `ScoreEvaluationJob` (C9) — C8 introduces its own `BarsIndicatorLoader`

---

## Requirements

### Requirement: BARS Indicator Loading — BarsIndicatorLoader

C8 MUST introduce a dedicated `BarsIndicatorLoader` class that scopes BARS indicators by
BOTH `role_id` AND `competency_id`. This MUST be new code; the existing C9
`ScoreEvaluationJob` inline indicator query MUST NOT be refactored or extracted.

The loader MUST prevent cross-role indicator contamination: indicators belonging to the same
competency code but a different role MUST NOT be returned.

#### Scenario: Indicators filtered by both role and competency

- GIVEN competency COL exists for roles FLL (3 indicators) and MLL (2 different indicators)
- WHEN `BarsIndicatorLoader::load(role_id: FLL, competency_id: COL)` is called
- THEN only the 3 FLL-COL indicators are returned; no MLL-COL indicators appear in the result

#### Scenario: Cross-role contamination is impossible

- GIVEN roles FLL and MLL share competency code COL with disjoint indicator sets
- WHEN `BarsIndicatorLoader::load()` is called for each role independently
- THEN the two returned indicator sets are disjoint; no indicator from MLL appears in the FLL result and vice versa

---

### Requirement: System-Prompt Composition — Pure Function

The system MUST compose a system-prompt string server-side at `/start` time as a
deterministic, side-effect-free function of the following inputs:

| Input | Source |
|---|---|
| `competency_code` + BARS indicators + anchor texts `{5,3,1}` | `BarsIndicatorLoader` scoped by `role_id` + `competency_id`, pinned `framework_version_id` |
| `assessment_type` | Project configuration (`standard` only — C8) |
| `role_code` / `role_id` | Project configuration |
| `project_language` | Project configuration (`it` / `en` binding) |
| `follow_up_budget` (max N per competency) | Platform config; default N=2 [PROVISIONAL — OQ-1] |
| `nudge_min_chars` | `Project.nudge_min_chars` |
| `prompt_template_version` | `config/conversation.php`; bumped on any template change |

The composition MUST:
- Require NO LLM inference call.
- Produce identical output for identical inputs (deterministic).
- Emit a stable `prompt_version` string that uniquely identifies the template and its version.
- Contain NO hardcoded per-tenant text; all anchor text flows from the versioned framework catalog at the pinned `framework_version_id`.
- Select the correct language (it/en binding) for all injected text.

#### Scenario: Deterministic composition — same inputs yield same output

- GIVEN competency PRS, framework version V, role FLL, language `it`, N=2, nudge_min_chars=80, template v1
- WHEN `ConversationService::composePrompt()` is called twice with identical inputs
- THEN both calls return the identical prompt string and the same `prompt_version` value

#### Scenario: prompt_version is non-null and version-stamped

- GIVEN any valid set of composition inputs
- WHEN the prompt is composed
- THEN `prompt_version` is a non-null, non-empty string reflecting the active template version from `config/conversation.php`

#### Scenario: No LLM call during composition

- GIVEN the composition service is invoked at `/start`
- WHEN `composePrompt()` runs
- THEN no HTTP call is made to any LLM or external provider; the result is produced purely from in-memory template + catalog data

#### Scenario: Composition uses pinned framework_version_id, never live draft

- GIVEN `project.framework_version_id = V` and a newer live catalog draft V+1 exists
- WHEN the prompt is composed
- THEN BARS indicators and anchors are read from version V; no data from V+1 is injected

> **⚠️ KNOWN GAP (pre-existing, deferred — do NOT treat as covered by C8).** This scenario is
> currently **unenforceable**: `framework_bars_indicators` has no `framework_version_id` column,
> and neither the C8 `BarsIndicatorLoader` nor the merged C9 `ScoreEvaluationJob` filters
> indicators by framework version — both scope by `role_id`/`competency_id` only. This is a
> data-model divergence that **predates C8** and cannot be closed here (C8 design forbids a new
> migration, RV-1/RV-4). Closing it requires a dedicated **framework-versioning slice** that adds
> the column + backfill and updates BOTH C8 and C9 loaders under their own tests. Until then this
> scenario is aspirational, not verified.

---

### Requirement: Adaptive Standard Follow-Up Questioning (SA-02)

For `assessment_type = 'standard'`, the composed system prompt MUST instruct the avatar
to conduct coverage-driven follow-up questioning within each competency:

1. Ask at most N follow-up questions per competency, where N = `follow_up_budget` (default N=2, provisional OQ-1).
2. The avatar MUST be instructed to speak `end_phrase` only when all BARS indicators are addressed OR the follow-up budget is exhausted — not on the first candidate answer.
3. The system prompt MUST explicitly name the BARS indicators to be covered so the avatar LLM can evaluate coverage.
4. Follow-up slots are consumed only by coverage-driven turns, not by nudge re-prompts.

#### Scenario: follow_up_budget injected into composed prompt

- GIVEN N=2, assessment_type='standard', competency STG with 3 BARS indicators for role BUL
- WHEN the prompt is composed
- THEN the resulting prompt string contains language instructing the avatar to ask at most 2 follow-up questions and to advance (end_phrase) only after coverage or budget exhaustion

#### Scenario: Budget exhaustion triggers end_phrase — integration assertion

- GIVEN a HeyGen session initialized with a standard prompt capping N=2 follow-ups
- WHEN the avatar has asked the initial question plus 2 follow-up questions
- THEN the avatar speaks `end_phrase` at the next turn — PROVIDER INTEGRATION TEST ONLY (@ai suite)

#### Scenario: Coverage achieved before budget — end_phrase fires early — integration assertion

- GIVEN a HeyGen session and candidate answers that address all BARS indicators in fewer than N turns
- WHEN the avatar determines coverage is complete
- THEN the avatar speaks `end_phrase` before consuming the full N budget — PROVIDER INTEGRATION TEST ONLY (@ai suite)

---

### Requirement: Nudge Enforcement (SA-03)

The composed system prompt MUST inject the `nudge_min_chars` value from `Project` and
instruct the avatar to re-prompt the candidate when an answer is below the minimum length
threshold before counting it toward BARS coverage.

A nudge MUST NOT consume a follow-up budget slot (provisional OQ-3).

#### Scenario: nudge_min_chars from Project injected into prompt

- GIVEN `Project.nudge_min_chars = 100` and any valid competency
- WHEN the prompt is composed
- THEN the prompt string contains a character-length threshold instruction (100 chars) directing the avatar to re-prompt when the answer is too short

#### Scenario: nudge_min_chars = 0 — no nudge instruction injected

- GIVEN `Project.nudge_min_chars = 0`
- WHEN the prompt is composed
- THEN no nudge length threshold instruction is injected (nudge disabled)

#### Scenario: Nudge does not consume a follow-up slot — integration assertion

- GIVEN N=2, a candidate who gives a too-short first answer (nudge fires), then a sufficient answer
- WHEN the avatar re-prompts once (nudge) and the candidate responds adequately
- THEN the avatar proceeds to use its 2 follow-up budget slots for coverage (nudge did not consume one) — PROVIDER INTEGRATION TEST ONLY (@ai suite)

---

### Requirement: Provider Payload Contract — PR-Gated Shape Assertion (C-1)

The provider create-call body MUST include the composed `system_prompt` (and the
`conversational_context` envelope if required by the provider) at session creation.

A unit/feature-tier `Http::fake` payload-shape assertion MUST verify the system prompt
field is present and non-empty in the provider REST call body. This test MUST run on
every PR (not only in the `@ai` suite). A missing or renamed provider field MUST fail
the PR test suite.

Avatar behavioral compliance (≤N follow-ups, nudge non-slot-consumption, `end_phrase`
advance signal) belongs exclusively to the `@ai` integration suite.

#### Scenario: Provider create-call body contains system_prompt — feature test

- GIVEN `Http::fake` intercepts the provider session-creation request
- WHEN `/start` is called with a valid candidate JWT and a composed `system_prompt`
- THEN the intercepted request body contains a non-empty `system_prompt` (or provider-mapped equivalent field); missing or null fails the assertion — UNIT/FEATURE TEST, PR-gated

#### Scenario: Provider call omits system_prompt — feature test catches it

- GIVEN `Http::fake` intercepts the provider session-creation request
- WHEN `QuestionContext::system_prompt` is null or empty (composition failure bypassed)
- THEN the `Http::fake` payload-shape assertion fails; no provider session is created — UNIT/FEATURE TEST, PR-gated

---

### Requirement: QuestionContext Carries Composed Prompt

The `QuestionContext` DTO MUST carry the composed `system_prompt` and `prompt_version`
as additive fields. The extended `QuestionContext` flows through
`ProviderSessionService::issue()` to the provider adapters (HeyGen, Tavus).

The C7a `/start` control flow (create-or-resume, provider-outside-txn, failure matrix)
is UNCHANGED. This is a purely additive widening.

The `/start` response body MUST include `prompt_version` in the `question_context` object
as a non-null, non-empty string (audit and traceability). This field is additive to the
existing `question_context` shape (C7a addendum: `end_phrase`, `final_phrase`).

#### Scenario: /start response contains prompt_version

- GIVEN a valid candidate JWT and a project with a configured `standard` competency
- WHEN `POST /api/candidate/interview/start` returns HTTP 201
- THEN `question_context.prompt_version` is a non-null, non-empty string in the response body

#### Scenario: C7a failure matrix is unchanged after QuestionContext widening

- GIVEN a provider 5xx/timeout hard-failure at `/start`
- WHEN `ProviderSessionService::issue()` is invoked with the extended `QuestionContext`
- THEN the failure matrix (session → error, participant → errore, HTTP 502) behaves identically to pre-C8 behavior

---

### Requirement: i18n — Composed Prompt in Project Language

The composed system prompt (instructions, indicator descriptions, anchor texts, nudge
instruction, follow-up guidance) MUST be entirely in the project language for the
`it`/`en` binding. Mixed-language prompts are PROHIBITED.

If any required anchor or indicator translation is missing for the project locale, the
engine MUST NOT silently fall back to English. Composition MUST fail with the
`anchor_translation_missing` signal; `/start` MUST return HTTP 422 and MUST NOT create
any `InterviewSession` row or make any provider call.

> **Coverage note — `it` fixture gap**: Italian-language composition scenarios require
> factory-authored anchor translations. Seeded IT translations do not exist yet; the
> `anchor_translation_missing` hard-fail path (HTTP 422) covers the gap at the feature
> tier until IT seed data is authored.

#### Scenario: Project language selects `en` anchor texts

- GIVEN project language = `en` and competency COL has English anchor translations
- WHEN the prompt is composed
- THEN all injected indicator descriptions and anchor texts are in English

#### Scenario: Project language selects `it` anchor texts (factory-seeded)

- GIVEN project language = `it` and competency COL has Italian anchor translations (factory-authored)
- WHEN the prompt is composed
- THEN all injected strings are in Italian; no English anchor string appears

#### Scenario: Missing project-locale translation blocks composition — HTTP 422

- GIVEN project language = `it` and competency INN has no Italian translation for one indicator's anchor text
- WHEN `POST /api/candidate/interview/start` is called
- THEN HTTP 422 is returned; no `InterviewSession` row is created; no provider call is made; the error carries the `anchor_translation_missing` signal

---

### Requirement: Testability Split — Server-Asserted vs Provider-Delegated

Requirements marked **"PROVIDER INTEGRATION TEST ONLY"** MUST NOT be verified in unit or
feature tests; they belong in the `@ai` group run on `workflow_dispatch` / `release/*`,
never on PR.

All other requirements MUST be verifiable via unit tests with zero HTTP and zero avatar
dependency (deterministic assertions on the composed prompt string, indicator content,
versioning, language, budget, nudge value).

#### Scenario: Unit test asserts BARS indicators appear in composed prompt

- GIVEN competency COL with 3 FLL BARS indicators I1, I2, I3 and their English anchor texts
- WHEN the prompt composition unit test runs with no HTTP fixtures
- THEN the returned prompt string contains all 3 indicator names/descriptions and all anchor texts

#### Scenario: @ai integration test asserts end_phrase compliance

- GIVEN a live HeyGen session initialized with a standard prompt
- WHEN the `@ai` test group runs on workflow_dispatch
- THEN the test verifies the avatar speaks `end_phrase` only after coverage/budget exhaustion — NOT run on PR

---

## Coverage Note

The following paths MUST be held to ~95% test coverage (unit / Pest feature tests, no HTTP):

- `BarsIndicatorLoader::load()` — filters by both `role_id` and `competency_id`; cross-role contamination impossible
- `ConversationService::composePrompt()` — all input combinations: `standard`, it/en, N=0/1/2, nudge_min_chars=0/N, missing translation hard-fail (HTTP 422)
- `prompt_version` non-null and changes when template version changes
- `QuestionContext` widening — `system_prompt` and `prompt_version` non-null after composition
- `/start` response includes `question_context.prompt_version`
- Provider payload shape (`Http::fake` assertion) — PR-gated
- `anchor_translation_missing` hard-fail blocks session creation (HTTP 422)

Provider-compliance scenarios (avatar follow-up count, nudge slot non-consumption, end_phrase timing) MUST be in the `@ai` integration suite, NOT in the Pest feature suite.
