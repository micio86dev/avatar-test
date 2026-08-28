# Delta for Observability & Analytics

## ADDED Requirements

### Requirement: Conversation LLM usage is an append-only, one-row-per-session aggregate carrying a rate-card snapshot

`interview_session_llm_usage` MUST carry a UNIQUE `interview_session_id` (the
idempotency guard for a double `/end`), `created_at` only (no `updated_at`),
and a `rate_card` jsonb snapshot of the rates used at write time, so a later
registry price edit MUST NOT retroactively change a historical row's cost. An
architecture guard MUST fail the build if business logic updates or deletes a
row.

The row MUST be written **only** when `llm_binding_status === 'applied'` for
that session — a session that ran on the vendor default (`unbound`) or on a
binding that could not be applied (`degraded`) MUST produce no usage row,
because charging Gemini rates for a conversation that did not run on Gemini
would be confidently wrong.

`interview_session_llm_usage` MUST NOT be added to `PurgeExpiredDataCommand`.
It is a cost aggregate with no candidate-derived subject matter, and cost
history MUST survive the transcript retention purge.

#### Scenario: Exactly one usage row is written per applied session

- GIVEN a session with `llm_binding_status = 'applied'`
- WHEN `/end` completes
- THEN exactly one `interview_session_llm_usage` row exists for that session

#### Scenario: A double /end does not produce a second row

- GIVEN a usage row already exists for a session
- WHEN `/end` is called again for the same session
- THEN no second `interview_session_llm_usage` row is created

#### Scenario: An unbound or degraded session writes no usage row

- GIVEN a session with `llm_binding_status` of `unbound` or `degraded`
- WHEN `/end` completes
- THEN no `interview_session_llm_usage` row is written for that session

#### Scenario: A later registry price edit does not rewrite a historical row's cost

- GIVEN a usage row written with a given `rate_card` snapshot
- WHEN the referenced model's rate in `llm_models` is subsequently changed
- THEN the stored row's `rate_card` and `estimated_cost_usd` remain unchanged

#### Scenario: Mutating a usage row fails the build

- WHEN business logic attempts to update or delete an `interview_session_llm_usage` row
- THEN an architecture test fails

#### Scenario: A usage row survives the transcript retention purge

- GIVEN a usage row referencing a session whose transcript has passed its retention window
- WHEN `PurgeExpiredDataCommand` runs
- THEN the transcript's utterances are purged and the usage row still exists unchanged

### Requirement: Actual token usage is a distinct, permanently-nullable fact from the estimate in managed mode

`actual_input_tokens`, `actual_output_tokens`, and `actual_cost_usd` on
`interview_session_llm_usage` MUST ship NULL for every row written while the
conversation ran in `managed` mode, because neither provider reports token
usage back to BEAI in that mode. These columns exist unmodified so a future
mode that receives real provider `usage` objects can populate them with no
schema or read-contract change.

#### Scenario: Every managed-mode usage row has null actual values

- GIVEN a usage row written for a session whose binding ran in `managed` mode
- WHEN the row is inspected
- THEN `actual_input_tokens`, `actual_output_tokens`, and `actual_cost_usd` are all NULL
