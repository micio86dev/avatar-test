# Archive Report: interview-continuous-flow

**Change**: interview-continuous-flow  
**Archived**: 2026-08-20  
**Status**: Complete — merged, deployed, verified  

**Artifact traceability** (all from Engram):
- Proposal: #1255 (`sdd/interview-continuous-flow/proposal`)
- Specification: #1256 (`sdd/interview-continuous-flow/spec`)
- Design: #1254 (`sdd/interview-continuous-flow/design`)
- Tasks: openspec/changes/archive/2026-08-20-interview-continuous-flow/tasks.md
- Apply progress: openspec/changes/archive/2026-08-20-interview-continuous-flow/apply-progress.md
- Verify report: #1257 (`sdd/interview-continuous-flow/verify-report`)

---

## Summary

Server-directed continuous interview flow with bounded single re-offer of failed competencies. The change closes a fundamental gap in the interview mechanics: the live application was ending interviews after one competency, and was showing a manual interstitial after every question — neither of which the specification or the product requirements called for.

**Root cause**: The backend never sent the competency total or the next-step directive to the frontend. The frontend guessed both from an empty array, and the guess produced the one-competency truncation and the unconditional interstitial. The specification incorrectly claimed that `pause_every_n_competencies` had no backend column (it did, always had); the false premise led to the unconditional screen.

**Fix**: Add `total_competencies` to `/start` and `next_action` directive to `/end`. Both are purely additive. The server already computed the numbers for the `in_valutazione` CAS; no new query is added. The client branches on the directive instead of guessing.

**Bounded re-offer**: A competency ending in `error` is re-offered once at the same session row (UNIQUE constraint forbids a second row). If it fails again, it stays `error`, becomes terminal, and counts toward completion so `in_valutazione` can fire. This closes the case of participants permanently stuck at `in_corso` with an error session.

---

## Scope and Delivery

### Artifacts Merged to Main Specs

| Spec | Action | Sections Modified | Verified |
|---|---|---|---|
| `openspec/specs/interview-frontend/spec.md` | Merged delta | Non-Goals: removed false `pause_every_n_competencies` claim. Added: 5 new requirements (continuous auto-advance, skip removal, progress indicator, re-offer notice, timer suspension). Modified: interview-session-loop (updated `/end` description and between-competency flow guidance), flow-screens (state machine corrected, SA-04 pause gated on `next_action`, live mute-pause preserved). Added new scenarios for server-directed behavior. | Yes, grep verified |
| `openspec/specs/interview-session/spec.md` | Merged delta | Non-Goals: removed `pause_every_n_competencies` UX gate. Modified: InterviewSession status enum definition (added re-offer note). Added: 3 new requirements (`/start` total_competencies, `/end` next_action directive, bounded single re-offer). Modified: POST /end step 4 (completion tally now includes exhausted re-offers), step 7 (response body widened). | Yes, git-verified main spec |
| `openspec/specs/interview-conversation/spec.md` | Merged delta | Added: OpeningTextComposer `retry` variant requirement (4 scenarios). | Yes, read in place |

### Factual Correction Applied

**`openspec/specs/interview-frontend/spec.md` lines 24-25 and 867-871** — **FALSE CLAIM CORRECTED**

- **Was**: "Server-enforced `pause_every_n_competencies` — no backend column exists; C7b implements pause/resume with client-side state only"
- **Now**: Removed from Non-Goals (gate is now genuinely server-enforced). Requirement replaced with server-directed behavior.
- **Evidence**: Column exists at `api/database/migrations/2026_07_17_200001_create_projects_table.php:41` since project-table creation. Already in Project model, already validated, already serialized, already settable in backoffice.

---

## Spec Changes: Destructive Deltas

Per `openspec/config.yaml` rules.archive: *"Warn before merging destructive deltas"*. These are the intentional removals:

| Target | Removed | Reason | Replacement |
|---|---|---|---|
| `interview-frontend/spec.md:24-25` | Non-goal: "no backend column exists" | False premise (column always existed); gate is now server-enforced per decision 2 | None (gate deleted; implementation moved to server) |
| `interview-frontend/spec.md:450-462` | Between-competency guidance: unconditional interstitial + client-side last-competency arithmetic | Superseded by server-directed next_action; client-side count was the source of the one-competency truncation | Server-directed guidance: branch on next_action (continue/pause/done); no client computation |
| `interview-frontend/spec.md:456-462` | Last-competency detection: client-side comparison against a competency list (never shipped) | Unnecessary; the server's `next_action = 'done'` is the source of truth | `next_action` field from /end response |
| `interview-frontend/spec.md:858` | End-of-Question state description: "competencies remain" as entry condition | Conditional on pause directive, not on remaining competencies; unconditional interstitial removed | Conditional entry: only on `next_action = 'pause'` |
| `interview-frontend/spec.md:857-858` | Pause/Resume row in state machine table: `end_of_question → paused` edge | Between-competency pause is candidate-optional and removed; SA-04 scheduled pause replaces it | Live mute-pause (`live ⇄ paused`) retained; only the candidate-optional between-competency path removed |
| `interview-frontend/spec.md:867-871` | `paused` state description: "entered from end_of_question" | Narrowed; paused is live mute-pause only (already shipped in v0.6.3), not candidate-optional between-competency pause | Narrowed: entry from `live` only (Pause button); exit to `live` only (Resume); SA-04 pause is separate (`end_of_question` state) |
| `interview-session/spec.md:22` | Non-goal: "`pause_every_n_competencies` UX gate (C7b)" | No longer a pure deferral; server now computes and sends the directive | Server computes next_action; `/end` response carries the directive |
| `interview-frontend` requirement | Skip control remains in UI | Candidate's ways to end a live question now only: avatar completion or timer. Skip action removed. `skipped` value remains for historical rows and operator paths (Decision 1) | Requirement: "Skip control removed from the live interview UI" (no Skip control anywhere) |

**Destructive-delta impact assessment**: All deletions are superseded by more specific implementations, not abandoned:
- Unconditional interstitial → conditional (SA-04 pause screen or none)
- Client-side arithmetic → server-directed (no guessing, no arithmetic)
- Between-competency pause → scheduled pause (server-governed, per project config)
- False non-goal → correct server-enforced implementation

**No ratified requirement is silently dropped.** The bounded re-offer closes an open product decision (CLAUDE.md #4, retry semantics — at least for the competency case); no requirement is violated.

---

## Delivered Implementation

### API (v0.23.0, v0.24.0, v0.25.0 — all deployed to Railway production)

**PR 1 (v0.23.0)**: `error_count` migration + bounded re-offer + completion tally
- Migration: `unsignedTinyInteger('error_count')->default(0)` on `interview_sessions`, with backfill `SET error_count = 1 WHERE status = 'error'`
- `MAX_ERROR_ATTEMPTS = 2` on `InterviewSession`
- `settleCompletionIfFinished()` extracted, three call sites (D5): 
  - Site 1: `/end` step 4 (CAS condition)
  - Site 2: `/start` on provider success (if all competencies terminal)
  - Site 3: `/start` on returning participant whose competencies are all terminal
- Completion tally: `whereIn('status', ['completed','timeout','skipped'])->orWhere(fn ($q) => $q->where('status', 'error')->{exhausted-re-offer condition})`
- `ResetSessionForRetry` shared action extracted from `RecoverFailedParticipant`
- Ratified decision: no remediation for participants already stranded in production pre-migration (they are settled on return via site 3)

**PR 2 (v0.24.0)**: `/start` and `/end` contract additions
- `/start` response: `question_context.total_competencies` (int) + `competency_ordinal` (additive, backward-compatible)
- `/end` response: body widened from `null` to `{ended_competencies, total_competencies, next_action: 'continue'|'pause'|'done'}`
- `next_action` computation (inside `/end` transaction):
  - `ended_competencies === total_competencies` → `'done'`
  - `ended_competencies % pause_every_n === 0 && pause_every_n !== null` → `'pause'` (unless done)
  - Otherwise → `'continue'`
- Regenerated `api/openapi.json` → fed to frontend typed-client generation

**PR 3 (v0.25.0)**: `OpeningTextComposer` re-offer variant
- New `retry` variant alongside existing `first`/`next`/`resume`
- Locale-keyed in it.json and en.json (`interview.opening.retry`)
- Wired in controller: if `$nextCompetency['reoffer'] === true` → variant = 'retry'
- Asserted at provider request body payload shape test

### Frontend (v0.7.0, v0.8.0 — both deployed to Railway production)

**PR 1 (v0.7.0)**: Directive consumption, Skip removal, SA-04 pause screen, transition panel stub
- `callEnd()` returns `next_action` from response body; `advanceAfterQuestion(directive)` routes `'continue'` → auto-advance, `'pause'` → pause screen, `'done'` → done screen
- HTTP 409 treated as successful no-op (losing call in avatar/timer race)
- Skip control removed from UI; `interview.live.skip` removed from both locales
- Progress indicator: `question_index + 1` / `total_competencies` (server-reported, stable)
- Re-offer opening variant: `reoffer` flag → select `retry` variant from `OpeningTextComposer`
- Timer suspension: pause on `live → paused`, resume continues from same remaining second
- `paused` state: entry from `live` (Pause button), exit to `live` (Resume, sole destination); `end_of_question → paused` edge deleted
- Invariant: `pause()` can only happen from `live`; Resume always returns to `live`
- 765 unit tests passing (net +2 from prior)

**PR 2 (v0.8.0)**: Transition panel (D12 implementation)
- Added connecting/between-competencies transition panel: fires on `connecting && !avatarMounted && hasRunACompetency > 0`
- `hasRunACompetency` computed from server-sent `endedCompetencies > 0`, not a page-local flag
- First-connect skeleton (no avatar) preserved separately on `connecting && !avatarMounted && hasRunACompetency === 0`
- Removed stale test that asserted nothing meaningful ("resuming from end_of_question... kept passing only because pause() from that state is now a no-op")
- E2E: Real live-pause/resume test added (pause during live, resume same competency), pre-existing `unsupported-gate` visual baseline verified red on develop before this change (pre-existing, not a regression)

---

## Verification Summary

**Status**: PASS WITH WARNINGS (from verify-report #1257, re-run 2026-08-20)

**Six CRITICAL findings from the first verify pass** — all genuinely fixed, independently re-verified:

1. ✅ `apply-progress.md` exists (reconstructed from shipped commits, honestly labeled as such)
2. ✅ `interview-session/spec.md` field name `completed_competencies` → `ended_competencies` (grep: 0 old, 7 new)
3. ✅ `interview-conversation/spec.md` variant name `reoffer` → `retry` (grep: 0 old as variant name; 7x as expected)
4. ✅ D12 transition panel built per design: `hasRunACompetency` from server tally `endedCompetencies > 0`, i18n keys present
5. ✅ Stale unit test removed with removal reason recorded in place
6. ✅ E2E Pause/Resume test rewritten with real live-pause/mic-mute/resume/same-competency assertion chain

**Remaining warnings** (non-blocking, judged acceptable to archive):

- **V-7** (D2 — two queries instead of promised one): `resolveNextCompetency()` runs two separate `pluck()` calls for status and error counts. Functionally correct, fully tested. Documentation-accuracy nit, not a spec violation. Fast-follow one-liner if convenient.
- **V-8** (No dedicated migration-backfill test): `error_count = 1` backfill on `WHERE status = 'error'` is correct; already executed in production. No unit test seeds a pre-migration error row to assert the backfill. Worth a fast-follow test (one-shot migration, already deployed), not a gate.

**Disclosed known gaps** (acceptable to archive):

- `App\Services\Interview\NextCompetency` not created (D2 partial): behavior correct, fully tested via array-key `reoffer`. Disclosed in design and apply-progress. Ordinary technical debt.
- WebKit E2E not run locally: CI covers it (standard practice). Chromium: 59 passed, 1 pre-existing failure (`unsupported-gate` visual baseline, verified red on develop without this change).
- `question_index` off-by-one: deliberately out of scope (D6). Routes around it with `competency_ordinal`. Tracked as own follow-up.

**Test suites re-run from scratch**:
- API: `php artisan test --parallel` → 1988 total, 1983 passed, 5 skipped, 0 failed (identical to before)
- Frontend: `bun run test:unit` → 765/765 passing (net +2); typecheck clean; lint 0 errors
- Coverage gate: requires `php -d memory_limit=2G` (default 128M dies building report); not a failing gate

**Verdict**: sdd-archive may proceed. All CRITICALs resolved. Two WARNINGs and three known gaps judged non-blocking.

---

## Carrying Forward (Beyond This Change)

The following are intentionally deferred and are NOT addressed by this change, even though the proposal or design surfaced them:

### Owed (separate changes)

1. **Repair `question_index = -1` on first competency** — `position` written 0-based by all writers; query subtracts one in `resolveNextCompetency()`. This design routes around it with `competency_ordinal` (sent on `/start`). The column repair requires a dedicated migration + test, and is out of scope here. Its own change is tracked.

2. **D2 partial: Extract `App\Services\Interview\NextCompetency`** — currently returns an array with added `reoffer` key. The readonly result object is owed. Belongs with PR 3, which changes that return shape anyway.

3. **D2 deviation: One query instead of two** — `resolveNextCompetency()` runs two `pluck()` calls (status, error_count). Design promised one. Worth a fast-follow optimization, not a gate.

4. **D8 deviation: Dedicated migration-backfill test** — backfill logic is correct and ran in prod. Unit test coverage missing. Worth a fast-follow.

### Ratified Open Decisions (not this change)

- **CLAUDE.md #4 (retry semantics)**: This change closes it for the **competency case** (bounded single re-offer). The **scoring case** (C9 chain-PR 4 / RT-B) remains open.
- **CLAUDE.md #2 (GDPR retention)**: Out of scope; retention strategy is a data-controller decision, deferred.
- **CLAUDE.md #5 (deadline semantics)**: Out of scope; calling system owns scheduling.
- **FR-006 (multi-test portal) and white-label**: Underspecified (two lines of brief). Parked from C13 scope.

### Pattern Observations (Learned)

Recurring lesson across multiple spec sites and commits: **State the invariant, not the census.**

Comments that assert "no organization has X" (e.g., "no active avatar template", "no backend column") are true *at that moment of writing* but become false when the census changes. They expire silently and mislead future readers.

Comments and non-goals should state what the CODE guarantees — e.g., "the server computes the directive" or "the count scopes to project_id" — not what the DATA happens to show. These invariants are timeless and actionable.

Example: `interview-frontend/spec.md:24-25` asserted "no backend column exists". The column existed the entire time; the statement was a misreading of the census at that moment. The corrected invariant is "the server computes and sends the directive" (what the code does), not "the column doesn't exist" (what the data happened to be).

---

## Archive Integrity Check

- ✅ All proposal/spec/design/tasks artifacts present and moved
- ✅ Apply-progress reconstructed and validated (moved)
- ✅ Verify-report generated and moved
- ✅ Delta specs merged into main specs (3 specs: interview-frontend, interview-session, interview-conversation)
- ✅ Factual correction applied (pause_every_n_competencies non-goal deleted, server-directed behavior specified)
- ✅ Tasks checklist completed (5.1, 5.2 checked; 5.3 = this archive)
- ✅ No unchecked implementation tasks remain in tasks.md
- ✅ Change folder moved from `openspec/changes/interview-continuous-flow/` to `openspec/changes/archive/2026-08-20-interview-continuous-flow/`
- ✅ Active changes directory no longer contains interview-continuous-flow

**Status**: Ready for SDD cycle closure. All artifacts archived and traceability preserved via Engram observation IDs.
