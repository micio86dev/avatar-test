# Delta for Observability

## ADDED Requirements

### Requirement: Audit Token, Cost, and Latency Are a Separate Meter — Never Folded Into `ai_requests` or the Scoring-Cost Dashboard Metric

Every call to the `AuditJudge` implementation MUST have its token counts,
estimated cost, and latency recorded exclusively on
`indicator_score_audit_runs`. This meter MUST NOT be written into
`ai_requests`, and MUST NOT be summed, joined, or otherwise folded into any
metric `DashboardController` computes from `ai_requests` (including the
scoring AI-cost/token metrics). This mirrors the existing, separately
ratified refusal to fold `SessionCostEstimator`'s proctoring-cost meter into
the scoring-cost metric: two different vendors on different meters produce
one total with no owner.

A zero-cost `ai_requests` row MUST continue to mean exactly what it means
today (an anomaly worth surfacing) — this capability MUST NOT introduce any
row into `ai_requests` that could be mistaken for that anomaly.

#### Scenario: An audit run's cost never appears in the `ai_requests`-derived dashboard metric

- GIVEN an audit run that judged several indicators and recorded a non-zero
  `estimated_cost_usd` on its own run row
- WHEN the scoring AI-cost dashboard metric is computed from `ai_requests`
- THEN the audit run's cost is not included in that figure

#### Scenario: `ai_requests`' zero-cost anomaly signal is unaffected

- GIVEN the existing zero-cost-row anomaly detection reads `ai_requests`
- WHEN any number of audit runs complete
- THEN the set of `ai_requests` rows considered by that detection is
  unchanged — the audit introduces no new rows there
