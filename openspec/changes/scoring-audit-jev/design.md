# Design: Post-hoc Audit of Persisted Indicator Scores (TypeSafe / Jev)

> **Scope of this document.** AD-1 … AD-7 in `proposal.md` are ratified and are **not** re-opened
> here. This document decides only the HOW, against the code as it actually exists on `develop`
> today. Every path, line reference and constraint name below was read before it was written.

## Technical Approach

Nine moving parts, plus five corrections to premises the proposal inherited. The corrections come
first because three of them change what gets written into the database (a coverage identity that
does not add up, a column name that lies about what it holds, and a cost column that must be
allowed to be NULL) and two of them decide what a slice can honestly claim to have verified.

1. **The judge seam is a contract plus three pure collaborators**, so that the one genuinely
   unverified thing in this change — TypeSafe's wire format — is contained in a single mapper
   class and cannot reach the schema, the DTOs, the job, or the read surface (D2, C-C).
2. **AD-6 becomes a structural property, not a promise.** `AuditSubject` is a readonly DTO built
   from exactly four persisted `IndicatorScore` columns; an arch test bans `TranscriptAssembler`,
   `Utterance` and `InterviewSession` from `app/Services/Audit/**` and from the job. With no
   transcript type reachable, a second scoring pass is not something the code declines to do — it
   is something the code cannot express (D3, D11).
3. **Two append-only tenant tables whose invariants live in Postgres**, not in a service: a status
   enumeration CHECK, two equivalence CHECKs in the exact shape of
   `indicator_scores_unassessable_reason_check`, and a coverage identity CHECK (D4).
4. **In-flight refusal is a Redis lock, never a row**, because a `running` status would force an
   UPDATE and destroy the append-only invariant the same change is arch-testing (D7).
5. **The run row is written once, at the end, in one transaction** — and the cost this trades away
   on a worker kill is named as a known ceiling rather than left to be discovered (D6).
6. **The skip rule tests `score === -1` first and `excerpts === []` second**, which is the
   proposal's rule plus a closed door on a third case the proposal's table does not enumerate
   (D5).
7. **One new key inside `serializeCompetencyResult()`**, one new `meta.audit` sibling outside it,
   and one new map parameter shaped exactly like the existing `$catalogue` parameter — one query
   for the whole report, never one per indicator (D9).
8. **Reads go through a named reader.** `App\Support\Admin\AuditVerdictReader` is the only class
   in `app/` permitted to query either audit table, which is what lets the append-only arch guard
   ban `::where(` outright, exactly as `AiRequestAppendOnlyArchTest` already does (D10).
9. **The scoring pipeline is byte-unchanged.** `ScoreEvaluationJob`, `PromptBuilder`,
   `EvaluationParser`, `MeanCalculator`, `AssessableFractionReliability`, `CompletionGate`,
   `IndicatorValidator`, `ExcerptValidator`, `EvaluationPayloadAssembler`, `AiRequest` and its
   migrations acquire no diff and no import (D11).

---

## Corrections to Inherited Premises

### C-A — `SessionCostEstimator` lives under `app/Services/Proctoring/`

AD-2's fourth argument quotes `SessionCostEstimator.php:20-22` and cites it as
`app/Support/Observability/`. The file is at **`api/app/Services/Proctoring/SessionCostEstimator.php`**
and the quoted doctrine is verbatim at `:20-22`:

> *"The LLM side is NOT summed in here: token cost comes from `ai_requests` via
> `AiRequestCostEstimator`, and the two are different vendors on different meters. One total would
> be a number with no owner."*

The argument stands unchanged; only the path was wrong. The estimator the audit meter is modelled
on, `AiRequestCostEstimator`, **is** under `app/Support/Observability/`, which is where this
change's own estimator goes (D8).

### C-B — The binding site is `AppServiceProvider.php:55-61`, and it is env-conditional by `environment('testing')`

The affected-areas table cites `:49-61`; `:49` is `register()`'s opening brace. The actual
`LLMProvider` binding is:

```php
if ($this->app->environment('testing')) {
    $this->app->bind(LLMProvider::class, FakeLLMProvider::class);
} else {
    $this->app->bind(LLMProvider::class, AnthropicLLMProvider::class);
}
```

`AuditJudge` joins this exact `if/else`, in the same method, immediately below it (D2). The
mechanism that keeps the `@ai` group able to reach the real vendor is that those tests run
*outside* `APP_ENV=testing` — not a group check in the provider.

### C-C — The TypeSafe wire contract is UNVERIFIED, and this design does not pretend otherwise

A full-repository search finds **no TypeSafe code, config, env key, fixture or dependency anywhere**
— the only occurrences of the string are `proposal.md` and `.atl/skill-registry.md`. This design
phase had no network access, so the endpoint path, the request envelope field names, the response
envelope, the exact `judge_model` id and the vendor's published rate card are **not verified
facts**. They are the single largest unknown in this change.

Two consequences, both load-bearing:

1. **The seam is drawn so that being wrong is cheap.** Everything downstream of
   `AuditJudge::judge()` — the DTOs, the schema, the CHECK constraints, the job's state machine,
   the serializer, the backoffice — is expressed in BEAI's own vocabulary and is invariant under
   any wire format. A wrong guess costs `JevRequestBuilder` + `JevResponseMapper`, two pure classes
   with no state and no I/O.
2. **P1 opens with a verification task, not a code task.** Before `TypesafeJevJudge` is written,
   read `https://docs.typesafe.ai/api.md` and the Noul primitive page
   (`https://docs.typesafe.ai/primitives/noul.md`), and record the confirmed endpoint, request
   envelope, response envelope, model id and published rates **in this document** as a revision.
   Treat any figure in D2/D8 below as a placeholder until then. Writing an HTTP client against a
   remembered API shape is precisely how `gemini-3-flash` reached a seeder in this repository and
   failed at the vendor (pluggable-conversation-llm, C-A).

### C-D — The coverage identity in AD-4 omits `malformed`, and would fail on any run that has one

AD-3 defines four indicator statuses — `judged`, `unavailable`, `malformed`, `skipped`. AD-4 then
states the reconciliation as `indicators_total = judged + skipped + unavailable`, and lists it as a
success criterion "for every run". The two cannot both hold: a run containing one malformed verdict
breaks that identity by construction.

**Resolution: a fourth counter.** `indicator_score_audit_runs` carries `indicators_malformed`, and
the identity — enforced as a database CHECK, not only a test — is:

```
indicators_total = indicators_judged + indicators_skipped + indicators_unavailable + indicators_malformed
```

**Considered and rejected: folding `malformed` into the `unavailable` counter.** It would preserve
the proposal's three-term arithmetic at the cost of the exact distinction AD-3 built the indicator
grain to preserve — *"the vendor did not answer"* and *"the vendor answered and the answer was
unusable"* are different facts with different owners, and the run counters are the first thing an
operator reads. A three-term identity that is only correct because a real distinction was erased
is worse than a four-term one.

**This must propagate to `spec.md`**: the reconciliation requirement is four terms.

### C-E — `skip_reason` is a misnomer for a column that also holds non-skip reasons

The proposal's AD-2 table names the indicator-grain reason column `skip_reason`, while AD-3 defines
the CHECK over *every* non-`judged` status: `unavailable` and `malformed` rows must also carry a
non-null reason. A column literally named `skip_reason` on an `unavailable` row says something
false about the row it is on.

**Resolution: the column is `outcome_reason`.** This is the same correction
`App\Enums\IndicatorFailureReason`'s own docblock records for its column — *"Deliberately named
`unassessable_reason` at every layer… NOT `failure_reason` (a misnomer: `ModelDeclared` is the
model answering HONESTLY…)"* — applied one grain down. The vocabulary it carries:

| status | `outcome_reason` values |
|---|---|
| `skipped` | `unassessable_by_construction`, `assessed_without_excerpts` |
| `unavailable` | `judge_unreachable`, `judge_http_error`, `judge_timeout` |
| `malformed` | `verdict_missing`, `verdict_unparseable`, `probability_out_of_domain` |
| `judged` | *(must be NULL)* |

**This must propagate to `spec.md`.**

### C-F — A new `ShouldQueue` job with a `$timeout` is not free, and a named queue would silently never run

`App\Support\Queue\QueueRuntimeInvariant::violations()` reflects over **every** `ShouldQueue`
implementor under `app/` and asserts `max(declared job $timeout) < queue.runtime.worker_timeout`.
`worker_timeout` defaults to **1260s** (`config/queue.php:169`) and `ScoreEvaluationJob::$timeout`
is 1200. `AuditEvaluationJob::$timeout` must therefore be **< 1260**, and this is checked both by
`tests/Unit/QueueRuntimeConfigTest.php` and by `beai:queue-work --validate-only` at container
start — a too-large value is a **worker that refuses to boot**, not a failing test.

Second trap, same file: `queue.runtime.worker_queues` defaults to `['default']`
(`config/queue.php:182-184`). Dispatching `AuditEvaluationJob` onto a named queue (`onQueue('audit')`)
without also changing `QUEUE_WORKER_QUEUES` in every environment produces a job that enqueues
successfully, returns 202, and is never consumed by anything. **v1 uses the default queue.**

---

## Architecture Decisions

### D1 — Namespaces and file layout

**Choice.**

| Namespace / path | Holds | Precedent followed |
|---|---|---|
| `app/Contracts/AuditJudge.php` | the judgment contract | `app/Contracts/LLMProvider.php` |
| `app/DTOs/Audit/` | `AuditSubject`, `AuditRequest`, `AuditVerdict`, `AuditBatchResult` | `app/DTOs/LLMResponse.php`, `app/DTOs/Scoring/*` |
| `app/Enums/Audit/` | `AuditRunStatus`, `AuditVerdictStatus`, `AuditOutcomeReason` | `app/Enums/Scoring/ScoringFailure`, `ScoringDisposition` |
| `app/Exceptions/Audit/AuditJudgeException.php` | transport/protocol failure, `retryable` flag | `app/Exceptions/LLM/AnthropicException.php` |
| `app/Services/Audit/` | `TypesafeJevJudge`, `JevRequestBuilder`, `JevResponseMapper` | `app/Services/LLM/AnthropicLLMProvider.php` |
| `app/Support/Observability/AuditRunCostEstimator.php` | tokens → USD, own rate table | `AiRequestCostEstimator.php`, same directory |
| `app/Support/Admin/AuditVerdictReader.php` | the ONLY reader of either audit table | `AdminParticipantReader`, `SessionEvidenceReader` |
| `app/Testing/FakeAuditJudge.php` | default test binding | `app/Testing/FakeLLMProvider.php` |
| `app/Jobs/AuditEvaluationJob.php` | the trigger-agnostic unit | `app/Jobs/ScoreEvaluationJob.php` |
| `app/Models/IndicatorScoreAuditRun.php`, `IndicatorScoreAudit.php` | `extends TenantModel` | `AiRequest.php`, `IndicatorScore.php` |
| `app/Http/Controllers/Api/EvaluationAuditController.php` | the operator entry point | `ParticipantRecoveryController.php` |

**Alternatives considered.** (a) One `app/Services/Audit/` namespace holding the DTOs, enums and
exception too. (b) `app/Services/Scoring/Audit/`.

**Rationale.** (a) fights two conventions at once: every DTO in this codebase lives under
`app/DTOs/` and every enum under `app/Enums/`, and a reviewer looking for the audit's status
vocabulary will look where the other three failure vocabularies live. (b) is the one that matters:
the proposal's own approach section says `Services/Scoring/` must stay the scoring pipeline and
"nothing in it acquires an audit import", and D11's arch test enforces exactly that — nesting the
audit inside it would make the guard's own path predicate incoherent.

**Class name.** The proposal names the production binding `App\Services\Audit\TypesafeJevJudge`;
the launch brief for this phase called it `TypeSafeAuditJudge`. **`TypesafeJevJudge` wins** — it is
the ratified artifact's name, it names the *model* (Jev) rather than the vendor tier, which is what
`judge_model_version` records per run, and `AnthropicLLMProvider` already sets the precedent of
treating a vendor name as a single PascalCase word.

### D2 — The `AuditJudge` contract: one call per competency, keyed by indicator, never positional

**Choice.**

```php
namespace App\Contracts;

use App\DTOs\Audit\AuditBatchResult;
use App\DTOs\Audit\AuditRequest;
use App\Exceptions\Audit\AuditJudgeException;

interface AuditJudge
{
    /**
     * Judge whether each subject's persisted excerpts and explanation support
     * its persisted score.
     *
     * @throws AuditJudgeException on transport failure, non-2xx, or an
     *                             unparseable envelope. NEVER on a per-subject
     *                             problem — a missing or malformed verdict is
     *                             reported by its ABSENCE from the result map.
     */
    public function judge(AuditRequest $request): AuditBatchResult;
}
```

```php
namespace App\DTOs\Audit;

/** The ENTIRE state that may leave BEAI for one indicator (AD-6). */
final readonly class AuditSubject
{
    /** @param list<string> $excerpts */
    public function __construct(
        public int $indicatorScoreId,   // LOCAL correlation key — never serialized
        public int $position,
        public string $indicatorText,
        public int $score,
        public string $explanation,
        public array $excerpts,
    ) {}
}

final readonly class AuditRequest
{
    /** @param list<AuditSubject> $subjects */
    public function __construct(public string $competencyCode, public array $subjects) {}
}

final readonly class AuditVerdict
{
    /** @param array<string, float> $questionProbabilities keyed by question id */
    public function __construct(
        public int $indicatorScoreId,
        public float $supportProbability,
        public array $questionProbabilities,
    ) {}
}

final readonly class AuditBatchResult
{
    /** @param array<int, AuditVerdict> $verdicts keyed by indicatorScoreId */
    public function __construct(
        public array $verdicts,
        public int $inputTokens,
        public int $outputTokens,
        public string $judgeModel,
        public int $latencyMs,
    ) {}
}
```

**Batching.** One `judge()` call per competency, carrying that competency's judgeable indicators —
the proposal's stated assumption 3, mirroring `PromptBuilder`'s own batching shape. Nothing in the
schema depends on it: changing to per-indicator requests is a change inside `app/Services/Audit/`
with no migration.

**`indicatorScoreId` is a LOCAL key and is never serialized.** `JevRequestBuilder` assigns each
subject an ordinal question key (`i1`, `i2`, …) scoped to the request and keeps the ordinal →
`indicatorScoreId` map in memory; `JevResponseMapper` inverts it. Sending a database id to a third
party would leak an internal identifier into a vendor's logs and make two requests correlatable
across tenants for no benefit — and the skill's own guidance is that question ids exist for code.

**Alternatives considered.** (a) Return a positional `list<AuditVerdict>` and map back by index.
(b) Throw on a missing per-subject verdict. (c) Return `null` for the whole batch on any problem.

**Rationale.** (a) is the exact fragility `EvaluationParser` already documents ("position-based
mapping", C9 D4 FIX-8) and pays for with `IndicatorCountMismatchException`. Here we hold real ids,
so there is no reason to reintroduce it: a verdict for a subject that was never sent, or a missing
verdict for one that was, is detected structurally rather than by counting. (b) collapses AD-3: one
unusable verdict would cost every sibling in the same competency its judgment. (c) is the same
mistake at batch scale.

**Three Noul questions per subject, one persisted probability, three persisted raws.** The
validated spike asked three Noul questions per indicator; the three that matter are independently
useful and name the three distinct ways a score can be unsupported:

| id | judgment |
|---|---|
| `relevance` | the quoted excerpts are evidence of *this indicator's* behaviour at all |
| `calibration` | the evidence supports the *level* the score asserts |
| `grounding` | the explanation asserts nothing the quoted excerpts do not show |

`support_probability = min(relevance, calibration, grounding)` — the weakest link. It is a
conservative, explainable definition (and, by Fréchet, an upper bound on the probability that all
three hold, so it never over-claims support). All three raws are persisted alongside it as a
numeric-only JSON object.

**Alternatives considered.** (a) One Noul, one probability, no raws. (b) Three probabilities, three
columns, no composed value. (c) Persist only the composed value.

**Rationale.** (a) would make v1's cost measurement incomparable to the only spike we have, which
is AD-1's whole purpose. (b) widens the schema and the read surface for a composition need nobody
has validated, and the proposal's Modified Capability text names a single support probability. (c)
breaks the proposal's own stated mitigation — *"v1 persists the raw probability so a threshold
change is a display change and reruns nothing"*. Discarding the raws means a later change to the
composition rule requires re-paying for every run ever made. The raws are numbers, not text, so
AD-6's "probability and machine reason codes only" holds literally.

### D3 — `TypesafeJevJudge`: raw `Http`, three classes, and the one class that may be wrong

**Choice.** `TypesafeJevJudge` mirrors `AnthropicLLMProvider` structurally, line for line where the
shape allows:

```php
final class TypesafeJevJudge implements AuditJudge
{
    public function __construct(
        private readonly JevRequestBuilder $builder = new JevRequestBuilder,
        private readonly JevResponseMapper $mapper = new JevResponseMapper,
    ) {}

    public function judge(AuditRequest $request): AuditBatchResult
    {
        [$body, $keyMap] = $this->builder->build($request);   // pure

        $startMs = (int) round(microtime(true) * 1000);

        try {
            $response = Http::withHeaders($this->buildHeaders())
                ->timeout((int) config('scoring.audit.timeout_seconds', 30))
                ->post($this->buildUrl(), $body);
        } catch (\Throwable $e) {
            throw new AuditJudgeException('TypeSafe transport error: '.$e->getMessage(), retryable: true, previous: $e);
        }

        if (! $response->successful()) {
            throw new AuditJudgeException(
                "TypeSafe returned HTTP {$response->status()}",   // NO body — see below
                retryable: $response->status() >= 500,
            );
        }

        return $this->mapper->map($response->json(), $keyMap, (int) round(microtime(true) * 1000) - $startMs);
    }
}
```

**The one deliberate divergence from `AnthropicLLMProvider`: the response body is NOT put into the
exception message.** `AnthropicLLMProvider` interpolates `{$body}` at `:87`. Here the request body
contains verbatim candidate speech, and a vendor error frequently echoes the request — the message
would land in the log. `ScoreEvaluationJob` already states this rule for the sibling case at
`:735-737`: *"The reason is a machine key, never `$e->getMessage()`: a provider error can echo
prompt content, and prompts contain candidate answers."* Status code only.

**Three classes, not one.** `JevRequestBuilder` (pure: `AuditRequest` → `[array $body, array
$keyMap]`) and `JevResponseMapper` (pure: `array $json, array $keyMap, int $latencyMs` →
`AuditBatchResult`) hold everything vendor-shaped. They have no facades, no `Log`, no config reads
beyond the judge id, and are unit-testable without an HTTP fake. **This is the containment C-C
depends on**: when the live API shape turns out to differ from the guess, exactly these two files
change.

**Response mapping rules** (`JevResponseMapper`), stated because they decide what `malformed` means:

| condition | outcome |
|---|---|
| envelope unparseable / not an object | `AuditJudgeException` (whole batch → `unavailable`) |
| a subject's ordinal key absent from the answers | that subject omitted from `verdicts` → `malformed` / `verdict_missing` |
| any of its three probabilities absent or non-numeric | omitted → `malformed` / `verdict_unparseable` |
| any probability outside `[0,1]` | omitted → `malformed` / `probability_out_of_domain` |
| answers present for keys never sent | ignored, and logged at `warning` |

**`FakeAuditJudge`** mirrors `FakeLLMProvider` exactly: constructor-configured canned verdicts, a
`getCalls()` recorder, `callCount()`, and `httpRequestCount()` returning a hard `0`. The recorder is
load-bearing for two of the proposal's success criteria — *"was never passed to the judge (asserted
on the fake's recorded calls)"* — so it records the full `AuditRequest`, not a summary. It also
supports a per-competency throw (`throwOn(string $competencyCode)`) so the mid-run failure test is
expressible without an HTTP fake.

**Binding**, in `AppServiceProvider::register()` immediately below the `LLMProvider` block
(C-B):

```php
if ($this->app->environment('testing')) {
    $this->app->bind(AuditJudge::class, FakeAuditJudge::class);
} else {
    $this->app->bind(AuditJudge::class, TypesafeJevJudge::class);
}
```

**No SDK, no D25 entry, no `composer.json` diff.** The Dependency Resolution Policy is not
triggered because no dependency is added — the same statement `AnthropicLLMProvider`'s docblock
makes for itself.

### D4 — Schema: two append-only tenant tables, four CHECKs, one identity

**Choice.** Two migrations, in one slice (P2). Both tables are append-only in the
`ai_requests` sense: `created_at` only, `useCurrent()`, no `updated_at`, `$timestamps = false`,
`const CREATED_AT = 'created_at'`.

```
─── indicator_score_audit_runs ─────────────────────────────────────────────────
id                        bigIncrements
organization_id           FK organizations          cascadeOnDelete
evaluation_id             FK evaluations            cascadeOnDelete   NOT NULL
requested_by_user_id      FK users                  nullOnDelete      nullable
status                    string(16)                NOT NULL
failure_reason            string(64)                nullable
indicators_total          unsignedInteger           NOT NULL
indicators_judged         unsignedInteger           NOT NULL
indicators_skipped        unsignedInteger           NOT NULL
indicators_unavailable    unsignedInteger           NOT NULL
indicators_malformed      unsignedInteger           NOT NULL          -- C-D
input_tokens              unsignedInteger           NOT NULL
output_tokens             unsignedInteger           NOT NULL
estimated_cost_usd        decimal(12,6)             nullable          -- D8
latency_ms                unsignedInteger           NOT NULL
judge_model_version       string(64)                NOT NULL
audit_prompt_version      string(32)                NOT NULL
created_at                timestamp useCurrent()

CHECK indicator_score_audit_runs_status_check
      status IN ('completed','partial','failed')
CHECK indicator_score_audit_runs_failure_reason_check
      (status <> 'completed') = (failure_reason IS NOT NULL)
CHECK indicator_score_audit_runs_coverage_check
      indicators_total = indicators_judged + indicators_skipped
                       + indicators_unavailable + indicators_malformed
CHECK indicator_score_audit_runs_cost_check
      estimated_cost_usd IS NULL OR estimated_cost_usd >= 0
INDEX (organization_id, evaluation_id, created_at)          -- D22 org-first

─── indicator_score_audits ─────────────────────────────────────────────────────
id                        bigIncrements
organization_id           FK organizations          cascadeOnDelete
audit_run_id              FK indicator_score_audit_runs   cascadeOnDelete
indicator_score_id        FK indicator_scores             cascadeOnDelete
status                    string(16)                NOT NULL
support_probability       decimal(5,4)              nullable
question_probabilities    jsonb                     nullable
outcome_reason            string(48)                nullable          -- C-E
created_at                timestamp useCurrent()

CHECK indicator_score_audits_status_check
      status IN ('judged','unavailable','malformed','skipped')
CHECK indicator_score_audits_probability_check
      (status = 'judged') = (support_probability IS NOT NULL)
CHECK indicator_score_audits_reason_check
      (status = 'judged') = (outcome_reason IS NULL)
CHECK indicator_score_audits_probability_domain_check
      support_probability IS NULL OR (support_probability >= 0 AND support_probability <= 1)
UNIQUE (audit_run_id, indicator_score_id)
INDEX  (organization_id, indicator_score_id)                -- D22 org-first
```

The two equivalence CHECKs are written in the identical shape as
`indicator_scores_unassessable_reason_check` — `(score = -1) = (unassessable_reason IS NOT NULL)`
(`2026_08_25_000002_add_unassessable_reason_to_indicator_scores.php:59-62`) — and exist for the
identical reason: an equivalence, not an implication, so a `judged` row with no probability and a
`skipped` row carrying one are *both* rejected.

**The status columns carry a value-enumerating CHECK; the reason columns deliberately do not.**
This asymmetry is not an oversight and it diverges from `unassessable_reason`'s stated policy, so
it is argued: the equivalence CHECKs are written against the literal `'judged'`, which means an
unrecognised status value would be silently admitted as "not judged" and would corrupt the run
counters in a way nothing detects. The status vocabulary must therefore be closed at the database.
The reason vocabulary must *not* be — the `unassessable_reason` migration's own docblock states why
(`:18-21`): "UNCONSTRAINED to specific values … so the vocabulary MAY extend later without a
migration".

**The coverage identity is a CHECK, not only a test.** The proposal asserts it by test; a
constraint costs nothing, fails at the write rather than in CI, and — because the run row is
inserted exactly once, at the end, with every counter known (D6) — is always satisfiable.

**`cascadeOnDelete` from BOTH parents** is deliberate: an audit is deleted when its subject
indicator is purged (AD-2's retention requirement) *and* when its run is deleted, so no dangling
row of either kind is reachable.

**Alternatives considered.** (a) A single table with the cost on the "first" indicator row. (b)
`restrictOnDelete` on `indicator_score_id`. (c) Enforcing coverage in `AuditEvaluationJob` only.

**Rationale.** (a) is refused by the proposal (AD-2) and by arithmetic. (b) would make a retention
purge of `indicator_scores` fail with a FK violation, turning an advisory feature into a blocker on
a GDPR obligation. (c) puts a data invariant in the one place a future second writer would not
look.

### D5 — The skip rule tests `score === -1` FIRST

**Choice.**

```php
// Order is load-bearing. See below.
if ($indicator->score === -1) {
    return $this->skipped($indicator, AuditOutcomeReason::UnassessableByConstruction);
}

if ($indicator->excerpts === []) {
    return $this->skipped($indicator, AuditOutcomeReason::AssessedWithoutExcerpts);
}

// judgeable
```

On today's write paths the two predicates are interchangeable, and the proposal's table is
exhaustive: `IndicatorScoreDTO::asUnassessable()` (`:48-58`) **drops excerpts to `[]`** on every
path that produces a `-1`, and its docblock states why — *"persisting a non-verbatim excerpt would
store model-invented text in the field whose entire contract is 'verbatim from the transcript'"*.
`indicator_scores_unassessable_reason_check` then makes `score = -1` and
`unassessable_reason IS NOT NULL` equivalent at the database, so keying on the score is equivalent
to keying on the reason.

The ordering exists for the case the proposal's table does not enumerate: a `-1` row that somehow
carries excerpts. It cannot be written today, but if it ever appears it is a `-1` whose cited
evidence was, by the only mechanism that produces such rows, **evidence that failed the verbatim
check** — model-invented text. Handing that to a judge and asking whether it supports the score is
the one thing this feature must never do. Testing the score first makes the anomalous row skip as
`unassessable_by_construction` instead of being judged.

**Every skipped indicator still gets a row** (AD-4), which is what makes the coverage identity
reconcile and what lets an operator read *"12 judged, 3 skipped — no evidence to check"* rather than
wonder where three indicators went.

### D6 — The run is one terminal transaction, and the cost this trades away is named

**Choice.** `AuditEvaluationJob` buffers verdicts in memory and writes the run row plus every
indicator row in **one** `DB::transaction()` at the end, run first (the audits need its id).

```
for each competency:
    partition indicators → skipped[] (D5) | judgeable[]
    if judgeable is empty: continue
    try:
        result = judge->judge(new AuditRequest(code, judgeable))
        accumulate tokens, latency
        for each judgeable subject:
            verdict present? → judged(p, raws) : malformed(reason)
    catch (Throwable):                       # AD-3, per-competency isolation
        for each judgeable subject: unavailable(reason from exception class)
        runFailureReason ??= 'judge_unavailable'

DB::transaction:
    run   = IndicatorScoreAuditRun::create([... counters, tokens, cost, versions ...])
    audits= IndicatorScoreAudit::create(...) for every buffered verdict
```

**This deliberately does NOT follow C13's `recordAiRequest`-before-the-transaction doctrine, and
the difference is argued rather than assumed.** That doctrine exists because nesting an
irreversible billed fact inside a revocable local transaction "failed in the direction that HIDES
cost" (`ScoreEvaluationJob.php:792-805`). Here the constraint runs the other way: the run's cost,
counters and coverage identity are *only knowable at the end*, and the alternative — a third,
per-call table — is scope the proposal explicitly did not take. Two things make the trade
acceptable:

- Every judge call is already wrapped in `try/catch(Throwable)` (AD-3), so the realistic failure
  modes — vendor 5xx, timeout, malformed body, DNS — never reach the buffer-losing path at all.
  They produce rows.
- `$tries = 1` (D7) means a lost run is not silently re-run and re-billed.

**KNOWN CEILING, stated rather than discovered.** A worker kill mid-run — `$timeout` exceeded, OOM,
container restart during deploy — loses the cost record of calls already made. `failed()` writes a
best-effort `failed` run row with all counters at `0` (which satisfies the coverage CHECK:
`0 = 0+0+0+0`), `failure_reason = 'job_killed'`, and releases the lock, so the *attempt* is
recorded even though the *spend* is not. The same class of ceiling is already named explicitly in
this codebase at `ResetUserPasswordCommand.php:151-153`, which is the convention being followed:
name it, do not let a later reader mistake it for a guarantee.

**`failed()` is reachable with no tenant context** (queue workers reset the resolver). It derives
the org from `Evaluation::withoutGlobalScopes()->find($id)` and wraps the write in
`TenantContextScope::runFor()`, mirroring `ScoreEvaluationJob::failed()` (`:976-1005`) including
its "if the org is not derivable, log and skip the tenant-scoped write" branch.

### D7 — In-flight refusal is a Redis lock; the job's `$tries` is 1; the timeout is derived

**Choice.**

```php
public int $tries = 1;                 // NOT 3
public int $timeout = 600;             // 18 × 30s × 1.1 = 594 → 600; must stay < 1260 (C-F)
```

**`$tries = 1`, diverging from `ScoreEvaluationJob::$tries = 3`.** A queue retry of this job
re-pays TypeSafe for *the whole evaluation*. AD-3 already converts every failure mode into a
recorded degraded row rather than a thrown exception, so the only failures that reach the queue's
retry machinery are the ones a retry cannot fix (a killed worker, a bug). Retrying would duplicate
spend to no purpose, and duplicated spend is the specific thing AD-1 exists to keep measurable.

**`$timeout = 600` is derived, not chosen.** `QueueRuntimeInvariant::MAX_ROLE_COMPETENCIES` (18) ×
`config('scoring.audit.timeout_seconds')` (30) × 1.1 = 594. It must remain strictly below
`queue.runtime.worker_timeout` (1260) or the worker refuses to boot (C-F). It does **not** become
the `ceilingCheckClass` — `ScoreEvaluationJob` keeps that role, and nothing about
`QueueRuntimeInvariant` needs to change.

**In-flight detection is `Cache::lock("audit:evaluation:{$evaluationId}", ttl)`**, acquired by the
controller, whose owner token is passed into the job's constructor and released by the job in a
`finally`. TTL = `$timeout + 120` so an orphaned lock self-heals.

**Alternatives considered.** (a) A `running` status on the run row, flipped to terminal at the end.
(b) A `SELECT … WHERE status = 'running'` existence check. (c) `implements ShouldBeUnique`.

**Rationale.** (a) is refused outright: it forces an UPDATE on a table this change is
simultaneously arch-testing as append-only, and "append-only except for the status column" is not
append-only. (b) is a TOCTOU window exactly the width of a double-click — the failure it exists to
prevent. (c) fails in the wrong direction: `ShouldBeUnique` makes the *dispatch* a silent no-op, so
the operator receives 202 and nothing ever happens. A refusal must be visible.

**Redis unavailable ⇒ refuse, not proceed.** If lock acquisition throws, the controller returns
409 `audit_lock_unavailable`. This is the opposite of the M2M guard's fail-safe (`AppServiceProvider.php:236-248`,
which re-queries the DB rather than fail open) and the difference is the consequence: there, failing
closed would lock out a legitimate authenticated client; here, failing open risks paying a vendor
twice for the same evaluation. Fail toward the cheaper mistake.

**No listener, anywhere.** `app/Listeners/` and `app/Events/EvaluationCompleted.php` are diff-free
(AD-1). The job's constructor takes `(int $evaluationId, ?int $requestedByUserId, ?string $lockOwner)`
— an evaluation id, because `EvaluationCompleted` already carries exactly that
(`ScoreEvaluationJob.php:536`: `event(new EvaluationCompleted($evaluation->id))`). A v2 listener is
therefore a class that calls `AuditEvaluationJob::dispatch($event->evaluationId, null, null)` and
nothing else.

### D8 — A separate cost meter, and a NULL cost when the model is unpriced

**Choice.** `App\Support\Observability\AuditRunCostEstimator`, beside `AiRequestCostEstimator`,
reading `config('scoring.audit.cost_rates_usd_per_million')` keyed by the exact judge model id.
It returns `?float` — **`null`, not `0.0`, for an unknown model**.

This is the one place this design deliberately declines to copy `AiRequestCostEstimator`'s
behaviour, and AD-2 is the reason. That estimator returns `0.0` for an unknown model precisely
because *"a zero-cost row is visible in the dashboard as the anomaly it is"* — the anomaly signal
AD-2 forbids this feature from polluting. Reusing `0.0` here would produce a run whose cost reads
as free, in a table whose entire purpose is to answer "what does this cost". `null` says *unpriced*,
which is a different fact from *free*, and it is the doctrine already ratified one change ago:
pluggable-conversation-llm D1 — *"NULL means 'Google does not publish this', and that is a different
fact from zero… the cost is refused, not coerced."*

Token counts are recorded regardless, so an unpriced run still carries the measurement AD-1 needs;
only the dollar figure is withheld until the rate card is filled in (C-C).

**Generalising `AiRequestCostEstimator` to take a rate table was considered and rejected**: it
would put a diff on the scoring meter's class inside a change whose central claim is that the two
meters are separate, and the two classes make materially different promises about an unknown model.

### D9 — The read surface: one key inside the shaper, one sibling outside it, one map parameter

**Choice.** `AdminEvaluationSerializer::serializeCompetencyResult()` gains a third parameter and
exactly one new key per behavior:

```php
private function serializeCompetencyResult(
    CompetencyResult $result,
    array $catalogue = [],
    array $verdicts = [],          // NEW: array<int, IndicatorScoreAudit> keyed by indicator_score_id
): array
```

```php
'behaviors' => $result->indicatorScores->map(fn (IndicatorScore $i): array => [
    'indicator'           => …,          // unchanged
    'score'               => …,          // unchanged
    'explanation'         => …,          // unchanged
    'excerpts'            => …,          // unchanged
    'unassessable_reason' => …,          // unchanged
    'audit'               => $this->serializeAudit($verdicts[$i->id] ?? null),   // NEW
])
```

```php
/** @return array{status: string, support_probability: float|null, reason: string|null} */
private function serializeAudit(?IndicatorScoreAudit $audit): array
{
    return $audit === null
        ? ['status' => 'never_audited', 'support_probability' => null, 'reason' => null]
        : ['status' => $audit->status, 'support_probability' => $audit->support_probability, 'reason' => $audit->outcome_reason];
}
```

**`never_audited` is a serializer-only status and is never a database value.** The DB CHECK
enumerates four; the wire enumerates five. The asymmetry is deliberate and is the Modified
Capability's explicit requirement ("never a missing key"): a row that does not exist cannot carry a
status, and writing a `never_audited` row for every indicator of every evaluation would be a table
that grows with the product and says nothing.

**No band, no threshold, no derived label.** The raw probability goes on the wire and the
backoffice renders it verbatim. This is the ratified `reliability` doctrine (CLAUDE.md ruling 1:
*"No High/Medium/Low bands — render the percentage verbatim"*) applied to the second advisory
number the product has ever had, and it is the doctrine the proposal itself flags as probably
extending here (open item 4). **Consequence: `config/scoring.php` ships NO `support_threshold` key
in v1** — a config key nothing reads is a promise the code does not keep. Add it in the same change
that ratifies a band.

**Run provenance is a `meta.audit` sibling**, not a per-competency key:

```php
public function auditMeta(Participant $participant): ?array   // NEW public method
// → ['run_id', 'status', 'judge_model_version', 'audit_prompt_version', 'created_at',
//    'indicators_total','indicators_judged','indicators_skipped','indicators_unavailable','indicators_malformed']
// → null when the evaluation has never been audited
```

wired through `EvaluationResource`'s new third constructor argument beside `$scoringMeta`, emitted
from `with()` as `meta.audit`. This exactly mirrors how `meta.scoring` already exposes
provenance (D7, bars-full-scale-1-5) and, like `meta.scoring`, it is **absent from the
session-review view** — `SessionEvidenceReader::forSession()` returns competency-level keys only
and already omits `meta.scoring` for the same reason. The invariant AD-7 actually requires —
"the full report and the session-review view emit an identical `audit` object for the same
indicator" — is satisfied because the *verdict* lives inside the single shaper.

**One query for the whole report.** A new private `auditVerdicts(Participant): array` resolves the
latest run once and loads its verdicts keyed by `indicator_score_id`, mirroring
`indicatorCatalogue()`'s stated doctrine — *"One query for the whole report rather than one per
indicator"*. Both `serialize()` and `serializeCompetency()` call it, exactly as both already call
`indicatorCatalogue()`.

**LATEST RUN, not latest verdict per indicator.** These differ, and the difference matters: a later
run may legitimately `skip` an indicator an earlier run judged (its excerpts were purged, say).
Showing the earlier judgment beside the later run's counters would produce a report whose coverage
numbers contradict its own rows. The read surface answers "what did the most recent run conclude",
and the history stays queryable because nothing is ever updated.

**`tests/Unit/Services/Admin/EvaluationKeySetTest.php:85` breaks by design.** That test pins the
literal `behaviors[]` key set and exists precisely to catch this; its expected list gains `'audit'`
in the same commit, and its failure message already instructs the author to update the backoffice
hand-typed interface together with it. This is the P5 RED test.

### D10 — `AuditVerdictReader` is the only class in `app/` that may query either audit table

**Choice.** `App\Support\Admin\AuditVerdictReader`:

```php
public function latestRunFor(int $evaluationId): ?IndicatorScoreAuditRun;
/** @return array<int, IndicatorScoreAudit> keyed by indicator_score_id */
public function verdictsForRun(int $runId): array;
public function hasRunInFlight(int $evaluationId): bool;   // NOT used for the 409 — see D7
```

Both queries run under the ambient tenant scope (both models extend `TenantModel`), never
`withoutGlobalScopes()` — the rule `AdminEvaluationSerializer`'s own docblock states for itself.

**Why a reader at all.** It is what lets the append-only arch guard ban `::where(` and `::find(`
outright, which is how `AiRequestAppendOnlyArchTest` is written and what its failure message
demands: *"read it through a dedicated reader, never mutate it"*. Without a reader the guard would
have to permit reads everywhere and could only ban mutation verbs — measurably weaker, and it would
leave `AdminEvaluationSerializer` growing a fourth private query method.

### D11 — Isolation is enforced by three arch tests, in this codebase's own arch-test idiom

**Choice.** Three new files under `tests/Arch/Audit/`, all following the established
glob + `file_get_contents` + `str_contains` shape (this codebase deliberately does not depend on
`pest-plugin-arch` for these — see `ScoringFormulaIsolationTest`'s docblock).

| File | Asserts |
|---|---|
| `AuditAppendOnlyArchTest.php` | no file under `app/` except the two models and `AuditVerdictReader` contains `IndicatorScoreAudit::where(`, `::find(`, `::query()->update(`, `->save(`, `->update(`, `->delete(`, or the raw-builder mutation forms `DB::table('indicator_score_audits')->update(` / `->delete(` / `->increment(` / `->decrement(` (and the same list for `…AuditRun`). Plus `$timestamps === false` on both models. Copied from `AiRequestAppendOnlyArchTest`, including its raw-query-builder needles. |
| `AuditIsolationArchTest.php` | `MeanCalculator`, `AssessableFractionReliability`, `CompletionGate`, `IndicatorValidator`, `ExcerptValidator`, `EvaluationParser`, `PromptBuilder`, `ScoreEvaluationJob`, `EvaluationPayloadAssembler` contain none of `IndicatorScoreAudit`, `IndicatorScoreAuditRun`, `AuditJudge`, `AuditEvaluationJob`, `Services\Audit`. Extends D9's existing ban one class of metadata further. |
| `AuditNeverReadsTranscriptArchTest.php` | no file under `app/Services/Audit/`, and not `app/Jobs/AuditEvaluationJob.php`, contains `TranscriptAssembler`, `Utterance`, `InterviewSession`, or `Participant`. **This is AD-6 as a property.** |

The existing `tests/Arch/C2/TenantModelArchTest.php` needs **no edit**: both new models extend
`TenantModel`, so they satisfy the structural rule without joining the documented exclusion list.

### D12 — The operator entry point: `POST /api/participants/{id}/evaluation/audit`

**Choice.** `EvaluationAuditController::store()`, in its own route group adjacent to the Admin Read
API block, exactly as `POST /participants/{id}/recover` is (`routes/api.php:446-456`), and for the
same stated reason — it is a WRITE, not a read.

```php
Route::middleware(['auth:api', TenantContext::class])->group(function (): void {
    // Every accepted call fans out into up to 18 paid third-party AI calls — the most
    // expensive per-request primitive in this API. throttle:6,1 follows the cost-primitive
    // precedent already recorded for POST /forgot-password (routes/api.php:107-108),
    // deliberately tighter than the storage-burn routes' 10,1.
    Route::post('/participants/{id}/evaluation/audit', [EvaluationAuditController::class, 'store'])
        ->middleware('throttle:6,1');
});
```

Ordered behaviour, and the status each step owns:

| # | Step | Failure |
|---|---|---|
| 1 | `config('scoring.audit.enabled')` | **409** `{"reason":"audit_disabled"}` |
| 2 | `$this->authorize('audit', Evaluation::class)` — model-less, runs first | **403** (viewer/operator) |
| 3 | `$this->reader->read($id, ParticipantReadScope::Evaluation)` | **404** cross-tenant/unknown; **409** `lifecycle_not_ready` when not `completato` |
| 4 | `Evaluation::where('participant_id', …)->firstOrFail()` (ambient scope) | **404** |
| 5 | `Cache::lock("audit:evaluation:{$id}", $ttl)->get()` | **409** `audit_already_running`; **409** `audit_lock_unavailable` on a Redis throw |
| 6 | `AuditRecorder::record('evaluation.audit_requested', 'evaluation', $evaluation->id, after: […])` | never propagates (its own contract) |
| 7 | `AuditEvaluationJob::dispatch($evaluation->id, $actor?->id, $lock->owner())` | — |
| 8 | `202 {"status":"queued","evaluation_id":N}` | — |

**403 before 404 is deliberate and matches the write precedent.** `ParticipantRecoveryController`
authorizes before resolving (`:48`, documented at `:32-36`) so a `viewer` never learns whether an
id exists. The proposal's success criterion — *"a cross-tenant participant id yields 404, never
403"* — is satisfied by step 3: an **admin** presenting a foreign id passes step 2 and is refused by
`AdminParticipantReader`'s org filter with a `ModelNotFoundException`.

**Step 3 buys the lifecycle gate for free.** `ParticipantReadScope::Evaluation` requires
`completato` with an empty `off_progression` list (`LifecycleReadGate.php:75-78`) — so an audit of
an in-flight or errored participant is refused 409 by machinery that already exists, rather than by
a new rule.

**`EvaluationPolicy::audit(User $user): bool` is admin-only**, diverging from every other ability on
that policy (`viewAny`/`view` admit all three roles). Rationale: those are reads; this spends money
with a third party. It is the same narrowing `ParticipantPolicy::recover()` documents for itself
(`:72-87`), one step further — recovery admits `operator`, an audit does not, because recovery
restores a stuck candidate while an audit is discretionary spend.

**409, not 503, for the kill switch.** 503 signals a transient infrastructure condition that clients
and proxies legitimately retry; `SCORING_AUDIT_ENABLED=false` is a deliberate operator state that
must not be retried. 409 with a `reason` key is also the refusal envelope this codebase already has
(`ParticipantRecoveryController.php:60`), so the backoffice renders one shape for every refusal on
this route.

---

## Data Flow

```
 ADMIN (backoffice)                    api                                   TypeSafe
 ─────────────────                     ───                                   ────────
 [Run audit] ──POST /participants/{id}/evaluation/audit
                       │
                       ├─1 config('scoring.audit.enabled') ────── false ──► 409 audit_disabled
                       ├─2 Gate: EvaluationPolicy::audit ──────── deny ───► 403
                       ├─3 AdminParticipantReader::read(Evaluation) ─────► 404 | 409 lifecycle
                       ├─4 Evaluation (ambient tenant scope) ────────────► 404
                       ├─5 Cache::lock(audit:evaluation:N) ────── held ──► 409 already_running
                       ├─6 AuditRecorder 'evaluation.audit_requested'
                       ├─7 AuditEvaluationJob::dispatch(N, actor, owner)
                       └─8 202 {status:"queued"}
                                    │
                          ┌─────────▼──────────────── queue worker ─────────────────────┐
                          │ Evaluation::withoutGlobalScopes()->find(N)  ← org derivation │
                          │ TenantContextScope::runFor(orgId, …)                         │
                          │   re-check kill switch ─ off ─► no rows, release lock, return│
                          │   CompetencyResult::with('indicatorScores')  (scoped)        │
                          │   for each competency:                                       │
                          │     partition (D5) → skipped[] | judgeable[]                 │
                          │     try  judge->judge(AuditRequest) ──────────────────────────► POST
                          │     catch Throwable → all judgeable = unavailable   ◄──────────  verdicts
                          │   DB::transaction:                                           │
                          │     IndicatorScoreAuditRun::create(counters, tokens, cost)   │
                          │     IndicatorScoreAudit::create(× indicators_total)          │
                          │ finally: Cache::restoreLock(key, owner)->release()           │
                          └──────────────────────────────────────────────────────────────┘

 GET /participants/{id}/evaluation
      AdminEvaluationSerializer::serialize()
        ├─ indicatorCatalogue()   (1 query, existing)
        ├─ auditVerdicts()        (2 queries: latest run, its verdicts — NEW)
        └─ serializeCompetencyResult(result, catalogue, verdicts)
              behaviors[].audit = {status, support_probability, reason}
      EvaluationResource::with() → meta.scoring (existing) + meta.audit (NEW)
```

---

## Multi-Tenancy: every query scope, explicit

`openspec/config.yaml` → `rules.design`: *"every query scope must be explicit in the design"*.

| Query | Context | Scope mechanism |
|---|---|---|
| `Evaluation::withoutGlobalScopes()->find($evaluationId)` | job, step 1 | **Unscoped by necessity** — this read *derives* the org; no context exists yet. Identical shape and justification to `ScoreEvaluationJob.php:149` / `:209`. No write occurs before the scope is established. |
| everything else in the job | inside `TenantContextScope::runFor($orgId, …)` | Ambient `TenantScoped` global scope. **Deliberately NOT `withoutGlobalScopes()`** — `ScoreEvaluationJob`'s unscoped reads predate `TenantContextScope`; a new job has no such legacy, and queued-job-tenancy D3 established the wrapper so scoped reads work inside jobs. |
| `IndicatorScoreAuditRun::create()`, `IndicatorScoreAudit::create()` | job transaction | `TenantScoped::creating` stamps `organization_id` **unconditionally** from the resolver and throws `MissingTenantContextException` when none is set (`TenantScoped.php:70-83`). `organization_id` is absent from both `$fillable` lists, so it cannot be mass-assigned. |
| `AdminParticipantReader::read()` | controller | Explicit `where('organization_id', $resolver->getOrgId())->findOrFail()` — `Participant` is **not** a `TenantModel`. |
| `Evaluation::where('participant_id', …)` | controller | Ambient scope (`Evaluation extends TenantModel`) **plus** the participant already org-verified in the previous step. |
| `AuditVerdictReader::latestRunFor()` / `verdictsForRun()` | serializer | Ambient scope on both models; never `withoutGlobalScopes()`, per `AdminEvaluationSerializer`'s own docblock rule. |
| `Cache::lock("audit:evaluation:{$evaluationId}")` | controller + job | The evaluation id is globally unique and already org-verified before the lock is taken, so no tenant prefix is needed. Two tenants cannot collide on one id. |

**Cross-tenant test scenarios required** (`rules.specs`): a foreign `participant_id` on the audit
route returns 404 (never 403, never 409); a foreign evaluation's audit rows are invisible to
`AuditVerdictReader` under another org's context; `organization_id` is absent from both `$fillable`
lists; a raw insert with a foreign `organization_id` is overwritten by the `creating` stamp.

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Contracts/AuditJudge.php` | Create | `judge(AuditRequest): AuditBatchResult` (D2) |
| `api/app/DTOs/Audit/{AuditSubject,AuditRequest,AuditVerdict,AuditBatchResult}.php` | Create | Readonly DTOs; `AuditSubject` is the entire AD-6 egress surface |
| `api/app/Enums/Audit/{AuditRunStatus,AuditVerdictStatus,AuditOutcomeReason}.php` | Create | Backed string enums; vocabularies in C-E |
| `api/app/Exceptions/Audit/AuditJudgeException.php` | Create | `retryable` flag; mirrors `AnthropicException` |
| `api/app/Services/Audit/TypesafeJevJudge.php` | Create | Raw `Http`, no SDK; status-code-only error messages (D3) |
| `api/app/Services/Audit/JevRequestBuilder.php` | Create | Pure. `AuditRequest` → `[body, ordinal⇄id map]` |
| `api/app/Services/Audit/JevResponseMapper.php` | Create | Pure. Per-subject absence ⇒ `malformed` (D3) |
| `api/app/Testing/FakeAuditJudge.php` | Create | Default test binding; records calls; `throwOn(code)` |
| `api/app/Support/Observability/AuditRunCostEstimator.php` | Create | Own rate table; `?float`, NULL when unpriced (D8) |
| `api/app/Providers/AppServiceProvider.php` | Modify | `AuditJudge` binding below the `LLMProvider` `if/else` (`:55-61`); `Gate::policy` needs no change |
| `api/config/scoring.php` | Modify | New `audit` block (D13) |
| `api/tests/Unit/Config/AuditConfigTest.php` | Create | Pins shipped defaults, `TruncationRetryConfigTest` idiom |
| `api/database/migrations/*_create_indicator_score_audit_runs_table.php` | Create | Run grain + 4 CHECKs (D4) |
| `api/database/migrations/*_create_indicator_score_audits_table.php` | Create | Indicator grain + 4 CHECKs + UNIQUE (D4) |
| `api/app/Models/IndicatorScoreAuditRun.php` | Create | `extends TenantModel`, `$timestamps=false`, `hasMany(IndicatorScoreAudit)` |
| `api/app/Models/IndicatorScoreAudit.php` | Create | `extends TenantModel`, `$timestamps=false`, `belongsTo` run + indicatorScore |
| `api/database/factories/{IndicatorScoreAuditRunFactory,IndicatorScoreAuditFactory}.php` | Create | `AiRequestFactory` shape; states `judged`/`skipped`/`unavailable`/`malformed` |
| `api/app/Jobs/AuditEvaluationJob.php` | Create | `$tries=1`, `$timeout=600`, default queue (C-F, D6, D7) |
| `api/app/Http/Controllers/Api/EvaluationAuditController.php` | Create | 8-step order in D12 |
| `api/app/Policies/EvaluationPolicy.php` | Modify | `audit()` — admin only |
| `api/routes/api.php` | Modify | One route, own group, `throttle:6,1` |
| `api/app/Support/Admin/AuditVerdictReader.php` | Create | The only reader of either table (D10) |
| `api/app/Services/Admin/AdminEvaluationSerializer.php` | Modify | `$verdicts` param + `behaviors[].audit` + public `auditMeta()` (D9) |
| `api/app/Http/Resources/Admin/EvaluationResource.php` | Modify | Third ctor arg `$auditMeta`; `with()` emits `meta.audit` |
| `api/app/Http/Controllers/Api/ParticipantController.php` | Modify | `evaluation()` passes `auditMeta($participant)` |
| `api/tests/Unit/Services/Admin/EvaluationKeySetTest.php` | Modify | Expected `behaviors[]` list gains `'audit'` — the P5 RED (D9) |
| `api/tests/Arch/Audit/{AuditAppendOnly,AuditIsolation,AuditNeverReadsTranscript}ArchTest.php` | Create | D11 |
| `api/openapi.json` | Modify | Re-export against **Postgres**, never SQLite |
| `backoffice/app/composables/useEvaluationReport.ts` | Modify | `EvaluationBehavior.audit`, `EvaluationAuditMeta` |
| `backoffice/app/composables/useEvaluationAudit.ts` | Create | `POST …/evaluation/audit`; typed 409 reasons |
| `backoffice/app/components/atoms/AuditFlag.vue` | Create | Net-new review-status affordance |
| `backoffice/app/components/molecules/IndicatorEvidence.vue` | Modify | `<AuditFlag>` beside `<ScoreChip>` in the trigger |
| `backoffice/app/components/organisms/EvaluationAuditPanel.vue` | Create | Trigger button + run status + refusal rendering |
| `backoffice/i18n/locales/{en,it}.json` | Modify | `report.audit.*`, authored not machine-translated |
| `api/app/Jobs/ScoreEvaluationJob.php`, `app/Services/Scoring/*`, `app/Support/Prompting/PromptBuilder.php` | **Unchanged** | AD-7; arch-tested (D11) |
| `api/app/Models/AiRequest.php` + its three migrations | **Unchanged** | AD-2 — separate meter |
| `api/app/Services/Webhooks/EvaluationPayloadAssembler.php` | **Unchanged** | AD-7 |
| `api/app/Events/EvaluationCompleted.php`, `app/Listeners/*` | **Unchanged** | AD-1 — no listener in v1 |
| `backoffice/app/components/atoms/ScoreChip.vue`, `molecules/ExcerptList.vue` | **Unchanged** | `ScoreChip` keeps encoding score only |
| `frontend/*` | **Unchanged** | No candidate-facing audit surface |

---

## Interfaces / Contracts

### D13 — `config/scoring.php` → `audit`

**Choice.** The block lives in `config/scoring.php`, `truncation_retry`-shaped, with a
`tests/Unit/Config/AuditConfigTest.php` pinning the shipped defaults the way
`TruncationRetryConfigTest` does.

```php
'audit' => [
    // Kill switch (AD-1). In v1 "enabled" means an OPERATOR MAY ASK — never
    // that the platform spends. false makes the route refuse (409
    // audit_disabled) and an already-dispatched job no-op with zero rows.
    'enabled' => (bool) env('SCORING_AUDIT_ENABLED', true),

    // NEVER hardcode. Provisioned in Railway `api` production.
    'api_key' => env('TYPESAFE_API_KEY', ''),
    'base_url' => env('TYPESAFE_BASE_URL', 'https://api.typesafe.ai'),

    // The EXACT vendor model id, recorded verbatim on every run as
    // judge_model_version. Placeholder until C-C's verification task lands —
    // an alias would silently repoint and the judgment history would stop
    // meaning anything (config/scoring.php:69-73's own reasoning).
    'judge_model' => env('SCORING_AUDIT_JUDGE_MODEL', 'jev-1'),

    // Semver for the audit question set. Bump on ANY edit to the three Noul
    // questions — the scoring prompt_version idiom, one grain over.
    'prompt_version' => env('SCORING_AUDIT_PROMPT_VERSION', '1.0.0'),

    // Per-request Http timeout. Feeds AuditEvaluationJob::$timeout's derivation
    // (D7) — raising it above ~63s breaks QueueRuntimeInvariant's assertion A.
    'timeout_seconds' => (int) env('SCORING_AUDIT_TIMEOUT', 30),

    // Own meter. NEVER summed into scoring.cost_rates_usd_per_million (AD-2).
    // An unknown model yields NULL, not 0.0 (D8).
    'cost_rates_usd_per_million' => [
        // 'jev-1' => ['input' => ?, 'output' => ?],   // pending C-C
    ],
],
```

**Why `config/scoring.php` and not a new `config/audit.php`.** Three reasons, and the third is
decisive: the proposal already names `config('scoring.audit')` in AD-1; the shipped-defaults test
convention and its sibling (`TruncationRetryConfigTest`) live around this file; and **`config/audit.php`
would collide semantically with the `audit_logs` / `AuditRecorder` domain that already exists** —
two unrelated meanings of "audit" in one config namespace is the kind of confusion that costs an
afternoon. Config namespacing is not a dependency direction, so nothing about it weakens D11's
arch-tested ban on the scoring pipeline importing audit types.

**No `support_threshold`, no `batch_size` in v1** (D9, D2).

`.env.example` gains `SCORING_AUDIT_ENABLED`, `TYPESAFE_API_KEY=`, `SCORING_AUDIT_JUDGE_MODEL`,
`SCORING_AUDIT_PROMPT_VERSION`, `SCORING_AUDIT_TIMEOUT`. Note the standing
`config`↔`.env.example` parity guard convention that already exists for `SCORING_PROMPT_VERSION`
(`config/scoring.php:102-108`): if a parity test is added for `audit.prompt_version`, both defaults
must be bumped together, and a deploy environment that sets the variable explicitly overrides both
and must be bumped separately.

### Wire payload sketch — UNVERIFIED (C-C)

Recorded so the verification task has something concrete to confirm or correct. Built from the
TypeSafe skill's described programming model (state / instructions / criteria, Noul returning a
probability of yes), **not from the live API reference**:

```jsonc
{
  "model": "jev-1",
  "state": {
    "competency_code": "COL",
    "indicators": [
      { "key": "i1",
        "indicator": "Shares information proactively with peers outside their own team.",
        "assigned_score": 4,
        "scale": "1 to 5, where higher means stronger demonstration of the indicator",
        "explanation": "…",                    // persisted, verbatim
        "excerpts": ["…", "…"] }                // persisted, verbatim candidate speech
    ]
  },
  "questions": [
    { "id": "i1.relevance",   "type": "noul",
      "instructions": "The excerpts in `state.indicators[0].excerpts` describe behaviour of the kind `state.indicators[0].indicator` names." },
    { "id": "i1.calibration", "type": "noul",
      "instructions": "The excerpts support a rating of `state.indicators[0].assigned_score` on `state.indicators[0].scale`, rather than a materially lower one." },
    { "id": "i1.grounding",   "type": "noul",
      "instructions": "Every claim in `state.indicators[0].explanation` is shown by the excerpts, with nothing asserted that they do not contain." }
  ]
}
```

**What is in this payload, exhaustively:** an indicator's catalogue text, an integer, a scale
description, the scorer's own explanation, and the excerpts already persisted on that row. **What is
not:** the transcript, the participant, a name, an email, `candidate_ref`, a project, an
organization, or any database identifier.

---

## Testing Strategy

Strict TDD (`openspec/config.yaml` → `strict_tdd: true`), vertical slices, every RED before its
GREEN. Coverage ≥ 85% overall; ~95% on the job's state machine and on tenancy scoping
(`coverage_high_integrity`).

| Layer | What to test | Approach |
|---|---|---|
| Unit — config | shipped `scoring.audit` defaults; `api_key` default is `''` | `tests/Unit/Config/AuditConfigTest.php`, `TruncationRetryConfigTest` idiom |
| Unit — pure | `JevRequestBuilder` emits ordinal keys and **no** `indicatorScoreId`; payload contains no transcript/participant field | Plain assertions, no HTTP |
| Unit — pure | `JevResponseMapper`: missing key ⇒ omitted; non-numeric ⇒ omitted; `p > 1` ⇒ omitted; extra keys ignored; `min()` composition | Table-driven |
| Unit — cost | `AuditRunCostEstimator` returns `null` (not `0.0`) for an unknown model; 6dp rounding | Mirrors `AiRequestCostEstimatorTest` |
| Unit — transport | `TypesafeJevJudge` maps 5xx ⇒ `retryable: true`, 4xx ⇒ `false`, transport throw ⇒ retryable; **message contains no response body** | `Http::fake()` |
| Feature — DB | raw insert of `judged` + NULL probability rejected; `skipped` + probability rejected; `judged` + non-null reason rejected; probability `1.5` rejected; counters that do not sum rejected; unknown status rejected | `DB::statement` against Postgres — a CHECK is not testable through Eloquent |
| Feature — job | judge throws on competency 3 of 5 ⇒ every indicator of all five has a row, competency 3's `unavailable`, run `partial`, identity holds, **job does not throw** | `FakeAuditJudge::throwOn('…')` |
| Feature — job | every `score = -1` indicator is `skipped`/`unassessable_by_construction` and **was never passed to the judge** | Asserted on `FakeAuditJudge::getCalls()`, not on output |
| Feature — job | `score ∈ {1..5}` with `excerpts = []` ⇒ `skipped`/`assessed_without_excerpts` | — |
| Feature — job | `SCORING_AUDIT_ENABLED=false` ⇒ zero rows, zero judge calls, lock released | Config override |
| Feature — job | re-auditing creates a **new** run; the earlier run and its audits are unchanged | Row-count + id assertions |
| Feature — job | tenancy: rows carry the evaluation's org even with the resolver reset; a foreign org reads nothing | `TenantContextScope` + resolver flip |
| Feature — job | deleting an `IndicatorScore` deletes its audits; deleting the run deletes its audits | Cascade assertions |
| Feature — invariance | `indicator_scores`, `competency_results`, `evaluations` are **byte-identical** before and after a run; `ai_requests` gains no row | Snapshot compare |
| Feature — route | 409 `audit_disabled`; 403 for viewer/operator; 404 for a cross-tenant id (**never 403**); 409 `lifecycle_not_ready` for a non-`completato` participant; 409 `audit_already_running` on a second call; 202 on success; `Queue::fake()` asserts one dispatch | `actingAs` + `Queue::fake()` |
| Feature — route | `evaluation.audit_requested` audit row records actor, subject type `evaluation`, subject id | `AuditLog` assertions |
| Feature — serializer | full report and session-review view emit a **byte-identical** `audit` object for the same indicator | Two call sites, one `expect(...)->toBe(...)` |
| Feature — serializer | an evaluation never audited emits `status: "never_audited"` on **every** behavior, never a missing key; `meta.audit` is `null` | — |
| Unit — key set | `behaviors[]` key set equals the explicit list **including `audit`** | `EvaluationKeySetTest` (the P5 RED) |
| Arch | append-only; scoring-formula isolation; no transcript type reachable from `Services/Audit` or the job | D11 |
| Arch (existing) | `QueueRuntimeConfigTest` — `AuditEvaluationJob::$timeout` enters assertion A automatically | No edit; the number must be < 1260 |
| Vitest | `AuditFlag.vue` renders each of the five statuses; probability rendered verbatim with no band; `never_audited` renders as "not audited", never as "no issues" | Vue Test Utils |
| Vitest | `useEvaluationAudit` maps each 409 reason to its own message | Fetch mock |
| Playwright | operator triggers a run and sees the run-status state change; Chromium + WebKit; **no** mobile/viewport project (backoffice has no gate) | Existing backoffice config |
| `@ai` group | the ONLY real-vendor coverage; see Dependencies — it must not be added to an already-red workflow | `workflow_dispatch` lane |

**The default test binding is `FakeAuditJudge`**, so no ordinary test can reach
`https://api.typesafe.ai` — structurally, by container binding, exactly as `FakeLLMProvider`
guarantees it for Anthropic.

---

## Threat Matrix

The matrix in `references/threat-matrix.md` targets shell, subprocess, VCS and PR-automation
boundaries. This change has none: it adds one HTTP route, one queued job, one outbound HTTPS call
and two tables. **No row is applicable.**

| Boundary | Applicability | Reason |
|---|---|---|
| Documentation-like paths | **N/A** | No file is read, classified or executed by path. No file input of any kind. |
| Git repository selection | **N/A** | No VCS invocation. No `git` call, no cwd authority. |
| Commit state | **N/A** | No index or worktree interaction. |
| Push state | **N/A** | No remote, ref or refspec resolution. |
| PR commands | **N/A** | No PR automation; no command is composed from input. |

The adversarial boundaries this change *does* have are owned by named decisions rather than by this
matrix, and each already has its RED test above: outbound egress of verbatim candidate speech to a
new sub-processor (D2/D3/D11 + the transcript-isolation arch test), a paid-fan-out endpoint
reachable by a stolen bearer token (D12's `throttle:6,1` and admin-only policy), double-spend on a
double-click (D7's lock), cross-tenant read/write (the multi-tenancy table), and a vendor error body
echoing prompt content into the log (D3).

---

## Migration / Rollout

Six slices, `feature-branch-chain`, delivery strategy `auto-chain`, P1 → P6, each `api` slice
landing before the `backoffice` slice consuming it. **No deploy unless explicitly requested.**

| Slice | Contents | Independently revertable? |
|---|---|---|
| P1 | Contract, DTOs, enums, exception, `TypesafeJevJudge`, `JevRequestBuilder`, `JevResponseMapper`, `FakeAuditJudge`, binding, config block + config test. **Opens with C-C's wire-verification task.** | Yes — nothing reads it |
| P2 | Two migrations, two models, two factories, three arch tests | Yes — tables referenced by nothing |
| P3 | `AuditEvaluationJob` + `AuditRunCostEstimator` | Yes — nothing dispatches it |
| P4 | Route, controller, `EvaluationPolicy::audit`, lock, audit-log event | Yes — removes the only trigger |
| P5 | `AuditVerdictReader`, serializer `audit` key + `auditMeta()`, `EvaluationResource`, `EvaluationKeySetTest`, OpenAPI re-export | Yes — shape returns byte-identical |
| P6 | `backoffice`: types, composable, `AuditFlag`, `IndicatorEvidence`, panel, `en`/`it` | Yes — `bun run codegen` against the still-current `openapi.json` |

**P3 is the tight slice** and may need splitting at `sdd-tasks` time — the proposal already flags
it. A defensible split: **P3a** = the per-competency partition + skip rules + buffer + terminal
transaction with a judge that always succeeds; **P3b** = `Throwable` isolation, degraded rows,
`failed()`, and the coverage reconciliation tests.

**Reverse order P6 → P1.** P3/P2 revert the code and **leave the tables**: they are isolated,
append-only, referenced by nothing, and dropping them destroys the cost evidence AD-1 exists to
gather.

**Emergency, no deploy:** `SCORING_AUDIT_ENABLED=false`. The route refuses and any in-flight job
no-ops with zero partial rows.

**Forward migration only.** No backfill exists or is possible — there is no historical audit data,
and every pre-existing indicator reads `never_audited` at the read surface without a single row
being written (D9).

**After P5:** `DB_CONNECTION=pgsql … php artisan scramble:export` → `task openapi:sync` →
`bun run codegen`, guarded by `bun run codegen:check`. Exporting against SQLite produces a
spec that is wrong, not merely different (`api/CLAUDE.md`).

**Version bumps** follow Git Flow ×4: `api/VERSION` and `composer.json` must agree and `openapi.json`
must be re-exported after the bump because `info.version` is generated from `VERSION`; the two Nuxt
apps each carry their own `VERSION` file that a wrapper guard compares.

---

## Open Questions

Inherited from the proposal, unchanged, both **blocking P1**:

- [ ] **TypeSafe as a sub-processor of candidate personal data.** The excerpts sent to TypeSafe are
      verbatim candidate speech. AD-6 minimises it to the persisted verdict plus its own evidence
      and this design makes that minimisation structural (D2/D11), but the sub-processor question is
      a data-controller decision under CLAUDE.md ruling 2's pending GDPR sign-off. Not taken here.
- [ ] **`TYPESAFE_API_KEY` provisioning and the real-API CI lane.** `ai-integration.yml` is on
      record as already failing on every push with an invalid `ANTHROPIC_API_KEY`. Adding a
      TypeSafe `@ai` group to an already-red workflow buys no signal. Owner decision: fix the
      existing lane, isolate the new group, or defer real-API coverage to `workflow_dispatch` only.

Raised by this design:

- [ ] **The TypeSafe wire contract, model id and rate card are unverified (C-C).** P1's first task
      is a documentation read, and its output is a revision to D2/D3/D13. Until then
      `judge_model = 'jev-1'` is a placeholder and `cost_rates_usd_per_million` is empty, which by
      D8 means every run records `estimated_cost_usd = NULL` — honest, and useless for AD-1's
      measurement gate. **The rate card is therefore a prerequisite for the measurement, not a
      nicety.**
- [ ] **C-D — does the orchestrator accept the four-term coverage identity?** `spec.md` must carry
      `total = judged + skipped + unavailable + malformed`, not the proposal's three-term form.
- [ ] **C-E — does the orchestrator accept `outcome_reason` in place of `skip_reason`?** `spec.md`
      must name the column and its four-status vocabulary.
- [ ] **D9 — v1 ships no threshold and no band**, per ruling 1's ratified precedent. This resolves
      the proposal's non-blocking open item 4 in the "no band at all" direction. If product wants
      bands, that is a later change that adds a config key and a display rule and **reruns nothing**,
      because the raw probabilities are persisted (D2).
- [ ] **D6's known ceiling** — a worker kill mid-run loses the cost record of calls already made.
      Accepted here as proportionate. If AD-1's measurement turns out to be materially affected by
      it, the fix is a per-call cost row, which is a new table and a new change.
