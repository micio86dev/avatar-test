# Delta for Data Retention

## ADDED Requirements

### Requirement: An Audit Row Never Outlives the Indicator It Judges

`indicator_score_audits.indicator_score_id` MUST be `cascadeOnDelete`.
Whenever an `IndicatorScore` row is deleted — by this capability's own purge
mechanism, by a future retention extension, or by any other deletion path —
its associated `indicator_score_audits` rows MUST be deleted as part of the
same database-enforced cascade, never left dangling and never requiring a
separate purge step to notice them.

#### Scenario: Deleting an IndicatorScore deletes its audit rows

- GIVEN an `IndicatorScore` with one or more `indicator_score_audits` rows
  pointing at it
- WHEN that `IndicatorScore` row is deleted
- THEN every `indicator_score_audits` row referencing it is also deleted
- AND no audit row survives its subject

### Requirement: Audit Rows Carry No Candidate Personal Data of Their Own

An `indicator_score_audits` row MUST store only a probability and a machine
reason code — never free text, never a copy of an excerpt, never any
candidate-identifying value. Because it carries no personal data of its own,
this capability MUST NOT add `indicator_score_audits` or
`indicator_score_audit_runs` to the retention purge's independent artifact
inventory (the `snapshot`/`transcript`/`webhook_payload`/`participant_pii`
classes) — their retention lifecycle is governed entirely by the cascade
from `indicator_scores`, not by a class this purge command tracks and
redacts on its own.

#### Scenario: An audit row contains no personal data to purge independently

- GIVEN any `indicator_score_audits` row
- WHEN its columns are inspected
- THEN none of them contain free text, a copied excerpt, or any value that
  identifies a candidate

#### Scenario: The purge command's artifact inventory is unchanged by this capability

- GIVEN the retention purge command's configured artifact classes
- WHEN this capability lands
- THEN `snapshot`, `transcript`, `webhook_payload`, and `participant_pii`
  remain the complete set — no audit-related class is added
