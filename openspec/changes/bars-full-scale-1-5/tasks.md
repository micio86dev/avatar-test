# Tasks: BARS Full 1–5 Indicator Scale

> Strict TDD active. Every code phase is RED (failing test) → GREEN (make it pass) → REFACTOR.
> Ship order is binding (AD-2/D10): **1 (wrapper, docs+specs) → 2a (api, `meta` only) → 2 (backoffice) → 3 (api, domain)**.
> Rollback reverses it: 3 → 2 → 2a → 1.

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | PR1: 90–140 / PR2a: 40–70 / PR2: 140–200 / PR3: 160–220 |
| 400-line budget risk | Low |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → PR 2a → PR 2 → PR 3 (feature-branch-chain) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Low

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Docs + 3 spec deltas merged into main specs | PR 1 | Base = `feature/bars-full-1-5-scale` (wrapper). Zero runtime effect; unblocks all others. |
| 2a | `AdminEvaluationSerializer.meta()` + `EvaluationResource` sibling key | PR 2a | Base = `api/feature/bars-full-1-5-scale`. Additive, domain-independent — safe alone. |
| 2 | `bars.ts` D6 + `ScoreChip.vue` D1 + i18n + provenance render + `theme.spec.ts` | PR 2 | Base = `backoffice/feature/bars-full-1-5-scale`. Depends on PR 1; harmless while API still emits `{1,3,5}`. |
| 3 | `IndicatorValidator` + `PromptBuilder` + `prompt_version`/`.env.example` parity + cassettes | PR 3 | Base = `api` branch from PR 2a. **Hard gate: MUST NOT merge/deploy before PR 2 is merged and deployed.** |

---

## Phase 0: Branch Hygiene (blocking, do first)

- [x] 0.1 `backoffice/` is checked out on unrelated branch `fix/nginx-spa-fallback-manifest`. Before touching any backoffice file, `git checkout feature/bars-full-1-5-scale` in `backoffice/` and confirm `git status` is clean relative to that branch. Do NOT merge or touch the nginx fix. — VERIFIED: all three repos (wrapper, api, backoffice) were already on `feature/bars-full-1-5-scale` with clean working trees when this apply batch started.

## PR 1 — Docs + Spec Deltas (wrapper, no runtime effect)

- [x] 1.1 Rewrite `DESIGN.md:654-657`: delete the `{1,3,5}`/"never 2, never 4"/"picks the single closest one"/"a chip rendering 2 or 4 is a bug" text; replace with the `{1,2,3,4,5,-1}` domain statement, the one-line "4/2 are residual levels" pointer to `scoring-model`, the D1 seven-state table (incl. `invalid`), and the out-of-domain-must-render-loud line (D2).
- [x] 1.2 Update `DESIGN.md:643-646` ASCII mock so `STG` shows `[4] [3] [1]` (mean `2.67`) or equivalent, so a skimming reader sees a non-`{1,3,5}` example.
- [x] 1.3 Add one row to `DESIGN.md` §9.1 contrast table: `--destructive` (`#b91c1c`) on `--color-error-light` (`#fee2e2`) ≈5.30:1, AA pass (D2).
- [x] 1.4 Update `CLAUDE.md` "Binding domain constraints" BARS scoring bullet: `{1,3,5}` → `{1,2,3,4,5,-1}`, add one-line AD-1 rubric summary (residual levels 4/2, anchor-primacy tie-break).
- [x] 1.5 Update `openspec/ROADMAP.md` C9 row: "indicators {1,3,5}" → "indicators {1,2,3,4,5}".
- [x] 1.6 Update `docs/app_description/02-domain/02-valutazione.md`: replace "insieme discreto {1,3,5}" wording with the widened domain.
- [x] 1.7 Update `docs/app_description/03-ux-reference/02-output-valutazione.md`: same wording correction.
- [x] 1.8 Update the 4× `AGENTS.md` (wrapper + `api/` + `frontend/` + `backoffice/`) domain-constraint restatements from `{1,3,5}` to `{1,2,3,4,5,-1}`.
- [x] 1.9 Write `openspec/changes/bars-full-scale-1-5/specs/scoring-model/spec.md` MODIFIED/ADDED blocks into `openspec/specs/scoring-model/spec.md` per the already-approved delta (this happens formally at `sdd-archive`, but confirm the delta file itself needs no further edits here). — Confirmed: delta file is final, no further edits needed; formal merge deferred to sdd-archive.
- [x] 1.10 Confirm `openspec/specs/scoring-engine/spec.md`, `admin-backoffice/spec.md`, `admin-read-api/spec.md` deltas are final (already approved) — no action beyond archive-time merge. — Confirmed final.
- [x] 1.11 **Manual doc-pass**: `openspec/specs/scoring-engine/spec.md` non-requirement prose ("Coverage Note", "Purpose" sections, outside any `### Requirement:` heading) still says `{1,3,5}`. The delta MODIFIED mechanism only replaces matched Requirement blocks — it will NOT touch this prose. Manually edit these free-text sections in the main spec at archive time (or note here for `sdd-archive` to action) so no `{1,3,5}` claim survives outside a superseded Requirement. — DONE: fixed `## Coverage Note` in `scoring-engine/spec.md`. Also found and fixed an equivalent residual-prose case task 1.11 didn't name explicitly: `## Implementation Note (C9 — Delivered)` in `scoring-model/spec.md` (also outside any Requirement heading, also said `{1,3,5}`). Both fixed to `{1,2,3,4,5}`.
- [x] 1.12 Repo-wide sweep: grep `{1,3,5}`, "never 2", "never 4", "Do NOT use scores 2, 4" across `CLAUDE.md`, `ROADMAP.md`, the 2 domain docs, 4× `AGENTS.md`, `DESIGN.md` — confirm zero residual hits outside the archived `2026-07-16-scoring-discrete-bars/` directory (which stays byte-unchanged). — VERIFIED: `rg` sweep returned zero hits after edits.

## PR 2a — API: Scoring Provenance `meta` (additive, domain-independent)

> Base: `api` branch off PR 1's wrapper merge point. Safe to merge alone — read-only, no domain dependency.

- [ ] 2a.1 **RED** `api/tests/Feature/Admin/EvaluationMetaTest.php`: assert `GET /api/participants/{id}/evaluation` response carries a `meta.scoring` sibling of `data` with `prompt_version`, `model_version`, `framework_version` (the resolved version string, not the FK id) — per `admin-read-api` spec "Evaluation Read Surface Exposes Its Scoring Regime".
- [ ] 2a.2 **GREEN** Add `AdminEvaluationSerializer::meta(Participant $participant): array` returning the three persisted values; fix stale docblock in the same file (D7, proposal item 9).
- [ ] 2a.3 **GREEN** Wire `EvaluationResource::with()` to emit `meta.scoring` as a sibling of `data`.
- [ ] 2a.4 Run Phase 2a.1 test; confirm green. Run `./vendor/bin/pint --test`.

## PR 2 — Backoffice: Chip States + Provenance Render

> Base: `backoffice/feature/bars-full-1-5-scale` (after Phase 0.1 branch fix and PR 1 merged). Depends on PR 2a for the `meta` shape it consumes.

- [ ] 2.1 **RED** `backoffice/tests/unit/utils/bars.spec.ts`: add cases for `indicatorChipState(2)` → `'below-mid'`, `indicatorChipState(4)` → `'above-mid'`, both distinct from `'unassessable'`; `indicatorChipState(0)`, `(6)`, `(2.5)`, `(NaN)` → `'invalid'`; explicit assertion that scores 2 and 4 are NEVER `'unassessable'` (D6, must-have item 6). Add `competencyMeanState(2.5)` and `(3.5)` boundary assertions per AD-4 (assumed unchanged: both `'warning'`).
- [ ] 2.2 **GREEN** Rewrite `backoffice/app/utils/bars.ts:16-34`: widen `BarsChipState` to `'error' | 'below-mid' | 'warning' | 'above-mid' | 'success' | 'unassessable' | 'invalid'`; make `indicatorChipState` a total function per D6 — `Number.isInteger` guard before the switch, explicit `default: return 'invalid'` (never `'unassessable'`). Update header docblock (stale-doc item, proposal item 9).
- [ ] 2.3 **RED** `backoffice/tests/unit/components/atoms/ScoreChip.spec.ts`: assert score `2`/`4` render their own numeral (never `–`) with distinct icon (`ArrowDownCircleIcon`/`ArrowUpCircleIcon`) and dashed border; assert an `invalid` score renders `String(props.score)` verbatim, `ExclamationCircleIcon`, `--color-error-light` fill; assert SR label resolves via `$t('report.chip.belowMid'|'aboveMid'|'invalid')` in both `en` and `it`.
- [ ] 2.4 **GREEN** `backoffice/app/components/atoms/ScoreChip.vue`: add `below-mid`/`above-mid`/`invalid` branches to the icon `v-if` chain, `display`, `labelKey`, and `colorClass` computeds per D1/D6 (dashed border for residual states, solid for anchors and invalid).
- [ ] 2.5 Add i18n keys `report.chip.belowMid`, `report.chip.aboveMid`, `report.chip.invalid` (interpolated `{score}`) to `backoffice/i18n/locales/en.json` and `it.json` per D3.
- [ ] 2.6 **RED** `backoffice/tests/unit/theme.spec.ts`: add a numeric WCAG relative-luminance assertion for `--destructive` (`#b91c1c`) on `--color-error-light` (`#fee2e2`) ≈5.30:1 AA pass — must assert the ratio, never accept the design doc's number on faith (must-have item 5).
- [ ] 2.7 **GREEN** Confirm the assertion in 2.6 passes against the actual computed tokens; if it disagrees with `DESIGN.md` §9.1, fix the doc row (D2 rule: test wins).
- [ ] 2.8 Add `EvaluationScoringMeta` type and update `backoffice/app/composables/useEvaluationReport.ts` `fetchEvaluation()` return type from `EvaluationReportData` to `{ data: EvaluationReportData; meta: EvaluationScoringMeta }` (D7).
- [ ] 2.9 Update `backoffice/app/pages/participants/[id].vue` to destructure the new `{ data, meta }` return shape.
- [ ] 2.10 Add the provenance footnote row to `backoffice/app/components/organisms/EvaluationReport.vue`: muted `text-xs` line between `<Table>` and excerpts block, `$t('report.provenance.label')` (localized) + literal `prompt_version`/`model_version`/`framework_version` values (never localized — machine-facing per CLAUDE.md).
- [ ] 2.11 **RED+GREEN** `backoffice/tests/unit/components/organisms/EvaluationReport.spec.ts`: assert the provenance line renders the three literal values unchanged across `en`/`it` locales (per `admin-backoffice` spec "The version string is identical across locales").
- [ ] 2.12 Run full Vitest suite; confirm no regressions; confirm ~95% coverage on `bars.ts`.

## PR 3 — API: Domain Widening (hard-gated on PR 2 merged + deployed)

> Base: `api` branch continuing from PR 2a. **MUST NOT merge or deploy before PR 2 is merged and deployed** (AD-2/D10) — merging first makes real 2/4 render neutral, the exact silent-masking failure this change exists to prevent.

- [ ] 3.1 **RED** `api/tests/Unit/Services/IndicatorValidatorTest.php`: flip existing "score 2 rejected" / "score 4 rejected" assertions to "accepted"; add new negative cases for `0`, `6`, `-2`, decimal (e.g. `3.5`).
- [ ] 3.2 **GREEN** `api/app/Services/Scoring/IndicatorValidator.php:27` — `LEGAL_SCORES` → `[1, 2, 3, 4, 5, -1]`. Update class docblock (stale-doc item, proposal item 9).
- [ ] 3.3 **RED** `api/tests/Unit/Services/PromptBuilderTest.php`: assert the composed prompt contains the D4 `SCORING_PROCEDURE` ordered-steps text verbatim; assert the string "Do NOT use scores 2, 4" is absent; assert the output-format comment reads `<1, 2, 3, 4, 5, or -1>`.
- [ ] 3.4 **GREEN** `api/app/Services/Scoring/PromptBuilder.php`: add `private const SCORING_PROCEDURE` (D4 ordered procedure with early-stop and residual-tie-break, exact text from design.md D4); inject it between the RULES block and the indicator rubric; delete the `PromptBuilder.php:101` "Do NOT use scores 2, 4, or any other value. Do NOT interpolate between anchors." line; update `PromptBuilder.php:100` to "assign a score from EXACTLY one of: 1, 2, 3, 4, 5, OR -1"; update `PromptBuilder.php:114` output-format comment to `<1, 2, 3, 4, 5, or -1>`.
- [ ] 3.5 **GREEN** Tighten the explanation contract in the prompt output schema (D5): for scores 4 and 2, require the explanation to name both bounding anchors (prompt-copy only, not a validated parser field).
- [ ] 3.6 **RED** `api/tests/Unit/Services/PromptBuilderTest.php` (same file, D8 parity case): assert `config('scoring.prompt_version')` equals the value in `api/.env.example:75` `SCORING_PROMPT_VERSION` (parity test — fails today because config default is `1.0.0` and env example is also `1.0.0`, but will catch future drift once both bump).
- [ ] 3.7 **GREEN** Bump `api/config/scoring.php:101` default `'1.0.0' → '2.0.0'` **and** `api/.env.example:75` `SCORING_PROMPT_VERSION=1.0.0 → SCORING_PROMPT_VERSION=2.0.0` together in the same commit (D8 — missing this stamps `1.0.0` on 2.0.0-rubric Evaluations from any environment provisioned from `.env.example`, corrupting the D7 provenance line).
- [ ] 3.8 Create `api/tests/Fixtures/cassettes/intermediate_golden.php`: competency A `{4,2,3}` → mean `3.00`, reliability `1.0`; competency B `{5,4,-1}` → mean `4.50`, reliability `2/3`; competency C `{2,3,4,5}` → mean exactly `3.50` (D9 boundary case).
- [ ] 3.9 Create `api/tests/Feature/Jobs/IntermediateScaleCassetteTest.php` driving the fixture from 3.8 end-to-end (parse → validate → persist → mean → serialize). Confirm `api/tests/Fixtures/cassettes/col_slf_golden.php` and `GoldenCassetteTest.php` stay byte-unchanged and still green (anchors-only regression pin).
- [ ] 3.10 Extend `DeterminismTest`'s `detCassetteForCompetencyCode` fixture to include `{5,4,2}` — run-twice invariance over residual levels.
- [ ] 3.11 **GREEN** Verify (from 2.6/2.7 in Vitest, this is a cross-repo assertion, not a new api test) `backoffice/tests/unit/utils/bars.spec.ts` explicitly asserts `indicatorChipState(2)` and `indicatorChipState(4)` are never `'unassessable'` — re-confirm this Vitest assertion exists and is green before merging PR 3 (must-have item 6, contract not implementation detail).
- [ ] 3.12 Fix stale docblocks: `api/app/Models/IndicatorScore.php`, `api/database/migrations/2026_07_22_000003_create_indicator_scores_table.php` (comments only, no schema change).
- [ ] 3.13 Run `./vendor/bin/pest`; confirm full suite green, no regressions against PR 1/2a. Confirm ~95% coverage on `IndicatorValidator` (correctness-critical zone).
- [ ] 3.14 Run `./vendor/bin/pint --test`; fix PSR-12 violations.

## Phase 4: Drift Detection (existing `@ai` group only — do NOT claim cassettes cover this)

- [ ] 4.1 Add a new rubric-adherence test to the existing `@ai` group (`ai-integration` workflow, zero PR cost, real LLM, never runs on PR/develop): given a fixed transcript with one deliberately mid-band answer, assert (a) every returned score ∈ `{1,2,3,4,5,-1}`, (b) at least one residual score (2 or 4) is emitted, (c) no score is out of domain. Band assertions only — never assert an exact value against a live model. Golden cassettes CANNOT detect model drift (they replay recorded responses; the model is not in the loop) — this `@ai` test is the only mechanism that can.

## Phase 5: Ops Follow-up (not a code task — requires human confirmation)

- [ ] 5.1 **Human action required, cannot be verified from the repo.** Any Railway (or other) deploy environment that sets `SCORING_PROMPT_VERSION` explicitly, overriding `.env.example`, must be updated to `2.0.0` at/after PR 3 deploys — otherwise D8's parity guard passes in CI while production keeps stamping `1.0.0`. Flag for the human operator before/at PR 3 deploy; do not close this item from code alone.

## Phase 6: Final Sweep (after PR 3 merges)

- [ ] 6.1 Confirm `docs/app_description/03-ux-reference/esempio-report-valutazione.json` values remain legal (subset of new domain) — no change required, optional diversification only.
- [ ] 6.2 Confirm `openspec/changes/archive/2026-07-16-scoring-discrete-bars/` is byte-unchanged.
- [ ] 6.3 Run full Pest + Vitest suites across all repos; confirm CI green; confirm overall coverage ≥85%, ~95% in the scoring zone.
- [ ] 6.4 Re-run the repo-wide `{1,3,5}` / "never 2, never 4" sweep from 1.12 after all 4 PRs land, to catch anything introduced during implementation.
