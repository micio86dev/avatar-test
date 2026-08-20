# Proposal: Continuous Interview Flow and Server-Governed Pauses

> **Status of the system today**: a production interview **ends after one competency**, and the
> candidate is stopped by a manual "Next" screen that the domain documents never asked for. Both
> defects are in the same flow, and neither is fixable without an API contract addition.

## Intent

`docs/app_description/02-domain/03-tipi-assessment.md:48` makes pauses a **per-project option**:

> Pause | Ogni quante competenze mostrare una pausa (es. ogni N competenze; `null` = nessuna pausa)

and binding acceptance criterion **SA-04**
(`docs/app_description/06-acceptance-criteria/01-scenari-accettazione.md:36-40`) makes the trigger
explicit: *a project with a pause every 3 competencies* shows the pause screen after the 3rd.

The delivered flow ignores the option entirely. It interposes a manual screen after **every**
competency, and then ends the interview after the first one anyway. A BEAI interview is supposed to
feel like a conversation; today it feels like a wizard that gives up.

## Verified current state

Read from code on 2026-08-20, at the cited lines, on `develop` (the `frontend@hotfix/0.6.3` and
`api@hotfix/0.22.4` fixes are already reflected in these files).

| # | Finding | Evidence |
|---|---|---|
| 1 | The interstitial is **unconditional**. An `end_of_question` screen with a manual Next button renders after every competency | `frontend/app/pages/interview/session.vue:124-144` |
| 2 | The interview **ends after one competency**. `competencies` is an empty array, so `currentQuestionIndex + 1 >= competencies.length` is `1 >= 0` → always last | `session.vue:309`; `useInterviewSession.ts:412-420` |
| 3 | The progress bar divides by that same empty array — `:total="competencies.length"` is always `0` | `session.vue:132-135` |
| 4 | Questions are **skippable** by candidate action | `session.vue:83-85`, `useInterviewSession.ts:616-622` |
| 5 | The `/start` response carries **no total and no last-competency signal** — only `competency_code`, `question_index`, `end_phrase`, `final_phrase`, `prompt_version` | `api/app/Http/Controllers/Candidate/InterviewController.php:764-781` |
| 6 | `POST /end` returns **`response()->json(null, 200)`** — an empty body | `InterviewController.php:351` |

### The spec's stated justification is factually false

`openspec/specs/interview-frontend/spec.md:24-25` and `:867-871` both assert:

> Server-enforced `pause_every_n_competencies` — **no backend column exists**; C7b implements
> pause/resume with client-side state only

The column exists and always has:

- `api/database/migrations/2026_07_17_200001_create_projects_table.php:41` —
  `$table->unsignedTinyInteger('pause_every_n_competencies')->nullable();`
- `api/app/Models/Project.php:39` (docblock) and `:71` (`$fillable`)
- Validated `1..255` on both write paths — `StoreProjectRequest.php:72`, `UpdateProjectRequest.php:85`
- Serialised by `ProjectResource.php:55-57`

The C7b non-goal was written against a premise that was never true, and the false premise is what
produced the unconditional screen.

### Requested investigation: is the field already settable and already carried?

Asked, not assumed. Two different answers:

| Surface | Result |
|---|---|
| **Backoffice project form** | **Already settable.** `backoffice/app/components/organisms/ProjectForm.vue:436, 621, 671, 688` binds, validates (`:436` error key at `ProjectForm.spec.ts:436`) and submits it. **No backoffice work is needed.** |
| **Candidate surfaces** | **Absent.** `POST /candidate/interview/start` never mentions it (`:764-781`); `ParticipantResource.php:37` exposes a project block of `{id, role_code, language, assessment_type, exit_redirect_url, error_redirect_url}` and nothing more. The candidate app has no way to learn the pause cadence. |

**Correction to the framing:** it is not true that every project has `pause_every_n_competencies =
null`. The demo dataset seeds **2 and 3** (`api/app/Support/Demo/DemoDataset.php:56, 68, 80, 97`),
so demo tenants are exactly the ones whose correct behaviour is *not* fully continuous. The reported
production project is `null`; the platform is not.

### The root cause of Finding 2 is a spec assumption with no implementation

`interview-frontend/spec.md:456-462` specifies last-competency detection against *"the ordered
competency list obtained from the C6 candidate-session bootstrap"*. **That bootstrap never shipped
the list** — `ParticipantResource` has no competencies field. `session.vue:305-309` documents the
gap in its own comment and then guesses wrong about who compensates:

> the composable handles last-competency detection internally when `/start` returns
> `question_context.question_index` vs total

It does not, because there is no total. This is why the contract addition below is not optional
polish — it is the missing half of an already-ratified requirement.

## Scope

### In Scope

| # | Deliverable | Repo |
|---|---|---|
| 1 | `POST /candidate/interview/start` returns the competency total | `api` |
| 2 | `POST /candidate/interview/end` returns a body carrying the **server's** next-step directive | `api` |
| 3 | Auto-advance: no interstitial unless a scheduled pause is due | `frontend` |
| 4 | SA-04 pause screen, triggered by `pause_every_n_competencies` only | `frontend` |
| 5 | Remove the Skip control from the live UI | `frontend` |
| 6 | Progress bar shows a real total instead of `0` | `frontend` |
| 7 | Correct the false non-goal at `interview-frontend/spec.md:24-25` and the `paused` scoping at `:867-871`; rewrite last-competency detection at `:456-462` and the screen table at `:858-861` | delta spec |
| 8 | **Bounded single re-offer of an `error` competency** (Decisions 4 and 5), and the completion-tally amendment that makes `in_valutazione` reachable | `api` |

### Out of Scope

- **The three defects already fixed** on `frontend@hotfix/0.6.3-interview-live-flow` and
  `api@hotfix/0.22.4-snapshot-data-url` (missing `voiceChat` SessionConfig, `pause()` rejecting
  `live`, snapshot data-URL 422). Adjacent context only; not re-proposed.
- **The 5-minute per-question timer.** Ratified: it stays as an automatic `timeout` close.
- **Candidate-initiated pause during a live question.** Ratified: it stays, and is independent of
  SA-04. It mutes the microphone and keeps the provider session alive.
- **Backoffice project configuration.** Already complete (see the investigation table).
- **Adaptive question count within a competency** (C8) and scoring (C9). Untouched.
- **Exposing the ordered competency *list* to the candidate browser.** See Decision 3.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- **`interview-frontend`** — the non-goal at `:24-25` is deleted (its premise is false). The
  between-competency flow at `:450-462` changes from "the candidate initiates the next competency by
  an explicit action" to server-directed auto-advance with a conditional pause. `:867-871` is
  rescoped: `paused` is no longer only candidate-initiated. `:858-861` (screen table) and `:884`
  (done-screen scenario) follow. The `skip → end_of_question` exit trigger at `:858` is removed.
- **`interview-session`** — the `/start` and `/end` response contracts gain fields; `:22`
  ("`pause_every_n_competencies` UX gate (C7b)") stops being a pure deferral once the backend
  computes the directive. The competency lifecycle gains the **bounded single re-offer**
  (Decisions 4 and 5): `error` is no longer terminal on first occurrence, and the completion tally
  changes. `POST /end`'s `ended_reason ∈ {completed, timeout, skipped}` enum is **unchanged**
  (Decision 1).
- **`participant-sso`** — hosts the ratified recovery requirements at `:882-897` ("Atomic Participant
  and Session Recovery from Errore"), **not** a `participant-error-recovery` spec; there is no spec
  file by that name. Touched only if the one-retry bound is scoped to include the operator path
  (question 1c). Confirm in `sdd-spec` before assuming a delta is needed.
- **`project-config`** — unchanged. `:24` already documents the column correctly.

## Decisions

### Decision 1 — `skipped` stays a valid `ended_reason` *(taken)*

**Keep it.** Removing the enum value would be a migration on a `status`/`ended_reason` column, a
`/end` validation change (`InterviewController.php:244`), a spec amendment at
`interview-frontend/spec.md:441` and `:884`, and a rewrite of the `/end` counting query at
`:296` — all to delete a value that no longer has a caller. That is churn with a real regression
surface and zero product benefit. Historical rows carrying `skipped` must remain readable and must
keep counting toward completion.

What changes is only that **the candidate can no longer produce it**. The value stays reachable for
operator/recovery paths and for the historical record. The delta spec must say this explicitly, so
a future reader does not "clean up" an enum the domain still needs.

### Decision 2 — The server decides, the client renders *(recommendation; design finalises)*

**Recommended shape** — additive on both endpoints:

```
POST /candidate/interview/start  →  201
  question_context: {
    competency_code, question_index, end_phrase, final_phrase, prompt_version,
    total_competencies: int          // NEW — for the progress bar
  }

POST /candidate/interview/end    →  200   (today: null body)
  {
    completed_competencies: int,
    total_competencies: int,
    next_action: "continue" | "pause" | "done"    // NEW — the directive
  }
```

Three reasons this is better than putting an "is last" flag on `/start` alone:

1. **The server already computes it.** `InterviewController.php:293-303` counts ended sessions and
   total `project_competencies` inside the `/end` transaction, to drive the `in_valutazione` CAS.
   `next_action` is that same pair of numbers plus one modulo against
   `project.pause_every_n_competencies`. No new query.
2. **It deletes the arithmetic that caused Finding 2.** No client-side count means no empty array to
   get wrong, and no way for the frontend and the backend to disagree about which competency is last
   — a disagreement that today silently truncates an assessment.
3. **It makes SA-04 genuinely server-enforced**, which is what the corrected spec should be able to
   claim. Pause cadence is a tenant configuration value; it should not be re-derived in a browser.

**`total_competencies` on `/start` is still required** — the progress bar must render before the
first `/end` ever returns.

**Both additions are purely additive**, which is what makes the multi-repo ordering safe: the api can
deploy first, and a frontend that ignores the new fields behaves exactly as it does today.

### Decision 3 — Send a count, not the competency list *(recommendation)*

`interview-frontend/spec.md:456-462` assumed the candidate app would hold the ordered competency
list. Do not build that. The list is the ordered BARS competency plan for the interview; shipping it
to the candidate's browser before the interview starts tells the candidate exactly what is about to
be probed, which cuts against the anti-leak posture the conversation layer already enforces
(`interview-session/spec.md:341-349`). A count and a directive are sufficient for every screen this
change needs. Confirm in `sdd-design`.

### Decision 4 — An `error` competency is RE-OFFERED, not counted as attempted *(RATIFIED)*

A competency whose session ended in `error` MUST be offered to the candidate again. It is neither
silently skipped (today's behaviour, `InterviewController.php:475`) nor counted as attempted. A
candidate does not lose a competency because the provider failed.

Consequence: `resolveNextCompetency` must stop treating `error` as terminal on the **first** failure.

### Decision 5 — Exactly ONE re-offer, then the competency is definitively closed *(RATIFIED)*

A competency returns from `error` to `pending` **at most once**. If the second attempt also ends in
`error`, it stays `error`, becomes terminal, and **MUST count toward the completion tally** so
`in_valutazione` can fire.

**Rationale — one retry rule across the product, not two.** This mirrors the already-ratified scoring
retry semantics in CLAUDE.md: *"Exactly 1 retry; after a failed retry → `completed` (definitive)"*.
The same bound, the same shape, at the interview stage.

**This closes CLAUDE.md open product decision #4 ("OPEN — retry semantics") for the competency
case only.** The scoring-side case (C9 chain-PR 4 / RT-B) is **NOT** closed by this change and
remains open.

### Requirement and schema constraint arising from Decisions 4 and 5 *(design decides the shape)*

Verified in the migration, stated here as a constraint — **not designed here**.

`api/database/migrations/2026_07_20_100002_create_interview_sessions_table.php:77` declares
`$table->unique(['participant_id', 'competency_code']);` — **one row per participant per
competency** — and the status enum at `:19` / `:65` is LOCKED to
`{pending, in_corso, completed, timeout, skipped, error}`. **There is no attempt-counter column.**

Therefore:

1. **"Re-offer" cannot mean a second session row.** The unique constraint forbids it. It must mean
   resetting the existing row from `error` back to `pending` and re-issuing a provider session. The
   resume machinery already exists — `createOrResumeSession` (`:494-520`) catches
   `UniqueConstraintViolationException` and re-queries the existing row.
2. **The one-retry bound requires persisting an attempt count that survives the reset.** A new
   nullable column on `interview_sessions` is the obvious candidate; the exact shape is a **design
   decision**, not a proposal decision. The requirement is: the bound must be durable, and it must
   not be inferrable from `status` alone — a re-offered session sitting at `pending` is
   indistinguishable from a never-attempted one.
3. The migration docblock at `:12` ("One row per competency **attempt** per participant") becomes
   inaccurate under a re-offer and needs correcting alongside.

### The re-offer mechanic already exists — reuse it, do not invent a second one

**Newly found, beyond the briefed scope.** `api/app/Actions/Participant/RecoverFailedParticipant.php:117-128`
already performs exactly this reset, operator-initiated:

```
$session->status = 'pending';
$session->provider_session_ref = null;
$session->ended_reason = null;
$session->ended_at = null;
```

Three consequences the design phase must reconcile:

| Aspect | Existing operator recovery | This change's automatic re-offer |
|---|---|---|
| Trigger | Operator action on a participant at `errore` | Automatic, in-flow, on the next `/start` |
| Bound | **Unbounded** — an operator may recover repeatedly | **Exactly once** (Decision 5) |
| Utterances | **Deleted** on reset (`:118-119`) — *ratified* at `participant-sso/spec.md:892-897` | Recommended: same rule. Confirm — see question 1a |

The reset itself is proven code **and its behaviour is already ratified in a spec**. The design should
extend or share it rather than author a parallel path, and must state whether the one-retry bound
also constrains the operator path or only the automatic one.

Note the interaction to check in `sdd-design`: `participant-sso/spec.md:895` justifies the reset by
saying `resolveNextCompetency()` *"continues to skip already-answered competencies"*. Decision 4
changes what `resolveNextCompetency` does with `error`. The ratified scenario at `:909-914`
("Resume, not restart") must still hold verbatim afterwards.

## Approach

Server-directed flow, client-rendered screens. After each `/end`:

| `next_action` | Client behaviour |
|---|---|
| `continue` | Immediately calls `/start` for the next competency. No screen, no candidate action. |
| `pause` | Renders the SA-04 pause screen. Resume calls `/start`. |
| `done` | Renders the done screen and stops. |

The existing `end_of_question` state is **retained as the pause screen** rather than deleted — it
already owns the progress bar and the resume affordance — but it is only entered on `pause`. The
`live → connecting → live` transition on `continue` needs a non-blocking treatment: today each
competency tears the provider down and rebuilds it (`useInterviewSession.ts:545-559`), so without an
interstitial the candidate watches the avatar disappear and return with no explanation. See Risk 3.

`pause` computation (server): `pause_every_n !== null && completed % pause_every_n === 0 && completed < total`.
A pause is never due on the last competency — `done` wins.

### Changed-line forecast

```
400-line budget risk: High
Chained PRs recommended: Yes
Decision needed before apply: Yes
```

Estimated ~700–850 lines across two repos, roughly 45% tests. Decisions 4 and 5 raised the forecast:
they add a migration, a durable attempt bound, and a reset path that must be reconciled with
`RecoverFailedParticipant`. Three slices, ordered by the deploy constraint:

| PR | Repo | Content | ~Lines |
|---|---|---|---|
| 1 | `api` | Bounded re-offer: attempt-count migration, `resolveNextCompetency` re-offer branch, completion-tally amendment, reconciliation with `RecoverFailedParticipant` | 300 |
| 2 | `api` | `total_competencies` on `/start`; `/end` body with `next_action`; regenerate `openapi.json` | 250 |
| 3 | `frontend` | Auto-advance, conditional pause screen, Skip removal, real progress total; regenerate the typed client; unit + E2E | 300 |

PR 1 ships independent value: it unblocks participants **currently stranded in production** at
`in_corso` with an errored competency, with no frontend change at all.

`Decision needed before apply: Yes` — Decision 2's exact field shape, the attempt-bound persistence
shape, and the utterance/operator-path questions in the question round.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Http/Controllers/Candidate/InterviewController.php:764-781` | Modified | `total_competencies` in `question_context` |
| `api/app/Http/Controllers/Candidate/InterviewController.php:293-303, 351` | Modified | `next_action` computed from the existing counters; `/end` stops returning `null` |
| `api/app/Http/Controllers/Candidate/InterviewController.php:441-479` | Modified | `resolveNextCompetency` gains the bounded re-offer branch (`:475` stops treating `error` as terminal on the first failure); it already reads the full ordered list, so it is also the cheapest source for the total |
| `api/app/Http/Controllers/Candidate/InterviewController.php:294-297` | Modified | Completion tally must include a competency that exhausted its single re-offer |
| `api/database/migrations/` | New | Durable attempt bound on `interview_sessions` (shape = design decision); `2026_07_20_100002_…:12` docblock corrected |
| `api/app/Actions/Participant/RecoverFailedParticipant.php:117-128` | Modified? | The reset it already performs must be shared or reconciled with the automatic re-offer; bound scoping is an open question |
| `api/openapi.json`, `frontend/openapi.json`, `frontend/types/api.ts` | Regenerated | Scramble → typed client; never hand-edited |
| `frontend/app/pages/interview/session.vue:83-85, 124-144, 305-309` | Modified | Skip removed; interstitial made conditional; empty `competencies` array deleted |
| `frontend/app/composables/useInterviewSession.ts:412-420, 602-607, 616-622` | Modified | `advanceAfterQuestion` consumes `next_action`; `nextCompetency` becomes the resume path only |
| `frontend/i18n/locales/{it,en}.json` | Modified | `interview.live.skip` removed; pause-screen copy revised for a *scheduled* pause |
| `frontend/tests/unit/{use-interview-session,interview-session-page,i18n-interview-keys}.spec.ts` | Modified | RED first — several pin today's unconditional flow |
| `frontend/tests/e2e/interview-flow.spec.ts` | Modified | The happy path asserts the Next button today |
| `api/tests/Feature/C7a/…`, `api/tests/Feature/Api/ResourceContractTruthTest.php` | Modified | New response fields |
| `openspec/specs/interview-frontend/spec.md:24-25, 441, 450-462, 858-861, 867-871, 884` | Delta | Six blocks; `:24-25` is a factual correction |
| `backoffice/**` | **Unchanged** | Already ships the field |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **1. A competency ending in `error` makes completion unreachable.** `/end` counts only `{completed, timeout, skipped}` (`:296`) while `resolveNextCompetency` *skips* `error` (`:475`). So `endedCount === totalCompetencies` can never hold, `in_valutazione` never fires — and under Decision 2 `next_action` would never return `done`, stranding the candidate. Client-side arithmetic masks this today | **RESOLVED — no longer blocking.** Product answer ratified (Decisions 4 and 5); design work remains | Re-offer once, then count the exhausted competency toward the tally. **Not a blocker on `sdd-spec`/`sdd-design` — it is now their input.** Residual work is the durable attempt bound (schema constraint above) and the `RecoverFailedParticipant` reconciliation. This also **fixes participants currently stranded in production** |
| **1b. The re-offer is silent to the candidate.** A competency that fails and is re-offered looks identical to one being asked for the first time | Med | Product-visible: decide whether the candidate is told the question is being repeated. Raised in the question round |
| 2. Auto-advance removes the only place a candidate could catch their breath between competencies, in an interview that may run 14–18 competencies | Med | Exactly what `pause_every_n_competencies` is for. Flag to the data controller that projects with `null` now run genuinely continuously — that is the specified behaviour, but it is a behaviour change for live projects |
| 3. On `continue`, the avatar tears down and reconnects with no screen — the candidate sees a blank frame and may think the session broke | **High if unguarded** | Keep the `connecting` state visible with a non-blocking, i18n-keyed transition indicator. No candidate action required; must not become a second interstitial |
| 4. Deploying `frontend` before `api` reintroduces the one-competency truncation | Med | Both additions are additive; sequence api first (see Dependencies). A missing `next_action` must degrade to the current behaviour, not to a crash |
| 5. Amending six ratified spec blocks — one of which states a false fact — needs sign-off, not a silent overwrite | Certain | Authored explicitly in `sdd-spec`; the `:24-25` correction is called out as a correction |
| 6. Demo tenants seeded at 2 and 3 (`DemoDataset.php:56, 68`) will start showing pause screens that today never appear | Med | Correct per SA-04. Note it in the change log so it is not filed as a regression |
| 7. Removing Skip leaves the 5-minute timer as the only per-question escape; a candidate who genuinely cannot answer now waits it out | Med | Accepted and ratified. The timer already produces `timeout`, which counts toward completion |
| 8. E2E and unit suites assert the Next button on the happy path | Certain | Strict TDD: RED on the corrected assertions before any GREEN |

## Rollback Plan

`pause_every_n_competencies` already exists and is already populated. Decisions 4 and 5 introduce
**one additive, nullable migration** (the attempt bound) — the only schema change in this change.

- **PR 3 (`frontend`) reverts alone** and restores the manual-Next flow — including its
  one-competency truncation. Reverting frontend while api stays deployed is safe: the extra response
  fields are simply unread.
- **PR 2 (`api`, contract) reverts alone only while PR 3 is unshipped.** Once the frontend consumes
  `next_action`, reverting it strands the flow. Revert PR 3 first, or roll forward.
- **PR 1 (`api`, bounded re-offer) reverts to a *worse* state**, not a neutral one: it restores the
  tally that leaves participants permanently unable to reach `in_valutazione`. Roll forward.
  The migration must be additive and nullable so the column can be left in place on a code revert —
  down-migrating it while a re-offered session sits at `pending` would erase the only record of the
  attempt bound and permit an unbounded second re-offer.
- Sessions in flight during a deploy carry no incompatible state: every competency is an independent
  `InterviewSession` row and the flow decision is recomputed from the database on each `/end`.
- The spec deltas revert with their PR. Note that reverting `:24-25` restores a **false statement**;
  if the flow is rolled back, the correction should be re-landed separately.

## Dependencies

- **Deploy order is a hard constraint**: `api` must be live before `frontend`. Independent SemVer
  per Git Flow ×4 (`docs/git-flow.md`); the wrapper pins both. Current: `frontend@0.6.2`.
- The typed client is generated from `openapi.json` — regenerate before the frontend slice, never
  hand-maintain the types.
- **PR 1 before PR 2** within `api`: the `done` directive is only correct once the tally can actually
  reach `total`.
- **No open CLAUDE.md product decision blocks this change.** This change **closes decision #4 (retry
  semantics) for the competency case** (Decision 5) and leaves the scoring case (C9 chain-PR 4 /
  RT-B) open. **#2 (GDPR retention)** is untouched — though the utterance question below borders it.

## Success Criteria

- [ ] A project with `pause_every_n_competencies = null` runs **every** competency end to end with
      **zero** candidate clicks between competencies.
- [ ] A project with `pause_every_n_competencies = 3` shows the pause screen after the 3rd and 6th
      competency and at no other point — SA-04, asserted as a test.
- [ ] A pause is never shown after the final competency; `done` wins.
- [ ] An interview with N competencies produces N `InterviewSession` rows and reaches
      `in_valutazione`. Asserted with N > 1 — the case the current suite never covered.
- [ ] A competency that ends in `error` is offered to the candidate **again**, on the same row, in
      its original `project_competencies.position` order.
- [ ] A competency that ends in `error` a **second** time stays `error`, is never offered a third
      time, and **counts toward the tally** — the participant still reaches `in_valutazione`.
- [ ] The attempt bound survives the reset to `pending`: a re-offered session is distinguishable
      from a never-attempted one.
- [ ] A participant already stranded in production (errored competency, `in_corso`, tally
      unreachable) can complete. Asserted as an explicit regression test.
- [ ] `RecoverFailedParticipant` still works and does not silently acquire — or silently bypass —
      the new bound; whichever behaviour is chosen is asserted.
- [ ] The progress bar reads `1/N … N/N` with the real N, never `x/0`.
- [ ] No Skip control exists in the interview UI, and `interview.live.skip` is gone from both locale
      files.
- [ ] The 5-minute timer still closes a question with `ended_reason='timeout'`, and that competency
      still counts toward completion.
- [ ] Candidate-initiated pause during a `live` question still mutes the mic, keeps the provider
      session alive, and resumes to `live`.
- [ ] `skipped` is still accepted by `POST /end` and still counted; no migration touches it.
- [ ] `interview-frontend/spec.md` no longer claims the column does not exist.
- [ ] Coverage: api ≥ 85% (candidate state machine held to ~95% per CLAUDE.md); frontend ≥ 85%.

## Proposal question round

Round 1 is **answered and ratified** — see Decisions 4 and 5. What follows is round 2: the questions
those answers opened, plus the ones still outstanding. Each is a product decision that `sdd-spec` and
`sdd-design` must not settle alone.

1. ~~What should happen to a competency that ends in `error`?~~ **ANSWERED** — re-offered exactly
   once, then terminal and counted (Decisions 4 and 5). Three follow-ons remain:
   - **1a. Are the first attempt's utterances kept or discarded on re-offer?** There is a
     **ratified precedent**: `participant-sso/spec.md:892-897` requires that a reset session's
     utterances *"MUST be deleted"*, implemented at `RecoverFailedParticipant.php:118-119`. The
     recommendation is therefore to **discard**, for one rule across both paths — but confirm it,
     because it destroys candidate speech BEAI recorded, and the alternative (keep) would make C9
     score one competency against two partial conversations, one of which failed mid-turn.
   - **1b. Is the candidate told the question is being repeated?** A silent re-offer looks like the
     avatar asking the same thing twice for no reason.
   - **1c. Does the one-retry bound also constrain the operator path?** `RecoverFailedParticipant`
     is unbounded today. If the bound is global, an operator loses the ability to rescue a
     participant whose automatic re-offer was itself consumed by an outage.
2. **Is a fully continuous 18-competency interview acceptable for `null` projects?** It is the
   specified behaviour, but it is a real behaviour change for live projects and a candidate-fatigue
   question. If not, the answer is a non-null default, not a hardcoded interstitial.
3. **What does the candidate see during the ~2–4 s reconnect between competencies?** (Risk 3.) A
   spinner, a persistent avatar frame, or a one-line "next competency" caption — the choice decides
   whether continuous flow reads as smooth or as broken.
4. **Should the SA-04 pause be timed or untimed?** SA-04 says only "a pause screen before
   continuing". A pause with no cap can idle until the candidate JWT expires, which today would
   surface as a `403` terminal screen — a bad ending to a deliberate rest.
5. **Confirm Decision 3**: a count, not the competency list, reaches the candidate browser.
