# Tasks: Operator Participant Visibility

Store mode: hybrid. Engram mirror: `sdd/operator-participant-visibility/tasks`.
Chain strategy: **Feature Branch Chain** (design.md §Delivery). Runner discipline:
`cd api && ./vendor/bin/pest <exact-file>` while iterating, full unfiltered run
before each PR — **never `php artisan test --filter`** (observed fabricating
passes in this repo). `openapi:sync` requires `DB_CONNECTION=pgsql` explicitly —
under sqlite it silently produces a wrong export.

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | ~1,000–1,200 (excl. generated `openapi.json`/`types.ts` churn) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR1 → PR2 → PR3 → PR4, plus 2 cross-submodule sync cycles |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|---|---|---|---|
| 1 | Read gate loosened (D1–D3) + partial marker DTO (D2) | PR1 (`api`) | ~230 lines. Ships alone; unblocks INN's 27 turns |
| 2 | `CompetencyTally` move (D5) + one-pass aggregator (D3/D4/D6) | PR2 (`api`) | ~260 lines. Purely additive read fields |
| 3 | List project column + interview status/progress/elapsed/cost panel | PR3 (`backoffice`) | ~300 lines. Needs sync-cycle 2 |
| 4 | Mirrored gate (D7) + `TranscriptPanel` + E2E | PR4 (`backoffice`) | ~350 lines. Needs only sync-cycle 1 — independent of PR3 |

## Testing discipline (repo gotchas — apply to every task below)

- [ ] Every RED task must be **observed failing for the right reason** (assertion
      mismatch, not a thrown error from a missing symbol/route) before its GREEN.
- [ ] No incidental count assertions (e.g. "exactly one alert rendered"). Assert
      by **content**: which alert, which key, which value — not how many.
- [ ] Query-count guards assert **invariance** (1-row count == 3-row count), never
      an absolute literal.

---

## PR1 (`api`): Read Gate + Partial Marker — D1, D2, D3 (~230 lines)

Branch: `feature/operator-participant-visibility-pr1-gate` (base: api `develop`).

RED — gate matrix + invariants:
- [x] 1.1 Extend `tests/Feature/C11/AdminLifecycleGateMatrixTest.php`: `in_corso`
      and `errore` Transcript read+download flip to `200`; assert the new
      `required_status: "in_corso"` literal on the still-denied `in_attesa` row.
- [x] 1.2 New test: D1 **disjointness invariant** — no `off_progression` member
      (`errore`) appears in `ORDERED_STATUSES`. Its own test, not folded into 1.1.
- [x] 1.3 New test: D1 **closure invariant** — every `off_progression` member is
      in `KNOWN_STATUSES`.
- [x] 1.4 New test: Evaluation's `off_progression` allow-list is empty (the
      mechanism that opens `errore` for Transcript is visibly refused here).
- [x] 1.5 Confirm must-stay-green: `in_attesa` Transcript denial, Evaluation rows
      at `in_corso`/`errore`, and the unrecognized-status fail-closed scenario.

GREEN:
- [x] 1.6 `api/app/Support/Admin/LifecycleReadGate.php`: replace the single
      ordered comparison with `SCOPE_RULES` (`minimum` + `off_progression` per
      scope); extract `reaches()`; `assert()` = `reaches() || in_array(off_progression)`.
- [x] 1.7 Same file: add `isTranscriptPartial(string $status): bool = ! reaches($status, 'in_valutazione')`.
- [x] 1.8 Verify 1.1–1.5 all green (targeted file run).

RED — D2 DTO + marker:
- [x] 1.9 New/extended serializer test: `AdminTranscriptSerializer::serialize()`
      returns `isPartial = true` for `in_corso`/`errore`, `false` for
      `in_valutazione`/`completato`.
- [x] 1.10 New test: `is_partial` key is **present** on both the JSON read and the
      `.txt` download for the same participant, and the two values agree
      (assert key presence, not just truthiness).

GREEN:
- [x] 1.11 Create `api/app/Services/Admin/AdminTranscript.php` — `final readonly`
      DTO `{bool $isPartial, array $sessions}`.
- [x] 1.12 `AdminTranscriptSerializer` returns the DTO; turn assembly (`:45-67`)
      untouched.
- [x] 1.13 `TranscriptResource.php`: construct from the DTO, typed return, add
      `@scramble-return array{is_partial: bool, sessions: array<int, array{...}>}`
      (fixes the pre-existing wrong `sessions: string` declaration, D2b).
- [x] 1.14 `ParticipantDownloadController::renderTranscriptText(AdminTranscript)`:
      unconditional `partial: <bool>\nstatus: <s>` header, machine-facing, not
      localized.
- [x] 1.15 Verify 1.9–1.10 green.

OpenAPI + verify:
- [x] 1.16 `task openapi:sync` with `DB_CONNECTION=pgsql` (not sqlite); commit
      the regenerated `api/openapi.json` inside PR1.
- [x] 1.17 Full unfiltered Pest suite green; `Arch/C11/AdminTenancySafetyArchTest.php`
      and `Arch/C11/CandidateCannotReadProctoringArchTest.php` stay green,
      unmodified.
- [ ] 1.18 Run `php artisan test --coverage --min=85`; record the actual
      percentage for `LifecycleReadGate`/`AdminTranscriptSerializer`/
      `TranscriptResource` (~95% correctness-critical target) — do not close
      this task without the number.
- [x] 1.19 Confirm `is_partial`, the `.txt` header, `error: "lifecycle_not_ready"`,
      `required_status` are not passed through any i18n/`__()` wrapper.
- [ ] 1.20 Git Flow: PR against api `develop`; merge after review.

---

## Cross-submodule sync-cycle 1 (after PR1 merges — unblocks PR4)

- [ ] S1.1 `task openapi:sync` (`DB_CONNECTION=pgsql`) from the wrapper root.
- [ ] S1.2 Commit regenerated `openapi.json`/`types/api.ts` to `backoffice`; commit
      the generated-snapshot-only `openapi.json` to `frontend` (no feature work).
- [ ] S1.3 ONE wrapper commit advancing `api`, `frontend`, `backoffice` pointers
      together.
- [ ] S1.4 Git Flow for the frontend snapshot: branch, PR, merge on frontend's
      own `develop`.

---

## PR2 (`api`): Aggregates — D5, D3/D4/D6 (~260 lines)

Branch: `feature/operator-participant-visibility-pr2-aggregates` (base: PR1
branch, or api `develop` post-merge).

D5 — `CompetencyTally` move, **first commit, alone**:
- [x] 2.1 RED: `CompetencyTally::ended()`/`::total()` match the current private
      `endedCompetencyCount()` output for a fixture participant, **including the
      spent-retry `error` session case**.
- [x] 2.2 RED: cross-surface parity — admin `done` and candidate
      `directive.ended_competencies` are the same integer for that same fixture.
- [x] 2.3 GREEN: create `api/app/Support/Interview/CompetencyTally.php` —
      `ended()` (verbatim moved body + docblock) + `total()`.
- [x] 2.4 GREEN: `InterviewController.php` — delete `endedCompetencyCount()`; all
      numerator/denominator call sites (`:416`, `:874`) delegate to
      `CompetencyTally`. No behaviour change.
- [x] 2.5 Verify `Feature/C7a/*` and `Feature/C8/*` stay fully green in isolation.
- [x] 2.6 Audit: grep `api/` for any remaining inline ended-competency predicate
      outside `CompetencyTally` — confirm **no second tally definition** remains.
- [ ] 2.7 Commit 2.1–2.6 as its own commit before any aggregator work. (Left to
      the orchestrator — this executor was instructed to leave the branch
      uncommitted; D5 and the aggregator work are separable in the diff but not
      committed separately here.)

D3/D4/D6 — one-pass aggregator:
- [x] 2.8 RED: progress — 15 project competencies, 6 ended → `done/total` = 6/15.
- [x] 2.9 RED: elapsed — two sessions (300s, 480s) → 780s; `sessions_counted`/
      `sessions_total` present.
- [x] 2.10 RED: elapsed absence — no session has `ended_at` → `seconds: null`,
      never `0`.
- [x] 2.11 RED: elapsed — an open session (`started_at`, no `ended_at`)
      contributes 0 and is excluded from `sessions_counted` (no `now()` clamp).
- [x] 2.12 RED: cost — 3 sessions, 2 estimable → sum of the 2, `sessions_estimated: 2`/`sessions_total: 3`.
- [x] 2.13 RED: cost absence — no session estimable → `amount: null`, never `0`.
- [x] 2.14 RED: one-session-query assertion — `aggregate()` issues exactly one
      `InterviewSession` query, asserted by SQL content, not by an unrelated count.
      Judgment call (documented in the apply-progress artifact): the assertion
      scopes "one query" to the raw session LOAD used for elapsed/cost (excludes
      `count(`-aggregate SQL), because progress's numerator still delegates to
      `CompetencyTally::ended()` — a second, COUNT-aggregate query — per D5's
      "never re-derive the predicate" rule, which this executor judged to
      outrank a literal single-query-total reading of this task.
- [x] 2.15 GREEN: create `api/app/Services/Admin/ParticipantInterviewAggregator.php`
      — one session load (ambient `TenantContext`, no `withoutGlobalScopes()`),
      progress via `CompetencyTally`, elapsed/cost per D4/D6 absence rules.
- [x] 2.16 Verify 2.8–2.14 green.

Resource + reader wiring:
- [x] 2.17 RED: `ParticipantDetailResource` — status is a literal domain value
      (5 cases), never boolean/reduction.
- [x] 2.18 RED: `ParticipantDetailResource` — `progress`/`elapsed`/`cost` shaped
      per the Interfaces contract.
- [x] 2.19 GREEN: `ParticipantDetailResource.php` calls the aggregator once;
      `@scramble-return` in lockstep.
- [x] 2.20 RED: `ParticipantResource` — list row carries `project_name:
      string|null`; orphaned FK renders `null`, not a thrown error.
- [x] 2.21 RED: N+1 guard — query-count **invariance** (1 participant vs 3).
- [x] 2.22 GREEN: `AdminParticipantReader::listQuery()` → `->with('project:id,name')`;
      `ParticipantResource.php` → flat `project_name`.
- [x] 2.23 Verify 2.17–2.21 green.

Tenancy + verify:
- [x] 2.24 Cross-org `404` on every new/modified read (detail + list). Covered
      by the existing `AdminCrossTenantIsolationTest.php` (`show`/`index` cases),
      which exercise the exact endpoints this PR modified and stayed green — no
      new dedicated test was added for this task.
- [x] 2.25 `Arch/C11/AdminTenancySafetyArchTest.php` stays green.
- [ ] 2.26 `task openapi:sync` (`DB_CONNECTION=pgsql`); commit regenerated
      `api/openapi.json` in PR2. **Explicitly out of scope for this executor**
      per the orchestrator's instructions — the orchestrator owns this step.
- [x] 2.27 Full unfiltered Pest suite green; coverage recorded for
      `ParticipantInterviewAggregator`/`CompetencyTally` (~95% target).
      Result: 2054 tests, 2049 passed, 5 skipped (pre-existing), 0 failed.
      `App\Services\Admin\ParticipantInterviewAggregator`: Methods 100%
      (1/1), Lines 100% (40/40). `App\Support\Interview\CompetencyTally`:
      Methods 100% (2/2), Lines 100% (12/12).
- [ ] 2.28 Git Flow: PR against api `develop`; merge after review. (Orchestrator's
      responsibility — this executor left the branch uncommitted per instructions.)

---

## Cross-submodule sync-cycle 2 (after PR2 merges — unblocks PR3)

- [ ] S2.1 `task openapi:sync` (`DB_CONNECTION=pgsql`) from the wrapper root.
- [ ] S2.2 Commit regenerated `openapi.json`/`types/api.ts` to `backoffice`;
      generated-snapshot commit to `frontend`.
- [ ] S2.3 ONE wrapper commit advancing all three pointers together.
- [ ] S2.4 Git Flow for the frontend snapshot: branch, PR, merge.

---

## PR3 (`backoffice`): List Column + Interview Panel (~300 lines)

Branch: `feature/operator-participant-visibility-pr3-panel` (base: backoffice
`develop`, post sync-cycle 2).

`formatDuration` extraction (avoid a third copy):
- [x] 3.1 RED: `tests/unit/utils/format.spec.ts` — `formatDuration(seconds, t)`,
      including `null → '–'` (dash, never `0`/empty).
- [x] 3.2 GREEN: extract `formatDuration` in `app/utils/format.ts`.
- [x] 3.3 GREEN: migrate `SessionList.vue:78` and `SessionReviewPanel.vue:120`
      onto it in the same commit.
- [x] 3.4 Verify existing `SessionList`/`SessionReviewPanel` specs stay green.
      (No dedicated `SessionList.spec.ts` exists in this repo — its only
      coverage is indirect via `detail.spec.ts`, which stayed green.
      `SessionReviewPanel.spec.ts`: 7/7 green.)

Project column:
- [x] 3.5 RED: `CandidateTable.spec.ts` — 5th column renders `project_name`;
      `TableEmpty :colspan` asserted at 5, not 4.
- [x] 3.6 GREEN: `CandidateTable.vue` — project column, colspan 4→5.
- [x] 3.7 Verify 3.5 green.

Interview status/progress/elapsed/cost panel:
- [x] 3.8 RED: status renders the real literal value (`errore` case), never a
      boolean/reduction. (Characterization test — `StatusBadge` already
      satisfied this per design's Deliverable-4 note; test passed on first
      run with no GREEN required. Documented, not silently skipped.)
- [x] 3.9 RED: progress renders `done / total` (6/15 fixture), replacing the bare
      `session_count` at `[id].vue:53`.
- [x] 3.10 RED: cost figure unconditionally carries a visible "estimate" label.
- [x] 3.11 RED: partial cost total states "X of Y sessions contributed", in `it`
      **and** `en`.
- [x] 3.12 RED: absent cost/elapsed render `–`, never `0`.
- [x] 3.13 RED: a `viewer` role sees all fields — no restriction beyond RBAC.
- [x] 3.14 GREEN: `[id].vue` — Interview Card of `MetricCard`s (progress/elapsed/
      cost), replacing `:53`.
- [x] 3.15 GREEN: `i18n/locales/{it,en}.json` — coverage lines, estimate label,
      progress/elapsed copy (reuse `review.costEstimate`/`costValue`/`durationValue`).
- [x] 3.16 Verify 3.8–3.13 green.

Verify:
- [x] 3.17 Confirm every new user-facing string exists in both `it.json` and
      `en.json` — no hardcoded literal in a template.
- [x] 3.18 Confirm API-sourced machine values (`in_corso`, `errore`, `is_estimate`)
      are rendered via the existing status/label mapping, never used as i18n keys.
- [x] 3.19 `bun run test:unit` full suite green; coverage recorded (85% gate).
      Result: 98 test files, 770 tests, 0 failed (baseline before this PR:
      98 files/755 tests). Overall coverage 94.67% stmts / 88.91% branch /
      86.2% funcs. `app/utils/format.ts`: 100/100/100/100. `[id].vue`
      (participants): 98.1% stmts.
- [ ] 3.20 Git Flow: PR against backoffice `develop`; merge after review.
      (Left to the orchestrator — this executor was instructed to leave the
      branch uncommitted.)

---

## PR4 (`backoffice`): Mirrored Gate + Transcript Panel + E2E — D7 (~350 lines)

Branch: `feature/operator-participant-visibility-pr4-transcript` (base:
backoffice `develop`, post sync-cycle 1 — independent of PR3; ships alone if
PR2/PR3 stall, per design's "PR1+PR4 is the complete answer" note).

D7 mirror (red-first, per proposal):
- [x] 4.1 RED: `tests/unit/utils/participant-lifecycle.spec.ts:30,42` — `in_corso`
      and `errore` now `true` for `'transcript'` only; observe today's assertion
      fail on value mismatch (not a thrown error). Observed: `AssertionError:
      expected false to be true` on both cases (right reason — value
      mismatch, not a thrown/missing-symbol error).
- [x] 4.2 Confirm must-stay-green: same file's `'evaluation'` cases (`:48-60`).
- [x] 4.3 RED: mirror's own disjointness invariant — `offProgression` never
      overlaps the ordered list, client-side twin of D1. Observed:
      `TypeError: Cannot convert undefined or null to object` (SCOPE_RULES/
      ORDERED_STATUSES not yet exported) — right reason, new symbols absent.
- [x] 4.4 Confirm must-stay-green: `in_attesa` still denies transcript.
- [x] 4.5 GREEN: `participant-lifecycle.ts` — same `SCOPE_RULES` shape
      (`minimum`/`offProgression`) as the server.
- [x] 4.6 Verify 4.1–4.4 green. 19/19 (was 17/17 pre-PR4).

`useTranscript` + `TranscriptPanel`:
- [x] 4.7 RED: `useTranscript.spec.ts` — typed read from `types/api.ts`;
      rejections propagate to the page (mirrors `useEvaluationReport`).
      Observed: `Failed to resolve import ".../useTranscript"` — module did
      not exist yet.
- [x] 4.8 GREEN: `app/composables/useTranscript.ts`.
- [x] 4.9 RED: `TranscriptPanel.spec.ts` — turns grouped by question, speaker
      shown as a text label (never colour alone, §9.1). Observed: `Failed to
      resolve import ".../TranscriptPanel.vue"` — component did not exist yet.
- [x] 4.10 RED: `is_partial: true` → visible `Alert`
      (`data-testid="transcript-partial"`) rendered **above** the turns —
      assert DOM order, not mere presence. (Same missing-component RED as 4.9;
      GREEN confirmed the DOM-order assertion specifically passes, not just
      element presence.)
- [x] 4.11 RED: `is_partial: false` → no partial label rendered.
- [x] 4.12 RED: the label follows the payload prop, not a client-recomputed
      lifecycle check (vary only the prop; confirm status changes alone do not
      move the label). Structural guarantee: `TranscriptPanel` takes NO
      status/lifecycle prop at all — impossible for status to move the label.
      Also covered end-to-end at the page level (new detail.spec.ts test:
      `completato` + payload `is_partial: true` still shows the label).
- [x] 4.13 RED: panel visibility uses the SAME `isParticipantResourceReady(status,
      'transcript')` gate as the download button — both agree at `in_attesa`.
      Done at the PAGE level (`detail.spec.ts`, not `TranscriptPanel.spec.ts`,
      since the gate lives in `[id].vue`'s `v-if`). RED verified by
      temporarily stashing the `[id].vue` wiring: 7/9 new page tests failed
      for the right reason (assertion mismatch / element not found); 2 passed
      vacuously (absence-of-panel assertions, expected with no wiring) —
      restored and reran GREEN, 9/9.
- [x] 4.14 GREEN: `components/organisms/TranscriptPanel.vue`.
- [x] 4.15 Verify 4.7–4.13 green. 6/6 (TranscriptPanel, incl. one added after
      GREEN to close a coverage gap on the unrecognized-speaker fallback —
      flagged, not RED-first) + 2/2 (useTranscript) + 19/19 (mirror).

Wiring + i18n:
- [x] 4.16 GREEN: `[id].vue` — mount `TranscriptPanel`, gated by the mirrored
      lifecycle check. New Card, fetched only when `transcriptReady`; a fetch
      failure despite the gate being open surfaces a distinct
      `transcript-load-error` state (own new test, not in the original task
      list, added for symmetry with the Evaluation card's D4 doctrine).
- [x] 4.17 GREEN: `i18n/locales/{it,en}.json` — partial-label copy, speaker labels.
- [x] 4.18 Confirm every new string has both `it`/`en` entries. Parity
      verified: 594 keys in both locale files (587 baseline + 7 new).
- [x] 4.19 Confirm the `.txt` download's `partial:`/`status:` header stays literal
      wherever any composable parses it — never localized. `useDownloads.ts`
      never parses the blob body at all (fetch-then-blob, D9) — no composable
      touches the header text, so there is nothing to localize by construction.

E2E + verify:
- [x] 4.20 New Playwright spec: operator opens an `in_corso` participant, reads
      progress/elapsed/estimated cost, opens the transcript, sees the partial
      label AND both speakers' turns grouped by question.
      `tests/e2e/transcript-panel.spec.ts`.
- [x] 4.21 New Playwright spec: `in_attesa` participant offers no transcript
      panel and no download control (asserted via `toBeDisabled()` — the
      button element still renders, per this repo's existing pattern of
      disabled-not-absent controls; the panel itself is fully absent).
- [x] 4.22 Confirm the panel is covered by the existing per-page axe/a11y run.
      Dedicated `checkA11y()` test with the panel visible, plus click-through
      navigation (not `page.goto()` reload) — the reload path is the
      documented pre-existing blocker behind `admin-flow.spec.ts`'s "candidate
      detail view is WCAG 2.1 AA clean" known failure.
- [x] 4.23 `bun run test:unit` and `bunx playwright test --project=chromium`
      full suites green; coverage recorded (85% gate). Unit: 100 files / 789
      tests, 0 failed (baseline before PR4: 98 files/770 tests). Coverage:
      94.73% stmts / 88.9% branch / 86.36% funcs / 94.73% lines.
      `participant-lifecycle.ts`/`useTranscript.ts`: 100/100/100/100.
      `TranscriptPanel.vue`: 97.77/85.71/100/97.77. `[id].vue` (participants):
      98.08/81.88/87.5/98.08. Playwright chromium: 66 passed, 4 failed —
      byte-identical to the four pre-existing known failures (verified via
      `git stash` against unmodified `develop`), no fifth. Webkit run also
      performed (not requested, done for repo-wide policy confidence): 65
      passed, 5 failed — the same 4 plus one pre-existing, unrelated
      `session-cookie.spec.ts` webkit-only failure, independently confirmed
      pre-existing via the same stash technique.
- [ ] 4.24 Git Flow: PR against backoffice `develop`; merge after review. No
      dependency on PR3's branch state. (Left to the orchestrator — this
      executor was instructed to leave the branch uncommitted.)

---

## Final wrapper reconciliation

- [ ] W.1 Confirm the wrapper's Cross-Stack Consistency job
      (`Taskfile.yml:161-166`) still finds `openapi.json` byte-identical across
      `api/`, `frontend/`, `backoffice/` after PR3/PR4 land; re-sync if needed.
- [ ] W.2 Final wrapper commit(s) advancing the `backoffice` submodule pointer(s)
      for PR3/PR4.

## Deferred (not a task in this change)

- Extra confirmation step on the transcript **download** button when a partial
  transcript is ruled strictly diagnostic (Open Question 1). Gated on a
  product/compliance answer; small additive follow-up if it lands.
