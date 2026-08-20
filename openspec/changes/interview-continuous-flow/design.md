# Design: Continuous Interview Flow and Server-Governed Pauses

## Technical Approach

Three axes, in dependency order. The ordering is the deploy constraint, not a preference.

1. **Make the tally reachable** (`api`). A competency that ends in `error` is re-offered exactly once
   against the *same* row, bounded by a durable counter that the reset cannot touch. The reset itself
   is not written twice: the proven, ratified reset inside `RecoverFailedParticipant` is **extracted
   into one shared action** and both paths call it.
2. **Move the arithmetic to the server** (`api`). `/start` gains the ordinal and the total; `/end`
   stops returning `null` and returns the next-step directive it already has the numbers for. The
   client renders; it never counts.
3. **Render it continuously** (`frontend`). The interstitial becomes conditional on the directive,
   Skip is removed, and the provider teardown/rebuild between competencies gets a named transition
   instead of a blank skeleton.

`replaceUtterances()` is **not modified** — see **F3**. Keeping that method out of the diff is a
design constraint, not an oversight: its guard is correct and the hole is closed elsewhere.

---

## Findings that changed the design

Verified in code on 2026-08-20, beyond what the proposal established.

**F1 — the automatic re-offer and the operator recovery are reachable from DISJOINT participant
states.** `markSessionError()` (`InterviewController.php:692-710`) is the **sole** writer of
`interview_sessions.status = 'error'` in the whole application (`DemoDataset.php:186` aside, which is
a fixture). It is reached from exactly two classifications:

| Class | Session | Participant | Which recovery is reachable |
|---|---|---|---|
| `ClientError` (4xx — our bug) | `error` | **untouched** (`in_corso`) | **automatic re-offer only.** `ParticipantStatusGuard` does not block; the candidate's own retry re-enters `/start`. |
| `Upstream` (5xx/timeout) | `error` | → `errore` | **operator only.** `ParticipantStatusGuard::TERMINAL_STATUSES = ['completato','errore']` 403s every candidate request. |

This is what decides question 1c. The two paths are not two mechanisms competing for the same state;
they are one mechanism each for two disjoint states. See **D4**.

**F2 — `question_index` is off by one, and a server-driven progress bar would expose it.**
`ProjectController.php:98` and `:161` assign `position` from the PHP array index — **0-based**.
`DemoWriter.php:254` does the same. But `resolveNextCompetency()` (`:463`) computes
`question_index = position - 1`, i.e. **-1 for the first competency** of every project created through
the API. `DemoWriter.php:406` writes `question_index = $position` (0-based) — the two writers already
disagree. A progress bar rendered as `question_index + 1` would read **`0/N`** on the first
competency: the same class of defect this change exists to remove. See **D6** — this design does not
consume `question_index` and does not silently repair it.

**F3 — the empty-transcript hole is closed by *when* the delete happens, not by changing the guard.**
`replaceUtterances()` (`:845-864`) was already reordered by
`2026-08-20-liveavatar-contract-alignment` PR4: the `if (empty($transcript)) return;` guard now sits
**before** the `DELETE`, so it protects a good transcript from a soft fetch failure — which is
exactly why it must stay. The hole the brief describes is real only if attempt 1's utterances are
still present when attempt 2 ends. They are not, because the shared reset deletes them at re-offer
time, before `issue()` is even called. The distinction is temporal: **delete-on-reset, never
delete-on-write.** `replaceUtterances()` is unchanged.

**F4 — a terminal error is written on `/start`; no `/end` will ever fire for it.** Amending `/end`'s
tally is therefore necessary but *not sufficient*: nothing would ever re-evaluate it. The completion
CAS needs a second call site at the moment the bound is exhausted. See **D5**.

**F5 — correction to the proposal.** Decision 2 claims `next_action` costs "no new query". It costs
**one**: `/end` has the session but never loads the project, and the directive needs
`pause_every_n_competencies`. It is a single-column read on an ownership-proven FK — cheap, but the
claim as written is false and is corrected here rather than inherited.

---

## Architecture Decisions

### D1 — The durable bound is `interview_sessions.error_count`, NOT NULL DEFAULT 0, backfilled

**Column**: `$table->unsignedTinyInteger('error_count')->default(0)` — "the number of times this
session has been abandoned to `status = error`". Sole writer: `markSessionError()` (**F1**).
Constant: `InterviewSession::MAX_ERROR_ATTEMPTS = 2`.

| Option | Verdict |
|---|---|
| Increment on successful `issue()` ("attempts started") | **Rejected — unbounded.** The dominant error source is `issue()` *failing*, which never reaches the increment. Two failed issues would leave the counter at 0 and the re-offer branch open forever. |
| `reoffered_at` nullable timestamp (boolean-with-forensics) | **Rejected.** Encodes "one re-offer" in the column's *type*. A future decision to allow two (or to bound the operator path) becomes a migration instead of a constant. |
| Nullable integer, per the proposal's sketch | **Rejected.** Tri-state with no third meaning: every read site would carry `?? 0`. PostgreSQL 11+ adds a non-null column with a default as a catalogue-only operation — no table rewrite, so nullable buys nothing. |
| **`unsignedTinyInteger` NOT NULL DEFAULT 0 (chosen)** | Monotonic, cheap, and readable without a decoder ring. |

**The migration MUST backfill**: `UPDATE interview_sessions SET error_count = 1 WHERE status =
'error'`. Without it a legacy errored row reads 0, is granted a re-offer, errors to 1, is granted a
*second* re-offer, and gets three attempts — silently violating the ratified bound for exactly the
production rows this change exists to rescue.

**Durability across the reset**: `error_count` is never written by the reset (**D3**), never cleared,
and never inferred from `status`. A re-offered session sits at `pending` with `error_count = 1`; a
never-attempted session sits at `pending` with `error_count = 0`. The bound survives by construction.

**Not configurable.** CLAUDE.md ratifies *"Exactly 1 retry"* as a product invariant. A config knob
would let a tenant set 5 and break a ratified rule; a domain constant cannot.

### D2 — `resolveNextCompetency()` gains one branch, ordered between the existing two

```
pending | in_corso                                  → RESUME  (unchanged, first)
error AND error_count < MAX_ERROR_ATTEMPTS          → RE-OFFER (new)
error AND error_count >= MAX_ERROR_ATTEMPTS         → skip, terminal
completed | timeout | skipped                       → skip, terminal (unchanged)
```

The branch is ordered **after** RESUME and **before** the terminal skip. That ordering is what keeps
the ratified participant-sso scenario true — see **D8**.

The existing `pluck('status','competency_code')` becomes
`->get(['competency_code','status','error_count'])->keyBy('competency_code')`. Same query, one more
column.

Return type changes from `array{competency_code, question_index}` to a readonly
`App\Services\Interview\NextCompetency{competencyCode, questionIndex, ordinal, total, isReoffer}`.
**Rationale**: the array was about to grow from 2 keys to 5, maintained only by a docblock — which is
precisely the shape **F2** hid inside. `ordinal` and `total` come from the ordered list this method
already loads, at zero additional cost.

### D3 — One reset, extracted: `App\Actions\InterviewSession\ResetSessionForRetry`

`RecoverFailedParticipant.php:117-128` already performs the exact five writes plus the utterance
delete, and that behaviour is ratified at `participant-sso/spec.md:892-897`. It is **extracted
verbatim** into a shared action; `RecoverFailedParticipant`'s loop body becomes a call to it, and the
automatic re-offer calls the same object.

```php
final class ResetSessionForRetry
{
    /** @return int utterances discarded. MUST be called inside a transaction; the
     *  caller MUST have already proven ownership of $session. This action performs
     *  NO org filtering and NO status check — deliberately (see Multi-tenancy). */
    public function handle(InterviewSession $session): int;
}
```

| Option | Verdict |
|---|---|
| A second reset written inline in the controller | **Rejected.** Two implementations of a ratified rule is how one of them quietly stops obeying it. The brief forbids it explicitly. |
| Move the reset onto the `InterviewSession` model | **Rejected.** The utterance delete is a cross-table write; a model method that deletes children on `save()` is a landmine for every other caller. |
| **Shared action, transaction+ownership as documented preconditions (chosen)** | Both call sites already hold a lock and have already proven ownership by different means (org-filtered participant vs `resolveOwnedSession`). Duplicating the filter inside would be dead code in both. |

**It does not read or write `error_count`.** That single sentence is the whole answer to "does the
operator path silently acquire or bypass the bound" (**D4**).

**Call site (automatic)**: in `start()`, after `createOrResumeSession()` returns the existing `error`
row, inside `DB::transaction` + `lockForUpdate` + a re-read CAS on `status === 'error'`. The lock is
not for the counter (the reset never touches it) — it prevents a concurrent `/start` that has already
moved the row to `in_corso` from having its live `provider_session_ref` cleared out from under it.
The reset **commits before `issue()`**, so there is no window in which attempt 2 is live while
attempt 1's utterances exist (**F3**).

### D4 — The bound governs the automatic path only. The operator path stays unbounded. *(answers 1c)*

**Choice**: `RecoverFailedParticipant` remains unbounded and continues to reset an `error` session
regardless of `error_count`; it does not clear it.

**Rationale**:
- Per **F1** the two paths are reachable from disjoint participant states. A "global" bound would not
  unify two competing mechanisms — it would import a bound designed for an *unattended* retry loop
  into a *human-authorized*, 409-guarded, audit-logged write.
- The bound exists to stop a browser hammering a degraded provider. That failure mode does not exist
  behind an operator action.
- Because the counter is monotonic and the reset never clears it, an operator recovery grants
  **exactly one further attempt**, never a loop: the row returns to `pending` with `error_count`
  already at 2, so if it errors again the automatic branch stays closed. The operator can rescue
  again — deliberately, and on the record — but the machine never can.
- The rejected alternative is the proposal's own stated cost: a global bound removes the only rescue
  for a participant whose automatic re-offer was itself consumed by an outage.

**Testability**: assert both halves explicitly — recovery succeeds at `error_count = 5`, **and** a
recovered-then-re-errored session is not re-offered automatically.

### D5 — The completion CAS gains two call sites *(closes F4)*

`/end` steps (7)+(8) (`:293-312`) are extracted to
`settleCompletionIfFinished(int $participantId, int $projectId): void`, called from:

1. `/end`, inside the existing transaction — behaviour identical, tally amended (**D7**).
2. `handleProviderFailure()`, **after** the classification switch, when
   `$session->status === 'error' && $session->error_count >= MAX_ERROR_ATTEMPTS`.
3. `start()`'s `no_competency_remaining` branch, before the 422 — idempotent self-heal.

**Why site 2 is placed after the switch, not inside `markSessionError()`.** For `Upstream`,
`markParticipantFailed()` flips the participant to `errore`. Settling *before* that would flip
`in_corso → in_valutazione`, dispatch `FinalizeInterview`, and then have `markParticipantFailed()`
overwrite `in_valutazione → errore` — a scored, webhooked participant sitting at `errore`. Placed
after, the existing CAS predicate `where('status','in_corso')` is already the correct guard: for
`Upstream` it matches zero rows and does nothing. **One guard, no branch duplication, and it is the
same guard `/end` already relies on.**

**Why not "settle on the next `/start`"** (the obvious alternative): after a terminal error the
client renders the error screen and may never call anything again. A settlement that depends on a
client action that may never come is not a settlement.

**Residual, stated**: on a terminal error of the *last* competency the candidate lands on the
retryable error screen while scoring proceeds correctly behind them. `ParticipantStatusGuard` does
not block `in_valutazione`, so their retry reaches `/start` and gets `422 no_competency_remaining`.
**D11** maps that code to the done screen, which resolves it without a new contract field.

### D6 — `/start` returns `competency_ordinal` and `total_competencies`; `question_index` is untouched

```
POST /candidate/interview/start → 201
  question_context: {
    competency_code, question_index, end_phrase, final_phrase, prompt_version,   // unchanged
    competency_ordinal: int,     // NEW — 1-based index in project_competencies.position order
    total_competencies: int      // NEW
  }
```

Both machine-facing: literal in every locale, per CLAUDE.md.

**Why a new `competency_ordinal` rather than letting the client compute `question_index + 1`.** Per
**F2** that arithmetic yields `0/N` on the first competency of every API-created project. Fixing
`question_index` means changing a persisted column *and* an already-shipped contract field, and needs
a backfill decision — a different change with a different blast radius. Smuggling it in here would
mean this change ships a silent contract repair inside a flow rewrite. `competency_ordinal` is
derived from the ordered list's array index in `resolveNextCompetency()`, is correct by construction
regardless of what `position` contains, and costs nothing. **The `question_index` off-by-one is
recorded as an open item, not fixed here.**

**No `is_retry` field.** The only consumer of "this is a second attempt" is the avatar's spoken
greeting, composed server-side (**D10**). Putting it on the wire would create a fact the client can
disagree about — the defect class this change removes.

### D7 — `/end` returns the directive; the tally counts exhausted errors

```
POST /candidate/interview/end → 200   (today: null body)
  {
    ended_competencies: int,
    total_competencies: int,
    next_action: "continue" | "pause" | "done"
  }
```

**`ended_competencies`, not the proposal's `completed_competencies`.** The tally counts every
competency that reached a terminal state — including `timeout`, `skipped`, and a re-offer-exhausted
`error`. Calling that "completed" would put a second false statement into a contract this change
exists to de-falsify, and it would contradict the domain's own vocabulary (`ended_reason`,
`ended_at`, `$endedCount`).

**Amended tally** (replaces `whereIn('status', ['completed','timeout','skipped'])`):

```
status ∈ {completed, timeout, skipped}
  OR (status = 'error' AND error_count >= MAX_ERROR_ATTEMPTS)
```

**Directive computation — evaluated on the server, inside the `/end` transaction:**

```
if (ended >= total)                                          → "done"
elseif (pauseEvery !== null && ended % pauseEvery === 0)      → "pause"
else                                                         → "continue"
```

`done` is evaluated first, so a pause is never due on the final competency. `pauseEvery` comes from
`$session->project()->value('pause_every_n_competencies')` — the one new query (**F5**); a null
project fails closed to "no pause".

**Why server, not client** — SA-04 cadence is *tenant configuration*. A browser must not re-derive
tenant policy; the numbers are already in hand inside the transaction; client-side arithmetic is the
documented cause of Finding 2; and a server-side rule is assertable by a cheap Pest feature test
instead of an E2E.

### D8 — The ratified participant-sso scenarios still hold verbatim; no delta is required

`participant-sso/spec.md:895` justifies the recovery reset with *"`resolveNextCompetency()` continues
to skip already-answered competencies"*, and `:909-914` ("Resume, not restart") asserts the reset
`COL` competency is returned and nothing already answered is re-asked. Both survive **D2**:

- The operator reset leaves the session at **`pending`**, and the `pending | in_corso` branch is
  **untouched and still evaluated first**. The recovered session is returned by the same branch, for
  the same reason, in the same position order.
- "Already-answered" means `completed | timeout | skipped`. **D2** does not touch that branch. `error`
  was never "already answered" — it is the state the requirement was written to rescue.
- A session reset by the operator can never reach the new branch: it is `pending`, not `error`. And
  the operator path resets *every* `error` session for that participant, so on return there are none
  left.

**Consequence for `sdd-spec`**: no `participant-sso` delta is needed for correctness. The new shared
rule belongs as an ADDED requirement in `interview-session`. Two **code** docblocks do become false
and must be corrected in the same PR: `RecoverFailedParticipant.php:27-30` and `:36-41` state that
`resolveNextCompetency()` "treats `error` as terminal-completed", and
`2026_07_20_100002_create_interview_sessions_table.php:12` says "One row per competency **attempt**".

### D9 — The status enum is untouched; `skipped` stays; no new status is introduced

The LOCKED enum (`:19`/`:65`) is not extended. "Re-offered" is `status = 'pending'` +
`error_count > 0`, never a sixth state. `POST /end`'s `in:completed,timeout,skipped` validation is
unchanged (Decision 1) — only the *client* stops producing `skipped`.

### D10 — A fourth `OpeningTextComposer` variant: `retry`

`OpeningTextComposer::VARIANTS` gains `'retry'`; `lang/{it,en}/interview.php` gains
`opening.retry` with the `:competency` placeholder. Selection stays in the controller (design D9 of
the archived change), with precedence:

```
resume  >  retry  >  first  >  next
```

`resume` wins because a re-offered row is `pending`, never `in_corso` — the two can never collide.
`retry` wins over `first` because a competency can fail on the participant's very first attempt.

**Copy constraint** (binding on the it/en strings): `opening.retry` **MUST stand alone** — greet and
explain the repeat in one string. On the `ClientError` path the provider session never came up, so
the candidate may have heard nothing at all; a retry line that assumes a prior greeting would open
the interview mid-sentence.

No new version string: it ships under the existing `conversation.prompt_version`, per the ratified
one-version rule.

### D11 — The client consumes the directive; an absent directive degrades to `pause`

`callEnd()` today returns `void` and discards the body. It becomes
`Promise<EndDirective | 'noop' | null>`:

| Result | Client behaviour | Why |
|---|---|---|
| `next_action: "continue"` | `startSession()` immediately, no screen | the flow this change exists to deliver |
| `next_action: "pause"` | scheduled-pause screen | SA-04 |
| `next_action: "done"` | done screen | — |
| `'noop'` (HTTP 409) | **no transition at all** | 409 is the loser of the avatar-complete/timer race. Today both callers advance and it is harmless because they advance to the same state; under a directive-driven machine the loser has no directive and must not act. |
| `null` — absent, unknown value, or any other `/end` error | **`pause`** | see below |
| `403` / `401` | terminal, unchanged | — |

**Why the fallback is `pause` and not `continue` or `done`.** `continue` against a stale api loops
`/start` past the last competency into a 422 error screen. `done` truncates the assessment — the
exact defect being fixed. `pause` stops and asks the candidate to press continue: it degrades to
today's manual flow, which is safe, recoverable, and the behaviour a rolled-back api produces anyway.
The same fallback covers an unknown future `next_action` value, so the enum can grow without a
frontend deploy. **This is why the scheduled-pause screen keeps a resume control even though the
"Next" semantic is gone.**

**Hard rule**: the new `/start` fields **MUST NOT** be added to `isValidStartResponse()`
(`useInterviewSession.ts:142-169`). That guard turns a missing required field into a non-retryable
`malformed_response` terminal; requiring `total_competencies` there would convert an api rollback
from "degrades" into "every candidate hits a dead end". Read them defensively instead.

`422 no_competency_remaining` on `/start` maps to the **done** screen, not the retryable error screen
— closing the **D5** residual with a client mapping instead of a contract field.

### D12 — The inter-competency gap gets a named transition, not a skeleton

Today `confirmDevices()` → `clearActiveProvider()` → `connecting` renders a bare `<Skeleton>`
(`session.vue:38-46`) while the provider is torn down and rebuilt. With the interstitial gone the
candidate watches the avatar vanish into grey boxes mid-conversation.

| Option | Verdict |
|---|---|
| Keep one provider session alive across competencies | **Rejected — not buildable on the pinned stack.** `provider_session_ref` is per `InterviewSession`, and each competency carries its own context/prompt/greeting. Reuse is a provider-level multi-context feature that does not exist. |
| Freeze the last video frame to a canvas | **Rejected.** New code on the hot path, and the frozen frame is a human face stopped mid-sentence — that reads *more* broken, not less. |
| **Distinct transition panel (chosen)** | Renders when `state === 'connecting' && !avatarMounted && aPreviousCompetencyHasRun`. i18n keys `interview.transition.*` (it/en), the `ended/total` progress line, `aria-live="polite"`, `aria-busy="true"`. **No control, no minimum display time** — dismissed by the state machine alone, so it can never become a second interstitial. |

The **first** connect keeps today's skeleton: it follows a device check the candidate just
interacted with, which is a different expectation from an avatar disappearing mid-interview.

### D13 — `paused` SURVIVES as a state, with one entry edge; `pausedFrom` is deleted

The delta spec's state-machine line
(`specs/interview-frontend/spec.md:236`) currently reads
`idle → device_check → connecting → live → end_of_question → done | error | terminal`
and the parenthetical at `:240-241` says the ratified live mute-pause is *"unaffected and
unchanged"*. **Those two statements cannot both hold**: the shipped implementation of that ratified
mute-pause **is** the `paused` state (`useInterviewSession.ts:573-595`, released in `frontend`
v0.6.3). A machine without `paused` is not the machine the code implements.

**Choice**: `paused` stays. Its `live` entry edge is untouched. Its `end_of_question` entry edge is
**removed**, and the `pausedFrom` bookkeeping that existed only to serve that second edge is deleted
with it.

| Edge | Before (v0.6.3) | After | Why |
|---|---|---|---|
| `live → paused` | Pause control during `live`; mic muted; provider session **stays up** | **unchanged** | Ratified. Untouched by this change. |
| `paused → live` | Resume; mic unmuted | **unchanged**, and now unconditional | Sole destination — see below. |
| `end_of_question → paused` | Pause control on the between-competency screen | **REMOVED** | `end_of_question` becomes the SA-04 *scheduled pause* screen. A Pause control on a pause screen is meaningless, so the control is removed — and with it the only trigger for this edge. |
| `paused → end_of_question` | `resume()`'s `pausedFrom ?? 'end_of_question'` fallback | **REMOVED** | Unreachable once the entry edge is gone, and actively harmful — see below. |

**Why `pausedFrom` is deleted rather than left in place.** With a single entry edge it can only ever
hold one value; a variable with one possible value is a comment, not state. More concretely, its
`?? 'end_of_question'` fallback changes meaning under the new flow. Previously `end_of_question` was
the ordinary between-competency screen, so landing there was harmless. Under this change it is the
SA-04 scheduled-pause screen whose Continue control calls `/start` for the **next** competency — so
the same fallback, firing during a live competency, tears the avatar down and restarts the current
question from its opening line. (It does not *skip* the competency: the session is still `in_corso`,
so `resolveNextCompetency()`'s untouched RESUME branch returns the same competency. The loss is the
in-progress turn, not the competency.) Shipped code that outlives its reason does not stay inert; it
acquires a new and worse meaning. It goes.

**Two invariants that MUST be preserved — the v0.6.3 fix depends on both:**

1. **`pause()` and `resume()` assign `state.value` directly and MUST NOT be routed through
   `transitionTo()`.** `transitionTo()` calls `clearActiveProvider()` for
   `end_of_question | done | error | terminal` (`:221-225`); `paused` is deliberately absent from
   that list. Routing pause through it as a "consistency" cleanup would unmount `AvatarPlayer` and
   destroy the provider session the ratified pause exists to keep alive.
2. **The paused panel INSIDE the avatar branch of `session.vue` (`:110-120`) stays; the standalone
   `paused` section (`:146-158`) is removed.** With `live` as the only entry, `paused` now implies
   `avatarMounted`, so the in-avatar panel is the only reachable one and the resume control stays
   reachable — which is exactly the defect v0.6.3 repaired. The standalone section becomes dead: its
   own comment (`:107-108`) states its sole purpose is *"the between-competencies pause, where the
   provider has already been unpublished"*, and this change removes that pause. Leaving it would
   leave a second, unreachable resume affordance for a future reader to wire back up.

The invariant `paused ⇒ avatarMounted` is what makes removing the standalone section safe, so it MUST
be pinned by a unit test rather than left as a reading of the v-if chain. Nothing clears the provider
while paused: `clearActiveProvider()` is reached only from `transitionTo()`'s terminal list,
`confirmDevices()`, and `teardown()`, none of which run from `paused`.

**This design does not narrow the `pause()` guard as a matter of taste** — it narrows it because the
delta spec removes the product decision the second branch implemented. Retaining an unreachable
`end_of_question` branch would leave a removed product decision encoded in shipped code, which is how
it gets re-enabled by someone restoring "the missing Pause button".

**Spec amendment required — route this back to `sdd-spec`.** The design and the delta spec disagree
today, and the delta spec is the artifact that is wrong:

- `:236` MUST include `paused`, e.g.
  `idle → device_check → connecting → live ⇄ paused → end_of_question → done | error | terminal`.
- `:237-241` MUST stop implying `paused` is gone. The correct claim is narrower: the
  **between-competency, candidate-optional** pause is removed; the `paused` **state survives** with
  its `end_of_question` entry edge removed and `live` as its sole entry and exit.
- The screen table at `:247-257` MUST regain a row: **Pause (live mute)** | `paused` | entry
  "candidate presses Pause during `live`; mic muted, provider session kept alive" | exit "candidate
  presses Resume → `live`, mic unmuted".
- The parenthetical at `:263-268` currently says the "Pause / Resume row is removed". That MUST be
  narrowed to: the *between-competency* Pause/Resume row is removed; the live mute-pause row is
  retained with a single entry edge.

---

## Sequence: auto-advance and the bounded re-offer

```
CANDIDATE            FRONTEND                    API                              DB
    │  avatar signals completion
    │──────────────▶ callEnd('completed')
    │                    │── POST /end ─────────▶ txn + FOR UPDATE
    │                    │                        status := ended_reason
    │                    │                        ended = COUNT(terminal ∪ exhausted-error)
    │                    │                        total = COUNT(project_competencies)
    │                    │                        pauseEvery = project.pause_every_n
    │                    │◀── 200 {ended,total,next_action} ──┘
    │                    │
    │        ┌───────────┴───────────┬────────────────┐
    │   "continue"                "pause"          "done" | null→pause | 'noop'→∅
    │        │                       │                │
    │  transition panel (D12)   pause screen      done screen
    │        │                       │
    │        └────▶ POST /start ◀────┘
    │                    │
    │                    │   resolveNextCompetency()            ── ordered list + statuses
    │                    │      pending|in_corso  → RESUME
    │                    │      error, count < 2  → RE-OFFER ──▶ txn + FOR UPDATE
    │                    │      error, count >= 2 → skip           CAS status='error'
    │                    │      terminal          → skip           ResetSessionForRetry:
    │                    │                                           status  := 'pending'
    │                    │                                           refs/reason/ended_at := null
    │                    │                                           utterances DELETE   ◀── F3
    │                    │                                         (error_count UNCHANGED)
    │                    │   variant = resume > retry > first > next
    │                    │   issue()  ── outside any txn ──▶ provider
    │                    │◀── 201 {…, competency_ordinal, total_competencies}
    │  avatar speaks opening.retry
```

Terminal-error settlement (**D5**, the path that has no `/end`):

```
issue() fails ──▶ handleProviderFailure()
                    ├─ markSessionError():  status='error', ended_reason='error',
                    │                       error_count += 1        ← sole writer (F1)
                    ├─ Upstream only: markParticipantFailed() → participant 'errore'
                    └─ if error_count >= 2:
                          settleCompletionIfFinished(pid, projectId)
                             CAS: participants WHERE id=? AND status='in_corso'
                                  → 'in_valutazione';  won===1 ⇒ FinalizeInterview
                             Upstream ⇒ participant already 'errore' ⇒ 0 rows ⇒ no-op
```

---

## Multi-tenancy — every query scope, explicit

`InterviewSession` and `Project` extend `TenantModel`, so the `TenantScoped` global scope appends
`{table}.organization_id = resolver->getOrgId()` to **every** Eloquent SELECT; the candidate context
is established by `TenantContextCandidate`. `Participant` is deliberately *not* scoped
(`participant-sso/spec.md:873-878`) and requires an explicit filter. Raw `DB::table()` builders get
no scope at all.

| # | Query | Scope | Notes |
|---|---|---|---|
| 1 | `resolveNextCompetency()` ordered list — `DB::table('project_competencies as pc')` | `pc.project_id = $project->id` | **Raw builder — no global scope.** `$project` is `auth('api-candidate')->user()->project`, i.e. an FK on the JWT-authenticated participant row; `project_id` is never taken from the request. Also the source of `ordinal` / `total` (**D6**). |
| 2 | `resolveNextCompetency()` existing sessions — `InterviewSession::…get(['competency_code','status','error_count'])` | global org scope **+** `participant_id` **+** `project_id` | Column list widened only. |
| 3 | Re-offer reset CAS — `InterviewSession::lockForUpdate()->find($id)` | global org scope **+** PK | Row already resolved through queries 1–2 for the authenticated participant. |
| 4 | `ResetSessionForRetry` utterance delete — `$session->utterances()->delete()` | `interview_session_id = $session->id` | The action performs **no** org filter **by design** (**D3**); both callers prove ownership first (`resolveOwnedSession` / org-filtered `Participant` + `lockForUpdate`). Stated as a precondition in the class docblock, because a shared action with no scope is exactly how a cross-tenant hole gets added later. |
| 5 | Amended `/end` tally — `InterviewSession::…count()` | global org scope **+** `participant_id` **+** `project_id` | Only the status predicate changes. |
| 6 | **NEW** cadence read — `$session->project()->value('pause_every_n_competencies')` | global org scope on `Project` **+** FK `$session->project_id` | The session was ownership-proven by `resolveOwnedSession()` (participant + org). Null project ⇒ no pause. This is **F5**'s one new query. |
| 7 | `settleCompletionIfFinished()` CAS — `Participant::where('id',$pid)->where('status','in_corso')` | explicit `id`; **no** org scope on `Participant` | Unchanged from `:304-306`. `$pid` originates from an ownership-proven session, never from the request. |

**Required test**: a second organization with an identically-coded competency and a participant at
`error` MUST NOT be re-offered, tallied, or reset by the first organization's `/start` or `/end`.

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/database/migrations/…_add_error_count_to_interview_sessions.php` | Create | `unsignedTinyInteger('error_count')->default(0)` + backfill `WHERE status='error'` (**D1**) |
| `api/database/migrations/2026_07_20_100002_create_interview_sessions_table.php` | Modify | Docblock `:12` corrected — one row per competency, *n* attempts (**D8**) |
| `api/app/Models/InterviewSession.php` | Modify | `MAX_ERROR_ATTEMPTS = 2`, `@property int $error_count`, status docblock (**D1**) |
| `api/app/Actions/InterviewSession/ResetSessionForRetry.php` | Create | The single reset, extracted verbatim (**D3**) |
| `api/app/Actions/Participant/RecoverFailedParticipant.php` | Modify | Loop body → shared action; false docblocks `:27-30`, `:36-41` corrected (**D3**, **D8**) |
| `api/app/Services/Interview/NextCompetency.php` | Create | Readonly result of `resolveNextCompetency()` (**D2**) |
| `api/app/Http/Controllers/Candidate/InterviewController.php` | Modify | Re-offer branch + reset call site; `settleCompletionIfFinished()` extraction + 2 new call sites; amended tally; directive computation; `competency_ordinal`/`total_competencies`; `retry` variant (**D2**,**D5**,**D6**,**D7**,**D10**) |
| `api/app/Services/Conversation/OpeningTextComposer.php` | Modify | `'retry'` variant (**D10**) |
| `api/lang/{it,en}/interview.php` | Modify | `opening.retry` (**D10**) |
| `api/openapi.json` → `frontend/openapi.json`, `frontend/app/types/api.ts` | Regenerate | Scramble → typed client; never hand-edited |
| `frontend/app/composables/useInterviewSession.ts` | Modify | `callEnd` returns the directive; `advanceAfterQuestion(directive)`; `competencies` option deleted; server-fed progress; Skip removed; `EndQuestionReason` narrows to `'timeout'` (**D11**); `pause()` guard narrows to `live`, `pausedFrom` deleted, `resume()` returns unconditionally to `live` (**D13**) |
| `frontend/app/pages/interview/session.vue` | Modify | Skip control removed; `end_of_question` becomes the scheduled-pause screen (its secondary Pause control removed); transition panel; real progress total (**D11**, **D12**); standalone `paused` section `:146-158` removed, in-avatar paused panel `:110-120` **kept** (**D13**) |
| `frontend/i18n/locales/{it,en}.json` | Modify | `interview.live.skip` removed; `interview.scheduled_pause.*`, `interview.transition.*` added |
| `api/app/Http/Controllers/Candidate/InterviewController.php` `:845-864` | **Unchanged** | `replaceUtterances()` guard is correct (**F3**) |
| `backoffice/**` | **Unchanged** | Already ships `pause_every_n_competencies` |
| `openspec/specs/interview-frontend/spec.md` `:24-25`, `:441`, `:450-462`, `:858-861`, `:867-871`, `:884` | Delta | `:24-25` is a factual correction (`sdd-spec` owns it) |
| `openspec/changes/interview-continuous-flow/specs/interview-frontend/spec.md` `:236`, `:237-241`, `:247-257`, `:263-268` | **Delta correction owed** | The delta drops `paused` from the state machine while claiming the ratified live pause is unchanged. `sdd-spec` must restore `paused` and narrow the removal to the between-competency edge (**D13**) |
| `openspec/specs/interview-session/spec.md` | Delta | Bounded re-offer, shared reset, `/start` + `/end` contracts |

---

## Testing Strategy

Strict TDD: every row below is RED first. Several existing tests currently *defend* the behaviour
being removed and must be corrected before any GREEN.

| Layer | What | How |
|---|---|---|
| Unit (api) | `ResetSessionForRetry`: five writes + utterance delete; `error_count` **unchanged** | Pure DB, no HTTP |
| Unit (api) | `OpeningTextComposer` `'retry'`: it/en, `:competency`, locale fallback, no BARS reachability | Pure |
| Feature (api) | Re-offer once; second `error` terminal and never offered a third time | `Http::fake` forcing `ClientError` |
| Feature (api) | Re-offer **deletes attempt 1's utterances** — asserted at `/start`, before `issue()` (**F3**) | DB assertion |
| Feature (api) | Terminal error on the **last** competency reaches `in_valutazione` and dispatches `FinalizeInterview` (**D5** site 2) | `Queue::fake` |
| Feature (api) | `Upstream` failure at `error_count = 2` does **NOT** dispatch scoring (participant `errore`) | `Queue::fake`, asserts the CAS guard |
| Feature (api) | Operator recovery succeeds at `error_count = 5`; the recovered-then-re-errored session is **not** auto-re-offered (**D4**) | Both halves in one test — asserting them apart is how one stops being true |
| Feature (api) | Migration backfill: a pre-existing `error` row gets exactly **one** re-offer | Seed at the old schema, migrate, assert |
| Feature (api) | SA-04: `pause_every_n = 3`, N = 7 → `pause` after 3 and 6, `continue` elsewhere, `done` at 7 | Directive assertions, no E2E needed |
| Feature (api) | `pause_every_n = null` → `continue` for every competency but the last |  |
| Feature (api) | `competency_ordinal` is `1..N` even when `question_index` is `-1` (**F2**) | Project built through `ProjectController` |
| Feature (api) | **Cross-tenant**: org B's `error` session is not re-offered, reset, or tallied by org A | Dedicated scenario per `rules.specs` |
| Contract (api) | `ResourceContractTruthTest` + regenerated `openapi.json` carry the new fields | Existing harness |
| Unit (frontend) | Directive → transition matrix incl. `null → pause`, unknown → `pause`, `409 → noop` (**D11**) | Vitest, mocked `candidateFetch` |
| Unit (frontend) | `isValidStartResponse` still passes when the new fields are **absent** (rollback guard) | Vitest |
| Unit (frontend) | `i18n-interview-keys`: `interview.live.skip` gone; `scheduled_pause.*`/`transition.*` present in it **and** en | Existing harness |
| Unit (frontend) | **Ratified live pause is untouched**: `pause()` from `live` mutes the mic, keeps the provider session alive, and `resume()` returns to `live` and unmutes (**D13**) | Vitest — the v0.6.3 regression guard |
| Unit (frontend) | `pause()` from `end_of_question` is a **no-op** (edge removed), and `resume()` from `paused` can only land on `live` | Vitest |
| Unit (frontend) | Invariant `paused ⇒ avatarMounted`, so the in-avatar resume control is always reachable — pinned before the standalone section is removed (**D13**) | Vue Test Utils on `session.vue` |
| E2E | Pause during a live question, resume, and finish the same competency — no restart, no lost turn | Playwright chromium + webkit |
| E2E | `pause_every_n = null`, N > 1: zero clicks between competencies, progress `1/N…N/N`, done screen | Playwright chromium + webkit |
| E2E | `pause_every_n = 3`: pause screen after 3 and 6 only | Playwright |
| Coverage | Candidate state machine ≥ ~95% per CLAUDE.md; api ≥ 85%; frontend ≥ 85% | `--coverage --min` gates |

---

## Migration / Rollout

**Deploy order is a hard constraint: `api` before `frontend`, and PR 1 before PR 2 within `api`.**

**The additive claim, verified rather than asserted:**
- `/start`: `isValidStartResponse()` (`:142-169`) checks only required keys and does not reject
  unknown ones; a stale frontend ignores `competency_ordinal` / `total_competencies`. ✔
- `/end`: `callEnd()` (`:323-333`) `await`s and **discards** the response body; a stale frontend is
  byte-identical whether the body is `null` or JSON. ✔

**Rollback asymmetry — read this before reverting anything:**
- `frontend` reverts alone and safely (restores the manual-Next flow *and* its one-competency
  truncation).
- `api` PR 2 reverts alone **only while PR 3 is unshipped**. Once shipped, a revert makes `/end`
  return `null` — which **D11** degrades to `pause`, i.e. today's manual flow, not a crash.
- `api` PR 1 reverts to a **worse** state than neutral: the old tally re-strands participants. Roll
  forward.
- **The migration MUST NOT be down-migrated on a code revert.** `error_count` is additive and unread
  by the reverted code, so leaving it costs nothing. Dropping it while a re-offered session sits at
  `pending` erases the only record of the bound; on re-deploy that row reads 0 and is granted a
  second re-offer. `down()` still drops the column for local development, and the migration docblock
  must say in words that it is not to be run against production while any row has `error_count > 0`.

Sessions in flight across a deploy carry no incompatible state: every competency is an independent
row and the directive is recomputed from the database on every `/end`.

**Behaviour changes to log, not to file as regressions:** demo tenants seeded at
`pause_every_n = 2` and `3` (`DemoDataset.php:56,68`) will start showing pause screens; `null`
projects become genuinely continuous.

---

## Open Questions

- [ ] **Is a fully continuous 14–18 competency interview acceptable for `null` projects?** Product.
      The design does not depend on the answer — if the answer is no, the fix is a non-null default
      in project configuration, never a hardcoded interstitial.
- [ ] **Should the SA-04 pause be capped?** Left untimed. An uncapped pause can idle until the
      candidate JWT expires, surfacing as the `session_expired` terminal — a poor ending to a
      deliberate rest. A cap is an additive client timer and needs no contract change, so this is
      answerable after ship.
- [ ] **`opening.retry` copy (it/en)** needs authoring against the **D10** stand-alone constraint.
      Wording is product; the constraint is not.
- [ ] **Does the 5-minute per-question timer keep running while the candidate is paused?** Two
      ratified decisions meet here and neither addresses the other: the timer stays, and the live
      mute-pause stays. Today `endQuestion()` guards on `state === 'live'`, so a timer expiry that
      lands during `paused` is swallowed and the question runs past its cap. Surfaced while writing
      **D13**; not settled here because "pause the clock" and "the cap is wall-clock" are both
      defensible product answers with different fairness implications.
- [ ] **The `question_index` off-by-one (F2)** — `-1` for the first competency of every API-created
      project. Deliberately **not** fixed here (persisted column + shipped contract field + backfill
      decision). Should be raised as its own change; **D6** ensures this one does not depend on it.
- [ ] **Confirmed, not open:** Decision 3 — a count and a directive reach the browser, never the
      ordered competency list. **D6**/**D7** leave the list with no client-side consumer at all, so
      the anti-leak posture is preserved by construction rather than by policy.
