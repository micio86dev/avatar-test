# Design: Repair the `question_index` Off-By-One

Store mode: hybrid. Engram mirror: `sdd/interview-question-index-offset/design`.
Inputs: `proposal.md`, `specs/interview-session/spec.md`, `specs/webhooks-integration/spec.md`.

## Technical Approach

Three characters of logic, one migration, and the removal of every sentence that
still teaches the defect.

1. **The reader stops subtracting** (D1). `question_index = position`, which is what
   `DemoWriter.php:404` has always written and what `TenancyTest.php:107` already asserts.
2. **The persisted column is recomputed from `project_competencies.position`, never
   shifted** (D2). This is the only risk-bearing element: production is **mixed**, so
   arithmetic on the existing value is guaranteed to corrupt the rows that are already right.
3. **The prose is corrected in lockstep** (D6, D7) — schema docblock, controller comments,
   test docblock — because this repo's own history is of a workaround comment outliving
   the defect it described.

**Scope is `api` only, verified, not assumed.** `frontend` no longer stores the field
(`useInterviewSession.ts:520`); `backoffice/app/components/organisms/TranscriptPanel.vue:35`
already renders `question_index + 1` and every backoffice fixture already uses `0`/`1` — the
post-fix values. The field's type and shape are unchanged, so no `openapi.json` cycle and no
wrapper cross-stack sync are triggered. One `api` PR + one wrapper pointer bump.

---

## D1 — Fix the reader; `position` stays 0-based

All four writers are 0-based. `project_competencies.position` is `unsignedInteger DEFAULT 0`
(`…200002_create_project_competencies_table.php:38`) — the column cannot hold the 1-based
values the subtraction assumes. `resolveNextCompetency()` emits `$row->position` verbatim.

| Option | Tradeoff | Verdict |
|---|---|---|
| Move `position` to 1-based | Two production writers, a live pivot, and every `orderBy('position')` reader, to repair one subtraction | Rejected |
| Leave the column, fix consumers | Adds a `+1` at four read sites and leaves `-1` persisted forever | Rejected |
| **Drop the `- 1`** | Half the codebase already holds the post-fix invariant | **Chosen** |

Selection order is unaffected: `question_index` is a label written onto the selected row, never
an input to selection. The correction is a monotonic relabelling, so every `orderBy('question_index')`
returns the identical sequence.

---

## D2 — THE CRUX: the backfill recomputes; it never shifts

A read-only join against production shows the dataset is **mixed today**:

| `question_index` | `position` | drift | sessions | written by |
|---|---|---|---|---|
| 0..4 | 0..4 | **0** | **29** | `DemoWriter.php:404` (never subtracted) |
| -1 | 0 | 1 | 6 | `InterviewController` |
| 0 | 1 | 1 | 1 | `InterviewController` |
| 1 | 2 | 1 | 1 | `InterviewController` |

| Option | What it does to the 37 rows | Verdict |
|---|---|---|
| `UPDATE … SET question_index = question_index + 1` | Repairs 8, **corrupts 29** — and corrupts them into values that are still plausible, so nothing downstream would ever raise | **Rejected — actively destructive** |
| Shift only `WHERE question_index < 0` | Repairs 6 of 8. The two rows at `(0,1)` and `(1,2)` are indistinguishable from correct rows by their own value alone; only the join can tell them apart | Rejected |
| Shift only rows written by the controller | There is no origin marker on the row. Provider-ref prefix heuristics (`DemoMarker::PREFIX`) are a guess dressed as a filter | Rejected |
| Leave the data, fix new writes only | Old sessions off by one, new ones not, and **nothing in the data to tell them apart later** | Rejected |
| **Recompute `question_index` from `pc.position` via join** | Correct for all 37 regardless of origin, and correct for any row shape not represented in today's sample | **Chosen** |

The choice does not rest on preference. Any arithmetic on the existing value must assume a
uniform provenance the table does not have; only the join reads the authoritative source.

```sql
UPDATE interview_sessions AS s
SET question_index = pc.position
FROM project_competencies AS pc
JOIN framework_competencies AS fc ON fc.id = pc.competency_id
WHERE pc.project_id = s.project_id
  AND fc.code       = s.competency_code
  AND s.question_index IS DISTINCT FROM pc.position;
```

**The join is unambiguous.** `framework_competencies.code` is globally `UNIQUE`
(`…111646_create_competencies_table.php:21`), so `fc.code = s.competency_code` resolves to
exactly one competency id, and `pc.project_id = s.project_id` pins it to one pivot row via
`UNIQUE(project_id, competency_id)`. At most one `position` per session. This is the same
join `ProgressPayloadAssembler:46-51` already performs at read time.

**Idempotency and non-destructiveness are one clause.** `IS DISTINCT FROM` restricts the
write to rows that would actually change, so an already-correct row is not in the UPDATE's
result set at all — it is untouched, not rewritten with the same value. The second run has an
empty result set by construction.

**Raw SQL, not Eloquent — two reasons, both load-bearing.** `InterviewSession` is
`TenantScoped`: a model-based update inside a migration runs with no ambient `TenantContext`
and would silently repair one tenant or none. And an Eloquent mass update stamps `updated_at`,
which would break the spec's byte-identical guarantee for the 29 correct rows. The migration
uses `DB::statement()` only. Unscoped by design, per the `error_count` backfill precedent
(`…120000_add_error_count_to_interview_sessions.php:44-47`): the invariant is per row, so a
tenant filter would leave exactly the rows it excluded broken.

**Reordering.** A project reordered since its sessions were created recomputes to the *current*
position. Accepted: every reader — the transcript serializer, both webhook assemblers, the
admin resources — already joins against current `position`, so this makes the row agree with
the surfaces that render it.

The backfill ships **in the same PR** as D1. A half-fixed dataset is worse than either state.

---

## D3 — A session whose competency is no longer attached is left alone, loudly

`ProjectController::update():164` calls a detaching `sync()`, so a session can outlive its
pivot row and the join can miss. This is not hypothetical — it is a named latent defect the
proposal keeps out of scope.

| Option | Tradeoff | Verdict |
|---|---|---|
| Write `0` | `0` means "first competency of this project". Writing it into a row whose competency has no position asserts a fact that is false and **unfalsifiable afterwards** — the evidence that it was a guess is gone | **Rejected** |
| Write `NULL` | The column is `NOT NULL`; making it nullable to express "unknown" is a schema change to carry a data defect | Rejected |
| Abort the migration | Blocks a deploy on a condition with no repair path inside this change — re-attaching a competency is a product decision, not a migration's | Rejected |
| **Leave untouched, report every affected id** | The row keeps the value it already had (no regression), and the residual is attributable rather than mysterious | **Chosen** |

The `UPDATE … FROM` leaves unmatched rows untouched by construction — no `WHERE` guard is
needed for correctness, only for disclosure. Before the UPDATE the migration counts unmatched
rows and, if any exist, emits one `Log::warning` naming the session ids and stating that their
`question_index` is unverifiable because the competency is detached from the project.

Consequence recorded honestly: the proposal's "zero negative rows after the migration" holds
for every session whose competency is still attached, and **only** for those. In today's
production sample the join covers every session, so the expected residual is zero — but the
migration must not depend on that remaining true.

---

## D4 — `down()` is a documented no-op, and says why

`-1` and `0` both recompute to `0`. The pre-migration value is not derivable from the
post-migration value, from the pivot, or from anything else in the schema. A `down()` that
wrote `position - 1` back would restore the *defect* to all 37 rows, including the 29 that
never had it — a reverse migration that is more destructive than the forward one.

Follow the `strip_language_from_avatar_templates_config` precedent (`:38-41`): an empty
`down()` whose docblock states plainly that the prior values are gone and that a rollback
needing them must restore from a database backup. **A reversible-looking irreversible
migration is worse than an honestly irreversible one**, because it is only discovered to be
wrong at the moment it is relied upon.

Code rollback is independent and safe: reverting the PR leaves the repaired rows repaired and
merely resumes writing `-1` for new sessions. If restoration ever matters, capture
`(id, question_index)` before running — cheap, and out of the migration's own hands.

---

## D5 — One payload builder, not three copies of `position - 1`

The expression appears three times (`:561`, `:571`, `:593`) inside three near-identical array
literals in one method. Fixing three characters in three places leaves three places for the
next edit to disagree.

| Option | Tradeoff | Verdict |
|---|---|---|
| Edit all three literals in place | Cheapest diff; preserves the duplication that let the drift exist | Rejected |
| Extract to `App\Support\Interview\*`, mirroring `CompetencyTally` | `CompetencyTally` earned its class because a **second surface** (admin) needed the definition and could not reach a private method. There is no second consumer here — the array never leaves `InterviewController`. A public seam for one caller invites the next caller to bind to it | Rejected |
| **One private builder on the controller**, three call sites | The construction of the payload exists once; the three branches differ only in the flag they add (`reoffer`). Local, ~8 lines, no new public surface | **Chosen** |

Same judgement as the archived consolidation, applied to a smaller radius: collapse the
duplicate **definition**, do not manufacture a shared **contract**.

---

## D6 — What `question_index` and `competency_ordinal` each mean once both are correct

`competency_ordinal` stays (out of scope), and after this change the two values coincide for a
dense, unreordered project. They are still different facts, and the docblocks must say so or a
future reader will delete one:

| | `question_index` | `competency_ordinal` |
|---|---|---|
| Source | `project_competencies.position` | the ordered list's own array index |
| Base | 0 | 1 |
| Lifetime | **Persisted** on the session row, frozen at creation | **Derived** per request, never stored |
| Meaning | *Which configured slot this session belongs to* — evidence, and the join key readers order and label by | *Which question of N the candidate is on right now* — a display rank, always dense |
| Diverges when | positions are sparse, or the project is reordered after the session exists | never — it is dense by construction |

`ordinal == question_index + 1` is a **coincidence of well-formed data**, not an identity.
The schema comment states the invariant as `question_index == project_competencies.position`,
never as arithmetic, so a future writer cannot re-derive a subtraction from it.

---

## D7 — The comments describing the defect are part of the change

`InterviewController.php:531-534` and `:1054-1063` currently teach that `question_index`
subtracts one and that `competency_ordinal` exists to route around it; `ServerDirectedFlowTest.php:18-23`
repeats it as the rationale for a test. Left in place they are a false map: the next
investigation reads them, believes the defect is live, and either re-introduces the workaround
or hunts a bug that no longer exists. This repo has already paid that cost once — census
comments expire, and these are census comments.

Each is rewritten to state what is now true and, where it explains a design (`competency_ordinal`),
why the field still exists on its own merits per D6 — not as a repair for something that has
been repaired. `ServerDirectedFlowTest`'s test at `:71` is red-first: its title asserts the two
values disagree on the first competency, which is precisely what stops being true.

**`frontend/app/composables/useInterviewSession.ts:520-525` is knowingly left as-is.** Its
operative claim — the field is not stored, the server owns last-competency detection — remains
true; only its parenthetical rationale ages into history. Editing it would open a `frontend`
submodule PR and a wrapper pointer bump for a comment. Recorded here so the omission is a
decision, not an oversight, and so the next `frontend` touch corrects it in passing.

---

## D8 — The `progress` webhook: no version bump, and what the release note must say

`answers[].question_index` changes value for every competency; the first competency's entry
goes `-1` → `0`. Shape, type and ordering are unchanged (`ProgressPayloadAssembler` needs no
edit — it emits the column).

`webhooks.payload.version` is **not** bumped. The ratified rule is explicit: *"bump on ANY
breaking payload **shape** change"* (`config/webhooks.php:9-10`). This is a value-semantics
change with no shape change, and bumping would tell every integrator of **both** event types
that the schema moved, which is false. The consequence is stated rather than hidden: a
shape-versioned envelope **cannot signal this class of change at all**, which is exactly why
the release note is load-bearing and not ceremonial.

The release note MUST state:

1. The field: `progress` webhook → `data.competencies[].answers[].question_index`.
2. The change: the value now equals the competency's 0-based `position` in the project's
   configured order. Every competency's value rises by one; the first competency's entry
   previously read `-1` and now reads `0`. Type, shape, field names and ordering are unchanged.
3. That it applies to **historical participants too** — a `progress` payload assembled after
   the deploy carries the corrected value even for a participant whose earlier deliveries
   carried the old one, so the two are not comparable across the deploy boundary.
4. That `payload.version` deliberately does not move, and why.
5. The deploy timestamp, and the required integrator action: any consumer special-casing `-1`,
   or adding `+1` to recover a question number, must remove that handling.

Permitted under CLAUDE.md's no-legacy-compatibility rule (greenfield). Permitted is not the
same as silent, which is the whole point of this decision record. Proposal question 1 —
*does any live integrator read the field?* — cannot be answered from this repository; it is a
pre-deploy verification, not a design gate.

---

## Data Flow

```
POST /candidate/interview/start
  resolveNextCompetency()
    project_competencies pc ⋈ framework_competencies fc   ORDER BY pc.position
      └─ competencyPayload($row, $index, $total)          ← D5, one construction site
           question_index    = $row->position             ← D1 (was: position - 1)
           competency_ordinal = $index + 1                ← unchanged (D6)
  → interview_sessions.question_index

migration (once, at deploy)
  interview_sessions s ⋈ pc ⋈ fc  ON pc.project_id = s.project_id AND fc.code = s.competency_code
    WHERE s.question_index IS DISTINCT FROM pc.position   ← D2: correct rows never enter the write
    unmatched rows → untouched + Log::warning(ids)        ← D3

readers (no code change; values shift)
  ProgressPayloadAssembler → progress webhook answers[]   ← D8, contract change
  ParticipantDownloadController:102  "(question %d)"  idx + 1 → 1 on the first competency
  TranscriptPanel.vue:35 (backoffice)                     already +1, becomes correct for free
  SessionSummaryResource / SessionReviewResource          raw value
```

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Http/Controllers/Candidate/InterviewController.php` | Modify | `question_index = $row->position`; three literals collapsed into one private builder (D1, D5); comments at `:531-534`, `:1054-1063` corrected (D7) |
| `api/database/migrations/2026_08_21_160000_recompute_interview_session_question_index.php` | **Create** | Join-based recompute, `IS DISTINCT FROM` guard, unmatched-row warning, no-op `down()` (D2, D3, D4) |
| `api/database/migrations/2026_07_20_100002_create_interview_sessions_table.php` | Modify | `:28`, `:51` — invariant stated as `question_index == project_competencies.position`, never as arithmetic (D6) |
| `api/tests/Feature/C9/ServerDirectedFlowTest.php` | Modify | Docblock `:18-23`; the `:71` test is red-first (D7) |
| `api/app/Services/Webhooks/ProgressPayloadAssembler.php` | **Unchanged** | Value shifts; no edit (D8) |
| `frontend/`, `backoffice/`, `openapi.json` | **Unchanged** | Verified — see Technical Approach |

---

## Testing Strategy (strict TDD — RED first)

Runner: `cd api && ./vendor/bin/pest <exact-file>` while iterating, full unfiltered run before
the PR. **Never `php artisan test --filter`** — observed fabricating passes in this repo. Tests
run on PostgreSQL (`phpunit.xml:57`), so the migration's `UPDATE … FROM` and `IS DISTINCT FROM`
are exercised as written, not through a SQLite dialect that would never see them.

| Tier | What it is responsible for proving |
|---|---|
| **Pest — endpoint** | That a `/start` on a project's **first** competency persists `0`, asserted through the real endpoint rather than a hand-written fixture. The existing unit coverage writes `0` directly and therefore cannot fail on this defect — that gap is the reason it survived |
| **Pest — migration, non-destructiveness** | **The one that matters most.** A dataset seeded to mirror production's mixture — already-correct rows alongside `-1` and the two mid-range drifted shapes — and the assertion that the correct rows are **byte-identical afterwards, `updated_at` included**. This is the test that fails on a blanket shift, on an Eloquent mass update, and on any future "simplification" of the join back into arithmetic |
| **Pest — migration, idempotency** | A second run changes nothing. Asserted as a property of the whole dataset, not of one row |
| **Pest — migration, detached competency** | A session whose competency has been `sync()`-detached keeps its value and is reported (D3). It must be provably impossible for the migration to write `0` there |
| **Pest — downstream** | The transcript download renders the first competency as *question 1*; the `progress` payload's first entry carries `0`; ordering is identical before and after; `competency_ordinal` still returns `1` on the first competency |
| **Pest — regression guards** | `Feature/Demo/TenancyTest.php:107` (the blanket-shift alarm) and `Unit/Services/Admin/AdminTranscriptSerializerTest.php:68` (ordering) stay green untouched |

Red-first: `Feature/C9/ServerDirectedFlowTest.php:71`, whose premise is the defect. Enumeration
belongs to the tasks phase.

---

## Delivery

```
400-line budget risk: Low
Chained PRs recommended: No
Decision needed before apply: No
```

Single `api` PR — logic fix, migration, comment and schema corrections, tests — plus one wrapper
pointer bump. No submodule sync cycle: the OpenAPI shape does not move. Deploy runs the
migration with the fixed code in the same release; the two must not be separated (D2).

---

## Open Questions

- [ ] **Does any live integrator consume `question_index` from the `progress` webhook?**
      Unanswerable from this repository. Gates the release note's distribution list, not the
      design (D8). Pre-deploy verification.
- [ ] Should the pre-migration `(id, question_index)` snapshot be captured as a matter of course
      (D4)? Cheap insurance; deliberately left outside the migration so it is an operator
      decision rather than a table this change owns forever.

---

## Assumptions for user review

1. **The backfill recomputes from `position`; it never shifts.** The central judgement, and it
   rests on the mixed dataset, not on taste (D2).
2. **Already-correct rows are excluded from the write, not rewritten with the same value** — the
   only way `updated_at` stays byte-identical (D2).
3. **A detached competency's session is left untouched and reported**, and the "zero negative
   rows" criterion therefore holds only for still-attached competencies (D3).
4. **`down()` is empty and documented as irreversible** (D4).
5. **The three payload literals collapse into one private builder**, not into a shared class —
   there is no second consumer (D5).
6. **`competency_ordinal` stays and keeps its own meaning**; convergence with `question_index + 1`
   is a coincidence of well-formed data, not an identity (D6).
7. **`webhooks.payload.version` is not bumped**; the release note is the only signal, by design
   and with the gap stated (D8).
8. **No `frontend` or `backoffice` change** — verified in code, including the one stale frontend
   comment deliberately left (D7).
