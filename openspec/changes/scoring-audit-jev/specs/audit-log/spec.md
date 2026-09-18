# Delta for Audit Log

## ADDED Requirements

### Requirement: An Evaluation Audit Request Is Audited

Every accepted `POST /api/participants/{id}/evaluation/audit` request MUST
produce one `audit_logs` row with action `evaluation.audit_requested`,
naming the requesting admin as actor, the audited evaluation (or
participant) as subject, the organization, and a timestamp — subject to this
capability's existing redaction and append-only rules. A refused request
(non-admin, in-flight duplicate, cross-tenant, or no evaluation to audit)
MUST NOT produce an `evaluation.audit_requested` row, since no run was
actually created.

#### Scenario: An accepted audit request is recorded

- GIVEN an admin's audit request for participant P's evaluation is accepted
  and a run is dispatched
- WHEN the request completes
- THEN one `audit_logs` row exists with action `evaluation.audit_requested`,
  naming the admin as actor and the evaluation as subject

#### Scenario: A refused request writes no audit-requested row

- GIVEN an audit request is refused because a run for the same evaluation is
  already in flight
- WHEN the refusal is returned
- THEN no `evaluation.audit_requested` row is written for that request

#### Scenario: A failed audit-log write does not break the trigger request

- GIVEN the audit-log recorder will throw when writing the
  `evaluation.audit_requested` row
- WHEN an admin's otherwise-valid audit request is processed
- THEN the request still succeeds and the run is still dispatched
- AND the audit-log failure is logged, consistent with this capability's
  existing "recording never breaks the operation it records" rule
