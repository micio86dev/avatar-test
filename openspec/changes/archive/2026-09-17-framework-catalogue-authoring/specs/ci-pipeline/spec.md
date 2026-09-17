# Delta for CI Pipeline

## ADDED Requirements

### Requirement: CI Catalogue Gates Govern The Baseline JSON Trees Only

The wrapper catalogue gate (`scripts/ci-guards.sh`) and its four control
files (`framework-{known-gaps,competency-gaps,crossrole-baseline,
locale-gaps}.txt`) MUST continue to assert invariants ONLY over the baseline
`docs/app_description/02-domain/framework/` / `api/database/framework/` JSON
trees. They MUST NOT be extended to query the database and MUST remain green,
unmodified, exactly as strict as before this change.

The equivalent invariants over runtime-written catalogue rows — exactly 3
indicators per published role×competency pair, `scale` keys exactly
`{1,3,5}`, non-blank `{en,it}` locale maps, 83 pairs, 85 anchored
competencies, no cross-role duplicate anchor text — are enforced separately,
at write time, by `catalogue-authoring`'s FormRequest validation and database
constraints, never by teaching this gate to read PostgreSQL.

#### Scenario: The wrapper gate stays green and unmodified

- GIVEN this change is applied
- WHEN `scripts/ci-guards.sh` runs against the unmodified baseline trees
- THEN it passes exactly as it did before this change, with no new
  database-reading step added to it

#### Scenario: A runtime-only invariant violation is caught by the DB twin, not this gate

- GIVEN a superadmin write via the catalogue API would produce a 4th
  indicator for a role×competency pair
- WHEN the write is attempted
- THEN `catalogue-authoring`'s FormRequest/DB-constraint layer rejects it
  with HTTP 422 — `scripts/ci-guards.sh` is never invoked and has no
  visibility into this rejection

#### Scenario: A revision export can refresh the baseline trees, but only by a human PR

- GIVEN a published revision exported to JSON via `catalogue-authoring`'s
  export command
- WHEN a human deliberately commits that export as an update to the baseline
  trees
- THEN `scripts/ci-guards.sh` evaluates the new trees exactly as it would any
  other baseline change — no auto-commit path exists
