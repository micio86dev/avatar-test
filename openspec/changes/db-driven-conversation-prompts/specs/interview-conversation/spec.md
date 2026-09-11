# Delta for Interview Conversation

## MODIFIED Requirements

### Requirement: System-Prompt Composition — Pure Function

The system MUST compose a system-prompt string server-side at `/start` time as a
deterministic, side-effect-free function of the following inputs:

| Input | Source |
|---|---|
| `competency_code` + BARS indicators + anchor texts `{5,3,1}` | `BarsIndicatorLoader` scoped by `role_id` + `competency_id`, pinned `framework_version_id` |
| `assessment_type` | Project configuration (`standard` only — C8) |
| `role_code` / `role_id` | Project configuration |
| `project_language` | Project configuration (`it` / `en` binding) |
| `follow_up_budget` (max N per competency) | Platform config `conversation.followup_budget`; default **N=4** |
| `min_questions` (floor, opening question included) | Platform config `conversation.min_questions`; default 4, CLAMPED by the composer |
| `nudge_min_chars` | `Project.nudge_min_chars` |
| **resolved template section set** (+ optional per-competency override) | Resolved at the CALL SITE from the active `conversation-prompt-templates` revision for `project_language`, and passed into `compose()` as a value object — the composer never reads it itself |

The composition MUST:
- Require NO LLM inference call.
- Perform NO DB, HTTP, time, or random access inside the composer — the resolved template
  section set arrives as a passed-in value; the composer is a pure function of its arguments.
- Produce identical output for identical inputs (deterministic), including an identical
  resolved template section set.
- Emit a `prompt_version` value that identifies the exact template revision id plus a content
  hash of the resolved section set — not a bumped config string.
- Contain NO hardcoded per-tenant text; all anchor text flows from the versioned framework
  catalog at the pinned `framework_version_id`.
- Select the correct language (it/en binding) for all catalogue-derived text AND for the
  resolved template sections (see the i18n requirement for exact scope).

Purity is defined as: no LLM call, no HTTP, no time, no randomness, no IO, evaluated ON THE
COMPOSER ITSELF. Template resolution happens at the call site (`InterviewController`);
`compose()` receives an already-resolved value object.

(Previously: template sections were hardcoded PHP heredocs inside the composer, and
`prompt_version` was a bumped config string with no structural relationship to the text that
produced it. This revision replaces the hardcoded sections with a passed-in resolved set and
redefines `prompt_version` as revision id + content hash.)

#### Scenario: Deterministic composition — same inputs yield same output

- GIVEN competency PRS, framework version V, role FLL, language `it`, N=2, nudge_min_chars=80, and a resolved template set from revision R
- WHEN `compose()` is called twice with identical inputs
- THEN both calls return the identical prompt string and the same `prompt_version` value

#### Scenario: prompt_version identifies the exact resolved revision and content

- GIVEN two compositions against different revisions R1 and R2 whose resolved section sets differ
- WHEN each prompt is composed
- THEN their `prompt_version` values differ, and each encodes its own revision id and content hash

#### Scenario: No LLM call during composition

- GIVEN the composition service is invoked at `/start`
- WHEN `compose()` runs
- THEN no HTTP call is made to any LLM or external provider

#### Scenario: Composer performs no DB, HTTP, time, or random access

- GIVEN the composer's implementation
- WHEN its call graph is inspected
- THEN it contains no query, no HTTP call, no time call, and no random-number call — all template content arrives via its parameters

#### Scenario: Composition uses pinned framework_version_id, never live draft

- GIVEN `project.framework_version_id = V` and a newer live catalog draft V+1 exists
- WHEN the prompt is composed
- THEN BARS indicators and anchors are read from version V; no data from V+1 is injected

> **⚠️ KNOWN GAP (pre-existing, deferred — do NOT treat as covered here).** Unchanged from
> before this delta: `framework_bars_indicators` has no `framework_version_id` column, so this
> scenario is aspirational, not verified. See `interview-conversation`'s existing note.

---

## ADDED Requirements

### Requirement: Byte-Identical Composition Against the Pre-Change Golden Output

The composed prompt MUST be byte-identical to the pre-change (hardcoded-PHP) composer's
output, for every (role, competency, locale, budget, nudge, minimum, advance-phrase,
authored-questions) combination the existing `SystemPromptComposerTest` suite covers, when
composed against the seeded template revision carrying the pre-change text verbatim. This is
the change's primary gate.

#### Scenario: Every existing test-suite combination byte-matches the golden

- GIVEN a seeded template revision containing the pre-change text verbatim
- AND every combination the existing test suite covers
- WHEN each combination is composed
- THEN the output is byte-identical to the captured pre-change golden output for that combination

---

### Requirement: Placeholder Contract Enforced at Composition Time

In addition to the save-time guard (`conversation-prompt-templates`), composition MUST
independently refuse — throwing `CompositionException` — any resolved `advance_*` body
missing its required placeholders. No unbound `:token` placeholder syntax and no bare
`end_phrase` literal MAY survive into the composed text.

#### Scenario: A resolved advance_* body missing a placeholder fails composition

- GIVEN a resolved `advance_with_phrase` body lacking the advance-phrase placeholder (having bypassed save-time validation, e.g. via a seeder or raw SQL)
- WHEN composition runs
- THEN `CompositionException` is thrown; no prompt is returned

#### Scenario: No unbound token or bare end_phrase literal survives into composed text

- GIVEN any valid composition inputs against the active revision
- WHEN the composed prompt string is inspected
- THEN it contains no unresolved `:token` placeholder syntax and no bare `end_phrase` literal

---

### Requirement: prompt_version Traceability and Unresolvable-Revision Refusal

`prompt_version` MUST identify exact composed bytes via the template revision id plus a
content hash of the resolved section set. An unresolvable revision MUST fail composition
rather than stamp an untraceable value — extending the existing blank-version refusal.
Editing or activating a revision MUST NOT retroactively change the prompt of any interview
already composed or scored.

#### Scenario: An unresolvable revision fails composition

- GIVEN the configured active revision id has no corresponding template rows
- WHEN composition is attempted
- THEN `CompositionException` is thrown; no `prompt_version` is stamped

#### Scenario: A stamped prompt_version reconstructs identical bytes later

- GIVEN an interview composed and stamped with `prompt_version` V
- WHEN the prompt is reconstructed later from V, even after a newer revision was activated
- THEN the reconstructed bytes are identical to what was originally composed

---

### Requirement: Locale Hard-Fail on Missing Template Row

A template section row missing the project's locale MUST cause composition to hard-fail; no
mixed-language prompt MAY be composed — mirroring the existing `AnchorTranslationMissingException`
rule for anchors.

#### Scenario: A missing-locale template row blocks composition

- GIVEN the active revision has no `it` body for section `nudge` and the project language is `it`
- WHEN composition is attempted
- THEN it fails; no prompt mixing `it` and `en` sections is produced

---

### Requirement: Per-Competency Override Rendered at a Fixed Position

When a per-role×competency override exists for the resolved (role, competency, locale), it
MUST render as one additional named section placed after COVERAGE TOPICS and before the STAR
protocol section, and MUST change nothing else in the composed prompt.

#### Scenario: An override appears at the specified position only

- GIVEN a competency with an override body
- WHEN the prompt is composed
- THEN the override text appears after COVERAGE TOPICS and before STAR COVERAGE PROTOCOL, and every other section is unchanged

#### Scenario: A competency with no override composes exactly the default

- GIVEN a competency with no override row
- WHEN the prompt is composed
- THEN the output is identical to composing the same inputs with the override step skipped entirely
