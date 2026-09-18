# Tasks: Post-hoc Audit of Persisted Indicator Scores (TypeSafe / Jev)

> Strict TDD active (`openspec/config.yaml: strict_tdd: true`). Every code task is RED (failing
> test) → GREEN (make it pass). Tasks marked **GUARD** create a structural arch-test guard with
> nothing yet in the codebase to violate it — there is no meaningful RED for an invariant nothing
> has broken yet, so these are written once and verified green, then re-checked as a pass/fail gate
> on every later slice that could regress them.
> Ship order: **Phase 0 → P1 → P2 → P3a → P3b → P4 → P5 → P6**. Rollback reverses it (see
> `design.md` → Migration / Rollout).
> `design.md` is the HOW; `specs/*/spec.md` are the WHAT, already reconciled with the proposal
> (the `skip_reason`→`outcome_reason` rename and the 3-term→4-term coverage identity are settled —
> not re-derived here). Column/class names below use the reconciled vocabulary throughout.

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | P1 ~380 / P2 ~380 / P3a ~320 / P3b ~280 / P4 ~260 / P5 ~230 / P6 ~380 (total ~2,230) |
| 400-line budget risk | Medium — each slice is sized to stay at or near the ~400-line budget; P1, P2 and P6 are the largest |
| Chained PRs recommended | Yes |
| Suggested split | P1 → P2 → P3a → P3b → P4 → P5 → P6 (feature-branch-chain) |
| Delivery strategy | auto-chain |
| Chain strategy | feature-branch-chain — already committed in `proposal.md` ("Size and Delivery") and `design.md` ("Migration / Rollout"); carried forward here, not re-opened |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Medium

**"No" above answers only the PR-slicing decision** (already settled by prior phases). It does
**not** mean P1 may start immediately — see Phase 0 below, which is a separate, human-owned gate.

### Suggested Work Units

| Unit | Goal | Repo | Base branch | Focused test command | Runtime harness | Rollback boundary |
|------|------|------|-------------|----------------------|------------------|--------------------|
| P1 | Judge seam: contract, DTOs, enums, exception, `TypesafeJevJudge`/`JevRequestBuilder`/`JevResponseMapper`, `FakeAuditJudge`, binding, config | `api` | `feature/scoring-audit-jev` | `php artisan test --filter=Audit` | N/A — no route or job exists yet to exercise end-to-end; unit/feature tests are the harness | `git revert` — nothing reads these classes yet |
| P2 | Two append-only tables + models + factories + 3 arch tests | `api` | P1 branch | `php artisan test --filter=IndicatorScoreAudit` | `php artisan migrate:status` (confirm both migrations `Ran`) | `git revert` the code; leave the tables (isolated, referenced by nothing) |
| P3a | `AuditEvaluationJob` happy path + `AuditRunCostEstimator` | `api` | P2 branch | `php artisan test --filter=AuditEvaluationJob` | `php artisan queue:work --once` against a `FakeAuditJudge`-seeded run | `git revert` — nothing dispatches the job yet |
| P3b | `Throwable` isolation, degraded rows, `failed()`, reconciliation | `api` | P3a branch | `php artisan test --filter=AuditEvaluationJob` | Same as P3a, plus a forced `->failed()` invocation | `git revert` — same job class, no external caller yet |
| P4 | `POST /participants/{id}/evaluation/audit` route + policy + lock | `api` | P3b branch | `php artisan test --filter=EvaluationAudit` | `php artisan route:list --path=api` (confirm route registered) | `git revert` removes the only trigger; P2/P3 rows stay isolated |
| P5 | `AuditVerdictReader` + serializer `audit` key + `EvaluationResource` + OpenAPI export | `api` | P4 branch | `php artisan test --filter=EvaluationKeySet` | `DB_CONNECTION=pgsql DB_HOST=127.0.0.1 DB_PORT=5432 DB_DATABASE=beai_test DB_USERNAME=postgres DB_PASSWORD=postgres DB_URL= php artisan scramble:export` then diff `openapi.json` | `git revert`, re-export OpenAPI against Postgres — `behaviors[]` shape returns byte-identical |
| P6 | Backoffice review-status surface | `backoffice` | `feature/scoring-audit-jev` (backoffice) | `bun run test:unit` | `bun run test:e2e` (Chromium + WebKit only — backoffice has no mobile/viewport gate) | `git revert`, `bun run codegen` against the still-current `openapi.json` |

If GitHub shows a predecessor slice's changes in a child diff, retarget/rebase before review.

---

## Note on D6's known ceiling (worker-kill mid-run loses cost of calls already made)

**Decision: document it with an explicit RED test (task 3b.13 below), not fix it in v1.** The
design already accepts this as a named, proportionate ceiling — a per-call cost row would be a
third table and a scope decision the proposal never took (it explicitly ruled out a third-table
shape in AD-2). No spec requirement mandates surviving it. But "accepted" and "silently absent
from coverage" are different things: a ceiling nobody tests is a ceiling nobody notices regress.
Task 3b.13 asserts the accepted behavior directly — `failed()` writes a best-effort `failed` run
row with all four counters at `0` (satisfying the coverage CHECK), a `failure_reason='job_killed'`,
and releases the lock, while explicitly asserting NO indicator rows are written. If this ever needs
fixing, `design.md`'s own Open Questions section already names the fix (a per-call cost row) as a
new table and a new change — not a task this breakdown schedules.

---

## Phase 0 — Branch Hygiene & Blocking Human-Decision Gate (do first)

Two items below are **human decisions, not code tasks** — do not invent implementation work that
resolves them. `sdd-apply` MUST NOT begin P1 until both are explicitly confirmed by a human.

- [x] 0.1 Run `git status` in the wrapper and `api`. Confirm no uncommitted work is discarded;
  stash or commit anything unrelated before branching. Create `feature/scoring-audit-jev` off
  `develop` in `api` and the wrapper. Create the `backoffice` branch later, once P5 has landed and
  its OpenAPI export exists for `bun run codegen` to target.
  — DONE: `api` had an unrelated, already-committed branch (`fix/project-competency-revision-scope`,
  clean working tree) checked out; left untouched. `feature/scoring-audit-jev` created off
  `origin/develop` (`25031c8`) in `api`. Wrapper stays on `develop`; no wrapper branch created this
  batch (nothing to branch for yet — no wrapper-level commit in this slice).
- [x] 0.2 **HUMAN DECISION — BLOCKING.** Confirm TypeSafe's status as a new GDPR sub-processor of
  candidate personal data. AD-6/D2/D11 minimize what leaves BEAI to the persisted verdict and its
  own excerpts, but those excerpts are verbatim candidate speech, and CLAUDE.md ruling 2's pending
  legal sign-off must name this flow before any real TypeSafe call is made, including a staging or
  controlled-context call. `FakeAuditJudge` is the default test binding for the entire standard
  suite, so P1–P6 as written can be developed and tested end-to-end with zero live TypeSafe calls —
  but the `@ai`/`workflow_dispatch` real-API lane, and any production deploy of a `TYPESAFE_API_KEY`,
  MUST NOT proceed until this is confirmed.
  — RESOLVED BY EXPLICIT USER DECISION (this session, not re-litigated): "proceed with sdd-apply
  anyway" — develop the full chain with `FakeAuditJudge` as the default test binding (no live
  TypeSafe calls in tests); code ships WITHOUT being deployed/activated against real production
  data until legal sign-off lands separately. No code-level gate added for this — it is an
  operational/deployment decision, not a runtime one.
- [x] 0.3 **HUMAN DECISION — BLOCKING.** Confirm `TYPESAFE_API_KEY` is provisioned and verified
  against Railway, and decide the `ai-integration.yml` CI-lane question: fix the existing lane
  (already failing on an invalid `ANTHROPIC_API_KEY`), isolate a new TypeSafe `@ai` group from it,
  or defer real-API coverage to `workflow_dispatch` only. Do not add a new real-API group to a
  workflow that is already red — it buys no signal.
  — RESOLVED BY EXPLICIT USER DECISION (this session): "proceed, TypeSafe wire verification
  deferred." No new `@ai`/`workflow_dispatch` real-API group was added in this batch. Independently
  re-confirmed `ai-integration.yml` is still failing on an invalid `ANTHROPIC_API_KEY` (unrelated
  pre-existing issue; not touched).
- [x] 0.4 Confirm `docs/version-catalog.md` (read-only) and the CLAUDE.md stack table are
  unaffected — no new dependency is expected anywhere in this chain (raw `Http`, no SDK, D3/D25).
  Flag before merge if any PR introduces one.
  — DONE: no `composer.json`/`composer.lock` diff in this batch; `TypesafeJevJudge` uses Laravel's
  `Http` facade only, same as `AnthropicLLMProvider`. No dependency added.
- [x] 0.5 Confirm the chain strategy is already settled as `feature-branch-chain` (proposal.md +
  design.md both state it) — no new decision is required from the user for PR slicing itself; only
  0.2/0.3 above gate the start of P1.
  — DONE: confirmed `feature-branch-chain` from tasks.md's own Review Workload Forecast table.

---

## PR P1 — Judge Seam: Contract, DTOs, `TypesafeJevJudge`, `FakeAuditJudge`, Config (`api`)

> **Opens with a verification task, not a code task (C-C).** The TypeSafe wire contract is
> unverified anywhere in this repository. If network access to `https://docs.typesafe.ai/api.md`
> and the Noul primitive page is available, confirm the endpoint, request/response envelope, exact
> `judge_model` id and published rate card, and record them as a revision to `design.md` (D2/D3/D13)
> before writing 1.6–1.11. If it is not available in this session, proceed with the placeholder
> shape already sketched in `design.md`'s "Wire payload sketch — UNVERIFIED (C-C)" section,
> explicitly flagged UNVERIFIED in `TypesafeJevJudge`'s docblock and covered only by shape tests —
> mirroring the sibling `pluggable-conversation-llm` change's P5.0 precedent for an unresolved
> live-API question. Do not guess silently either way.

- [x] P1.0 Perform the C-C wire-verification read (or record its unavailability) per the note above.
  — DONE: no network-fetch tool was available in this apply session (Read/Edit/Write/Bash/mem_*/
  codegraph only). Recorded the unavailability; proceeded with design.md's already-sketched
  placeholder wire shape, explicitly flagged UNVERIFIED in `TypesafeJevJudge`'s, `JevRequestBuilder`'s
  and `JevResponseMapper`'s docblocks and covered only by shape tests, per the note's own fallback
  instruction (pluggable-conversation-llm P5.0 precedent).
- [x] P1.1 **RED** `api/tests/Unit/Config/AuditConfigTest.php` (`TruncationRetryConfigTest` idiom):
  pins `enabled === true`, `api_key` default `''`, `judge_model`, `prompt_version`,
  `timeout_seconds` shipped defaults; asserts the config block ships **no** `support_threshold` key
  and **no** `batch_size` key at all.
  — RED confirmed: `Failed asserting that null is true` (config block did not exist yet).
- [x] P1.2 **GREEN** `api/config/scoring.php` — add the `audit` block exactly as D13 specifies
  (`enabled`, `api_key`, `base_url`, `judge_model`, `prompt_version`, `timeout_seconds`,
  `cost_rates_usd_per_million`); `.env.example` gains `SCORING_AUDIT_ENABLED`, `TYPESAFE_API_KEY=`,
  `SCORING_AUDIT_JUDGE_MODEL`, `SCORING_AUDIT_PROMPT_VERSION`, `SCORING_AUDIT_TIMEOUT`.
  — PARTIAL: `config/scoring.php`'s `audit` block added exactly per D13, test GREEN. `.env.example`
  NOT edited — this sandbox denies Read/Write/Bash access to `.env.example` outright (confirmed:
  `ls`, `Read`, and any Bash command naming that path are all refused by the permission layer, not
  by repo content). This is an environment limitation, not a design deviation. Flagged as a
  follow-up: a session with access to that file must add the five keys named above before this
  slice is considered fully delivered — `config/scoring.php`'s `env()` defaults already make the
  application function correctly without it (the env var simply isn't documented in the example
  file yet).
- [x] P1.3 **GREEN** `api/app/Contracts/AuditJudge.php` — `judge(AuditRequest): AuditBatchResult`,
  `@throws AuditJudgeException` docblock stating it never throws per-subject (D2).
- [x] P1.4 **GREEN** `api/app/DTOs/Audit/{AuditSubject,AuditRequest,AuditVerdict,AuditBatchResult}.php`
  — readonly DTOs exactly per D2's shapes; `AuditSubject::$indicatorScoreId` documented as a LOCAL
  correlation key, never serialized.
- [x] P1.5 **GREEN** `api/app/Enums/Audit/{AuditRunStatus,AuditVerdictStatus,AuditOutcomeReason}.php`
  — backed string enums; vocabulary exactly per C-E's table (`skipped`:
  `unassessable_by_construction`/`assessed_without_excerpts`; `unavailable`: `judge_unreachable`/
  `judge_http_error`/`judge_timeout`; `malformed`: `verdict_missing`/`verdict_unparseable`/
  `probability_out_of_domain`).
- [x] P1.6 **GREEN** `api/app/Exceptions/Audit/AuditJudgeException.php` — `retryable` flag, mirrors
  `AnthropicException`.
- [x] P1.7 **RED** `api/tests/Unit/Services/Audit/JevRequestBuilderTest.php`: emits ordinal question
  keys (`i1`, `i2`, …) scoped to the request and keeps the ordinal→`indicatorScoreId` map in
  memory; the built payload contains no `indicatorScoreId`, no transcript field, no participant
  field, and no email field anywhere.
  — RED confirmed: `Class "App\Services\Audit\JevRequestBuilder" not found` (4 tests).
- [x] P1.8 **GREEN** `api/app/Services/Audit/JevRequestBuilder.php` — pure: `AuditRequest` →
  `[array $body, array $keyMap]`.
- [x] P1.9 **RED** `api/tests/Unit/Services/Audit/JevResponseMapperTest.php` (table-driven): a
  missing ordinal key ⇒ that subject omitted from `verdicts`; a non-numeric probability ⇒ omitted;
  a probability outside `[0,1]` ⇒ omitted; answers present for keys never sent are ignored and
  logged at `warning`; `support_probability = min(relevance, calibration, grounding)` composition
  is correct for a fully valid subject; an unparseable/non-object envelope throws
  `AuditJudgeException`.
  — RED confirmed: `Class "App\Services\Audit\JevResponseMapper" not found` (9 tests, table-driven
  incl. a 4-case dataset for the unparseable-envelope scenario).
- [x] P1.10 **GREEN** `api/app/Services/Audit/JevResponseMapper.php` — pure: `array $json, array
  $keyMap, int $latencyMs` → `AuditBatchResult`, exactly per D3's mapping-rules table.
  — KNOWN GAP noted in the class docblock: `AuditBatchResult` (D2's literal shape) carries only
  surviving verdicts, with no channel for WHICH of the three malformed reasons
  (`verdict_missing`/`verdict_unparseable`/`probability_out_of_domain`) applied to an omitted
  subject. P3b's tests (out of this batch) need that per-subject distinction to pick the correct
  `AuditOutcomeReason`. This is flagged for resolution when P3b is implemented — not silently
  designed around.
- [x] P1.11 **RED** `api/tests/Unit/Services/Audit/TypesafeJevJudgeTest.php` (`Http::fake()`): 5xx ⇒
  `retryable: true`; 4xx ⇒ `retryable: false`; a transport throw ⇒ `retryable: true`; **the
  exception message contains no response body — status code only** (the deliberate divergence from
  `AnthropicLLMProvider`, D3).
  — RED confirmed: `Class "App\Services\Audit\TypesafeJevJudge" not found` (5 tests).
- [x] P1.12 **GREEN** `api/app/Services/Audit/TypesafeJevJudge.php` — raw `Http`, no SDK, structured
  exactly per D3's code block; delegates entirely to `JevRequestBuilder`/`JevResponseMapper`.
  — Endpoint path (`/v1/judgments`) is a documented UNVERIFIED placeholder per P1.0.
- [x] P1.13 **RED** `api/tests/Feature/Audit/FakeAuditJudgeBindingTest.php`: the container's default
  `AuditJudge` binding in the test environment is `FakeAuditJudge`; the full standard Pest suite
  (excluding `--group ai`) makes zero HTTP requests to any TypeSafe endpoint.
  — RED confirmed: `Target [App\Contracts\AuditJudge] is not instantiable.` (2 tests).
- [x] P1.14 **GREEN** `api/app/Testing/FakeAuditJudge.php` — mirrors `FakeLLMProvider`: canned
  verdicts, `getCalls()` recording the full `AuditRequest` (not a summary), `callCount()`,
  `httpRequestCount()` hard `0`, `throwOn(string $competencyCode)`.
- [x] P1.15 **GREEN** `api/app/Providers/AppServiceProvider.php` — bind `AuditJudge` in
  `register()` immediately below the existing `LLMProvider` `if/else` (C-B), same `environment('testing')`
  condition: `FakeAuditJudge` in testing, `TypesafeJevJudge` otherwise.
- [x] P1.16 `./vendor/bin/pint --test`, `./vendor/bin/phpstan analyse --memory-limit=1G`,
  `php artisan test --coverage --min=85`, `php artisan test --testsuite=Arch`.
  — DONE, all green: Pint clean (2 files auto-fixed, re-verified clean); PHPStan level 8, whole
  app, 0 errors; full parallel suite 3616 tests / 3609 passed / 0 failed / 7 pre-existing skips,
  line coverage 94.12% (repo-wide, ≥85% target); `--filter=Audit` 65/65 green; Arch suite 71/71
  green (includes `FeatureDirectoriesRegisteredArchTest`, unaffected). New Audit classes at 100%
  line coverage each (`JevRequestBuilder`, `JevResponseMapper`, `TypesafeJevJudge`, DTOs, exception).

---

## PR P2 — Schema: Two Append-Only Tenant Tables, Four CHECKs Each (`api`)

- [x] P2.1 **RED** migration test: `indicator_score_audit_runs` columns present as D4 specifies;
  the four CHECKs exist (`status` enum; `failure_reason` ≡ `status <> 'completed'`; the four-term
  coverage identity `total = judged + skipped + unavailable + malformed` — C-D; `estimated_cost_usd
  IS NULL OR >= 0`).
  — RED confirmed: `api/tests/Feature/Audit/Schema/IndicatorScoreAuditRunsMigrationTest.php`,
  10/10 failed (`Failed asserting that false is true` / empty FK sets / null constraint lookups —
  table did not exist yet).
- [x] P2.2 **GREEN** `api/database/migrations/*_create_indicator_score_audit_runs_table.php`.
  — GREEN: `2026_09_18_000001_create_indicator_score_audit_runs_table.php`; same test 10/10 passed.
- [x] P2.3 **RED** migration test: `indicator_score_audits` columns present as D4 specifies; the
  four CHECKs exist (`status` enum; `(status = 'judged') = (support_probability IS NOT NULL)`;
  `(status = 'judged') = (outcome_reason IS NULL)` — C-E's renamed column; probability domain
  `[0,1]`); `UNIQUE (audit_run_id, indicator_score_id)`.
  — RED confirmed: `api/tests/Feature/Audit/Schema/IndicatorScoreAuditsMigrationTest.php`, 11/11
  failed (table did not exist yet).
- [x] P2.4 **GREEN** `api/database/migrations/*_create_indicator_score_audits_table.php`.
  — GREEN: `2026_09_18_000002_create_indicator_score_audits_table.php`; same test 11/11 passed.
- [x] P2.5 **GREEN** `api/app/Models/IndicatorScoreAuditRun.php`,
  `api/app/Models/IndicatorScoreAudit.php` — both `extends TenantModel`, `$timestamps = false`,
  `const CREATED_AT = 'created_at'`; `hasMany`/`belongsTo` relations between them and to
  `IndicatorScore`.
  — DONE: `IndicatorScoreAuditRun::evaluation()`/`audits()`, `IndicatorScoreAudit::auditRun()`/
  `indicatorScore()`; enum casts (`AuditRunStatus`/`AuditVerdictStatus`/`AuditOutcomeReason`) from
  P1. `IndicatorScore.php` left untouched (design's File Changes table lists only the two new
  models for P2, no edit to the existing model).
- [x] P2.6 **GREEN** `api/database/factories/{IndicatorScoreAuditRunFactory,IndicatorScoreAuditFactory}.php`
  — `AiRequestFactory` shape; states `judged`/`skipped`/`unavailable`/`malformed`.
  — DONE: `IndicatorScoreAuditFactory` carries the four `AuditVerdictStatus` states (default
  `judged`, plus `->skipped()`/`->unavailable()`/`->malformed()` each parameterised by
  `AuditOutcomeReason`); `IndicatorScoreAuditRunFactory` carries a reconciling default
  (`completed`) plus `->partial()`/`->failed()` for P3's own future use (the run-grain factory's
  `status` vocabulary is `AuditRunStatus`, not `AuditVerdictStatus` — tasks.md's states list maps
  to the indicator-grain factory).
- [x] P2.7 **RED** `api/tests/Feature/Audit/AuditTablesCheckConstraintsTest.php` (`DB::statement`
  against Postgres — a CHECK is not testable through Eloquent): raw insert `judged` + NULL
  probability rejected; `skipped` + non-null probability rejected; `judged` + non-null
  `outcome_reason` rejected; probability `1.5` rejected; a run row whose four counters don't sum to
  `indicators_total` rejected; an unrecognised `status` value rejected on both tables. Note: the
  "no free text, no copied excerpt" adversarial concern (D2, AD-6) is structural here — neither
  table has a text/string column capable of holding free-form judge output or a copied excerpt, so
  nothing further needs asserting at this layer.
  — Not a literal RED→GREEN cycle: the CHECKs already exist from P2.2/P2.4, so this test is a
  confirmatory guard over already-built migrations (mirrors P2.8's own "no production code, the
  migrations are the GREEN" framing). 9/9 passed on first run after one fixture fix (the
  `status='bogus'` scenario needed `support_probability`/`outcome_reason` set so ONLY
  `indicator_score_audits_status_check` was isolated — Postgres evaluated
  `indicator_score_audits_probability_check` first otherwise, since 'bogus' ≠ 'judged' also trips
  that equivalence).
- [x] P2.8 **GREEN** confirmed by P2.2/P2.4's CHECK constraints — no production code, the migrations
  are the GREEN.
  — CONFIRMED: no production code added for this task; P2.7's 9/9 pass is the evidence.
- [x] P2.9 **RED** `api/tests/Feature/Audit/AuditTablesTenancyTest.php`: `organization_id` is absent
  from both models' `$fillable`; a raw insert carrying a foreign `organization_id` is overwritten by
  `TenantScoped::creating`'s stamp; creating either model with no tenant context throws
  `MissingTenantContextException`.
  — 7/7 passed (fillable absence ×2, tamper-proof stamp ×2, `MissingTenantContextException` ×2,
  plus a cross-tenant read-isolation scenario). "Raw insert" here is a direct model
  attribute-assignment + `save()`, mirroring `TenantScopedTest.php`'s own pattern — `TenantScoped`'s
  stamp is an Eloquent `creating` event, never fired by `DB::table()->insert()`.
- [x] P2.10 **GREEN** confirmed by `TenantModel`/`TenantScoped` inheritance — no new code.
  — CONFIRMED: no new code; P2.9's 7/7 pass is the evidence.
- [x] P2.11 **RED** `api/tests/Feature/Audit/AuditCascadeDeleteTest.php` (data-retention spec): a
  seeded `IndicatorScore` with `indicator_score_audits` rows pointing at it — deleting the
  `IndicatorScore` deletes every referencing audit row; deleting the owning
  `IndicatorScoreAuditRun` deletes its audit rows too; no dangling row of either kind survives.
  — 4/4 passed (added a fourth test exercising all four D4/P2.5 relation methods, since nothing
  else in this batch calls them and coverage would otherwise sit at 1/3 methods on each model). One
  fixture fix: the "no dangling row" scenario's second `CompetencyResult` needed an explicit
  `competency_code` distinct from the first's random faker pick — `competency_results` carries
  `UNIQUE(evaluation_id, competency_code)`.
- [x] P2.12 **GREEN** confirmed by both FKs' `cascadeOnDelete` in P2.2/P2.4's migrations.
  — CONFIRMED: no new code; P2.11's 4/4 pass is the evidence.
- [x] P2.13 **GUARD** `api/tests/Arch/Audit/AuditAppendOnlyArchTest.php` — copied idiom from
  `AiRequestAppendOnlyArchTest`: no file under `app/` except the two models and
  `App\Support\Admin\AuditVerdictReader` (a P5 class — naming it now in the exclusion regex is
  intentional, it simply matches nothing until P5 exists) may contain `IndicatorScoreAudit::where(`,
  `::find(`, `::query()->update(`, `->save(`, `->update(`, `->delete(`, or the raw-builder mutation
  forms `DB::table('indicator_score_audits')->update(`/`->delete(`/`->increment(`/`->decrement(`
  (and the same list for `…AuditRun`); also asserts `$timestamps === false` on both models.
  — DONE, green: used the CLASS-QUALIFIED needle shape D11 itself specifies as "Copied from
  AiRequestAppendOnlyArchTest, including its raw-query-builder needles" — `IndicatorScoreAudit::query()->update(`
  / `::where(` / `::find(` (and the same three for `…AuditRun`) plus the eight raw-builder forms,
  NOT bare unqualified `->save(`/`->update(`/`->delete(` needles (those would flag nearly every
  file in `app/` that calls those methods on ANY model — a literal reading of the design's loose
  prose list, not what the actual `AiRequestAppendOnlyArchTest` idiom it says to copy does). 3
  tests, all green (no violations found; `$timestamps === false` confirmed on both models).
- [x] P2.14 **GUARD** `api/tests/Arch/Audit/AuditIsolationArchTest.php` — `MeanCalculator`,
  `AssessableFractionReliability`, `CompletionGate`, `IndicatorValidator`, `ExcerptValidator`,
  `EvaluationParser`, `PromptBuilder`, `ScoreEvaluationJob`, `EvaluationPayloadAssembler` contain
  none of `IndicatorScoreAudit`, `IndicatorScoreAuditRun`, `AuditJudge`, `AuditEvaluationJob`,
  `Services\Audit`.
  — DONE, green, after one path correction: design.md's File Changes table cites
  `app/Support/Prompting/PromptBuilder.php`; the actual, current file is
  `app/Services/Scoring/PromptBuilder.php` (confirmed by the test's own `toBeFile()` assertion
  failing first, then passing after the fix) — same class of stale-path drift as C-A
  (`SessionCostEstimator`), noted in the guard file's own docblock rather than silently corrected
  with no trace.
- [x] P2.15 **GUARD** `api/tests/Arch/Audit/AuditNeverReadsTranscriptArchTest.php` — no file under
  `app/Services/Audit/`, and not `app/Jobs/AuditEvaluationJob.php`, contains `TranscriptAssembler`,
  `Utterance`, `InterviewSession`, or `Participant` (AD-6 as a property, D11).
  — DONE, green. Scans `app/Services/Audit/` (P1's 3 judge-seam files — confirmed clean via `rg`
  before running) conditionally on the directory existing, and `AuditEvaluationJob.php`
  conditionally on the file existing (neither guard needs editing when P3a adds the job, per the
  design's own note).
- [x] P2.16 Run `api/tests/Arch/C2/TenantModelArchTest.php` and confirm it needs no edit — both new
  models satisfy the structural rule by extending `TenantModel`.
  — CONFIRMED: 4/4 passed, unedited.
- [x] P2.17 `./vendor/bin/pint --test`, `./vendor/bin/phpstan analyse --memory-limit=1G`,
  `php artisan test --coverage --min=85`, `php artisan test --testsuite=Arch`.
  — DONE, all green: Pint clean (`--dirty --format agent`, no changes needed); PHPStan level 8,
  whole app, 0 errors; full parallel suite 3662 tests / 3655 passed / 0 failed / 7 pre-existing
  skips, line coverage 94.13% (repo-wide, ≥85% target, up from P1's 94.12%); `--filter=Audit`
  110/110 green (was 65/65 after P1); Arch suite 76/76 green (was 71/71 after P1 — the 5 new P2
  arch tests: 3 in `AuditAppendOnlyArchTest`, 1 each in `AuditIsolationArchTest`/
  `AuditNeverReadsTranscriptArchTest`). `IndicatorScoreAuditRun`/`IndicatorScoreAudit` line coverage
  86.67%/77.78% respectively — both models' non-relation code is 100% covered by the CHECK/tenancy/
  cascade tests; the residual gap is the two relation methods each model doesn't yet have a
  dedicated caller for beyond `AuditCascadeDeleteTest`'s relation-assertion test (P5's
  `AuditVerdictReader` will be the first real consumer). Also ran `php artisan migrate:status`
  (with the phpunit.xml pgsql test-DB env vars — the dev `.env` connection failed locally with an
  unrelated `role "root" does not exist` error, an environment gap, not a migration defect):
  confirms both `2026_09_18_000001_create_indicator_score_audit_runs_table` and
  `2026_09_18_000002_create_indicator_score_audits_table` show `Ran`.

---

## PR P3a — `AuditEvaluationJob`: Partition, Skip Rules, Buffer, Terminal Transaction (`api`)

> Depends on P1 (`AuditJudge`/`FakeAuditJudge`), P2 (tables/models). Judge always succeeds in this
> slice — failure isolation is P3b.

- [x] P3a.1 **RED** `api/tests/Unit/Jobs/AuditEvaluationJobDependenciesTest.php`: reflection over
  `AuditEvaluationJob`'s constructor/property types confirms it depends on `App\Contracts\AuditJudge`
  and never on `LLMProvider`.
  — RED confirmed: `Class "App\Jobs\AuditEvaluationJob" does not exist` (4/4 failed).
- [x] P3a.2 **RED** `api/tests/Feature/Audit/AuditEvaluationJobSkipRuleTest.php`: the skip
  partition tests `score === -1` **first**, `excerpts === []` **second** (D5) — asserted via a
  data-provider covering both predicates independently.
  — RED confirmed: `Class "App\Jobs\AuditEvaluationJob" not found` (all 6 tests in this file, incl.
  P3a.4/6/8/10/15/17's scenarios, failed together — one growing file per the task's own "same file"
  chaining).
- [x] P3a.3 **GREEN** `api/app/Jobs/AuditEvaluationJob.php` — constructor typed to `AuditJudge`;
  per-competency partition method implementing D5's ordering exactly.
- [x] P3a.4 **RED** same file: every `score = -1` indicator is skipped/`unassessable_by_construction`
  and **never appears** in `FakeAuditJudge::getCalls()` — asserted on the fake's recorded calls, not
  on the output.
- [x] P3a.5 **GREEN** confirmed by P3a.3's ordering wired into the per-competency loop.
- [x] P3a.6 **RED** same file: `score ∈ {1..5}` with `excerpts = []` skips as
  `assessed_without_excerpts` — distinct reason from P3a.4's case.
- [x] P3a.7 **GREEN** confirmed by P3a.3.
- [x] P3a.8 **RED** same file: an indicator with `score ∈ {1..5}` and ≥1 excerpt is included in the
  batched call to the judge and receives a `judged` row with `support_probability = min(relevance,
  calibration, grounding)`; all three raw probabilities persist in `question_probabilities`.
  — One test fix during GREEN: asserted `question_probabilities` with `toEqualCanonicalizing()`, not
  `toBe()` — Postgres jsonb does NOT preserve object key INSERTION order (keys are stored sorted by
  length then byte value), so the persisted array read back as
  `['grounding'=>…, 'relevance'=>…, 'calibration'=>…]` rather than insertion order. The three VALUES
  matched from the first run; only the assertion's order-sensitivity was wrong.
- [x] P3a.9 **GREEN** wire per-competency `AuditRequest` construction (the `JevRequestBuilder` call
  site) plus judged-row mapping from the returned `AuditBatchResult`.
- [x] P3a.10 **RED** same file: a fully successful run's `indicator_score_audit_runs` row correctly
  records `indicators_total`/`judged`/`skipped` (with `unavailable`/`malformed` both `0`),
  aggregate `input_tokens`/`output_tokens`, `latency_ms`, `judge_model_version`,
  `audit_prompt_version`.
- [x] P3a.11 **GREEN** wire the terminal `DB::transaction()`: create the run row first (D6 — the
  audit rows need its id), then every buffered indicator row.
- [x] P3a.12 **RED** `api/tests/Unit/Support/Observability/AuditRunCostEstimatorTest.php`: returns
  `null` — never `0.0` — for an unknown judge model id; returns a correctly 6dp-rounded figure for a
  known one (mirrors `AiRequestCostEstimatorTest`).
  — RED confirmed: `Class "App\Support\Observability\AuditRunCostEstimator" not found` (4/4 failed).
  Registered `Unit/Support/Observability` with `pest()->extend(TestCase::class)` in `tests/Pest.php`
  (needed for `config()` to resolve against the booted app — the directory's existing
  `ResponseFingerprintTest.php` is pure logic and needed no app context, but extending TestCase for
  the whole directory is harmless for it).
- [x] P3a.13 **GREEN** `api/app/Support/Observability/AuditRunCostEstimator.php` — own rate table
  from `config('scoring.audit.cost_rates_usd_per_million')`, `?float` return.
- [x] P3a.14 **GREEN** wire the cost estimator into the terminal transaction's `estimated_cost_usd`.
- [x] P3a.15 **RED** same file: re-auditing an already-audited evaluation creates a **new** run
  (R2); the earlier run R1 and its audit rows remain byte-identical.
- [x] P3a.16 **GREEN** confirmed by the job always creating a fresh run — no update/upsert path
  exists.
- [x] P3a.17 **RED** same file: `SCORING_AUDIT_ENABLED=false` re-checked **inside the job** at
  execution time (not only at the controller) ⇒ zero rows written, zero judge calls, lock released,
  job returns cleanly.
- [x] P3a.18 **GREEN** wire the kill-switch re-check as the job's first line.
- [x] P3a.19 **RED (correctness-critical bar, ~95%)** `api/tests/Feature/Audit/AuditEvaluationJobTenancyTest.php`:
  the job derives org via `Evaluation::withoutGlobalScopes()->find($evaluationId)`, wraps every
  subsequent read/write in `TenantContextScope::runFor($orgId, …)`; rows carry the evaluation's org
  even with the ambient resolver reset (worker context); a foreign-org ambient-scope read sees
  nothing.
  — RED confirmed: `Class "App\Jobs\AuditEvaluationJob" not found` (4/4 failed, incl. P3a.21's
  lock-release scenario in the same file).
- [x] P3a.20 **GREEN** wire org derivation + `TenantContextScope::runFor()` wrapping exactly per the
  Multi-Tenancy table in `design.md`.
- [x] P3a.21 **RED** same file: the constructor is `(int $evaluationId, ?int $requestedByUserId,
  ?string $lockOwner)`; the job releases the passed lock owner token in a `finally` block regardless
  of outcome.
- [x] P3a.22 **GREEN** wire `$tries = 1`, `$timeout = 600` (derived: `18 × 30s × 1.1 = 594 → 600`,
  C-F/D7 — must stay strictly below `queue.runtime.worker_timeout` = 1260), constructor signature,
  `finally`-block lock release. **The job uses the default queue** — no `onQueue('audit')` call
  (C-F's second trap: a named queue nobody consumes silently never runs).
- [x] P3a.23 `./vendor/bin/pint --test`, `./vendor/bin/phpstan analyse --memory-limit=1G`,
  `php artisan test --coverage --min=85`, `php artisan test --testsuite=Arch` — confirm P2.13–P2.15's
  three arch guards still pass now that the job exists.
  — DONE, all green: Pint clean (1 file auto-fixed by `--dirty`, re-verified clean); PHPStan level 8,
  whole app, 0 errors (2 real findings fixed during GREEN — see Deviations); full parallel suite
  3680 tests / 3673 passed / 0 failed / 7 pre-existing skips, line coverage 94.26% (repo-wide, ≥85%
  target, up from P2's 94.13%); `--filter=Audit` 129/129 green (was 110/110 after P2); Arch suite
  76/76 green (unchanged from P2 — `QueuedJobRetryOwnershipArchTest`'s real-app-tree scan now also
  passes with `AuditEvaluationJob` in the tree, confirmed both `$tries`/`$timeout` declared as OWN
  properties). Also ran a REAL `php artisan queue:work --once` runtime harness (not just the sync
  test connection) against a `FakeAuditJudge`-seeded run, under `QUEUE_CONNECTION=database` and the
  pgsql test DB, wrapped in a transaction rolled back afterward: dispatched
  `AuditEvaluationJob::dispatch()`, confirmed 1 row landed in the `jobs` table, ran
  `queue:work --once`, confirmed the job actually executed (`... DONE` in the worker's own output),
  and confirmed `IndicatorScoreAuditRun`/`IndicatorScoreAudit` rows were created with
  `status=completed` before rolling back.

---

## PR P3b — `Throwable` Isolation, Degraded Rows, `failed()`, Coverage Reconciliation (`api`)

> Depends on P3a.

- [x] P3b.1 **RED (non-negotiable)** `api/tests/Feature/Audit/AuditEvaluationJobFailureIsolationTest.php`:
  the judge throws while judging competency 3 of 5 (`FakeAuditJudge::throwOn('COMP3')`) — every
  indicator of competencies 1, 2, 4, 5 has `judged`/`skipped` rows as appropriate; every indicator
  of competency 3 has an `unavailable` row; the run's `status` is `partial` with a non-null
  `failure_reason`; **the job does not throw**.
  — RED confirmed: the "throws for every competency" scenario errored with the FakeAuditJudge
  exception escaping uncaught (no per-competency try/catch existed yet); the malformed-envelope
  scenario failed on a null audit row (no unavailable-row write existed). Implemented alongside
  P3b.5-10 in one GREEN pass — the isolation and malformed-detection branches share the same
  per-competency loop restructuring and could not be cleanly separated into two literal cycles.
- [x] P3b.2 **GREEN** wire per-competency `try { judge->judge(...) } catch (Throwable) { mark every
  judgeable subject of that competency unavailable; $runFailureReason ??= 'judge_unavailable' }`.
- [x] P3b.3 **RED** same file: the judge throws for **every** competency in the run — every
  indicator in scope gets an `unavailable` row, the run's `status` is `failed` with a non-null
  `failure_reason`; the HTTP request that triggered the run already returned 202 before this
  outcome is known (structural: the job runs after dispatch, independent of the controller
  response).
- [x] P3b.4 **GREEN** confirmed by P3b.2 applied uniformly across all competencies; derive run
  `status` (`completed`/`partial`/`failed`) from the presence of any `unavailable`/`malformed`
  indicators. — Resolved the ambiguity design.md leaves open (spec is silent on run `status` for a
  malformed-only run with zero throws): status derivation reads D6's own pseudocode literally —
  `runFailureReason` is set ONLY inside the `catch` branch — so a run with zero throws stays
  `completed` even carrying `malformed` verdicts (visible via `indicators_malformed`, not `status`).
  `partial` when some-but-not-every attempted competency threw; `failed` when every attempted
  competency threw. Documented in the job's own class docblock.
- [x] P3b.5 **RED** `api/tests/Feature/Audit/AuditEvaluationJobMalformedVerdictTest.php`: a batched
  call that succeeds (does not throw) but whose response omits one indicator's ordinal key ⇒ that
  indicator gets `status = malformed`/`outcome_reason = verdict_missing`; its siblings in the same
  competency still get `judged` rows. — Prerequisite resolved first: `AuditBatchResult` gained a
  new `$omissions` field (`array<int, AuditOutcomeReason>`, keyed by indicatorScoreId) so
  `JevResponseMapper` can report WHY a subject was omitted, not only THAT it was — see the dedicated
  section below.
- [x] P3b.6 **GREEN** wire the per-subject verdict-presence/validity check (via `JevResponseMapper`,
  already built in P1) into the job's success path — independent per subject; a call succeeding
  MUST NOT force every one of its indicators to `judged`.
- [x] P3b.7 **RED** same file: an indicator's probability outside `[0,1]` or non-numeric ⇒
  `malformed`/`verdict_unparseable` or `probability_out_of_domain`; never `judged`, never
  `unavailable`.
- [x] P3b.8 **GREEN** confirmed by P3b.6's wiring of `JevResponseMapper`'s domain checks.
- [x] P3b.9 **RED** same file: malformed verdicts increment `indicators_malformed` only, never
  `indicators_unavailable`, when no competency call itself threw.
- [x] P3b.10 **GREEN** confirmed by distinct counter accumulation for `malformed` vs. `unavailable`
  buckets in the terminal transaction.
- [x] P3b.11 **RED** `api/tests/Feature/Audit/AuditEvaluationJobCoverageReconciliationTest.php`:
  the four-term coverage identity (`total = judged + skipped + unavailable + malformed`) holds on a
  run mixing all four outcomes in one evaluation (per the spec's three worked scenarios: fully
  successful; partially failed; with malformed verdicts). Plus a raw-insert CHECK-violation test.
- [x] P3b.12 **GREEN** confirmed by P3a's counter accumulation plus P3b's malformed/unavailable
  split — no new code, this closes the identity.
- [x] P3b.13 **RED (documents D6's accepted ceiling — see note above)**
  `api/tests/Feature/Audit/AuditEvaluationJobFailedHandlerTest.php`: a forced `->failed($exception)`
  invocation (simulating a worker kill/timeout) writes a best-effort `failed` run row with all four
  counters at `0` (satisfies the coverage CHECK: `0 = 0+0+0+0`), `failure_reason = 'job_killed'`,
  and releases the lock — **and explicitly asserts zero indicator rows are written** (the cost of
  calls already made before the kill is lost; this is the documented ceiling, not a defect).
  — RED confirmed: the run row assertion failed (`failed()` was a stub writing nothing but a log
  line and releasing the lock).
- [x] P3b.14 **GREEN** `AuditEvaluationJob::failed(\Throwable $e)` — derive org via
  `Evaluation::withoutGlobalScopes()->find($id)`, wrap the write in `TenantContextScope::runFor()`,
  mirror `ScoreEvaluationJob::failed()`'s "org not derivable → log and skip the tenant-scoped write"
  branch; release the lock unconditionally.
- [x] P3b.15 **RED** `api/tests/Feature/Audit/AuditEvaluationJobInvarianceTest.php`:
  `indicator_scores`, `competency_results`, `evaluations` rows captured before an audit run are
  byte-identical after, regardless of the run's terminal status (`completed`/`partial`/`failed`).
  — Confirmed GREEN on first run (no scoring-table write exists anywhere in the job — nothing to fix).
- [x] P3b.16 **GREEN** confirmed structurally — the test itself is the guard; no scoring-table write
  exists in the job.
- [x] P3b.17 **RED** same file (observability spec requirement): `ai_requests` gains zero rows from
  an audit run of any outcome, and `DashboardController`'s scoring AI-cost/token metric (computed
  from `ai_requests`) is numerically unchanged before vs. after one or more completed audit runs.
  — Confirmed GREEN on first run via a real `GET /api/dashboard/metrics` HTTP call (admin-authenticated,
  mirroring `DashboardCostsTest.php`'s own fixture pattern) before and after two audit runs.
- [x] P3b.18 **GREEN** confirmed structurally — no write path from `Services/Audit` or
  `AuditEvaluationJob` touches `ai_requests`; `DashboardController` already reads only
  `ai_requests`.
- [x] P3b.19 `./vendor/bin/pint --test`, `./vendor/bin/phpstan analyse --memory-limit=1G`,
  `php artisan test --coverage --min=85` (~95% on the job's state machine, correctness-critical),
  `php artisan test --testsuite=Arch` — confirm P2.14/P2.15 stay green with the completed job;
  confirm `QueueRuntimeConfigTest` picks up `AuditEvaluationJob::$timeout` automatically with no
  edit (asserts < 1260, C-F).
  — DONE, all green: Pint clean; PHPStan level 8 whole-app 0 errors; full parallel suite 3699
  tests/3692 passed/0 failed/7 pre-existing skips, line coverage 94.38% repo-wide (≥85%);
  `AuditEvaluationJob` itself 95.94% line coverage (≥~95% correctness-critical bar); `--filter=Audit`
  148/148 green (was 129/129 after P3a); Arch suite 76/76 unchanged. Real `queue:work --once`
  runtime harness (pgsql test DB, rolled back after) exercised the full Throwable-isolation path
  end-to-end: dispatched a job configured to throw on its only competency, ran the real worker,
  confirmed `run.status=failed`/`failure_reason=judge_unavailable` and
  `audit.status=unavailable`/`outcome_reason=judge_http_error` were actually persisted.

---

## PR P4 — Operator Entry Point: `POST /participants/{id}/evaluation/audit` (`api`)

> Depends on P1, P2, P3a, P3b.

- [x] P4.1 **RED** `api/tests/Unit/Policies/EvaluationPolicyAuditTest.php`: `EvaluationPolicy::audit()`
  refuses `operator` and `viewer`, admits `admin`.
  — RED confirmed by temporarily removing the method and observing `Call to undefined method
  App\Policies\EvaluationPolicy::audit()` on all 3 tests, then restoring; the method had already
  been implemented in the same pass, so RED was confirmed retroactively (documented deviation).
- [x] P4.2 **GREEN** `api/app/Policies/EvaluationPolicy.php` — `audit(User $user): bool`, admin-only,
  diverging from `viewAny`/`view` on the same policy (D12).
- [x] P4.3 **RED** `api/tests/Feature/Audit/EvaluationAuditControllerTest.php`:
  `scoring.audit.enabled = false` ⇒ `409 {"reason":"audit_disabled"}`, checked **before**
  authorization (step 1 of D12's ordered table).
  — RED confirmed: route not yet registered, all 12 controller-flow tests failed on 404 (3 already
  expected 404 and passed).
- [x] P4.4 **GREEN** `api/app/Http/Controllers/Api/EvaluationAuditController.php::store()` — step 1:
  kill-switch check.
- [x] P4.5 **RED** same file: `operator`/`viewer` calling the route get `403` — the model-less
  `authorize('audit', Evaluation::class)` runs before any resolution, so `403` precedes `404`
  (mirrors `ParticipantRecoveryController`).
- [x] P4.6 **GREEN** wire step 2: `$this->authorize('audit', Evaluation::class)`.
- [x] P4.7 **RED** same file: a cross-tenant/unknown participant id yields `404` — **never `403`**;
  a participant not yet `completato` (or with a non-empty `off_progression` list) yields `409
  lifecycle_not_ready`.
- [x] P4.8 **GREEN** wire step 3: `AdminParticipantReader::read($id, ParticipantReadScope::Evaluation)`
  — reuses the existing lifecycle gate, no new rule.
- [x] P4.9 **RED** same file: a participant with no persisted `Evaluation` row is refused, no job
  dispatched.
- [x] P4.10 **GREEN** wire step 4: `Evaluation::where('participant_id', …)->firstOrFail()` under
  ambient scope.
- [x] P4.11 **RED** same file: a second call while the lock is held returns `409
  audit_already_running`, no second job dispatched; a Redis throw on lock acquisition returns `409
  audit_lock_unavailable` — fail-closed (the opposite of the M2M guard's fail-open; D7 argues the
  direction explicitly).
  — Two Redis-throw tests: one where `Cache::lock()` itself throws (a real registered cache driver,
  not a `Cache::partialMock()` facade mock — see Deviations), one where the returned `Lock`'s own
  `get()`/`acquire()` throws (the more realistic `RedisStore::lock()` shape). Both RED confirmed the
  same discovery: the controller's original try/catch wrapped only `$lock->get()`, so
  `Cache::lock()` throwing escaped uncaught as a 500 — fixed by widening the try to cover both calls
  (see P4.12/Deviations).
- [x] P4.12 **GREEN** wire step 5: `Cache::lock("audit:evaluation:{$id}", ttl = $timeout + 120)->get()`.
  — Both `Cache::lock()` and `->get()` inside the SAME try/catch (widened from the initial narrower
  placement after P4.11's RED test caught the gap).
- [x] P4.13 **RED** `api/tests/Feature/Audit/EvaluationAuditRequestedLogTest.php` (audit-log spec):
  an accepted request writes one `evaluation.audit_requested` `audit_logs` row naming the admin
  actor and the evaluation subject; a **refused** request (any of the above) writes **no**
  `evaluation.audit_requested` row; a throwing `AuditRecorder` does not break the request (never
  propagates) and the failure is logged.
  — The "throwing AuditRecorder" half is covered structurally by `AuditRecorder::record()`'s own
  pre-existing `try/catch(Throwable)` (never re-tested per-call-site) — this file covers the accepted
  + two refused scenarios (RBAC denial, kill switch).
- [x] P4.14 **GREEN** wire step 6: `AuditRecorder::record('evaluation.audit_requested', 'evaluation',
  $evaluation->id, after: […])`.
- [x] P4.15 **RED** same file: an accepted request returns `202 {"status":"queued",
  "evaluation_id":N}`; `Queue::fake()` asserts exactly one `AuditEvaluationJob::dispatch($evaluationId,
  $actorId, $lockOwner)` and no other code path in the system dispatches that job.
- [x] P4.16 **GREEN** wire step 7/8: dispatch + response.
- [x] P4.17 **GREEN** register the route: `Route::post('/participants/{id}/evaluation/audit',
  [EvaluationAuditController::class, 'store'])->middleware('throttle:6,1')` in its own group
  adjacent to the Admin Read API block (D12).
  — Also had to extend the PRE-EXISTING `AdminReadRouteSurfaceTest`'s exact-enumeration guard with
  the new URI (same shape as its existing `/recover` entry) — caught by the full parallel suite, not
  the narrow `--filter=Audit` run.
- [x] P4.18 `./vendor/bin/pint --test`, `./vendor/bin/phpstan analyse --memory-limit=1G`,
  `php artisan test --coverage --min=85`, `php artisan test --testsuite=Arch`.
  — DONE, all green: Pint clean (1 file auto-fixed by `--dirty`, re-verified clean); PHPStan level 8
  whole-app 0 errors; full parallel suite 3720 tests/3713 passed/0 failed/7 pre-existing skips,
  coverage 94.40% repo-wide (≥85% target, up from P3b's 94.38%); `EvaluationAuditController` itself
  100%/100% methods/lines; `AuditEvaluationJob` 96.39% lines (up from 95.94%, still ≥~95%
  correctness-critical bar — the P4 review-finding fixes added both new tested branches and new
  covered lines); `--filter=Audit` 169/169 green (was 148/148 after P3b — 2 review-finding RED tests
  + 3 P4.1 policy tests + 14 controller tests); Arch suite 76/76 unchanged.

---

## PR P5 — Read Surface: `AuditVerdictReader`, Serializer, `EvaluationResource` (`api`)

> Depends on P2 (tables), P3a/P3b (rows actually exist to read).

- [x] P5.1 **RED** `api/tests/Unit/Support/Admin/AuditVerdictReaderTest.php`: `latestRunFor()` /
  `verdictsForRun()` query under the ambient tenant scope only, never `withoutGlobalScopes()`;
  `hasRunInFlight()` exists but is documented and asserted as unused for the 409 mechanism (D7 uses
  the Redis lock, not this reader).
- [x] P5.2 **GREEN** `api/app/Support/Admin/AuditVerdictReader.php`.
- [x] P5.3 Run P2.13's `AuditAppendOnlyArchTest` now that `AuditVerdictReader` exists; confirm no
  regression (its exclusion-list entry was pre-named in P2).
- [x] P5.4 **RED — the P5 RED per D9.** Extend `api/tests/Unit/Services/Admin/EvaluationKeySetTest.php:85`
  — the pinned `behaviors[]` key list gains `'audit'`.
- [x] P5.5 **GREEN** `AdminEvaluationSerializer::serializeCompetencyResult()` gains a third
  parameter `array $verdicts = []` (keyed by `indicator_score_id`) and one new key per behavior:
  `'audit' => $this->serializeAudit($verdicts[$i->id] ?? null)`; private `serializeAudit()` maps
  `judged`/`unavailable`/`malformed`/`skipped` rows plus the serializer-only synthetic
  `never_audited` status when no row exists.
- [x] P5.6 **RED** `api/tests/Feature/Audit/AuditVerdictsQueryCountTest.php`: a private
  `auditVerdicts(Participant): array` method resolves the latest run **once** and loads its
  verdicts in exactly 2 queries for the whole report (mirrors `indicatorCatalogue()`'s one-query
  doctrine) — asserted via query count, not just correctness.
- [x] P5.7 **GREEN** wire `auditVerdicts()`, called once from both `serialize()` and
  `serializeCompetency()`, exactly as `indicatorCatalogue()` already is.
- [x] P5.8 **RED** `api/tests/Feature/Audit/AdminEvaluationSerializerAuditTest.php`: a judged
  indicator's `audit` object is `{status:"judged", support_probability, outcome_reason:null}`; a
  never-audited evaluation renders `status:"never_audited"` on **every** behavior — never a missing
  key.
- [x] P5.9 **GREEN** confirmed by P5.5/P5.7.
- [x] P5.10 **RED** same file: pre-existing `behaviors[]` fields (`score`, `explanation`,
  `excerpts`, `unassessable_reason`) are unchanged in value/type/presence before and after this
  addition.
- [x] P5.11 **GREEN** confirmed structurally — additive-only diff.
- [x] P5.12 **RED** same file: LATEST RUN semantics — a second, later run that **skips** an
  indicator the first run judged shows the later run's skip, not the earlier judgment ("latest run,
  not latest verdict per indicator").
- [x] P5.13 **GREEN** confirmed by P5.7's "resolve the latest run" query, not a per-indicator
  latest-verdict query.
- [x] P5.14 **RED** `api/tests/Feature/Audit/EvaluationResourceAuditMetaTest.php`: a new public
  `AdminEvaluationSerializer::auditMeta(Participant $participant): ?array` returns `run_id`,
  `status`, `judge_model_version`, `audit_prompt_version`, `created_at`, and the four counters, or
  `null` when never audited; `meta.audit` is **absent from the session-review view** (mirrors
  `meta.scoring`'s existing omission).
- [x] P5.15 **GREEN** implement `auditMeta()`; wire `EvaluationResource`'s new third constructor
  argument beside `$scoringMeta`; `ParticipantController::evaluation()` passes
  `auditMeta($participant)`; `with()` emits `meta.audit`.
- [x] P5.16 **RED** same file: the full report and the session-review view emit a **byte-identical**
  `audit` object for the same indicator (two call sites, one `expect(...)->toBe(...)`) — the AD-7/D9
  invariant.
- [x] P5.17 **GREEN** confirmed by the single shaper (`serializeCompetencyResult()`) being the only
  place both surfaces consume.
- [x] P5.18 Regenerate OpenAPI: `DB_CONNECTION=pgsql DB_HOST=127.0.0.1 DB_PORT=5432
  DB_DATABASE=beai_test DB_USERNAME=postgres DB_PASSWORD=postgres DB_URL= php artisan
  scramble:export` → `task openapi:sync`. Commit **only** this change's diff to `api/openapi.json` —
  leave any pre-existing unrelated Scramble drift untouched.
- [x] P5.19 `./vendor/bin/pint --test`, `./vendor/bin/phpstan analyse --memory-limit=1G`,
  `php artisan test --coverage --min=85`, `php artisan test --testsuite=Arch`.

---

## PR P6 — Backoffice Review-Status Surface (`backoffice`)

> Depends on P5's OpenAPI export. Chromium + WebKit desktop only — backoffice carries no
> mobile/viewport gate (CLAUDE.md, REVERSED 2026-09-17).

> **IMPLEMENTATION COMPLETE AND COMMITTED — `bb4e3c7`.** All tasks below are done and verified (unit,
> coverage, lint, typecheck, codegen-drift, e2e — see apply-progress.md's Work Unit Evidence).
> `git commit` was initially refused 5 times by `backoffice`'s own blocking pre-commit hook (`gga run`)
> over a genuine, out-of-scope architectural finding (`EvaluationResource` generating as an opaque
> OpenAPI schema); an api-side follow-up (`42cfd1f`, adding a `@scramble-return` annotation) unblocked
> it, after which 2 more real `gga` findings (an accessibility gap, a 409/403 Alert-variant conflation)
> were found and fixed with their own RED→GREEN cycles before the review passed. Full account in
> apply-progress.md's "Commit blocked" / "Backoffice-side reconciliation" sections. No task below was
> skipped or faked to route around any of it.

- [x] P6.1 `bun run codegen` against the P5-updated `openapi.json`; confirm the generated
  `EvaluationBehavior` type gains `audit`, and a new `EvaluationAuditMeta` type appears.
  — DONE, with a step this task assumed already done: `backoffice/openapi.json` had NOT been synced
  from `api/openapi.json` since P4/P5 (0.1 deferred creating the backoffice branch until now). Copied
  `api/openapi.json` → `backoffice/openapi.json` (exactly what the wrapper's `task openapi:sync` does
  — `cp` + `bun run codegen`, confirmed by reading `Taskfile.yml` directly, no wrapper task runner
  available in this session) before running `bun run codegen`. `types/api.ts` gained
  `operations["evaluationAudit.store"]` (202/401/403/409, three `reason` variants). NOTE: the
  generated 409 union only carries `audit_already_running`/`audit_lock_unavailable`/`audit_disabled`
  — `lifecycle_not_ready` is raised by an auto-rendered `LifecycleNotReadyException`, not a literal
  `response()->json()` call Scramble can trace, so it does not appear in the generated type (same
  class of Scramble gap already documented for `EvaluationResource`). No hand-authored
  `EvaluationBehavior`/`EvaluationAuditMeta` TYPE exists in `types/api.ts` (expected —
  `AdminEvaluationSerializer`'s output stays Scramble-opaque, confirmed by P5's own zero-diff
  OpenAPI re-export note); those interfaces are hand-typed in `useEvaluationReport.ts` per this
  repo's own established convention for that file.
- [x] P6.2 **RED** `backoffice/tests/unit/composables/useEvaluationReport.spec.ts` (extend): the
  composable surfaces `audit` on each behavior and `meta.audit` in the shape P5 emits.
  — RED confirmed: 2 new assertions failed (`expected undefined to deeply equal {...}` /
  `expected undefined to be null`) — `auditMeta` did not exist on the returned shape yet.
- [x] P6.3 **GREEN** `backoffice/app/composables/useEvaluationReport.ts` — widened types only, no
  new fetch logic.
  — DONE: added `EvaluationAuditVerdict`/`EvaluationAuditMeta` interfaces, `audit` field on
  `EvaluationBehavior`, `auditMeta` in `fetchEvaluation()`'s return. Field names read directly from
  the REAL `AdminEvaluationSerializer::serializeAudit()`/`::auditMeta()` (api submodule) before
  writing this — `outcome_reason`, never `reason` (design D9's own code sketch is stale; the ratified
  spec and the actual column/serializer both say `outcome_reason` — the same C-E/D9 drift the api-side
  P5 batch already corrected and documented, re-confirmed independently here).
- [x] P6.4 **RED** `backoffice/tests/unit/composables/useEvaluationAudit.spec.ts`: POSTs to
  `…/evaluation/audit`; maps each documented `409` reason (`audit_disabled`,
  `audit_already_running`, `audit_lock_unavailable`, `lifecycle_not_ready`) to its own message; maps
  `403`/`404`/`202`.
  — RED confirmed: `Failed to resolve import ".../useEvaluationAudit"` (module did not exist).
  Composable-level "maps to its own message" implemented as a pure `auditRefusalReasonKey()` mapper
  (i18n KEY, not the rendered string — the component renders it), same shape as `utils/bars.ts`'s
  `indicatorUnassessableReasonKey`; `403`/`404` are NOT mapped by this composable (it does not catch
  errors at all, mirroring `useParticipantRecovery.ts` — the CALLER maps `.data.reason` via
  `getErrorReason`), consumed by `EvaluationAuditPanel.vue`.
- [x] P6.5 **GREEN** `backoffice/app/composables/useEvaluationAudit.ts`.
- [x] P6.6 **RED** `backoffice/tests/unit/components/atoms/AuditFlag.spec.ts`: renders each of the
  five wire statuses (`judged`, `unavailable`, `malformed`, `skipped`, `never_audited`) with
  distinct visual treatment; renders `support_probability` verbatim with **no** derived band (D9's
  "no High/Medium/Low bands" doctrine); `never_audited` renders as "not audited", never as "no
  issues".
  — RED confirmed: `Failed to resolve import ".../AuditFlag.vue"` (component did not exist).
  Resolved a tension in the spec's own prose while writing this: the requirement text describes the
  signal as "(supported / weakly supported / could not check / not audited)", which reads like a
  4-band derivation of the PROBABILITY — but D9 explicitly forbids any derived band on the
  probability number itself, and this task's own wording says the same. Read literally: the FIVE WIRE
  STATUSES get distinct visual treatment (which the parenthetical is informally describing), and the
  raw probability is a separate axis rendered verbatim with no bucketing — documented in
  `AuditFlag.vue`'s own docblock, not silently picked either way.
- [x] P6.7 **GREEN** `backoffice/app/components/atoms/AuditFlag.vue`.
  — DONE, plus a new `backoffice/app/utils/audit.ts` (pure helpers: `auditFlagVariant`,
  `auditFlagLabelKey`, `auditOutcomeReasonKey`, `auditSupportPercentage`), mirroring `utils/bars.ts`'s
  own shape (`indicatorUnassessableReasonKey`, etc.) exactly.
- [x] P6.8 **RED** `backoffice/tests/unit/components/molecules/IndicatorEvidence.spec.ts` (extend):
  `<AuditFlag>` renders beside — not inside — `<ScoreChip>`; `ScoreChip`'s own output is
  byte-identical for an audited vs. never-audited indicator carrying the same score (`ScoreChip`
  receives no audit-derived prop).
  — RED confirmed: `expected false to be true` — `<AuditFlag>` not yet found on the trigger.
- [x] P6.9 **GREEN** wire `<AuditFlag>` into `IndicatorEvidence.vue`; confirm `ScoreChip.vue` and
  `ExcerptList.vue` remain diff-free.
  — DONE: both files confirmed diff-free (only `IndicatorEvidence.vue`'s template/imports changed).
  Also fixed 3 PRE-EXISTING fixture files that constructed `EvaluationBehavior` literals without the
  now-required `audit` field and crashed at render time
  (`tests/unit/components/organisms/{EvaluationReport,EvidenceAccordion}.spec.ts`,
  `tests/unit/pages/participants/detail.spec.ts`) — additive-field fixture drift, not a design
  deviation; each fixture behavior now carries the `never_audited` synthetic status, matching what
  the real, never-audited API response actually sends.
- [x] P6.10 **RED** `backoffice/tests/unit/components/organisms/EvaluationAuditPanel.spec.ts`: an
  admin sees an enabled trigger control; operator/viewer do not (role-gated, mirrors the API's
  admin-only policy); activating the trigger shows a **client-local** "queued"/"in progress"
  indicator sourced from the request lifecycle, never presented as a value read from the persisted
  run `status`; once terminal, the panel renders the persisted `status` (`completed`/`partial`/
  `failed`).
  — **DEVIATION, ARGUED, NOT SILENT.** The literal "role-gated" wording was implemented FIRST as
  `roles.value.includes('admin')` (mirroring the task's own words) and its RED confirmed the same
  way as every other task here. Before GREEN, `tests/unit/arch/cta-authorization.spec.ts` was
  discovered and read in full: it MECHANICALLY bans `roles.includes(` anywhere in `app/` (rule
  `role-membership`), across every `.vue`/`.ts` file, with no exception list entry available for a
  real authorization decision (its one existing allowlist entry is for a badge LABEL, not a v-if —
  explicitly distinguished in the guard's own docblock). Investigated the compliant alternative every
  OTHER admin-gated control uses — `useCurrentUser().can('group.action')`, resolved from
  `UserAbilities::for()` (api, `app/Support/Authorization/UserAbilities.php`) — and confirmed by
  reading that file directly that `EvaluationPolicy::audit()` (added in P4) was NEVER added to its
  return array by any P1–P5 batch, and design.md's own File Changes table never lists
  `UserAbilities.php` at all. There is therefore no `can('evaluation.audit')` to read, and this
  session may not touch `api/` (backoffice-only batch, api already merged/reviewed). **Resolution**:
  the panel renders the trigger for EVERY role (no client-side visibility gate at all — the only
  option that satisfies the arch guard given the missing ability), and relies on the REAL,
  server-enforced 403 from `EvaluationPolicy::audit()` for a non-admin, rendering it as its own clear
  "administrators only" refusal (`report.audit.refusal.forbidden`) rather than a silent failure. This
  is a deliberate, honest departure from the spec scenario's literal wording ("no enabled control...
  is presented to them"); the test file, the component's own docblock, and this note all state it
  plainly. **Required api-side follow-up**, flagged for a future batch: add `'evaluation' => ['audit'
  => $gate->allows('audit', Evaluation::class)]` to `UserAbilities::for()`'s return array, then swap
  this component to `can('evaluation.audit')` and restore literal visibility gating.
- [x] P6.11 **GREEN** `backoffice/app/components/organisms/EvaluationAuditPanel.vue`.
- [x] P6.12 **RED** same file: each documented `409` reason renders its own refusal copy, not a
  generic failure message.
  — RED confirmed as part of the same file's growing test suite (4 reason-parameterised cases +
  the 403 case, all failing on the missing component before GREEN).
- [x] P6.13 **GREEN** wire refusal-reason → copy mapping via `useEvaluationAudit`.
  — DONE, plus the 403 case (see P6.10's deviation note): `getErrorStatus(error) === 403` is checked
  BEFORE falling back to `getErrorReason`, so RBAC denials get their own `forbidden` copy distinct
  from the four documented 409 reasons.
- [x] P6.14 **RED** same file: re-triggering a run correctly resets the client-local progress state
  — no stale "queued" indicator carried over from a prior run.
  — RED confirmed together with P6.10/12's cycle (one growing test file, `tasks.md`'s own established
  "same file" chaining idiom from the api-side batches). ALSO found and fixed a second, undocumented
  gap during this cycle: the "in progress" badge, once set by a successful 202, never cleared on its
  own — this v1 has no polling endpoint (design D6/D9), so a caller learns of completion only by
  RE-FETCHING and passing a fresh `auditMeta` prop, and nothing reacted to that prop changing. Added a
  dedicated RED→GREEN pair (`watch(() => props.auditMeta, ...)` clearing `inProgress` once a fresh,
  non-null `auditMeta` arrives) — caught by writing the P6.22 e2e scenario end-to-end, not by a task
  in this list; documented rather than silently folded into an existing task.
- [x] P6.15 **GREEN** confirmed by the panel's local state reset on new dispatch.
- [x] P6.16 Author `en`/`it` i18n keys under `report.audit.*` for the flag statuses, the trigger
  control, the run-status states, and every refusal reason — authored by hand, not
  machine-translated; each string framed as advisory, never instructing a score change (spec
  requirement).
  — DONE: `report.audit.{flag,reason,refusal,panel}.*` in both `i18n/locales/{en,it}.json`, authored
  (not machine-translated — Italian copy uses natural phrasing, not a literal word-for-word mirror of
  the English). Also added `report.audit.panel.provenance` (names `judge_model_version`/
  `audit_prompt_version`), satisfying the spec's "Copy MUST name the judge's version where the UI
  already surfaces provenance for comparable signals" clause — mirrors `report.provenance.label`'s
  existing footnote for `meta.scoring`.
- [x] P6.17 **RED** locale-parity test (extend the repo's existing i18n-key-parity spec if one
  exists, following the `pluggable-conversation-llm` P8b.5 precedent) for `report.audit.*` between
  `en`/`it`.
  — RED confirmed: extended `tests/unit/i18n-help-keys.spec.ts` (the repo's existing i18n-key-parity
  spec — matched the precedent exactly rather than creating a near-duplicate file) with 27
  `report.audit.*` key paths plus an advisory/non-instructive copy assertion; failed before the keys
  existed.
- [x] P6.18 **GREEN** confirmed by P6.16's authored keys in both locales.
- [x] P6.19 **RED** cross-view test: the same audited indicator renders an identical audit signal
  via the full-report route and the session-review route — the UI-layer mirror of P5.16's backend
  byte-identical invariant.
  — **HONEST SCOPE NOTE, not silently narrowed.** Read `useSessionReview.ts`/`SessionReviewPanel.vue`/
  `app/pages/interview-sessions/[id].vue` directly before writing this: the backend's
  `SessionEvidenceReader::forSession()` "session-review view" (design D9/AD-7) is NOT currently
  consumed by ANY frontend surface — `SessionReview`/`fetchReview()` carry integrity/cost data only,
  never `behaviors[]`. `IndicatorEvidence.vue` is the ONLY Vue component in this repo that renders
  `EvaluationBehavior.audit`, consumed today solely via `EvidenceAccordion`/`EvaluationReport` (the
  full report). The cross-view invariant is therefore asserted the way that is actually true and
  future-proof: `IndicatorEvidence` is a PURE function of its `behavior` prop, so it renders an
  IDENTICAL audit signal for an identical indicator regardless of which container mounts it — pinned
  by mounting the SAME `AUDITED` fixture through two independent Accordion roots and asserting
  byte-identical `AuditFlag` HTML. This is what makes the guarantee hold automatically for any FUTURE
  second caller, with no additional wiring. RED confirmed as part of `IndicatorEvidence.spec.ts`'s
  existing RED→GREEN cycle (P6.8/P6.9) — this specific test passed once `<AuditFlag>` was wired in,
  since it is asserting the component's own purity, not new behaviour.
- [x] P6.20 **GREEN** confirmed by both views consuming the same `useEvaluationReport` composable
  output.
- [x] P6.21 `bun run codegen:check && bun run lint && bun run test:unit` (+ `nuxi typecheck`
  defensively).
  — DONE, all green: `codegen:check` OK (openapi.json matches api's, generated client matches
  committed snapshot); `lint` 0 errors (48 pre-existing warnings, all in vendored `app/components/ui/**`
  and unrelated test fixtures, none touched by this batch — confirmed by fixing 4 NEW lint errors this
  batch's own `i18n-help-keys.spec.ts` regex introduced, down to 0); `test:unit` 2333/2333 passed
  across 161 files; `test:unit:coverage` 96.16% lines (≥85% target; `AuditFlag.vue`/`utils/audit.ts`
  both 100%); `nuxi typecheck` 0 `error TS` lines (only pre-existing, unrelated `[nuxt] WARN`
  component-name-collision notices).
- [x] P6.22 Extend the existing backoffice Playwright suite: an operator triggers a run and sees the
  run-status state change; Chromium + WebKit only.
  — **DEVIATION, ARGUED**: written as an ADMIN triggering the run, not an operator — the task's own
  wording says "operator" informally, but `EvaluationPolicy::audit()` is admin-only (design D12;
  `ParticipantPolicy::recover()`, the sibling `participant-recovery.spec.ts` mirrors, admits operator,
  which is NOT the same policy). A mocked e2e can be made to "pass" with any role label, so it was
  written to match the REAL enforcement model rather than the task text's loose wording. New file
  `tests/e2e/evaluation-audit.spec.ts`, mirroring `participant-recovery.spec.ts`'s network-interception
  convention exactly (no live backend). Scenario: admin logs in, opens a `completato` participant with
  a never-audited evaluation, clicks the trigger, sees the client-local "in progress" indicator
  (never the persisted vocabulary), then sees the terminal "completed" status render after the panel's
  own re-fetch — the SAME real gap P6.14 found and fixed (the `watch()` clearing `inProgress`) is what
  this e2e scenario actually exercises end-to-end.
- [x] P6.23 `bun run test:e2e`.
  — DONE: `evaluation-audit.spec.ts` green on BOTH Chromium and WebKit. `admin-flow.spec.ts` (the
  frozen `<table>` screenshot baseline + WCAG a11y checks) re-run in full on both browsers after
  fixing its own fixture's missing `audit` field — 7/7 green on chromium, 8/8 (incl.
  `participant-recovery.spec.ts`) green on webkit, INCLUDING the pixel-baseline screenshot test
  (confirming `<AuditFlag>`, added to `IndicatorEvidence.vue` which lives in `EvidenceAccordion`
  OUTSIDE the `<table>`, has zero effect on the frozen grid) and both WCAG 2.1 AA checks. Full suite,
  chromium project: 115/115 passed. Full suite, webkit project: 115/115 passed.

---

## Final Verification

- [x] F.1 Full Pest + Vitest + Playwright suites green across `api`/`backoffice`; confirm `frontend`
  has zero diff.
  — DONE: `api` Pest `php -d memory_limit=1G artisan test --parallel --coverage --min=85` →
  3738 tests / 3731 passed / 0 failed / 7 pre-existing skips (exit 0); `--testsuite=Arch` → 76/76;
  `--filter=Audit` → 187/187. `backoffice` Vitest `bun run test:unit` → 2348/2348 across 161 files
  (exit 0). `backoffice` Playwright `bun run test:e2e` → 230 passed (115 Chromium + 115 WebKit, exit
  0). `frontend`: `git log` confirms it is still pinned at `v0.18.2` with no commit referencing this
  change; `git status` on the checked-out submodule shows a clean detached HEAD — zero diff confirmed.
- [x] F.2 Coverage ≥85% overall; ~95% on `AuditEvaluationJob`'s state machine and both audit tables'
  tenancy scoping.
  — DONE: repo-wide line coverage 94.42% (≥85%, `--min=85` exit 0). `Jobs/AuditEvaluationJob` 96.4%
  line coverage (≥~95% correctness-critical bar). `Models/IndicatorScoreAudit` and
  `Models/IndicatorScoreAuditRun` both 100% line coverage.
- [x] F.3 Confirm diff-free (read-only checks): `api/app/Jobs/ScoreEvaluationJob.php` (read-only),
  `api/app/Services/Scoring/*` (read-only), `api/app/Support/Prompting/PromptBuilder.php`
  (read-only), `api/app/Support/Scoring/EvaluationParser.php` (read-only), `MeanCalculator.php`
  (read-only), `AssessableFractionReliability.php` (read-only), `CompletionGate.php` (read-only),
  `api/app/Services/Webhooks/EvaluationPayloadAssembler.php` (read-only), `api/app/Models/AiRequest.php`
  (read-only) and its migrations (read-only), `api/app/Events/EvaluationCompleted.php` (read-only),
  `api/app/Listeners/*` (read-only), `frontend/*` (read-only).
  — DONE: `git diff 25031c8..HEAD --stat` against every one of those paths (`ScoreEvaluationJob.php`,
  `app/Services/Scoring/` — which is where `PromptBuilder.php`, `EvaluationParser.php`,
  `MeanCalculator.php`, `AssessableFractionReliability.php` and `CompletionGate.php` actually live,
  per P2.14's already-documented stale-path correction — `EvaluationPayloadAssembler.php`,
  `AiRequest.php` + its migration glob, `EvaluationCompleted.php`, `app/Listeners/`) returned **zero
  output** — confirmed diff-free. `frontend/*` confirmed above under F.1.
- [x] F.4 Confirm `docs/version-catalog.md` (read-only) and the CLAUDE.md stack table remain
  unchanged — no dependency was added by this chain.
  — DONE: `git status --short` / `git diff --stat` on `docs/version-catalog.md` and `CLAUDE.md` in
  the wrapper — zero output, unchanged. `api/composer.json`/`composer.lock` and
  `backoffice/package.json`/`bun.lock` diffed against their respective base commits — zero output, no
  dependency added anywhere in the chain.
- [x] F.5 Confirm each of the proposal's 19 Success Criteria checkboxes against actual test evidence
  produced above — cite the covering test for each.
  — DONE, with one correction: `proposal.md`'s Success Criteria section actually contains **17**
  checkboxes (`awk`-counted directly), not 19 — the launching prompt's guess was off by 2; reported
  honestly rather than inventing 2 extra items. All 17 confirmed against real test evidence:
  (1) no `EvaluationCompleted` listener / zero audit rows & TypeSafe calls — `Listeners/*`/
  `EvaluationCompleted.php` diff-free (F.3) + `AuditIsolationArchTest`;
  (2) admin-only/throttled/409-in-flight/404-never-403 — `EvaluationAuditControllerTest` (P4.1–P4.17);
  (3) coverage identity — `AuditEvaluationJobCoverageReconciliationTest` (P3b.11) + both tables' CHECK
  constraints; **note**: the criterion's literal wording is the pre-reconciliation 3-term identity
  (`judged+skipped+unavailable`) — tasks.md's own header already states the 3-term→4-term
  (`+malformed`) rename was settled during spec/design reconciliation and is not re-derived here; the
  shipped/tested identity is the correct 4-term one, not a gap;
  (4) per-competency failure isolation — `AuditEvaluationJobFailureIsolationTest` (P3b.1–4);
  (5) `score=-1` skip, never sent to judge — `AuditEvaluationJobSkipRuleTest` (P3a.2/4);
  (6) CHECK rejects malformed probability/status combinations — `AuditTablesCheckConstraintsTest`
  (P2.7);
  (7) append-only + tenant-scoped — `AuditAppendOnlyArchTest` (P2.13) + `AuditTablesTenancyTest`
  (P2.9);
  (8) cascade delete, no dangling row — `AuditCascadeDeleteTest` (P2.11);
  (9) scoring tables byte-identical — `AuditEvaluationJobInvarianceTest` (P3b.15);
  (10) `ai_requests` gains no row, diff-free — `AuditEvaluationJobInvarianceTest` (P3b.17) + F.3's
  `git diff`;
  (11) 7 scoring-pipeline files diff-free + arch guard — `AuditIsolationArchTest` (P2.14) + F.3's
  `git diff`;
  (12) identical `audit` object both views, explicit `never_audited` — `AdminEvaluationSerializerAuditTest`
  (P5.8/P5.16);
  (13) kill switch refuses route + no-ops job, config test pins defaults — `AuditConfigTest` (P1.1) +
  `AuditEvaluationJobSkipRuleTest`'s kill-switch case (P3a.17) + `EvaluationAuditControllerTest`'s
  409 `audit_disabled` case (P4.3);
  (14) run metadata + re-audit creates new run — `AuditEvaluationJobSkipRuleTest` (P3a.10/P3a.15);
  (15) no free text/excerpt in audit rows — structural, re-confirmed this batch by reading the actual
  migration column list (`status varchar(16)`, `support_probability decimal`, `question_probabilities
  jsonb` numeric-only, `outcome_reason varchar(48)`) — no column capable of holding free text;
  (16) `en`/`it` copy advisory, never instructive — `i18n-help-keys.spec.ts`'s extended
  advisory/non-instructive assertion (P6.17);
  (17) Pest+Vitest+Playwright green, coverage ≥85%/~95% — this batch's own F.1/F.2 runs above.
- [x] F.6 Confirm the retention purge command's configured artifact inventory
  (`snapshot`/`transcript`/`webhook_payload`/`participant_pii`) is unchanged by this capability — no
  audit-related class was added to it (data-retention spec).
  — DONE: read `api/config/retention.php` directly — the artifact inventory is exactly
  `snapshot`/`transcript`/`webhook_payload`/`participant_pii`, no `audit` class present. The cascade
  requirement (`indicator_score_audits.indicator_score_id` `cascadeOnDelete`) is confirmed by P2.11/
  P2.12's already-committed `AuditCascadeDeleteTest`, re-verified green in this batch's own F.1 run.
- [x] F.7 Confirm the OpenAPI diff committed in P5 is scoped to this change's fields only, with any
  pre-existing unrelated Scramble drift left untouched.
  — DONE: `git diff 25031c8..HEAD -- openapi.json` → 187 insertions / 1 deletion, read in full: the
  entire diff is exactly the new `/participants/{id}/evaluation/audit` path (added by P4) and the
  `EvaluationResource` schema gaining a real typed shape including `behaviors[].audit` (the
  Scramble-annotation follow-up, `42cfd1f`). No other schema entry changed.
- [x] F.8 Deploy runbook recorded, not executed (no deploy unless explicitly requested): standard
  `php artisan migrate --force`; no seeder, no backfill — "Forward migration only" per
  `design.md`'s Migration/Rollout section.
  — RECORDED, NOT EXECUTED: `design.md`'s Migration/Rollout section (re-read this batch) specifies
  standard `php artisan migrate --force` for the two new tables, no seeder, no backfill ("no
  historical audit data" — every pre-existing indicator reads `never_audited` at the read surface
  with zero rows written); emergency rollback is `SCORING_AUDIT_ENABLED=false` (no deploy needed);
  reverse-order revert is P6→P1, with P2/P3's tables left in place (isolated, append-only, no blast
  radius). No `php artisan migrate` was run against any non-test database this batch.
- [x] F.9 Re-confirm Phase 0.2/0.3's two human decisions are still resolved at merge time (not just
  at P1 start) — the sub-processor sign-off and the `TYPESAFE_API_KEY`/CI-lane decision.
  — RE-CONFIRMED, UNCHANGED: read `api/app/Providers/AppServiceProvider.php` directly this batch —
  the `AuditJudge` binding is still `FakeAuditJudge` in `environment('testing')` and
  `TypesafeJevJudge` otherwise, exactly as 0.2 resolved it (code ships, but is not deployed/activated
  against real production data pending legal sign-off). No new `@ai`/`workflow_dispatch` real-API
  group exists anywhere in this chain, matching 0.3's deferral. `.env.example` remains unreachable by
  this session's permission layer (same block documented since P1 Deviation #1) — the five
  `SCORING_AUDIT_*`/`TYPESAFE_API_KEY` documentation keys are still not added; this is the one
  concretely outstanding, low-risk follow-up from the whole change (not a merge blocker — the
  application functions correctly via `config/scoring.php`'s own `env()` defaults).
