# Proposal: Scoring Failure Containment

## Intent

On **2026-08-24**, participant 19 (`evaluation_id` 6) completed a real interview and **all
five competencies returned 0%**, each stamped `llm_parse_error`. The evaluation finalized as
`pending` with `valid_count=0`. **The root cause is still unknown — and that is the finding.**

The raw response is never persisted, and `finish_reason` — which already flows from
`AnthropicLLMProvider::parseResponse()` into `ai_requests.finish_reason` — is never inspected
by any code branch. A markdown-fenced JSON body and a response truncated at `max_tokens`
(2048) are indistinguishable after the fact. The operator, meanwhile, is told nothing at all:
`AdminEvaluationSerializer::serializeCompetencyResult()` returns `{score, reliability,
behaviors}` and never reads the `unscorable_reason` the system already persisted.

Five gaps, one family: **the scorer hits a problem and destroys an entire competency instead
of degrading**. This change makes each failure *identifiable*, *contained*, and *visible*.

Success = a scoring failure names itself in the log, in `ai_requests` and to the operator;
a truncation self-heals once; and one bad indicator no longer discards its healthy siblings.

---

## AD-1 — A validation-failed indicator is out-of-band metadata; the score stays `-1` (RATIFIED)

Ratified by the product owner. `IndicatorScore.score` **remains `-1`**, so `MeanCalculator`,
`AssessableFractionReliability` and `CompletionGate` are **untouched** and ratified product
decision #1 (`reliability = assessed / total`, `-1` excluded from the numerator) is preserved
byte-for-byte. Alongside `-1`, a **nullable reason field** records *why* the indicator is
unassessable — at minimum three values:

| Reason | Meaning |
|---|---|
| declared by the model | the LLM itself emitted `-1`: no assessable evidence in the transcript |
| excerpt unverifiable | the LLM claimed evidence we could not verify verbatim against the transcript |
| score illegal | the LLM emitted a value outside `{1,2,3,4,5,-1}` |

**Why not option (a), folding into a bare `-1`.** A bare `-1` conflates *"the model reported
no assessable evidence"* with *"the model claimed evidence we could not verify"*. Those are
different facts about different actors, and an operator who cannot separate them **is being
told less than the system already knows** — the exact failure mode this whole change exists
to remove.

**Why not option (b), a new sentinel value.** It would break the `{1,2,3,4,5,-1}` domain
ratified, specified and shipped to production *hours* earlier
(`archive/2026-08-25-bars-full-scale-1-5`). Widening a domain twice in a day, in opposite
directions, is how a source of truth stops being one.

The reason field is **metadata, never arithmetic**. No formula may read it. Any future
proposal that wants it in the denominator argues against decision #1 explicitly.

## AD-2 — The diagnostic fingerprint is DERIVED SIGNALS ONLY; raw substrings are DEFERRED

`ai_requests` records `finish_reason` and `output_tokens` today. The fingerprint adds only
**derived, non-reversible signals**: response **byte length**, a **"starts with a fence"
boolean**, and optionally a **response hash**. **No raw substrings — not even short ones.**

**This is a GDPR boundary, not a preference.** `openspec/specs/data-retention/spec.md:46-56`
enumerates exactly **four** candidate-data classes — `snapshot`, `transcript`,
`webhook_payload`, `participant_pii`. **`ai_requests` is deliberately not among them**,
correctly, because today it carries no verbatim content. A raw fragment of a scoring response
*is* candidate-derived content — the response IS the model's rendering of the transcript.
Storing one would make `ai_requests` a **fifth candidate-data class with no ratified retention
duration**, mirroring the pending legal sign-off already outstanding for
`webhook_deliveries.payload` and `participants.display_name` (open product decision #2).
Independently, `openspec/specs/observability/spec.md:383-465` states that `failure_reason`
records why a result was unusable — **"never the raw provider payload"**.

**Deferred, not rejected.** The raw-substring variant is technically trivial; it is blocked on
a legal answer we do not have. It is recorded here so a future reader does not mistake its
absence for an oversight.

**Derived signals are sufficient.** With AD-3 in place, `finish_reason = max_tokens` *is* the
truncation diagnosis and the fence boolean *is* the other diagnosis. The raw text buys almost
nothing the derived signals do not already give — at the cost of a new legal class.

## AD-3 — Truncation is detected, not guessed

`AnthropicLLMProvider` already carries `stop_reason` into `LLMResponse::$finishReason`, and
**nothing reads it**. `max_tokens` is today indistinguishable from `end_turn` downstream.

Check `finishReason` **before** parsing and short-circuit to a **distinct failure class**, so
a truncation never again arrives at `json_decode()` disguised as a generic
`JsonParseException: Syntax error`. The signal is already in the pipe, unused — this is the
highest diagnostic yield per line in the change.

**Cost:** `AiRequestFailureReason` is a **closed set of 6 enforced by a Postgres CHECK
constraint** (`ai_requests_failure_reason_check`). A new truncation value is a **migration**,
not a config edit, and it is a blocking dependency for Increment A.

## AD-4 — Truncation-only retry, with a cap — and it is NOT RT-B

D4 FIX-9 deliberately RETURNS instead of throwing on parse errors, so queue retry never fires
for this class. **That rule stays intact for every class it correctly covers**: fence, prose,
indicator count mismatch, invalid score and non-verbatim excerpt are all genuinely
deterministic — retrying them at the same budget reproduces them exactly.

**Truncation is the one exception, and only because its determinism is budget-scoped.** A
response truncated at `max_tokens = N` is deterministic *at N*; it is not deterministic at
`2N`. Retrying with a larger budget is the remedy, not a gamble. Constraints:

- **Capped** — a bounded number of enlarged-budget attempts (one, unless design argues otherwise).
- **Own `ai_requests` row** — every call is billed and every call is logged
  (`observability/spec.md`: exactly one row per provider call, append-only). A retry that
  reuses the first row hides a real cost.
- **Truncation only** — no other failure class becomes retryable.

**This does NOT touch RT-B / open product decision #4.** RT-B
(`scoring-engine/spec.md:713-784`) is a **domain-level candidate retry**: re-issuing a magic
link, re-interviewing invalid competencies, merging into the same Evaluation row — a
cross-slice C6/C7/C9 UX decision awaiting product ratification. What AD-4 adds is a
**queue-job-internal, same-competency, same-interview** retry of one LLM call at a larger
budget. The two share a word and nothing else. Stated loudly so no reviewer conflates them.

## AD-5 — Fence and leading/trailing prose tolerance in `EvaluationParser`

`EvaluationParser::parse()` calls `json_decode()` with **zero pre-processing**. A markdown
fence or any conversational preamble throws `JsonParseException` carrying the bare
`json_last_error_msg()` — exactly the `"Syntax error"` seen in production.

Strip a leading/trailing code fence and surrounding prose before decoding; **keep hard-fail
for everything else**. Tolerance is narrow and named: it must not become a general "try to
find some JSON in there" salvage routine, which would trade a loud failure for a silent
mis-parse.

## AD-6 — `unscorable_reason` is a public read-surface contract, not an internal note

The reason is persisted and **never shown**. The operator sees `score: null`,
`reliability: "0%"`, `behaviors: []` and no explanation. **That is the operator-facing half of
the bug**, and it is exactly the failure the existing `admin-backoffice` requirement calls out
in a different context: *"an operator learns about unscorable competencies before inviting
candidates, not at report time"*.

`AdminEvaluationSerializer::serializeCompetencyResult()` MUST expose `unscorable_reason`, and
`EvaluationReport.vue` MUST render it instead of a bare, unexplained 0%. This is a **public
contract change**: Scramble regenerates `openapi.json`, and `backoffice` regenerates its typed
client from it. Per the machine-facing-values convention the enum key is returned **literally
in every locale**; the *label* is i18n'd in the backoffice (`en`, `it`).

**RATIFIED 2026-08-25 — the reason also reaches the calling system.** This proposal was
drafted assuming `unscorable_reason` stayed operator-only (see the question round below, now
answered). The product owner extended it to the `evaluation` webhook payload, and the reasoning
is the same one that justifies showing it to the operator: CLAUDE.md already sends sub-90%
evaluations via webhook **with partial data**, so an integrator already receives zero-scored
competencies — and today cannot distinguish *"the candidate gave no assessable evidence"* from
*"our scorer failed"*. The first is a fact about the candidate; the second is a fact about us.
An integrator making a selection decision on a zero deserves to know which one they are reading.

The `webhooks-integration` capability therefore gains a delta this proposal did not originally
anticipate. `sdd-spec` resolved the versioning question that follows from it: the addition is
**additive and does NOT bump `payload_version`**, mirroring the existing open-map precedent in
the payload's `files` block.

## AD-7 — Per-indicator isolation

`ScoreEvaluationJob::scoreCompetency()` validates **all** DTOs inside **one** `try`. A single
catch spans the whole competency, so a bad excerpt on indicator 3 **discards indicators 1 and
2 that already validated cleanly**. Restructure so indicator-level validation failures are
contained per-indicator: the failing indicator becomes `-1` + an AD-1 reason, its siblings
keep their scores, and the competency survives with a lower reliability instead of vanishing.

Competency-level failures (parse, truncation, count mismatch) are unaffected — there are no
per-indicator DTOs to isolate when the envelope itself did not parse.

## AD-8 — Increment A is independently shippable; B depends on A

| Increment | Contents | Ships alone? |
|---|---|---|
| **A** | AD-5 fence/prose tolerance · AD-3 truncation detection · AD-2 derived fingerprint · AD-6 operator surfacing | **Yes.** Alone, it would have made the 2026-08-24 incident **visible instead of silent** |
| **B** | AD-4 truncation retry (requires A's detection) · AD-7 + AD-1 per-indicator isolation | No — B's retry has nothing to trigger on without A |

A is diagnosis; B is remediation. **Diagnosis first**: shipping a retry before we can prove
what we are retrying is how a bug becomes a bill.

---

## Scope

### In Scope

| # | Deliverable | Increment | Repo |
|---|---|---|---|
| 1 | `EvaluationParser` fence + leading/trailing prose tolerance; narrow, named, hard-fail otherwise | A | `api` |
| 2 | `finishReason === 'max_tokens'` check before parse → distinct failure class | A | `api` |
| 3 | New `AiRequestFailureReason` truncation case **+ Postgres CHECK-constraint migration** | A | `api` |
| 4 | `ai_requests` derived-signal fingerprint columns (byte length, fence boolean, optional hash) + migration | A | `api` |
| 5 | `AdminEvaluationSerializer` exposes `unscorable_reason`; `openapi.json` regen | A | `api` |
| 6 | `EvaluationReport.vue` renders the reason; i18n keys (`en`, `it`); typed-client regen | A | `backoffice` |
| 7 | New golden cassettes: **fenced** response and **truncated** response (none exist today) | A | `api` |
| 8 | Truncation-only retry at an enlarged budget, capped, with its own `ai_requests` row | B | `api` |
| 9 | Per-indicator isolation in `scoreCompetency()` | B | `api` |
| 10 | `indicator_scores` nullable reason column + migration; `IndicatorScoreDTO` carries it | B | `api` |
| 11 | Indicator reason surfaced through the serializer + report viewer | B | `api` + `backoffice` |
| 12 | `scoring-engine` **Coverage Note amendment** — the pinned three-value `unscorable_reason` enum | A | wrapper |

### Out of Scope — explicit non-goals

Three follow-on changes are **already planned** and named here only so they are not lost:

1. **Whole-conversation transcript for the evaluator** — today the evaluator sees only the
   single competency's `InterviewSession`.
2. **Evaluator rigor calibration** — `PromptBuilder` carries no severity guidance.
3. **STAR-based interviewer prompt** — `SystemPromptComposer` has no STAR model, no
   same-episode constraint, no minimum question count.

Also explicitly out of scope:

- **Raw response substrings in the fingerprint** — DEFERRED pending legal sign-off (AD-2).
- **`data-retention/spec.md`** — deliberately **untouched**. Adding a fifth candidate-data
  class is the thing AD-2 exists to avoid; a delta here would be the bug, not the fix.
- **RT-B / open product decision #4** — the domain-level candidate retry. Untouched (AD-4).
- **`MeanCalculator`, `AssessableFractionReliability`, `CompletionGate`** — untouched by
  construction (AD-1). Ratified product decision #1 and the validity threshold T stand.
- **The `{1,2,3,4,5,-1}` score domain** — unchanged. No new sentinel (AD-1).
- **Re-scoring `evaluation_id` 6 or any historical evaluation** — no backfill. This change
  makes the *next* failure legible; it does not retroactively diagnose this one.
- ~~**Webhook payload contract**~~ — **NO LONGER OUT OF SCOPE.** Ratified 2026-08-25: the
  reason reaches the calling system, so `EvaluationPayloadAssembler` and the
  `webhooks-integration` capability are IN scope. See AD-6. The addition is additive and does
  not bump `payload_version`.
- **General "find the JSON somewhere" salvage parsing** — see AD-5.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `scoring-engine`: a distinct **truncation** failure class detected from `finish_reason`
  before parsing; fence/prose tolerance in the parse acceptance criteria; the truncation-only
  retry carve-out from the no-queue-retry rule; per-indicator validation-failure isolation;
  the `unscorable_reason` enum widens beyond the three values pinned as **normative text** in
  the Coverage Note (`spec.md:823-824`) — which MUST be amended explicitly.
- `scoring-model`: an indicator's `-1` may carry an **out-of-band reason**; `-1`, the mean
  denominator and the reliability formula are restated as **unchanged invariants**.
- `observability`: `ai_requests` gains derived-signal fingerprint columns and a new
  `failure_reason` value; the **append-only**, **one-row-per-call** and **never-the-raw-
  provider-payload** requirements are preserved, and the retry attempt gets its **own row**.
- `admin-read-api`: the evaluation read surface exposes `unscorable_reason` (and, in B, the
  per-indicator reason) as machine-facing values, unlocalized.
- `admin-backoffice`: the report viewer states *why* a competency is unscorable rather than
  rendering an unexplained 0%.
- `webhooks-integration` *(added 2026-08-25, after the AD-6 ratification)*: the `evaluation`
  payload carries `unscorable_reason` per competency, so an integrator can tell a candidate's
  missing evidence from our own scorer's failure. **Additive — `payload_version` does not
  bump**, mirroring the payload's existing open-map `files` precedent.

## Approach

**Read the signals we already pay for, then contain the blast radius.** Two of the four
Increment-A items are pure "start inspecting a value that already flows through the pipe"
(`finish_reason`) or "start serializing a column that is already persisted"
(`unscorable_reason`). The genuinely new machinery is small: a narrow parser pre-processor,
two migrations, and a retry branch guarded by a single failure class.

Ordering within A: **migrations → detection/parsing → serializer → UI**, because the CHECK
constraint must accept the new value before any code can write it. B follows A; per AD-8 it
cannot precede it.

Strict TDD per `openspec/config.yaml` (`strict_tdd: true`): every RED task precedes its GREEN.
Scoring is a correctness-critical zone held to **~95%** coverage. **No existing golden cassette
exercises a fenced or truncated response** — all three are clean JSON, so Increment A needs
**new fixtures**, not merely new assertions.

## Size and Delivery

- `Chained PRs recommended: Yes`
- `400-line budget risk: Medium`
- `Decision needed before apply: Yes` — the question round below gates AD-4's cap and the
  webhook-payload question.

Natural slices: **A1** (migrations + enum), **A2** (detection + parser + fingerprint +
cassettes), **A3** (serializer + openapi + backoffice render), **B1** (truncation retry),
**B2** (per-indicator isolation + indicator reason). Each is independently revertable and
independently verifiable. A3 spans two repos and must land `api` before `backoffice`.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Services/Scoring/EvaluationParser.php` | Modified | Fence + prose tolerance before `json_decode` (AD-5) |
| `api/app/Jobs/ScoreEvaluationJob.php` | Modified | Truncation short-circuit; per-indicator isolation; capped retry |
| `api/app/Services/LLM/AnthropicLLMProvider.php` | Modified | Surface the derived fingerprint signals alongside `finishReason` |
| `api/app/DTOs/LLMResponse.php` | Modified | Carry the derived fingerprint |
| `api/app/Enums/AiRequestFailureReason.php` | Modified | New truncation case |
| `api/database/migrations/*_ai_requests_*` | Added | CHECK-constraint update + fingerprint columns |
| `api/database/migrations/*_indicator_scores_*` | Added | Nullable reason column (Increment B) |
| `api/app/DTOs/Scoring/IndicatorScoreDTO.php` | Modified | Optional reason (Increment B) |
| `api/app/Models/IndicatorScore.php` | Modified | Reason attribute + cast (Increment B) |
| `api/app/Services/Admin/AdminEvaluationSerializer.php` | Modified | Expose `unscorable_reason` (+ indicator reason in B) |
| `api/tests/Fixtures/cassettes/*` | Added | Fenced response, truncated response |
| `api/config/scoring.php` | Modified | Retry cap + enlarged-budget `max_tokens` (AD-4) |
| `backoffice/app/components/organisms/EvaluationReport.vue` | Modified | Render the reason instead of an unexplained 0% |
| `backoffice/i18n/locales/{en,it}.json` | Modified | Reason labels |
| `backoffice` generated API types | Regenerated | From the updated `openapi.json` |
| `openspec/specs/scoring-engine/spec.md` (Coverage Note) | Modified | The pinned three-value enum, amended explicitly |
| `MeanCalculator`, `AssessableFractionReliability`, `CompletionGate`, `IndicatorValidator::LEGAL_SCORES`, `data-retention/spec.md` | **Unchanged** | Guaranteed by AD-1 and AD-2 |
| `PromptBuilder`, `config('scoring.prompt_version')` | **Unchanged** | No prompt-copy edit is proposed; no version bump is due |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| The Postgres CHECK constraint rejects the new failure reason if the migration lags the code | **High** | Migration ships in slice A1, **before** any writer; deploy order is part of the slice contract |
| A future reader treats the widened `unscorable_reason` as a regression against the pinned three-value Coverage Note | **High** | Deliverable 12 amends that normative text **explicitly**, in the same change |
| A truncation retry doubles the billed cost of an already-failed call | Med | Hard cap; truncation-only carve-out; its own `ai_requests` row so the cost is visible, never hidden |
| Fence tolerance drifts into general salvage parsing, converting loud failures into silent mis-parses | Med | AD-5 constrains it to leading/trailing fence + prose; negative cassettes assert that malformed bodies still hard-fail |
| Per-indicator isolation is misread as changing what "total" means, silently reinterpreting ratified decision #1 | Med | AD-1 keeps `-1` and forbids any formula from reading the reason; the three formula classes are asserted unchanged |
| Scope creep from AD-2 into a raw-substring fingerprint, creating a fifth candidate-data class | Med | Explicit non-goal; `data-retention/spec.md` must appear in **no** delta |
| New fixtures do not faithfully reproduce a real provider truncation | Med | Build the truncated cassette from a real `stop_reason = max_tokens` shape, not a hand-cut string |
| The backoffice renders a reason key the API has not shipped yet | Low | A3 lands `api` before `backoffice`; unknown keys must render a neutral fallback, never a blank |
| Real root cause of `evaluation_id` 6 turns out to be neither fence nor truncation | Low | The fingerprint is diagnostic by design: byte length + `output_tokens` + `finish_reason` still narrow an unknown third cause |

## Rollback Plan

Per-slice, feature branch, no deploy.

- **B2 / B1:** `git revert`. Behaviour returns to whole-competency failure. The
  `indicator_scores` reason column is **nullable and additive** — leave it in place; existing
  rows stay valid because the arithmetic never read it (AD-1).
- **A3:** `git revert` in `backoffice` first, then `api`. Regenerate `openapi.json` and the
  typed client. The serializer drops a field — additive removal, no consumer breaks.
- **A2:** `git revert`. Truncations return to being reported as generic parse errors.
- **A1:** the fingerprint columns are nullable and additive — **prefer leaving them**. If the
  CHECK constraint must be narrowed back, any rows already carrying the truncation value must
  be migrated first, or the constraint will refuse to apply. This is the **only** rollback
  step with a data precondition; it must be scripted, not improvised.
- Reverse ship order on rollback: **B2 → B1 → A3 → A2 → A1**.
- Wrapper submodule pointers revert to their previous pinned commits.

## Dependencies

- **Blocking within the change:** the A1 CHECK-constraint migration gates AD-3; AD-3 gates
  AD-4.
- **Open product decision #2 (GDPR sign-off)** — **not blocking**, precisely because AD-2
  keeps `ai_requests` out of the candidate-data classes. It blocks *only* the deferred
  raw-substring variant.
- **Open product decision #4 (RT-B)** — **not blocking**. Different concept (AD-4).
- **Ratified decision #1 (reliability = assessed/total)** — a constraint, not a dependency:
  AD-1 is built to preserve it exactly.
- **`archive/2026-08-25-bars-full-scale-1-5`** — must be merged into `openspec/specs/` before
  this change's deltas are authored, so the `{1,2,3,4,5,-1}` domain is the baseline.

## Success Criteria

- [ ] A truncated provider response is recorded with the **new truncation failure reason**, never as a generic `llm_parse_error`.
- [ ] A markdown-fenced JSON response parses successfully; a genuinely malformed body still hard-fails, proven by a negative cassette.
- [ ] `ai_requests` carries `finish_reason`, `output_tokens`, response byte length and the fence boolean for every failed scoring call — and **no raw response text**, asserted by test.
- [ ] `data-retention/spec.md` is byte-unchanged and appears in no delta.
- [ ] `GET /api/participants/{id}/evaluation` returns `unscorable_reason` for every unscorable competency, unlocalized, and `openapi.json` reflects it.
- [ ] `EvaluationReport.vue` renders a human-readable reason (`en` + `it`) for an unscorable competency; no unexplained 0% remains reachable.
- [ ] A truncation retries **at most the capped number of times**, at an enlarged budget, and each attempt writes its **own** `ai_requests` row.
- [ ] No non-truncation failure class becomes retryable; D4 FIX-9 still holds for fence, prose, count mismatch, invalid score and non-verbatim excerpt.
- [ ] A competency with one unverifiable excerpt out of three persists **two** scored indicators and a reduced reliability — not zero indicators.
- [ ] `IndicatorScore.score` for a validation failure is `-1`, with the reason in the metadata field, and **no formula reads that field** (asserted by test).
- [ ] `MeanCalculator`, `AssessableFractionReliability`, `CompletionGate` and `IndicatorValidator::LEGAL_SCORES` are diff-free.
- [ ] The `scoring-engine` Coverage Note no longer claims a three-value `unscorable_reason` enum.
- [ ] New fenced and truncated cassettes exist and are green.
- [ ] Pest + Vitest + Playwright green in CI; coverage ≥ 85% overall, ~95% on the scoring zone.

## Proposal Question Round

Execution mode did not allow interactive questioning. These are **product** decisions —
`sdd-spec` and `sdd-design` MUST NOT silently invent answers. Assumptions are stated so a
correction is cheap.

1. **Retry cap and budget (AD-4).** How many enlarged-budget attempts, and how much larger?
   A truncation retry is a **second billed call on an already-failed evaluation**.
   *Assumed:* **exactly one** retry at a **doubled** `max_tokens`, both config-driven.
2. **Does the reason reach the calling system?** `unscorable_reason` currently stays internal;
   the `evaluation` webhook carries score/reliability/behaviors. Should an integrator learn
   *why* a competency scored nothing, or is that operator-only detail?
   **ANSWERED 2026-08-25 — the reason reaches the integrator too.** The assumption recorded
   here was operator-only; the product owner overruled it. See AD-6 for the reasoning and the
   `webhooks-integration` delta it produced. The addition is additive; `payload_version` does
   not bump.
3. **Indicator reason vocabulary (AD-1).** Three values are proposed (declared by the model /
   excerpt unverifiable / score illegal). Is that the full set the operator needs, or should
   it distinguish finer causes (e.g. whitespace-normalization near-miss vs. wholly invented
   excerpt)?
   *Assumed:* **three**, extensible later — the column is nullable and unconstrained.
4. **Partial competency credibility.** After AD-7 a competency survives partially: 2 of 3
   indicators assessed → reliability 67%, above T = 0.5, therefore `valid`; 1 of 3 → 33%,
   below T, therefore invalid. Should indicators lost to *validation failure* count against
   reliability identically to indicators the model declared genuinely unassessable?
   *Assumed:* **yes, identically** — the reason is metadata and T already does the filtering.
   The alternative (weighting validation failures differently) reopens ratified decision #1.
5. **Operator visibility of the fingerprint.** Should the derived signals (finish reason, byte
   length, fence flag) be visible to an org admin in the backoffice, or remain
   engineering-only in `ai_requests`?
   *Assumed:* **engineering-only** — the operator gets the *reason*, not the telemetry.
