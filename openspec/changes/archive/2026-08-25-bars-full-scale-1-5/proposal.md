# Proposal: BARS Full 1–5 Indicator Scale

## Intent

Indicator scores are today constrained to the discrete set `{1,3,5}` plus the `-1`
unassessable sentinel. The product owner ratified on **2026-08-24**, from a reference
interview/evaluation log, that the evaluator must be able to emit the **full 1–5 integer
scale**: `4` = "strong, exceeding expectations", `2` = "below expectations".

The current domain forces the LLM to round genuine intermediate evidence to the nearest
authored anchor. A candidate who clearly exceeds the anchor-3 behaviour but does not
reach anchor-5 is recorded as a flat `3` — the same value as someone who merely meets
expectations. That loss is systematic, invisible to the operator, and propagates into
`competency.score`, the reliability percentage and the ≥90% completion gate.

Success = the scoring pipeline accepts, produces, renders and transmits
`{1,2,3,4,5,-1}` end-to-end, with a **written, versioned rule** for what 4 and 2 mean,
and with no surface left asserting `{1,3,5}`.

## AD-1 — Anchor semantics: explicit relational rubric, three authored anchors (RATIFIED)

The exploration surfaced the crux: `framework_bars_indicators` authors only `anchor_5`,
`anchor_3`, `anchor_1`. Ratifying a wider scale does not, by itself, tell the LLM — or a
human auditing a score — what distinguishes a 4 from a 5.

**Decision: Option 3 (Hybrid).** The BARS catalog stays **unchanged** — no `anchor_4` /
`anchor_2` columns, no migration, no domain-expert content-authoring effort across
indicator × role × locale. Instead, the rule for the intermediate levels becomes an
**explicit, versioned rubric block injected by `PromptBuilder`**, not ad hoc LLM
discretion:

| Score | Rule |
|---|---|
| `5` | The evidence matches the **anchor-5** description. |
| `4` | The evidence **clearly exceeds** the anchor-3 description but does **not fully match** the anchor-5 description. |
| `3` | The evidence matches the **anchor-3** description. |
| `2` | The evidence is **clearly below** the anchor-3 description but is **not as weak as** the anchor-1 description. |
| `1` | The evidence matches the **anchor-1** description. |
| `-1` | The transcript contains **no assessable evidence** for this indicator. |

**Anchor-primacy tie-break (binding).** `4` and `2` are *residual* levels. When the
evidence is equally consistent with an authored anchor and an intermediate level, the
**authored anchor wins**. This keeps the three authored descriptions as the semantic
centre of gravity and limits intermediate-level drift across model upgrades.

Final rubric wording is prompt logic: `sdd-spec` MUST express it as testable Given/When/
Then, and it MUST be covered by a golden cassette. `config('scoring.prompt_version')`
MUST be bumped `1.0.0 → 2.0.0` — CLAUDE.md and `api/config/scoring.php:97-101` require a
bump on ANY prompt edit, and this is a domain change, not a wording tweak.

**This closes no doors.** Option 1 (authored `anchor_4` / `anchor_2` text) remains a
purely **additive** future upgrade: it would add columns and catalog entries and replace
the relational sentences with authored descriptors, leaving the score domain, the
validator, the mean, the reliability formula and the UI untouched.

**Accepted cost — auditability is partial, not solved.** A reviewer checking a `4` has a
written rule, not an observable reference behaviour. `temperature=0` gives per-request
reproducibility; it does not give the same *interpretability* that an authored anchor
sentence gives, nor stability of the exceeds/meets line across model versions. We accept
this deliberately, in exchange for shipping without a multi-locale authoring project.

## Answering the archived `2026-07-16-scoring-discrete-bars`

That change exists **solely** to establish `{1,3,5}`. It is not overwritten — it is
answered. Its archive stays intact as the audit trail.

| Original reason | Verdict |
|---|---|
| Only three anchors exist, so the LLM cannot legitimately emit an unanchored value | **Answered by AD-1.** The rubric + anchor-primacy tie-break supplies the missing selection rule the original change could not assume. |
| Discreteness makes scoring reproducible/traceable | **Conflated, does not survive.** Determinism comes from `temperature=0` plus versioned `model/prompt/framework` — orthogonal to domain size. This never independently justified `{1,3,5}`. |
| `competency.score` = mean of assessed indicators | **Unaffected.** `MeanCalculator` is domain-agnostic. |
| `-1` sentinel exempt and excluded from the mean | **Fully preserved.** |
| The "unified remapping rule" | **Moot.** One-time fixture regeneration; no runtime code. |
| Full auditability of every emitted level | **Accepted as a cost**, not answered. See AD-1. |

Discreteness was a *consequence of catalog shape*, never a product preference for a
coarse scale. The catalog shape still holds; what changes is that we now state the
selection rule for the gaps instead of forbidding them.

## AD-2 — Ship order is a correctness constraint, not a preference

`backoffice/app/utils/bars.ts:33` falls through to `'unassessable'` for anything outside
`{1,3,5}`, and `ScoreChip.vue:37` then renders `–`. **If the validator widens before the
UI, real 2 and 4 scores render as a grey "not assessable" chip — silently hiding data
rather than failing loudly.** Operators would read a scored indicator as unscored.

Binding ship order:

1. **Docs first** — `DESIGN.md` §8.3 + binding-doc corrections. No runtime effect.
2. **Backoffice second** — `indicatorChipState` / `ScoreChip` accept 2 and 4, plus their
   tests. Harmless while the API still cannot emit them.
3. **API last** — `IndicatorValidator`, `PromptBuilder`, `prompt_version` bump.

The API slice MUST NOT merge before the backoffice slice is merged and deployed.
Additionally, the `indicatorChipState` fallthrough MUST be hardened: an out-of-domain
value must map to an explicit unknown/invalid state, never be laundered into
`'unassessable'`. Silent masking is the failure mode that made sequencing load-bearing in
the first place, and it must not survive this change.

## AD-3 — `DESIGN.md` §8.3 is revised BEFORE any UI change

§8.3 states verbatim *"A chip rendering `2` or `4` is a bug, not a styling choice"* and
*"Colored chips map one-to-one: `1 = error`, `3 = warning`, `5 = success`"*. CLAUDE.md
makes `DESIGN.md` authoritative on UI and forbids implementing anything contradicting it
without updating it first. The moment this lands, §8.3 becomes authoritative-but-false.

Proposed semantics (five assessed states + neutral):

| Score | State | i18n key | Direction |
|---|---|---|---|
| `1` | `error` | `report.chip.low` (existing) | unchanged |
| `2` | new state | `report.chip.belowMid` (new) | error-toned, visually distinct from `1` |
| `3` | `warning` | `report.chip.mid` (existing) | unchanged |
| `4` | new state | `report.chip.aboveMid` (new) | success-toned, visually distinct from `5` |
| `5` | `success` | `report.chip.high` (existing) | unchanged |
| `-1`/null | `unassessable` | `report.chip.unassessable` | unchanged |

Non-negotiable constraints carried forward: the numeral and an icon must keep carrying
the meaning so **colour is never the sole signal** (WCAG 2.1 AA 1.4.1,
`ScoreChip.vue:16-21`), and any text/icon-sized colour must clear the §9.1 contrast
table — the plain `--color-success` / `--color-warning` tokens are already banned there.

**Explicitly deferred to `sdd-design`:** the exact colour tokens and icon shapes for the
two new states, and their measured contrast ratios. This proposal fixes the *semantics*
(five distinct assessed states, new i18n keys, distinctness requirement); the token
choice is a design decision that must be made against §9.1 and then written into §8.3.

## AD-4 — Mean-chip boundaries need explicit product re-confirmation

`competencyMeanState()` uses `<2.5 error`, `2.5–3.5 warning` (inclusive), `>3.5 success`.
These are generic `[1,5]` midpoints and remain mathematically valid. But under `{1,3,5}` a
three-indicator mean could only land on `{1.0, 1.67, 2.33, 3.0, 3.67, 4.33, 5.0}` — it
could **never** equal 2.5 or 3.5. Under the full scale it will land there routinely
(e.g. `2,3,3` → 2.67; `2,2,3` → 2.33; `2,3,4,5` → 3.5 exactly).

The two existing boundary tests in `bars.spec.ts` move from unreachable edge cases to
everyday behaviour. This is a **behavioural surface increase**, not a bug — and it must be
re-confirmed by the product owner rather than changing silently. See the question round.

## Scope

### In Scope

| # | Deliverable | Repo |
|---|---|---|
| 1 | `DESIGN.md` §8.3 rewrite: domain `{1,2,3,4,5,-1}`, five assessed chip states | wrapper |
| 2 | Binding-doc corrections mirroring/reversing 2026-07-16: `CLAUDE.md`, `openspec/ROADMAP.md` (C9 row), `docs/app_description/02-domain/02-evaluation.md`, `docs/app_description/03-ux-reference/02-evaluation-output.md`, and the 4× `AGENTS.md` | wrapper + 3 submodules |
| 3 | `scoring-model` delta: MODIFIED "Indicator Score Domain" (supersedes the `NEVER 4` scenarios), plus consequential edits to "Unassessable Indicator Sentinel", "Competency Score Arithmetic", "Reliability Formula" wording | wrapper |
| 4 | `scoring-engine` delta: MODIFIED "Indicator Score Domain Validation", "Competency Mean Recomputed Server-Side", "LLM Parse Error" | wrapper |
| 5 | `admin-backoffice` delta: MODIFIED "BARS Report Viewer Rendering Correctness" | wrapper |
| 6 | `indicatorChipState` widened to 2/4 + hardened fallthrough; `ScoreChip` new states + i18n keys (`en`, `it`); Vitest | `backoffice` |
| 7 | `IndicatorValidator::LEGAL_SCORES` → `[1,2,3,4,5,-1]`; Pest incl. new negative cases (0, 6, decimals) | `api` |
| 8 | `PromptBuilder` AD-1 rubric block; remove "Do NOT use scores 2, 4"; `prompt_version` → `2.0.0`; golden cassette exercising 2 and 4 | `api` |
| 9 | Stale docblock corrections: `IndicatorScore.php`, `AdminEvaluationSerializer.php`, `2026_07_22_000003_create_indicator_scores_table.php`, `bars.ts` header | `api` + `backoffice` |

### Out of Scope — explicit non-goals

Four further divergences from the reference log were identified. Each warrants its **own**
change and is named here only so it is not lost:

1. **Whole-conversation transcript for the evaluator** — today the evaluator sees only the
   single competency's `InterviewSession`.
2. **Excerpt elision tolerance + per-indicator failure isolation** — today one malformed
   excerpt discards the entire competency.
3. **STAR-based interviewer prompt** — `SystemPromptComposer` has no STAR model, no
   same-episode constraint, no minimum question count.
4. **Evaluator rigor calibration** — `PromptBuilder` carries no severity guidance.

Also out of scope:

- **Authored `anchor_4` / `anchor_2` text (Option 1)** — deliberately deferred; additive later.
- **`scripts/ci-guards.sh` (~L1912)** — validates catalog *anchor-key structure* (`"5"`,`"3"`,`"1"`), a different concern from the scored domain. Stays as-is.
- **Data migration** — `score` is a bare `smallInteger()` with no CHECK constraint; existing rows stay valid. `{1,3,5,-1} ⊂ {1,2,3,4,5,-1}`.
- **Re-scoring historical evaluations** — past Evaluations keep `prompt_version 1.0.0` and their original scores. No backfill.
- **Reliability formula, validity threshold T, and the ≥90% completion gate** — untouched.
- **Webhook/API contract change** — `EvaluationPayloadAssembler` passes `score` through raw; `openapi.json` pins no enum. Nothing to renegotiate.
- **`DemoDataset` / `evaluation-report-example.json` regeneration** — current values stay legal; diversifying them is documentation value, optional, not correctness.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `scoring-model`: indicator score domain widens to `{1,2,3,4,5,-1}`; the AD-1 relational rubric and anchor-primacy tie-break become binding; the "score is NEVER 4" scenarios are superseded.
- `scoring-engine`: validation accepts `{1,2,3,4,5} ∪ {-1}`; parse-error rejection criteria and prompt-version traceability updated.
- `admin-backoffice`: BARS report viewer renders five distinct assessed indicator states plus the neutral unassessable chip.

## Approach

Domain widening, not restructuring. Three of five services in `api/app/Services/Scoring/`
are already domain-agnostic (`MeanCalculator`, `AssessableFractionReliability`,
`EvaluationPayloadAssembler` — confirmed by source read). The real work is a one-line
constant, a prompt rubric block, a UI state map, and the binding-document + spec-delta
paperwork that keeps the source of truth honest.

Ordering per AD-2: docs → backoffice → api. Strict TDD per `openspec/config.yaml`
(`strict_tdd: true`): every RED task precedes its GREEN. `IndicatorValidator` is a
correctness-critical zone held to ~95% coverage.

## Size and Delivery

- `Chained PRs recommended: Yes`
- `400-line budget risk: Low`
- `Decision needed before apply: No`

Three natural slices matching AD-2's ship order (docs / backoffice / api), each small,
independently revertable and independently verifiable. The chain exists for **sequencing
safety**, not for line count.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `DESIGN.md` §8.3 | Modified | New domain + five assessed chip states; must land first |
| `CLAUDE.md` (Binding domain constraints) | Modified | `{1,3,5}` / "no 2, no 4" → `{1,2,3,4,5}` + AD-1 rubric summary |
| `openspec/ROADMAP.md` (C9 row) | Modified | "indicators {1,3,5}" → `{1,2,3,4,5}` |
| `docs/app_description/02-domain/02-evaluation.md` | Modified | "insieme discreto {1,3,5}" |
| `docs/app_description/03-ux-reference/02-evaluation-output.md` | Modified | Same wording |
| `AGENTS.md`, `api/AGENTS.md`, `frontend/AGENTS.md`, `backoffice/AGENTS.md` | Modified | 4× domain-constraint restatement |
| `api/app/Services/Scoring/IndicatorValidator.php` | Modified | `LEGAL_SCORES = [1,2,3,4,5,-1]` |
| `api/app/Services/Scoring/PromptBuilder.php` | Modified | AD-1 rubric; drop the "no 2, no 4" instruction |
| `api/config/scoring.php` | Modified | `prompt_version` → `2.0.0` |
| `api/tests/Unit/Services/IndicatorValidatorTest.php` | Modified | 2/4 accepted; new negative cases |
| `api/tests/Fixtures/cassettes/*` | Added | New golden cassette emitting 2 and 4 |
| `backoffice/app/utils/bars.ts` | Modified | 2/4 states; hardened out-of-domain fallthrough |
| `backoffice/app/components/atoms/ScoreChip.vue` | Modified | Two new states, icons, colours, labels |
| `backoffice/i18n/locales/{en,it}.json` | Modified | `report.chip.belowMid`, `report.chip.aboveMid` |
| `backoffice/tests/unit/utils/bars.spec.ts`, `.../ScoreChip.spec.ts` | Modified | 2/4 render + boundary cases |
| `api/app/Models/IndicatorScore.php`, `AdminEvaluationSerializer.php`, `2026_07_22_000003_*.php` | Modified | Stale docblocks only |
| `MeanCalculator`, `AssessableFractionReliability`, `EvaluationPayloadAssembler`, `openapi.json`, `scripts/ci-guards.sh`, DB schema | Unchanged | Confirmed domain-agnostic by source read |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| API ships before UI → real 2/4 render as grey "not assessable", silently hiding data | **High** | AD-2 binding ship order; hardened fallthrough so out-of-domain fails loudly; Vitest asserts 2/4 are never `unassessable` |
| Intermediate-level drift across model upgrades (4 vs 5 line moves) | Med | Anchor-primacy tie-break; `prompt_version` + `model_version` stamped per Evaluation; golden cassette pins current behaviour and fails on drift |
| Partial auditability of 2/4 disputed downstream by a client | Med | Stated as an accepted tradeoff, not a solved problem; Option 1 remains additive |
| Mean-chip boundaries 2.5/3.5 silently change felt behaviour | Med | AD-4 flags it for explicit re-confirmation; question round Q1 |
| `DESIGN.md` §8.3 authoritative-but-false window | Med | Docs slice ships first, before any UI change |
| Spec deltas drop the superseded `NEVER 4` scenarios instead of formally MODIFYing them | Med | Full MODIFIED Requirement blocks per openspec convention; archive of 2026-07-16 stays untouched |
| Score distribution shifts, moving competencies across the validity threshold T and the ≥90% gate | Low | Formulae unaffected; only the input distribution changes. Monitor after go-live; no code change proposed |
| Mixed-version evaluations coexist (`prompt_version` 1.0.0 vs 2.0.0) with different domains | Low | Already the designed behaviour — every Evaluation stamps its versions. Cross-version score comparison is not a product claim |

## Rollback Plan

Per-slice, feature branch (`feature/bars-full-1-5-scale` exists in wrapper, `api/` and
`backoffice/`), no deploy.

- **API slice:** `git revert`. `LEGAL_SCORES` narrows, the rubric block disappears, and
  `prompt_version` returns to `1.0.0`. **No data migration either way** — `score` has no
  CHECK constraint. Any 2/4 rows already written stay in the database and remain readable;
  after a revert-of-UI they would render neutral, which is why the UI is reverted **last**.
- **Backoffice slice:** `git revert`. Chips return to three assessed states. Safe as long
  as the API slice is already reverted.
- **Docs slice:** `git revert` restores the `{1,3,5}` wording.
- Reverse ship order on rollback: **api → backoffice → docs**.
- Wrapper submodule pointers revert to their previous pinned commits.

## Dependencies

- No blocking dependency on any open product decision. Decisions 1 (reliability/T),
  2 (GDPR), 3 (framework pinning), 4 (retry), 5, 8, 9 are all untouched.
- **Product decision 6 (non-English BARS anchors)** is *relieved*, not blocked, by AD-1:
  choosing the relational rubric avoids adding two more anchor fields per locale to an
  already-unresolved translation backlog. The AD-1 rubric text itself must still be
  authored per locale — that is prompt copy, one block, not per-indicator content.
- `sdd-design` MUST resolve the two new chip colour tokens against `DESIGN.md` §9.1
  before the backoffice slice can start.

## Success Criteria

- [ ] `IndicatorValidator` accepts `{1,2,3,4,5,-1}` and rejects 0, 6, and decimals, at ~95% coverage.
- [ ] `PromptBuilder` injects the AD-1 rubric verbatim, including the anchor-primacy tie-break; the "Do NOT use scores 2, 4" instruction is gone.
- [ ] `config('scoring.prompt_version')` is `2.0.0` and is stamped on every new Evaluation.
- [ ] A golden cassette exercises indicator scores 2 and 4 end-to-end and is green.
- [ ] `indicatorChipState(2)` and `indicatorChipState(4)` return distinct assessed states — never `'unassessable'` — and an out-of-domain value maps to an explicit invalid state.
- [ ] `ScoreChip` renders the numeral for 2 and 4 (never `–`), with distinct icon + colour and an i18n-keyed screen-reader label resolving in both `en` and `it`.
- [ ] `DESIGN.md` §8.3 contains no "a chip rendering 2 or 4 is a bug" wording, and every colour used clears the §9.1 contrast table.
- [ ] `scoring-model`, `scoring-engine` and `admin-backoffice` deltas each carry full MODIFIED Requirement blocks; no `NEVER 4` assertion survives in `openspec/specs/`.
- [ ] A repo-wide sweep finds no residual `{1,3,5}` / "no 2, no 4" claim in `CLAUDE.md`, `ROADMAP.md`, the two domain docs, or the 4× `AGENTS.md`.
- [ ] The archive `openspec/changes/archive/2026-07-16-scoring-discrete-bars/` is byte-unchanged.
- [ ] No catalog file, no migration, and no CHECK constraint changed.
- [ ] Pest + Vitest green in CI; coverage ≥ 85% overall, ~95% on the scoring zone.

## Proposal Question Round

Execution mode did not allow interactive questioning. These are product decisions —
`sdd-spec` and `sdd-design` MUST NOT silently invent answers.

1. **Mean-chip boundaries (AD-4).** With 2.5 and 3.5 now routinely reachable, is
   `2.5 → warning` and `3.5 → warning` (both inclusive, the current behaviour) still the
   intent? A competency averaging exactly 3.5 currently reads "warning", not "success".
   Assumed unchanged.
2. **Anchor-primacy tie-break.** Confirm that 4 and 2 are *residual* levels — that a
   genuine tie resolves to the authored anchor. The alternative (free choice on ties)
   produces more 4s and 2s and a visibly softer score distribution. Assumed: anchors win.
3. **Historical comparability.** Evaluations scored under `prompt_version 1.0.0` used a
   coarser domain. Is cross-version score comparison something the product claims to
   support? Assumed **no** — no backfill, no re-scoring, no comparability claim.
4. **Distribution shift vs the ≥90% gate.** Widening the domain changes the score
   distribution but not the reliability formula. Should the validity threshold T (0.5) or
   the gate be revisited under the new distribution? Assumed **no** — monitor post-go-live.
5. **Chip visual weight.** Should 2 and 4 read as *softer* variants of error/success
   (proposed: yes, distinct but tonally related), or as five fully independent colours?
   The latter risks the §9.1 contrast budget and a busier report table.
