# Proposal: Repair the `question_index` Off-By-One

> **Not a discovery.** `InterviewController.php:1054-1063` already documents this exact
> mismatch and says `competency_ordinal` was introduced to route around it, *"repairing
> `question_index` is a separate change"*. `ServerDirectedFlowTest.php:18-23` and
> `useInterviewSession.ts:520-525` carry the same note. The workaround is correct for its own
> callers. This change pays off the debt at the source.

## Intent

`interview_sessions.question_index` is written as `position - 1`, but
`project_competencies.position` is **0-based at every writer**. Every index is one below what
it should be, and the first competency of every project stores **-1**.

| Side | Verified at |
|---|---|
| Reader subtracts one | `InterviewController.php:561, 571, 593` (`$row->position - 1`) |
| Writer 1 — **production project creation** | `Api/ProjectController.php:98-99` (`foreach ($competencyIds as $position => …)`) |
| Writer 2 — **production project update** | `Api/ProjectController.php:161-162`, then `sync()` |
| Writer 3 — demo provisioning | `Support/Demo/DemoWriter.php:252-259` |
| Writer 4 — role pivot feeding the default set | `FrameworkCatalogSeeder.php:368-370` |
| The false premise, in the schema itself | `2026_07_20_100002_create_interview_sessions_table.php:28, 51` — *"question_index: 0-based ordinal (position - 1)"* |
| The false premise, ratified in a spec | `interview-session/spec.md:31, 81, 366, 1067` — *"= position 1 - 1"*, *"= position 3 - 1"* |

**Correction to the framing.** The brief named `FrameworkCatalogSeeder` as a
`project_competencies` writer; it writes `framework_role_competency`. The two real
`project_competencies` writers are both in `ProjectController` — the **production** path, not
a seeder. All four are 0-based, so the conclusion holds and the evidence is stronger.

**Confirmed in production**, not inferred: `position` ranges 0–4, `question_index` ranges
**-1 to 4**, with **6 sessions currently holding -1**.

### Consequences

| Consumer | Effect |
|---|---|
| `Api/ParticipantDownloadController.php:102` — `sprintf('… (question %d)', $idx + 1)` | First competency prints **"question 0"**; every later one is one low |
| `backoffice/app/components/organisms/TranscriptPanel.vue:35` — same `+ 1` | Same wrong number, operator-facing |
| `Services/Webhooks/ProgressPayloadAssembler.php:57, 67` | Emits `question_index` in the **`progress` webhook** — an external integrator contract |
| `SessionSummaryResource.php:35`, `SessionReviewResource.php:54` | Raw value on admin read surfaces |

**Ordering is NOT affected, and that is why this survived.** `orderBy('question_index')`
(`AdminTranscriptSerializer.php:49`) sorts identically under a monotonic shift, and the
webhook assemblers order by `project_competencies.position` directly. Nothing was ever
mis-sequenced — only mis-labelled.

**The webhook value change is deliberate, not incidental.** CLAUDE.md: *"No legacy backward
compatibility (API/webhook/ID formats): greenfield."* That permits it. It does not excuse
shipping it silently, so it is named here as a contract change.

## Scope

### In Scope

| # | Deliverable |
|---|---|
| 1 | `resolveNextCompetency()` writes `question_index = $row->position` at all three sites (`:561, 571, 593`) |
| 2 | **Backfill migration** recomputing `question_index` from `project_competencies.position` for existing rows — **D2**, the risk-bearing element |
| 3 | Correct the schema docblock and column comment (`create_interview_sessions_table.php:28, 51`) |
| 4 | Correct the three in-code comments that describe the defect as live (`InterviewController.php:533-534, 1057-1063`; `ServerDirectedFlowTest.php:18-23`) |
| 5 | Delta specs: `interview-session` (the `= position - 1` definition), `webhooks-integration` (the changed `answers[].question_index` value) |
| 6 | Pest coverage per project policy — strict TDD is active (`config.yaml: strict_tdd: true`). Enumeration belongs to the tasks phase |

### Out of Scope

- **Removing `competency_ordinal`.** It is a shipped contract field the frontend trusts
  (`useInterviewSession.ts:525`) and it is correct by construction whatever `position` holds.
  It becomes equal to `question_index + 1` for dense positions; that is convergence, not
  redundancy to clean up here.
- **Changing `position` to 1-based.** Rejected: four writers, a live pivot table, and every
  `orderBy('position')` reader, to fix a subtraction in one method.
- **`interview-frontend/spec.md:471-485`**, which still mandates the progress numerator be
  `question_index + 1` while the shipped composable uses `competency_ordinal`. That drift came
  from `interview-continuous-flow` and is a separate stale-spec defect. Named, not fixed here.
- **`ProjectController::update`'s `sync()` detaching competencies that already have sessions.**
  A latent defect surfaced while verifying the backfill's edge cases. Named, not fixed here.
- **`frontend` and `backoffice` code.** Verified: the frontend no longer stores the field, and
  `TranscriptPanel.vue:35` already renders `+ 1` — fixing the source makes it correct with no
  edit. Backoffice fixtures already use `0`/`1`, the post-fix values.
- **`openapi.json` regeneration.** The field's type and shape are unchanged; only its value is.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- **`interview-session`** — the `question_index` definition and its three worked examples
  (`spec.md:31`, `:81`, `:366`, `:1067`) assert `position - 1` against a 1-based `position`
  that never existed. This spec is the origin of the defect, not a downstream victim of it.
- **`webhooks-integration`** — `spec.md:287-289` and the scenario at `:315`: the
  `{question_index, answered_at}` entry's **value** changes for every competency.

## Approach

### D1 — Fix the reader, keep `position` as it is

Drop the `- 1`. `question_index` then equals `position`, which is what `DemoWriter.php:404`
has always written (`'question_index' => $position`) and what
`tests/Feature/Demo/TenancyTest.php:107` already asserts as `[0, 1, 2, 3, 4]`. The
post-fix invariant is not new — half the codebase already holds it.

### D2 — Recompute the backfill from `position`; **never blanket-shift**

**This is the one decision carrying real risk, and it is not the obvious one.** A blanket
`UPDATE … SET question_index = question_index + 1` is wrong: demo-provisioned rows are
**already correct** (`DemoWriter.php:404`), so a shift corrupts them. The dataset is mixed
today.

The backfill must instead **recompute from the authoritative source** — join
`project_competencies` on `project_id` + `competency_code` and set `question_index =
position`. Correct for every row regardless of origin, and idempotent.

Leaving the 6 production rows while fixing new writes is the worst available outcome: old
sessions off by one, new ones not, and nothing in the data to tell them apart later.

Two edge cases the design phase owns: a session whose competency was since detached has no
join row, and a project reordered after its sessions existed will recompute to *current*
position — which is what every reader already joins against.

### D3 — `down()` is not restorable, and must say so

Once recomputed, the original values cannot be derived (`-1` and `0` both map to `0`). Follow
the `avatar-language-follows-project` precedent: a documented one-way `down()`, never a
migration disguised as reversible.

### Changed-line forecast

```
400-line budget risk: Low
Chained PRs recommended: No
Decision needed before apply: No
```

Three characters of production logic. The migration, the spec deltas, the comment corrections
and the tests are the volume. Single `api` PR + wrapper pointer bump.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Http/Controllers/Candidate/InterviewController.php:561, 571, 593` | Modified | `- 1` removed (D1) |
| `api/app/Http/Controllers/Candidate/InterviewController.php:533-534, 1057-1063` | Modified | Comments describing a defect that no longer exists |
| `api/database/migrations/` | **New** | Recompute backfill; one-way `down()` (D2, D3) |
| `api/database/migrations/2026_07_20_100002_create_interview_sessions_table.php:28, 51` | Modified | Docblock and column comment corrected |
| `api/tests/Feature/C9/ServerDirectedFlowTest.php:18-23, 71-88` | Modified | Docblock + the test that pins the defect |
| `openspec/specs/{interview-session,webhooks-integration}/spec.md` | Delta | See Capabilities |
| `api/app/Services/Webhooks/ProgressPayloadAssembler.php` | **Unchanged** | Value shifts; no code edit |
| `backoffice/`, `frontend/` | **Unchanged** | Verified — see Out of Scope |

## Existing tests that pin today's behaviour

| Test | Effect |
|---|---|
| `Feature/C9/ServerDirectedFlowTest.php:71` — *"competency_ordinal is 1-based on the FIRST competency, **where question_index is not**"* | **Red-first.** Its whole premise is the defect being removed |
| `Feature/Demo/TenancyTest.php:94, 107` — `question_index = pivot position` → `[0,1,2,3,4]` | Must stay green — it already asserts the post-fix invariant, and it is the guard against a blanket-shift backfill (D2) |
| `Unit/Services/Admin/AdminTranscriptSerializerTest.php:68` — ordering by `question_index` | Must stay green — ordering is not what changes |
| `Unit/C10/ProgressPayloadAssemblerTest.php:118` — `answers[0].question_index` `toBe(0)` | Must stay green; the fixture writes `0` directly, so it is unaffected — a first-competency **end-to-end** assertion is what is missing today |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Blanket `+1` backfill corrupts already-correct demo rows | **Certain if taken** | D2 — recompute from `position`, never shift. `TenancyTest.php:107` fails loudly if this is got wrong |
| The `progress` webhook changes value for live integrators | Med | Deliberate and permitted (greenfield, CLAUDE.md); named in the delta spec and requiring a release note, not a silent ship |
| Migration `down()` cannot restore prior values | Certain | D3 — documented one-way; capture an `(id, question_index)` snapshot in the same PR if restoration ever matters |
| A session whose competency was detached has no join row | Low | Named as a design-phase obligation; leave untouched rather than guess |
| Someone "simplifies" `competency_ordinal` away once the two converge | Med | Out of Scope states why it stays: correct by construction, and a shipped field the frontend reads |
| A future writer re-introduces 1-based `position` | Low | The corrected schema comment states the invariant (`question_index == position`) rather than the arithmetic |

## Rollback Plan

**Code**: revert the PR. Three characters return, and new sessions resume writing `-1`.

**Data**: the backfill is **not** revertible (D3) — `-1` and `0` both recomputed to `0`. Roll
the migration back independently of the code only if a snapshot was captured. Reverting the
code while rows are already correct is safe and merely re-introduces the drift for new rows.

## Dependencies

- `single-session-interview` (active, frontend-only, no API or schema change) — verified
  non-overlapping.
- Pest run as `cd api && ./vendor/bin/pest <exact-file>` or a full run — never
  `php artisan test --filter`, observed fabricating passes in this repo.

## Success Criteria

- [ ] A `/start` on the **first** competency of a project persists `question_index = 0`, not `-1`.
- [ ] `question_index == project_competencies.position` for every session, asserted end to end
      through the endpoint rather than from a hand-written fixture.
- [ ] Transcript download renders the first competency as **"question 1"**.
- [ ] After the migration, **zero** rows hold a negative `question_index`, and demo-provisioned
      rows are byte-identical to before (D2).
- [ ] The migration is idempotent — running it twice changes nothing the second time.
- [ ] Transcript session ordering is unchanged before and after.
- [ ] `competency_ordinal` still returns `1` on the first competency and is unchanged everywhere.
- [ ] No comment, docblock, or spec sentence still claims `question_index = position - 1`.
- [ ] Full Pest suite green.

## Proposal question round

Not asked interactively — recorded for review before `sdd-spec`. Neither blocks implementation.

1. **OPEN — does any live integrator consume `question_index` from the `progress` webhook?**
   Cannot be answered from this repository. If yes, this needs a **release note**; the value
   silently improving is still a silent change. Pre-deploy verification, not a design gate.
2. **OPEN — for the 6 production rows at `-1`, is recompute-to-current-position acceptable
   for a project reordered since?** D2 assumes yes, on the grounds that every reader already
   joins against current `position`.

## Assumptions for user review

1. The fix is at the **reader**; `position` stays 0-based (D1).
2. The backfill ships **with** the code fix, in the same PR — a half-fixed dataset is worse
   than either state alone.
3. The backfill **recomputes**, it does not shift (D2). This is the change's central judgement.
4. `down()` is a documented one-way (D3).
5. The webhook value change is accepted under the greenfield rule and disclosed in the spec.
6. **No `frontend` or `backoffice` code changes** — verified, not assumed.
