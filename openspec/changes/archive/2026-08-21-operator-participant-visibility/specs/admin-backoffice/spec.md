# Delta for Admin Backoffice

## ADDED Requirements

### Requirement: Participants List Project Column

`CandidateTable.vue` MUST render a project column, sourced from the
participant resource's project name, for every row.

#### Scenario: The list shows each row's project

- GIVEN participants from two different projects
- WHEN the participants list renders
- THEN each row displays its own project's name

### Requirement: Participant Detail Interview Status, Progress, Elapsed Time, And Cost

The participant detail view MUST render: the real lifecycle status as one of
the five domain values, never a completed/not-completed reduction; session
progress as `done / total`; total elapsed interview time; and the cost
estimate, visibly labeled as an estimate. These fields MUST be visible to any
operator authorized to view the participant — no additional role restriction
applies beyond existing RBAC.

A partial cost total (some sessions excluded because they yielded no
estimate) MUST state how many sessions contributed to the shown total. When
no session yields an estimate, no cost figure MUST be rendered, never `0`.

#### Scenario: Status renders as the real lifecycle value

- GIVEN a participant at `errore`
- WHEN the detail page renders
- THEN the status shown is `errore`, not a boolean or "not completed"
  reduction

#### Scenario: Progress renders as done over total

- GIVEN a participant with 6 of 15 project competencies attempted
- WHEN the detail page renders
- THEN it shows `6 / 15`

#### Scenario: Cost is visibly labeled an estimate

- WHEN the detail page renders any cost figure
- THEN the figure carries a visible "estimate" label

#### Scenario: A partial cost total states its coverage

- GIVEN the API reports 2 of 3 sessions contributed to the cost total
- WHEN the detail page renders the cost figure
- THEN it states that 2 of 3 sessions contributed

#### Scenario: Any authorized role sees these fields

- GIVEN an authenticated `viewer` who can already read this participant
- WHEN they open the detail page
- THEN status, progress, elapsed time, and cost estimate are all visible

### Requirement: Turn-by-Turn Transcript Panel With Partial Labelling

The participant detail view MUST offer a transcript panel showing turns
grouped by question, each turn attributed to its speaker (avatar or
candidate), covering both. When the API's partial marker indicates partial,
the panel MUST render a visible, unambiguous partial-data label; when it
indicates complete, no partial label MUST be shown. The panel MUST be
reachable for any status the API now permits (`in_corso`, `in_valutazione`,
`completato`, `errore`) and MUST NOT be rendered for `in_attesa`.

#### Scenario: Turns are grouped by question and attributed to speaker

- GIVEN a transcript response with sessions carrying avatar and candidate
  utterances
- WHEN the panel renders
- THEN turns are grouped by question
- AND each turn shows which speaker produced it

#### Scenario: A partial transcript is visibly labeled

- GIVEN the API marks the transcript partial
- WHEN the panel renders
- THEN a visible partial-data label is shown

#### Scenario: A complete transcript carries no partial label

- GIVEN the API marks the transcript complete
- WHEN the panel renders
- THEN no partial-data label appears

#### Scenario: The panel is unreachable at in_attesa

- GIVEN a participant at `in_attesa`
- WHEN the detail page renders
- THEN no transcript panel is offered

### Requirement: Client-Side Transcript Availability Mirror

`backoffice/app/utils/participant-lifecycle.ts`'s transcript-availability
check MUST return `true` for `in_corso` and `errore`, matching the server
gate, while its evaluation-availability check remains unchanged. The mirror
MUST NOT diverge from the server: any status the server now permits for a
scope MUST also be permitted by this client-side check for that scope.

(Previously: `in_corso` and `errore` both returned `false` for the transcript
scope.)

#### Scenario: in_corso permits transcript, not evaluation

- WHEN the mirror is evaluated for status `in_corso`
- THEN the transcript check returns `true`
- AND the evaluation check returns `false`

#### Scenario: errore permits transcript, not evaluation

- WHEN the mirror is evaluated for status `errore`
- THEN the transcript check returns `true`
- AND the evaluation check returns `false`

#### Scenario: in_attesa still denies transcript

- WHEN the mirror is evaluated for status `in_attesa`
- THEN the transcript check returns `false`
