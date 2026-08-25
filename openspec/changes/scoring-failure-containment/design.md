# Design: Scoring Failure Containment

## Technical Approach

Four moving parts, plus three corrections to premises the proposal inherited from `explore.md`
and which do not survive contact with the code. The corrections are stated first because two
of them delete work the proposal budgeted for, and one of them deletes a rollback hazard the
change was being planned around.

1. **Detection** becomes a pure classifier (`ScoringFailureClassifier`) whose enum defaults to
   *terminal*, so D4 FIX-9 is enforced by the shape of the type rather than by a comment (D3).
2. **Parsing** gains one narrow pre-processor (`ResponseEnvelopeStripper`) that can only ever
   turn a hard-fail into a hard-fail or a success — never into a silent mis-parse (D5).
3. **The scoring loop** splits into an *envelope* phase that may throw and a *per-indicator*
   phase whose `try` lives inside the loop, with a `count()` post-condition making
   "no sibling is discarded" a checkable property rather than an intention (D7).
4. **The fingerprint** is made unable to hold text by the column types themselves — a
   `CHECK` regex on a `char(64)` is the enforcement; the prose in AD-2 is only the reason (D6).

`MeanCalculator`, `AssessableFractionReliability`, `CompletionGate` and
`IndicatorValidator::LEGAL_SCORES` are untouched, and D9 makes that mechanically verifiable.
`data-retention/spec.md` needs no amendment, and D6 explains why that is a property of the
schema rather than a promise.

---

## Corrections to Inherited Premises

### C-A — There is no value-enumerating CHECK constraint on `ai_requests.failure_reason`

`explore.md:47-49` and AD-3 both state that `AiRequestFailureReason` is "a closed set of 6
enforced by a Postgres CHECK constraint (`ai_requests_failure_reason_check`)", and the whole
A1 slice, its ordering contract and the *only* rollback step with a data precondition were
built on that.

**Verified against the migration.** `2026_07_31_000001_add_cost_conformance_to_ai_requests_table.php:41`
declares `failure_reason` as `string(64)->nullable()`. The constraint that shares its name is
at `:62-65` and reads, in full:

```sql
CHECK ((success = false) = (failure_reason IS NOT NULL))
```

It constrains **presence**, not **value**. `rg` over `database/migrations` for `CHECK (` returns
six constraints across four tables and none of them enumerates a failure reason. The closed set
is enforced in PHP, at the single writer (`ScoreEvaluationJob::recordAiRequest()`), and nowhere
else — exactly as `competency_results.unscorable_reason` is
(`2026_07_22_000002:56` — "Domain values: … " in a comment, `string()->nullable()` in the schema).

**Consequences, all in the change's favour:**

- Adding `AiRequestFailureReason::Truncated` is a **one-case enum edit**. No migration,
  no deploy-ordering contract, no blocking dependency for anything.
- The rollback data precondition described in the proposal (`Rollback Plan`, A1) **does not
  exist**. There is no constraint to narrow, so there are no rows to migrate first.
- The A1 slice loses its reason to exist as a separate PR. The enum case ships with its writer.

**Should we add the enumerating constraint?** No — see D2.

### C-B — The `evaluation` webhook already ships `unscorable_reason`

The proposal lists the webhook payload as out of scope pending a product answer, and the task
brief asks for a versioning decision on *adding* the field. It is already there:
`EvaluationPayloadAssembler::renderText():150-153` emits `unscorable_reason` as an
**additive key present only when the competency is unscorable**, and two tests pin both
directions (`tests/Unit/C10/EvaluationPayloadAssemblerTest.php:172,189`).

So the ratified answer to product question 2 — *the reason reaches the calling system* — is
**already satisfied for the competency-level reason, with zero code change**. What is genuinely
new is (a) the *value set* of that field widening by one, and (b) Increment B adding a
per-indicator key inside `behaviors[]`. D10 decides both.

### C-C — The backoffice does not consume a generated type for this endpoint

The task brief assumes "Scramble/OpenAPI regen plus typed-client regen in `backoffice`".
`backoffice/app/composables/useEvaluationReport.ts:1-14` documents the opposite, explicitly:
the report types are **hand-typed** against `AdminEvaluationSerializer`, because Scramble emits
`EvaluationResource` as `{[key: string]: unknown}` — it cannot infer a passthrough `toArray()`
(the same limitation is already recorded for `DashboardMetricsResource`). Regenerating
`openapi.json` is still correct and still required for the published contract, but it
**propagates nothing** to the backoffice. The hand-typed interface must be edited by hand, and
D11 adds the drift guard that this arrangement has been missing.

---

## Architecture Decisions

### D1 — Two failure vocabularies, deliberately not unified

| Enum | Column | Grain | Audience |
|---|---|---|---|
| `AiRequestFailureReason` (exists) | `ai_requests.failure_reason` | **one provider call** | engineering / cost dashboard |
| `UnscorableReason` (**new type**, existing values) | `competency_results.unscorable_reason` | **one competency, after all attempts** | operator **and** integrator |
| `IndicatorFailureReason` (**new**, Increment B) | `indicator_scores.unassessable_reason` | **one indicator** | operator |

> **Naming note (Phase 0 correction, product owner decision).** This section originally named
> the truncation values `response_truncated`/`llm_response_truncated` and the indicator-grain
> field `failure_reason`. The **approved spec deltas win**: the persisted truncation values are
> `truncated` (`ai_requests.failure_reason`) and `llm_truncated`
> (`competency_results.unscorable_reason`), and the indicator-grain field is named
> `unassessable_reason` — at the DB column, `IndicatorScoreDTO` property, API field, and i18n
> key base — never `reason` (too vague) nor `failure_reason` (misleading: one of its three
> values, `model_declared`, is the model answering honestly, not a failure). All three names
> below are corrected accordingly.

**Choice.** Three distinct types. `AiRequestFailureReason` gains
`Truncated = 'truncated'`. `UnscorableReason` is introduced as a backed enum
holding the three shipped values plus `LlmTruncated = 'llm_truncated'`.

**Alternatives considered.** (a) One shared enum across both columns. (b) Map truncation back
onto `llm_parse_error` at the competency level, keeping the operator-facing set at three.

**Rationale.** (a) is wrong because the grains differ: under D8 a single truncated competency
produces **two** `ai_requests` rows (`truncated`, then whatever the retry yields) and
**one** `CompetencyResult`. A shared type invites a join that means nothing. (b) is the failure
this change exists to remove — telling the operator "could not be read" when the system knows
"was cut off" is the same class of under-reporting as the incident itself.

Widening the operator-facing set to **four** is what obliges the `scoring-engine` Coverage Note
amendment (`spec.md:823-824`), which is deliverable 12 and owned by `sdd-spec`.

### D2 — `UnscorableReason` is an enum in PHP and a plain string in Postgres

**Choice.** Introduce `App\Enums\UnscorableReason` and use it at every **write** site
(`persistUnscorable()`, factories, `DemoWriter`) and as the single source of the value set for
the serializer, the assembler and the backoffice i18n key list. Do **not** add an Eloquent cast,
and do **not** add a value-enumerating `CHECK` to either `unscorable_reason` or
`failure_reason`.

**Alternatives considered.** (a) Enum + `$casts` + a Postgres `CHECK … IN (…)` on both columns.
(b) Leave both as bare strings, as today.

**Rationale.** (a) buys enforcement at the DB and costs a rollback data precondition — the exact
hazard C-A just showed we do not currently have. It also converts a *read* of an unexpected
legacy value into a thrown `ValueError`, and there is at least one out-of-domain legacy value
already named in the codebase (`BarsArithmeticTest:127` asserts no row carries
`no_assessable_evidence`). A report that crashes on a stale row is strictly worse than a report
that renders the stale key loudly — this is D6 of `bars-full-scale-1-5` applied to the
persistence layer instead of the chip. (b) leaves the value set duplicated across the job, the
serializer, the assembler and two locale files, which is how the Coverage Note drifted from the
code in the first place.

The enum is therefore a **write-side and vocabulary** device; reads stay `string|null` and the
backoffice's total function (D12) absorbs anything unrecognised.

### D3 — Truncation detection lives in a classifier whose default arm is terminal

**Choice.** Three small pieces, none of them inside `scoreCompetency()`'s body:

```php
// App\DTOs\LLMResponse — one additive field, defaulted
public bool $truncated = false;

// App\Enums\Scoring\ScoringFailure    — what went wrong, provider-neutral
// App\Enums\Scoring\ScoringDisposition — what we are allowed to do about it
enum ScoringDisposition { case Terminal; case RetryWithLargerBudget; }

final class ScoringFailureClassifier
{
    public function classify(ScoringFailure $failure, int $attemptsAlreadyMade): ScoringDisposition
    {
        return match ($failure) {
            ScoringFailure::ResponseTruncated => $attemptsAlreadyMade < $this->maxAttempts()
                ? ScoringDisposition::RetryWithLargerBudget
                : ScoringDisposition::Terminal,
            default => ScoringDisposition::Terminal,   // D4 FIX-9 — fence, prose,
        };                                             // count mismatch, illegal score,
    }                                                  // non-verbatim excerpt, provider error
}
```

`AnthropicLLMProvider::parseResponse()` sets `truncated: ($data['stop_reason'] ?? '') === 'max_tokens'`
and continues to carry the **raw** `stop_reason` string into `finishReason` unchanged, because
that string is already persisted to `ai_requests.finish_reason` and re-encoding it would rewrite
what historical rows mean. `ScoreEvaluationJob` reads `$llmResponse->truncated` **before**
`$evaluationParser->parse()` and never reads the raw string.

**Alternatives considered.** (a) Throw from `AnthropicLLMProvider` on `stop_reason = max_tokens`.
(b) An inline `if` in `scoreCompetency()`. (c) A `FinishReason` enum on `LLMResponse` with
`EndTurn | MaxTokens | StopSequence | Refusal`.

**Rationale.** (a) is the worst option and worth naming: an exception out of `complete()` skips
`recordAiRequest()` entirely, so a truncated — and **billed** — call would leave no cost row.
That is precisely the violation `observability/spec.md:385-398` was written to close, reintroduced
one layer up. It also duplicates vendor vocabulary into `CassetteLLMProvider` and `FakeLLMProvider`.

(b) works and is smaller, but it buries the single legitimate exception to FIX-9 inside a
200-line method. `explore.md:56-57` already identified `Services/Webhooks/RetryClassifier` as
the right architectural shape; this is that shape, in the scoring namespace.

(c) is rejected for the reason it looks attractive: an enum with five arms is an invitation to
branch on the other four. **The system must make exactly one decision from this signal —
"was the output cut off" — and a boolean is the only surface that cannot answer a second
question.** The raw string remains in `ai_requests` for anyone doing forensics.

**How the carve-out resists misreading.** `ScoringDisposition` has exactly two cases, and
`RetryWithLargerBudget` is reachable from exactly one arm of one `match`. Every other failure —
including any failure class added in future — lands in `default => Terminal`. Adding a
retryable class is therefore not an omission but an *edit to the only line that grants retry*,
which a reviewer sees in the diff. A Pest test asserts the property directly: for every case of
`ScoringFailure` except `ResponseTruncated`, `classify()` returns `Terminal` at every attempt
count — a data-provider loop over `ScoringFailure::cases()`, so a new case added without thought
fails the test rather than sliding through.

### D4 — Truncation is short-circuited before parse, and is its own unscorable reason

**Choice.** In `scoreCompetency()`, immediately after `complete()` returns and before any
parsing:

```
$llmResponse = $llmProvider->complete($fullPrompt, $options);      // attempt 1
if ($llmResponse->truncated) → ScoringFailure::ResponseTruncated
      ├─ RetryWithLargerBudget → D8
      └─ Terminal → recordAiRequest(success:false, AiRequestFailureReason::Truncated)
                    persistUnscorable(UnscorableReason::LlmTruncated)
                    return
```

**Rationale.** A truncated body is not a parse failure that happens to be caused by truncation —
it is a *different fact about a different actor*, and routing it through `json_decode()` is what
made the 2026-08-24 incident undiagnosable. Short-circuiting before the parser also means the
truncation branch is provably unreachable from `EvaluationParser`, so D5's tolerance can never
be blamed for — or accused of masking — a truncation.

`persistUnscorable()` takes `UnscorableReason` instead of `string`; the three existing call sites
change type only.

### D5 — `ResponseEnvelopeStripper`: one predicate, two callers, no partial acceptance

**Choice.** A pure collaborator, called by `EvaluationParser::parse()` and by
`ResponseFingerprint::from()` so that "fenced" has exactly one definition in the codebase:

```php
final readonly class UnwrappedResponse { public string $json; public bool $wasFenced; }

final class ResponseEnvelopeStripper { public function unwrap(string $raw): UnwrappedResponse; }
```

Two rules, both narrow, applied to the trimmed input:

1. **Fence.** If it starts with ``` ``` ``` optionally followed by a language tag on the same
   line, **and** a closing ``` ``` ``` exists, take what is between them. `wasFenced = true`.
2. **Prose.** Otherwise, if it does not already start with `{`, take the substring from the
   first `{` to the last `}` — **but only if the discarded leading and trailing runs contain no
   `{`, `}` or `"`.** If either run contains one of those, strip nothing and let the decode fail.

**Alternatives considered.** (a) Regex-extract the first balanced `{…}` block anywhere in the
body. (b) Try `json_decode`, and on failure retry against progressively trimmed substrings.

**Rationale.** Both alternatives are the "find some JSON in there" salvage routine AD-5 forbids,
and both share one specific danger: given a *truncated* response containing a complete inner
object followed by an incomplete one, they would return the inner object and we would score a
partial answer as if it were whole. Rule 2's brace-and-quote condition rejects exactly that
shape — a truncated body's trailing run is full of `"` and `{`.

The structural safety argument matters more than the rules: **the stripper never validates
anything.** `json_decode()` remains the sole acceptance test, unchanged at
`EvaluationParser.php:46-50`. A stripper that returns garbage produces a `JsonParseException`
identical to today's. There is no partial-acceptance path for the tolerance to leak through, so
the worst case of a stripper bug is the failure we already have — never a silent mis-parse.

Negative fixtures pin this: a body with a fence *and* trailing prose containing a brace, and a
body that is plausible-looking but malformed, both still raise `JsonParseException`.

### D6 — The fingerprint cannot hold text, by column type

**Choice.** Three additive nullable columns on `ai_requests`, written only from
`recordAiRequest()`, only from a value object that structurally cannot carry the response:

| Column | Type | Source |
|---|---|---|
| `response_bytes` | `unsignedInteger` nullable | `strlen($content)` |
| `response_fenced` | `boolean` nullable | `ResponseEnvelopeStripper::unwrap()->wasFenced` |
| `response_sha256` | `char(64)` nullable | `hash('sha256', $content)` |

```php
final readonly class ResponseFingerprint
{
    private function __construct(
        public int $bytes, public bool $fenced, public string $sha256,
    ) {}
    public static function from(string $content, ResponseEnvelopeStripper $s): self;
}
```

Plus one constraint, which is the actual enforcement mechanism:

```sql
ALTER TABLE ai_requests ADD CONSTRAINT ai_requests_response_sha256_format_check
  CHECK (response_sha256 IS NULL OR response_sha256 ~ '^[0-9a-f]{64}$');
```

**Alternatives considered.** (a) A `text` column plus a code comment and a code-review norm.
(b) A truncated ~120-char `response_head` (AD-2's deferred variant). (c) Drop the hash, keep
byte length and the boolean only.

**Rationale.** The task asked for the constraint to be *structurally enforced rather than merely
documented*, and this is the only version of that which is true: **`unsignedInteger` and
`boolean` cannot hold a substring at all, and the one text-capable column is fixed at 64
characters and constrained to lowercase hex.** No fragment of a scoring response satisfies that
regex. The illegal state is unrepresentable — the AD-2 prose is the *reason*, not the guard.
Option (a) is what every leak looks like the day before it happens.

**Why `data-retention/spec.md` needs no amendment, and would be wrong to receive one.** That
spec (`:46-56`) enumerates four candidate-data classes because purge is about *readable content*.
None of these three columns is readable content: a byte count and a boolean carry no transcript
bits, and a SHA-256 is non-reversible and useless as a candidate identifier because the input is
never stored anywhere to compare against. Adding `ai_requests` to that enumeration would assert a
retention obligation over data that cannot be read back, and — worse — would create the fifth
candidate-data class with no ratified duration that AD-2 exists to avoid. **If a delta touches
`data-retention/spec.md`, this design was implemented wrong.**

(c) is the conservative fallback and is genuinely close. The hash earns its place by grouping
identical failures across calls and competencies — which is exactly the question the 2026-08-24
incident could not answer ("were all five the same response shape?"). If legal disagrees later,
dropping one additive nullable column is a clean revert with no data precondition.

### D7 — Envelope failures and per-indicator failures get different catch scopes

This is the structural core. Today, `ScoreEvaluationJob.php:640-678` runs `parse()` **and** the
validation loop inside one `try`, so one bad excerpt on indicator 3 discards indicators 1 and 2.
The two failure kinds must first be separated *by where they can be thrown*, not by which arm of
a `match` they land in.

**Choice — the parser becomes total over `behaviors[]`, and keeps throwing only for the envelope.**

| Failure | Kind | Raised by | Result |
|---|---|---|---|
| Body is not JSON / `behaviors` missing or not an array | envelope | `EvaluationParser` throws `JsonParseException` | whole competency unscorable |
| `count(behaviors) ≠ count(indicators)` | envelope | `EvaluationParser` throws `IndicatorCountMismatchException` | whole competency unscorable |
| `score` is `4.5`, `"abc"`, an array | **per-indicator** | `EvaluationParser` **no longer throws** — emits a DTO carrying `ScoreIllegal` | that indicator only |
| `score` is `0`, `6`, `-2` | **per-indicator** | `IndicatorValidator` throws, caught **inside** the loop | that indicator only |
| Excerpt not verbatim | **per-indicator** | `ExcerptValidator` throws, caught **inside** the loop | that indicator only |

`EvaluationParser::coerceScore()` currently throws `InvalidIndicatorScoreException`
(`EvaluationParser.php:128`), which aborts DTO construction and destroys the sibling DTOs that
were already built. That single throw is the reason isolation cannot be done in the job alone.
It becomes a per-behavior capture instead. **After this change the only exceptions
`EvaluationParser` can throw are envelope-level** — the whole-response / per-indicator boundary
is a property of the class's throw set, not a convention.

```php
// scoreCompetency() — phase 1: envelope. May throw. Nothing to isolate: no DTOs exist.
try {
    $dtos = $evaluationParser->parse($llmResponse->content, $indicatorList);
} catch (JsonParseException|IndicatorCountMismatchException $e) {
    // unchanged behaviour: ai_requests(success:false) + persistUnscorable(LlmParseError)
    return;
}

// phase 2: per-indicator. The try is INSIDE the loop.
$validated = [];
foreach ($dtos as $dto) {
    try {
        $indicatorValidator->validate($dto);
        $excerptValidator->validate($dto, $transcript);
        $validated[] = $dto;
    } catch (InvalidIndicatorScoreException) {
        $validated[] = $dto->asUnassessable(IndicatorFailureReason::ScoreIllegal);
    } catch (ExcerptNotVerbatimException) {
        $validated[] = $dto->asUnassessable(IndicatorFailureReason::ExcerptUnverifiable);
    }
}
assert(count($validated) === count($dtos));   // and asserted in Pest, not only here
```

`IndicatorScoreDTO::asUnassessable()` returns a new readonly instance with `score: -1`
(AD-1 — the arithmetic is untouched), `excerpts: []`, `explanation` preserved, and
`unassessableReason` set. **Excerpts are dropped deliberately**: persisting a non-verbatim excerpt
would store model-invented text in the field whose entire contract is "verbatim from the
transcript". Dropping them also lands the DTO on exactly the `-1` + empty-excerpts shape
`ExcerptValidator` already skips (CC2), so no re-validation branch is needed. The explanation is
kept — it is model prose about the indicator, already persisted for every other indicator, and
introduces no new data class.

**Alternatives considered.** (a) Keep one `try` and re-run the loop after removing the offending
DTO. (b) Collect exceptions and decide at the end. (c) Isolate only `ExcerptNotVerbatim` and
leave illegal scores whole-competency-fatal.

**Rationale.** (a) is O(n²) calls to a validator and re-derives which DTO failed from the
exception's position field — the exceptions carry `position`, but reconstructing state from an
exception is how off-by-one bugs enter correctness-critical code. (b) defers the decision without
removing the coupling. (c) is arbitrary: an illegal score and an unverifiable excerpt are both
one indicator's problem, and AD-1's vocabulary already names them separately.

**The post-condition is the point.** `count($validated) === count($dtos)` holds because the loop
appends exactly once on every path — try-success, and both catch arms. A Pest property test
drives a competency whose three indicators fail in three different ways and asserts three
`IndicatorScore` rows persist. That is what makes "a sibling is never silently dropped"
verifiable rather than intended.

**One documented consequence, under a non-default flag.** A competency where *every* indicator
fails validation now persists `CompetencyResult(score: null, reliability: 0.0, valid: false,
unscorable_reason: NULL)` with N indicator rows, where previously it persisted
`unscorable_reason: 'llm_parse_error'` with zero rows. `unscorable_reason: NULL` is correct and
consistent — `BarsArithmeticTest:101` already pins NULL for the all-unassessable case as the
Defect-D regression. But `resolveEvaluationTerminalState()` under
`gate.count_unscorable_against_total = false` counts `where('unscorable_reason', null)` into the
denominator (`ScoreEvaluationJob.php:464-466`), so such a competency now enters that denominator
where before it did not. The default policy (`true`) is unaffected. Named here, pinned by a test,
and carried to Open Questions.

### D8 — One retry, doubled budget, its own row, and an honest bill

**Choice.** Config-driven per the ratified answer, with a config-invariant test instead of a
hardcoded cap:

```php
// config/scoring.php
'truncation_retry' => [
    'enabled'           => (bool)  env('SCORING_TRUNCATION_RETRY_ENABLED', true),
    'max_attempts'      => (int)   env('SCORING_TRUNCATION_RETRY_MAX_ATTEMPTS', 1),
    'budget_multiplier' => (float) env('SCORING_TRUNCATION_RETRY_MULTIPLIER', 2.0),
    'budget_ceiling'    => (int)   env('SCORING_TRUNCATION_RETRY_CEILING', 8192),
],
```

Retry budget = `min((int) round($currentMaxTokens * multiplier), ceiling)`. The second call is a
plain second `complete()` with `$options['max_tokens']` overridden — `AnthropicLLMProvider:57`
already honours that key, so nothing in the provider changes.

**Cost accounting — the non-negotiable part.** Each attempt calls `recordAiRequest()`
**separately**, before its outcome is known to be terminal. Two calls means two rows: the first
carries `success: false, failure_reason: truncated` with its own `input_tokens`,
`output_tokens` and `estimated_cost_usd`; the second carries whatever it earns. This satisfies
`observability/spec.md:385` ("exactly one `ai_requests` row per provider call, whether or not
the result is usable") and keeps the doubled spend visible in the org cost dashboard as two line
items rather than one averaged one. **A retry that reuses the first row hides a real cost, and
hides it at the exact moment something is already wrong.**

**When the enlarged budget also truncates:** `attemptsAlreadyMade` now equals `max_attempts`,
`classify()` returns `Terminal`, a second `ai_requests` row is written with
`failure_reason: truncated`, and `persistUnscorable(UnscorableReason::LlmTruncated)` runs. **No
third call, ever.** A test asserts `CassetteLLMProvider::callCount() === 2` for that scenario.

**Alternatives considered.** (a) A hardcoded `private const MAX_ATTEMPTS = 1`, not
config-driven. (b) Reuse Laravel's queue retry with a growing budget in the job payload.

**Rationale.** (a) is what an engineer reaches for when the worry is "someone sets this to 5 on a
production box", and that worry is real — but the product answer ratified *config-driven*, and
the codebase already has the right idiom for exactly this tension: `QueueRuntimeConfigTest` and
the `prompt_version` parity guard (`config/scoring.php:100-107`) pin shipped config defaults with
a test. So a Pest config-invariant test asserts `max_attempts === 1` and
`budget_multiplier === 2.0` in the shipped defaults. Changing the cap then requires editing a
test — deliberate and visible — while an operator retains the env override the product asked for.
Deployment environments that set these explicitly are outside the guard's reach, exactly as the
`prompt_version` docblock already warns; that is called out in the B1 slice checklist.

(b) is rejected outright: routing through the queue means re-entering `handle()`, re-running the
start-of-job guard, and re-scoring competencies that already succeeded. It is also a *queue*
retry, which is the thing FIX-9 forbids for this whole family. D8's retry is
**in-job, same-competency, same-interview, one extra call** — and per AD-4 it has nothing to do
with RT-B.

**`CassetteLLMProvider` must gain per-call variation.** Today it is constructed with one
`finishReason` for every entry (`CassetteLLMProvider.php:43`), so it cannot express "first call
truncated, second call complete" — which both the A-slice truncated cassette and B1's retry test
need. The cassette map's values widen from `string` to `string|CassetteResponse|list<CassetteResponse>`,
where a list is consumed in call order per competency code and a bare string keeps today's
meaning. Existing cassettes and `GoldenCassetteTest` stay byte-unchanged.

### D9 — Formula diff-freeness is asserted, not promised

**Choice.** Three mechanisms, in increasing strength:

1. **Signature isolation.** `MeanCalculator::compute()`, `AssessableFractionReliability::compute()`
   and `CompletionGate::evaluate()` accept `list<int>` and `int` — they never receive a DTO or a
   model. Because `asUnassessable()` sets `score: -1`, `array_map(fn ($d) => $d->score, $validated)`
   yields a `list<int>` byte-identical in shape to today's. The reason field is not in their input
   type, so no formula *can* read it.
2. **Arch test.** A Pest arch assertion that those three classes, plus
   `IndicatorValidator`, do not depend on `IndicatorFailureReason`, `UnscorableReason` or
   `IndicatorScoreDTO`. This is the executable form of the success criterion "no formula reads
   that field" — it fails on the import, before anyone can write the branch.
3. **Regression pin.** Their existing unit tests ship **byte-unchanged** and must stay green.
   A test file that had to be edited is the signal that the guarantee broke.

**Alternatives considered.** A CI step running `git diff --exit-code` over the four files.

**Rationale.** A diff check is a policy, not a property: it passes trivially today and says
nothing about whether the *behaviour* is preserved once someone legitimately touches a docblock.
The arch test states the actual invariant — the reason is structurally unreachable from the
arithmetic — and survives refactoring.

### D10 — Webhook payload: additive, no version bump

**Choice.** `webhooks.payload.version` stays `1.0`. `EvaluationPayloadAssembler` is unchanged in
Increment A. In Increment B it gains one additive key inside each `behaviors[]` entry,
`unassessable_reason`, present only when the indicator is unassessable.

**Alternatives considered.** (a) Bump to `1.1` for the widened `unscorable_reason` value set.
(b) Bump to `1.1` when Increment B adds `behaviors[].unassessable_reason`. (c) Bump to `2.0`.

**Rationale — three reasons, the second of which is decisive.**

*What an integrator's parser actually does.* A tolerant deserializer (the overwhelming default:
`JSON.parse`, `json.loads`, Jackson without `FAIL_ON_UNKNOWN_PROPERTIES`) ignores an unknown key
and is unaffected. A strict validator with `additionalProperties: false` rejects the payload —
**and a version bump does not save it.** A strict validator pinned to `1.0` rejects the new key
whether the envelope says `1.0` or `1.1`, unless it version-gates its schema selection, in which
case it is not the fragile consumer we were protecting. The bump costs coordination and buys
nothing for either class of consumer. The same reasoning already governs `files`, which
`webhooks-integration/spec.md:253-255` documents as an **OPEN, EXTENSIBLE map** where
"a spec-compliant receiver MUST NOT reject the payload or assume a closed key set". This design
extends that published rule to `behaviors[]` entries and to the `unscorable_reason` **value
set** — which is a spec-text obligation, owned by `sdd-spec`, not a code change.

*The version field is global to both payload types.* `config('webhooks.payload.version')` is read
by `EvaluationPayloadAssembler:87`, `ProgressPayloadAssembler:80` **and**
`WebhookDeliveryRecorder:106` (which stamps `webhook_deliveries.payload_version`). There is one
knob. Bumping it for an evaluation-only additive key would relabel **every `progress` payload**
as a new schema version despite zero change to it, and would split the delivery history into two
`payload_version` values that differ by nothing for `progress` consumers. A version number that
moves for reasons unrelated to its payload is worse than no version number.

*The competency-level field already ships.* Per C-B, `unscorable_reason` has been on the wire
since C10. Only its value set widens. `1.0` never promised a closed set; the spec never
enumerated one.

**What would justify a bump:** removing a key, changing a key's type, or changing the meaning of
an existing value. None of that happens here. CLAUDE.md's greenfield stance is not the reason —
it would license a bump just as easily; the reason is that the bump is *inert for consumers and
actively misleading for `progress`*.

### D11 — Operator surfacing: additive field, hand-edited type, drift guard

**API.** `AdminEvaluationSerializer::serializeCompetencyResult()` returns
`{score, reliability, behaviors, unscorable_reason}` — the machine key, unlocalized per
CLAUDE.md, `null` for scored competencies. In Increment B each `behaviors[]` entry gains
`unassessable_reason: string|null`. The docblock array shapes on `serialize()`,
`serializeCompetencyResult()` and `EvaluationResource::__construct()` update in the same commit.
`openapi.json` is regenerated — for the published contract, not for the backoffice (C-C).

**Backoffice.** `useEvaluationReport.ts`'s hand-typed `EvaluationCompetencyResult` and
`EvaluationBehavior` gain the fields. Because nothing generates these, D11 adds the guard the
arrangement has always lacked: a Pest test in `api` asserting that the *key set* of
`serializeCompetencyResult()`'s output equals a literal expected list. When someone adds a field
without touching the backoffice, that test is the thing that names the omission — currently
nothing does.

**Render.** `CompetencyRow.vue` is where the unexplained 0% lives. For a row with
`unscorable_reason !== null`, the Indicators cell — today an empty `<ul>`, which *is* the visual
hole — renders instead:

```
⚠ Not scored — the evaluator's response was cut off before it was complete.
```

`text-muted-foreground text-xs` with `ExclamationTriangleIcon`, inside the same cell, so the
sentence sits on the same row as the `0%` badge and no operator can read one without the other.
The Mean cell keeps `CompetencyMean`'s `–` and `ReliabilityBadge` keeps `0%`: both are *true*,
and hiding a true value to make room for the explanation would be a second lie.

**Copy (`en`; `it` mirrors, authored with the slice).**

```jsonc
"report": {
  "unscorable": {
    "role_no_bars":                "Not scored — no BARS indicators are defined for this competency in the pinned framework version.",
    "anchor_translation_missing":  "Not scored — the BARS anchors are not available in this project's language.",
    "llm_parse_error":             "Not scored — the evaluator's response could not be read.",
    "llm_truncated":               "Not scored — the evaluator's response was cut off before it was complete.",
    "unknown":                     "Not scored — unrecognised reason ({reason})."
  },
  "indicatorReason": {                                        // Increment B
    "model_declared":       "No assessable evidence in the transcript",
    "excerpt_unverifiable": "Evidence could not be verified against the transcript",
    "score_illegal":        "The evaluator returned an invalid score",
    "unknown":              "Not assessed — unrecognised reason ({reason})"
  }
}
```

The copy names *what happened*, never *what to do*, because the remedy differs per tenant and
this surface has no standing to recommend one. `llm_parse_error` deliberately does not say
"invalid JSON": that is engineering vocabulary and the operator's action is identical either way.

**Per-indicator placement (B).** The indicator chip strip is dense and a fourth column is not
worth a rare case, so the reason becomes the `unassessable` `ScoreChip`'s screen-reader label and
`title`, replacing the generic `report.chip.unassessable` when an `unassessable_reason` is present.
The chip's visual density is unchanged; the reason is available to both the SR user and on hover.

### D12 — Unknown keys render loudly, never blankly

**Choice.** A total function in `backoffice/app/utils/bars.ts`, alongside `indicatorChipState`:

```ts
const KNOWN_UNSCORABLE = ['role_no_bars', 'anchor_translation_missing',
                          'llm_parse_error', 'llm_truncated'] as const

export function unscorableReasonKey(reason: string | null): string | null {
  if (reason === null) return null
  return KNOWN_UNSCORABLE.includes(reason as never)
    ? `report.unscorable.${reason}`
    : 'report.unscorable.unknown'   // interpolates {reason} verbatim
}
```

**Rationale.** This is D6 of `bars-full-scale-1-5` applied to a second field, for the same
reason: the failure mode that made ship-ordering load-bearing was **silent masking**. An
unrecognised key that renders nothing tells the operator "there is no explanation", which is a
lie about the data. Rendering the raw key inside a localized sentence preserves the report, flags
the specific cell as untrustworthy, and gives support the exact value to quote. It also makes
the "backoffice renders a key the API has not shipped yet" risk structurally harmless rather than
merely mitigated by deploy order — which matters, because A4 and A5 are separate PRs.

### D13 — Slices

Ship order is left-to-right; rollback reverses it. Each is independently revertable and
independently verifiable. Chain: PR #1 targets `feature/scoring-failure-containment`, each child
targets its predecessor.

| # | Slice | Repo | Contents | Est. Δ |
|---|---|---|---|---|
| A1 | truncation detection | `api` | `LLMResponse.truncated` · Anthropic mapping · `ScoringFailure`/`ScoringDisposition`/`ScoringFailureClassifier` + case-loop test · `AiRequestFailureReason::Truncated` · `UnscorableReason` enum (D2) · job short-circuit · `CassetteLLMProvider` per-call responses · truncated cassette | ~330 |
| A2 | parse tolerance | `api` | `ResponseEnvelopeStripper` + `UnwrappedResponse` · `EvaluationParser` wiring · fenced cassette · negative cassettes | ~190 |
| A3 | fingerprint | `api` | migration (columns + sha256 format CHECK) · `ResponseFingerprint` · `recordAiRequest()` wiring · no-leak-across-all-columns test | ~210 |
| A4 | read surface | `api` | serializer `unscorable_reason` · docblock shapes · key-set drift guard (D11) · `openapi.json` regen | ~100 |
| A5 | operator UI | `backoffice` | hand-typed interfaces · `unscorableReasonKey()` · `CompetencyRow` render · `en`+`it` · Vitest | ~230 |
| B1 | truncation retry | `api` | `config/scoring.php` block · config-invariant test · second-call path · second `ai_requests` row · cap + ceiling + also-truncated tests | ~250 |
| B2 | per-indicator isolation | `api` | `indicator_scores.unassessable_reason` migration + backfill + equivalence CHECK · `IndicatorFailureReason` · DTO `unassessableReason` + `asUnassessable()` · parser totality · two-phase `scoreCompetency()` · arch test (D9) · count post-condition test | ~380 |
| B3 | indicator surfacing | `api` + `backoffice` | serializer + `EvaluationPayloadAssembler` `behaviors[].unassessable_reason` · `ScoreChip` SR label · i18n · tests | ~180 |

**Ordering constraints, and only these:**

- **A1 has no migration gate.** Per C-A there is no value CHECK to widen, so the enum case and
  its writer ship together. This is the single largest simplification the code review produced.
- **A3's migration precedes A3's writer** — same PR, migration commit first (`work-unit-commits`).
- **A4 before A5** — `api` lands before `backoffice`. D12 makes an out-of-order deploy render a
  loud fallback instead of a blank cell, so this is a preference, not a hard gate.
- **B1 depends on A1** (`truncated` + classifier). **B3 depends on B2.** **B2 depends on nothing
  in A** technically, but AD-8 fixes B after A and diagnosis-before-remediation is the point.

`Chained PRs recommended: Yes` · `400-line budget risk: Medium` · `Decision needed before apply: No`

**B2 is the only slice at budget.** If the RED-phase test count pushes it past 400, split at the
natural seam: **B2a** = schema + `IndicatorFailureReason` + DTO + parser totality (the parser can
emit `ScoreIllegal` DTOs while the job still validates them in one `try` — behaviour unchanged,
fully testable); **B2b** = the job's two-phase restructure + arch test. B2a is inert alone, which
is what makes the split safe.

**B2 migration rollback has no data precondition.** `down()` drops the equivalence CHECK and then
the column; dropping a column cannot violate a constraint. The backfill
(`UPDATE indicator_scores SET unassessable_reason = 'model_declared' WHERE score = -1`) is a statement
of fact, not a guess, in the same sense as `2026_07_31_000001:44-50`: before this change, a
validation failure discarded the whole competency and wrote **zero** `IndicatorScore` rows, so
every existing `-1` row is model-declared by construction.

---

## Data Flow

```
  LLMProvider::complete(prompt, {max_tokens: N})
            │
            ▼
   LLMResponse{content, finishReason:"max_tokens", truncated:true, tokens}   (D3)
            │
            ├─────────────► ResponseFingerprint::from(content)               (D6)
            │                  {bytes, fenced, sha256}  ── no text, by type
            │                            │
            ▼                            ▼
   truncated? ──yes──► ScoringFailureClassifier::classify(ResponseTruncated, n)
            │              │
            │              ├─ RetryWithLargerBudget ──► complete({max_tokens: min(2N, ceiling)})
            │              │        (D8)                     └──► its OWN ai_requests row
            │              │
            │              └─ Terminal ──► ai_requests(success:false, truncated)
            │                              persistUnscorable(LlmTruncated)
            no
            │
            ▼
   ResponseEnvelopeStripper::unwrap()  ── fence + narrow prose, NO validation   (D5)
            │
            ▼
   EvaluationParser::parse()      ◄── throws ONLY envelope failures now         (D7)
            │  JsonParse | IndicatorCountMismatch ──► persistUnscorable(LlmParseError)
            │
            ▼  list<IndicatorScoreDTO>, one per behavior, ALWAYS
   ┌── per-DTO try ─────────────────────────────────────────────┐
   │  IndicatorValidator  ─ throws ─► asUnassessable(ScoreIllegal)          │
   │  ExcerptValidator    ─ throws ─► asUnassessable(ExcerptUnverifiable)   │
   └────────────────────────────────────────────────────────────┘
            │  count($validated) === count($dtos)   ← post-condition (D7/D9)
            ▼
   array_map(fn($d) => $d->score)  →  list<int>  ← IDENTICAL shape to today
            │
            ├──► MeanCalculator                (untouched, arch-asserted)   (D9)
            ├──► AssessableFractionReliability (untouched, arch-asserted)
            ├──► CompletionGate                (untouched, arch-asserted)
            │
            ▼
   CompetencyResult{score, reliability, valid, unscorable_reason}
   IndicatorScore{score:-1, unassessable_reason} ← reason is metadata, never arithmetic (AD-1)
            │
            ├──► EvaluationPayloadAssembler ──► webhook, version "1.0", additive   (D10)
            │
            ▼
   AdminEvaluationSerializer ──► {score, reliability, behaviors, unscorable_reason}  (D11)
            │
            ▼
   unscorableReasonKey()  ── total; unknown → loud fallback, never blank   (D12)
            │
            ▼
   CompetencyRow — the reason sits in the cell that is empty today
```

Every read in the job path keeps its existing `withoutGlobalScopes()` + `TenantContextScope::runFor($orgId, …)`
boundary (`ScoreEvaluationJob.php:183`); no new query is introduced outside it, and
`AdminEvaluationSerializer` continues to read under the ambient tenant scope, never
`withoutGlobalScopes()` — the arch test at C11 task 5.3 already pins that split.

---

## File Changes (beyond the proposal's list)

| File | Action | Why |
|---|---|---|
| `api/app/Enums/UnscorableReason.php` | Create | D1/D2 — single source of the four operator-facing values |
| `api/app/Enums/Scoring/ScoringFailure.php` | Create | D3 — provider-neutral failure vocabulary |
| `api/app/Enums/Scoring/ScoringDisposition.php` | Create | D3 — two cases; `Terminal` is the default arm |
| `api/app/Enums/IndicatorFailureReason.php` | Create | D1 — Increment B |
| `api/app/Services/Scoring/ScoringFailureClassifier.php` | Create | D3 — shaped after `Webhooks/RetryClassifier` |
| `api/app/Services/Scoring/ResponseEnvelopeStripper.php` | Create | D5 — one definition of "fenced", two callers |
| `api/app/Support/Observability/ResponseFingerprint.php` | Create | D6 — cannot hold text |
| `api/app/Testing/CassetteLLMProvider.php` | Modify | D8 — per-call responses; existing cassettes unchanged |
| `api/app/Http/Resources/Admin/EvaluationResource.php` | Modify | D11 — docblock array shape |
| `api/tests/Unit/Services/Scoring/ScoringFailureClassifierTest.php` | Create | D3 — loop over `ScoringFailure::cases()` |
| `api/tests/Feature/Jobs/TruncationRetryTest.php` | Create | D8 — two rows, cap, also-truncated → `callCount() === 2` |
| `api/tests/Feature/Jobs/PerIndicatorIsolationTest.php` | Create | D7 — three failure kinds, three rows persisted |
| `api/tests/Unit/Observability/FingerprintNoLeakTest.php` | Create | D6 — marker absent from **every** column |
| `api/tests/Arch/ScoringFormulaIsolationTest.php` | Create | D9 — the formulas cannot see the reason |
| `api/tests/Unit/Config/TruncationRetryConfigTest.php` | Create | D8 — shipped defaults 1 / 2.0 |
| `api/tests/Unit/Services/Admin/EvaluationKeySetTest.php` | Create | D11 — the drift guard C-C showed was missing |
| `backoffice/app/utils/bars.ts` | Modify | D12 — `unscorableReasonKey()` |
| `backoffice/app/components/molecules/CompetencyRow.vue` | Modify | D11 — reason in the Indicators cell |
| `backoffice/app/composables/useEvaluationReport.ts` | Modify | C-C/D11 — hand-typed, by hand |
| `api/database/migrations/*_add_response_fingerprint_to_ai_requests.php` | Create | D6 |
| `api/database/migrations/*_add_unassessable_reason_to_indicator_scores.php` | Create | D7 — additive, backfilled, equivalence CHECK |
| **NOT changed** | — | `MeanCalculator`, `AssessableFractionReliability`, `CompletionGate`, `IndicatorValidator`, `data-retention/spec.md`, `PromptBuilder`, `prompt_version`, `webhooks.payload.version` |

---

## Testing Strategy

| Layer | What | Approach |
|---|---|---|
| Unit, api ~95% | `ScoringFailureClassifier` — every `ScoringFailure` case except `ResponseTruncated` is `Terminal` at every attempt count | Pest data provider over `::cases()`; a new case added without thought fails |
| Unit, api ~95% | `ResponseEnvelopeStripper` — fence, fence+lang tag, leading prose, trailing prose; **and** refuses when a discarded run holds `{`, `}` or `"` | Pest table test |
| Unit, api ~95% | `EvaluationParser` throws **only** envelope exceptions; illegal scores become `ScoreIllegal` DTOs | Pest; assert the throw set |
| Unit, api | `ResponseFingerprint` — sha256 hex shape; no property can hold content | Pest + `ReflectionClass` property types |
| Unit, api | Shipped config defaults: `max_attempts === 1`, `budget_multiplier === 2.0` | Pest, `QueueRuntimeConfigTest` precedent |
| Arch, api | Formula classes do not depend on the reason types (D9) | Pest arch |
| Arch, api | Serializer key set equals the literal expected list (D11) | Pest |
| Integration, api ~95% | Truncated cassette → `truncated` in `ai_requests` **and** `llm_truncated` on the `CompetencyResult`, never `llm_parse_error` | Pest + extended `CassetteLLMProvider` |
| Integration, api ~95% | Fenced cassette parses green; malformed negative cassettes still hard-fail | Pest, new fixtures — none exist today |
| Integration, api ~95% | 3 indicators, 3 different failures → **3** `IndicatorScore` rows, all `-1`, reliability `0.0` | Pest |
| Integration, api ~95% | 1 unverifiable of 3 → 2 assessed, reliability `2/3`, `valid: true` at T=0.5 | Pest |
| Integration, api ~95% | Truncation retry → **2** `ai_requests` rows with independent costs; also-truncated → `callCount() === 2`, no third | Pest |
| Integration, api | No column of a failed `ai_requests` row contains a distinctive marker from the response body | Pest over `getAttributes()` |
| Regression, api | `col_slf_golden.php`, `intermediate_golden.php`, `GoldenCassetteTest`, and the three formula unit tests stay **byte-unchanged** and green | Pest |
| Unit, backoffice | `unscorableReasonKey()` over the four known keys, `null`, and garbage → loud fallback, never blank | Vitest |
| Unit, backoffice | `CompetencyRow` renders the sentence for an unscorable row and nothing extra for a scored one; resolves in `en` **and** `it` | Vue Test Utils |
| E2E | None new | No new route or flow; rendering is unit-covered |

---

## Migration / Rollout

Two migrations, both additive, both with clean `down()`:

- **`ai_requests`** (A3): three nullable columns + the sha256 format CHECK. `down()` drops the
  constraint then the columns. **No data precondition** — existing rows are NULL and NULL passes
  the constraint by construction.
- **`indicator_scores`** (B2): one nullable column, backfilled
  `WHERE score = -1 → 'model_declared'`, then the equivalence CHECK
  `(score = -1) = (unassessable_reason IS NOT NULL)`. `down()` drops constraint then column. **No
  data precondition** — dropping a column cannot violate anything.

**No enum-value CHECK is added or narrowed anywhere** (C-A, D2), so the change carries no
rollback step with a data precondition at all. Reverse ship order on rollback:
B3 → B2 → B1 → A5 → A4 → A3 → A2 → A1. Wrapper submodule pointers revert to their pinned commits.
No backfill of historical evaluations, no re-scoring of `evaluation_id` 6.

---

## Open Questions

- [ ] **Alt gate policy interaction (product, non-blocking).** Under
      `gate.count_unscorable_against_total = false`, a competency where every indicator fails
      validation now enters the denominator, because D7 gives it `unscorable_reason: NULL` and N
      indicator rows where it previously had `'llm_parse_error'` and zero. The default policy
      (`true`) is unaffected and no shipped environment sets `false`. This design assumes the new
      behaviour is correct — the competency *was* scored — and pins it with a test so a change of
      intent breaks a test rather than sliding.
- [ ] **`it` copy (product/i18n).** The `en` strings in D11 are proposed; the Italian must be
      authored with slices A5 and B3, not machine-translated in the PR.
- [ ] **`response_sha256` (legal, non-blocking).** D6 argues a non-reversible digest of a never-
      stored input is not candidate content and needs no retention class. If legal disagrees,
      dropping one additive nullable column is a clean revert; `response_bytes` and
      `response_fenced` carry the diagnosis on their own.
- [ ] **Spec-text obligations owned by `sdd-spec`, recorded here so they are not lost.** The
      `scoring-engine` Coverage Note must stop claiming a three-value `unscorable_reason` enum;
      `webhooks-integration` must publish the `unscorable_reason` **value set** and `behaviors[]`
      keys as OPEN and EXTENSIBLE, extending the rule it already states for `files` (`:253-255`),
      since D10 declines a version bump on the strength of that rule; and `observability` must
      record the three fingerprint columns and the new `truncated` failure reason.
