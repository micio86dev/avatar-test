# Delta for Interview Conversation

## MODIFIED Requirements

### Requirement: BARS Indicator Loading — BarsIndicatorLoader

`BarsIndicatorLoader` MUST be the SINGLE shared implementation of
role-and-competency-scoped BARS indicator lookup, consumed by BOTH the
conversation (C8) prompt composer and the scoring (C9) `ScoreEvaluationJob`.
The prior RV-2 carve-out — permitting C9 to keep an independent,
competency-only inline query — is REVERSED: that duplicated, unscoped query
was the root cause of cross-role indicator contamination in scoring. The
loader MUST additionally support the `potential` assessment type via an
explicit `whereNull('role_id')` branch when no role is pinned.

The loader MUST prevent cross-role indicator contamination: indicators
belonging to the same competency code but a different role MUST NOT be
returned.
(Previously: C9's inline competency-only query was explicitly carved out as
untouched, non-refactorable code (RV-2), and the loader had no
`potential`/null-role branch.)

#### Scenario: Indicators filtered by both role and competency

- GIVEN competency COL exists for roles FLL (3 indicators) and MLL (2 different indicators)
- WHEN `BarsIndicatorLoader::forRoleCompetency(role_id: FLL, competency_id: COL)` is called
- THEN only the 3 FLL-COL indicators are returned; no MLL-COL indicators appear in the result

#### Scenario: Cross-role contamination is impossible

- GIVEN roles FLL and MLL share competency code COL with disjoint indicator sets
- WHEN `BarsIndicatorLoader` is called for each role independently
- THEN the two returned indicator sets are disjoint; no indicator from MLL appears in the FLL result and vice versa

#### Scenario: C9 scoring consumes the same loader as C8 conversation

- GIVEN `ScoreEvaluationJob` needs indicators for a role×competency pair
- WHEN it requests them
- THEN it calls the shared `BarsIndicatorLoader`, not an independent inline query
- AND the result is identical to what C8's prompt composer would receive for the same pair

#### Scenario: Null-role branch serves potential competencies

- GIVEN competency MTG has 3 indicators with `role_id = null`
- WHEN `BarsIndicatorLoader` is called with no role (potential path)
- THEN it issues `whereNull('role_id')`, not `where('role_id', null)`, and returns the 3 MTG indicators
