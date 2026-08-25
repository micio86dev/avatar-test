# Delta for Scoring Engine

## MODIFIED Requirements

### Requirement: Indicator Score Domain Validation

Each indicator score returned by the LLM MUST be validated server-side as exactly one
value from `{1, 2, 3, 4, 5} ∪ {-1}`. Scores of 0, 6, any decimal, any other negative
value, or any value outside this set MUST be rejected. An illegal score MUST NOT
discard the whole competency: validation happens per-indicator, and a rejected
indicator is persisted with `IndicatorScore.score = -1` and `IndicatorScore.reason =
'score_illegal'` (see Requirement: Per-Indicator Validation-Failure Isolation).
Sibling indicators in the same competency that validated cleanly MUST retain their
own scores unaffected.
(Previously: legal domain was `{1, 3, 5} ∪ {-1}`, and an illegal score threw
`InvalidIndicatorScoreException` inside a single `try` spanning the whole competency,
discarding every already-validated sibling indicator.)

#### Scenario: Indicator count mismatch → llm_parse_error, no queue retry

- GIVEN the LLM returns a `behaviors` array with 4 elements for competency COL, but COL has 3 indicators in the BARS catalog
- WHEN `EvaluationParser` maps the response to BARS indicators by array position
- THEN the count mismatch is detected
- AND the competency is immediately marked `llm_parse_error` with `score = NULL`, `valid = false`
- AND NO queue retry is triggered for this competency
- AND this is a competency-envelope failure, unaffected by per-indicator isolation (no per-indicator DTOs exist to isolate when the envelope itself did not parse)

#### Scenario: Score 2 accepted

- GIVEN the LLM returns an indicator score of 2 for indicator I
- WHEN the validator processes the response
- THEN an `IndicatorScore` row is persisted with `score = 2`

#### Scenario: Score 4 accepted

- GIVEN the LLM returns an indicator score of 4 for indicator I
- WHEN the validator processes the response
- THEN an `IndicatorScore` row is persisted with `score = 4`

#### Scenario: Score -1 accepted as unassessable sentinel, tagged model_declared

- GIVEN the LLM returns score -1 for indicator I (no assessable evidence)
- WHEN the validator processes the response
- THEN an `IndicatorScore` row is persisted with `score = -1` and `reason = 'model_declared'`

#### Scenario: Score 5 accepted

- GIVEN the LLM returns score 5 for indicator I
- WHEN the validator processes the response
- THEN an `IndicatorScore` row is persisted with `score = 5`

#### Scenario: Illegal score is contained to its own indicator, siblings survive

- GIVEN competency COL has 3 indicators and the LLM returns scores `[3, 6, 5]` (indicator 2 is illegal)
- WHEN the validator processes the response
- THEN indicator 2 is persisted with `score = -1`, `reason = 'score_illegal'`
- AND indicators 1 and 3 are persisted with their own scores `3` and `5`, unaffected
- AND no `InvalidIndicatorScoreException` propagates past the single indicator

#### Scenario: Illegal decimal score is contained the same way

- GIVEN the LLM returns an indicator score of 3.5 for one indicator among several valid ones
- WHEN the validator processes the response
- THEN only that indicator is persisted with `score = -1`, `reason = 'score_illegal'`
- AND the competency's other indicators are unaffected

#### Scenario: Illegal negative score other than -1 is contained the same way

- GIVEN the LLM returns an indicator score of -2 for one indicator among several valid ones
- WHEN the validator processes the response
- THEN only that indicator is persisted with `score = -1`, `reason = 'score_illegal'`
- AND the competency's other indicators are unaffected

---

### Requirement: Excerpt Verbatim Validation

Every excerpt in an `IndicatorScore` result MUST be a verbatim substring of the assembled
session transcript (whitespace-normalized for the check only). The system MUST validate
this by substring search. A non-matching excerpt MUST NOT discard the whole competency:
that single indicator is persisted with `score = -1` and `reason = 'excerpt_unverifiable'`
(see Requirement: Per-Indicator Validation-Failure Isolation); sibling indicators that
validated cleanly retain their own scores. The system MUST NOT accept paraphrased,
summarized, or invented text for any indicator.

Whitespace normalization: collapses runs of `\s+` (all whitespace including `\n`, `\t`,
multiple spaces) to a single U+0020 on BOTH the excerpt AND the assembled transcript
before the substring check. The ORIGINAL LLM excerpt text is persisted in
`IndicatorScore.excerpts` (not the normalized form). Cross-utterance excerpts are
PERMITTED: the transcript is one assembled string (speaker-prefixed utterances joined by
`\n`); an excerpt may span across utterance boundaries within that assembled string.
(Previously: a non-verbatim excerpt "flagged the competency result as invalid" via the
single competency-wide `try`/catch, discarding every already-validated sibling indicator.)

#### Scenario: Verbatim excerpt accepted

- GIVEN a transcript T containing the phrase "mi è capitato di lavorare"
- WHEN an excerpt exactly matching that phrase is validated
- THEN the excerpt is accepted and persisted

#### Scenario: Non-verbatim excerpt is contained to its own indicator, siblings survive

- GIVEN competency COL has 3 indicators and indicator 2's excerpt "candidate showed collaboration" is not a substring of transcript T
- WHEN the excerpt is validated
- THEN indicator 2 is persisted with `score = -1`, `reason = 'excerpt_unverifiable'`
- AND indicators 1 and 3, which validated cleanly, retain their own scores
- AND the competency is NOT discarded — it survives with a lower reliability

#### Scenario: Whitespace normalization — multi-space collapsed

- GIVEN an excerpt "foo  bar" and the assembled transcript containing "foo bar" (single space)
- WHEN both are whitespace-normalized and the substring check runs
- THEN the excerpt is accepted

#### Scenario: Cross-utterance excerpt accepted

- GIVEN the assembled transcript is "Interviewer: Tell me about collaboration.\nCandidate: I worked closely with a colleague."
- WHEN an excerpt "collaboration.\nCandidate: I worked" is submitted
- THEN after whitespace normalization the excerpt is a substring of the normalized transcript
- AND the excerpt is accepted

---

### Requirement: LLM Parse Error — Persistent Malformed Output

When the LLM returns output that cannot be parsed into valid per-indicator results after
the fence/prose tolerance pass (see Requirement: Fence and Leading/Trailing Prose
Tolerance) — including wrong indicator count or JSON that remains invalid after that
tolerance — the competency MUST be marked with `unscorable_reason = 'llm_parse_error'`
and `score = NULL`, `valid = false`. A response whose `finish_reason` indicates
truncation MUST NOT be marked `llm_parse_error`; it is a distinct class (see
Requirement: Truncation Detected From `finish_reason` Before Parsing). Neither class
triggers a queue retry directly; both ARE counted in the gate denominator.
(Previously: rejection criteria was scores outside `{1,3,5,-1}` with zero
pre-processing before `json_decode`, so a markdown-fenced body or a truncated
response both surfaced as the same generic `llm_parse_error`.)

#### Scenario: Persistent invalid JSON, not fenced and not truncated → llm_parse_error

- GIVEN the LLM returns syntactically invalid JSON for competency STG, with no leading/trailing fence and `finish_reason != 'max_tokens'`
- WHEN `EvaluationParser` applies fence/prose tolerance and still cannot decode the body
- THEN the competency is marked `llm_parse_error` with `score = NULL`, `valid = false`
- AND no queue retry is dispatched for this competency
- AND scoring continues to the next competency

#### Scenario: Truncated response is never mislabeled llm_parse_error

- GIVEN a provider response for competency PRS with `finish_reason = 'max_tokens'` and a body that would otherwise fail `json_decode`
- WHEN the engine processes the response
- THEN the competency's `unscorable_reason` is `llm_truncated`, never `llm_parse_error`

---

### Requirement: Fence and Leading/Trailing Prose Tolerance

`EvaluationParser` MUST strip a single leading/trailing markdown code fence (e.g.
` ```json ... ``` `) and any surrounding conversational prose before calling
`json_decode()`. This tolerance is NARROW and NAMED: it MUST NOT become a general
"locate JSON anywhere in the body" salvage routine. Any body that, after stripping at
most one leading and one trailing fence/prose wrapper, still fails `json_decode()` MUST
hard-fail exactly as before (see Requirement: LLM Parse Error).

#### Scenario: Markdown-fenced JSON parses successfully

- GIVEN a provider response body ` ```json\n{"indicators": [...]}\n``` ` for competency COL
- WHEN `EvaluationParser::parse()` runs
- THEN the fence is stripped, `json_decode()` succeeds, and COL scores normally

#### Scenario: Leading conversational prose is stripped

- GIVEN a response body "Here is the evaluation:\n{"indicators": [...]}"
- WHEN `EvaluationParser::parse()` runs
- THEN the leading prose is stripped and the JSON parses successfully

#### Scenario: A genuinely malformed body still hard-fails (negative cassette)

- GIVEN a response body with a stray trailing comma inside the JSON structure itself (not a fence/prose wrapper)
- WHEN `EvaluationParser::parse()` runs, including the fence/prose tolerance pass
- THEN `json_decode()` still fails and the competency is marked `llm_parse_error`
- AND no salvage attempt beyond one leading/trailing strip occurs

---

### Requirement: Truncation Detected From `finish_reason` Before Parsing

Before any parse attempt, the engine MUST inspect the provider response's
`finish_reason` (already carried by `LLMResponse::$finishReason` into
`ai_requests.finish_reason`, per `observability`). If `finish_reason` indicates
truncation (provider's max-output-tokens stop), the engine MUST short-circuit to a
distinct, truncation-specific failure class BEFORE attempting `json_decode()`. This
value MUST NOT collapse into `llm_parse_error`. `CompetencyResult.unscorable_reason`
MUST be `llm_truncated` for this class (superseding the Coverage Note's pinned
three-value enum — see Requirement: Unscorable Reason Enum Widens Beyond Three Values).

#### Scenario: Truncated response short-circuits before json_decode

- GIVEN a provider response with `finish_reason = 'max_tokens'`
- WHEN the engine processes the response
- THEN `unscorable_reason = 'llm_truncated'` is recorded WITHOUT ever calling `json_decode()` on the body
- AND the underlying `ai_requests` row records `finish_reason = 'max_tokens'` and a truncation-specific `failure_reason` (see `observability`)

#### Scenario: A non-truncated finish_reason proceeds to normal parsing

- GIVEN a provider response with `finish_reason = 'end_turn'`
- WHEN the engine processes the response
- THEN parsing proceeds normally (fence/prose tolerance, then `json_decode()`)

---

### Requirement: Truncation-Only Retry At An Enlarged Budget

When a competency's scoring call is short-circuited as truncated (see Requirement:
Truncation Detected From `finish_reason` Before Parsing), the engine MUST retry that
ONE call exactly once, at a configurably enlarged `max_tokens` budget (doubled by
default, config-driven), before finalizing the competency as unscorable. The retry
attempt MUST produce its OWN `ai_requests` row (never reuse or update the first
attempt's row) — every call is billed and every call is logged. This retry applies
ONLY to the truncation class: fence/prose failures, indicator count mismatch,
illegal scores, and non-verbatim excerpts remain non-retryable exactly as before (D4
FIX-9 stands for every class it already correctly covers).

This retry is a queue-job-internal, same-competency, same-interview retry of one LLM
call. It is NOT the domain-level candidate retry (RT-B, Requirement: Retry — Fast-Follow
Work Unit) — RT-B re-interviews the candidate and is untouched by this requirement.

#### Scenario: A truncated call retries once at double the budget and succeeds

- GIVEN competency PRS truncates at `max_tokens = 2048`
- WHEN the engine retries with `max_tokens = 4096`
- AND the retried call returns `finish_reason = 'end_turn'` with valid JSON
- THEN PRS scores normally from the retried response
- AND TWO `ai_requests` rows exist for PRS: the failed truncated attempt and the successful retry

#### Scenario: A retry that also truncates finalizes as unscorable, no second retry

- GIVEN competency PRS truncates on the first attempt
- WHEN the retry at the enlarged budget ALSO returns `finish_reason = 'max_tokens'`
- THEN PRS is finalized with `unscorable_reason = 'llm_truncated'`
- AND no third attempt is made (the cap is exactly one retry)
- AND TWO `ai_requests` rows exist for PRS, both marked `success = false`

#### Scenario: A fence/prose failure is never retried at an enlarged budget

- GIVEN competency STG fails with a genuinely malformed body (`llm_parse_error`) and `finish_reason = 'end_turn'` (not truncated)
- WHEN the engine handles the failure
- THEN no enlarged-budget retry is attempted for STG
- AND exactly ONE `ai_requests` row exists for STG

---

### Requirement: Per-Indicator Validation-Failure Isolation

`ScoreEvaluationJob`'s per-competency validation MUST catch validation failures at the
INDICATOR level, not with a single `try`/catch spanning every indicator DTO in the
competency. An indicator that fails validation (illegal score, or non-verbatim excerpt)
MUST be persisted as `IndicatorScore.score = -1` with a reason (see Requirement: Indicator
Validation-Failure Reason Vocabulary), while sibling indicators that validated cleanly
in the SAME competency, whether validated before or after the failing one in processing
order, MUST retain their own scores. The competency's mean and reliability are then
computed over whatever the isolated set produces — no formula changes (see
`scoring-model`'s Validation-Failure Reason Is Excluded From Every Scoring Formula
requirement). Competency-envelope failures (parse, truncation, indicator count
mismatch) are UNAFFECTED by this requirement: there are no per-indicator DTOs to
isolate when the envelope itself did not parse.

#### Scenario: One unverifiable excerpt out of three leaves two indicators scored

- GIVEN competency COL has 3 indicators; indicators 1 and 3 validate cleanly with scores 5 and 3; indicator 2's excerpt is not verbatim
- WHEN `scoreCompetency()` runs
- THEN indicator 2 persists as `score = -1`, `reason = 'excerpt_unverifiable'`
- AND indicators 1 and 3 persist their own scores
- AND COL's `reliability` = 2/3 ≈ 0.667, NOT 0 — COL is not discarded

#### Scenario: A failing indicator earlier in processing order does not poison later ones

- GIVEN competency DRV has 3 indicators; indicator 1 has an illegal score; indicators 2 and 3 have not yet been processed
- WHEN `scoreCompetency()` processes indicators in order
- THEN indicator 1 persists as `score = -1, reason = 'score_illegal'`
- AND indicators 2 and 3 are still evaluated and persist normally if they validate

### Requirement: Indicator Validation-Failure Reason Vocabulary

Every `IndicatorScore` MUST carry a nullable `reason` attribute distinguishing WHY a
`-1` score exists, from exactly three values: `model_declared` (the LLM itself
returned `-1` — no assessable evidence), `excerpt_unverifiable` (the LLM claimed
evidence that failed the verbatim-substring check), and `score_illegal` (the LLM
returned a value outside `{1,2,3,4,5,-1}`). The column is nullable (null when
`score != -1` is not applicable, or for pre-migration rows) and UNCONSTRAINED — no
Postgres CHECK constraint — so the vocabulary MAY extend later without a migration.
`reason` is METADATA ONLY: no scoring formula (`MeanCalculator`,
`AssessableFractionReliability`, `CompletionGate`) MAY read it (see `scoring-model`).

#### Scenario: The three reasons are each independently producible

- GIVEN three indicators in one competency: one the LLM declares `-1`, one with an unverifiable excerpt, one with an illegal score
- WHEN validation runs
- THEN the three `IndicatorScore` rows carry `reason` values `model_declared`, `excerpt_unverifiable`, and `score_illegal` respectively, all with `score = -1`

#### Scenario: A cleanly-assessed indicator carries a null reason

- GIVEN an indicator that validates with a legal score in `{1,2,3,4,5}`
- WHEN it is persisted
- THEN `IndicatorScore.reason` is `null`

### Requirement: Unscorable Reason Enum Widens Beyond Three Values

`CompetencyResult.unscorable_reason` MUST accept a fourth value, `llm_truncated`, in
addition to the three already in force (`anchor_translation_missing`, `role_no_bars`,
`llm_parse_error`). This requirement SUPERSEDES the scoring-engine spec's Coverage
Note text pinning the enum at exactly three values; that note MUST be updated to
reflect four values when this delta is merged, and the widening MUST NOT be read as a
regression against the three-value pin. The column remains a plain string with no
Postgres CHECK constraint, so this widening is schema-safe.

#### Scenario: llm_truncated is a legal, distinct unscorable_reason value

- GIVEN a competency finalized as truncated after the retry (see Requirement:
  Truncation-Only Retry At An Enlarged Budget)
- WHEN `CompetencyResult.unscorable_reason` is read
- THEN it equals `llm_truncated`, distinguishable from `llm_parse_error`,
  `anchor_translation_missing`, and `role_no_bars`
