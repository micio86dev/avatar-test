# Proposal: Stamp `interview_sessions.started_at` on the Real Interview Path

> **Not a feature.** The schema has always declared `started_at` alongside `ended_at` and
> documented both as *"server-set"* (`2026_07_20_100002_create_interview_sessions_table.php:27,
> 82-84`). `ended_at` is written. `started_at` is not. This change supplies the missing half of
> an interval the schema already intended to hold.

## Intent

`interview_sessions.started_at` is **never written on the real interview path**. Every
production interview stores an interval with no beginning.

| Fact | Verified at |
|---|---|
| Session inserted with `status = 'pending'`, no `started_at` | `InterviewController.php:642-650` |
| Session flips to `in_corso` — **resume path** | `InterviewController.php:723` |
| Session flips to `in_corso` — **issue-pending path** | `InterviewController.php:769` |
| `ended_at` **is** stamped | `InterviewController.php:344` — `$locked->ended_at = now();` |
| Column declared nullable, no default, "server-set" | `create_interview_sessions_table.php:27, 83` |
| The **only** application writer | `Support/Demo/DemoWriter.php:411` — synthetic fixtures |

Neither `in_corso` site stamps a start time. That asymmetry — end recorded, beginning not — is
the defect.

**Two corrections to the brief.** (1) `DemoWriter.php:366` writes **`participants.started_at`**,
a different column on a different table, which *is* correctly maintained on the real path
(`InterviewController.php:776`). The sole writer of the **session** field is `DemoWriter.php:411`.
The conclusion is unchanged and the evidence is narrower than stated. (2) `started_at` **is** in
`InterviewSession::$fillable` (`InterviewSession.php:100`) — unlike `Participant`, no
direct-assignment workaround is required here.

**Why the whole Pest suite is green over a field production never writes.**
`InterviewSessionFactory.php:40` defaults `'started_at' => now()->subMinutes(10)`. Every
factory-built session has a start time, so every duration, cost, and ordering assertion passes
against a value the production path never produces. The tests were never wrong; they were never
pointed at the production writer.

**Production evidence.** Of 8 sessions belonging to non-demo participants, `started_at` is NULL
on **all 8**, while `ended_at` is present on 4. Every "measured" duration in the database — 28
sessions at exactly 20.00 minutes, min 20, max 20 — is `DemoWriter.php:412`'s
`addMinutes(20)`. Twenty minutes is exactly the HeyGen session cap, which is what made the
synthetic figure look plausible.

### Why now

| Consumer | Effect today |
|---|---|
| `ParticipantInterviewAggregator.php:73` — operator "total elapsed time" | Requires both timestamps. Shipped hours ago (`operator-participant-visibility`, api v0.27.0); it correctly reports *unknown* rather than `0`, and will report unknown for **every real interview**. The field the operator asked for never shows a number. |
| `SessionCostEstimator.php:35` — provider cost | Returns `null` with no duration. Nothing to price, ever. |
| `SessionSummaryResource.php:28-30` / `SessionReviewResource.php:77` | `duration_seconds` is always `null` on the real path. |
| `SessionReviewController.php:62` — `orderByDesc('started_at')` | **Third consumer, not previously named.** With every value NULL the session list collapses to its `id` tiebreaker; the intended ordering never applies. |

The cost consumer is the blocking one. The product owner has asked to **measure real provider
cost per interview before deciding** whether to accept the doubled concurrency a seamless
competency handover requires (`single-session-interview`, Risk 1; CLAUDE.md open decision #7).
That measurement is impossible until this is fixed.

## Scope

### In Scope

| # | Deliverable |
|---|---|
| 1 | `interview_sessions.started_at` stamped when a session becomes `in_corso`, at **both** sites (`InterviewController.php:723, 769`), inside the existing transactions |
| 2 | Resume semantics for the stamp — reset, extend, or leave alone — **decided in design** (Q1) |
| 3 | Historical rows: backfill, leave NULL, or mark — **decided in design** (Q2). If backfilled, a one-way migration with the `interview-question-index-offset` precedent's documented `down()` |
| 4 | `InterviewSessionFactory.php:40` no longer masks the production path (D3) |
| 5 | Delta spec: `interview-session` — the session-row requirement (`spec.md:29-40`) gains a *when* for `started_at` |
| 6 | Pest coverage per project policy; `strict_tdd: true` is active. Enumeration belongs to the tasks phase |

### Out of Scope

- **`participants.started_at`.** Correctly written and deliberately guarded against clobbering
  (`participant-error-recovery` D2b). Different table, different semantics, not touched.
- **`frontend` and `backoffice` code.** Verified: the frontend app reads this field nowhere —
  only its generated `openapi.json` mirror carries it. The backoffice reads it at
  `SessionList.vue:31`, `useSessionReview.ts:45`, and the elapsed panel in
  `pages/participants/[id].vue`, all read-only. They render `–` today and start rendering real
  values with no edit.
- **`openapi.json` regeneration.** The field stays a nullable timestamp; only its population
  changes.
- **`admin-read-api` delta.** `spec.md:478` requires the field be *returned*, not that it hold
  any particular value. The contract is unchanged.
- **Persisting `duration_seconds` or cost.** Both stay derived at read time, per the ratified
  requirement at `interview-session/spec.md:1452-1463`.
- **Acting on the cost measurement.** This change makes the number measurable.
  `single-session-interview` stays parked.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- **`interview-session`** — `spec.md:29-40` declares `started_at` nullable and server-set but no
  requirement anywhere states **when** it is written; the `in_corso` transition requirements
  (`:92`, `:398`, `:424`) stamp only `participant.started_at`. The spec is the origin of the
  omission, not a downstream victim of it. The cost requirement (`:1452-1463`) presumes a
  duration the real path never produces.

## Approach

### D1 — Stamp at `in_corso`, not at row creation

A `pending` session that never reaches the provider consumed no avatar time; stamping at INSERT
would price a session that never ran. `in_corso` is set only after `issue()` returns, which is
the moment provider billing actually starts. This mirrors `ended_at`, which is stamped at the
status write, not at request entry.

### D2 — Resume is the real decision, and it is open

`in_corso` is written at **two** sites and one of them is RESUME (`:723`), where a *second*
provider session is issued for a session that already started. Three defensible answers:

| Option | Consequence for the cost figure |
|---|---|
| Leave the original stamp | `ended_at − started_at` spans the gap between attempts — over-counts an abandoned tab |
| Reset to `now()` | Discards the minutes already billed on the first attempt — under-counts |
| Extend/accumulate | Correct, but needs a second column or a per-attempt row; no longer a small change |

Naming this rather than settling it is the point. The elapsed aggregator already faced the same
class of problem and chose to exclude open sessions rather than clamp with `now()`
(`operator-participant-visibility` design D-elapsed) — that precedent constrains the answer but
does not decide it.

### D3 — The factory default is a red-first target

Leaving `InterviewSessionFactory.php:40` as-is means the new tests would pass against the
unfixed controller. Whatever the factory does after this change, it must not be the reason a
production-path assertion is green.

### Changed-line forecast

```
400-line budget risk: Low
Chained PRs recommended: No
Decision needed before apply: Yes
```

Two assignments of production logic. `Decision needed before apply: Yes` is for Q1 and Q2, not
for size. Single `api` PR + wrapper pointer bump — unless Q2 resolves to a backfill, in which
case the migration is a candidate second slice.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Http/Controllers/Candidate/InterviewController.php:723` | Modified | Resume `in_corso` — semantics per D2 |
| `api/app/Http/Controllers/Candidate/InterviewController.php:769` | Modified | Issue-pending `in_corso` — the plain case |
| `api/database/factories/InterviewSessionFactory.php:40` | Modified | Stop masking the production path (D3) |
| `api/database/migrations/` | **New (conditional)** | Only if Q2 resolves to a backfill |
| `api/app/Support/Demo/DemoWriter.php:411-412` | Modified (conditional) | The fixed 20-minute duration (Q3) |
| `openspec/specs/interview-session/spec.md` | Delta | See Capabilities |
| `api/app/Services/{Proctoring/SessionCostEstimator,Admin/ParticipantInterviewAggregator}.php` | **Unchanged** | Values start existing; no code edit |
| `frontend/`, `backoffice/` | **Unchanged** | Verified — see Out of Scope |

## Existing tests that pin today's behaviour

| Test | Effect |
|---|---|
| `Feature/C11/SessionCostEstimatorTest.php:24`, `Unit/Services/Admin/ParticipantInterviewAggregatorTest.php` (10 sites) | Must stay green — they hand-write `started_at`, so they are unaffected. Their existence is also the evidence that **no** test asserts the field end to end through `/start` |
| `Feature/C11/SessionReviewTest.php:64, 100, 195` | Must stay green — contract shape unchanged |
| `Feature/Demo/TeardownSelectivityTest.php:61` | Must stay green — demo rows keep a start time whatever Q3 decides |
| `Feature/ParticipantRecovery/RecoverFailedParticipantTest.php:213` | Must stay green — asserts `participant.started_at` is not clobbered; a different column, and the guard that this change does not stray into it |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Resume semantics chosen wrong → a cost figure that quietly over- or under-counts, and is then used to settle open decision #7 | **Med** | D2 — named as a design gate with all three options and their cost consequence stated, not assumed |
| A backfill from `created_at` becomes indistinguishable from a measurement once written | **Med** | Q2 — the choice is explicit; if backfilled, the design must say how a proxy value is marked or accepted as such |
| The factory keeps masking the defect and the new tests pass against unfixed code | Med | D3 — red-first, confirmed failing before the fix |
| Timestamp written outside the existing transaction, diverging from the status write | Low | Stamp inside the same `DB::transaction()` closure that already sets `status` |
| Demo rows and real rows become distinguishable by duration shape, breaking a demo expectation | Low | Q3 — raised, not decided; `TeardownSelectivityTest` guards the demo path |
| Cost/elapsed dashboards jump from "unknown" to a number and are read as retroactive | Low | Only sessions created after the fix carry a measured start unless Q2 says otherwise; disclosure is a design obligation |

## Rollback Plan

**Code**: revert the PR. Both assignments disappear and new sessions resume storing NULL. No
consumer breaks — every one of them (`SessionCostEstimator:35`,
`ParticipantInterviewAggregator:73`, `SessionSummaryResource:28`) already null-guards, because
NULL has been the only value they ever saw in production.

**Data**: nothing to roll back unless Q2 resolves to a backfill. If it does, that migration is
one-way — a value recomputed from `created_at` cannot be distinguished from a measured one
afterwards, so it follows the `interview-question-index-offset` D3 precedent: a documented
one-way `down()`, never a migration disguised as reversible.

## Dependencies

- `operator-participant-visibility` (shipped, api v0.27.0) — the elapsed-time consumer this
  change makes functional.
- `single-session-interview` (parked) and CLAUDE.md **open decision #7** — downstream consumers
  of the cost measurement this unblocks. Neither is resolved here.
- Pest run as `cd api && ./vendor/bin/pest <exact-file>` or a full run — never
  `php artisan test --filter`, observed fabricating passes in this repo.

## Success Criteria

- [ ] A `/start` that reaches the provider persists a non-null `interview_sessions.started_at`,
      asserted **end to end through the endpoint**, not from a factory default.
- [ ] A session that never leaves `pending` still has `started_at` NULL.
- [ ] A completed real interview returns a non-null `duration_seconds` and a non-null cost
      estimate — the first measurable provider cost the platform has ever produced.
- [ ] The operator's "total elapsed time" shows a number for a real participant, with
      `sessions_counted` equal to the sessions that actually finished.
- [ ] Resume behaviour is asserted explicitly against whichever semantics D2 selects — not left
      to whatever the code happens to do.
- [ ] `participants.started_at` is unchanged on every path, including recovery.
- [ ] `GET /api/participants/{id}/sessions` orders by a populated `started_at`.
- [ ] No test asserting a duration, cost, or ordering relies on the factory default to pass.
- [ ] Full Pest suite green.

## Proposal question round

Not asked interactively — recorded for review before `sdd-spec`. Q1 and Q2 are design gates.

1. **When is a session "started" — and what does resume do to it?** (D2.) Row creation vs. the
   `in_corso` transition is the easy half; the hard half is that `in_corso` is written at two
   sites and one is RESUME. Reset, extend, or leave alone each produces a different cost figure,
   and that figure is about to inform open decision #7.
2. **Should historical rows be backfilled, left NULL, or marked?** `created_at` records when
   `/start` inserted the row and is close to the true start — but it is a proxy, not an
   observation, and once written it is indistinguishable from a measurement. Eight production
   rows are affected. Leaving them NULL is honest; backfilling them is useful; doing both is not
   possible without a marker.
3. **Does the demo seeder's fixed 20-minute duration stay?** (`DemoWriter.php:412`.) It makes
   every demo interview look like it ran to the HeyGen cap, which is precisely what made the
   synthetic data hard to spot. Varying it is a fixture change, not a product change — but it is
   the product owner's call whether demo data should look this uniform.
4. **Is the cost estimate expected to be comparable across resumed and un-resumed interviews?**
   If yes, Q1 is forced toward accumulate; if operators will treat it as indicative, the cheaper
   options open up.

## Assumptions for user review

1. **The stamp goes at the `in_corso` transition**, not at row creation (D1) — a session that
   never reached the provider consumed nothing.
2. **`participants.started_at` is not touched.** Different table, already correct, actively
   guarded by a recovery test.
3. **Nothing new is persisted beyond the timestamp** — `duration_seconds` and cost stay derived.
4. **No `frontend` or `backoffice` code changes** — verified, not assumed; both start rendering
   real values with no edit.
5. **No `openapi.json` regeneration** — the field's type and nullability are unchanged.
6. **Resume semantics and the backfill are deliberately unresolved here** and carried into design
   as Q1 and Q2. Settling them in the proposal would be guessing at the two decisions that
   actually determine whether the resulting cost number can be trusted.
