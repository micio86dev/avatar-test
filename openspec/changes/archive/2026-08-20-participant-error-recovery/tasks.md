# Tasks: Participant Error Recovery

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | ~620–720 (excl. openapi.json churn) — **actual: ~1863 excl. generated openapi.json/types.ts** |
| 400-line budget risk | High — **confirmed: PR2 (945) and PR3 (667) both individually exceed budget, marked `size:exception`** |
| Chained PRs recommended | Yes — implemented as 5 branches (PR1, PR2a, PR2, PR3, PR4) |
| Suggested split | PR0 gate → PR1 → PR2a → PR2 → PR3 → PR4 |
| Delivery strategy | ask-on-risk (could not confirm interactively at apply time — user unavailable) |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|---|---|---|---|
| 0 | Branch-base grep gate | pre-PR1 | Base = tracker branch; not a diff |
| 1 | Refusal-reason split, honest 409 | PR1 | Base: tracker branch. ~150 lines |
| 2a | `started_at` fix (D2b) | PR2a | Base: PR1 branch. ~30 lines; split out only if PR2 > 400 |
| 2 | Recovery capability (the crux) | PR2 | Base: PR2a (or PR1) branch. ~300 lines |
| 3 | Backoffice recovery action | PR3 | Base: PR2 branch. Blocked on PR2's `openapi.json` + wrapper submodule pointer. ~150 lines |
| 4 | Frontend error copy + guard | PR4 | Own submodule chain, independent. ~40 lines |

## PR0: Pre-Apply Branch Gate (blocking, not a diff)

- [x] 0.1 Before first commit: `grep markParticipantFailed api/app/Http/Controllers/Candidate/InterviewController.php` and confirm `app/Enums/ProviderFailureClass.php` exists. If either is missing, STOP — wrong base (D0). **Re-verified at apply time (2026-08-20)**: `api/.git/HEAD` on `feature/liveavatar-contract-alignment-pr6-tavus-concurrency`; `markParticipantFailed()` present at `:697-708`; `app/Enums/ProviderFailureClass.php` exists. Gate PASSED.

## PR1: Refusal-Reason Split + Honest 409 (~150 lines; actual 129+102 = 231 lines incl. openapi.json)

Branch: `feature/participant-error-recovery-pr1-refusal-split` (base: `feature/liveavatar-contract-alignment-pr6-tavus-concurrency`).

RED (correct first, per design):
- [x] 1.1 Correct `api/tests/Unit/Sso/EntryLinkMinterTest.php:90-111`: assertion `Terminal`→`Completed`; add sibling test asserting `Failed` for `errore`.
- [x] 1.2 Extend `api/tests/Feature/C6/SsoLinkMintTest.php:257`: assert 409 body `message` + `reason` for both `completed` and `failed`; keep the 409-only assertion. Also extended `tests/Feature/EntryLink/EntryLinkMintTest.php` (operator-facing mint) with the same assertions, and corrected the `SsoLinkResponseGoldenTest.php` golden 409 body (additive `reason` field).
- [x] 1.3 Add mint-controller test: `errore` refusal message never contains "completed" (both `EntryLinkController` and `SsoLinkController`).

GREEN:
- [x] 1.4 `api/app/Exceptions/Sso/EntryLinkRefusalReason.php`: split `Terminal` → `Completed` + `Failed`.
- [x] 1.5 `api/app/Support/Sso/EntryLinkMinter.php:61-63`: select reason by participant status.
- [x] 1.6 `api/app/Http/Controllers/Api/EntryLinkController.php:83-86`: two-arm 409 body + `reason`.
- [x] 1.7 `api/app/Http/Controllers/M2m/SsoLinkController.php:94-97`: same, per-caller literals.

Verify:
- [x] 1.8 Full Pest suite green (1871/1876, 5 pre-existing skipped) in isolation on the PR1 branch; `Feature/C6/SsoExchange403Test.php:173` unaffected; `api/openapi.json` regenerated (102 changed lines).

Acceptance: an `errore` mint refusal never says "already completed" in either controller; `reason` is machine-facing, not localized; both stay HTTP 409. MET.

## PR2a: `started_at` Fix — D2b (~30 lines; actual 52 lines)

Branch: `feature/participant-error-recovery-pr2a-started-at-fix` (base: PR1 branch).

RED:
- [x] 2a.1 Audited existing fixtures/tests for a `Participant` built with `started_at` set while `status = 'in_attesa'` — none found (`startParticipant()` helpers only set `status`, never `started_at`).
- [x] 2a.2 New feature test in `InterviewStartTest.php`: recovered participant (`in_attesa`, `started_at` already set) re-entering keeps `started_at` unchanged and gets the `next` greeting (asserted via the HeyGen `opening_text` request body), never `first`. Confirmed RED first (assertion failed against the unfixed code).

GREEN:
- [x] 2a.3 `api/app/Http/Controllers/Candidate/InterviewController.php:135`: `$isFirst = $participant->status === 'in_attesa'` → `$isFirst = $participant->started_at === null`.

Verify:
- [x] 2a.4 `Feature/C7a/InterviewStartTest.php` (all 16 cases, extended), `Feature/C8/InterviewStartCompositionTest.php` stay green. Full Pest suite green in isolation on the PR2a branch (1872/1877, 5 skipped).

## PR2: Recovery Capability — the crux (~300 lines; actual 945+98 = 1043 lines incl. openapi.json — SIZE:EXCEPTION, see risks)

Branch: `feature/participant-error-recovery-pr2-recovery-capability` (base: PR2a branch).

Phase 1 — Foundation:
- [x] 2.1 RED: unit test `errore → in_attesa` allowed, `→ in_corso`/`→ in_valutazione`/`→ completato` still rejected (extended `Unit/C7a/ParticipantTransitionsC7aTest.php`).
- [x] 2.2 GREEN: `api/app/Models/Participant.php:111-116`: added `'errore' => ['in_attesa']`; updated the transition-map docblock.
- [x] 2.3 GREEN: `ParticipantPolicy::recover()` — admin + operator; viewer denied.
- [x] 2.4 GREEN: `api/routes/api.php` — new `POST /api/participants/{id}/recover`, own `auth:api` + `TenantContext` group, adjacent to the Admin Read API block (not inside it).

Phase 2 — Core (D2 crux, sequenced before UI/copy work):
- [x] 2.5 RED — **non-negotiable**: full-cycle feature test (`tests/Feature/ParticipantRecovery/RecoverFailedParticipantTest.php`) — participant fails at competency 2 of 3 via `Upstream` 5xx → recover → re-enter → finish competencies 2 and 3 → participant reaches `in_valutazione`, `FinalizeInterview` dispatched exactly once. Written and observed RED FIRST (against no `RecoverFailedParticipant`/route/policy at all). Also caught and fixed a SECOND stranding bug beyond design's original D2 finding: `handleIssuePending()` only flipped `participant.status` to `in_corso` when `isFirstCompetency` was true, so a recovered participant resuming its failed competency would stay `in_attesa` forever — fixed alongside (see InterviewController.php diff).
- [x] 2.6 RED: resume-not-restart — asserted inline in the crux test (competency 1's session untouched; a manually-inserted partial utterance on the failed session is discarded and counted).
- [x] 2.7 RED: idempotent double-recover — second call observes `in_attesa` in-lock, returns 200, empty `competencies_reset`/zero `utterances_discarded`.
- [x] 2.8 RED: recover-vs-`/start` both interleavings (D6) — two dedicated tests: (a) `/start` already committed `in_corso` → recovery 409 `not_failed`; (b) a stale in-memory `errore` `Participant` instance still cannot self-transition to `in_corso` after a concurrent recovery (proves the existing `booted()` guard is sufficient, no new mechanism needed).
- [x] 2.9 RED: both refusal guards — `evaluation_already_delivered` (guard 1, checked first) and `nothing_to_recover` (guard 2), each its own test.
- [x] 2.10 RED: cross-tenant 404; viewer 403 with **403-before-404** ordering (asserted against a non-existent id too, proving existence never leaks).
- [x] 2.11 GREEN: `App\Actions\Participant\RecoverFailedParticipant` — `lockForUpdate`, in-lock status re-read, both guards, participant status reset, error-sessions reset to `pending` (cleared `provider_session_ref`/`ended_reason`/`ended_at`), delete those sessions' utterances only, interim `Log::info('participant.recovered (INTERIM — NOT the ratified audit trail...)', …)` per D7 payload shape (no `display_name`/`candidate_ref`/actor email).
- [x] 2.12 GREEN: `App\Http\Controllers\Api\ParticipantRecoveryController` — thin; `authorize('recover', ParticipantPolicy::MODEL)`; delegates with a raw int id; no literal `Participant::` (verified — docblock phrasing was corrected during implementation to avoid a false-positive arch-guard trip from prose alone).

Phase 3 — Regression guard (deliverable 8):
- [x] 2.13 RED: extended `Feature/C7a/InterviewStartTest.php` to 4 cases — `ClientError` (4xx) and `Throttle` (429) × `in_attesa`/`in_corso` origin — participant untouched in all four (the 2 new in_corso-origin cases pass unmodified against already-shipped `liveavatar-contract-alignment` behavior, confirming no regression).

Phase 4 — Verify:
- [x] 2.14 `Arch/C11/AdminTenancySafetyArchTest.php` (all 3 tests) stays green against the new controller/action.
- [x] 2.15 Full Pest suite green (1884/1889, 5 pre-existing skipped, 0 failures/errors) on the PR2 tip branch (final combined state); `api/openapi.json` regenerated (98 additional changed lines for the new endpoint).

Acceptance: an operator recovers a stuck `errore` candidate and that candidate completes the interview end-to-end; both refusal guards enforced with 409 + `reason`; idempotent double-recover; `started_at` never clobbered; `errore→in_corso`/`in_valutazione` still throw `ParticipantTransitionException`. MET — proven by the full-cycle crux test.

**SIZE:EXCEPTION** — PR2's diff (945 non-generated lines, ~1043 incl. openapi.json) is ~2.6x the 400-line review budget and the tasks forecast's own ~300-line estimate. Not split further: the action, its controller, and the full-cycle crux test are one atomic, correctness-critical unit (candidate state machine, ~95% coverage target per CLAUDE.md) that the design explicitly sequenced as inseparable ("sequence THIS before UI or copy work"). Splitting test from implementation across a PR boundary was rejected as worse for review quality than one oversized but coherent PR. Flagged here for the human reviewer to accept or request a follow-up split.

## PR3: Backoffice Recovery Action (~150 lines; actual 107 modified + 560 new = 667 non-generated lines, ~974 incl. openapi.json/types.ts — SIZE:EXCEPTION)

Branch: `feature/participant-error-recovery-pr3-backoffice` (base: backoffice `develop`, via an isolated `git worktree` — the currently-checked-out branch in the primary backoffice worktree had unrelated uncommitted WIP that was left untouched).

Gate:
- [x] 3.0 PR2's `api/openapi.json` was copied locally into the backoffice worktree and `bun run codegen` regenerated `types/api.ts` from it — this satisfies "PR3 cannot be typed before this" LOCALLY. **NOT satisfied**: the real wrapper submodule pointer move (api submodule commit → wrapper) was not performed — wrapper pointer changes are out of this task's git-discipline scope (repo-local branches only, no push). **A human must**: merge/tag the API's PR2 chain, advance the wrapper's `api` submodule pointer, then re-run `bun run codegen` in backoffice's real working tree (the copy used here is a manual stand-in, verified byte-identical to the api branch's own `openapi.json`).

Implementation:
- [x] 3.1 `backoffice/app/composables/useParticipantRecovery.ts` (mirrors `useEntryLinks.ts`).
- [x] 3.2 `backoffice/app/components/organisms/ParticipantRecoveryPanel.vue` — confirm step naming the competency to be re-asked + data-loss warning (sourced from the `sessions` prop, itself from `GET /participants/{id}/sessions` — no new read endpoint), optional free-text reason (500-char limit, trimmed).
- [x] 3.3 Mounted in `backoffice/app/pages/participants/[id].vue`'s own new `<Card v-if="!isViewer && (status === 'errore' || justRecovered)">` — NOT the existing entry-link card (a distinct card, adjacent to it), visible when `status === 'errore'`. **Deviation found and fixed during implementation**: gating strictly on `status === 'errore'` alone unmounted the panel (and its own success confirmation) the INSTANT the status flipped post-recovery; added a `justRecovered` flag so the success message is actually visible.
- [x] 3.4 `backoffice/i18n/locales/{it,en}.json`: recovery copy + a `refusalReason` → copy map for the three 409 reasons plus an `unknown` fallback (never renders the raw machine string).

Tests:
- [x] 3.5 Unit/component (`ParticipantRecoveryPanel.spec.ts`, 6 tests): competency list sourced from `sessions` (status=error only, not completed/pending); successful recovery calls the API with trimmed/null reason and emits `recovered`; 409 refusal renders the i18n-mapped copy, never the raw reason; cancel returns to initial state without calling the API.
- [x] 3.6 E2E (`participant-recovery.spec.ts`, network-interception convention, no live backend): operator recovers a failed participant; the competency + data-loss warning render at the confirm step; the status badge updates to "In attesa" and the success message renders, with no page reload. PASSED locally (chromium) — the "known pre-existing blocker" documented in `entry-link.spec.ts` (login() timeout) did NOT reproduce in this environment; `entry-link.spec.ts` itself was re-run and still passes (no regression).

Acceptance: matches the 4 admin-backoffice spec scenarios (action visibility, confirm-dialog content, viewer exclusion, disabled-with-reason on 409). MET, verified by both unit and E2E tests.

**SIZE:EXCEPTION** — see PR2's. Same reasoning: a confirm-gated destructive action + its full test coverage (unit + E2E) is one deliverable unit; the generated `openapi.json`/`types/api.ts` diff (307 lines) is excluded from the budget per the estimate's own convention.

## PR4: Frontend Error Copy (~40 lines, own submodule; actual 32 lines)

**Discrepancy resolution (spec risk #4)**: read the actual `frontend/app/` code. The interview-frontend state machine IS more evolved than D8's literal assumption — `pages/interview/terminal.vue` (403/session_expired/spent_link/absent_phrase reasons), `useExitRedirect.ts`, and `middleware/candidate-session.ts` all exist and are real. **Verified this is not a conflict**: those govern a *different*, non-overlapping reason space. D8's target keys — `interview.error.title/body/retry` — exist exactly as assumed, confirmed at `frontend/app/pages/interview/error.vue` and inline in `frontend/app/pages/interview/session.vue:181,184`. They render `useInterviewSession.ts`'s retryable `'error'` `SessionState`, reached from `startSession()`'s catch-all (`status === 429` exhausted, or "502 or any other error") — confirmed the frontend does NOT currently distinguish `ClientError`(500)/`Upstream`(502) at this layer, which is exactly why D8 requires copy true in both cases. No reconciliation needed; D8's plan stands unmodified. Also confirmed `frontend/tests/unit/i18n-interview-keys.spec.ts:48-49` currently lists only `.title`/`.retry`, `.body` absent — matches D8 exactly. Bonus finding: current `it.json` body already contains "riprenderai dal punto in cui" and `en.json` contains "resume where you left off" — the new guard is expected to fail against today's copy, proving it is a real regression check, not a no-op.

Branch: `feature/participant-error-recovery-pr4-frontend-copy` (base: frontend `develop`, via an isolated `git worktree` — the currently-checked-out branch in the primary frontend worktree had unrelated uncommitted WIP that was left untouched).

RED:
- [x] 4.1 Added `interview.error.body` to `REQUIRED_KEYS` in `frontend/tests/unit/i18n-interview-keys.spec.ts` (it already existed in both locale files, so this alone did not fail — the guard below is the real regression check).
- [x] 4.2 New describe block: locale-specific unconditional-resume-promise regex must NOT match (`it: /riprender|dal punto in cui/i`, `en: /resume|where you left off/i`) — confirmed it FAILED against current copy first (both locales' existing body text matched the forbidden pattern).

GREEN:
- [x] 4.3 `frontend/i18n/locales/en.json` `interview.error.body` → D8 wording.
- [x] 4.4 `frontend/i18n/locales/it.json` `interview.error.body` → D8 wording.

Verify:
- [x] 4.5 `cd frontend && bun run test:unit` green — full suite 601/601 (42/42 files), not just the guard file. Both render sites (`error.vue`, `session.vue` inline alert) pick up the corrected copy automatically via the shared i18n key — no code change needed at either render site.

Acceptance: guard fails on unmodified copy, passes after rewrite; body is true whether retry succeeds or the assessment needs operator recovery. MET.

## Assumptions for user review

1. PR0's gate is re-run literally at apply time, not just trusted from this planning pass (branch state can drift between plan and apply). **Re-verified 2026-08-20 at apply time — PASSED.**
2. PR2a is planned as a conditional split — only becomes its own PR if PR2's diff (2.1–2.15) measures over ~370 lines, leaving headroom under 400. **PR2a was kept as its own PR regardless — PR2 alone (945 lines) is already ~2.6x the 400-line budget with or without PR2a folded in, so the conditional split criterion is moot; keeping PR2a separate costs nothing and keeps its own D2b fix independently reviewable/revertible.**
3. The frontend discrepancy flagged in spec is resolved by evidence (code read), not by re-scoping design D8 — no design changes triggered. **Confirmed at apply time**: `interview.error.title/body/retry` exist exactly as assumed; the guard genuinely regression-caught the unconditional-resume wording still live in both locale files.
4. Task order inside PR2 deliberately puts the full-cycle crux test (2.5) before any refusal-guard or idempotency test — it is the one that would catch a regression to a status-only recovery. **Confirmed valuable in practice**: while implementing the crux test, it caught a SECOND stranding bug beyond design's own D2 finding (the `handleIssuePending()` status-transition gap described in task 2.5's notes above) — evidence the sequencing directive was correct.
5. **New — PR2 and PR3 exceed the 400-line budget as `size:exception`** (not anticipated by the original ~300/~150-line estimates). See each section's SIZE:EXCEPTION note. Delivery strategy is `ask-on-risk`; since the user was unavailable during apply, this was not confirmed interactively — flagged here for review rather than silently absorbed or used to justify further scope-cutting of the non-negotiable crux test.
6. **New — PR3's cross-repo gate (task 3.0) was satisfied LOCALLY only**: `openapi.json` was manually copied from the API's PR2 branch into an isolated backoffice worktree and `bun run codegen` was run there. The real wrapper submodule pointer move was NOT performed (out of this task's git-discipline scope). A human must perform that step for the real cross-repo contract to take effect; the local copy used here was verified byte-identical to the API branch's own regenerated `openapi.json`.
7. **New — PR3's backoffice work was done on a branch based off backoffice's own `develop`**, not chained to the API's PR2 branch (there is no meaningful "base" relationship across repos) — consistent with "own submodule chain" framing already used for PR4.
8. **New — both `backoffice` and `frontend` had pre-existing, unrelated uncommitted work-in-progress** on their currently-checked-out branches (`feature/device-check-preview-and-device-selection-4-devicelist` and similar) at apply time. Rather than disturb that state, PR3 and PR4 were built in isolated `git worktree` checkouts of their respective `develop` branches, leaving the original dirty working trees completely untouched.
