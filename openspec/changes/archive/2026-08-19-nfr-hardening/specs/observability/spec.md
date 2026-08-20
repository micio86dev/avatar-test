# Delta: observability — `ai_requests` conformance

## MODIFIED Requirements

### Requirement: AI Request Logging

Every call to an LLM provider MUST produce exactly one `ai_requests` row,
**whether or not the call's result is usable**, and that row MUST survive a
rollback of the work the call was made for.

Two properties, and they are separate. The current implementation satisfies
neither, and each failure loses money silently.

**1. Logging is failure-path inclusive.**

A provider call that returns unparseable JSON, violates the indicator contract,
or produces a non-verbatim excerpt has still been **made and billed**. The
scoring job today returns early on those paths, before any row is written, so
the spend leaves no trace. A row MUST be written for them, carrying
`success = false` and a `failure_reason`.

`failure_reason` records why the RESULT was unusable, never the raw provider
payload — an error string can echo prompt content, and this table is read by an
org-scoped cost dashboard.

**2. Logging is transaction-independent.**

The row MUST NOT be written inside the transaction that persists the scoring
results. A provider call is an external, irreversible, billed event; the results
are local and revocable. Wrapping the first in the second means any later
failure in that transaction rolls back the record of money already spent — the
database ends up disagreeing with the invoice, and it disagrees in the direction
that hides cost.

Write the row in its own committed statement, before or after the results
transaction, never within it.

**Field set.** In addition to the shipped columns, the table MUST carry:

| Column | Purpose |
|---|---|
| `provider` | Which vendor was billed. Nullable-free: unattributable spend is not a cost record. |
| `estimated_cost_usd` | Derived at write time from the model's rate. Stored, not computed on read, so a later rate change cannot silently rewrite history. |
| `success` | Whether the result was usable. Distinct from "the HTTP call returned 200". |
| `failure_reason` | Machine key, null when `success` is true. Never a raw payload. |

`estimated_cost_usd` is an ESTIMATE and is named so. It is not an invoice, it is
not authoritative for billing, and the dashboard reading it MUST present it as
an estimate.

**Append-only.** `ai_requests` has no `updated_at` and MUST NOT be updated by
business logic. A cost record that can be edited is not a cost record.

#### Scenario: A billed call whose result cannot be parsed is still recorded

- GIVEN a provider call that returns 200 with a body that fails JSON parsing
- WHEN the scoring job handles the failure
- THEN one `ai_requests` row exists for that competency
- AND `success` is false
- AND `failure_reason` identifies the failure class
- AND the row contains no fragment of the provider payload

#### Scenario: A rolled-back scoring transaction does not erase the spend

- GIVEN a provider call that succeeded and was billed
- AND the transaction persisting the competency results subsequently fails
- WHEN the transaction rolls back
- THEN the `ai_requests` row is still present

This is the property the current code most clearly violates, and the one with
the largest blast radius: it under-reports cost precisely when something else
went wrong, which is exactly when spend tends to spike.

#### Scenario: Every recorded call is attributable

- WHEN an `ai_requests` row is written
- THEN `provider`, `model`, `organization_id` and `estimated_cost_usd` are all
  populated

#### Scenario: The table rejects mutation

- WHEN business logic attempts to update an existing `ai_requests` row
- THEN an architecture test fails the build

Enforced the same way the append-only discipline is enforced elsewhere: by a
guard, not by a convention.
