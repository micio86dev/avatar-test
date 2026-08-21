# Design: Record a Session's Live Time, Not the Span Around It

Store mode: hybrid. Engram mirror: `sdd/interview-session-started-at/design`.
Inputs: `proposal.md`, `specs/interview-session/spec.md`.

## Technical Approach

The spec settled the semantics: **recorded duration is accumulated live time**, the gap
between stretches is never counted, and no historical row is backfilled. One
`started_at`/`ended_at` pair cannot express two stretches, so the design's real work is
choosing where the second stretch lives.

Four moves:

1. **A stretch becomes a row** (D1). `interview_session_live_periods` records one
   `[started_at, ended_at]` per period the session held a live provider session.
2. **`interview_sessions.started_at` is stamped write-once at the first `in_corso`** and
   keeps the meaning `SessionReviewController:62` already assumes — *when this competency
   began* (D2). The pair `ended_at − started_at` stops being the duration and is never
   read as one again (D3).
3. **Three seams open and close stretches** — the two `in_corso` sites and the three exits
   from `in_corso` — through one shared clock, never inline arithmetic (D4, D5).
4. **The fixtures stop inventing a start** (D8) and the demo seeder stops pinning every
   interview to the HeyGen ceiling (D9).

Scope is `api` only. Re-verified: `frontend` reads the field nowhere; `backoffice` reads
`started_at` and `duration_seconds` read-only at `SessionList.vue:31`,
`useSessionReview.ts:45` and the elapsed panel. No payload **shape** moves, so no
`openapi.json` cycle — but `duration_seconds` changes **meaning**, which is a release-note
obligation (see Delivery).

---

## D1 — THE CRUX: a stretch is a row, not a second column pair and not a counter

Three exits from `in_corso` exist (`/end` `:343-346`, `markSessionError` `:975`, and resume
`:704-725`), and resume is unbounded — a candidate may reconnect any number of times. The
storage shape must therefore hold *N* stretches, not two.

| Option | What it costs | Verdict |
|---|---|---|
| `started_at` + `resumed_at` / second pair | Holds exactly two stretches. Resume is unbounded today; the third reconnect silently overwrites the second | Rejected |
| `live_seconds` counter on `interview_sessions`, `started_at` = current stretch | Cheapest diff. But it **persists a duration**, which `interview-session/spec.md:1458-1460` ratified against; and it is unfalsifiable — an accumulate that runs twice, or not at all, produces a plausible number with no evidence of either. This change exists to produce a figure that will settle open decision #7; a figure nothing can check is the failure mode, not the cost | **Rejected** |
| Derive stretches from `utterances.ts` | Silence is billed and silence has no utterance. `harvestOutgoingTranscript()` also deletes and re-inserts this session's slice (`:944-954`), so the row set is not a clock | Rejected |
| One `InterviewSession` row per stretch | Forbidden by `UNIQUE(participant_id, competency_code)`, and the row's own docblock (`create_interview_sessions_table.php:13-17`) states the opposite invariant | Rejected |
| **A child table of live periods, keyed to the session and to `provider_session_ref`** | One migration, one model, one shared clock. Duration stays **derived** (a sum over observations), each stretch is attributable, and a double-open is a constraint violation rather than a silent double count | **Chosen** |

```
interview_session_live_periods
  id, organization_id (FK cascade), interview_session_id (FK cascade),
  provider_session_ref  string|null   -- the ONLY key shared with the provider's own bill
  started_at            timestampTz NOT NULL
  ended_at              timestampTz NULL      -- NULL ⇔ the stretch is still live
  closed_reason         string|null  ∈ {resume, end, error}
  timestamps
  INDEX (organization_id, interview_session_id)                       -- D22 org-lead
  UNIQUE (interview_session_id) WHERE ended_at IS NULL                -- partial, D5
```

`provider_session_ref` is not decoration. Neither provider exposes a per-session billed
amount, so the ref is the only handle by which our number can ever be reconciled against
HeyGen's or Tavus's own record. `closed_reason` answers the first question anyone will ask
of a surprising total — *which stretches were cut short by a reconnect?*

### Why this survives `single-session-interview`

That change makes **one provider session span many competencies**. A period is keyed by the
ref, not by the competency, so a ref that spans competencies yields periods that still sum
to that ref's true lifetime, and a participant-level cost can be reconciled `DISTINCT ref`
against one provider bill. Nothing in the table changes; only *who* opens and closes
periods. The counter column is the option that would have to be rebuilt: per-competency
seconds can only be trusted if you already believe the slices partitioned perfectly, and
once one ref covers five rows there is nothing left to check that belief against. **That is
the ground on which the counter was rejected, alongside the persisted-duration rule.**

---

## D2 — `started_at` is the FIRST live moment, written once

| Option | Consequence | Verdict |
|---|---|---|
| Reset on every resume | A reconnect jumps the session to the top of the operator's newest-first list because the candidate reloaded a tab | Rejected |
| Leave NULL, derive from the earliest period | Honest, but `SessionReviewController:62` orders on the column in SQL and would need a join or a subquery for an ordering that works today | Rejected |
| **Stamp at the first `in_corso`, never overwrite** | The column answers exactly what its consumers ask: *when did this competency begin* | **Chosen** |

Written at **both** `in_corso` sites as `started_at ??= now()`, not `= now()`. The `??=` is
load-bearing: `handleIssuePending` (`:768`) is **not** only the first-stretch path —
`ResetSessionForRetry:50-53` returns an already-lived session to `pending`, so a re-offered
or operator-recovered competency reaches `:768` with a start already recorded.

`ended_at` (`:344`) is unchanged. **Consequence, stated plainly:** `ended_at − started_at`
is now a wall-clock span that includes abandonment gaps. It is not the duration and must
never again be read as one — which is D3.

---

## D3 — One definition of duration; four subtractions collapse onto it

The subtraction exists four times today: `SessionCostEstimator:39`,
`SessionSummaryResource:28-30`, `SessionReviewResource:75-82`,
`ParticipantInterviewAggregator:73-80`. Four copies of a formula that is now wrong is four
chances to keep it.

`InterviewSession::liveSeconds(): ?int` — the sum of `ended_at − started_at` over the
session's **closed** periods; `null` when there are none. Open periods contribute `0` and
are excluded, mirroring `operator-participant-visibility` D4 verbatim: clamping with `now()`
reports weeks for an abandoned tab. `null`, never `0`, per the spec's absent-not-zero
requirement.

The proposal's claim that `SessionCostEstimator` and `ParticipantInterviewAggregator` are
**unchanged** does not survive the accumulate decision, and this design contradicts it: left
untouched they would compute the span, which is the precise wrong number this change exists
to prevent. Both are edited.

N+1 is the price. `SessionReviewController::index` and the aggregator's session load both
gain `->with('livePeriods')`; the aggregator already has a query-count **invariance** guard
in its suite, and the same discipline extends to the session list.

---

## D4 — The two `in_corso` sites, and why they differ

| Site | Writes today | Adds |
|---|---|---|
| `:768` `handleIssuePending` | `provider_session_ref`, `status='in_corso'`, participant stamps | `started_at ??= now()`; **open** a period — inside the same `DB::transaction()` (`:765`) |
| `:723` `handleResumeInCorso` | `provider_session_ref`, `status='in_corso'` | `started_at ??= now()` (a no-op for any row that truly resumed); **close** the outgoing period at step (b); **open** the new one inside the existing txn (`:721`) |

They differ for one reason only: **resume is the sole site that can find a stretch already
open.** The plain path arrives from `pending`, which by D5's invariant holds no open period.

The close reuses the seam `harvestOutgoingTranscript()` already occupies (`:704`) — the same
event, stated twice: *the outgoing stretch is final, so harvest its words and stop its
clock.* It is placed **beside** that call, not nested inside its `$oldRef !== null` guard: a
period is BEAI's own observation and must close even when no provider ref survives, or a
null-ref row leaks an open period forever and loses its first stretch from every sum.

Closing before the `(c)` transaction is deliberate. If `(c)` fails (`db_error` + teardown
compensation), the stretch that genuinely ended stays correctly closed. The reverse order
would discard a real observation because a later, unrelated write failed.

The third exit, `markSessionError` (`:975`), closes with `closed_reason = 'error'` inside
its existing best-effort `try`. **A resume whose `issue()` throws never reaches teardown**,
so the old provider session may keep billing to its ceiling while we record only up to the
moment we learned it was dead. That under-counts, and it is recorded here as a known,
bounded residual rather than papered over with an invented end time.

One owner for all of it: `App\Support\Interview\SessionLiveClock::open()/close()`, next to
`CompetencyTally` — the repo's existing home for shared interview definitions. `close()` is
a no-op when nothing is open, which is what makes `pending → error` free.

**Amended by D4a, below.** "Stop its clock" as written here meant stamping raw `now()` at the
moment of discovery. That instruction is what apply implemented, and it is what apply's own
crux test caught as wrong — proven by direct execution, not assumed. D4a is the correction.

---

## D4a — AMENDMENT (post-apply): the close boundary is cap-bounded, not `now()`

**Recorded during `sdd-apply`, after the crux test (Phase 2) was implemented exactly as D4
specifies and produced ~11 400s — the explicitly-rejected "gap counted" failure — for the
scenario D4's own acceptance criterion names. This is a design defect, not an apply defect:**
apply implemented "stop its clock" at discovery time verbatim, and the design's own math
does not hold for a resume request that itself arrives late, which is the ordinary case for
genuine abandonment.

**What D4 got wrong.** D4 assumed BEAI can learn when a stretch actually stopped being live.
It cannot. On abandonment there is no signal at all: the browser is gone, and the only event
that ever arrives is the resume request, hours later. Stamping `now()` at that request
therefore always regresses to the wall-clock span the periods table exists to replace,
whenever discovery is late — which is precisely when it matters most.

**What the crux test's original 600s expectation also got wrong.** It assumed the provider
session ended when the candidate stopped talking. It did not. **Production evidence**: a
real candidate's browser console emitted `[SDK:SESSION_STOPPED] Server stopped session,
reason: MAX_DURATION_REACHED`. Nothing tears the outgoing provider session down on
abandonment — `handleResumeInCorso` only tears it down when the candidate reconnects, and
`/end` only runs when they finish. The abandoned session therefore stayed live and BILLABLE,
provider-side, until the provider's own ceiling. The true cost of that stretch was never the
candidate's last-spoken minute; it was however long the provider kept billing before its own
timeout fired.

**The fix.** `SessionLiveClock::close()` stamps:

```
min(now(), period.started_at + provider_max_seconds)
```

`provider_max_seconds` resolves per the session's `provider` column against
`App\Support\AvatarTemplates\ProviderFieldSpecs`: `HEYGEN_MAX_SECONDS = 1200`,
`TAVUS_MAX_SECONDS = 3600`. If the organization's active `AvatarTemplate` configures a lower
`maxSessionDurationSec` (HeyGen) / `maxCallDurationSec` (Tavus) — and its `provider` matches
the session's — that value wins: it is what was actually sent to the provider on `issue()`,
so it is the real ceiling that session's provider call was bound by. A template belonging to
a different provider, or no active template, falls back to the platform constant.

**Why this is honest rather than a fudge:**
- The provider terminates at its own ceiling by contract — a live period cannot legitimately
  exceed it. This is the provider's own limit, not a tuning constant reverse-engineered from
  a test's expected number.
- Stamping raw `now()` records hours of billing that could not physically have occurred —
  worse than an honest unknown, because it looks measured.
- We genuinely do not know the candidate stopped at minute 4. The ceiling is the honest
  UPPER BOUND on what could have been billed, never a guess at the true value. Over-counting
  within a bound we can name and defend is acceptable; over-counting with no bound is not.
- **Symmetric with D4's already-accepted bounded UNDER-count on the error exit** (a resume
  whose `issue()` throws is recorded only up to detection, never invented forward). D4a is
  the mirror-image bounded OVER-count on the ordinary exits — one class of honest bound, used
  in both directions, rather than one accepted and one denied.

**The cap is a CEILING, never a FLOOR.** A stretch that closes normally, well inside the
ceiling — the ordinary `/end` case — records its real, uncapped duration unchanged. Nothing
about this amendment touches the common path; it only bounds the pathological one.

**Rejected alternative: leave D4's raw `now()` as written and revise only the crux test's
expected number down to whatever `now()` happens to produce.** Rejected because the number
`now()` produces is not a property of the interview — it is a property of when the candidate
happened to come back, which is exactly the "gap counted" defect this table was built to
retire. A test that asserted "whatever `now()` gives you" would assert nothing.

**Disclosed residual, not a task here.** BEAI could learn the TRUE stop time if the client
reported its `session.disconnected` event — the handler already exists in
`frontend/app/providers/heygen.ts`, unused for this purpose. Wiring it to a heartbeat/ping
endpoint that `SessionLiveClock::close()` could read instead of the cap is a separate,
future change. Until it ships, a stretch that hits the cap is a disclosed UPPER ESTIMATE of
an abandoned stretch, never a claim of observed candidate activity — record this note so the
gap between "recorded" and "true" duration on an abandoned stretch is never filed as an
undiscovered bug.

**Crux test consequence.** For 4 min live → 3 h gap → resume → 6 min live on a HeyGen session
at the 1200s platform ceiling (no avatar template configured): `1200 + 360 = 1560`, not 600.
The test derives this from the resolved cap, never a hardcoded `1560` — it asserts the
BEHAVIOUR (cap-bound first stretch + real second stretch), not a number that happens to match
today's constant.

---

## D5 — At most one open period, enforced by the schema

`UNIQUE (interview_session_id) WHERE ended_at IS NULL` — a PostgreSQL partial index, issued
via `DB::statement()` (the fluent builder cannot express it). Tests run on PostgreSQL
(`phpunit.xml:57`), so it is exercised as written.

A double-open — the one bug that silently doubles the cost figure — becomes a constraint
violation instead of a plausible number. Rejected alternative: enforce it in the clock class
only. Discipline in one class is not an invariant; the next writer of a status transition
does not read that class.

---

## D6 — A re-offer discards the transcript and keeps the billed time

`ResetSessionForRetry` deletes the attempt's utterances because BARS must not score a
conversation that mixes two attempts. It does **not** delete that attempt's periods, and it
does not clear `started_at`. The minutes were spent; the words must not be scored. Two
different questions, two different answers — and the class docblock's own precedent
(`error_count` deliberately survives the reset) is the same judgement applied to a different
column.

---

## D7 — No backfill; the eight NULL rows stay absent

Settled upstream, restated for its consequence: production's eight non-demo sessions keep no
recorded start and therefore no recorded duration, forever. `created_at` is a proxy, and a
proxy written into an observation column is indistinguishable from a measurement the moment
it lands. The first trustworthy cost figure is measured from the first interview after
deploy — which the release note must say, so nobody reads the dashboards as retroactive.

---

## D8 — The factory stops synthesizing a start

`InterviewSessionFactory` has exactly **one** consumer (`SessionReviewTest.php:58`, via
`reviewSession()`, which already hand-writes `started_at`) — so the default is cheap to fix
and was never carrying the suite. It is still the same defect class that hid the
`question_index` off-by-one behind 1-based fixtures: a fixture asserting a state production
never produces.

The default becomes production's INSERT (`:642-650`): `status => 'pending'`, no
`provider_session_ref`, no `started_at`, no `ended_at`, no `ended_reason`. (`'ended'`, the
current default, is not even a member of the LOCKED enum.) Three explicit states replace it:

- `->live()` — `in_corso` + one **open** period
- `->ended(int $seconds)` — `completed` + one **closed** period + `started_at`/`ended_at`
- `->resumed(int $first, int $gap, int $second)` — two closed periods with a gap between them

Existing tests that hand-write `started_at`/`ended_at` and assert a duration or a cost
(`SessionCostEstimatorTest`, `ParticipantInterviewAggregatorTest`,
`AdminParticipantDetailAggregatesTest`, `SessionReviewTest`, `InterviewSessionModelTest`)
are repaired by **naming the state they were relying on**, never by restoring a default.
Each becomes a stronger assertion than before, because the state it depends on is now
written down. This fixture migration is the bulk of the diff and it is mechanical.

---

## D9 — The demo seeder varies its durations and stays marked

`DemoWriter.php:411-412` writes a flat `addMinutes(20)` for every session — exactly the
HeyGen ceiling, which is what made 28 synthetic rows read as measurements.

Both halves change, and the marker half matters more: the reliable discriminator is
`provider_session_ref` starting with `DemoMarker::PREFIX` (`:408`), which **stays** — so
demo rows remain identifiable by a value, not by their shape, and `TeardownSelectivityTest`
is untouched. Periods cascade on session delete, so demo teardown needs no edit.

The duration stops being pinned to the ceiling: a **deterministic** per-competency length
derived from `position` (seeders are re-run and `DemoDatasetValidator` asserts invariants —
randomness is not available), comfortably below 1200s. One demo participant gets a
**resumed** session — two periods with a gap — so the demo exercises the shape the product
now supports and an operator can see what a resumed interview looks like.

---

## D10 — `SessionReviewController:62` needs no ordering change

`orderByDesc('started_at')->orderByDesc('id')` stays exactly as written. Under D2 the column
holds the first live moment, so a resume never reshuffles the operator's list — which is the
behaviour the two-key ordering already intended and never got to exercise.

Disclosed rather than fixed: PostgreSQL sorts `DESC` **NULLS FIRST**, so `pending` sessions
(still NULL by design) sort ahead of started ones. That is today's behaviour, it stays
deterministic through the `id` tiebreaker as the spec requires, and adding `NULLS LAST`
would be an unrequested change to a live ordering contract. The only edit to this method is
D3's eager load.

---

## Data Flow

```
POST /start
 ├─ pending  → handleIssuePending :765 txn { ref, status=in_corso,
 │                                            started_at ??= now(),
 │                                            SessionLiveClock::open() }
 └─ in_corso → handleResumeInCorso
        (b) :704  harvestOutgoingTranscript(...)        ← words
                  SessionLiveClock::close('resume')     ← clock, same event, no ref guard
                  provider->teardown(old)
        (c) :721  txn { ref, status=in_corso, started_at ??= now(), clock::open() }

POST /end :343  txn { status=ended_reason, ended_at=now(), clock::close('end') }
markSessionError :975  { status=error, error_count++, clock::close('error') }

read time (no persisted duration)
  InterviewSession::liveSeconds() = Σ (ended_at − started_at) over CLOSED periods, else null
     ├─ SessionCostEstimator          → cost
     ├─ SessionSummaryResource        → duration_seconds
     ├─ SessionReviewResource         → duration_seconds
     └─ ParticipantInterviewAggregator → elapsed + cost
```

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/database/migrations/2026_08_21_180000_create_interview_session_live_periods_table.php` | **Create** | Table + org-lead index + partial unique index via `DB::statement()` (D1, D5) |
| `api/app/Models/InterviewSessionLivePeriod.php` | **Create** | `TenantModel`; belongsTo session |
| `api/app/Models/InterviewSession.php` | Modify | `livePeriods()` HasMany; `liveSeconds(): ?int` (D3); docblock states span ≠ duration |
| `api/app/Support/Interview/SessionLiveClock.php` | **Create** | `open()` / `close(reason)` — the only writers of a period. `close()` reads `App\Support\AvatarTemplates\{ProviderFieldSpecs,ActiveTemplateResolver}` to cap-bound the close timestamp (D4a) — no edit to either, read-only dependency |
| `api/app/Http/Controllers/Candidate/InterviewController.php` | Modify | `:723`, `:768` stamp + open; `:704` close; `:344` close; `:975` close (D4) |
| `api/app/Services/Proctoring/SessionCostEstimator.php` | Modify | Reads `liveSeconds()` (D3) — contradicts proposal's "Unchanged" |
| `api/app/Services/Admin/ParticipantInterviewAggregator.php` | Modify | Reads `liveSeconds()`; `->with('livePeriods')` (D3) |
| `api/app/Http/Resources/Admin/SessionSummaryResource.php` | Modify | Subtraction → `liveSeconds()` |
| `api/app/Http/Resources/Admin/SessionReviewResource.php` | Modify | `durationSeconds()` → `liveSeconds()` |
| `api/app/Http/Controllers/Api/SessionReviewController.php` | Modify | Eager load only; ordering untouched (D10) |
| `api/database/factories/InterviewSessionFactory.php` | Modify | Production-shaped default + `live()`/`ended()`/`resumed()` (D8) |
| `api/database/factories/InterviewSessionLivePeriodFactory.php` | **Create** | Closed/open states |
| `api/app/Support/Demo/DemoWriter.php` | Modify | Periods per session; varied deterministic length; one resumed participant (D9) |
| `api/database/migrations/2026_07_20_100002_create_interview_sessions_table.php` | Modify | Docblock `:27` — `started_at` = first live moment; the pair is a span, not a duration |
| `api/app/Actions/InterviewSession/ResetSessionForRetry.php` | **Unchanged** | Deliberately keeps periods and `started_at` (D6) — comment added |
| `frontend/`, `backoffice/`, `openapi.json` | **Unchanged** | Verified; no shape moves |

---

## Testing Strategy (strict TDD — RED first)

Runner: `cd api && ./vendor/bin/pest <exact-file>` while iterating; full unfiltered run
before the PR. **Never `php artisan test --filter`** — observed fabricating passes here.

| Tier | What it is responsible for proving |
|---|---|
| **Pest — the gap** | **The one that matters.** Through the real endpoints: `/start` → 4 min live → travel 3 h → `/start` (resume) → 6 min → `/end`, then assert the recorded duration equals **the resolved provider cap + the real second stretch** (D4a — 1560s for a HeyGen session at the 1200s platform ceiling with no avatar template, derived in the test, never hardcoded). It must fail on ~11 400 s (gap counted, raw `now()`) and on 360 s (first stretch discarded). Time moved with `travel()`, never hand-written rows. A companion test proves the cap is a CEILING, not a FLOOR: a stretch well inside it, closed normally through `/end`, records its real uncapped duration |
| **Pest — end to end, plain path** | A `/start` that reaches the provider persists a non-null `started_at` **and** one open period, asserted through the endpoint. Red-first against today's controller |
| **Pest — absence** | A session left `pending` (a `429 provider_busy`) has no `started_at`, no period, and `liveSeconds()`, `duration_seconds`, cost and elapsed are all **absent, never 0** |
| **Pest — invariant** | A second `open()` on a session that already has one violates the partial unique index (D5). Asserted against PostgreSQL, not simulated |
| **Pest — exits** | Each of the three exits closes the open period exactly once with the right `closed_reason`; `/end`'s 409 idempotency guard closes nothing a second time |
| **Pest — re-offer** | `ResetSessionForRetry` discards utterances, **keeps** the periods and `started_at`, and the next `/start` opens a second stretch through `:768` (D6). `RecoverFailedParticipantTest:213` stays green — `participants.started_at` untouched on every path |
| **Pest — consumers** | Cost, `duration_seconds` (both resources) and the aggregator's elapsed all read accumulated time; a resumed session's cost is priced on live minutes, not on the span |
| **Pest — ordering** | `GET /participants/{id}/sessions` orders by a populated `started_at`; a resume does **not** move a session; repeated reads of a NULL-start mix return an identical order (D10) |
| **Pest — fixtures** | A default factory session is `pending` with no recorded start; a duration assertion cannot be satisfied without a state that creates periods (D8) |
| **Pest — queries** | Query-count **invariance** across row counts for the session list and the aggregator (D3's N+1) |
| **Pest — schema/demo** | New table in `MigrationSchemaTest`; demo durations vary and sit below the ceiling; `TeardownSelectivityTest` green untouched; periods cascade on session delete |

---

## Migration / Rollout

One migration: `CREATE TABLE` + two indexes. **No backfill** (D7), so no data is rewritten
and the `interview-question-index-offset` one-way precedent does not apply here.

`down()` drops the table and is **genuinely reversible in the sense that matters**: it
returns the schema to a state the system previously occupied, and the rows it destroys never
existed before `up()`. Stated honestly: those rows exist nowhere else, so a rollback after
production traffic loses the live-time observations recorded in between — and, per D7, they
cannot be reconstructed. Code rollback is independent and safe: every consumer already
null-guards, and durations return to absent.

---

## Delivery

```
400-line budget risk: Medium
Chained PRs recommended: No
Decision needed before apply: No
```

Single `api` PR + one wrapper pointer bump. **Splitting is refused on a correctness ground,
not a size one**: any slice that stamps `started_at` before the consumers move to
`liveSeconds()` publishes the span — gaps included — as a duration, live, in the dashboards
the product owner is about to read. If a reviewer insists on a split, the only safe seam is
[production writers + consumers + D5 invariant] then [D8 fixture hygiene + D9 demo], in that
order.

Release note (no `openapi.json` cycle; `duration_seconds` keeps its type and nullability):
state that the field changes **meaning** from wall-clock span to accumulated live time, that
it starts carrying a value for interviews run after the deploy, and that pre-deploy
interviews stay absent by design. Same doctrine as `interview-question-index-offset` D8 — a
shape-versioned contract cannot signal a value-semantics change, so the note is load-bearing
rather than ceremonial.

---

## Open Questions

- [ ] **`interview-session/spec.md:1454-1456` still says cost derives from the
      `started_at`/`ended_at` duration.** The delta supersedes it in substance, but the
      archive merge must reword that sentence to *recorded live duration* or the archived
      spec teaches the span again — the exact "the comment outlived the defect" failure this
      repo has already paid for. Spec hygiene, not a design gate.
- [ ] Proposal Q4 — should cost be **comparable** across resumed and un-resumed interviews?
      Answered in the affirmative by construction here; recorded so it is a settled fact
      rather than a side effect.
- [ ] A resume whose `issue()` fails leaves the old provider session billing to its ceiling
      while we record only to the moment we detected the failure (D4). Bounded under-count,
      disclosed. Closing it would require a provider-side billing read neither vendor offers.

---

## Assumptions for user review

1. **A stretch is a row** — new child table, not a second column pair and not a counter
   (D1). This is the whole design and the one thing to push back on.
2. **`started_at` is write-once, the first live moment** (D2); `??=` because
   `handleIssuePending` is reachable with a prior stretch already recorded.
3. **`ended_at − started_at` is no longer a duration anywhere** — four subtraction sites
   collapse onto `liveSeconds()` (D3). This **contradicts the proposal's "Unchanged"**
   marking for `SessionCostEstimator` and `ParticipantInterviewAggregator`.
4. **At most one open period, enforced by a partial unique index** on PostgreSQL (D5).
5. **A re-offer keeps the billed time and discards only the transcript** (D6).
6. **No backfill; the eight production rows stay absent forever** (D7).
7. **The factory default becomes production's INSERT**, and existing duration/cost tests are
   repaired by naming their state, never by restoring a default (D8).
8. **Demo durations vary deterministically and stay marked by `DemoMarker::PREFIX`** (D9).
9. **`SessionReviewController:62` keeps its ordering**; the NULLS-FIRST placement of
   `pending` sessions is disclosed, not changed (D10).
10. **This artifact exceeds the skill's 800-word budget deliberately**, matching the register
    of the archived designs it was directed to follow.
