# Proposal: Scoring Engine (C9)

## Intent

The interview produces **nothing usable** until scoring runs. C7a captures a transcript (one `InterviewSession` per competency); C9 turns that transcript into the **BARS competency evaluation** the whole product exists to deliver — the shape in `docs/app_description/03-ux-reference/esempio-report-valutazione.json`. Today `FinalizeInterview` (`api/app/Jobs/FinalizeInterview.php:112`) has only a `TODO(C9)` hook; there is no `Evaluation`, no prompt/anchor injection, no LLM scoring, no reliability/gate, no `ai_requests`. C9 builds the async engine end-to-end (Horizon, p95 < 10 min), deterministic (`temperature=0`) and versioned.

Success = a `pending`/`completed` `Evaluation` (per-competency means from **assessed** indicators, reliability, ≥90% gate) is persisted and emitted for C10, driving `in_valutazione → completato`.

## Scope

### In Scope (first-pass scoring)
- `ScoreEvaluationJob` (Horizon) off the `FinalizeInterview` hook; `Evaluation`/`CompetencyResult`/`IndicatorScore` models + migrations (tenant-scoped, `organization_id`-first per D22).
- Prompt assembly with **anchor injection** read via the pinned `framework_version_id` (never the live C3 draft); real non-test `LLMProvider` binding (D25-pinned SDK — STOP if unpinnable).
- Parse + validate: scores strictly `{1,3,5}∪{-1}`; excerpts **verbatim substrings** (validate, never invent); **recompute means server-side** (mean of assessed only).
- **Reliability = R-A** (`assessed/total`, exclude -1); **valid competency = reliability ≥ T (default T=50%)**; ≥90% gate → `completed` else `pending` — behind an **injectable `ReliabilityStrategy` + `ValidityPredicate`** (T is config; client ratifies later without code change).
- **Non-EN (L-2)**: score in project language; **hard-fail per-competency** on a missing anchor translation (C3 `hasTranslation`); **never** silent EN fallback.
- `ai_requests` append-only log; record `framework_version`/`model_version`/`prompt_version` on `Evaluation`.
- **Retry (RT-B), as a fast-follow work unit**: re-interview INVALID competencies only; single-use token + explicit re-issue; C9 owns the merge + `after-failed-retry → completed`.

### Out of Scope (non-goals)
- Webhook **delivery** (C10); dashboards / report viewer (C11); adaptive selection / answer-attribution (C8); GDPR media purge (C13).
- **Authoring** IT/non-EN anchor translations + missing catalog (`bars/SRX.json`, MTG/LAT) — client/C3 deliverables, tracked vs C3 `framework_gaps`. C9 flags unscorable (`role_no_bars`), never fabricates.

## Capabilities

### New Capabilities
- `scoring-engine`: async BARS evaluation pipeline (schema → prompt/anchor-injection → LLM → validate → means → reliability/gate → lifecycle → `ai_requests`), injectable reliability/validity strategies, L-2 language hard-fail, RT-B retry (fast-follow).

### Modified Capabilities
- `scoring-model`: closes the deferred **"Reliability Formula Out of Scope"** requirement — C9 defines reliability = assessable-fraction (R-A) + valid-competency predicate (V-A, T=50%) feeding the ≥90% gate.

## Approach

Deterministic core (prompt assembly via the existing `LLMProvider` seam, parse/validate, competency means, `Evaluation` persistence, `ai_requests`, `in_valutazione → completato`) with the reliability/gate wired **last** behind injectable strategies. **Mock-first (D36)**: `FakeLLMProvider` + a golden cassette from the sample report proving COL 3.67 from {5,3,3} and SLF 4.0 from {5,3,-1} @ reliability 67%. Ship via **chain PRs**: (1) `Evaluation` schema + persistence, (2) prompt/parse/validate + `ai_requests`, (3) reliability/gate strategy + lifecycle, (4) retry.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `api/app/Jobs/FinalizeInterview.php` | Modified | Fill the `TODO(C9)` hook → dispatch `ScoreEvaluationJob` |
| `api/app/Jobs/ScoreEvaluationJob.php` | New | Horizon async scoring; p95 < 10 min |
| `api/app/Models/{Evaluation,CompetencyResult,IndicatorScore}.php` + migrations | New | Tenant-scoped, `organization_id`-first (D22) |
| `api/app/Services/Scoring/*` (prompt, parser, validator, ReliabilityStrategy, ValidityPredicate) | New | Deterministic core + injectable gate |
| `api/app/Providers/AppServiceProvider.php` + `composer.json` | Modified | Real LLM binding (D25-pinned SDK); strategy bindings |
| `api/database/migrations/` (`ai_requests`) | New | Append-only observability log |
| `api/tests/` (+ `Fixtures/cassettes/`) | New | ~95% on validation, mean, 90% gate, tenant scoping; determinism + substring tests |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Reliability/validity/gate misdefined | Med | R-A + V-A(T=50%) reproduce the sample byte-for-byte; injectable, config-ratifiable; gate wired last |
| Silent wrong-language scoring | Med | L-2 hard-fail per competency via C3 `hasTranslation`; IT go-live gated on expert anchors; never EN fallback |
| Hallucinated/non-verbatim excerpts | High | Strict substring validation vs session transcript; reject non-matching |
| Illegal indicator scores (2/4/decimals) | High | Hard-validate `{1,3,5}∪{-1}`; recompute means server-side; ~95% cov |
| Missing catalog data (SRX, MTG/LAT) | High | Skip-and-flag `role_no_bars`, don't crash; blocked until client authors |
| LLM SDK unpinnable (D25) | Low | STOP + report per Dependency Resolution Policy; never downgrade/substitute |
| p95 < 10 min at scale / provider cost | Med | Horizon sizing, mock LLM in load tests (D35), cost via `ai_requests`, careful per-competency parallelisation |

## Rollback Plan

Feature branch on the `api` submodule. Migrations reversible (`down()` drops `evaluations`/`competency_results`/`indicator_scores`/`ai_requests`). No prod data/deploy. Rollback = `git revert` + `migrate:rollback`; the `FinalizeInterview` hook reverts to `TODO(C9)`; remove the LLM SDK dependency.

## Dependencies

- **C3 (`framework-catalog`)** — anchors + `hasTranslation`; read via pinned `framework_version_id`.
- **C7a (`interview-session`)** — transcript + one-session-per-competency; `FinalizeInterview` hook.
- **Gates**: IT prod scoring go-live gated on **client** anchor translations (data, not code). Retry spans C6/C7/C9 (product ratification). Real LLM binding respects **D25** (STOP on conflict).
- **Downstream**: C10 consumes the emitted `Evaluation` (`completed`/`pending`, same payload shape).

## Success Criteria

- [ ] `ScoreEvaluationJob` scores each `InterviewSession` off the `FinalizeInterview` hook (Horizon, p95 < 10 min).
- [ ] Scores validated `{1,3,5}∪{-1}`; excerpts verbatim substrings; means recomputed server-side (assessed only).
- [ ] Anchors injected via pinned `framework_version_id`; L-2 hard-fail on missing translation (no EN fallback).
- [ ] Reliability (R-A) + valid predicate (V-A, T=50%) + ≥90% gate behind injectable strategies; `completed`/`pending` resolved; both → `completato`.
- [ ] `Evaluation` records `framework_version`/`model_version`/`prompt_version`; `ai_requests` append-only.
- [ ] Golden cassette proves COL 3.67 from {5,3,3}, SLF 4.0 from {5,3,-1} reliability 67%; determinism + substring tests green.
- [ ] Correctness-critical zones (validation, mean, 90% gate, tenant scoping) ~95% coverage.
- [ ] Retry (RT-B) fast-follow: re-interview invalid-only, single-use token, merge + `after-failed-retry → completed`.
