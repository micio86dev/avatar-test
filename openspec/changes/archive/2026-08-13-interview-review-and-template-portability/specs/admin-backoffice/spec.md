# Delta: admin-backoffice — session review and template portability UI

## ADDED Requirements

### Requirement: Interview session review view

The backoffice MUST provide a per-session review reachable from the participant
detail, showing: the session's timing and duration, its provider and technical
refs, the integrity timeline with its risk score and band, the timed snapshot
strip, and the two cost estimates.

The review MUST be a view of its own, not a panel on the participant detail. A
participant has one session per competency; folding N proctoring timelines into
a page that already carries a lifecycle timeline, a transcript and a BARS report
makes all four harder to read.

Cost MUST be labelled as an estimate wherever it appears. No provider exposes a
per-session billed figure, and an operator who reads the number as an invoice
line will eventually reconcile it against a real bill and find a discrepancy
that was never a defect.

The risk band MUST NOT be rendered as a verdict on the candidate. It is an input
to an operator's judgement; the events that produced it MUST be listed so the
score can be disagreed with.

#### Scenario: A session review shows evidence, not a conclusion

- WHEN an operator opens a session review
- THEN the integrity events are listed individually with their times
- AND the risk score is shown alongside them, not in place of them

#### Scenario: Cost is presented as an estimate

- WHEN the review renders costs
- THEN each is labelled an estimate
- AND the avatar and LLM figures appear separately, never as one total

#### Scenario: A session with no integrity events reads as clean, not broken

- GIVEN a session that produced no events
- WHEN its review is opened
- THEN an explicit "no events recorded" state is shown, not an empty area

### Requirement: Avatar template export and import UI

The avatar templates view MUST offer export and import of the JSON document to
**admins only**. The controls MUST NOT render for operators or viewers — a
control that appears and then fails with 403 teaches the operator that the
product is broken rather than that they lack the right.

Import MUST report, per entry, what was created and what was refused and why.
A silent partial import leaves the operator believing a configuration is present
when it is not.

#### Scenario: Only admins see the controls

- GIVEN an authenticated operator
- WHEN they open the avatar templates view
- THEN neither the export nor the import control is rendered

#### Scenario: A refused entry is reported with its reason

- WHEN an import rejects an entry
- THEN the view names the entry and the reason
- AND states which entries, if any, were created
