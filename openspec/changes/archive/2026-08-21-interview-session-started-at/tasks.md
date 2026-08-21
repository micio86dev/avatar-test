# Tasks: Record a Session's Live Time, Not the Span Around It

Derived from `proposal.md`, `design.md` (D1–D10) and the delta spec
`specs/interview-session/spec.md`.

**Strict TDD is active.** Every behavioural task is RED-first: the failing test is its own
task, run and observed failing **for the right reason**, before the task that makes it pass.
A RED step that has not been run and its actual failure recorded may not be ticked.

## Why this ships as one PR — record the refusal, do not re-slice it later

The design **refuses** a split on a correctness ground, not a size one (Delivery section):
any slice that stamps `started_at` before the consumers move onto `liveSeconds()` publishes
the wall-clock span — abandonment gaps included — as a *duration*, live, in the dashboards
the product owner is about to read to settle open decision #7. A PR that ships the stamp
without the consumer migration is not a smaller safe PR; it is a wrong number in production
for however long the second PR takes to land. **Do not split this change on size grounds** —
if a reviewer insists, the design names the only safe seam: [production writers + consumers +
D5 invariant] then [D8 fixture hygiene + D9 demo], in that order, never the reverse.

| Field | Value |
|---|---|
| Changed-line forecast | Medium (~400 lines, most of it the fixture migration across ~8 test files) |
| Chained PRs recommended | No |
| Decision needed before apply | No |

Runner: `cd api && ./vendor/bin/pest <exact-file>` while iterating; full unfiltered run
before the PR. **Never `php artisan test --filter`** — observed fabricating passes in this
repo. Coverage: `./vendor/bin/pest --coverage --min=85`.

**Two standing rules for every test task below:**
- Never assert an incidental count (no `->once()` on a log or event expectation). Assert
  **by content** — the message, the context payload, the specific value.
- A fixture may never be the reason a duration/cost/ordering assertion passes. If a test
  needs a session to have live time, it must reach that state through a **named factory
  state** (`->live()`, `->ended()`, `->resumed()`) or the real endpoint — never a bare
  default.

---

## Phase 1 — Schema: a stretch is a row (D1, D5)

Req: `interview-session` "InterviewSession tenant model — LOCKED status enum"

- [x] **1.1** — Migration `api/database/migrations/2026_08_21_180000_create_interview_session_live_periods_table.php`:
      `id`, `organization_id` (FK cascade), `interview_session_id` (FK cascade),
      `provider_session_ref` (nullable string), `started_at` (timestampTz NOT NULL),
      `ended_at` (timestampTz NULL — NULL ⇔ still live), `closed_reason` (nullable string
      ∈ `{resume, end, error}`), timestamps. Composite index `(organization_id,
      interview_session_id)` (D22 org-lead convention). Partial unique index
      `UNIQUE (interview_session_id) WHERE ended_at IS NULL` via `DB::statement()` — the
      fluent builder cannot express a partial index (D5).
- [x] **1.2** — `down()`: drops the table. Docblock states plainly (D7, Migration/Rollout):
      this is genuinely reversible in the schema sense, but every row it destroys is a live
      observation that exists nowhere else — a rollback after production traffic loses those
      minutes permanently and per D7 they cannot be reconstructed from anything else in the
      schema. State this honestly; do not claim full reversibility.
- [x] **1.3** — Model `api/app/Models/InterviewSessionLivePeriod.php`: `TenantModel`,
      `belongsTo(InterviewSession::class)`.
- [x] **1.4** — `api/app/Models/InterviewSession.php`: add `livePeriods(): HasMany`.
- [x] **1.5** — Factory `api/database/factories/InterviewSessionLivePeriodFactory.php`:
      `closed()` (both timestamps set) and `open()` (`ended_at` null) states — no default
      that implies a duration.
- [x] **1.6** — `MigrationSchemaTest`: the new table, both indexes (including the partial
      unique index's exact `WHERE` clause), and the FK cascade behaviour are present. Confirm
      RED against the pre-1.1 state, GREEN after.

---

## Phase 2 — RED: the test that matters, before anything can make it pass

Req: `interview-session` "Recorded duration is accumulated live time, not wall-clock span"
— scenario "Two live stretches sum; the gap between them does not"

**This is the single guard named in the design as the reason the change exists**: 4 minutes
live → 3 hour gap with no live provider session → 6 minutes live → `/end`, and the recorded
duration must equal **the resolved provider ceiling for the abandoned first stretch, plus the
real 6-minute second stretch** (D4a amendment, recorded during apply — 1560s for a HeyGen
session at the 1200s platform ceiling, derived in the test, never hardcoded) — never ~11 400
(the gap counted, the over-count a raw-`now()` leave-alone stamp produces) and never 360 (the
first stretch discarded, the under-count a reset produces). D4a's rationale: BEAI cannot
observe when an abandoned stretch truly stopped — the provider itself keeps billing until its
own ceiling (production evidence: `MAX_DURATION_REACHED`) — so the cap is the honest bound,
never a guess at the true value.

**It is worthless written any other way.** It MUST drive `Illuminate\Support\Carbon::travel()`
through the **real endpoints** — `POST /start` → wait 4 real minutes of simulated time →
`travel()` 3 hours → `POST /start` (resume) → wait 6 minutes → `POST /end` — and read the
result from the session as the endpoints leave it. A test that hand-seeds
`interview_session_live_periods` rows and sums them proves only that addition works; it
cannot fail on a wrong resume decision because the resume decision is never exercised. Do not
accept a version of this test that constructs period rows directly.

- [x] **2.1 RED** — `tests/Feature/.../SessionLiveDurationAccumulationTest.php` (or the
      project's C11/C9-equivalent tier): the 4-min / 3h-gap / 6-min scenario above, driven
      entirely through `POST /start` (issue), `travel()`, `POST /start` (resume), `travel()`,
      `POST /end`, reading `InterviewSession::liveSeconds()` (or the resource field once wired)
      at the end. Run against the current, unwired controller and confirm it fails — record
      the **actual** value observed (expect: no accumulation exists yet, so the assertion
      fails outright — capture what it actually returns, do not assume).

---

## Phase 3 — The clock and its two writer sites (D2, D4)

Req: `interview-session` "A live session records when it became live, at both sites that
grant it"

- [x] **3.1** — `api/app/Support/Interview/SessionLiveClock.php`: `open(InterviewSession
      $session, ?string $providerRef): void` and `close(InterviewSession $session, string
      $reason): void`. `close()` is a no-op when nothing is open (makes `pending → error`
      free). These are the **only** writers of a period row — no inline arithmetic anywhere
      else touches `interview_session_live_periods`.
- [x] **3.2** — `InterviewController.php:768` (`handleIssuePending`): add `started_at ??=
      now()` and `SessionLiveClock::open()`, inside the existing `DB::transaction()` at
      `:765` — same transaction as the `provider_session_ref`/`status='in_corso'` write, not
      a second one.
- [x] **3.3** — `InterviewController.php:723` (`handleResumeInCorso`): add `started_at ??=
      now()` (a no-op for any row that truly resumed, per D2's `??=`), `SessionLiveClock::close('resume')`
      placed **beside** `harvestOutgoingTranscript()` at `:704` — not nested inside its
      `$oldRef !== null` guard, so a null-ref row still closes its period — then
      `SessionLiveClock::open()` inside the `(c)` transaction at `:721`. Confirm the close
      happens **before** the `(c)` transaction, not after: if `(c)` fails, the genuinely-ended
      stretch must stay closed rather than be discarded by a later failed write.
- [x] **3.4** — `InterviewController.php:344` (`/end`): `SessionLiveClock::close('end')`
      alongside the existing `ended_at = now()` write.
- [x] **3.5** — `InterviewController.php:975` (`markSessionError`): `SessionLiveClock::close('error')`
      inside its existing best-effort `try`. Docblock/comment states the known residual named
      in D4: a resume whose `issue()` throws never reaches teardown, so the old provider
      session may keep billing to its ceiling while the recorded period closes at the moment
      the failure was detected — a bounded, disclosed under-count, not papered over.
- [x] **3.6** — Docblock on `create_interview_sessions_table.php:27`: `started_at` is the
      first live moment, write-once; the pair with `ended_at` is a span and MUST NOT be read
      as a duration.

---

## Phase 4 — GREEN: the crux, and the invariant that protects it (D5)

Req: `interview-session` "Recorded duration is accumulated live time, not wall-clock span";
"InterviewSession tenant model — LOCKED status enum"

- [x] **4.1 GREEN** — `InterviewSession::liveSeconds(): ?int` on the model: sum of
      `ended_at − started_at` over **closed** periods only; `null` when there are none. Open
      periods contribute nothing and are excluded — mirrors `operator-participant-visibility`
      D4: clamping an open period with `now()` reports weeks for an abandoned tab.
- [x] **4.2 — RESOLVED via D4a (design amendment).** Was BLOCKED: `close()` stamping raw
      `now()` at discovery time reproduces the "gap counted" failure whenever the resume
      request itself arrives late (proven by direct execution: 11400s, not 600s — the
      design's own math did not hold). Escalated; the orchestrator recorded **D4a**: the
      close boundary is `min(now(), period.started_at + provider_max_seconds)`, resolved
      from `App\Support\AvatarTemplates\ProviderFieldSpecs` (`HEYGEN_MAX_SECONDS = 1200`,
      `TAVUS_MAX_SECONDS = 3600`), overridden by the org's active `AvatarTemplate` config
      when it applies to the session's provider. Implemented in `SessionLiveClock::close()`.
      Re-ran 2.1: **GREEN at 1560s** (1200s capped first stretch + 360s real second stretch),
      derived in the test from the resolved cap, never hardcoded. See `design.md` D4a for the
      full rationale, the `MAX_DURATION_REACHED` production evidence, and the rejected
      alternative (leaving `now()` and lowering the test's expectation instead).
- [x] **4.3 RED** — Invariant test: attempt to `SessionLiveClock::open()` a session that
      already has an open period — assert the **PostgreSQL partial unique index** rejects the
      second row (a real DB constraint violation, `tests run on PostgreSQL` per `phpunit.xml:57`),
      not a check inside the clock class. Temporarily stub the index away (or open two period
      rows directly bypassing the clock) to confirm the test can actually fail before trusting
      it green.
      **4.3 GREEN** — Confirm the real migration's index rejects the double-open as written.

---

## Phase 5 — Mutation check on the crux (mandatory, not optional)

Req: `interview-session` "Recorded duration is accumulated live time, not wall-clock span"

The design states a wrong cost number is worse than none because nobody questions it — that
claim is only true if 2.1 can actually catch a wrong number. Prove it can, on both plausible
wrong implementations, then restore.

- [x] **5.1** — Re-run under D4a. Temporarily replaced `liveSeconds()`'s accumulation with
      **leave-alone span** semantics (`ended_at − started_at` on the outer session, ignoring
      periods — note: the SESSION-level columns are never cap-bounded, only period rows are,
      so this mutation is unaffected by D4a). Re-ran 2.1. Confirmed it **fails**: actual value
      **11400** (the 3-hour gap counted in full).
- [x] **5.2** — Re-run under D4a. Temporarily replaced `liveSeconds()` with
      **reset-on-resume** semantics (only the last closed period counts). Re-ran 2.1.
      Confirmed it **fails**: actual value **360** (the first stretch discarded).
- [x] **5.3** — Reverted to the accumulation implementation from 4.1. Confirmed byte-identical
      to the pre-mutation file via `md5sum` + `diff` (both empty/matching). Re-ran 2.1:
      **GREEN at 1560** — the correct value, distinct from BOTH mutation values (11400,
      360) and from the original raw-`now()` implementation's own failure value (11400,
      identical to mutation 5.1 — expected, since D4 was mathematically indistinguishable
      from leave-alone for a late-arriving resume). All three values distinct: 11400 / 360 /
      1560 — the guard was not weakened by the amendment.

---

## Phase 6 — Plain path, absence, exits, re-offer

Req: `interview-session` "A live session records when it became live, at both sites that
grant it"; "An absent recorded duration is never coerced to zero"

- [x] **6.1 RED → GREEN** — End-to-end, plain path: a `/start` that reaches the provider
      persists a non-null `started_at` **and** one open period, asserted through the endpoint
      (not a factory). RED-first against the pre-Phase-3 controller if not already covered by
      2.1/4.2; otherwise confirm this is already proven and note where.
- [x] **6.2 RED → GREEN** — Absence: a session left `pending` (e.g. a `429 provider_busy`)
      has no `started_at`, no period row at all, and `liveSeconds()`, `duration_seconds`,
      cost, and elapsed are all **absent** — never `0`. Assert absence, not falsiness.
- [x] **6.3 RED → GREEN** — Exits: each of the three exits (`/end`, `markSessionError`,
      resume) closes the open period **exactly once** with the correct `closed_reason`
      (`end`, `error`, `resume`). Include the `/end` 409 idempotency guard: a second `/end`
      call closes nothing a second time (assert by re-reading the period row's `ended_at`
      value is unchanged, not by a call-count expectation).
- [x] **6.4 RED → GREEN** — Re-offer (D6): `ResetSessionForRetry` deletes the attempt's
      utterances but **keeps** its periods and `started_at` unmodified; the next `/start`
      opens a **second** stretch through `:768`. Confirm `RecoverFailedParticipantTest.php:213`
      (`participants.started_at` untouched on every path — a different column, a different
      guard) stays green unmodified.
- [x] **6.5** — `api/app/Actions/InterviewSession/ResetSessionForRetry.php`: add a comment
      stating the deliberate choice (D6) — periods and `started_at` survive a reset because
      the minutes were spent even though the words must not be scored, the same judgement
      already applied to `error_count`'s survival.
- [x] **6.6 (D4a addendum)** — The cap is a CEILING, never a FLOOR: a stretch that closes
      normally through `/end`, well inside the provider ceiling, records its real, uncapped
      duration unchanged. `SessionLivePeriodExitsTest.php` — 7 real minutes on a HeyGen
      session (1200s ceiling), asserted `liveSeconds() === 420`, never rounded up toward the
      cap.

---

## Phase 7 — Consumers move onto `liveSeconds()` (D3 — contradicts the proposal's "Unchanged")

Req: `interview-session` "Recorded duration is accumulated live time, not wall-clock span";
"An absent recorded duration is never coerced to zero"

**The proposal marks `SessionCostEstimator` and `ParticipantInterviewAggregator` "Unchanged".
The design explicitly contradicts that** (D3, Assumptions #3): left untouched, both would
keep computing `ended_at − started_at` — the exact wrong number this change exists to
prevent. Do not skip these as out-of-scope on the proposal's authority; the design supersedes
it.

- [x] **7.1 RED → GREEN** — `api/app/Services/Proctoring/SessionCostEstimator.php:39`: the
      subtraction is replaced with `liveSeconds()`. Existing `SessionCostEstimatorTest.php:24`
      (hand-writes `started_at`/`ended_at`) is repaired to hand-write a **closed period**
      instead (or use the new factory `->ended()` state) — not left asserting the span. A
      resumed session's cost is priced on live minutes, not on the span across the gap.
- [x] **7.2 RED → GREEN** — `api/app/Services/Admin/ParticipantInterviewAggregator.php:73-80`:
      same replacement. `ParticipantInterviewAggregatorTest.php` (10 sites) repaired the same
      way — named states, not restored defaults.
- [x] **7.3 RED → GREEN** — `api/app/Http/Resources/Admin/SessionSummaryResource.php:28-30`
      and `SessionReviewResource.php:75-82`: `duration_seconds` reads `liveSeconds()`.
      `SessionReviewTest.php:64, 100, 195` repaired to named factory states; contract shape
      (field names, types, nullability) stays unchanged.
- [x] **7.4** — `api/app/Http/Controllers/Api/SessionReviewController.php` and the
      aggregator's session load: add `->with('livePeriods')`. Ordering (`orderByDesc('started_at')`)
      stays exactly as written — no ordering change (D10).
- [x] **7.5 RED → GREEN** — Query-count **invariance**: the aggregator already has a
      query-count invariance guard in its suite (per design) — extend the same discipline to
      the session review list. Assert the query count does not grow with the number of
      sessions/periods (N+1 guard for the new eager load).

---

## Phase 8 — Ordering stays deterministic through an absent value (D10)

Req: `interview-session` "Ordering by recorded start remains deterministic when the value is
absent"

- [x] **8.1 RED → GREEN** — `GET /api/participants/{id}/sessions` orders by a populated
      `started_at`; a resume does **not** move a session up the list (D2's write-once
      guarantee, exercised end to end). Repeated reads of a NULL-start mix (two `pending`
      sessions, both absent) return an identical order across calls — the `id` tiebreaker,
      not incidental row order.
- [x] **8.2** — Confirm (do not silently accept) PostgreSQL's `DESC` **NULLS FIRST** behaviour
      for `pending` sessions is disclosed in this suite as today's behaviour, deterministic
      through the tiebreaker, and deliberately unchanged — no `NULLS LAST` added.

---

## Phase 9 — Fixtures stop synthesizing what production does not write (D8)

Req: `interview-session` "Test fixtures must not synthesize a start production would not
write"

**This is the third time this defect class has appeared on this project** — 1-based
`position` fixtures hid the `question_index` off-by-one for months (`interview-question-index-offset`).
`InterviewSessionFactory.php:40` currently defaults `started_at => now()->subMinutes(10)`,
which is exactly why the whole suite has been green over a field the real path never writes.
**Existing tests are repaired by NAMING THEIR STATE — never by restoring the default.**

- [x] **9.1 RED → GREEN** — New test: a factory-built `InterviewSession` in its default state
      is confirmed matching production's INSERT byte-for-byte in field set. Properly RED-first
      confirmed: the D8 factory was stashed (swapped for the git-`HEAD` pre-change version via
      `git show HEAD:...`), the test run in isolation, and failed for the right reason —
      `Expected 'pending' / Actual 'ended'` — then the D8 factory was restored (`diff` against
      the pre-stash copy confirmed byte-identical) and the suite re-run GREEN.
      `pending`, with **no** `provider_session_ref`, **no** `started_at`, **no** `ended_at`,
      **no** `ended_reason` — matching the real `/start` INSERT (`InterviewController.php:642-650`)
      byte-for-byte in field set, not just in `status`. Run against the current factory;
      confirm it fails (`started_at` is currently non-null).
- [x] **9.2 GREEN** — `InterviewSessionFactory.php:40`: default becomes the production INSERT
      shape. Add three explicit states: `->live()` (`in_corso` + one open period),
      `->ended(int $seconds)` (`completed` + one closed period + `started_at`/`ended_at` set
      consistently), `->resumed(int $first, int $gap, int $second)` (two closed periods with
      a gap between them, matching the shape 2.1 exercises through the real endpoints).
- [x] **9.3** — New test: a test that asserts a duration, cost, or start-ordering **cannot**
      be satisfied by the fixture default alone — it must use `->live()`/`->ended()`/`->resumed()`
      or the real endpoint. (Mirrors the spec scenario "A duration assertion cannot pass on
      the fixture default alone.") Confirm this fails if attempted against the bare default.
- [x] **9.4** — Repair every existing test that hand-writes `started_at`/`ended_at` and
      asserts a duration or cost by **naming the state it was relying on**:
      `Feature/C11/SessionCostEstimatorTest.php`, `Unit/Services/Admin/ParticipantInterviewAggregatorTest.php`
      (10 sites), `Feature/Admin/AdminParticipantDetailAggregatesTest.php`,
      `Feature/C11/SessionReviewTest.php`, `Unit/.../InterviewSessionModelTest.php`. Each
      becomes a **stronger** assertion than before — the state it depends on is now written
      down explicitly, not implied by a default. Confirm none of these tests were quietly
      weakened (e.g. dropped assertions) to make them pass.
- [x] **9.5** — Confirm `Feature/Demo/TeardownSelectivityTest.php:61` stays green unmodified
      — demo rows keep a start time whatever Phase 10 does to the duration shape.

---

## Phase 10 — Demo seeder stops pinning to the HeyGen ceiling (D9)

Req: none directly (demo fixture, not product behaviour) — guarded by
`Feature/Demo/TeardownSelectivityTest.php` and `DemoDatasetValidator`

- [x] **10.1** — `api/app/Support/Demo/DemoWriter.php:411-412`: stop writing a flat
      `addMinutes(20)` for every session (the HeyGen ceiling — exactly why 28 synthetic rows
      read as measurements). Replace with a **deterministic** per-competency length derived
      from `position`, comfortably below 1200s (seeders are re-run and `DemoDatasetValidator`
      asserts invariants — randomness is not available). The marker half (`provider_session_ref`
      starting with `DemoMarker::PREFIX`, `:408`) is **unchanged** — demo rows stay
      identifiable by value, not by shape.
- [x] **10.2** — One demo participant gets a **resumed** session — two periods with a gap —
      so the demo exercises the shape the product now supports and an operator can see what a
      resumed interview looks like.
- [x] **10.3** — Confirm periods cascade on session delete (FK cascade from Phase 1); demo
      teardown needs no edit. Re-run `TeardownSelectivityTest.php`; GREEN unmodified.
- [x] **10.4** — Re-run `DemoDatasetValidator`'s invariant checks; confirm the varied,
      deterministic durations still satisfy them.

---

## Phase 11 — Spec and doc hygiene (design Open Questions)

Req: `interview-session` — supersedes `spec.md:1454-1456`

- [x] **11.1** — Reword `interview-session/spec.md:1454-1456`, which still defines cost as
      derived from the `started_at`/`ended_at` **duration** (the span). The delta in this
      change supersedes it in substance but the archive merge must reword the sentence to
      *recorded live duration* / `liveSeconds()` — otherwise the archived spec teaches the
      span again, the exact "the comment outlived the defect" failure already paid for once
      on `question_index` (`interview-question-index-offset` D6/D7 precedent).
- [x] **11.2** — Confirm `create_interview_sessions_table.php:27` docblock (3.6) and any
      remaining comment referring to `ended_at − started_at` as "the duration" are corrected
      repo-wide. Sweep `api/app`, `api/tests`, `api/database` for the phrase; confirm zero
      live occurrences outside historical/past-tense context.

---

## Phase 12 — Coverage gate and full suite (may not be ticked without the number)

- [x] **12.1 — FULLY GREEN after D4a.** Ran `cd api && ./vendor/bin/pest --parallel` (full,
      unfiltered). **2097 tests, 2092 passed, 0 failed, 0 errors, 5 skipped.** Baseline on
      `develop` was 2062/2057/5/0; net for this change: +35 tests, +35 passing, 0 failures.
      `SessionLiveDurationAccumulationTest` (the crux) is GREEN at 1560s, the D4a-resolved
      value.
- [x] **12.2** — Ran `./vendor/bin/pest --coverage --min=85 --parallel`. **Gate PASSED.
      Overall: Classes 72.50% (174/240), Methods 82.26% (547/665), Lines 94.21% (6475/6873).**
      Correctness-critical zone, all 100% lines: `InterviewSession` (9/9 methods),
      `InterviewSessionLivePeriod` (2/2), `SessionLiveClock` (4/4 — including
      `resolveMaxSeconds()`'s platform-default, org-override, and different-provider branches),
      `SessionCostEstimator` (1/1), `ParticipantInterviewAggregator` (1/1).
      `InterviewController` 55% methods/91.62% lines (uncovered methods are pre-existing,
      unrelated to this change's 4 wiring sites, all of which ARE exercised).

---

## Phase 13 — Git Flow

**Deliberately left unticked by `sdd-apply`** — branching/PR/merge/wrapper-pointer are Git
Flow operations owned by the orchestrator, not the phase executor.

- [ ] **13.1** — `api`: branch `feature/interview-session-started-at` from `develop`. Commit
      the migration, model, clock, controller wiring, consumer changes, fixtures, demo
      changes, and tests as this single PR.
- [ ] **13.2** — Open the PR against `api`'s `develop`. CI green: Pint, PHPStan, full Pest
      suite, coverage gate.
- [ ] **13.3** — Merge. New table + new field semantics, no breaking shape change —
      MINOR-level per `docs/git-flow.md`'s SemVer rule (new capability, backward compatible);
      version bump itself happens on the next `release/*` branch.
- [ ] **13.4** — Wrapper: bump the `api` submodule pointer to the merged commit. Conventional
      commit, e.g. `chore(api): pin interview-session-started-at`.

---

## Phase 14 — Release note (load-bearing, not ceremonial)

Req: none directly — Delivery section of `design.md`

- [ ] **14.1** — Write the release note. No `openapi.json` cycle (field keeps its type and
      nullability), so this note is the **only** signal of the change. It MUST state:
      1. `duration_seconds` changes **meaning** — from wall-clock span (`ended_at − started_at`)
         to accumulated live time — not shape or type.
      2. It starts carrying a real, non-null value only for interviews **run after the
         deploy**.
      3. Pre-deploy interviews stay absent by design (D7 — no backfill) — the dashboards are
         **NOT retroactive**. Eight production rows never gain a start; this is deliberate,
         not a gap to be filled later.
      4. Resume behaviour: a resumed interview's cost/duration reflects live minutes only,
         never the abandonment gap.
      5. **(D4a)** An abandoned stretch's recorded duration is a bounded UPPER ESTIMATE, capped
         at the provider's own session ceiling (1200s HeyGen / 3600s Tavus, or the org's
         configured template value if lower) — never a claim that the candidate was observed
         active for that whole span. This is a disclosed, intentional residual, not a bug:
         BEAI has no signal for when an abandoned stretch truly stopped short of the provider's
         own timeout (production evidence: `MAX_DURATION_REACHED`). A future change wiring the
         client's `session.disconnected` event (handler already exists in
         `frontend/app/providers/heygen.ts`) could tighten this; it is out of scope here.
      Same doctrine as `interview-question-index-offset` D8: a shape-versioned contract
      cannot signal a value-semantics change, so this note carries the disclosure the contract
      itself cannot.

---

## Phase 15 — Post-deploy verification

**Deliberately left unticked by `sdd-apply`** — live-production operational step requiring
access this implementation session does not have.

- [ ] **15.1** — Post-deploy: query production and confirm real (non-demo) sessions created
      after the deploy record at least one `interview_session_live_periods` row, and that a
      completed one has a non-null `liveSeconds()`-derived duration and cost — the first
      measurable provider cost the platform has produced. Cross-check against
      `provider_session_ref` where the provider's own dashboard exposes a per-session figure,
      if available.
- [ ] **15.2** — Confirm the eight pre-existing non-demo sessions with NULL `started_at`
      remain NULL — no backfill occurred (D7), and the release note (Phase 14) has been
      distributed so dashboards are not misread as retroactive.
