# Delta for Webhooks Integration

## MODIFIED Requirements

### Requirement: progress payload — creation and advancement cases

The `progress` webhook payload MUST carry the `candidate_ref` verbatim, a project
reference, a `version` field, and a per-competency progress list. Each list entry
carries the competency `code`, the underlying interview session's live `status`
(`pending|in_corso|completed|timeout|skipped|error`), and an `answers` array.

Per the C7a domain model, ONE `interview_sessions` row represents ONE competency, not
one question — `question_index` on that row is a static competency-position ordinal,
not a per-question counter, and there is no per-question sub-resource. A competency
therefore contributes AT MOST ONE `answers` entry, `{question_index, answered_at}`,
present only once that competency's session has ended; before it ends, `answers` is
empty. **Per-question-level progress tracking within a single competency would require
a domain-model extension (e.g. a session-per-question model, or a sub-resource under
the existing session) and is explicitly OUT OF SCOPE for C10** — this requirement
describes competency-level granularity only, matching what C7a's `interview_sessions`
table actually records (verified: `App\Services\Webhooks\ProgressPayloadAssembler`
appends at most one `answers` entry per competency row).

`answers[].question_index` MUST equal `project_competencies.position` of that entry's
competency — the same corrected value `interview-session` now persists. This is a
DELIBERATE, disclosed contract change for an integrator-facing field: every
competency's value shifts by one, and the first competency's entry — previously
`-1` — now reads `0`. Permitted under the project's no-legacy-compatibility rule
(greenfield); disclosed here rather than shipped silently.
(Previously: `answers[].question_index` carried the value written to
`interview_sessions.question_index`, which was `position - 1` and therefore `-1`
for a project's first competency.)

For a newly created participant, ALL project competencies MUST be present in the list
with empty `answers`. For an advancement trigger (competency-session end), the payload
MUST reflect the current cumulative state across all competencies for that
participant: the just-ended competency shows its one `answers` entry; competencies not
yet ended show an empty list; competencies already ended by a PRIOR request continue to
show their own one entry.

#### Scenario: New-candidate progress payload — all competencies present, empty lists

- GIVEN a participant is created for a project with 3 competencies
- WHEN the participant-creation `progress` payload is assembled
- THEN all 3 competency codes are present, each with `status = "pending"` and an empty `answers` list

#### Scenario: Advancement progress payload reflects cumulative state

- GIVEN a participant has ended competency INN (`status = "completed"`) and has not started the remaining competencies
- WHEN a `progress` payload is assembled after the INN competency-session ends
- THEN INN shows `status = "completed"` and exactly ONE `answers` entry (`{question_index, answered_at}` for that session)
- AND every other, not-yet-ended competency shows its current live `status` and an empty `answers` list

#### Scenario: The first competency's answers entry carries question_index 0, not -1

- GIVEN a participant's FIRST competency (the one at `project_competencies.position = 0`)
  has just ended
- WHEN the `progress` payload is assembled for that advancement
- THEN that competency's `answers` entry carries `question_index = 0`, never `-1`
