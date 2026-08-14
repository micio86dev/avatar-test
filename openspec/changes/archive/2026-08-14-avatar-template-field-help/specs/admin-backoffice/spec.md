# Delta: admin-backoffice — avatar template field help

## ADDED Requirements

### Requirement: Every avatar template field explains itself

Each field in the avatar template form MUST render a one-line hint describing
what the setting does, and — where the value comes from a provider dashboard —
where to find it.

A form of 29 provider settings with labels alone is a form filled by copying the
previous value or by guessing. The setting names are the provider's vocabulary,
not the operator's.

The hint MUST be i18n-keyed like every other string, and MUST be carried by the
field spec rather than the template, so a field added server-side arrives with
its explanation instead of acquiring one later, if ever.

A field whose hint is missing MUST still render its control. Explanation is an
aid; losing it must never cost the operator the ability to configure.

#### Scenario: Each rendered field carries its hint

- WHEN an operator opens the avatar template form
- THEN every provider field shows its descriptive text under the control

#### Scenario: A field without a hint still works

- GIVEN a field spec carrying no hint key
- WHEN the form renders
- THEN the control appears without a hint and remains usable
