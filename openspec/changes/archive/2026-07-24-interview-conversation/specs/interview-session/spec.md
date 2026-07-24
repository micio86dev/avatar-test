# Delta for Interview Session

## ADDED Requirements

### Requirement: POST /start question_context — prompt_version, server-side system_prompt injection (C8 addendum)

`POST /api/candidate/interview/start` MUST include `prompt_version` as an additive field in
the `question_context` response object, alongside the existing `end_phrase` and
`final_phrase` fields (C7a addendum).

- `prompt_version`: a non-null, non-empty string uniquely identifying the prompt template
  version used for this session (sourced from `config/conversation.php`). Used by C9 for
  traceability — aligns with `Evaluation.prompt_version` (scoring-engine spec).

`prompt_version` is NESTED inside `question_context` — it is NOT a top-level response field.
This is a backward-compatible addition to the existing `/start` response shape. The
five-endpoint contract, the C7a failure matrix, and all other `question_context` fields
are unchanged.

**SECURITY — the composed `system_prompt` MUST NOT appear in the `/start` response.** The
system prompt embeds the BARS indicator anchors that C9 uses to score the candidate;
returning it to the candidate client would expose the scoring rubric to the person being
assessed. The composed `system_prompt` is therefore delivered ONLY server-to-server: the
controller passes it through the extended `QuestionContext` to
`ProviderSessionService::issue()`, which injects it into the provider session at creation.
The candidate client receives only `prompt_version` for traceability. The C7a control flow
(create-or-resume, provider-outside-txn, failure matrix, UNIQUE resume path) is UNCHANGED by
this widening.

#### Scenario: /start returns question_context.prompt_version for standard session

- GIVEN a project with assessment_type='standard', language='en', and a competency with BARS indicators
- WHEN `POST /api/candidate/interview/start` returns HTTP 201
- THEN `question_context.prompt_version` is a non-null, non-empty string

#### Scenario: /start response never exposes the composed system_prompt (anti-leak)

- GIVEN a project with assessment_type='standard', language='it', and competency PRS with factory-authored Italian BARS indicators
- WHEN `POST /api/candidate/interview/start` returns HTTP 201
- THEN the response body contains `question_context.prompt_version`
- AND NO field of the response body contains the composed `system_prompt` text or its BARS anchor content
- AND the composed `system_prompt` IS present in the outbound provider `issue()` request body (server-to-server only)

#### Scenario: Composition failure (anchor_translation_missing) returns 422 — no session created

- GIVEN project language='it' and competency INN has missing Italian anchor translations
- WHEN `POST /api/candidate/interview/start` is called
- THEN HTTP 422 is returned; no `InterviewSession` row is created; no provider call is made; error carries `anchor_translation_missing`

#### Scenario: C7a failure matrix unchanged after QuestionContext widening

- GIVEN a provider 5xx hard-failure during `/start`
- WHEN `ProviderSessionService::issue()` receives the extended `QuestionContext`
- THEN session status = 'error', participant → errore, HTTP 502 — identical to pre-C8 behavior
