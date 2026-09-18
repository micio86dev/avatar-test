# Proposal: Post-hoc Audit of Persisted Indicator Scores (TypeSafe / Jev)

## Intent

A BEAI evaluation is a black box with a confident face. `ScoreEvaluationJob` asks one LLM,
per competency, for a score, an explanation, and verbatim excerpts; `IndicatorValidator` and
`ExcerptValidator` check that the score is in `{1,2,3,4,5,-1}` and that each excerpt is a real
substring of the transcript. Both are **shape** checks. Neither asks the only question an
operator actually cares about:

> *Does the evidence quoted here actually support the score that was given?*

An indicator can carry a legal score, a fluent explanation, and three genuinely-verbatim
excerpts that say nothing about the behaviour being rated — and today that renders in the
backoffice identically to a well-founded score. The `ScoreChip` encodes the number; there is no
element anywhere in `backoffice/` that encodes *review status*. An operator reading a report has
no way to tell "the model was on solid ground here" from "the model reached".

This change adds a **post-hoc, advisory, never-blocking** audit layer: after an `IndicatorScore`
is persisted, TypeSafe's Jev is asked whether the persisted excerpt and explanation genuinely
support the persisted score, and a low-support judgment surfaces as a flag on the existing
`behaviors[]` read surface. It is the "verify and escalate" pattern: code owns the workflow, a
System One model supplies the semantic judgment, and a human decides what to do about it.

Success = an operator opens an evaluation, asks for an audit, and gets back a per-indicator
"supported / weakly supported / could not check" signal alongside scores that already exist —
with the cost of having asked recorded to the cent, and **no persisted score changed by any of it**.

---

## AD-1 — v1 is **operator-triggered, per evaluation**. No automatic trigger ships.

**Choice.** The only way an audit runs in v1 is an authenticated admin explicitly asking for one:
`POST /api/participants/{id}/evaluation/audit`, which dispatches a queued `AuditEvaluationJob`.
No listener is registered on `EvaluationCompleted`. Nothing audits itself.

**Why not (a), event-driven behind a `scoring.audit.enabled` kill-switch shipped OFF.** This was
the exploration's recommendation and it is the wrong shape for the specific unknown we have.
A default-off boolean does not de-risk an unquantified cost; it *defers the same unbounded
commitment to a single flip*. There is no intermediate state between "off" and "every completed
evaluation in every tenant, forever". The first day anyone turns it on is the first day anyone
learns what it costs, and by then it is charging production. An unpriced feature whose only
control is a platform-wide boolean is not de-risked — it is loaded.

**Why not (b), default-on.** Explicitly refused. The spike that validated Jev's judgment quality
measured **one indicator, in isolation** (~1175 in / 68 out tokens, 3 Noul questions). A full
evaluation is 14–18 competencies × up to 3 indicators each, and shared-instruction overhead
amortizes differently in a batch, so that number cannot be multiplied. Shipping default-on means
committing the platform's external-AI spend to a figure nobody has measured.

**Why operator-triggered is the right first increment, not a timid one:**

1. **It produces the missing measurement, in production, attributably.** Every run writes its own
   token counts, estimated cost, and latency (AD-3). After N real audits the economics question
   is answered with production data across real roles and real transcripts — which is strictly
   better evidence than a throwaway spike, and it is evidence we get *while delivering value*
   rather than instead of it.
2. **The cost is paid exactly where the value lands.** The consumer of an advisory flag is a human
   reading a report. An audit on an evaluation nobody opens has produced a row and nothing else.
3. **It is not a new architectural shape.** `POST /api/participants/{id}/recover`
   (`ParticipantRecoveryController`) is already an admin-triggered, per-participant, queued
   operator action. This is the second instance, not the first.
4. **It forecloses nothing.** The trigger-agnostic unit is `AuditEvaluationJob`. A v2 listener on
   `EvaluationCompleted` — auto-discovered, `try/catch(Throwable)`-wrapped exactly like
   `SendEvaluationWebhook` — dispatches *the same job*. v2 is a listener class and a config flag,
   not a redesign.

**`config('scoring.audit')` still ships, and `enabled` defaults `true`** — mirroring
`truncation_retry`'s block shape, with a `tests/Unit/Config/` test pinning the shipped defaults
the way `TruncationRetryConfigTest` does. This is not a contradiction: in v1 "enabled" means *an
operator may ask*, never *the platform spends*. It exists so that a TypeSafe incident can be shut
out without a code deploy, and so v2's automatic arm has a switch already wired and already tested.

**Explicit gate on v2, stated so nobody rediscovers it.** *A batched multi-indicator cost and
latency measurement — every indicator of one real competency in one Jev request, following
`PromptBuilder`'s own batching shape — is a **prerequisite** before any automatic or default-on
trigger is proposed.* v1's accumulated `indicator_score_audit_runs` rows are the intended source
of that measurement: **no fewer than 20 real audit runs spanning at least two roles**, with
recorded per-run cost and latency, before v2 is written. Until then, "on by default" is not a
scope decision anyone is entitled to make.

## AD-2 — A dedicated tenant-scoped table. **`ai_requests` is not reused, and not extended.**

**Choice.** Two new tables, both `TenantModel`, both append-only. `ai_requests` is **diff-free**.

**Why not a `provider = 'typesafe'` discriminator on `ai_requests`.** Four reasons, each sufficient:

1. **The grain is wrong and cannot be fixed.** `ai_requests` carries `competency_code` and no
   indicator identity whatsoever. An audit is inherently *per indicator*. There is no column to
   put the answer in, and adding one changes the meaning of every existing row.
2. **Most of its columns are Anthropic-completion-shaped and would be permanently NULL.**
   `finish_reason`, `response_fenced`, `response_sha256`, `response_bytes` describe a text
   completion. Jev returns typed probabilities. `prompt_version` is the *scoring prompt's* semver
   (`3.1.0`) — a value that means nothing on an audit row and actively lies if copied.
3. **It would poison the dashboard's own anomaly signal.** `AiRequestCostEstimator` computes cost
   at write time from `config('scoring.cost_rates_usd_per_million')`, keyed by exact Anthropic
   model ids, and `config/scoring.php` states in terms: *"An unknown model yields 0.0 … A
   zero-cost row is visible in the dashboard as the anomaly it is."* Every TypeSafe row would be
   a zero-cost row. The one signal that catches a mispriced model would start firing constantly
   and be learned to be ignored.
4. **`DashboardController` aggregates `ai_requests` into a scoring-cost metric.** Folding a second
   vendor's meter into it repeats an error this codebase has already ratified refusing, verbatim
   at `SessionCostEstimator.php:20-22`: *"the two are different vendors on different meters. One
   total would be a number with no owner."*

**Two tables, not one, because judgment and cost have different grains:**

| Table | Grain | Holds |
|---|---|---|
| `indicator_score_audit_runs` | one row per operator invocation over one evaluation | status, counts (`indicators_total` / `judged` / `skipped` / `unavailable`), aggregate tokens, `estimated_cost_usd`, `latency_ms`, `judge_model_version`, `audit_prompt_version`, `failure_reason` |
| `indicator_score_audits` | one row per **indicator** in that run | FK → `indicator_scores` and → the run, `status`, `support_probability`, `skip_reason` |

A single table would force per-call cost onto per-indicator rows, which either multiply-counts it
or leaves it on an arbitrary "first" row. Getting cost arithmetic wrong defeats AD-1's entire
purpose, since the cost row *is* the business case for v2.

Both tables extend `TenantModel` (`organization_id` excluded from `$fillable`, stamped by
`TenantScoped::creating`), satisfying the arch test that every model carrying `organization_id`
does so. Both are **append-only** (`$timestamps = false`, `created_at` only), arch-tested exactly
like `AiRequestAppendOnlyArchTest`. Re-auditing creates a **new run**; nothing is ever updated.
The read surface shows the latest run, and the history survives — which matters because the
judgment is advisory and a later judge version may legitimately disagree with an earlier one.

`indicator_score_audits.indicator_score_id` is `cascadeOnDelete`. **The audit must not outlive
the indicator it judges**: a retention purge that removes an indicator must take its audit with
it, and a dangling audit row is unreadable anyway.

## AD-3 — A failed or malformed judgment writes an **explicit degraded row**, never silent absence.

**Choice.** Every indicator the run covers gets a row, always. `indicator_score_audits.status` is
an enum — `judged`, `unavailable`, `malformed`, `skipped` — under a DB CHECK expressing the
equivalence: **a `judged` row MUST carry a non-null `support_probability` and a null
`skip_reason`; every other status MUST carry a null probability and a non-null reason.** This is
the identical shape as `indicator_scores_unassessable_reason_check`
(`(score = -1) = (unassessable_reason IS NOT NULL)`), which exists for the identical reason.

At the run level, `status ∈ {completed, partial, failed}` with a `failure_reason`, so a TypeSafe
outage is a *recorded* outcome and not an absence.

**Why not "no row when the judge is unavailable".** Because absence is ambiguous and the UI would
resolve the ambiguity in the most dangerous direction. "No flag" and "could not check" would
render the same, and an operator reads an unflagged indicator as *audited and fine*. A confident
absence of a warning is worse than a visible refusal to answer. This codebase already made this
call twice — `unassessable_reason` is nullable-but-CHECK-paired rather than inferred from silence,
and `ai_requests` writes a row for a **failed** LLM call (`success`, `failure_reason`) rather than
losing the record of a call that was actually made.

Consistent with that, the audit **never fails the request that triggered it and never touches
scoring**. `AuditEvaluationJob` catches `Throwable` per competency call, records the degraded rows,
and completes. A third external AI dependency going down must be visible in a status column, not
in an exception trace.

## AD-4 — Indicators with no evidence are **out of judgment scope**, and are recorded as `skipped`.

**Choice.** The audit's scope rule keys on **evidence presence, not score value**: an
`IndicatorScore` whose `excerpts` is `[]` is not sent to Jev. It still gets a row, with
`status = 'skipped'` and a `skip_reason` distinguishing the two ways it can happen:

| Case | `skip_reason` | Meaning |
|---|---|---|
| `score = -1` (⟺ `unassessable_reason` is set, by DB CHECK) | `unassessable_by_construction` | The scorer asserted there was no assessable evidence, and `PromptBuilder` instructs an empty `excerpts` array in that case. There is nothing to check. |
| `score ∈ {1..5}` with `excerpts = []` | `assessed_without_excerpts` | A scored indicator citing nothing. Distinct reason code because this is a **data anomaly worth seeing**, not a normal state. |

**Why -1 rows are excluded from judgment.** "Does the evidence support the score" over zero
evidence is not a hard version of the same question — it is a *different* question: *"was the
scorer right to give up?"* Answering it requires reading the transcript, which makes the audit a
second independent scoring pass. That was ruled out in exploration and stays ruled out: it would
double the platform's exposure to candidate speech, reopen the GDPR surface, and produce a second
opinion on a score the first pass already owns.

**Why they are not simply absent.** The run's coverage must reconcile: `indicators_total =
judged + skipped + unavailable`, asserted by test. An operator must be able to see *"12 judged,
3 skipped — no evidence to check"* rather than wonder why three indicators are missing.

**Named follow-up, not smuggled in:** auditing the *decision to score -1* — "was this really
unassessable?" — is a genuinely different capability needing transcript access. It is listed under
Out of Scope so it is proposed deliberately or not at all.

## AD-5 — A new `AuditJudge` contract. `LLMProvider` is **not** reused.

**Choice.** `App\Contracts\AuditJudge` with its own typed DTO (per-indicator support probability),
implemented by `App\Services\Audit\TypesafeJevJudge` over Laravel's `Http` facade, bound in
`AppServiceProvider` beside `LLMProvider`, with `App\Testing\FakeAuditJudge` as the test binding.

**Why not force it behind `LLMProvider`.** `complete(string $prompt, array $options): LLMResponse`
is a one-shot **text completion** contract — content, model, tokens, `finishReason`, `truncated`.
Jev returns typed judgments over several parallel questions and generates no text. Squeezing it
in means serializing structured answers into a string to immediately re-parse them, and inheriting
`truncated` / `finishReason` semantics that have no referent. The abstraction would be lossy in
the direction that loses the actual answer.

**No SDK, no new D25 pin.** This follows `AnthropicLLMProvider`'s stated precedent verbatim —
raw `Http` client, own contract, own prod/fake binding. The Dependency Resolution Policy is not
triggered because no dependency is added.

**Strict TDD consequence, load-bearing:** `FakeAuditJudge` is the **default test binding**, so no
ordinary test can reach the live TypeSafe API — the `FakeLLMProvider` arrangement, for the same
reason. Real-API coverage belongs in the existing `--group ai` / `workflow_dispatch` lane, subject
to the dependency caveat below.

## AD-6 — Jev sees only what was persisted. The transcript is never read.

**Choice.** The state sent to Jev is exactly `indicator_text`, `score`, `explanation`, and
`excerpts` from the persisted `IndicatorScore` row, batched per competency to mirror
`PromptBuilder`'s own batching shape. **No transcript. No participant identity. No email.**

This is the boundary that keeps the audit from becoming a second scoring pass, and it is what
makes "advisory only" structurally true rather than a promise: with only the persisted verdict and
its own cited evidence in hand, the judge *cannot* produce a replacement score, because it has
never seen the behaviour.

The audit row itself stores a **probability and a machine reason code — never free text, never a
copy of an excerpt**. An audit row therefore carries no personal data of its own, and the
personal data it points at is purged by the existing mechanism through AD-2's cascade.

**Stated, not hidden:** the excerpts *are* verbatim candidate speech, and sending them to TypeSafe
makes TypeSafe a **new sub-processor of candidate personal data**. That is a data-controller
decision, it is exactly the kind of thing ruling 2's pending GDPR sign-off must name, and this
proposal does not decide it. See Open Decisions.

## AD-7 — The flag is read-only and additive. No persisted score is ever changed by an audit.

**Choice.** `AdminEvaluationSerializer::serializeCompetencyResult()` gains one `audit` key on each
`behaviors[]` entry. That method is the **single** place both the full report and the session-review
view are shaped — its own docblock states the two "must never disagree" — so the flag lands on both
surfaces from one implementation, or on neither.

`ScoreEvaluationJob`, `MeanCalculator`, `AssessableFractionReliability`, `CompletionGate`,
`EvaluationParser`, `IndicatorValidator` and `ExcerptValidator` are **diff-free**. No audit result
feeds any scoring formula, mirroring the arch-tested rule that already forbids the scoring
formulas from reading `unassessable_reason` (D9): the audit is metadata about a verdict, not an
input to it. An arch test extends that ban to the audit models.

**The `evaluation` webhook payload is deliberately unchanged.** `EvaluationPayloadAssembler` is
diff-free. The webhook is a contract with an external system that has no idea what an audit is,
the signal is advisory, and v1 has not yet earned the right to add a field to a shipped integration
surface. Listed under Out of Scope so it is a decision, not an omission.

---

## Scope

### In Scope

| # | Deliverable | PR | Repo |
|---|---|---|---|
| 1 | `App\Contracts\AuditJudge` + DTO, `TypesafeJevJudge` (raw `Http`), `FakeAuditJudge`, `AppServiceProvider` binding, `config/scoring.php` `audit` block + shipped-defaults config test (AD-1, AD-5) | P1 | `api` |
| 2 | `indicator_score_audit_runs` + `indicator_score_audits` migrations, CHECK constraints, tenant models, factories, append-only + tenancy + no-scoring-read arch tests (AD-2, AD-3) | P2 | `api` |
| 3 | `AuditEvaluationJob` — per-competency batching, skip rules, per-call `Throwable` isolation, degraded-row writes, coverage reconciliation, cost/latency recording (AD-3, AD-4, AD-6) | P3 | `api` |
| 4 | `POST /api/participants/{id}/evaluation/audit` — admin-only policy, throttled, 409 on a run already in flight; `audit_log` event `evaluation.audit_requested` | P4 | `api` |
| 5 | `AdminEvaluationSerializer::serializeCompetencyResult()` gains `audit`; `EvaluationResource` passthrough; OpenAPI re-export (AD-7) | P5 | `api` |
| 6 | `EvaluationBehavior` type extension, `useEvaluationReport` composable, net-new flag element on `IndicatorEvidence.vue`, run-trigger + run-status UI, `en`/`it` i18n authored not machine-translated | P6 | `backoffice` |

### Out of Scope — explicit non-goals

- **Any automatic trigger.** No `EvaluationCompleted` listener, no scheduled sweep. v2, gated by
  AD-1's measurement requirement.
- **Any change to what `ScoreEvaluationJob` decides.** No auto-correction, no re-score, no
  suppression of a flagged score. The audit cannot write to `indicator_scores`.
- **Transcript access by the audit** (AD-6), and therefore **auditing the -1 decision itself**
  (AD-4) — a different capability, proposed separately or not at all.
- **Reusing or extending `ai_requests`** (AD-2). It stays diff-free, and audit cost is a separate
  meter never summed into the scoring-cost dashboard metric.
- **The `evaluation` webhook payload** (AD-7). `EvaluationPayloadAssembler` diff-free.
- **Per-organization or per-project audit toggles.** v1 has one platform config flag and a human.
  A DB-backed tenant toggle is a schema decision that should follow the cost data, not precede it.
- **Live-conversation integration.** C7/C8, `InterviewController`, the providers and
  `SystemPromptComposer` are untouched. Jev judges persisted rows, never a live turn.
- **Retry semantics** (open ruling 4). An audit run is not a scoring retry and does not interact
  with the one-retry rule.
- **Any new dependency.** Raw `Http`, no SDK, no D25 catalog change.

## Capabilities

### New Capabilities

- `scoring-audit`: the audit judge contract and its TypeSafe binding; what state is and is not
  sent to the judge; the run/indicator two-grain record and its append-only invariants; the
  `judged | unavailable | malformed | skipped` status model and its CHECK equivalence; the
  evidence-presence scope rule; coverage reconciliation; the operator-triggered entry point and
  its authorization, throttling and in-flight refusal; and the standing invariant that no audit
  result may influence any scoring value.

### Modified Capabilities

- `admin-read-api`: each `behaviors[]` entry gains an `audit` object (status, support probability,
  reason code) plus a competency-level and evaluation-level run summary, emitted from the single
  `serializeCompetencyResult()` shaper so the full report and the session-review view cannot
  disagree; an un-audited evaluation renders an explicit "never audited" state, never a
  missing key.
- `admin-backoffice`: net-new per-indicator review-status affordance — `ScoreChip` keeps encoding
  score only — plus an operator trigger and run status, `en`/`it`.
- `observability`: audit token/cost/latency is recorded on its own meter and is **never** folded
  into `ai_requests` or the scoring-cost dashboard metric; a zero-cost `ai_requests` row keeps
  meaning what it means today.
- `data-retention`: `indicator_score_audits` cascades from `indicator_scores` — an audit never
  outlives the indicator it judges; audit rows store no free text and no copied excerpt.
- `audit-log`: `evaluation.audit_requested` records who asked for a run, on which evaluation, when.

## Approach

**Contract and storage before behaviour; behaviour before the button; the button before the UI.**

P1 and P2 create facts nothing reads yet: a judge seam with a fake on the test binding, and two
append-only tenant-scoped tables with their invariants enforced in the database rather than in a
service. P3 is the substance — batching, the skip rules, per-call failure isolation, and the
coverage reconciliation that makes a run's counts add up. Only then does P4 expose a way to ask
for one, and P5/P6 make the answer visible. Every slice is independently revertable, and every
`api` slice lands before the `backoffice` slice consuming it.

New namespace `app/Services/Audit/` — `TypesafeJevJudge`, the batching request builder, the
response mapper — so `Services/Scoring/` stays the scoring pipeline and nothing in it acquires an
audit import.

**Strict TDD** per `openspec/config.yaml` (`strict_tdd: true`), vertical slices, every RED before
its GREEN. Representative pairs: P2 RED — a raw insert of a `judged` row with a null probability is
rejected by the CHECK, and a `skipped` row carrying a probability is rejected too. P3 RED — a judge
that throws on competency 3 of 5 still produces rows for every indicator of all five, with
competency 3's marked `unavailable`, and `indicators_total = judged + skipped + unavailable`
holds. P3 RED — an indicator with `score = -1` is never passed to the judge (asserted on the fake's
recorded calls, not on the output). P5 RED — the full report and the session-review view emit a
byte-identical `audit` object for the same indicator. Coverage ≥85% overall, ~95% on the job's
state machine and the tenancy scoping, per `coverage_high_integrity`.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Contracts/AuditJudge.php` + DTO | Added | Typed judgment contract; **not** `LLMProvider` (AD-5) |
| `api/app/Services/Audit/*` | Added | `TypesafeJevJudge` (raw `Http`, no SDK), request builder, response mapper |
| `api/app/Testing/FakeAuditJudge.php` | Added | Default test binding — no ordinary test reaches TypeSafe |
| `api/app/Providers/AppServiceProvider.php` | Modified | Env-conditional binding beside `LLMProvider` (`:49-61`) |
| `api/config/scoring.php` | Modified | New `audit` block (`enabled`, batching, threshold, timeout), `truncation_retry`-shaped |
| `api/database/migrations/*_create_indicator_score_audit_runs_table.php` | Added | Run grain: status, counts, tokens, cost, latency, versions, `failure_reason` |
| `api/database/migrations/*_create_indicator_score_audits_table.php` | Added | Indicator grain: FK `cascadeOnDelete`, status/probability/reason CHECK equivalence |
| `api/app/Models/{IndicatorScoreAuditRun,IndicatorScoreAudit}.php` | Added | `extends TenantModel`, `$timestamps = false`, `organization_id` out of `$fillable` |
| `api/app/Jobs/AuditEvaluationJob.php` | Added | Queued, trigger-agnostic; the unit a v2 listener would dispatch |
| `api/app/Http/Controllers/Api/...AuditController.php` + `routes/api.php` | Added / Modified | `POST /participants/{id}/evaluation/audit`, admin policy, throttle, 409 in-flight |
| `api/app/Services/Admin/AdminEvaluationSerializer.php` (`:311-355`) | Modified | One `audit` key on each `behaviors[]` entry — the single shaper (AD-7) |
| `api/app/Http/Resources/Admin/EvaluationResource.php` | Modified | Passthrough + OpenAPI re-export against Postgres |
| `api/tests/Arch/*` | Added | Audit models append-only; no scoring formula imports an audit model; tenancy |
| `backoffice/app/composables/useEvaluationReport.ts`, `app/types/*` | Modified | `EvaluationBehavior` gains `audit` |
| `backoffice/app/components/molecules/IndicatorEvidence.vue` + new flag atom | Modified / Added | Net-new review-status surface; `ScoreChip` keeps encoding score only |
| `backoffice/i18n/locales/{en,it}.json` | Modified | Authored copy, not machine-translated |
| `api/app/Jobs/ScoreEvaluationJob.php`, `Services/Scoring/*`, `Support/Prompting/PromptBuilder.php` | **Unchanged** | The scoring decision is untouched (AD-7) |
| `api/app/Models/AiRequest.php` + its migration | **Unchanged** | Separate meter (AD-2) |
| `api/app/Services/Webhooks/EvaluationPayloadAssembler.php` | **Unchanged** | Webhook contract not churned for an advisory signal (AD-7) |
| `api/app/Events/EvaluationCompleted.php`, `app/Listeners/*` | **Unchanged** | No listener in v1 (AD-1) |
| `frontend/*` | **Unchanged** | Candidate-facing app has no audit surface |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Cost/latency at realistic scale is unquantified; a batched run is assumed from a single-indicator spike | **High** | AD-1: no automatic trigger ships; every run records its own tokens, cost and latency; ≥20 runs across ≥2 roles are an explicit **gate** before any v2 default-on proposal |
| An advisory flag is read as authoritative and an operator "corrects" a score by hand | **High** | Copy and API name the signal as advisory and name its judge version; no write path from an audit to `indicator_scores`; arch test bans the import |
| TypeSafe is a **third** independent AI failure domain, with no existing test for "third AI dependency down" | Med | AD-3: per-call `Throwable` isolation, explicit degraded rows, run-level `failed`/`partial`; a RED test that a mid-run judge failure still yields a complete, reconciling row set |
| Sending verbatim candidate excerpts to a new vendor is a new sub-processor relationship | Med | AD-6 minimizes state to the persisted verdict and its own excerpts; **returned as an open data-controller decision**, not assumed |
| A flag's meaning drifts as the judge model changes, making old and new runs incomparable | Med | `judge_model_version` + `audit_prompt_version` recorded per run; append-only, so re-auditing adds a run rather than rewriting one |
| Probability threshold picked from cookbook defaults rather than BEAI data | Med | Threshold is config, not a literal; v1 persists the **raw probability** so a threshold change is a display change and reruns nothing |
| `TYPESAFE_API_KEY` provisioning is asserted, not verified; the existing `ai-integration.yml` real-API lane is on record as **already failing** on an invalid `ANTHROPIC_API_KEY` | Med | Confirm the key with whoever owns Railway before P1; do **not** add a new real-API group to a red workflow — fix or isolate the lane first |
| An operator double-clicks and pays twice | Low | 409 on an in-flight run for the same evaluation; route throttled |
| Audit rows survive a retention purge of the data they describe | Low | `cascadeOnDelete` from `indicator_scores` (AD-2), asserted by test |

## Rollback Plan

**Nothing existing can break, because nothing existing is read or written differently.** No
production data has an audit row, no scoring path calls the judge, and no automatic trigger exists.
Per-slice, feature branch, no deploy unless explicitly requested. Reverse order: **P6 → P1.**

- **P6 (`backoffice`)** — `git revert`, then `bun run codegen` against the still-current
  `openapi.json`. The operator loses the flag; rows remain.
- **P5** — `git revert`, re-export `openapi.json` against Postgres (never SQLite), `bun run
  codegen:check`. The `behaviors[]` shape returns to today's, byte-identical.
- **P4** — `git revert` removes the only way to start a run. Existing rows stay readable until P5
  is also reverted; then they are simply unread.
- **P3 / P2** — `git revert` the code and **leave the tables**. They are isolated, append-only,
  referenced by nothing else, and dropping them would destroy the very cost evidence AD-1 exists
  to gather. Drop only after that evidence has been used.
- **P1** — `git revert`. No dependency was added, so nothing to unpin. Unset `TYPESAFE_*` env vars.
- **Emergency, no deploy:** set `SCORING_AUDIT_ENABLED=false` — the route refuses and the job
  no-ops. This is the one-step mitigation for a TypeSafe incident.
- Wrapper submodule pointers revert to their previously pinned commits.

## Dependencies

- **Blocking before P1:** a provisioned, verified `TYPESAFE_API_KEY`, and a decision on the
  real-API CI lane given that `ai-integration.yml` is on record as already failing on an invalid
  `ANTHROPIC_API_KEY`. A new real-API group must not be added to a workflow that is already red.
- **Blocking before P1 (product/legal):** the sub-processor question under Open Decisions.
- **Internal order:** P1 → P2 → P3 → P4 → P5 → P6. Each `api` slice lands before the `backoffice`
  slice consuming it.
- **Client regeneration after P5:** `DB_CONNECTION=pgsql … php artisan scramble:export` →
  `task openapi:sync` → `bun run codegen`, guarded by `bun run codegen:check`.
- **Not a dependency:** v2's automatic trigger. v1 ships and is useful without it (AD-1).

## Size and Delivery

- `Decision needed before apply: Yes`
- `Chained PRs recommended: Yes`
- `400-line budget risk: Medium`

~1,400–1,800 changed lines across 6 slices. Delivery strategy `auto-chain`; chain strategy
`feature-branch-chain`. P3 (`AuditEvaluationJob` plus its state machine and tests) is the tight one
and may need splitting at `sdd-tasks` time. The "decision needed" is the pair of Open Decisions
below — both gate P1, neither gates spec or design work on everything else.

## Success Criteria

- [ ] No listener is registered on `EvaluationCompleted`; an evaluation completing end-to-end
      produces **zero** audit rows and **zero** TypeSafe calls (asserted by test).
- [ ] `POST /api/participants/{id}/evaluation/audit` is admin-only, throttled, returns **409** when
      a run for that evaluation is already in flight, and a cross-tenant participant id yields
      **404**, never 403.
- [ ] `indicators_total = judged + skipped + unavailable` for every run, including a run in which
      the judge throws part-way through.
- [ ] A judge failure on one competency leaves every other competency judged, the run `partial`,
      and the affected indicators `unavailable` — and **never** throws out of the job.
- [ ] Every `score = -1` indicator has a `skipped` / `unassessable_by_construction` row and was
      **never** passed to the judge (asserted on the fake's recorded calls).
- [ ] The CHECK rejects a raw-inserted `judged` row with a null probability, and a non-`judged` row
      carrying a probability.
- [ ] Both audit tables are append-only (arch test) and tenant-scoped; a cross-tenant read returns
      nothing; `organization_id` is absent from both `$fillable` lists.
- [ ] Deleting an `IndicatorScore` deletes its audits; no audit row survives its subject.
- [ ] `indicator_scores`, `competency_results` and `evaluations` are **byte-identical** before and
      after a run; no scoring value changes.
- [ ] `ai_requests` gains **no** row from an audit, and its migration and model are diff-free.
- [ ] `ScoreEvaluationJob`, `PromptBuilder`, `EvaluationParser`, `MeanCalculator`,
      `AssessableFractionReliability`, `CompletionGate` and `EvaluationPayloadAssembler` are
      **diff-free**; an arch test forbids any of them importing an audit model.
- [ ] The full report and the session-review view emit an identical `audit` object for the same
      indicator; an un-audited evaluation emits an explicit "never audited" state, never a missing key.
- [ ] `SCORING_AUDIT_ENABLED=false` makes the route refuse and the job no-op, with no partial rows;
      a config test pins the shipped defaults.
- [ ] Each run records `judge_model_version`, `audit_prompt_version`, tokens, `estimated_cost_usd`
      and `latency_ms`; re-auditing creates a **new** run and updates nothing.
- [ ] No audit row contains free text or a copied excerpt — probability and machine reason codes only.
- [ ] `en`/`it` copy names the signal advisory and never instructs a score change.
- [ ] Pest + Vitest + Playwright green in CI; coverage ≥85% overall, ~95% on the job state machine
      and tenancy scoping.

## Open Decisions — returned to the orchestrator, not decided here

Both gate **P1**. Neither blocks `sdd-spec` or `sdd-design` on anything else, and neither may be
silently assumed by a later phase.

1. **TypeSafe as a sub-processor of candidate personal data.** AD-6 minimizes what leaves BEAI to
   the persisted verdict plus its own excerpts — but those excerpts are verbatim candidate speech,
   and this makes TypeSafe a new processor of personal data. Product decision 2 (GDPR retention)
   is already recorded as *"defaults set, legal sign-off pending"*, and that sign-off must name
   this flow. **This is a data-controller decision and this proposal does not take it.** No
   assumption is made; P1 does not start without it.
2. **`TYPESAFE_API_KEY` provisioning and the real-API CI lane.** The key's existence was asserted
   in exploration and has not been independently verified against Railway. Separately, the
   `ai-integration.yml` lane is on record as failing on every push with an invalid
   `ANTHROPIC_API_KEY`. Adding a TypeSafe real-API group to an already-red workflow buys no signal.
   Needs an owner decision: fix the existing lane, isolate the new group, or defer real-API
   coverage to `workflow_dispatch` only.

Non-blocking, assumptions stated so a correction is cheap:

3. **Batching granularity.** *Assumed:* one Jev request per competency, carrying that competency's
   indicators, mirroring `PromptBuilder`. This is the shape whose real cost AD-1 sets out to
   measure; if the first runs show per-indicator requests are cheaper or materially more accurate,
   it is a change inside `app/Services/Audit/` with no schema impact.
4. **Flag threshold and rendering.** *Assumed:* v1 persists the raw `support_probability` and
   renders bands from a config threshold, so a threshold change reruns nothing. The band **labels**
   are product copy and are not chosen here. Note the ratified precedent for `reliability`
   (ruling 1): percentage rendered verbatim, **no High/Medium/Low bands** — if that doctrine
   extends here, the audit shows a number and no band at all.
