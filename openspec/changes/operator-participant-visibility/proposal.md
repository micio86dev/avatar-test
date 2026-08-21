# Proposal: Operator Participant Visibility

## Intent

An operator reported that a participant stuck at `in_corso` showed no interview data, and
framed it as: *"either the data is not collected, or it is not shown."*

**It is collected. It is not shown.** Production participant 17 (`participants.status =
'in_corso'`), inspected 2026-08-20:

| Session | Session status | Utterances stored | From the candidate |
|---|---|---|---|
| INN | `completed` | **27** | **18** |
| CSF | `in_corso` | 2 | 0 |
| STG | `timeout` | 2 | 1 |

INN's 27 turns — a complete, speaker-attributed competency interview — are in the database
right now and the operator cannot reach a single one of them.

Why: `api/app/Support/Admin/LifecycleReadGate.php:59` requires lifecycle ≥ `in_valutazione`
for the Transcript scope, and `errore` is deliberately absent from `ORDERED_STATUSES`
(`:34`), so `array_search()` returns `false` and that status is denied outright. A
participant whose interview is in flight, or whose interview crashed, is exactly a
participant whose lifecycle has not reached the threshold — so the operator's window closes
precisely when they need it open.

This is therefore a **visibility defect, not a collection defect**, and that distinction is
the whole reason this change exists.

**Prior art — do NOT re-scope it.** The CSF/STG rows hold only resume-greeting lines
("Riprendiamo da dove eravamo rimasti, parlando di …") plus one "Sí." because a separate
defect let resume replace the provider session without harvesting the outgoing transcript.
That defect is **already fixed and shipped as api v0.26.4** and is out of scope here. It is
also the reason this change matters: with harvesting fixed, everything now being collected
is still invisible.

Alongside the gate, the same operator surface is missing five plainly answerable facts —
which project a candidate belongs to, the real lifecycle status, how far through the
interview they got, how long it took, and roughly what it cost.

## Scope

### In Scope

| # | Deliverable |
|---|---|
| 1 | **Transcript read gate loosened.** `GET /api/participants/{id}/transcript` (and its `/download` sibling, which shares `AdminParticipantReader::read()`) becomes readable from `in_corso` onward **and** for `errore`. `in_attesa` stays denied — there is nothing to read. |
| 2 | **Partial-transcript labelling** in the payload: an explicit machine-readable marker that the interview had not reached `in_valutazione` when read, so the backoffice cannot render partial evidence as final. |
| 3 | **Project column** on the participants list. Requires `Admin\ParticipantResource` to carry the project **name**, not just `project_id` (`ParticipantResource.php:53`). |
| 4 | **Real lifecycle status** surfaced on the detail as the interview status, across all five values including `errore` — not a completed/not-completed reduction. |
| 5 | **Session progress as `done / total`.** Today the detail renders a bare `timeline.session_count` (`backoffice/app/pages/participants/[id].vue:53`). The denominator already has one defined source: `count(project_competencies WHERE project_id)`, computed for the candidate at `InterviewController.php:416`. |
| 6 | **Total elapsed interview time** for the participant, aggregated from the per-session `duration_seconds` already returned by `SessionSummaryResource.php:28-30`. |
| 7 | **Estimated provider cost** for the whole interview, aggregated from the existing `SessionCostEstimator`, **labelled an estimate at every point of display**. |
| 8 | **Turn-by-turn transcript panel** in the backoffice, grouped by question and attributed by speaker, showing both what the avatar said and what the candidate answered. |
| 9 | The mirrored client-side gate `backoffice/app/utils/participant-lifecycle.ts:34` moved in lockstep with the server gate. |
| 10 | Tests per project policy: **Pest** (api), **Vitest** (backoffice), **Playwright E2E**. Enumeration belongs to the tasks phase. |

### Out of Scope

- **The resume/transcript-harvest defect.** Fixed in api v0.26.4. Referenced above as prior
  art; not re-opened, not re-proposed.
- **The evaluation read gate.** `Evaluation` scope stays at `completato`. A BARS score for
  an unfinished interview is not partial data, it is a wrong verdict.
- **`in_attesa` transcript reads.** Still `409`. Fail-closed stays fail-closed where the
  answer is genuinely "nothing exists".
- **LLM/token cost.** `SessionCostEstimator`'s docblock (`:20-22`) states that avatar-minute
  cost and `ai_requests` token cost are different vendors on different meters and must not
  be summed into one owner-less total. That reasoning is honoured, not overturned.
- **Persisting any aggregate.** No new columns, no backfill, no migration.
- **Candidate-facing exposure.** Nothing here reaches the `frontend` submodule. The
  proctoring/review surface stays backoffice-only, pinned by
  `tests/Arch/C11/CandidateCannotReadProctoringArchTest.php`.
- **UI visual design.** `DESIGN.md` is authoritative; the design phase consults it.
- **Per-question audio playback**, retention/purge changes, and the M2M participant
  contract — all untouched.

## Capabilities

### New Capabilities

None. Both surfaces already have owning specs; a third document would let the gate's
thresholds drift across two places.

### Modified Capabilities

- `admin-read-api`: the **Lifecycle Read-Gate (Fail-Closed)** requirement
  (`spec.md:64-107`) — its prose, its status matrix (`:80-87`, the `in_corso` and `errore`
  Transcript rows flip to `200`), and the scenario at `:89-94` which currently asserts the
  exact denial being removed. Plus new Summary-scope aggregate fields (progress
  denominator, elapsed time, cost estimate, project name).
- `admin-backoffice`: participants-list project column, detail interview-status /
  progress / elapsed / cost panels, the turn-by-turn transcript panel, and the partial-data
  labelling obligation.

## Approach

### D1 — The gate is the entire fix for deliverables 1, 8

`AdminTranscriptSerializer` (`api/app/Services/Admin/AdminTranscriptSerializer.php:45-67`)
**already** emits exactly the payload the operator asked for: sessions ordered by
`question_index`, each carrying `{session_id, competency_code, question_index, utterances:
[{speaker, text, ts}]}`, utterances ordered by `ts` then `id`, with **no speaker filter** —
avatar turns and candidate turns both. There is no new assembly logic to write and no new
endpoint. One threshold change in `LifecycleReadGate` releases all 27 of INN's turns.

### D2 — Label the partial data; do not hide it

**This is the one decision in this change that carries real risk, and it is a loosening.**
The gate is not accidental: it encodes that a mid-interview transcript is *incomplete*, and
an incomplete transcript read as a complete one misleads. That concern is legitimate and
survives this change.

The answer is that the gate applies the wrong instrument to it. This surface is
`auth:api` + `TenantContext` + RBAC and org-filtered through `AdminParticipantReader`; the
reader is an authenticated operator of the owning organization, not the candidate and not
the public. For that audience the correct control over incomplete evidence is **disclosure**
— mark it partial, in the payload and in the UI — not concealment. Concealment produced the
present failure mode, in which an operator concluded the platform had lost data it in fact
held.

The gate's fail-closed *architecture* is untouched: no `?? true` fallback appears, an
unrecognized status still denies for every scope, and `in_attesa` and the Evaluation
threshold are unchanged. Only two threshold rows move.

### D3 — `errore` becomes transcript-readable, explicitly

Yes. `errore` gains Transcript access, not merely `in_corso`.

An errored interview is precisely the case where an operator most needs the transcript: it
is the only evidence of what the candidate managed to say before the failure, it is the
input to deciding whether recovery (`POST /api/participants/{id}/recover`, shipped by
`participant-error-recovery`) is worth offering, and today it is the *most* strongly denied
status of the five. Leaving `errore` blind would fix the reported symptom and leave the
worst case untouched.

Mechanically, `errore` cannot simply be appended to `ORDERED_STATUSES` — that list encodes
*progression*, and `errore` is terminal-failed, not "further along" (class docblock,
`:17-22`). The design phase owns the shape; the requirement is that the ordering semantics
stay honest rather than being bent to fit.

### D4 — Aggregates are derived at read time, never persisted

Following the precedent `SessionCostEstimator` set explicitly (`:11-15`): a figure stored
under an old rate becomes a number nobody can reproduce. Elapsed time, progress denominator,
and cost aggregate are all computed per request from rows that already exist. No migration.

### D5 — Cost is an estimate and says so

`api/config/interview.php:154-179` already carries the `rates` block, added for this exact
C11 review surface, and its comment is unambiguous: neither HeyGen nor Tavus exposes a
per-session billed amount, so *"an operator who reads it as an invoice line will reconcile
it against a real bill and find a discrepancy that was never a defect."* The participant
total is the sum of the per-session estimates. `SessionCostEstimator::estimate()` returns
`null` for an unfinished session or an unrecognised provider (`:33-60`) — those sessions are
excluded from the sum, and the fact that they were excluded is disclosed rather than
silently absorbed into a confident-looking total.

### D6 — The project column costs a join, so guard it

`ParticipantResource` carries `project_id` only; the list is server-paginated
(`admin-backoffice` spec:215-219). Adding a project name means eager-loading the relation on
the index query. `ParticipantDetailResource.php:65` already resolves the project via
`firstOrFail()` for the detail, so only the index needs work — with an N+1 guard, since
this is a per-row field on a paginated list.

### D7 — The two gates move together or the UI lies

`backoffice/app/utils/participant-lifecycle.ts` is a client-side mirror of the server gate,
with a Vitest suite pinning `in_corso → false` and `errore → false`
(`tests/unit/utils/participant-lifecycle.spec.ts:30,42`). If the server opens and the mirror
does not, the backoffice hides data the API now returns. Under strict TDD those two
assertions are red-first targets, not collateral damage.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Support/Admin/LifecycleReadGate.php` | Modified | Transcript threshold + `errore` (D2, D3) |
| `api/app/Services/Admin/AdminTranscriptSerializer.php` | Modified | Partial marker only — turn assembly unchanged (D1) |
| `api/app/Http/Resources/Admin/TranscriptResource.php` | Modified | Partial marker in the contract |
| `api/app/Http/Resources/Admin/ParticipantResource.php` | Modified | Project name for the list column (D6) |
| `api/app/Http/Resources/Admin/ParticipantDetailResource.php` | Modified | Progress `done/total`, elapsed, cost estimate |
| `api/app/Http/Controllers/Api/AdminParticipantController.php` | Modified | Eager-load + aggregate wiring |
| `api/app/Services/Proctoring/SessionCostEstimator.php` | Consumed | Participant-level aggregation (D5); estimator body unchanged |
| `backoffice/app/components/organisms/CandidateTable.vue` | Modified | Project column (`:35-38` — 4 headers today) |
| `backoffice/app/pages/participants/[id].vue` | Modified | Status, `done/total` (`:53`), elapsed, cost, transcript panel |
| `backoffice/app/utils/participant-lifecycle.ts` | Modified | Mirrored gate (D7) |
| `backoffice/app/components/**` (transcript panel) | New | Turn-by-turn, speaker-attributed, partial-labelled |
| `backoffice/i18n/locales/{it,en}.json` | Modified | New labels incl. the estimate disclaimer |
| `{api,frontend,backoffice}/openapi.json` | Modified | Three snapshots move together |

Both `api` and `backoffice` are git submodules — every slice is a submodule PR plus a
wrapper pointer bump.

## Existing tests that pin today's behaviour

Under strict TDD each is either a red-first target or a must-stay-green invariant.

| Test | Effect |
|---|---|
| `api` Lifecycle gate matrix (`tests/Feature/C11/AdminLifecycleGateMatrixTest.php`) | **Red-first.** Asserts the `in_corso`/`errore` Transcript denials being removed. |
| `api` Evaluation-scope rows of the same matrix | Must stay green — Evaluation threshold unchanged. |
| `api` `in_attesa` Transcript denial | Must stay green — still `409`. |
| `api` Unrecognized-status fail-closed scenario (`spec.md:109`) | Must stay green — the architecture is not being loosened, only two rows. |
| `api` `tests/Arch/C11/AdminTenancySafetyArchTest.php` | Must stay green — constrains the eager-load and aggregate queries. |
| `api` `tests/Arch/C11/CandidateCannotReadProctoringArchTest.php` | Must stay green — nothing reaches the candidate. |
| `backoffice` `tests/unit/utils/participant-lifecycle.spec.ts:30,42` | **Red-first.** `in_corso` and `errore` flip to `true` for `'transcript'` only. |
| `backoffice` same file, `'evaluation'` cases (`:48-60`) | Must stay green. |

## Changed-line forecast and delivery

**Estimate ≈ 1,000–1,200 changed lines** across two submodules, excluding generated
`openapi.json` churn. Well above the review budget → **chained PRs required**.

| PR | Slice | Repo | Est. | Boundary |
|---|---|---|---|---|
| 1 | Read gate + partial marker (D1–D3) | `api` | ~250 | Ships alone; unblocks INN's 27 turns even if nothing else lands |
| 2 | Participant aggregates: project name, `done/total`, elapsed, cost (D4–D6) | `api` | ~250 | Pure additive read fields |
| 3 | List project column + detail status/progress/elapsed/cost panels | `backoffice` | ~300 | Depends on PR 2 |
| 4 | Mirrored gate + turn-by-turn transcript panel + E2E (D7) | `backoffice` | ~350 | Depends on PR 1; closes the operator's original report |

`400-line budget risk: High` · `Chained PRs recommended: Yes` ·
`Decision needed before apply: Yes`

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| A partial transcript is read as a finished one and drives a hiring judgement | **Med** | D2 — explicit partial marker in the payload *and* a visible UI label; the Evaluation gate is untouched, so no score accompanies it |
| Loosening a fail-closed gate weakens it structurally | Low | Only two matrix rows move. No `?? true`, no default-allow, `in_attesa` and Evaluation unchanged, fail-closed scenario stays green |
| `errore` forced into `ORDERED_STATUSES` corrupts the ordering semantics | Med | D3 — named as a design-phase obligation; `errore` is terminal-failed, not "further along" |
| Cost estimate reconciled against a real provider invoice | **Med** | D5 — labelled an estimate at every display point, per the config comment's own instruction; excluded sessions disclosed |
| N+1 on the paginated participants list from the project join | Med | D6 — eager-load with an explicit query-count assertion |
| Server gate and backoffice mirror drift | Med | D7 — both move in the same change; mirror assertions are red-first, not incidental |
| Cross-tenant leak through new aggregate queries | Low | All reads stay behind `AdminParticipantReader` (org filter → RBAC → gate); arch test enforces it |
| Progress denominator disagrees with the candidate-side number | Low | Single source: `count(project_competencies)`, the same one `InterviewController.php:416` already uses |

## Rollback Plan

Revert in reverse chain order; each slice is independently revertible.

- PR 4 / PR 3: `backoffice` only. Reverting restores the previous UI with no server effect.
  Reverting PR 4 alone re-hides transcripts the API still serves — safe, just less useful.
- PR 2: additive read fields; removing them cannot break stored state.
- PR 1: restore the two matrix rows in `LifecycleReadGate`. The gate returns to denying
  `in_corso`/`errore` transcripts on the next request.

**No migrations, no schema change, no data backfill, nothing persisted.** Every field this
change adds is derived at read time (D4), so rollback is code-only and instantaneous.

## Dependencies

- `participant-error-recovery` (shipped) — the recovery action on participant detail is the
  consumer of D3's errored-participant transcript.
- api **v0.26.4** (shipped) — the resume/transcript-harvest fix. Without it the transcripts
  this change reveals would keep being destroyed on resume.
- Three `openapi.json` snapshots regenerated together (`task openapi:sync`, needs
  `DB_CONNECTION=pgsql`).
- Pest run as `cd api && ./vendor/bin/pest <exact-file>` or a full run — never
  `php artisan test --filter`, observed fabricating passes in this repo.

## Success Criteria

- [ ] An operator opens production participant 17 and reads **all 27 INN turns**, avatar and
      candidate attributed, grouped by question — the exact data the original report
      believed was never collected.
- [ ] The transcript is visibly and machine-readably marked **partial** while the
      participant is below `in_valutazione`.
- [ ] A participant at `errore` returns `200` on transcript read and download.
- [ ] `in_attesa` still returns `409 lifecycle_not_ready`; evaluation still returns `409`
      below `completato`; an unrecognized status still denies for every scope.
- [ ] The participants list shows a project column and the paginated query issues no N+1.
- [ ] The detail shows the real lifecycle status across all five values, `done / total`
      sessions, total elapsed time, and a cost figure **labelled an estimate**.
- [ ] A cross-org participant id still `404`s on every new and modified read.
- [ ] Full Pest suite green; backoffice Vitest green with the mirror assertions corrected;
      Playwright E2E covers the partial-transcript operator path; three OpenAPI snapshots in
      sync.

## Proposal question round

Not asked interactively — recorded for review before `sdd-spec`.

1. **Is a partial transcript ever allowed to inform a hiring decision, or is it strictly
   diagnostic?** The answer sets how loud the partial label must be, and whether the
   backoffice should actively discourage exporting it. This is a product/compliance call,
   not a technical one.
2. **Should the cost estimate be visible to every authorized role, or admin-only?** It is
   commercially sensitive internal data and today no BEAI read surface is role-restricted
   below the existing viewer/operator/admin RBAC.
3. **When some sessions yield no cost estimate, is a partial total acceptable, or should the
   whole figure be suppressed?** D5 assumes "partial total, exclusion disclosed".
4. **Does `done / total` count competencies or questions?** The proposal assumes competencies
   (`project_competencies`), matching the candidate-side progress number. If operators think
   in questions, the two surfaces would disagree.

## Assumptions for user review

Every item below is a default adopted without the user's confirmation.

1. **`in_corso` and `errore` become transcript-readable; `in_attesa` does not.**
2. **The Evaluation gate is untouched at `completato`** — no partial scores, ever.
3. **Partial data is labelled, not hidden** (D2). This is the change's central and riskiest
   judgement and it is stated plainly rather than assumed away.
4. **Nothing is persisted**; every new field is derived per request (D4).
5. **Provider cost only** — LLM/token cost is deliberately not folded in (D5).
6. **The turn-by-turn payload needs no new assembly logic** — `AdminTranscriptSerializer`
   already emits speaker-attributed turns grouped by question. Verified at `:45-67`.
7. **The progress denominator is `count(project_competencies)`**, the same source the
   candidate-side progress already uses (question 4).
8. **No `frontend` submodule work.** This is an operator surface end to end.
9. **The download endpoint follows the read endpoint** — it shares
   `AdminParticipantReader::read()`, so loosening the gate opens both. Intended, not
   incidental.
10. **No UI visual design is proposed here.** `DESIGN.md` is authoritative and the design
    phase consults it.
