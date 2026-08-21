# Release Note — `progress` webhook: `question_index` value correction

**Change:** `interview-question-index-offset`
**Deploy timestamp:** to be filled in by the operator at the moment code + migration
ship together (D2 — they must not be separated).

## 1. The field

`progress` webhook → `data.competencies[].answers[].question_index`.

## 2. The change

The value now equals the competency's 0-based `position` in the project's
configured order. Every competency's value rises by one; the first competency's
entry previously read `-1` and now reads `0`. Type, shape, field names and
ordering are unchanged — this is a value-semantics correction, not a schema
change.

## 3. Applies to historical participants too

A `progress` payload assembled **after** the deploy carries the corrected value
even for a participant whose earlier deliveries carried the old one. The two are
not comparable across the deploy boundary — do not diff a pre-deploy delivery
against a post-deploy one and interpret the difference as new activity.

## 4. `payload.version` does NOT move

The ratified versioning rule bumps `payload.version` on any breaking payload
**shape** change. This is a value-semantics change with no shape change, so the
version is deliberately not bumped — bumping it would falsely signal a shape
change to every integrator of both webhook event types (`progress` and
`evaluation`). This release note is therefore the only signal of this change;
integrators are not able to detect it from the payload envelope itself.

## 5. Required integrator action

Remove any handling that special-cases `question_index = -1`, or that adds `+1`
to a `question_index` value to recover a 1-based question number. Both are no
longer necessary and will misinterpret data after this deploy — the field
already equals the competency's position; the historic negative and off-by-one
values are gone.

---

## Background (for context, not required reading for integrators)

`interview_sessions.question_index` was persisted as `project_competencies.position
- 1`, but `position` is 0-based at every writer, so the first competency of every
project stored `-1`. This was a defect in the API's internal reader, not in the
webhook assembler (`ProgressPayloadAssembler` required no code change — it emits
the column as stored). A backfill migration recomputed every previously-persisted
`question_index` from the authoritative `project_competencies.position` (never a
blanket arithmetic shift, which would have corrupted the sessions that already
held the correct value). See `openspec/changes/interview-question-index-offset/`
for the full design record.

**Open question this note exists to close, per the design's proposal round:**
*Does any live integrator consume `question_index` from the `progress` webhook?*
This was unanswerable from the repository alone; it is a pre-deploy verification
step (tasks.md Phase 7), and this release note is the artifact to distribute to
any integrator identified as consuming the field.
