# Delta for Observability & Analytics

## ADDED Requirements

### Requirement: AiRequestFailureReason Gains a Truncation Case

`AiRequestFailureReason` (the closed set backing `ai_requests.failure_reason`,
enforced by the `ai_requests_failure_reason_check` Postgres CHECK constraint) MUST
gain a seventh case, `truncated`, identifying a provider response truncated at the
configured `max_tokens` budget (distinct from the existing `ParseError`,
`IndicatorCountMismatch`, `InvalidIndicatorScore`, `ExcerptNotVerbatim`,
`ProviderError`, and `Timeout` cases, and distinct from `scoring-engine`'s
competency-level `llm_truncated` `unscorable_reason` — the two are different columns
on different models, deliberately given related but non-identical names).
Adding this case REQUIRES a migration widening the CHECK constraint; the migration
MUST ship before any code path writes the new value, or every write of it fails
at the database layer.

#### Scenario: A truncated call is logged with the truncation failure reason

- GIVEN a provider call returns `finish_reason = 'max_tokens'`
- WHEN the `ai_requests` row for that call is written
- THEN `failure_reason = 'truncated'`, distinct from `llm_parse_error`

#### Scenario: The CHECK constraint accepts the new value only after migration

- GIVEN the CHECK-constraint migration has run
- WHEN a row is inserted with the new truncation `failure_reason` value
- THEN the insert succeeds
- AND inserting the same value against the PRE-migration constraint would have been rejected — the migration MUST precede any writer (deploy-order contract)

---

### Requirement: ai_requests Derived-Signal Diagnostic Fingerprint

Every `ai_requests` row for a scoring call MUST additionally carry a
DERIVED-SIGNALS-ONLY diagnostic fingerprint: response byte length (integer), a
boolean indicating whether the raw response body starts with a markdown code fence,
and OPTIONALLY a non-reversible response hash. `finish_reason` and `output_tokens`
already exist and remain part of this fingerprint's readable signal set.

The fingerprint MUST NOT include any raw substring of the provider response body, at
any length. This is a GDPR boundary, not a style preference:
`openspec/specs/data-retention/spec.md` enumerates exactly four candidate-data
classes (`snapshot`, `transcript`, `webhook_payload`, `participant_pii`);
`ai_requests` is deliberately not among them because it carries no verbatim
candidate-derived content today. Storing a raw fragment would create a fifth
candidate-data class with no ratified retention duration. `data-retention/spec.md`
MUST appear in NO delta of this change — that document stays byte-unchanged.

#### Scenario: A failed scoring call's ai_requests row carries the derived fingerprint

- GIVEN a scoring call that fails to parse
- WHEN its `ai_requests` row is written
- THEN it carries `finish_reason`, `output_tokens`, a response byte-length integer, and a fence-boolean
- AND it carries no field containing any substring of the raw provider response body — asserted by test

#### Scenario: data-retention/spec.md is untouched by this change

- GIVEN the complete diff for this change
- WHEN `openspec/specs/data-retention/spec.md` is inspected
- THEN it is byte-identical to its pre-change state; no delta targets this capability

---

### Requirement: Each Truncation Retry Attempt Gets Its Own ai_requests Row

The truncation-only retry (see `scoring-engine`'s Truncation-Only Retry At An
Enlarged Budget requirement) MUST write a SEPARATE `ai_requests` row for the retried
call — it MUST NOT update or reuse the row from the first, truncated attempt. This
follows the existing one-row-per-call, append-only, transaction-independent logging
requirements verbatim: a retry is a second billed provider call, and hiding it inside
the first row's row would under-report cost exactly when a failure already occurred.

#### Scenario: Two ai_requests rows exist for one competency's truncation-and-retry sequence

- GIVEN competency PRS truncates once and is retried once at an enlarged budget
- WHEN both attempts complete (regardless of whether the retry succeeds)
- THEN exactly TWO `ai_requests` rows exist for PRS: one `success = false` (truncation), and one reflecting the retry's own outcome
- AND neither row is a mutation of the other — both are independent, append-only inserts
