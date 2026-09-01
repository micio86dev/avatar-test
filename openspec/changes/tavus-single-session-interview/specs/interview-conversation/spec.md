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
| `follow_up_budget` (max N per competency) | Platform config; default N=2 [PROVISIONAL — OQ-1] |
| `nudge_min_chars` | `Project.nudge_min_chars` |
| `prompt_template_version` | `config/conversation.php`; bumped on any template change |

The composition MUST:
- Require NO LLM inference call.
- Produce identical output for identical inputs (deterministic).
- Emit a stable `prompt_version` string that uniquely identifies the template and its version.
- Contain NO hardcoded per-tenant text; all anchor text flows from the versioned framework catalog at the pinned `framework_version_id`.
- Select the correct language (it/en binding) for all injected text.

For a project whose Tavus session covers multiple competencies in one conversation, the
composition function MUST ALSO support a multi-competency mode: given an ORDERED list of
competency codes for the same role/framework version, it MUST return ONE combined context
string containing each competency's full instructions, coverage topics, and anchor set,
still produced with no LLM call and still deterministic for identical inputs (the same
ordered list yields the same combined string). Each competency's segment within the
combined context MUST remain internally distinguishable, so a boundary interaction can
steer to one segment without altering another's already-established instructions.
(Previously: composition assumed exactly one competency per invocation; no multi-competency
input shape existed.)

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
> data-model divergence that **predates C8** and cannot be closed here. Closing it requires a
> dedicated **framework-versioning slice**. Until then this scenario is aspirational, not verified.

#### Scenario: Multi-competency composition is deterministic for the same ordered competency list

- GIVEN competencies [CSF, INN] for role FLL, framework version V, language `it`
- WHEN the multi-competency composition path is called twice with the ordered list [CSF, INN]
- THEN both calls return the identical combined context string and the same `prompt_version`

#### Scenario: A single-competency project is unaffected by the multi-competency mode's existence

- GIVEN a project whose Tavus session covers exactly one competency
- WHEN `/start` composes its context
- THEN the existing single-competency composition path runs unchanged; no multi-competency
  combination logic executes

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

When the session's provider is Tavus and the conversation will span several competencies,
`QuestionContext.system_prompt` MUST carry the FULL multi-competency combined context (per
the multi-competency composition mode above), composed once at the FIRST `/start` call that
creates the conversation — never recomposed or re-sent at a later competency's `/start`
within the same conversation, since `POST /v2/conversations` is called exactly once per
conversation. A subsequent `/start` that advances an existing live conversation (the
`interview-session` "Advance-on-live-ref" path) MUST NOT carry a `system_prompt` destined
for a fresh provider create-call.

#### Scenario: /start response contains prompt_version

- GIVEN a valid candidate JWT and a project with a configured `standard` competency
- WHEN `POST /api/candidate/interview/start` returns HTTP 201
- THEN `question_context.prompt_version` is a non-null, non-empty string in the response body

#### Scenario: C7a failure matrix is unchanged after QuestionContext widening

- GIVEN a provider 5xx/timeout hard-failure at `/start`
- WHEN `ProviderSessionService::issue()` is invoked with the extended `QuestionContext`
- THEN the failure matrix (session → error, participant → errore, HTTP 502) behaves identically to pre-C8 behavior

#### Scenario: The combined context is composed once at conversation creation, not per competency

- GIVEN a live Tavus conversation covering competencies [CSF, INN, DRV]
- WHEN the conversation is created at the first `/start`
- THEN `QuestionContext.system_prompt` carries all three competencies' composed content at
  that single call; the second and third `/start` calls for INN and DRV do not carry a
  fresh `system_prompt` destined for a new provider create-call

---

## ADDED Requirements

### Requirement: Multi-Competency Coverage Topics Are Never Revealed Verbatim to the Client

The "internal; not revealed verbatim" property already required of a single competency's
coverage topics extends unchanged to every competency's topics inside a multi-competency
combined context: no coverage topic, indicator name, or anchor text for ANY competency in
the combined context MUST appear in any response the candidate's browser can read, at any
point in the conversation — including for competencies not yet reached and competencies
already completed within that same conversation.

#### Scenario: An unreached competency's anchors are as protected as the current one's

- GIVEN a live conversation whose combined context already holds competency INN's anchors,
  currently on competency CSF
- WHEN any candidate-facing response is inspected while CSF is active
- THEN no fragment of INN's anchor or indicator text appears in it, exactly as CSF's own
  anchors do not

#### Scenario: A completed competency's anchors remain protected after its boundary has passed

- GIVEN a live conversation that has already advanced past competency CSF onto INN
- WHEN any candidate-facing response is inspected
- THEN no fragment of CSF's anchor or indicator text appears in it either — completion does
  not relax the guarantee
