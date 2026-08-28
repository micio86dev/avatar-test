# Delta for Interview Session

## ADDED Requirements

### Requirement: A session snapshots its LLM binding at issue(), never re-derived

`InterviewSession` MUST carry `avatar_template_id`, `llm_model_key` (the
model's `key` string, not a foreign key), `llm_binding_status` (one of
`applied | unbound | degraded`), and `system_prompt_chars`, all captured at
**`issue()`** — the same moment `provider` and `framework_version_id` are
already copied from project/template state and never re-derived. If an
operator edits the template's binding after a session has started, the
session's own snapshot MUST NOT change: an end-time read would otherwise
attribute the conversation to the wrong model.

`llm_binding_status` MUST be `applied` when the template's binding resolved
and was successfully applied to the provider payload; `unbound` when the
resolved template (or the absence of one) carries no LLM binding; and
`degraded` when a binding exists but could not be applied (e.g. a revoked
credential, a stale HeyGen configuration id, or a provider rejection) — in
which case the session still starts normally, on the provider's own default.

#### Scenario: The snapshot is captured at issue and stable across a mid-session edit

- GIVEN a session issued against a template bound to model `gemini-3-flash-preview`
- WHEN the operator changes that template's binding to a different model while the session is still live
- THEN the session's `llm_model_key` remains `gemini-3-flash-preview`

#### Scenario: A resolved template with no binding snapshots as unbound

- GIVEN the resolved active template for the session's provider carries no LLM binding
- WHEN the session is issued
- THEN `llm_binding_status = 'unbound'` and `llm_model_key` is null

#### Scenario: An unapplicable binding snapshots as degraded and the session still starts

- GIVEN a template bound to a credential that has since been revoked
- WHEN a candidate session is issued against that template
- THEN the session starts successfully, `llm_binding_status = 'degraded'`, and no conversation-LLM usage row is later written for it

#### Scenario: A successfully applied binding snapshots as applied

- GIVEN a template bound to a valid model and credential, resolvable and applicable to the provider payload
- WHEN a session is issued
- THEN `llm_binding_status = 'applied'` and `llm_model_key` equals the bound model's `key`
