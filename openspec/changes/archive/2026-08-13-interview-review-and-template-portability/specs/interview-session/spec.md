# Delta: interview-session — cost estimation inputs

## ADDED Requirements

### Requirement: Session cost is derived from stored timings, not recorded

The system MUST derive an avatar-provider cost estimate for a session from its
`started_at`/`ended_at` duration and a configured per-provider rate, with the
rates overridable by environment without a code change.

The estimate MUST NOT be persisted on the session. Rates change, and a stored
figure computed under an old rate becomes a number nobody can reproduce or
explain; deriving it at read time keeps the calculation inspectable.

Neither supported provider exposes a per-session billed amount through an API,
so the value MUST be treated and labelled as an estimate everywhere it surfaces.

#### Scenario: Cost follows the configured rate

- GIVEN a session of known duration and a configured provider rate
- WHEN its review is read
- THEN the returned estimate equals duration × rate for that provider

#### Scenario: An unfinished session has no cost estimate

- GIVEN a session with no `ended_at`
- WHEN its review is read
- THEN the estimate is absent rather than computed from a partial duration
