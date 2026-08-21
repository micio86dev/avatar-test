# Tasks: Repair the `question_index` Off-By-One

Derived from `proposal.md`, `design.md` (D1–D8) and the two delta specs.

**Strict TDD is active.** Every RED task precedes its GREEN task and the RED task must
report the actual failure observed — never assumed. `ServerDirectedFlowTest.php:71` is
inverted inside the RED task that supersedes it, never afterwards.

**Delivery: single `api` PR** + one wrapper pointer commit. No chaining, no `frontend`/
`backoffice` changes (verified in the design, not assumed).

| Field | Value |
|---|---|
| 400-line budget risk | Low |
| Chained PRs recommended | No |
| Decision needed before apply | No |

Runner: `cd api && ./vendor/bin/pest <exact-file>` while iterating, full unfiltered
`php artisan test --parallel` before the PR. **Never `php artisan test --filter`** —
observed fabricating passes in this repo. Coverage: `php artisan test --coverage --min=85`.

---

## Phase 1 — RED: pin the corrected value at every consumer, before touching the source

Req: `interview-session` "InterviewSession tenant model", "POST /start", "Competency
sessions created in project_competencies.position order"; `webhooks-integration`
"progress payload — creation and advancement cases"

- [x] **1.1 RED** — Feature test: `POST /candidate/interview/start` on a project's
      **first** competency persists `question_index = 0` in the DB, asserted through the
      real endpoint (not a hand-written fixture — the existing unit coverage writes `0`
      directly and cannot fail on this defect, per design's Testing Strategy). Run against
      current code; capture the actual failure (`-1`, not `0`).
      DONE: `tests/Feature/C7a/QuestionIndexZeroBasedTest.php`, driven through the real
      endpoint against a new `casDenseProject()` fixture (0-based positions, matching the
      real production writers — `casProject()`'s 1-based `$i + 1` would have masked the
      RED). RED observed: `Failed asserting that -1 is identical to 0.`
- [x] **1.2 RED** — Invert `ServerDirectedFlowTest.php:71`'s assertion: its current title
      and body assert `competency_ordinal` is 1-based on the first competency **where
      `question_index` is not** — that disagreement is precisely the defect. Rewrite the
      assertion to require the two values to reconcile as designed (`ordinal ==
      question_index + 1` on a dense project). Run against current code; capture the
      actual failure.
      DONE: renamed to `competency_ordinal reconciles with question_index + 1 on a dense
      project`, uses `casDenseProject()`. RED observed: `the first competency sits at
      position 0 — Failed asserting that -1 is identical to 0.`
- [x] **1.3 RED** — Feature test: `ParticipantDownloadController`'s transcript download
      renders **"question 1"**, not "question 0", for a project's first competency. Run
      against current code; capture the actual failure.
      DONE: `tests/Feature/C11/TranscriptQuestionNumberingTest.php`, driven through the
      real `/start` endpoint. RED observed: transcript body contained
      `DDE (question 0)`, not `DDE (question 1)`.
- [x] **1.4 RED** — Feature test, end to end through `ProgressPayloadAssembler` (not a
      hand-written fixture): once a project's **first** competency's session has ended,
      the `progress` payload's `answers[0].question_index` equals `0`, not `-1`. Run
      against current code; capture the actual failure.
      DONE: `tests/Feature/C10/ProgressPayloadFirstCompetencyTest.php`, real `/start` +
      `/end`. RED observed: `Failed asserting that -1 is identical to 0.`
- [x] **1.5 GREEN** — `InterviewController.php`: extract one private `competencyPayload()`
      builder (D5) replacing the three near-identical literals at `:561, 571, 593`; drop
      the `- 1` (D1); write `question_index = $row->position`.
      DONE — signature takes `array{competency_code: string, position: int} $row` (cast
      from the stdClass row at each of the three call sites) to keep PHPStan level 8 clean.
- [x] **1.6** — Re-run 1.1–1.4: all GREEN. Re-run the regression guards named in the
      design and confirm they stay green **unmodified**: `Feature/Demo/TenancyTest.php:107`
      (`[0,1,2,3,4]` — the blanket-shift alarm), `Unit/Services/Admin/
      AdminTranscriptSerializerTest.php:68` (ordering), `Unit/C10/
      ProgressPayloadAssemblerTest.php:118` (`answers[0].question_index` `toBe(0)`, unaffected
      because its fixture writes `0` directly).
      DONE — all GREEN together: 32 tests / 32 passed / 131 assertions.
- [x] **1.7** — Correct the comments that describe the defect as live (D7):
      `InterviewController.php:533-534` and `:1054-1063` (state what is now true; where it
      explains `competency_ordinal`, ground it in D6's own-merits rationale, not as a
      workaround for something already fixed) and `ServerDirectedFlowTest.php:18-23`
      (docblock, paired with 1.2's inverted assertion).
      DONE. Also found and corrected a fourth live occurrence of the same false claim not
      listed in design's File Changes table: `app/Services/Provider/QuestionContext.php`'s
      `$competencyOrdinal` property docblock.

---

## Phase 2 — THE CRUX: the backfill migration (D2, D3, D4)

Req: `interview-session` "question_index backfill recomputes from position and never
shifts"

- [x] **2.1 RED** — Non-destructiveness test: seed a dataset mirroring production's
      mixture across **at least two distinct `organization_id`s** — already-correct rows
      at dense `0..4` positions (the `DemoWriter` shape), rows at `-1`, and the two
      mid-range drifted shapes (`(0,1)`, `(1,2)`). Assert the already-correct rows come out
      **byte-identical, every column including `updated_at`**, and the drifted rows
      recompute to their competency's current `position`. Run before the migration file
      exists; capture the actual failure (drifted rows stay wrong).
      DONE: `tests/Feature/C9/QuestionIndexBackfillMigrationTest.php`. RED observed (before
      the migration file existed): `require(…recompute_interview_session_question_index.php):
      Failed to open stream: No such file or directory` on all four tests in this file.
- [x] **2.2 GREEN** — Create
      `api/database/migrations/2026_08_21_160000_recompute_interview_session_question_index.php`:
      `DB::statement()` only (no Eloquent — `InterviewSession` is `TenantScoped` and a
      model-based update inside a migration has no ambient `TenantContext`), joining
      `project_competencies` + `framework_competencies` on `project_id` + `competency_code`,
      guarded by `IS DISTINCT FROM` so an already-correct row never enters the write set.
      Unscoped by design — covers every tenant in one statement.
      DONE. All 4 migration tests GREEN (13 assertions).
- [x] **2.3** — **Mutation check, not optional (repo convention).** Temporarily replace the
      raw-SQL update with (a) a blanket `question_index = question_index + 1` shift and
      separately with (b) an Eloquent `InterviewSession::query()->update()` mass update.
      Re-run 2.1 for each mutation and confirm it **fails** both times — (a) corrupts the
      already-correct rows, (b) stamps `updated_at` and/or misses tenants with no ambient
      `TenantContext`. Record the actual failures observed, then revert to the raw-SQL
      implementation and confirm 2.1 is GREEN again.
      DONE. (a) blanket +1: 3/4 tests failed — byte-identical test failed
      (`'question_index' => 0` expected, `1` actual on an already-correct row), idempotency
      test failed (every run shifts again), detached-competency test failed (`0` expected
      `-1`, wrote `-1 + 1 = 0` unconditionally). (b) Eloquent `InterviewSession::query()
      ->update(['question_index' => 0])` under the ambient tenant context left over from
      fixture setup: 3/4 tests failed — 2.1 failed on the drift-recompute assertion
      (`Failed asserting that 0 is identical to 1`), the two-tenant test failed (`org A's
      drifted row must be corrected … Failed asserting that -1 is identical to 0` — the
      Eloquent update only touched the LAST org set in TenantContext, leaving the other
      untouched — exactly the "repairs one tenant or none" failure mode named in the
      design), and the detached-competency test failed (wrote `0` unconditionally, not
      "unchanged"). Reverted to the raw-SQL implementation (`diff` confirmed byte-identical
      to the pre-mutation file); 2.1 confirmed GREEN again (4/4 passed).
- [x] **2.4 RED → GREEN** — Idempotency test: run the migration, snapshot every row's
      full column set, run the migration a **second time**, assert the snapshot is
      unchanged (whole-row diff, not a row count — "no rows changed" must not be assumed
      from the `IS DISTINCT FROM` guard, it must be observed).
      DONE — same file, `running the migration a second time changes nothing (whole-row
      diff)`.
- [x] **2.5 RED** — Cross-tenant repair test: seed drifted rows in **≥2 distinct**
      `organization_id`s. Prove the test can fail for the right reason: temporarily swap
      the migration's `DB::statement()` for an `InterviewSession::query()->update()` call
      (TenantScoped, no ambient `TenantContext` inside a migration) and confirm this test
      fails — this is the exact failure mode named in the design: it would silently repair
      one tenant or none. Revert the mutation.
      **2.5 GREEN** — Re-run against the real (raw-SQL) migration; assert rows in **both**
      organizations are corrected.
      DONE — `drifted rows are corrected in BOTH of two distinct organizations`; failed
      under the Eloquent mutation (see 2.3), GREEN against the raw-SQL migration.
- [x] **2.6 RED** — Detached-competency test (D3): seed a session whose competency was
      `sync()`-detached from `project_competencies` (no matching join row). Assert that
      after the migration runs, that row's `question_index` is **unchanged** — never
      written as `0` or `NULL` — and that a `Log::warning` naming that session's id was
      emitted. Confirm this fails before the pre-UPDATE detection + warning exists.
      DONE — same file, RED confirmed via the missing-migration-file error (2.1) and via
      both task-2.3 mutations (both wrote `0` where `-1` should have survived unchanged).
- [x] **2.7 GREEN** — Implement the pre-UPDATE unmatched-row count and one
      `Log::warning` naming the affected session ids, stating the competency is detached
      and the value unverifiable. Confirm the `UPDATE … FROM` structurally cannot touch an
      unmatched row (the join itself excludes it — no defensive `WHERE` needed for
      correctness, only the warning for disclosure). Re-run 2.6; GREEN.
      DONE. `Log::spy()` + `Log::shouldHaveReceived('warning')->withArgs(...)` asserts by
      CONTENT (message contains "detached" AND context session_ids contains the id) —
      no `->once()` count assertion.
- [x] **2.8** — `down()`: empty, with a docblock stating plainly that `-1` and `0` both
      recompute to `0`, the prior value is not derivable from anything in the schema, and
      restoration — if it ever matters — requires a database backup (D4).

---

## Phase 3 — Correct the false premise everywhere it is written down (D6, D7)

Req: `interview-session` "InterviewSession tenant model"

- [x] **3.1** — `create_interview_sessions_table.php:28, 51`: docblock and column comment
      restated as the invariant `question_index == project_competencies.position` — never
      as arithmetic, so a future writer cannot re-derive a subtraction from it (D6).
- [x] **3.2** — Confirm 1.7's rewrite of `InterviewController.php:533-534, 1054-1063` fully
      replaces the "routes around `position - 1`" framing with `competency_ordinal`'s own
      reason to exist (D6): different source, different base, persisted vs. derived.
- [x] **3.3** — Repo-wide sweep of `api/app`, `api/tests`, `api/database` for any remaining
      `position - 1` / "1-based" claim near `question_index`. Confirm zero live
      occurrences. (`openspec/specs/interview-session/spec.md` and
      `openspec/specs/webhooks-integration/spec.md` are corrected by this change's delta
      specs at `sdd-archive`, not by this task — confirm they are not also duplicated
      in-tree.)
      DONE — `rg "position - 1|position -1|1-based"` across `app tests database`: every
      remaining hit is either past-tense (describing the historic defect, e.g. this
      change's own new test docblocks and the migration's `down()` rationale) or a
      genuinely-1-based, unrelated fact (`competency_ordinal` IS 1-based by design). No
      live claim that `question_index = position - 1` remains. Confirmed no in-tree
      duplication of the openspec delta-spec claims within `api/`.

---

## Phase 4 — Downstream proof, coverage gate, full suite

Req: `interview-session` "Downstream question numbering derived from question_index
starts at 1"; `interview-session` "Competency sessions created in
project_competencies.position order" (ordering-unchanged scenario)

- [x] **4.1** — Dataset-level test: ordering by `question_index` returns the identical
      sequence before and after the correction (monotonic relabeling, not a reordering) —
      distinct from `AdminTranscriptSerializerTest.php:68`, which already covers this;
      confirm coverage rather than duplicate it.
      DONE — confirmed `AdminTranscriptSerializerTest.php:68` already covers this
      (unaffected by the fix, re-ran GREEN); no duplicate test added.
- [x] **4.2** — Confirm (existing or new) coverage that `competency_ordinal` still returns
      `1` on the first competency and is unaffected everywhere.
      DONE — covered by the rewritten `ServerDirectedFlowTest.php` test (asserts
      `ordinal->toBe(1)` explicitly) and the pre-existing `/start returns competency_ordinal
      and total_competencies` test in the same file, both GREEN.
- [x] **4.3** — Final sweep: no comment, docblock, or test description in `api/` still
      claims `question_index = position - 1`.
      DONE — same sweep as 3.3.
- [x] **4.4** — Run `php artisan test --parallel` (full, unfiltered) from `api/`. Record
      pass/fail counts.
      DONE (ran via `./vendor/bin/pest --parallel`, equivalent runner per this project's
      Pest setup): **2061 tests / 2056 passed / 5 skipped / 0 failed / 5656 assertions.**
      Baseline on `develop` was 2054 tests / 2049 passed / 5 skipped / 0 failed — the +7
      is exactly this change's new tests (1 + 1 + 1 + 4).
- [x] **4.5** — Run `php artisan test --coverage --min=85`. **Record the actual overall
      percentage in this task** — the gate is not satisfied by ticking the box without the
      number. Confirm the migration and `InterviewController::competencyPayload()` (the
      correctness-critical zone here) sit near the ~95% bar, not just the 85% floor.
      DONE (`./vendor/bin/pest --coverage --min=85 --parallel`): gate **passed**. Overall
      **Lines: 94.08% (6389/6791)**, Methods: 81.55% (535/656), Classes: 71.43% (170/238).
      `InterviewController` (whole class, 20 methods): Lines 91.15% (309/339), Methods
      55.00% (11/20) — `competencyPayload()` itself is exercised by all three of its call
      sites (new/RESUME/RE-OFFER) across the new and pre-existing suite (e.g.
      `ErrorCountBackfillTest.php` drives the re-offer branch). The migration file is
      **not** tracked by the coverage tool at all — `phpunit.xml`'s `<source><include>`
      is `app/` only (migrations are conventionally untested-by-coverage-tool in this repo,
      per the `error_count` backfill precedent) — its correctness is instead proven by the
      4 dedicated behavioral tests in `QuestionIndexBackfillMigrationTest.php`, including
      the mandatory mutation check (2.3).

---

## Phase 5 — Release note for the `progress` webhook contract change (D8)

Req: `webhooks-integration` "progress payload — creation and advancement cases"

- [x] **5.1** — Write the release note. It MUST state all five, per D8:
      DONE — `openspec/changes/interview-question-index-offset/release-note.md`, all five
      points present (field, change, historical-participant applicability, no version
      bump + why, deploy timestamp placeholder + required integrator action).
      1. The field: `progress` webhook → `data.competencies[].answers[].question_index`.
      2. The change: the value now equals the competency's 0-based `position`; every
         competency's value rises by one; the first competency's entry was `-1`, now `0`.
         Type, shape, field names and ordering are unchanged.
      3. It applies to **historical participants too** — a `progress` payload assembled
         after the deploy carries the corrected value even for a participant whose earlier
         deliveries carried the old one; the two are not comparable across the deploy
         boundary.
      4. `payload.version` deliberately does **not** move, and why (value-semantics change,
         no shape change — the ratified bump rule is scoped to shape).
      5. The deploy timestamp, and the required integrator action: remove any handling that
         special-cases `-1` or adds `+1` to recover a question number.

---

## Phase 6 — Git Flow and close-out

**Deliberately left unticked by `sdd-apply`.** Branching/PR/merge/wrapper-pointer are Git
Flow operations owned by the orchestrator, not the phase executor — the working branch was
already checked out (`fix/interview-question-index-offset`, not `feature/…` per this task's
original text) before apply started, and apply leaves everything uncommitted by design.

- [ ] **6.1** — `api`: branch `feature/interview-question-index-offset` from `develop`.
      Commit the reader fix, migration, comment corrections and tests as this single PR.
- [ ] **6.2** — Open the PR against `api`'s `develop`. CI green: Pint, PHPStan, full Pest
      suite, coverage gate.
- [ ] **6.3** — Merge. This is a bugfix + data repair with no API shape change — PATCH-level
      per `docs/git-flow.md`'s SemVer rule; the version bump itself happens on the next
      `release/*` branch, not on this feature merge.
- [ ] **6.4** — Wrapper: bump the `api` submodule pointer to the merged commit. Conventional
      commit, e.g. `chore(api): pin question_index offset fix`.

---

## Phase 7 — Pre-deploy / post-deploy verification

**Deliberately left unticked by `sdd-apply`.** These are live-production operational steps
(a real DB drift query, a real deploy, a real distribution list) requiring access this
implementation session does not have. Blocked on the deploy this code has not yet had.

- [ ] **7.1** — Pre-deploy: re-run the read-only production drift query (join
      `interview_sessions` to `project_competencies` via `project_id` + `competency_code`,
      `WHERE question_index <> position`) and record the baseline count.
- [ ] **7.2** — Deploy code + migration together (D2 — they must not be separated).
- [ ] **7.3** — Post-deploy: re-run the **same** drift query. Confirm **zero** rows where
      `question_index <> position` for competencies still attached to their project (D3's
      caveat: a session whose competency was detached is expected to remain in this count
      and must instead appear in the migration's `Log::warning` output from 2.7 — cross-check
      the two lists agree).
- [ ] **7.4** — Confirm the release note (Phase 5) is distributed to integrators. Gated on
      the open question — *does any live integrator consume `question_index` from the
      `progress` webhook* — which is unanswerable from this repository; this is where it
      gets answered, not before.

---

## Confirm — no user-facing surface touched

- [x] **8.1** — Confirm no user-facing string is introduced anywhere in this change:
      `question_index` remains machine-facing and unlocalized (API field name, DB column,
      log key, webhook payload key) per CLAUDE.md's machine-facing-responses rule. No i18n
      key is added or edited in `frontend` or `backoffice` — neither app is touched (verified
      in the design, Out of Scope). The Phase 5 release note is operator/integrator
      documentation, not an in-app string.
