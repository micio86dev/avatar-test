# Design: Operator Participant Visibility

Store mode: hybrid. Engram mirror: `sdd/operator-participant-visibility/design`.
Inputs: `proposal.md`, `specs/admin-read-api/spec.md`, `specs/admin-backoffice/spec.md`,
`DESIGN.md` (§8.2, §8.2.5 — authoritative for every UI ruling below).

## Technical Approach

Four moves, in dependency order:

1. **The gate stops being a single ordered comparison and becomes a two-clause rule**
   (D1). `errore` never enters the ranked list; it is admitted through a second,
   explicitly disjoint clause. Every other status's outcome is provably unchanged.
2. **The transcript payload becomes a value object, not an array** (D2), so the
   partial marker travels welded to the sessions it qualifies — through the JSON
   endpoint *and* the `.txt` download.
3. **The five missing facts are derived once, at read time**, by one aggregator over
   one session query (D3–D6). The `done/total` tally is *moved*, never re-stated (D5).
4. **The backoffice mirrors the gate and transports the marker** (D7) — one derived
   lifecycle rule client-side, zero derived completeness rules.

Nothing is persisted. No migration, no backfill, no new endpoint, no new route.

---

## D1 — THE CRUX: admitting `errore` without ranking it

`LifecycleReadGate` today asks one question: *is this status at or past a threshold
on the progression?* (`:63-71`). `ORDERED_STATUSES` (`:34`) is that progression, and
`errore` is deliberately outside it (`:17-22`) because terminal-failed is not "further
along". Appending it is not a small lie — it is a load-bearing one.

| Option | What it asserts / costs | Verdict |
|---|---|---|
| Append `errore` to the end of `ORDERED_STATUSES` | Asserts `errore > completato`. `array_search` then makes `errore` satisfy **every** threshold — including Evaluation. A BARS verdict for a crashed interview, which the proposal's Out of Scope forbids outright | **Rejected — actively unsafe** |
| Insert `errore` between `in_corso` and `in_valutazione` | Asserts an errored interview is further along than a live one and less far than one awaiting scoring. Both claims are false, and the rank silently participates in every future threshold anyone adds | Rejected |
| Replace the ordering with a flat per-scope allow-set | Honest, but discards monotonicity: adding a future status to the progression would need every set re-audited, and forgetting produces a **false 409 on a finished interview** — the exact over-denial this change exists to remove | Rejected |
| Keep the equality test the mirror already uses for Evaluation and hand-write Transcript | Two mechanisms with no shared vocabulary; the 409 body's `required_status` stops having a source | Rejected |
| **Two disjoint clauses: a `minimum` on the progression, plus an explicit off-progression allow-list, per scope** | One extra constant and one `||`. Ordered semantics for the four ranked statuses are untouched by construction | **Chosen** |

### Shape

```php
private const ORDERED_STATUSES = ['in_attesa', 'in_corso', 'in_valutazione', 'completato']; // UNCHANGED
private const KNOWN_STATUSES   = [...5 values...];                                          // UNCHANGED

/** minimum: a point ON the progression. off_progression: statuses that are NOT on it. */
private const SCOPE_RULES = [
    'transcript' => ['minimum' => 'in_corso',   'off_progression' => ['errore']],
    'evaluation' => ['minimum' => 'completato', 'off_progression' => []],
];
```

`assert()` permits iff `reaches($status, $rule['minimum']) || in_array($status,
$rule['off_progression'], true)`. `reaches()` is the existing `array_search`
comparison extracted verbatim — the ranked code path is not rewritten, only named.

### Why the clauses cannot contaminate each other

Three invariants, each pinned by a test, not by prose:

1. **Disjointness** — no `off_progression` member may appear in `ORDERED_STATUSES`.
   With that held, the `||` can never change the outcome of a *ranked* status: for
   the four ranked values the second clause is structurally unreachable. This is the
   whole guarantee, and it is mechanically checkable.
2. **Closure** — every `off_progression` member must be in `KNOWN_STATUSES`. A typo
   admits nothing; fail-closed survives.
3. **Evaluation's list is empty, and a test says so.** The mechanism that opens
   `errore` for Transcript must be visibly refused for Evaluation, or the next reader
   will assume it is available.

Unknown statuses are neither ranked nor listed → still denied for every scope. No
`?? true`, no default-allow. The fail-closed *architecture* is unchanged; the gate
simply stops being forced to express "off the progression" as "absent, therefore
denied".

### Recorded contract change

The Transcript `minimum` moves from `in_valutazione` to `in_corso`, so the 409 body's
`required_status` for a denied transcript now reads `in_corso` — truthfully, since
that is now what is required. Existing assertions on `in_valutazione` there are
red-first, not collateral.

---

## D2 — The partial marker is a type, not a field a caller remembers

Requirement: *impossible* to serve a partial transcript without the marker. A boolean
computed in the controller fails that by definition — there are two controllers
(`ParticipantController::transcript`, `ParticipantDownloadController::transcript`) and
adding a third would silently omit it.

| Option | Tradeoff | Verdict |
|---|---|---|
| Controller computes and passes it to the resource | The marker becomes caller discipline. Two call sites today, and the `.txt` renderer would be free to drop it | Rejected |
| `TranscriptResource` computes it from an injected Participant | Fixes the JSON path only; the download does not build a resource | Rejected |
| Serializer returns `array{is_partial: bool, sessions: [...]}` | Better, but `renderTranscriptText(array $sessions)` shows exactly how a shaped array gets destructured down to its payload half at a call site | Rejected |
| **Serializer returns a `final readonly AdminTranscript` DTO** | ~20 lines. `sessions` is only reachable through an object that also carries `isPartial`; both renderers take the DTO, so the marker is a *type error* to omit | **Chosen** |

`AdminTranscriptSerializer::serialize(Participant): AdminTranscript` is the single
producer for both endpoints. Turn assembly (`:45-72`) is untouched — the proposal's
assumption 6 is verified correct.

### Where the value comes from — the elegant part

Partial is **not** a new lifecycle rule. Complete ⟺ the status would have passed the
*old* Transcript threshold. So:

```php
public function isTranscriptPartial(string $status): bool
{
    return ! $this->reaches($status, 'in_valutazione'); // same comparison assert() uses
}
```

on `LifecycleReadGate`. `errore` is unranked → never reaches → partial, with **zero
special-casing**. Unknown statuses (unreachable behind the gate) also read partial —
fail-closed in the disclosure direction too. This change is therefore, literally, the
conversion of one denial into one disclosure: the same comparison, the same constant,
a different consequence.

Alternative rejected: a separate `TranscriptCompleteness` class. It would need its own
copy of the rank list, creating a second ranker that can drift from the gate — the
defect class this whole design is organised against.

### The download must carry it too

The `.txt` travels in email attachments where no JSON field can follow it. The
renderer emits an always-present, machine-facing header (CLAUDE.md: not localized):

```
partial: true
status: errore

=== INN (question 1) ===
[2026-08-20T10:11:02Z] avatar: …
```

`partial: false` is emitted just as unconditionally — an absent marker is
indistinguishable from "complete", which is exactly the concealment being removed.

### Generated-client truth (found by inspection, in scope by necessity)

`api/openapi.json:5522-5533` currently declares `TranscriptResource.sessions` as
`{"type": "string"}` — Scramble cannot infer a passthrough `toArray(): array<string,
mixed>`. The committed snapshot is **wrong today**. Rather than hand-type a fourth
copy of the shape in the backoffice, `TranscriptResource` gains a typed return plus an
explicit `@scramble-return array{is_partial: bool, sessions: array<int, array{…}>}`,
the same discipline `ParticipantResource:37-39` already uses. The panel then types
from `types/api.ts` instead of a hand-written mirror. (`useEvaluationReport`'s
hand-typing stays justified — a `Record<string, CompetencyResult>` passthrough is
genuinely not expressible; this one is.)

---

## D3 — One aggregator, one session pass

Progress, elapsed and cost all iterate the same rows. Three independent queries in
`ParticipantDetailResource` would be three chances to disagree about which sessions
count.

`App\Services\Admin\ParticipantInterviewAggregator::aggregate(Participant): array`
loads the participant's `InterviewSession` rows once (ambient `TenantContext` scope —
no `withoutGlobalScopes()`, per `AdminTenancySafetyArchTest`) and returns the three
blocks below. `ParticipantDetailResource` calls it once and spreads the result; the
resource stays a serializer.

Each figure carries **its own** coverage counts, adjacent to the number, because they
genuinely differ: cost also excludes unrecognised providers, elapsed does not. One
shared "n of m" would be wrong for at least one of them.

---

## D4 — Elapsed time: what is measured, and what an unfinished interview returns

**Measured**: the sum of *time inside avatar sessions* — `Σ (ended_at − started_at)`
over sessions where **both** timestamps exist and the delta is positive, mirroring
`SessionSummaryResource:28-30` and `SessionCostEstimator:35-43` exactly.

**Not measured**: wall-clock `timeline.started_at → completed_at`. That span includes
breaks and abandonment, has no end for `in_corso`/`errore`, and is already in the
payload — publishing a second, larger "elapsed" beside it invites the operator to
treat interview effort and calendar time as the same number.

| Case | Result | Why |
|---|---|---|
| Some sessions finished (participant 17: INN done, CSF open) | Sum of the finished ones + `sessions_counted / sessions_total` | The common case; the number is true and its incompleteness is stated |
| An open session (`started_at`, no `ended_at`) | Contributes **0**, excluded from `sessions_counted` | Clamping with `now()` would report weeks for an abandoned tab. A `timeout` session is precisely that case, and it exists in production |
| **No session has finished at all** | `seconds: null` — absent, never `0` | `0` claims the candidate spent no time while they are four minutes into question one. Same doctrine as cost, and DESIGN.md §8.2.5's "dash rather than zero" |

The UI renders `–` for `null`. `sessions_counted` is what makes an honest partial sum
readable as a partial sum.

---

## D5 — `done / total`: the definition MOVES, it is never re-stated

`InterviewController::endedCompetencyCount()` (`:906-919`) is **private**, and its own
docblock says why it exists: *"ONE definition, shared by the completion CAS and the
/end directive: two copies of this predicate would be two chances to disagree."* The
admin side cannot call it, and re-implementing it would create the second copy that
docblock was written to prevent. The denominator is already inline twice (`:416`,
`:874`).

| Option | Tradeoff | Verdict |
|---|---|---|
| Re-implement the predicate in the aggregator | The divergent-tally defect, by hand, in the surface whose entire point is that "3" was ambiguous | **Rejected** |
| Eloquent scope `InterviewSession::scopeEnded()` | Good home for the numerator, but the denominator (`project_competencies`) has no home on that model — the two halves would still be sourced from different places | Rejected |
| **`App\Support\Interview\CompetencyTally` with `ended()` and `total()`** | One class owns numerator *and* denominator, so they can never be sourced apart. Requires touching `InterviewController` | **Chosen** |

`endedCompetencyCount()` is **deleted**; its body (and docblock, verbatim — the
`error_count >= MAX_ERROR_ATTEMPTS` reasoning is hard-won) moves to
`CompetencyTally::ended()`. The two denominator call sites become `CompetencyTally::
total()`. Both `InterviewController` call sites delegate. Net definitions: 1 numerator
+ 1 denominator, down from 1 + 2.

**This change adds no second definition of an ended competency.** The admin `done`
and the candidate's `directive.ended_competencies` are the same integer from the same
method, and a Pest parity test asserts it for a participant with a spent-retry `error`
session — the one case where a naive re-implementation would differ.

Risk, stated plainly: this edits the repo's hottest file. It is a verbatim move, it is
the **first commit of PR 2 and nothing else**, and the existing candidate-side suite
(`Feature/C7a/*`, `Feature/C8/*`) is the gate.

`timeline.session_count` stays in the payload unchanged (contract stability) but stops
being rendered — it counts session *rows*, not ended competencies, and showing both
would put two different numbers for "how far" on one card.

---

## D6 — Cost: aggregate the existing estimator, disclose the coverage

`SessionCostEstimator::estimate()` is **consumed unchanged**. The aggregator calls it
per session and sums `usd`. Sessions returning `null` (unfinished, non-positive
duration, unrecognised provider) are excluded and counted.

- **Sum the rounded per-session values; do not re-derive the math.** 18 values rounded
  to 4dp accumulate ≤ 9e-4 of error. Reimplementing minute-rate arithmetic to recover
  a tenth of a cent would create a second pricing implementation for a figure that is
  an estimate by construction. Reuse beats precision here, and the config comment
  (`interview.php:154-169`) says why the precision was never real.
- **`amount: null` when nothing was estimable** — absent, never `0`. `0` claims the
  interview was free (`SessionCostEstimator:53-55` already refuses zero for exactly
  this reason).
- **`is_estimate: true` is an unconditional literal**, matching
  `SessionReviewResource:68-71`. It is never computed and never false.
- `currency: "USD"` is explicit — the rate keys are USD-denominated and an amount
  without a unit is not a figure.
- **No LLM/token cost.** Honoured, not revisited: different vendor, different meter,
  and `ai_requests` has no `interview_session_id` to attribute by.
- **No role restriction** beyond existing RBAC (spec: "Any authorized role sees these
  fields"). Proposal question 2 is answered by the spec and not re-opened here.

### Project name on the list (N+1)

`AdminParticipantReader::listQuery()` gains `->with('project:id,name')` — in the
reader, not the controller, so a future list caller cannot forget it and silently
lazy-load per row. `ParticipantResource` gains flat `project_name: string|null`
alongside `project_id`; nested would duplicate the detail resource's `project` object,
whose gate fields (`status`, `goes_live_at`, `deadline_at`) a table row has no use for.
`null` is reachable only on an orphaned FK — the list renders a dash rather than
throwing, deliberately unlike `ParticipantDetailResource:65`'s `firstOrFail()`, because
one bad row must not blank the whole page.

The guard asserts **invariance in the row count** (query count for 1 participant ==
query count for 3), not an absolute number — absolute counts break on unrelated changes
and get deleted.

---

## D7 — Backoffice: mirror the gate, transport the marker

The client derives **exactly one** lifecycle rule and **zero** completeness rules.

| Fact | Where it comes from | Why |
|---|---|---|
| *May I offer the transcript control?* | Mirrored client-side (`participant-lifecycle.ts`) | It must be known **before** the request, to avoid rendering a control that 409s |
| *Is this transcript partial?* | The payload's `is_partial`, transported verbatim | It arrives **with** the bytes on screen. Recomputing it client-side is a second definition that can disagree with the very data it labels |

The mirror copies the server's **shape**, not just its values: the same
`SCOPE_RULES = { transcript: { minimum: 'in_corso', offProgression: ['errore'] },
evaluation: { minimum: 'completato', offProgression: [] } }` and the same disjointness
invariant asserted in Vitest. A threshold move is then one line in each file and a
reviewer can diff them side by side — which is the only reason a mirror is tolerable
at all.

### Components

| Component | Change |
|---|---|
| `components/organisms/CandidateTable.vue` | 5th column, `project_name`; `TableEmpty :colspan` 4 → 5 |
| `components/organisms/TranscriptPanel.vue` | **New.** `<section>` per session, `<h3>` competency + question ordinal, turns as an `<ol>`; speaker carried by a **text label**, never colour alone (§9.1) |
| `composables/useTranscript.ts` | **New.** Typed from `types/api.ts` (possible because of D2's `@scramble-return`); rejections propagate to the page, per `useEvaluationReport`'s stated contract |
| `pages/participants/[id].vue` | Interview Card of `MetricCard`s (progress, elapsed, cost); mount `TranscriptPanel`; `:53` `session_count` → `done / total` |
| `utils/format.ts` | `formatDuration(seconds, t)` — extracted, and `SessionList.vue:78` + `SessionReviewPanel.vue:120` migrated onto it in the same commit. Two copies exist today; this change must not add a third (same doctrine as D5) |

**Deliverable 4 is already satisfied and needs no work.** `[id].vue:24` renders
`<StatusBadge :status="participant.status" />` over `statusBadgeVariant()`, which
already handles all five values including `errore`, and `participants.status.*` carries
all five keys in both locales. What is missing is the *interview* panel beside it, not
a status component. Recorded so the tasks phase does not build one.

**Reuse over invention** for cost and duration: `review.costEstimate` /
`review.costValue` (`≈ $ {usd}`) and `review.durationValue` already exist and are
already contrast- and copy-reviewed. Only coverage lines are new
(`{estimated} of {total} sessions estimated`), in `it` **and** `en`.

**Partial rendering**: an `Alert` (default variant, `data-testid="transcript-partial"`)
**above** the turns, inside the panel. Not `destructive` — partial evidence is a caveat,
not a failure. Not a header Badge — a badge is a label, not a reason, and the operator
must read the caveat *before* the evidence, which is also why it precedes the `<ol>`
in DOM order rather than merely appearing near it. Panel visibility is driven by the
**same** `isParticipantResourceReady(status, 'transcript')` that gates the download
button, so the panel and the button can never disagree about `in_attesa`.

---

## Data Flow

```
GET /participants/{id}/transcript ──> ParticipantController::transcript
   │  AdminParticipantReader::read(id, Transcript)
   │     org filter → 404 │ Gate::authorize → 403 │ LifecycleReadGate::assert → 409
   │        └── permits = reaches(status, 'in_corso') ‖ status ∈ off_progression
   ▼
AdminTranscriptSerializer::serialize(participant) ──> AdminTranscript (readonly)
   │   isPartial = ! reaches(status, 'in_valutazione')   ← the OLD threshold, disclosed
   │   sessions  = unchanged assembly (:45-72)
   ├──> TranscriptResource   ──> { is_partial, sessions[] }        (JSON)
   └──> renderTranscriptText ──> "partial: <bool>\nstatus: <s>\n…"  (text/plain)

GET /participants/{id} ──> ParticipantInterviewAggregator (ONE session query)
                              ├─ CompetencyTally::ended / ::total        → progress
                              ├─ Σ (ended_at − started_at)               → elapsed  + counted/total
                              └─ SessionCostEstimator::estimate() per s. → cost     + estimated/total
```

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Support/Admin/LifecycleReadGate.php` | Modify | `SCOPE_RULES`, extracted `reaches()`, `isTranscriptPartial()`; `ORDERED_STATUSES` untouched (D1, D2) |
| `api/app/Services/Admin/AdminTranscript.php` | **Create** | `final readonly` DTO: `bool $isPartial`, `array $sessions` |
| `api/app/Services/Admin/AdminTranscriptSerializer.php` | Modify | Returns the DTO; assembly unchanged |
| `api/app/Http/Resources/Admin/TranscriptResource.php` | Modify | DTO ctor, typed return, `@scramble-return` (fixes `sessions: string`) |
| `api/app/Http/Controllers/Api/ParticipantDownloadController.php` | Modify | `renderTranscriptText(AdminTranscript)` + header block |
| `api/app/Support/Interview/CompetencyTally.php` | **Create** | `ended()` (moved verbatim) + `total()` |
| `api/app/Http/Controllers/Candidate/InterviewController.php` | Modify | Delete `endedCompetencyCount()`; 4 call sites delegate. **No behaviour change** |
| `api/app/Services/Admin/ParticipantInterviewAggregator.php` | **Create** | One session pass → progress / elapsed / cost + coverages |
| `api/app/Http/Resources/Admin/ParticipantDetailResource.php` | Modify | `progress`, `elapsed`, `cost`; docblock + `@scramble-return` in lockstep |
| `api/app/Http/Resources/Admin/ParticipantResource.php` | Modify | `project_name` |
| `api/app/Support/Admin/AdminParticipantReader.php` | Modify | `listQuery()` eager-loads `project:id,name` |
| `api/app/Services/Proctoring/SessionCostEstimator.php` | **Unchanged** | Consumed, not modified |
| `backoffice/app/utils/participant-lifecycle.ts` | Modify | Mirrored two-clause rule (D7) |
| `backoffice/app/composables/useTranscript.ts` | **Create** | Typed read over the transcript endpoint |
| `backoffice/app/components/organisms/TranscriptPanel.vue` | **Create** | Turns + partial Alert |
| `backoffice/app/components/organisms/CandidateTable.vue` | Modify | Project column, colspan |
| `backoffice/app/pages/participants/[id].vue` | Modify | Interview panel + transcript panel |
| `backoffice/app/utils/format.ts` | Modify | `formatDuration` (+ migrate 2 existing copies) |
| `backoffice/i18n/locales/{it,en}.json` | Modify | Project column, progress, elapsed, coverage lines, partial label |
| `{api,frontend,backoffice}/openapi.json`, `{frontend,backoffice}/types/api.ts` | Regenerate | See Delivery |

No migrations. No schema. No backfill. No `frontend` **feature** work.

---

## Interfaces

```
GET /participants/{id}/transcript            → 200 { data: { is_partial: bool, sessions: [...] } }
GET /participants/{id}/transcript/download   → 200 text/plain, first lines "partial: <bool>\nstatus: <s>"
   409 { error: "lifecycle_not_ready", resource: "transcript",
         current_status: "in_attesa", required_status: "in_corso" }   ← required_status moved

GET /participants                            → data[].project_name: string|null
GET /participants/{id}                       → data.progress { done: int, total: int }
                                               data.elapsed  { seconds: int|null,
                                                               sessions_counted: int, sessions_total: int }
                                               data.cost     { amount: float|null, currency: "USD",
                                                               is_estimate: true,
                                                               sessions_estimated: int, sessions_total: int }
```

---

## Testing Strategy (strict TDD — RED first)

Runner discipline: `cd api && ./vendor/bin/pest <exact-file>` while iterating, full
unfiltered run before each PR. **Never `php artisan test --filter`** — observed
fabricating passes in this repo. Vitest via `bun run test:unit`; Playwright
`--workers=1`, extending existing specs.

| Tier | What it is responsible for proving |
|---|---|
| **Pest — gate** | The full 5-status × 2-scope × (read + download) matrix; that `errore` and `in_corso` return `200` for Transcript and `409` for Evaluation; that `in_attesa` and an unrecognised status still deny everywhere. Plus the three D1 **invariants as tests**: clause disjointness, off-progression closure over `KNOWN_STATUSES`, and Evaluation's allow-list being empty. These are what make "the ordering is uncorrupted" a checked fact rather than a claim |
| **Pest — marker** | That the marker is present on **every** transcript response, both variants, and that the two variants agree for the same participant. Not "the happy path is labelled" — that omission is impossible to detect from the happy path alone |
| **Pest — aggregates** | The arithmetic and, more importantly, the **absence rules**: no estimable session → `amount` absent not zero; no finished session → `seconds` absent not zero; partial sums always accompanied by their coverage counts |
| **Pest — tally parity** | That admin `done` and candidate `ended_competencies` are the same integer for a participant with a spent-retry `error` session. This is the test that would have caught the divergence D5 refuses to create |
| **Pest — tenancy** | Cross-org `404` on every new and modified read; query-count **invariance** across row counts for the list; both C11 arch tests green (`withoutGlobalScopes`, bare `Participant::`) |
| **Vitest — mirror** | The same 5 × 2 matrix as the server, plus the disjointness invariant, so the two files are provably the same rule |
| **Vitest — panel** | That the partial label is driven by the payload and **never recomputed**; that a complete transcript shows no label; that absent cost/elapsed render a dash and never `0`; that coverage lines appear whenever a total is partial; that every new key exists in both locales |
| **Playwright** | The operator's original report, end to end: open an `in_corso` participant, read progress/elapsed/estimated cost, open the transcript, see the partial label **and** both speakers' turns grouped by question. Plus the negative: an `in_attesa` participant offers no panel. Includes the axe pass the new panel inherits from the existing per-page a11y run |

Red-first targets: `Feature/C11/AdminLifecycleGateMatrixTest` (`in_corso`/`errore`
Transcript rows, and the `required_status` literal) and
`backoffice/tests/unit/utils/participant-lifecycle.spec.ts:30,42`. Must stay green:
every Evaluation-scope row, the `in_attesa` denial, the fail-closed scenario, both C11
arch tests, and the candidate-side `Feature/C7a`/`Feature/C8` suites (D5's move).

---

## Delivery

`400-line budget risk: High` · `Chained PRs recommended: Yes` ·
`Decision needed before apply: Yes`

Feature Branch Chain: PR 1 → the feature branch, each later PR → the previous PR's
branch.

| PR | Repo | Slice | ~Lines | Independently shippable as |
|---|---|---|---|---|
| **1** | `api` | D1 gate + D2 DTO/marker/`@scramble-return` + download header | ~230 | **The data becomes reachable.** All 27 of INN's turns return `200` on read and download for `in_corso` and `errore`; the detail payload's `files.transcript.url` stops 409-ing. No UI yet — the mirror still hides the button |
| **2** | `api` | D5 `CompetencyTally` (first commit, alone) + D3/D4/D6 aggregator + resource fields + eager load | ~260 | Purely additive read fields. Nothing renders them yet; nothing breaks without them |
| **3** | `backoffice` | Project column + interview panel + `formatDuration` + i18n + Vitest | ~300 | The five missing facts become visible |
| **4** | `backoffice` | D7 mirror + `TranscriptPanel` + `useTranscript` + partial Alert + E2E | ~350 | **Closes the operator's original report** |

**Cross-submodule ordering — the constraint the proposal understated.** The wrapper's
Cross-Stack Consistency job requires `openapi.json` to be **byte-identical in `api/`,
`frontend/` and `backoffice/`** (`Taskfile.yml:161-166`). So each api PR that moves the
schema forces a snapshot cycle **before** its wrapper pointer advances:

```
merge api PR → task openapi:sync (DB_CONNECTION=pgsql, mandatory) →
commit regenerated openapi.json to frontend + backoffice (+ types/api.ts) →
ONE wrapper commit moving all three pointers together
```

Advancing the `api` pointer alone turns `develop` red. `frontend` therefore takes a
**generated-snapshot-only commit** — no feature work, but it is a real third submodule
touch, contrary to the proposal's "no frontend submodule work".

Ordering: PR 3 needs sync-cycle 2; PR 4 needs only sync-cycle **1**. If PR 2 stalls
(the `InterviewController` extraction is the one contested edit), PR 4 rebases onto
sync-cycle 1 and ships alone — **PR 1 + PR 4 is the complete answer to the operator's
report**; PRs 2 and 3 are the five extra facts.

Rollback: reverse chain order. Backoffice reverts have no server effect. PR 2's fields
are additive; PR 2's `CompetencyTally` revert must restore the private method (revert
it **last** within the PR). PR 1 restores two `SCOPE_RULES` values and the gate denies
again on the next request. Nothing is persisted, so rollback is code-only.

---

## Open Questions

- [ ] **Is a partial transcript allowed to inform a hiring decision, or is it strictly
      diagnostic?** (Proposal question 1 — product/compliance, not technical.) The
      design labels it loudly in payload, UI and file. If the answer is "diagnostic
      only", the *download* button for a partial transcript needs an additional
      confirmation step — a small, purely additive follow-up. Not blocking.
- [ ] Should `partial: true` in the `.txt` header also be repeated as a footer? A long
      transcript scrolls its header off. Cheap to add later; deferred.

---

## Assumptions for user review

1. **D1's two-clause rule is the mechanism**, and its safety rests on clause
   disjointness being *tested*, not documented. If disjointness is ever relaxed, the
   ordered semantics stop being provably intact.
2. **The Transcript 409's `required_status` changes to `in_corso`.** Truthful, but it
   is a response-body change to an existing error contract.
3. **The partial marker is a DTO, not a field**, because "the caller must remember" is
   the failure mode the requirement explicitly forbids.
4. **`TranscriptResource` gets a typed `@scramble-return`**, fixing an already-wrong
   committed snapshot (`sessions: string`). In scope by necessity — the alternative is
   a hand-typed fourth copy of the payload shape.
5. **`InterviewController` is edited** to move `endedCompetencyCount()`. Verbatim move,
   isolated commit, candidate-side suite as the gate. If any sibling change holds a
   seam contract on that file at apply time, PR 2 rebases before touching it.
6. **Elapsed time is session time, not wall-clock time**, and is absent — never `0` —
   when no session has finished.
7. **The cost total sums the estimator's already-rounded values**; the pricing math is
   not re-implemented.
8. **`frontend` receives a generated-snapshot commit** per api sync cycle. Unavoidable,
   given the wrapper's cross-stack gate.
9. **Deliverable 4 needs no new component** — `StatusBadge` already renders all five
   values.
10. **This artifact exceeds the skill's 800-word budget deliberately**, per the
    orchestrator's direction that D1 receive a full decision record.
