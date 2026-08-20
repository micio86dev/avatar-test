# Proposal: Participant Error Recovery

## Intent

A candidate who hits a provider failure at interview start is flipped to `errore`.
`errore` is terminal (`api/app/Models/Participant.php:115` — `'errore' => []`), so:

- `ParticipantStatusGuard.php:45` 403s every `/api/candidate/interview/*` route;
- `EntryLinkMinter.php:57-63` refuses a new entry link for the same `candidate_ref`;
- both mint controllers answer that refusal with
  `"Conflict: participant has already completed this assessment."`
  (`EntryLinkController.php:83-86`, `SsoLinkController.php:94-97`) — **factually false**
  for a crashed candidate.

Net effect, reproduced in production on 2026-08-19: a transient failure permanently
destroys a candidate, with no self-serve and no operator-serve path back, and the one
message an operator does get is a lie.

**What the sibling change already fixed — do not re-scope it.** `liveavatar-contract-alignment`
fixed the root-cause payload AND already reduced the blast radius: `handleProviderFailure()`
(`InterviewController.php:639-657`) now switches on `ProviderFailureClass`, and
**`Throttle` and `ClientError` no longer touch the participant at all** — only the session
errors (`:646`, `:652`). That is acceptance-tested at
`tests/Feature/C7a/InterviewStartTest.php:386` ("provider 4xx → 500; participant.status
UNCHANGED"). Assumption 2 of this change's brief is therefore **already shipped**; this
proposal only adds a regression guard for it, it does not re-implement it.

What is left, and what this change owns:

1. Genuine `Upstream` failures still mark `errore`, and `errore` has no way out — for
   anyone, ever, including every participant already stuck today.
2. The 409 refusal message still reports a crashed candidate as completed.
3. `frontend/i18n/locales/{it,en}.json` → `interview.error.body` still promises
   "Try again and you will resume where you left off", which becomes false the instant
   the server writes `errore`.

## Scope

### In Scope

| # | Deliverable |
|---|---|
| 1 | One new lifecycle edge: `'errore' => ['in_attesa']`. `errore` stays terminal for everyone except an explicit, authorized recovery. |
| 2 | `POST /api/participants/{id}/reopen` — operator-initiated recovery on `auth:api` + `TenantContext`, authorized by a new `ParticipantPolicy::recover` (admin + operator; viewer denied). |
| 3 | Webhook-contract guard: recovery is **refused (409)** when an `evaluation` `WebhookDelivery` row exists for the participant — i.e. when the calling system was already told the assessment ended. |
| 4 | Interim structured log on every recovery (actor, participant, org, previous status, reason, timestamp) via Laravel's logger. **Explicitly NOT the ratified audit trail.** |
| 5 | `EntryLinkRefusalReason::Terminal` split into `Completed` and `Failed`, with honest 409 messages in **both** mint controllers. The gate itself stays inside `EntryLinkMinter` (single-source requirement, `participant-sso` spec:980-1002). |
| 6 | Backoffice: recovery action on participant detail, disabled-with-reason when refused; `it` + `en` copy. |
| 7 | `frontend` — honest `interview.error.*` copy plus a structural i18n guard extending the D-F precedent (`frontend/tests/unit/i18n-interview-keys.spec.ts:82-105`) to the `error` state. |
| 8 | Regression test pinning that `ClientError`/`Throttle` never write the participant (locks in the sibling change's reduction). |

### Out of Scope

- **A sixth lifecycle status** (exploration option b). `in_attesa → in_corso → in_valutazione
  → completato | errore` is marked BINDING in `CLAUDE.md`. Recorded below as a deferred
  alternative needing the user's explicit ratification.
- **Recovery of scoring failures** (`ScoreEvaluationJob::failed()`, Writer 3). That writer
  emits `EvaluationFailed`, which `SendEvaluationWebhook` turns into a delivered
  `evaluation` webhook carrying `status: 'errore'`. Re-opening a participant the calling
  system was already told had ended is an **integration contract break**, and today's
  webhook pipeline has no superseding-delivery concept (dedupe is on `evaluation_id` /
  `participant-failed:{id}`). Deliverable 3 refuses that case explicitly rather than
  silently allowing it. Follow-up change required, gated on a webhook-contract decision.
- **The `ZeroCompetencies` invariant writer** (`ScoreEvaluationJob.php:483-486`) — a project
  config bug, not a candidate failure. Not recoverable by an operator.
- **Implementing `openspec/specs/audit-log/spec.md`.** Nothing of it exists (no package, no
  model). Deliverable 4 is an interim; the audit-log capability supersedes it.
- **Re-dispatching scoring** after a recovery, and any change to `ProviderFailureClass` or
  the classification switch — already shipped, not re-litigated here.

## Capabilities

### New Capabilities

None. A separate `participant-recovery` spec would put the lifecycle invariants in a second
document and let them drift from `participant-sso`.

### Modified Capabilities

- `participant-sso`: the "Participant Model Lifecycle Guard" requirement (spec.md:96-127)
  gains the `errore → in_attesa` edge and its authorization precondition; "M2M SSO-Link Mint"
  (spec.md:235-241) keeps its 409 status but gains a distinct refusal reason/message for
  `errore` vs `completato`; "Shared Entry Link Minting Logic" (spec.md:980-1002) is
  re-affirmed — disambiguation stays inside `EntryLinkMinter`.
- `admin-backoffice`: new operator recovery action, its RBAC row (`recover` — admin/operator),
  the refused-with-reason state, and the interim logging obligation.
- `interview-frontend`: the `error` terminal copy must not promise a recovery the domain
  cannot deliver, enforced structurally.

## Approach

### D1 — Additive edge, not a new node

The transition map is already enforced at runtime (`Participant::booted()` `updating` hook
→ `ParticipantTransitionException` → 422), and every real `errore` writer goes through
`$participant->save()`, so it fires for all of them. Adding `'errore' => ['in_attesa']` is a
one-line map edit against an enforcement mechanism that already exists. `errore → in_corso`
and `errore → in_valutazione` stay illegal, so the two tests that pin terminality
(`ParticipantTransitionsC7aTest.php:137,145`) keep passing unchanged.

Recovering to `in_attesa` — not `in_corso` — is deliberate: `in_attesa` is the only status
that both `ParticipantStatusGuard` and `EntryLinkMinter` already treat as mintable and
startable, so the recovery composes with the existing operator link flow with zero new
gate logic. The candidate restarts the interview.

### D2 — Recovery is a write, so it lives outside the read-only admin group

`api/routes/api.php:197-213` is documented as the read-only Admin Read API. The recovery
route is registered in its own `['auth:api', TenantContext::class]` group, mirroring how
`POST /api/entry-links` was placed adjacent to — not inside — that block.

**Arch constraint:** `tests/Arch/C11/AdminTenancySafetyArchTest.php:102-113` fails any literal
`Participant::` under `app/Http/Controllers/Api`. The recovery controller must resolve the
participant through `AdminParticipantReader` (org filter applied) and reference
`ParticipantPolicy::MODEL` for the ability check — the same escape hatch `EntryLinkController`
already uses.

### D3 — Refuse what we cannot honestly undo

`webhook_deliveries` carries `participant_id` and `event_type`. An existing `evaluation`
delivery is an exact, checkable proxy for "the calling system was already told this
assessment ended". Recovery refuses with 409 and a message that says so. This is what keeps
the out-of-scope boundary in deliverable 3 enforced in code, not just in prose.

### D4 — The seam is consumed, not changed

`InterviewController::markParticipantFailed()` (`:697-708`) was extracted verbatim by the
sibling change and handed to this one. This proposal **leaves its body unchanged**: an
`Upstream` failure is a genuine provider failure and `errore` is the right record of it —
what changes is that `errore` is no longer a one-way door. Expected edit to
`InterviewController.php`: the seam docblock only.

### D5 — Honest copy, enforced structurally

`interview.error.body` is rewritten to state that the interview can be resumed **only if**
the session is still active, and to direct the candidate to the recruitment team otherwise —
mirroring the D-F treatment of `session_expired`. A new structural assertion in
`i18n-interview-keys.spec.ts` forbids the unconditional resume promise in both locales.
This puts a small, self-contained slice of this change in the **`frontend` submodule**;
everything else is `api` + `backoffice`.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Models/Participant.php` | Modified | `'errore' => ['in_attesa']` + docblock |
| `api/app/Policies/ParticipantPolicy.php` | Modified | `recover` — admin/operator |
| `api/app/Http/Controllers/Api/ParticipantRecoveryController.php` | New | `POST /participants/{id}/reopen` |
| `api/routes/api.php` | Modified | New write route group |
| `api/app/Exceptions/Sso/EntryLinkRefusalReason.php` | Modified | `Terminal` → `Completed` + `Failed` |
| `api/app/Support/Sso/EntryLinkMinter.php` | Modified | Emit the matching reason (`:61-63`) |
| `api/app/Http/Controllers/{Api/EntryLinkController,M2m/SsoLinkController}.php` | Modified | Honest 409 bodies |
| `api/app/Http/Controllers/Candidate/InterviewController.php` | Modified | Seam docblock only |
| `backoffice/app/pages/participants/[id].vue`, composable, `i18n/locales/{it,en}.json` | Modified | Recovery action |
| `frontend/i18n/locales/{it,en}.json`, `tests/unit/i18n-interview-keys.spec.ts` | Modified | Honest copy + structural guard |
| `{api,frontend,backoffice}/openapi.json` | Modified | Three snapshots move together |

## Sequencing and collision boundary with `liveavatar-contract-alignment`

- **Branch from the sibling's tip, never from `develop`.** `develop` has neither
  `ProviderFailureClass`, the `ClientError` split, nor the `markParticipantFailed()` seam.
  Base this change on `feature/liveavatar-contract-alignment-pr6-tavus-concurrency` (or on
  `develop` only after that chain is merged).
- **`api/app/Exceptions/ProviderException.php`: zero edits.** The sibling deliberately kept
  `isRetryable()` as a derived accessor so this change sees no breaking signature (see its
  docblock at `:17-20`). Do not touch it.
- **`InterviewController.php`: docblock only** (D4). The classification switch is owned by
  the sibling change and is not re-shaped here.
- Real merge-conflict surface is therefore near zero; the ordering constraint is the actual
  dependency, not textual collision.

## Existing Pest tests that pin today's behaviour

Under strict TDD, each of these is either a red-first target or a must-stay-green invariant.

| Test | Effect |
|---|---|
| `tests/Unit/C7a/ParticipantTransitionsC7aTest.php:137,145` | Must stay green — `errore → in_corso` / `→ in_valutazione` remain illegal. Add a sibling test for the new legal `errore → in_attesa` edge. |
| `tests/Unit/C6/ParticipantTransitionExceptionTest.php` | Guard-behaviour baseline; add the recovery edge case here or in the C7a file, not both. |
| `tests/Unit/Sso/EntryLinkMinterTest.php:90-111` | Asserts `reason === Terminal` for `completato`. **Breaks on the enum split** — must be corrected to `Completed`, plus a new sibling test asserting `Failed` for `errore`. |
| `tests/Feature/C6/SsoLinkMintTest.php:257` | Asserts 409 only, no message. Stays green; extend with the corrected message assertion. |
| `tests/Feature/C6/SsoExchange403Test.php:173` | Unaffected — the exchange already returns a generic non-leaking 403. |
| `tests/Feature/C7a/ParticipantStatusGuardTest.php:139,158,175` | Must stay green — `errore` stays in `TERMINAL_STATUSES`; only an outbound edge is added. |
| `tests/Feature/C7a/InterviewStartTest.php:323,448` | Must stay green — `Upstream` 5xx still writes `errore`. |
| `tests/Feature/C7a/InterviewStartTest.php:386` | Must stay green — the `ClientError`/participant-untouched guarantee (deliverable 8 extends it to `Throttle`). |
| `tests/Feature/C8/InterviewStartCompositionTest.php:320-337` | Must stay green — same `Upstream` invariant. |
| `tests/Feature/Jobs/ScoreEvaluationJobFailedTest.php:57,79` | Must stay green — Writer 3 is out of scope and unchanged. |
| `tests/Feature/Jobs/ScoreEvaluationJobGuardTest.php:59` | Must stay green — an `errore` participant is still a scoring no-op. |
| `tests/Feature/C11/AdminLifecycleGateMatrixTest.php:86,126,149` | Must stay green — read gates are unchanged by recovery. |
| `tests/Arch/C11/AdminTenancySafetyArchTest.php:102` | Must stay green — constrains the new controller (D2). |

## Changed-line forecast and delivery

**Estimate ≈ 620–720 changed lines (additions + deletions), excluding generated
`openapi.json` churn.** Above the 400-line review budget → **chained PRs recommended**
(`feature-branch-chain`).

| PR | Slice | Est. lines | Boundary |
|---|---|---|---|
| 1 | Refusal-reason split + honest 409 in both mint controllers (+ test corrections) | ~150 | Ships alone; fixes the lie even if nothing else lands |
| 2 | Lifecycle edge + `ParticipantPolicy::recover` + `POST /reopen` + webhook-delivery guard + interim log | ~300 | The recovery capability; depends on PR 1 only for a clean enum |
| 3 | Backoffice recovery action + `it`/`en` copy | ~150 | Completes the operator loop; UI-only |
| 4 | `frontend` honest `error` copy + structural i18n guard | ~40 | **Different submodule** — separate PR by construction |

`400-line budget risk: High` · `Chained PRs recommended: Yes` · `Decision needed before apply: Yes`

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Recovering an `in_corso`-origin participant to `in_attesa` produces an inconsistent restart (partial transcript exists, `question_index` advanced) | **High** | Design phase MUST resolve: restart-from-zero vs. resume. Proposal assumes restart-from-zero with the prior transcript retained but ignored for scoring. Unresolved open question. |
| Operator recovers a participant whose `evaluation` webhook already shipped | Med | Refused in code (D3), not by convention |
| Interim structured log does not satisfy `CLAUDE.md`'s admin-audit-log NFR | **Certain** | Stated plainly, not hidden. Recovery is a privileged mutation with no ratified audit trail until the `audit-log` capability ships. This is accepted debt the user must see. |
| Enum rename breaks a caller outside the two controllers | Low | Closed enum, two call sites, arch-visible; compiler/test coverage catches it |
| `error_redirect_url` (archived `interview-error-redirect` change) fires for a participant who is later recovered | Low | Design phase to confirm no state is stripped by the redirect |
| Recovery abused to re-run assessments and inflate provider cost | Low | Admin/operator only, logged, and refused once an evaluation webhook exists |

## Rollback Plan

Route-level and cleanly separable, in reverse chain order.

- PR 4 / PR 3: copy and UI only — revert with no server effect.
- PR 2: remove the route, the controller, and the policy ability. **Revert the map edit last**
  — with the route gone, the `errore → in_attesa` edge is unreachable by any request path.
  A participant already recovered stays at `in_attesa` and is indistinguishable from a normal
  waiting participant; no data repair needed.
- PR 1: the enum split reverts independently; the mint gate itself is untouched by it.

No migrations. No schema change. No data backfill.

## Dependencies

- `liveavatar-contract-alignment` must be merged (or be the branch base) — see the sequencing
  section.
- Three `openapi.json` snapshots regenerated together (`task openapi:sync` needs
  `DB_CONNECTION=pgsql`).
- Tests run as `cd api && ./vendor/bin/pest <exact-file>` or full runs — never
  `php artisan test --filter`, which was observed fabricating passes in this repo.

## Success Criteria

- [ ] An operator recovers a candidate stuck at `errore` and that candidate completes an interview end to end.
- [ ] `errore → in_corso` and `errore → in_valutazione` still throw `ParticipantTransitionException`.
- [ ] Viewer gets 403 on `POST /reopen`; admin and operator succeed; cross-org gets 404.
- [ ] Recovery of a participant with a delivered `evaluation` webhook is refused with 409 and a message that names the real reason.
- [ ] A mint refused for `errore` never says "already completed", in either mint controller.
- [ ] Every recovery emits a structured log line with actor, participant, org, previous status, and reason.
- [ ] `interview.error.body` makes no unconditional resume promise in `it` or `en`, enforced by a structural test.
- [ ] `Throttle` and `ClientError` provider failures leave `participant.status` untouched, pinned by test.
- [ ] Full Pest suite green; three OpenAPI snapshots in sync.

## Proposal question round

Not asked interactively — the user is unavailable and execution mode is `automatic`.
Recorded for review before `sdd-spec`.

1. **Restart or resume?** For an `in_corso`-origin recovery, does the candidate redo the whole
   interview (assumed) or resume at `question_index`? This is a product decision about candidate
   experience and evidence quality, not a technical one.
2. **Does the calling system need to be told about a recovery?** Today nothing is sent. If a
   `progress`-type notification is expected when an assessment restarts, that is a webhook
   contract addition and belongs in this change, not after it.
3. **Is a 409-refused recovery acceptable as the permanent answer for scoring failures?** If not,
   the follow-up change (superseding webhook delivery) needs to be scheduled, not just named.

## Assumptions for user review

Every item below is a default adopted without the user's confirmation.

1. **No sixth lifecycle status.** `CLAUDE.md` marks the 5-status lifecycle BINDING. Exploration
   option (b) — a distinct non-terminal infrastructure-failure status — is the architecturally
   cleaner shape for the three-way writer split, and is **deferred pending explicit ratification**,
   not rejected.
2. **Brief assumption 2 is already satisfied** by `liveavatar-contract-alignment` and is therefore
   NOT re-scoped; this change only adds a regression guard. This is a correction to the launch
   brief, verified at `InterviewController.php:646,652` and `InterviewStartTest.php:386`.
3. **`Upstream` failures keep writing `errore`**; the seam body is unchanged. Recovery is the fix,
   not suppression.
4. **Recovery target is `in_attesa`**, and the recovered candidate **restarts from zero** (open
   question 1).
5. **Recovery is admin + operator, viewer denied** — consistent with `ParticipantPolicy::create`'s
   stated reasoning that starting an assessment is not a read.
6. **Scoring-failure recovery is out of scope and actively refused in code** (409), not merely
   undocumented.
7. **Audit logging is an interim structured log only.** It does **not** satisfy `CLAUDE.md`'s admin
   audit-log requirement. Accepted, visible debt.
8. **The 409 disambiguation keeps HTTP 409** for both `completato` and `errore`; only the reason and
   the message differ. Changing the status code would break `SsoLinkMintTest.php:257` and the M2M
   contract.
9. **Backoffice UI is in scope (PR 3).** Without it, "operator-serve recovery" means a hand-rolled
   HTTP call, which is not a product capability. Drop this slice first if the budget bites.
10. **A `frontend` submodule slice is in scope (PR 4)** — small, isolated, and separate by
    construction.
