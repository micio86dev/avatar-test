# Design: Participant Error Recovery

Store mode: hybrid. Engram mirror: `sdd/participant-error-recovery/design`.
Inputs: `proposal.md` (Engram #1207), explore (#1174), incident (#1170).

## Technical Approach

`errore` stays terminal for everyone except one authorized, org-scoped, audited
operator action. That action is NOT a status flip: **recovery is a resume, not a
restart**, and it is a two-table unit of work (participant + the errored
`InterviewSession`) executed under a row lock. A status-only recovery — what the
proposal assumed — is provably broken; see D2.

Everything else composes with machinery that already exists: the `booted()`
transition guard enforces the new edge, `EntryLinkMinter` mints for `in_attesa`
with zero new gate logic, and `resolveNextCompetency()` already resumes by
session status.

---

## D0 — Branch base (decide first; a wrong base silently reinstates the bug)

Base: **`feature/liveavatar-contract-alignment-pr6-tavus-concurrency`**, NOT
`develop`. Verified by reading the working tree, not by assumption:
`app/Enums/ProviderFailureClass.php` exists, and
`InterviewController::markParticipantFailed()` is present at `:697-708` carrying
the seam docblock that names this change. `develop` has neither.

Pre-apply gate: `markParticipantFailed` MUST be greppable in
`app/Http/Controllers/Candidate/InterviewController.php` before the first commit.
If it is not, STOP — the base is wrong. If the sibling chain merges to `develop`
first, rebase this whole chain onto `develop` in one operation and re-run the gate.

---

## D1 — Where the recovery transition lives

| Option | Tradeoff | Decision |
|---|---|---|
| Inline in the controller | Blocked by `AdminTenancySafetyArchTest:102-113` (any literal `Participant::` under `app/Http/Controllers/Api`); work is multi-table + transactional | Rejected |
| `Participant::recover()` model method | Puts locking, session reset, utterance deletion and logging on a deliberately thin model whose only job is the transition guard | Rejected |
| Extend `AdminParticipantReader` | Its value is that it can only be used one way (read scope + lifecycle threshold). A write path there weakens the one component the arch guard protects | Rejected |
| **Dedicated action class** | Second org-filter site (must be tested), but keeps the guard's *intent* rather than routing around its text match | **Chosen** |

`App\Actions\Participant\RecoverFailedParticipant`, invoked by a thin
`ParticipantRecoveryController` under `app/Http/Controllers/Api`. The controller
calls `$this->authorize('recover', ParticipantPolicy::MODEL)` and passes the raw
int id — it never names `Participant`. The action lives under `app/Actions`, so
the arch guard does not fire, and it applies the org filter verbatim in the
`AdminParticipantReader:49-50` shape:
`Participant::where('organization_id', $resolver->getOrgId())->findOrFail($id)`.

Route: `POST /api/participants/{id}/recover`, own `auth:api` + `TenantContext`
group adjacent to (not inside) the Admin Read API block — mirroring
`POST /api/entry-links` (`routes/api.php:227-229`), because this is a WRITE.

---

## D2 — THE CRUX: what a recovered candidate actually re-enters

The proposal's open risk ("partial transcript, advanced `question_index`,
restart-from-zero?") is built on a wrong mental model, and it hides a worse bug.

**There is no participant-level cursor.** `question_index` is an
`interview_sessions` column set to `pc.position - 1` (`InterviewController:453`)
— a competency ordinal, not an intra-competency counter. Resume state lives
entirely in session rows, independent of `participant.status`.

**The real defect — verified by reading the code, not inferred:**

1. `markSessionError()` (`:666-684`) sets `session.status = 'error'`.
2. `resolveNextCompetency()` (`:446-466`) treats `error` as terminal-completed
   and **skips that competency forever**.
3. `end()`'s completion CAS (`:284-302`) counts only
   `whereIn('status', ['completed','timeout','skipped'])` — `error` is never
   counted, so `endedCount` can never equal `totalCompetencies`.

Therefore a status-only recovery produces a **second, quieter dead end**: the
candidate re-enters, silently skips the failed competency, finishes everything
else, and the participant is stranded in `in_corso` forever — scoring never
dispatched, no webhook ever sent. That is *worse* than today's lockout, which at
least renders an "Errore" badge. It is exactly the un-alerted stranded-`in_corso`
case the archived `operator-interview-link` change flagged as an open follow-up.
**This applies to the "safe" `in_attesa`-origin case too** — a first-competency
failure also leaves an `error` session.

### Decision

Recovery is an atomic unit of work, inside one transaction:

1. `participant.status: errore → in_attesa`
2. every `InterviewSession` for that participant with `status = 'error'` reset to
   `pending`, clearing `provider_session_ref`, `ended_reason`, `ended_at`
3. those sessions' `utterances` **deleted**
4. sessions in `completed | timeout | skipped` are **never touched**

Because (4) holds, `resolveNextCompetency()` still skips already-answered
competencies: **the candidate resumes at the failed competency and is not
re-asked anything they already answered.** Restart-from-zero never happens and
was never required.

| Alternative | Why rejected |
|---|---|
| Delete the errored session row | `UNIQUE(participant_id, competency_code)` makes a fresh row possible, but deletion destroys the failure's audit trail and cascades to any utterances |
| Leave `error`, insert a retry row | Blocked by the same unique constraint; needs an attempt column → migration (proposal forbids schema change) |
| Refuse recovery for `in_corso`-origin | Inverts the value: the candidate with 15 minutes invested is the one most worth saving; origin is also not recorded anywhere, only inferable |
| Keep the partial utterances | See below |

### Why deleting the partial utterances is correct, and why it is disclosed

The reset competency is re-asked **from its first question**. Keeping the
interrupted fragment would feed the scorer a transcript in which the candidate
answers the same competency twice, the second answer contradicting the first.
BARS scoring matches answers against anchors and requires `excerpts` **verbatim**
from the transcript — a duplicated partial turn actively degrades scoring, it
does not enrich it. Note the provider asymmetry that makes "just leave them" not
even consistent: HeyGen's `/end` `replaceUtterances()` would silently overwrite
them anyway; Tavus keeps live rows and would append, producing the incoherent
double transcript. Deleting makes both providers behave identically.

**This is real data loss and the operator MUST see it before confirming.** The
scope is bounded — one competency, chosen explicitly by the operator. The
backoffice confirm dialog names the competency to be re-asked and warns the
partial answer will be discarded, sourced from the existing
`GET /participants/{id}/sessions`; the 200 response reports
`{ competencies_reset[], utterances_discarded }`. No new read endpoint. (Task
phase: verify that payload exposes an utterance count; if not, the dialog names
the competency only and the count appears in the response.)

### D2b — `started_at` must not be clobbered

`$isFirst = $participant->status === 'in_attesa'` (`:135`) drives both the
opening-greeting variant and the `started_at` stamp (`:606-611`). A recovered
participant is `in_attesa`, so on re-entry the avatar would greet a candidate who
already answered three competencies as brand new, and `started_at = now()` would
destroy the true start shown in the backoffice timeline.

Fix: `$isFirst = $participant->started_at === null`. One line; makes `started_at`
write-once; fixes greeting and timestamp together. **Behaviour-preserving on every
existing path** — today `started_at` and `status = 'in_corso'` are written in the
same transaction, so the two predicates agree everywhere except the newly created
recovered path. In bounds of the sibling's seam contract, which protects
`markParticipantFailed()`'s body and the classification switch, neither of which
this touches.

---

## D3 — Refusal-reason split and HTTP status

`EntryLinkRefusalReason::Terminal` → `Completed` + `Failed` (English API
vocabulary; `errore` is a DB value, not a contract word). The gate stays inside
`EntryLinkMinter` (single-source requirement, participant-sso spec:980-1002); the
response literals stay per-caller in BOTH `EntryLinkController:83-86` and
`SsoLinkController:94-97`, because Scramble derives each schema from those call
sites.

**Both remain 409.** A recoverable-but-failed participant does not warrant 423 or
422: 409 ("conflict with current resource state") is correct for both, and the
difference — whether the state *can* change — is semantic, not protocol-level.
The calling system cannot recover a participant either way; only a BEAI operator
can, so a third status code buys the M2M client nothing and costs it a new branch.
It also keeps `Feature/C6/SsoLinkMintTest.php:257` green.

Honesty is carried by the body, plus a machine-readable discriminator so the
backoffice never string-matches:

| Reason | Status | Body |
|---|---|---|
| `Completed` | 409 | `{ message: "Conflict: participant has already completed this assessment.", reason: "completed" }` (message unchanged) |
| `Failed` | 409 | `{ message: "Conflict: this participant's assessment failed and must be re-opened by an operator before a new link can be issued.", reason: "failed" }` |

`reason` is machine-facing → not localized (CLAUDE.md). Additive; greenfield, no
back-compat obligation.

---

## D4 — Authorization

Ability **`recover`** on `ParticipantPolicy`; route, action, log event and i18n key
all use the same word. Rejected: `update` (too generic — a future reader would
widen it silently); `reopen` (suggests reopening a *successful* assessment, which
is precisely what D5 refuses).

Grant: `admin` + `operator`; `viewer` denied — same reasoning as `create`
(`ParticipantPolicy:59-70`), with more force: recovery mutates lifecycle state.

Org scoping is **not** in the policy. The policy stays role-only, matching every
existing ability here ("org scoping is the reader's job, not the policy's",
`AdminParticipantReader:14-16`). It is enforced by the action's `where(
'organization_id', ...)->findOrFail()`.

Failure order is **403 → 404** (authorize model-lessly in the controller, then
resolve in the action) — matching `EntryLinkController:25-31`, the write
precedent: a viewer never learns whether an id exists in another org. This is
deliberately the inverse of `AdminParticipantReader`'s read order (404 → 403),
which has a model in hand.

---

## D5 — Refusal guards (what recovery will NOT do)

Both evaluated inside the transaction, before any write.

1. **Evaluation already delivered → 409 `evaluation_already_delivered`.**
   `WebhookDelivery::where('participant_id', $id)->where('event_type',
   WebhookEventType::Evaluation)->exists()`. `WebhookDelivery` is a `TenantModel`,
   so the global scope applies — cannot leak cross-org. This checks that a
   delivery *row exists*, not that it succeeded: a `skipped` or `failed` row still
   means BEAI decided the assessment was over and told (or tried to tell) the
   caller. Conservative reading, and the enforceable one.
2. **Nothing to recover → 409 `nothing_to_recover`.** Requires at least one
   `InterviewSession` with `status = 'error'`.

Guard 2 is the clean structural discriminator between failure writers, and it
means the code never has to know which writer fired: `createOrResumeSession()`
always runs *before* `issue()`, so **every** interview-stage (Writer-1) failure
leaves exactly one `error` session, and **no** scoring-stage failure (Writers 2/3,
which fire from `in_valutazione` with all sessions `completed`) leaves any. It
also correctly catches the `ZeroCompetencies` invariant case (Writer 2), which
guard 1 would miss — recovering it would land the candidate on a
`no_competency_remaining` 422, another dead end. The two guards are mutually
exclusive in practice; both are kept because each documents a different
invariant. Guard 1 runs first — it gives the more informative refusal.

---

## D6 — Idempotency and concurrency

`DB::transaction` + `lockForUpdate` on the participant row — the `end()` pattern
(`:255-257`). Status is re-read **inside** the lock:

| In-lock status | Result |
|---|---|
| `errore` | Proceed |
| `in_attesa` | 200 idempotent no-op — the other operator already recovered. Session reset and utterance deletion do NOT re-run (this is why the re-read is inside the lock) |
| `in_corso` / `in_valutazione` / `completato` | 409 `not_failed` — the candidate is live again; re-opening now would be destructive |

**Recover racing an in-flight `/start`**: `/start` does not lock the participant,
so both interleavings must be safe, and both are, with no new mechanism:
- `/start` commits `in_corso` first → recovery re-reads `in_corso` → 409.
- Recovery holds the lock → `/start`'s `save()` blocks, then resumes with a stale
  in-memory original of `errore` and attempts `errore → in_corso` → the `booted()`
  guard throws `ParticipantTransitionException` → 422. Fail-closed. The candidate
  retries and gets a clean start. Accepted, and pinned by a feature test.

---

## D7 — Interim audit logging (explicit debt)

Default `stack` channel, `Log::info`. **No dedicated channel** — a channel named
`audit` would look like an audit trail and invite people to trust it. A named
message prefix is enough to grep and keeps the debt visible.

```
participant.recovered (INTERIM — NOT the ratified audit trail, openspec/specs/audit-log/spec.md)
{ participant_id, organization_id, project_id, actor_user_id,
  previous_status: 'errore', new_status: 'in_attesa',
  reason: <operator free text, nullable, max 500>,
  competencies_reset: [<code>], utterances_discarded: <int>,
  at: <ISO-8601> }
```

No `display_name`, no `candidate_ref`, no actor email — the audit-log spec
mandates denylist redaction, `participants.display_name` is explicitly inside the
pending GDPR sign-off (CLAUDE.md decision 2), and `candidate_ref` is the
cross-system join key. Internal ids are sufficient.

**Stated plainly: this does NOT satisfy CLAUDE.md's admin-audit-log NFR.** It is
not append-only, not tenant-queryable, not retained, not policy-redacted. It is
visible, accepted debt against `openspec/specs/audit-log/spec.md`, of which
nothing is implemented.

---

## D8 — Frontend honesty (`frontend` submodule)

The `error` state is genuinely retryable sometimes (429-exhausted; and now
ClientError → 500, which leaves the participant untouched) and genuinely fatal
others (Upstream → `errore`). Copy must be true in both cases and must not
contradict the 403 terminal screen the candidate may hit next.

| Key | en | it |
|---|---|---|
| `interview.error.body` | "The interview was interrupted by a technical problem. You can try again now. If the problem persists, your assessment will need to be re-opened by the recruitment team." | "Il colloquio è stato interrotto da un problema tecnico. Puoi riprovare ora. Se il problema persiste, sarà necessario che il team di selezione riapra la valutazione." |

`title` and `retry` unchanged. Neutral, professional Italian.

Structural guard (`frontend/tests/unit/i18n-interview-keys.spec.ts`), extending
D-F from `session_expired` to `error`:
- add `interview.error.body` to `REQUIRED_KEYS` — it is currently **absent**
  (only `.title` and `.retry` are listed), so nothing enforces its existence
- new describe block asserting the body does not promise a resume, with
  **locale-specific** patterns (unlike D-F, where "link" is the same word in both):
  `it → /riprender|dal punto in cui/i`, `en → /resume|where you left off/i`

---

## D9 — Backoffice action (`backoffice` submodule)

Follows the existing write pattern exactly, no invention:
- `app/composables/useParticipantRecovery.ts` — thin `useApi().apiFetch` wrapper
  typed from `types/api.ts`, mirroring `useEntryLinks.ts:17-27`
- `app/components/organisms/ParticipantRecoveryPanel.vue`, rendered inside the
  existing `<Card v-if="!isViewer">` region of `app/pages/participants/[id].vue`,
  shown only when `participant.status === 'errore'`
- confirm dialog per D2 (names the competency, warns about the discarded partial
  answer) + optional free-text reason bound to the request body
- i18n keys in `backoffice/i18n/locales/{it,en}.json`

`!isViewer` is UI convenience only — `ParticipantPolicy::recover` is the real gate.

**Cross-submodule ordering constraint**: `types/api.ts` is generated from the
API's `openapi.json`, so PR3 cannot be typed until PR2 has landed, Scramble has
been regenerated, and the wrapper's submodule pointer moved.

---

## Data Flow

```
operator ──POST /participants/{id}/recover──> ParticipantRecoveryController
                                                  │ authorize('recover', ParticipantPolicy::MODEL)  → 403
                                                  ▼
                                        RecoverFailedParticipant (app/Actions)
                                                  │ org filter + findOrFail                          → 404
                                                  ▼
                            ┌──── DB::transaction ─────────────────────────────┐
                            │ lockForUpdate(participant)                        │
                            │ guard 1: evaluation WebhookDelivery exists?       │ → 409
                            │ guard 2: any session.status = 'error'?            │ → 409
                            │ re-read status: in_attesa → no-op 200 │ else 409  │
                            │ participant: errore → in_attesa  (booted() guard) │
                            │ sessions error → pending (refs/reason/ended_at ⌀) │
                            │ delete utterances of those sessions ONLY          │
                            └───────────────────────────────────────────────────┘
                                                  │
                                     Log::info participant.recovered (interim)
                                                  ▼
        operator mints a link ──> EntryLinkMinter sees in_attesa ──> 201 (zero new gate logic)
                                                  ▼
        candidate re-enters ──> resolveNextCompetency() skips completed competencies,
                                returns the reset one (pending) ──> RESUME, not restart
                                                  ▼
        finishes remaining ──> endedCount == totalCompetencies ──> in_valutazione ──> scoring
```

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Models/Participant.php` | Modify | `'errore' => ['in_attesa']`; update the transition-map docblock (`:33-38`, `:91-116`) |
| `api/app/Actions/Participant/RecoverFailedParticipant.php` | Create | Org filter, lock, both guards, participant + session reset, utterance delete, interim log |
| `api/app/Http/Controllers/Api/ParticipantRecoveryController.php` | Create | Thin; authorize + delegate; no literal `Participant` |
| `api/app/Policies/ParticipantPolicy.php` | Modify | `recover()` — admin + operator |
| `api/routes/api.php` | Modify | `POST /participants/{id}/recover` in its own write group |
| `api/app/Exceptions/Sso/EntryLinkRefusalReason.php` | Modify | `Terminal` → `Completed` + `Failed` |
| `api/app/Support/Sso/EntryLinkMinter.php` | Modify | `:61-63` selects the reason by status |
| `api/app/Http/Controllers/Api/EntryLinkController.php` | Modify | Two-arm 409 match + `reason` discriminator |
| `api/app/Http/Controllers/M2m/SsoLinkController.php` | Modify | Same, per-caller literals |
| `api/app/Http/Controllers/Candidate/InterviewController.php` | Modify | `$isFirst` → `started_at === null` (D2b) + `markParticipantFailed()` docblock. Body unchanged; classification switch untouched |
| `frontend/i18n/locales/{it,en}.json` | Modify | `interview.error.body` |
| `frontend/tests/unit/i18n-interview-keys.spec.ts` | Modify | Add the key + the locale-specific resume-promise guard |
| `backoffice/app/composables/useParticipantRecovery.ts` | Create | Mirrors `useEntryLinks.ts` |
| `backoffice/app/components/organisms/ParticipantRecoveryPanel.vue` | Create | Panel + confirm dialog |
| `backoffice/app/pages/participants/[id].vue` | Modify | Mount the panel in the existing `!isViewer` card |
| `backoffice/i18n/locales/{it,en}.json` | Modify | Recovery copy |
| `openspec/specs/participant-sso/spec.md` | Modify (delta) | Lifecycle guard (`:96-127`), mint refusal reason (`:235-241`), shared-minter re-affirmation (`:980-1002`) |

No migrations. No schema. No backfill.

---

## Interfaces

```
POST /api/participants/{id}/recover     auth:api + TenantContext
  body:  { reason?: string|null }            // max 500, operator free text
  200:   { status: "in_attesa",
           competencies_reset: string[],     // competency codes to be re-asked
           utterances_discarded: int }
  403 | 404 | 409 { reason: "evaluation_already_delivered" | "nothing_to_recover" | "not_failed" }
```

---

## Testing Strategy (strict TDD — RED first, always)

| Layer | What | Where |
|---|---|---|
| Unit | `errore → in_attesa` allowed; `→ in_corso`, `→ in_valutazione`, `→ completato` still rejected | extend `Unit/C7a/ParticipantTransitionsC7aTest.php:137,145` |
| Unit | Minter returns `Failed` for `errore`, `Completed` for `completato` | `Unit/Sso/EntryLinkMinterTest.php:90-111` — the existing test BREAKS by design; correct it first, add the sibling |
| Feature | **Full-cycle invariant**: fail at competency 2 of 3 → recover → re-enter → finish 2 and 3 → participant reaches `in_valutazione`, `FinalizeInterview` dispatched | new — **non-negotiable**; this is the test that catches the D2 session-skip trap |
| Feature | Resume-not-restart: already-`completed` competencies are NOT re-asked | new |
| Feature | Cross-tenant 404; viewer 403; ordering 403-before-404 | new |
| Feature | Idempotent double-recover (no second utterance deletion); recover vs `/start` both interleavings | new |
| Feature | Both refusal guards; `started_at` not clobbered | new |
| Feature | **Regression guard**: ClientError (4xx) and Throttle (429) leave the participant untouched, for both `in_attesa` and `in_corso` origins — 4 cases | extends `Feature/C7a/InterviewStartTest.php:386` |
| Feature | Both mint controllers' 409 message + `reason` | `Feature/C6/SsoLinkMintTest.php:257` stays green, extended with a body assertion |
| Arch | `AdminTenancySafetyArchTest:102` still green with the new controller | unchanged |
| Unit (fe) | Extended i18n structural guard | `frontend/tests/unit/i18n-interview-keys.spec.ts` |
| E2E | Operator recovers a failed participant; badge changes | `backoffice/tests/e2e/` |

Must stay green (per proposal): `Unit/C6/ParticipantTransitionExceptionTest`,
`Feature/C6/SsoExchange403Test:173`, `Feature/C7a/ParticipantStatusGuardTest:139,158,175`,
`Feature/C7a/InterviewStartTest:323,448`, `Feature/C8/InterviewStartCompositionTest:320-337`,
`Feature/Jobs/ScoreEvaluationJob*`, `Feature/C11/AdminLifecycleGateMatrixTest:86,126,149`.

---

## Delivery

`400-line budget risk: High` · `Chained PRs recommended: Yes` ·
`Decision needed before apply: Yes`

Feature Branch Chain off D0's base; PR1 → the feature branch, each later PR → the
previous PR's branch.

| PR | Scope | ~Lines | Standalone value |
|---|---|---|---|
| 1 | Refusal-reason split, both controllers, `reason` discriminator, spec delta | 150 | Operators stop being told a false story, even if nothing else lands |
| 2 | Transition edge, action, policy, route, controller, both guards, session reset + utterance delete, interim log, full-cycle test | 330 | The actual fix |
| 2a | *Split out only if PR2 exceeds 400*: D2b `$isFirst`/`started_at` | 30 | Independently valuable and testable |
| 3 | Backoffice panel + composable + i18n + E2E (needs PR2's regenerated `openapi.json`) | 150 | Operator affordance |
| 4 | Frontend copy + structural guard (`frontend` submodule, own chain) | 50 | Candidate honesty |

Rollback: reverse chain order; revert the transition-map edit **last** — with the
route gone the edge is unreachable. A recovered participant sits at `in_attesa`,
indistinguishable from a normal waiting participant.

---

## Resolved by inspection

- **`error_redirect_url`** (proposal Med risk): fires only when the frontend
  reaches `error`/`terminal`. After recovery the candidate no longer hits 403, so
  it does not re-trigger. If the candidate was already redirected away, the
  operator mints a fresh link — which now succeeds, because the minter sees
  `in_attesa`. No change needed.
- **`ProviderException` / `ProviderFailureClass` / the classification switch**:
  zero edits, per the sibling's seam contract.

## Open Questions (for the user, not blocking design)

- [ ] Does the calling system need a `progress` webhook when an assessment is
      re-opened? Current answer: no — no `evaluation` was ever delivered for a
      recoverable participant (D5 guard 1 guarantees it), so nothing to supersede.
- [ ] Is 409-refusal the permanent answer for scoring-stage failures, or should a
      superseding-delivery follow-up be scheduled?
- [ ] Legal/GDPR: is discarding a partial utterance set on operator confirmation
      acceptable without a retention record? (Ties to CLAUDE.md decision 2.)

---

## Assumptions for user review (adopted without confirmation — user asleep)

1. **D2 is a correction, not a preference.** Status-only recovery is broken
   (stranded `in_corso`, scoring never dispatched). Session reset is mandatory,
   not an enhancement. If this is rejected, the whole change must be re-scoped.
2. **Deleting the errored session's partial utterances is accepted data loss**,
   bounded to one operator-chosen competency, disclosed in the UI and reported in
   the response. The alternative (keeping them) degrades BARS scoring and behaves
   differently per provider.
3. **Resume, not restart**: already-answered competencies are never re-asked.
   This supersedes proposal assumption 4.
4. **Both refusals stay 409**; honesty lives in the message plus a new
   machine-readable `reason` field. No new status code.
5. **`recover` is the name** everywhere (ability, route, action, log, i18n) —
   the proposal's `/reopen` route is renamed for consistency.
6. **D2b changes one line of `InterviewController` beyond the docblock**
   (`$isFirst`). Judged in bounds of the sibling's seam contract, which protects
   `markParticipantFailed()`'s body and the classification switch. Task phase must
   confirm no existing test builds a participant with `started_at` set while
   `status = 'in_attesa'`.
7. **A second org-filter site** (`RecoverFailedParticipant`) is accepted rather
   than widening `AdminParticipantReader` into a write path. Pinned by a
   cross-tenant feature test.
8. **Interim logging only** — explicitly does not satisfy the admin-audit-log NFR.
9. **Idempotent double-recover returns 200, not 409**; only a *live* participant
   (`in_corso`+) returns 409 `not_failed`.
10. **Failure order is 403 → 404** for this write, inverse of the admin read path.
11. **PR3 is blocked on PR2's regenerated `openapi.json`** and a wrapper submodule
    pointer move — a real cross-repo ordering constraint, not just sequencing.
12. **This artifact exceeds the skill's 800-word budget**, deliberately: the
    orchestrator directed the budget into D2, and D2's finding invalidates the
    proposal's assumed approach.
