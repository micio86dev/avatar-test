# Verification Report

**Change**: interview-continuous-flow
**Version**: api v0.25.0 / frontend v0.7.0 (per proposal)
**Mode**: Strict TDD (source inspection + real runtime execution)

## Artifact Retrieval

- `proposal` — Engram `sdd/interview-continuous-flow/proposal` (#1246) — read.
- `spec` (3 delta files) — read from filesystem `openspec/changes/interview-continuous-flow/specs/{interview-session,interview-frontend,interview-conversation}/spec.md` (Engram copy #1249 is the same content, hybrid store).
- `design.md` — read from filesystem (620 lines) and Engram #1250 — read in full.
- `tasks.md` — read from filesystem (224 lines) — read in full.
- `apply-progress` — **NOT FOUND.** Searched Engram under `sdd/interview-continuous-flow/apply-progress` and broader queries (`apply progress`, `apply`); searched the filesystem change directory for any `apply-progress*` file. **None exists.** Strict TDD is active per `openspec/config.yaml`, so a "TDD Cycle Evidence" table was expected from the apply phase and is entirely absent. Verification below is therefore based on direct source/test inspection rather than cross-referencing a reported evidence table — see Issue V-1.

## Completeness (tasks.md)

| Metric | Value |
|--------|-------|
| Tasks total (excluding Close-out 5.x) | 34 |
| Tasks checked `[x]` | 34 |
| Close-out tasks (5.1–5.3) | 3, correctly left `[ ]` (this verify run is 5.1) |
| Tasks checked but **not actually complete on inspection** | 2 (see V-4, V-5 below) |

## Build & Tests Execution (actually run, not taken on trust)

**api** — `php artisan test --parallel` (`/Users/alessandromicelli/Desktop/beai/api`):
```
1988 total, 1983 passed, 5 skipped, 0 failed, 5440 assertions
Line coverage: 94.05% overall; InterviewSession 100%, ResetSessionForRetry 100%,
RecoverFailedParticipant 100%, InterviewController 91.67% lines / 63.16% methods,
OpeningTextComposer 100%.
```
Matches the reported "1983 passing" claim. ✅

**frontend** — `bun run test:unit` (`/Users/alessandromicelli/Desktop/beai/frontend`):
```
44 files, 763 tests, 763 passed, 0 failed
```
Matches the reported "763 passing" claim. ✅ (Includes the stale test flagged as V-5 below, which passes for the wrong reason.)

**frontend typecheck** — `bunx nuxi typecheck`: exit 0, no TS errors (only pre-existing shadcn `UiX` duplicate-name warnings, unrelated to this change). Matches "typecheck clean". ✅ Note: Nuxt's typecheck pass does not cover `tests/unit/**`, so it would not have caught the dead `competencies` option still passed by ~60 call sites in `use-interview-session.spec.ts` — harmless (ignored at runtime) but confirms typecheck alone did not validate test-file cleanliness.

**frontend lint** — `bun run lint`: 0 errors, 10 pre-existing warnings, all in unrelated `app/components/ui/*` shadcn primitives (not touched by this change). Matches "lint 0 errors". ✅

**E2E** — not re-run in full (requires a live dev server per project config); source-inspected instead. Tasks.md's claims about pass/fail counts (`59 passed / 1 failed`, the pre-existing `unsupported-gate` baseline) were not independently re-executed, but the **content** of the "Pause / Resume" E2E describe block was inspected directly — see V-6.

## Design Coherence — D1 through D13

| Decision | Followed? | Evidence |
|---|---|---|
| **D1** — `error_count` durable bound, never touched by the reset | ✅ Yes | `ResetSessionForRetry.php` explicitly omits `error_count`; `markSessionError()` is confirmed the sole writer (`InterviewController.php:905`); pinned by `ResetSessionForRetryTest.php:99-107` and `CompletionCasTest.php:61-85`. |
| **D2** — re-offer branch ordered between the existing two | ✅ Yes (ordering) / ⚠️ deviation (query cost) | `resolveNextCompetency()` (`InterviewController.php:507-583`): `pending\|in_corso` branch first (547), `error && count<MAX` second (567), fallthrough skip last — matches spec exactly. **Deviation**: design states "the existing `pluck` becomes `->get([...])->keyBy(...)`. Same query, one more column" (one query). Shipped code runs **two separate queries** (`$existingStatuses` at 522 and `$errorCounts` at 527) instead of the single combined query the design specified. Functionally correct, but the design's explicit "no new query" cost claim is not what shipped. WARNING, not spec-breaking. |
| **D3** — `ResetSessionForRetry` extracted verbatim, shared by both paths | ✅ Yes | `api/app/Actions/InterviewSession/ResetSessionForRetry.php` — matches the docblock contract exactly; `RecoverFailedParticipant`'s loop body calls it (confirmed via `CompletionCasTest.php:300-336`, `338-383`). |
| **D4** — operator path stays unbounded | ✅ Yes | `CompletionCasTest.php:300-336` ("operator recovery stays UNBOUNDED — it does not consult error_count") and `:338-383` (reset session resumed, not re-offered) — both halves asserted, real DB state checked, not inferred. |
| **D5** — CAS gains exactly 3 call sites, site 2 after the classification switch | ✅ Yes | Site 1: `InterviewController.php:335` (inside `/end`). Site 2: `:802`, called from `handleProviderFailure()` **after** the `match($e->failureClass())` switch (774-786), exactly as designed, with the docblock reproducing the design's own "settle first would..." rationale. Site 3: `:109`, inside `start()`'s `no_competency_remaining` branch, before the 422. All three route through the single `settleCompletionIfFinished()` (`:835`). Pinned by `CompletionCasTest.php:114-176` (ClientError doesn't burn candidate; Upstream doesn't dispatch scoring) and `:133-154` (terminal error on last competency reaches `in_valutazione`). |
| **D6** — `competency_ordinal` from the ordered list's array index, `question_index` untouched | ✅ Yes | `InterviewController.php:533,538-543`: `foreach ($all->values() as $index => $row)`, `'competency_ordinal' => $index + 1`; `question_index` still `$row->position - 1` unchanged. Pinned by `ServerDirectedFlowTest.php:71-88` ("competency_ordinal is 1-based on the FIRST competency, where question_index is not") — the exact off-by-one regression this decision exists to route around. |
| **D7** — `done` evaluated before `pause`; server-computed directive | ✅ Yes (logic) / ❌ **spec field-name mismatch** | `buildDirective()` (`InterviewController.php:399-418`): `match(true)` puts `$ended >= $total => 'done'` **first**, cadence modulo second. Confirmed by `ServerDirectedFlowTest.php:191-211` ("done beats pause on the final competency"). **BUT**: shipped response key is `ended_competencies` (design.md D7 explicitly renamed it from the proposal's `completed_competencies`, with a stated rationale — "a second false statement... would contradict the domain's own vocabulary"). The **delta spec** `specs/interview-session/spec.md` was never updated to match: it still says `completed_competencies` **7 times**, including in every Given/When/Then scenario body (`:40,48,60,68,86,92,100`). Code, tests (`ServerDirectedFlowTest.php:125`, `CompletionCasTest.php`), and the frontend (`useInterviewSession.ts:346,358`) all agree on `ended_competencies`. Only the spec artifact disagrees with itself vs. the design decision it's supposed to encode. **See V-2 — CRITICAL, spec correction owed and not done.** |
| **D8** — participant-sso scenarios hold verbatim | ✅ Yes | `CompletionCasTest.php:338-383` — recovered session is `pending`, resumed via the untouched RESUME branch, `error_count` unchanged after resume. |
| **D9** — status enum untouched, no new status | ✅ Yes | No new enum value found in the migration or `InterviewSession`; "re-offered" stays `pending` + `error_count > 0`. |
| **D10** — 4th `OpeningTextComposer` variant | ✅ Yes (behavior) / ❌ **spec naming mismatch** | `OpeningTextComposer::VARIANTS = ['first', 'next', 'resume', 'retry']` (`:50`); selection precedence `resume > retry > first > next` implemented exactly (`InterviewController.php:211-216`), matching D10. Pinned by `CompletionCasTest.php:429-479` (asserts `opening.retry` copy is actually sent to the provider). **BUT**: the delta spec `specs/interview-conversation/spec.md` names the literal variant `reoffer` throughout ("MUST compose the opening greeting using a NEW `reoffer` variant", "THEN the `reoffer` variant is selected, not `first`/`next`/`resume`") — a name that does not exist anywhere in the shipped code (`rg -n "reoffer" --type=php` finds it only as the unrelated boolean array key `nextCompetency['reoffer']`, never as a compose() variant string). Unlike D13 (below), this discrepancy was never flagged for correction anywhere in design.md or tasks.md. **See V-3 — CRITICAL, spec/code naming contradiction, not caught by the close-out task.** |
| **D11** — client consumes directive; absent/unknown degrades to `pause`; 409 → no transition | ✅ Yes | `advanceAfterQuestion()` (`useInterviewSession.ts:466-481`): `'noop'` returns immediately (472); `'continue'` calls `confirmDevices()` immediately (474-478); anything else (including `null`) falls to `transitionTo(directive === 'done' ? 'done' : 'end_of_question')` (480) — `null`/unknown correctly lands on the pause screen, never `done`. `callEnd()` (339-397) already normalizes unrecognized `next_action` values to `null` (367) and 409 to `'noop'` (384). Matrix pinned by `use-interview-session.spec.ts` lines 942-1100 (continue/pause/done/absent/unrecognized/409 all covered with real assertions). |
| **D12** — named inter-competency transition panel, distinct from the first-connect skeleton | ❌ **NOT implemented** | Design requires a distinct panel rendering when `state === 'connecting' && !avatarMounted && aPreviousCompetencyHasRun`, with i18n keys `interview.transition.*` and `aria-live="polite"`/`aria-busy="true"`. `session.vue:37-46` has **one single** `connecting && !avatarMounted` block, used for both the first connect and every subsequent one — no branching, no distinct panel. `rg -n "transition" app/pages/interview/session.vue i18n/locales/{it,en}.json` returns **zero** matches for `interview.transition.*` anywhere in the frontend. **See V-4 — CRITICAL, tasks 4.9/4.10 marked done but D12 was never built.** |
| **D13** — `paused` survives, `live` sole entry/exit, `pause()`/`resume()` bypass `transitionTo()`, standalone section removed | ✅ Yes (implementation) / ⚠️ stale test left behind | `pause()` (`:653-658`) and `resume()` (`:666-671`) assign `state.value` directly, never call `transitionTo()`. `pause()` guards on `state.value !== 'live'` only (654) — the `end_of_question` entry edge is gone. `session.vue:112-122` keeps the in-avatar paused panel; the standalone section is gone, replaced with an explanatory comment (152-156). Invariant `paused ⇒ avatarMounted` pinned in `tests/unit/interview-session-page.spec.ts:353` ("renders NO standalone paused screen — paused always implies a mounted avatar"). The already-known spec/design conflict (state-machine line, `interview-frontend/spec.md:236` et seq.) **is** corrected in the live delta spec text (confirmed by direct read — `paused` is present, live⇄paused edges documented). **BUT** a stale unit test from the pre-D13 world was left in the suite — see V-5. |

## Frontend architectural claim — `question_index` typing

Unrelated finding, not part of D1–D13 but worth recording: `isValidStartResponse()` (`useInterviewSession.ts:160-187`) still types `question_index: string` in its guard shape and the `startSession` response type, while the API contract (`interview-session/spec.md`) documents `question_index` as an integer (`0-based`). This predates this change (not introduced by it) and is out of scope — noted only because D6 leans on `question_index` staying "deliberately not stored," which is confirmed true (`useInterviewSession.ts:520-525` — comment explains why).

## Issues Found

### CRITICAL

**V-1 — No `apply-progress` artifact exists; Strict TDD's required "TDD Cycle Evidence" table was never produced.**
`openspec/config.yaml` has `strict_tdd: true`. The verify skill's Strict TDD module requires reading `apply-progress` and flags CRITICAL if no TDD Cycle Evidence table is found ("apply phase did not follow the protocol"). Searched Engram (`sdd/interview-continuous-flow/apply-progress` and broader terms) and the filesystem change directory — no such artifact exists in any form, for any of the four chained PRs. Mitigating: `tasks.md` itself carries dense RED/GREEN per-task annotations that partially substitute, and this report independently re-derived test/behavior evidence by reading the actual test files and running the suites — but the formal protocol artifact is missing and should be produced or the gap acknowledged explicitly before archive.

**V-2 — `interview-session/spec.md` still specifies `completed_competencies`; shipped code and tests use `ended_competencies`.**
Design.md D7 explicitly renamed the field with a stated rationale ("Calling that 'completed' would put a second false statement into a contract this change exists to de-falsify"). The delta spec was never updated to match — it still names the field `completed_competencies` in the requirement prose and in **all 5** of its Given/When/Then scenario bodies (`specs/interview-session/spec.md:40,48,60,68,86,92,100`). This is a real, unresolved artifact-vs-shipped-code contradiction of the exact kind D13 required (and received) a correction for — this one was missed. Task 5.2 ("Confirm no artifact still disagrees with another... re-check before archive") has not yet run; this is precisely what it should catch.

**V-3 — `interview-conversation/spec.md` names the 4th `OpeningTextComposer` variant `reoffer`; shipped code names it `retry`.**
Confirmed via `rg -n "reoffer" --type=php` across the whole `api/` tree: the string `reoffer` never appears as a `compose()` argument or in `OpeningTextComposer::VARIANTS`; only as an unrelated boolean flag key (`$nextCompetency['reoffer']`) that triggers selection of the `'retry'` variant. The spec's two scenario assertions ("THEN the `reoffer` variant is selected, not `first`/`next`/`resume`") describe a literal value that does not exist in the implementation. Unlike D13, design.md never flagged this naming mismatch for correction, and it was not caught by the close-out check.

**V-4 — Tasks 4.9 and 4.10 are marked `[x]` but D12 (the named inter-competency transition panel) was never built.**
Task 4.9 claims: "`session.vue`: ... named transition panel (D12) ..."; task 4.10 claims: "i18n: ... add `interview.scheduled_pause.*` and `interview.transition.*` in it and en." Direct inspection of `session.vue` and both locale files (`i18n/locales/{it,en}.json`) confirms `scheduled_pause.*` exists but `interview.transition.*` does not exist anywhere in the frontend, and the connecting-screen skeleton is not conditioned on "a previous competency has run" — it is one undifferentiated block for every connect. This is a design decision (D12) presented as shipped in both the design's File Changes table and tasks.md that was not implemented at all — a third instance of task over-marking, beyond the two the requester says they already caught (2.9's honest PARTIAL note does not cover this one).

**V-5 — Stale pre-D13 unit test passes for the wrong reason (`use-interview-session.spec.ts:908`).**
`it('resuming from an end_of_question pause returns to end_of_question, not live', ...)` (lines 908-924) pauses and resumes from the `end_of_question` state and asserts the final state is `end_of_question`. Under the shipped D13 implementation, `pause()` guards on `state.value !== 'live'` (returns immediately, no-op) and `resume()` guards on `state.value !== 'paused'` (also a no-op, since pause() never fired) — so the assertion trivially holds because **neither function's transition logic ever executes**. The test's own docstring comment ("resume() must return to wherever pause() was entered from... between-competencies pause") describes the exact behavior D13 ratified as **removed**. This is the "incomplete TDD cycle / preconditions prevent the code path from running" pattern the Strict TDD assertion-quality audit classifies as CRITICAL — structurally identical to the assertion-free E2E test the requester says they already removed elsewhere, just in a different suite. It was not caught during the D13 rewrite's close-out.

**V-6 — The only E2E test in the "Pause / Resume" describe block does not test pause or resume (`interview-flow.spec.ts:689-705`).**
`test('end_of_question → pause → paused screen visible (structural — state machine covered by Vitest)', ...)` — its title claims to verify the pause/resume flow, but its body clicks consent and asserts only that the **device-check heading** is visible; it never reaches `live`, never presses Pause, never reaches `end_of_question` or `paused`. Its own inline comment concedes: "full end_of_question path requires real provider events; covered by unit tests" — but the misleading title remains, and this is the **only** test in that describe block. Design.md's Testing Strategy table requires an E2E scenario: "Pause during a live question, resume, and finish the same competency — no restart, no lost turn | Playwright chromium + webkit," and task 4.12 claims this was delivered ("Done, with two notes"). It was not: there is no Playwright test anywhere in the suite that drives a live pause → mic-mute assertion → resume → same-competency-continues cycle. This is exactly the shape of test the requester asked to be hunted for ("I removed one E2E that asserted nothing at all; look for others of that shape") — found in a second location.

### WARNING

**V-7 — D2's "same query, one more column" cost claim does not match the shipped implementation.**
`resolveNextCompetency()` runs two separate queries (`$existingStatuses`, `$errorCounts`) instead of the single combined `->get(['competency_code','status','error_count'])` the design specified. Functionally correct and covered by tests; only the stated query-cost rationale in design.md is now inaccurate. Does not break any spec scenario.

**V-8 — Design's own Testing Strategy row for the migration backfill has no dedicated test.**
Design.md's Testing Strategy table lists: "Feature (api) | Migration backfill: a pre-existing `error` row gets exactly one re-offer | Seed at the old schema, migrate, assert." No test file in `tests/` seeds a pre-migration state and runs the `2026_08_20_120000_add_error_count_to_interview_sessions` migration to assert the `error_count = 1` backfill. The migration's `up()` logic was read directly and is correct, but this specific promised test does not exist. This is not a formal spec scenario (the delta specs carry no Given/When/Then for it), so it is a design-vs-test-suite gap rather than a spec violation.

### SUGGESTION

**V-9** — `use-interview-session.spec.ts` still passes a `competencies` option to `useInterviewSession({ competencies })` in ~60 call sites via the `createLiveSession()` helper, even though `UseInterviewSessionOptions` no longer declares that field (task 4.8: "`competencies` option deleted"). It is silently ignored at runtime and does not affect test outcomes — `bunx nuxi typecheck` doesn't cover `tests/unit/**` so this went unflagged. Harmless, but worth a cleanup pass so a future reader doesn't assume the option still does something.

## Correctness (Static + Runtime Evidence)

| Requirement | Status | Notes |
|---|---|---|
| Cross-tenant isolation (interview-session) | ✅ COMPLIANT | Dedicated, real DB-asserting scenarios in `ServerDirectedFlowTest.php` ("directive counts and cadence resolve strictly within the organization"; "tally never counts another organization ended sessions") and `CompletionCasTest.php` ("the tally never counts another organization sessions") — all run against real orgs/participants/sessions, not mocked. Satisfies `rules.specs`. |
| Bounded single re-offer (D1/D2/D4/D5) | ✅ COMPLIANT | `CompletionCasTest.php` (multiple tests), `ServerDirectedFlowTest.php`, `ResetSessionForRetryTest.php` — all real HTTP+DB assertions. |
| `/start` `competency_ordinal`/`total_competencies` (D6) | ✅ COMPLIANT | `ServerDirectedFlowTest.php:55-107`. |
| `/end` directive (D7) | ⚠️ PARTIAL | Behavior compliant and tested; response field name contradicts the delta spec text (V-2). |
| Re-offer opening variant (D10) | ⚠️ PARTIAL | Behavior compliant and tested; variant name contradicts the delta spec text (V-3). |
| Client directive consumption incl. 409/absent/unknown (D11) | ✅ COMPLIANT | `use-interview-session.spec.ts:942-1100`. |
| Inter-competency transition panel (D12) | ❌ UNTESTED / NOT IMPLEMENTED | V-4. |
| `paused` state survival + invariant (D13) | ✅ COMPLIANT (impl) / ⚠️ stale test | `interview-session-page.spec.ts:353`; V-5. |
| E2E: live pause/resume same-competency continuity | ❌ UNTESTED | V-6. |
| E2E: cadence-driven directive screens | ✅ COMPLIANT | `interview-flow.spec.ts:472-589` — real assertions, replaced the empty test the requester already flagged. |

## Verdict

**FAIL** — not archive-ready as-is.

The implementation is functionally correct on every axis that was actually built (D1, D2 ordering, D3, D4, D5, D6, D7 logic, D8, D9, D10 behavior, D11, D13 implementation), and both real test suites are green (api 1983/1983, frontend 763/763), typecheck and lint clean. But six CRITICAL issues block a clean archive: the required Strict TDD apply evidence artifact is missing (V-1); two delta-spec files still contradict shipped code on literal field/variant names in a way the design itself already changed but never routed back to `sdd-spec` (V-2, V-3, mirroring the D13 correction that *was* done correctly); one full design decision (D12) is marked done in tasks.md but was never implemented (V-4); and two tests — one unit, one E2E — pass while testing nothing meaningful about the behavior their titles/comments claim to cover (V-5, V-6), which is the same defect class the requester already found and fixed once.

**Recommendation**: route back to `sdd-apply` to (a) build D12's transition panel and its E2E-worthy live-pause/resume coverage, (b) fix or delete the two misleading tests, and to `sdd-spec` to reconcile `completed_competencies`→`ended_competencies` and `reoffer`→`retry` before `sdd-archive` runs.
