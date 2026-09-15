# Delta for Project Configuration

## ADDED Requirements

### Requirement: Project Questions Layer

A `project_questions` table MUST exist, org+project scoped, with:
`competency_id` (FK `restrictOnDelete`), `text` (JSON locale map `{en,it}`),
`position` (int), soft deletes, and a partial unique index on
`(project_id, competency_id, position) WHERE deleted_at IS NULL`. CRUD is
exposed via index/store/update/reorder/destroy endpoints, RBAC-gated
identically to the `projects` resource.

The per-competency count MUST be validated against
`PlatformSettings::maxQuestionsPerCompetency()` (default
`{standard: 1, potential: 4}`) as a **maximum only** — zero questions for a
competency is always legal, at any assessment type.

#### Scenario: A potential project is savable with zero questions for a competency

- GIVEN a `potential` project competency with zero `project_questions` rows
- WHEN the project is saved
- THEN the save succeeds — zero is legal, the cap is a ceiling not a floor

#### Scenario: Exceeding the cap is rejected

- GIVEN a `potential` competency already has 4 questions (the default max)
- WHEN a 5th is submitted
- THEN the request is rejected with HTTP 422

### Requirement: Catalogue Defaults Auto-Fill On Competency Selection

Every time an operator selects competencies on a project — at creation or on
a later update, while the competency set is still mutable — the system MUST
copy the catalogue's default questions (see `catalogue-authoring`) for each
**newly selected** competency into `project_questions`, in the defaults'
authored order. A competency already carrying `project_questions` rows
(including soft-deleted, restorable rows — see below) MUST NOT be re-copied.
A catalogue default whose competency is outside the project's competency set
is never copied.

#### Scenario: Selecting a new competency copies its defaults

- GIVEN competency COL has 2 catalogue default questions
- WHEN an operator adds COL to a project's competency set
- THEN 2 `project_questions` rows are created for COL, matching the
  defaults' text and order

#### Scenario: A competency with no catalogue defaults yields zero rows

- GIVEN competency STG has zero catalogue default questions
- WHEN STG is selected on a project
- THEN zero `project_questions` rows are created for STG — this is not an
  error

#### Scenario: Re-saving an unchanged competency set does not duplicate rows

- GIVEN a project already has COL selected with its defaults copied
- WHEN the project is saved again with the same competency set
- THEN no additional `project_questions` rows are created for COL

### Requirement: A Catalogue Default Is Copied As A Snapshot; It Never Propagates

**RATIFIED by the product owner:** "in quel caso restano ferme le domande
sui progetti, non si aggiornano."

When a catalogue default question is copied into `project_questions` (on
competency selection — see above), that copy is a SNAPSHOT, frozen at the
moment of copy. A LATER edit to the catalogue default MUST NOT reach any
project that already has a copy — not an operator-modified row, and not an
untouched one either. A catalogue edit affects only projects that select
that competency AFTER the edit; every project that already selected it
keeps exactly the text it received at copy time, forever.

This is the SAME principle `CLAUDE.md` ruling 3 already ratifies for
`framework_version`: pinned at project creation, never retargeted by a later
catalogue revision. The copy made at competency selection is that same kind
of pin, at the question level instead of the anchor level, and a snapshot
that silently changes underneath a configured project is exactly what
ruling 3 exists to prevent. One rule now governs every catalogue write: it
never reaches a project that already exists.

**This has no propagation mechanism, by design — not a deferred one.**
There is no "find the untouched copies" query at edit time, no background
job, and no ordering hazard between a superadmin catalogue edit and a
concurrent project configuration, because a catalogue edit never writes to
`project_questions` at all. Editing a default is scoped entirely to the
catalogue's own draft revision (see `catalogue-authoring`); it has no
side-effect on any project.

The provenance flag introduced by this requirement's sibling copy-tracking
still exists, but it carries exactly two jobs, both already specified above:
(1) the auto-fill rule never overwrites a row flagged operator-modified, and
(2) restoring a deselected-then-reselected competency returns the operator's
own rewritten row, never a fresh default. Provenance carries NEITHER
propagation NOR a "should this follow the catalogue" decision — there is no
third job, because there is nothing left for a flag to gate once the
catalogue never reaches back into a project's copies at all.

#### Scenario: An untouched copy does not change when the catalogue default changes

- GIVEN a project's copy of a default has never been edited by an operator
- WHEN the superadmin later changes that default's text in the catalogue
- THEN the project's copy keeps the text it had at copy time, unchanged —
  no read, write, or comparison against the project's copy occurs as a
  result of the catalogue edit

#### Scenario: An operator-modified copy is equally unaffected

- GIVEN a project's copy of a default has been rewritten by an operator
- WHEN the superadmin later changes that same default's text in the
  catalogue
- THEN the project's copy still keeps the operator's rewritten text —
  provenance state does not change which projects a catalogue edit reaches;
  it reaches none

#### Scenario: A catalogue edit reaches only projects that select the competency afterward

- GIVEN a superadmin edits a competency's default question text
- WHEN a DIFFERENT project selects that competency for the first time,
  AFTER the edit
- THEN that project's new copy carries the edited text — the edit is
  visible only to selections made after it, never to selections made before

#### Scenario: The first operator edit sets the provenance flag

- GIVEN an untouched copy of a catalogue default
- WHEN an operator edits its text
- THEN the row's provenance flag is now "operator-modified"

### Requirement: Deselecting A Competency Soft-Deletes Its Questions; Reselecting Restores Them

Deselecting a competency MUST soft-delete its `project_questions` rows.
Reselecting the SAME competency later MUST restore exactly those rows —
including their provenance flag and any operator-rewritten text — and MUST
NOT re-copy the catalogue defaults over them.

#### Scenario: Reselection restores the operator's own edited text

- GIVEN a competency's questions were operator-edited, then the competency
  was deselected (soft-deleted)
- WHEN the operator reselects that competency
- THEN the same rows are restored with the operator's edited text — the
  catalogue defaults are NOT copied again

#### Scenario: Reselection restores an untouched copy without re-copying

- GIVEN a competency's questions were never edited, then deselected
- WHEN the operator reselects that competency
- THEN the same (untouched) rows are restored, not a fresh copy of the
  current catalogue defaults

### Requirement: Automation Never Overwrites An Operator-Modified Row

No automated write path — auto-fill on selection, or restore on
reselection — MAY overwrite a `project_questions` row whose provenance flag
indicates operator modification.

#### Scenario: Restore never re-copies over an operator-modified row

- GIVEN a restored row's provenance flag is "operator-modified"
- WHEN the same reselection event runs
- THEN the row's text is exactly what the operator last saved — never
  replaced by the catalogue default's current text

### Requirement: A Single Interviewability Predicate Gates Every Interview Entry Point

**RATIFIED by the product owner:** "tramite SSO bisogna applicare la stessa
logica, l'utente non può fare interviste su progetti che non sono in stato
completato di configurazione con almeno 1 domanda per ogni competenza."

A project IS INTERVIEWABLE only while every currently selected competency
has at least one LIVE (non-soft-deleted) `project_questions` row. This is a
property of the PROJECT, defined exactly once (e.g. `Project::isInterviewable()`
or an equivalent single service), and EVERY route capable of starting or
continuing an interview MUST consume that one definition — none may
reimplement its own check. Three independent checks that must agree is
three things that drift: this repo has already paid for that shape twice
(`AGENTS.md` living as a copy of `CLAUDE.md` instead of a symlink, and a
guard asserting an indicator count that disagreed with the spec and the
data). This requirement exists precisely so a fourth instance of that shape
does not ship.

The predicate is evaluated against current soft-delete state: a competency
deselected (its rows soft-deleted) is no longer a SELECTED competency and is
out of scope for the check entirely; only currently-selected competencies
with zero live rows make a project non-interviewable.

**Every entry point MUST consume the predicate:**

| Entry point | Route | Audience | Refusal behavior |
|---|---|---|---|
| Entry-link mint | `POST /api/entry-links`, `EntryLinkController::store` | Operator (authenticated, backoffice) | HTTP 422, machine-readable code `PROJECT_NOT_INTERVIEWABLE` — reaches someone who can fix it |
| SSO exchange | `GET /api/sso/exchange`, `SsoExchangeController::exchange` | Candidate (public, unauthenticated) | Refused **at the moment of exchange**, never a raw error — the candidate is redirected to the project's configured `error_redirect_url`, since they cannot fix a configuration problem |
| M2M enrolment | `POST /api/m2m/participants` and `POST /api/m2m/sso-link`, `App\Http\Controllers\M2m\ParticipantController::store` / `SsoLinkController::store` | Calling system (M2M API-key) | HTTP 422, machine-readable code `PROJECT_NOT_INTERVIEWABLE` — the earliest point the calling system can be told, strictly kinder than failing at the candidate's door |

**Timing — the check belongs at the moment of use, not only at mint.** A
project can become non-interviewable AFTER an entry link is minted or an SSO
token is issued but BEFORE the candidate arrives (a competency was
deselected, or its last live question was removed). Mint-time and use-time
are DISTINCT evaluations of the same predicate: minting an entry link or an
SSO token MUST check interviewability at that moment, and the SSO exchange
and any `/start` call for a competency not yet begun MUST check it again at
the moment of use — a token minted while interviewable is not a permanent
exemption.

**In-flight sessions are protected, not severed.** Once a competency
session has reached `in_corso`, a LATER configuration change that makes the
project non-interviewable MUST NOT retroactively fail, pause, or terminate
that session. The predicate gates the START of a new attempt (a fresh
`/start` for a competency with no prior session), never a session already
running. This choice is deliberate: a candidate mid-interview has no way to
know the operator changed the project underneath them, and severing them
converts a configuration mistake into a data-loss incident for a candidate
who did nothing wrong.

#### Scenario: Entry-link mint is refused for a non-interviewable project

- GIVEN a project with competencies [PRS, COL] selected, PRS has 1 live
  question, COL has zero live questions
- WHEN `POST /api/entry-links` is called for that project
- THEN the response is HTTP 422 with code `PROJECT_NOT_INTERVIEWABLE`
- AND no entry link is minted

#### Scenario: SSO exchange is refused for a non-interviewable project and routes to the error redirect

- GIVEN a project is non-interviewable and has a configured `error_redirect_url`
- WHEN a candidate's `GET /api/sso/exchange` request resolves to that project
- THEN the candidate is redirected to `error_redirect_url`, never shown a raw
  error page
- AND no `InterviewSession` or participant progress is created

#### Scenario: M2M enrolment is refused at the API boundary, before any candidate exists

- GIVEN a project is non-interviewable
- WHEN a calling system calls `POST /api/m2m/participants` (or subsequently
  `POST /api/m2m/sso-link`) for that project
- THEN the response is HTTP 422 with code `PROJECT_NOT_INTERVIEWABLE`
- AND no participant row and no SSO link are created — the calling system
  learns this before any candidate is ever invited

#### Scenario: A project that becomes non-interviewable after mint is still refused at use

- GIVEN an entry link (or SSO token) was minted while the project was
  interviewable
- AND the operator subsequently deselects a competency, or deletes its last
  live question, making the project non-interviewable
- WHEN the candidate then uses that link/token
- THEN the use-time check refuses it exactly as if it had never been
  interviewable — the mint-time check is not treated as a standing exemption

#### Scenario: An already in_corso participant is not severed by a later configuration change

- GIVEN a candidate has an `in_corso` competency session already underway
- WHEN the operator makes the project non-interviewable (deselects another
  competency, or empties a different competency's questions)
- THEN the candidate's already-running session continues uninterrupted
- AND the predicate only blocks a NEW session start, not the one in progress

#### Scenario: Minting succeeds once the project is interviewable

- GIVEN the same project, with a question then added back to COL
- WHEN `POST /api/entry-links` is called again
- THEN the response is HTTP 201 and an entry link is minted

#### Scenario: A deselected competency's soft-deleted questions do not count against interviewability

- GIVEN a project previously had competency STG selected with questions,
  then STG was deselected (its rows soft-deleted) and is no longer in the
  project's competency set
- WHEN interviewability is evaluated for any of the three entry points
- THEN STG's soft-deleted rows are not evaluated at all — only currently
  selected competencies are checked

#### Scenario: Interviewability reflects soft-delete state, not raw row count

- GIVEN a competency has 2 `project_questions` rows, both soft-deleted, and
  the competency is still selected on the project
- WHEN the predicate is evaluated
- THEN the competency counts as having zero LIVE questions, and the project
  is non-interviewable

## MODIFIED Requirements

### Requirement: assessment_type Invariants

Assessment type MUST be one of `standard` or `potential`. The invariants
below MUST be enforced at both the FormRequest validation layer and the
model guard layer.

**standard** invariants:
- `role_code` MUST be present and MUST be one of `{ICO, FLL, MLL, BUL, SRX}`.
- All competencies in `project_competencies` MUST have `type = 'standard'`.
- Every competency in `project_competencies` MUST exist in
  `framework_role_competency` for the given `role_code` (subset constraint).
- No `type = 'potential'` competency MAY appear.

**potential** invariants:
- `role_code` MUST be `null`.
- All competencies in `project_competencies` MUST have `type = 'potential'`
  and their code MUST be in `{MTG, LAT}`.
- No `type = 'standard'` competency MAY appear.

Mixing `standard` and `potential` competencies in a single project MUST be
rejected (HTTP 422).

Selecting or deselecting a competency, at any point the set is still
mutable, MUST trigger the catalogue-defaults auto-fill and
soft-delete/restore lifecycle described above; this applies uniformly to
`standard` and `potential` competency selection.

(Previously: silent on any question-related side effect of competency
selection — `project_questions` did not exist as a specified concept.)

#### Scenario: Valid standard project with correct role and subset

- GIVEN role_code = "ICO" and all competencies in `project_competencies` are
  standard and in ICO's framework_role_competency rows
- WHEN POST /api/projects is called
- THEN the response is HTTP 201

#### Scenario: standard project with invalid role_code is rejected

- GIVEN assessment_type = "standard" and role_code = "INVALID"
- WHEN POST /api/projects is called
- THEN the response is HTTP 422 with an error on `role_code`

#### Scenario: Valid potential project with MTG and LAT

- GIVEN assessment_type = "potential", role_code = null, competencies =
  [MTG, LAT] (both seeded)
- WHEN POST /api/projects is called
- THEN the response is HTTP 201

#### Scenario: Selecting a competency on project creation auto-fills its defaults

- GIVEN competency PRS has 1 catalogue default question
- WHEN POST /api/projects is called with PRS in the competency set
- THEN the created project has 1 `project_questions` row for PRS, copied
  from the default
