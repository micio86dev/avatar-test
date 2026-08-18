# Delta for scoring-engine

## MODIFIED Requirements

### Requirement: Missing Catalog Data — Skip and Flag

If a role has no BARS anchors for a competency (e.g. a future role with no
`bars/{ROLE}.json` yet, or a competency absent from an existing role's BARS
file), the engine MUST skip that competency and flag it with reason
`role_no_bars`. The engine MUST NOT crash or throw an unhandled exception.
The flag is visible in the Evaluation result for observability. An
unscorable competency (`role_no_bars`) counts against the 90% gate (see
Completion Gate requirement for the full policy).
(Previously: the illustrative example and its scenario named SRX as the
missing-BARS role — `bars/SRX.json` did not exist. After
`bars-catalogue-completion`, all 83 declared role×competency pairs,
including all of SRX, have anchors, so `role_no_bars` is a defensive-only
path with no real-catalog occurrence today; the example and scenario are
restated against a fixture.)

#### Scenario: Role with no BARS anchors (fixture) → skipped and flagged

- GIVEN a project uses a role×competency pair with no BARS anchors in the
  catalog (test fixture — post-completion, no real declared role×competency
  pair lacks anchors)
- WHEN the engine processes that project's competencies
- THEN the affected competency is skipped, flagged `role_no_bars`, and no
  LLM call is made
- AND no `ai_requests` row is created for the skipped competency
