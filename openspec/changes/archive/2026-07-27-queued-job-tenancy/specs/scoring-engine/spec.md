# Delta for Scoring Engine (queued-job-tenancy — C9 retrofit)

Modifies: `openspec/specs/scoring-engine/spec.md`

`ScoreEvaluationJob` writes four tenant-scoped rows per run (Evaluation,
AiRequest, CompetencyResult, IndicatorScore). This delta specifies that all
four MUST be stamped from the participant's own org, established per the
`tenancy` capability's *Queued-Job Tenant Context Establishment* requirement
— not from ambient resolver state.

---

## MODIFIED Requirements

### Requirement: Tenant Scoping

All reads and writes in the scoring pipeline MUST be scoped by `organization_id`.
Cross-tenant isolation MUST be enforced at the query layer (global `TenantScoped` scope).
A scoring job for org A MUST NOT read anchors, participants, sessions, or write evaluation
rows belonging to org B.

#### Scenario: Cross-tenant evaluation isolation

- GIVEN participant P_A in org A and participant P_B in org B exist
- WHEN `ScoreEvaluationJob` runs for P_A
- THEN all DB reads and writes are scoped to org A; org B data is never accessed

Write-side scoping MUST use tenant context re-derived from `P_A`'s own
`organization_id` at job execution time — never from the ambient
`TenantResolver` state left over from a prior request or job (see `tenancy`
capability). This applies to every tenant-scoped write the job performs:
the `Evaluation`, `AiRequest`, `CompetencyResult`, and `IndicatorScore` rows.
(Previously: stated the isolation goal without specifying how write-side org
context is established for a queued job; this closes the ambient-state gap
that let the job stamp a null or foreign org.)

#### Scenario: All four scoring writes stamped under the participant's org

- GIVEN `ScoreEvaluationJob` runs for participant P_A (org A)
- AND the ambient `TenantResolver` holds no org (post `Queue::before` reset)
  or a foreign org
- WHEN the job creates the `Evaluation`, `AiRequest`, `CompetencyResult`,
  and `IndicatorScore` rows
- THEN every created row's `organization_id` equals org A
- AND no row is created with a null or foreign `organization_id`
