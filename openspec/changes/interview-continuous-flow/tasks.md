# Tasks — interview-continuous-flow

Derived from `proposal.md`, `design.md` (D1–D13) and the three delta specs.

**Strict TDD is active.** Every RED task precedes its GREEN task and must be observed failing.
Several existing tests currently *defend* behaviour this change removes — they are corrected inside
the RED task that supersedes them, never afterwards.

**Delivery: four chained PRs.** The design forecasts ~700–850 changed lines, above the 400-line
review budget. Deploy order is a hard constraint: **`api` before `frontend`, and PR 1 before PR 2**.

| PR | Scope | Ships alone? |
|---|---|---|
| 1 | Completion-tally repair (D5) | Yes — fixes stranded participants already in production |
| 2 | Bounded re-offer: migration, reset action, `resolveNextCompetency` branch (D1–D4, D8–D10) | Yes |
| 3 | `/start` + `/end` contract additions (D6, D7) | Yes — additive, verified |
| 4 | Frontend continuous flow (D11–D13) | Requires PR 3 deployed |

Test commands: api `php artisan test --parallel`; frontend `bun run test:unit`,
`bunx nuxi typecheck`, `bun run lint`; E2E `bun run test:e2e`.

---

## PR 1 — Completion tally counts exhausted errors (D5)

Ships first and alone. Independent of every other slice: it repairs participants who are stranded
in production **today**, before any new behaviour is introduced.

- [ ] **1.1 RED** — Feature test: a participant whose last competency ends in a terminal `error`
      reaches `in_valutazione` and dispatches `FinalizeInterview` (`Queue::fake`). Fails today —
      the tally counts only `completed|timeout|skipped`, so the CAS never fires.
- [ ] **1.2 RED** — Feature test: an `Upstream` failure does **NOT** dispatch scoring; the
      participant goes to `errore`. Pins the CAS guard so 1.3 cannot over-fire.
- [ ] **1.3 GREEN** — Extract `settleCompletionIfFinished()` from `InterviewController::end()` and
      amend the tally to include competencies that have exhausted their re-offers. Wire the two new
      call sites (D5).
- [ ] **1.4 REFACTOR** — Confirm the extraction has one behaviour and one owner; no call site
      duplicates the CAS.
- [ ] **1.5** — Full api suite + coverage gate. Candidate state machine ≥ ~95% (CLAUDE.md).

> **Rollback**: PR 1 reverts to a *worse* state than neutral — the old tally re-strands
> participants. Roll forward, never back.

---

## PR 2 — Bounded single re-offer (D1–D4, D8–D10)

- [ ] **2.1 RED** — Unit test for `ResetSessionForRetry`: five writes (`status='pending'`,
      `provider_session_ref`/`ended_reason`/`ended_at` cleared, utterances deleted) and
      `error_count` **unchanged**. The unchanged assertion is the bound — a reset that clears its
      own counter grants unlimited re-offers.
- [ ] **2.2 GREEN** — Create `App\Actions\InterviewSession\ResetSessionForRetry`, extracted
      verbatim from `RecoverFailedParticipant` (D3).
- [ ] **2.3 GREEN** — Point `RecoverFailedParticipant`'s loop body at the shared action. Correct
      its two false docblocks (D3, D8).
- [ ] **2.4** — Migration: `unsignedTinyInteger('error_count')->default(0)` on
      `interview_sessions`, **with the backfill** `SET error_count = 1 WHERE status = 'error'`.
      Without the backfill every stranded production row gets three attempts instead of two.
      The docblock MUST state that `down()` is not to be run on a code revert: dropping the column
      while a re-offered session sits at `pending` erases the only record of the bound.
- [ ] **2.5 GREEN** — `InterviewSession`: `MAX_ERROR_ATTEMPTS = 2`, `@property int $error_count`,
      status docblock. Correct the create-migration docblock (`:12`) — one row per competency,
      *n* attempts, not one attempt (D8).
- [ ] **2.6 RED** — Feature test: a competency ending in `error` is re-offered exactly once; the
      second `error` is terminal and never offered a third time (`Http::fake` forcing
      `ClientError`).
- [ ] **2.7 RED** — Feature test: the re-offer **deletes attempt 1's utterances**, asserted at
      `/start` *before* `issue()` (F3). This is the ratified destructive step — assert it directly,
      never infer it from a later transcript read.
- [ ] **2.8 RED** — Regression test: the ratified `participant-sso` "Resume, not restart" scenario
      still holds verbatim (D8). `error_count` is only incremented in `markSessionError()`, so a
      reset session is `pending`, never `error`, and the operator path is unaffected.
- [ ] **2.9 GREEN** — Add the re-offer branch to `resolveNextCompetency()`, ordered **between** the
      existing two (D2). Create `App\Services\Interview\NextCompetency` as its readonly result.
- [ ] **2.10** — Confirm the operator recovery path stays **unbounded** (D4) and that a test pins
      that asymmetry deliberately, so a future reader does not "fix" it.
- [ ] **2.11 RED/GREEN** — `OpeningTextComposer` `'retry'` variant (D10): it/en, `:competency`
      interpolation, locale fallback. Add `opening.retry` to `api/lang/{it,en}/interview.php`.
      The candidate must be told they are re-attempting — an unexplained repeat reads as the avatar
      not having listened.
- [ ] **2.12** — Full api suite + coverage gate.

---

## PR 3 — Server-directed contract (D6, D7)

- [ ] **3.1 RED** — Feature test: `/start` returns `competency_ordinal` and `total_competencies`.
      `question_index` is **untouched** (D6) — it carries a separate, pre-existing off-by-one that
      is out of scope here and has its own change.
- [ ] **3.2 RED** — Feature test: `/end` returns `{ended_competencies, total_competencies,
      next_action}`, and `next_action` is `continue` / `pause` / `done` per the project's
      `pause_every_n_competencies` (D7). Cover `null` cadence → never `pause`.
- [ ] **3.3 GREEN** — Compute the directive inside the transaction that already holds the counters,
      so it adds no new query beyond the project load.
- [ ] **3.4** — Cross-tenant isolation tests: the directive and both counts resolve strictly within
      `organization_id` (mandated by `rules.specs`).
- [ ] **3.5** — Regenerate `api/openapi.json` via Scramble → `frontend/openapi.json` →
      `frontend/app/types/api.ts`. **Never hand-edit** the typed client.
- [ ] **3.6** — Full api suite + coverage gate.

> **Additive claim, already verified in code**: `isValidStartResponse()` accepts unknown keys and
> `callEnd()` discards the response body, so a stale frontend is unaffected by PR 3.

---

## PR 4 — Continuous flow in the client (D11–D13)

Requires PR 3 deployed.

- [ ] **4.1 RED** — Unit test: `callEnd()` returns the directive and `advanceAfterQuestion(directive)`
      routes `continue` → immediate `startSession()`, `pause` → scheduled-pause screen, `done` →
      done screen (D11).
- [ ] **4.2 RED** — Unit test: HTTP 409 (`'noop'`) causes **no transition at all**. It is the loser
      of the avatar-complete/timer race; under a directive-driven machine the loser has no directive
      and must not act.
- [ ] **4.3 RED** — Unit test: an absent, unknown or errored directive degrades to `pause` (D11) —
      today's manual flow, never a crash.
- [ ] **4.4 RED** — Regression guard: the ratified live mute-pause is untouched. `pause()` from
      `live` mutes the mic and keeps the provider session alive; `resume()` returns to `live` and
      unmutes (D13). This pins the v0.6.3 fix.
- [ ] **4.5 RED** — Unit test: `pause()` from `end_of_question` is a no-op, and `resume()` can only
      land on `live`.
- [ ] **4.6 RED** — Unit test: invariant `paused ⇒ avatarMounted`. **Must pass before 4.9 deletes
      the standalone section**, or removing dead markup silently produces a blank screen.
- [ ] **4.7 RED** — Unit test: the per-question timer suspends on pause and resumes from the same
      second; a new competency starts from the full limit. Already implemented and shipped in
      v0.6.4 — this pins it against the flow rewrite.
- [ ] **4.8 GREEN** — `useInterviewSession.ts`: directive consumption; `competencies` option
      deleted; server-fed progress; Skip removed; `EndQuestionReason` narrows to `'timeout'`;
      `pause()` guard narrows to `live`; `pausedFrom` deleted; `resume()` returns unconditionally
      to `live` (D11, D13).
      **Invariant**: `pause()`/`resume()` keep assigning `state.value` directly and MUST NOT be
      routed through `transitionTo()`, which calls `clearActiveProvider()` for the terminal states —
      that would unmount the player and destroy the session the pause exists to preserve.
- [ ] **4.9 GREEN** — `session.vue`: Skip control removed; `end_of_question` becomes the SA-04
      scheduled-pause screen with its secondary Pause control removed; named transition panel
      (D12); real progress total; standalone `paused` section removed, **in-avatar paused panel
      kept** (D13).
- [ ] **4.10** — i18n: remove `interview.live.skip`; add `interview.scheduled_pause.*` and
      `interview.transition.*` in it **and** en.
- [ ] **4.11** — `bun run test:unit`, `bunx nuxi typecheck`, `bun run lint`, coverage gate.
      Re-run the suite **after** committing: lint-staged rewrites files during commit, so the tree
      tested is not the tree committed.
- [ ] **4.12 E2E** — Playwright, chromium + webkit:
      - pause during a live question, resume, finish the same competency — no restart, no lost turn
      - `pause_every_n = null`, N > 1: zero clicks between competencies, progress `1/N…N/N`, done
      - `pause_every_n = 3`: pause screen after the 3rd and 6th only

---

## Close-out

- [ ] **5.1** — `sdd-verify` against spec, design and this checklist.
- [ ] **5.2** — Confirm no artifact still disagrees with another (the D13 spec/design conflict was
      corrected mid-flight; re-check before archive).
- [ ] **5.3** — `sdd-archive`: merge the three delta specs into the live specs, including the
      factual correction to `interview-frontend/spec.md:24-25` ("no backend column exists" — the
      column has existed since the projects table was created).

---

## Carried forward — NOT gated by this change

- The `question_index = -1` off-by-one: `position` is written 0-based at every writer while
  `resolveNextCompetency()` subtracts one. D6 routes around it with a fresh `competency_ordinal`
  rather than repairing a persisted column and a shipped contract field inside a flow rewrite.
  Needs its own change.
- Whether a scheduled SA-04 pause should have a cap before the candidate JWT expires. An additive
  client timer needing no contract change.
