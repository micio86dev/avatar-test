# Exploration — BARS Full 1–5 Indicator Scale

Widen the BARS indicator score domain from the discrete set `{1,3,5,-1}` to the full
1–5 integer scale plus the `-1` unassessable sentinel: `{1,2,3,4,5,-1}`.

**Decision source:** ratified by the product owner on 2026-08-24, based on a reference
interview/evaluation log that scores indicators 1–5 (`4` = "strong, exceeding
expectations", `2` = "below expectations"). The tension recorded below — that levels 4
and 2 have no behavioral anchor — was raised before ratification and the owner
reaffirmed the decision.

**Phase:** explore · **Status:** ready for proposal, with one precondition (see
[The Anchor Problem](#the-anchor-problem)).

---

## Current State

### Why `{1,3,5}` was chosen

Source: `openspec/changes/archive/2026-07-16-scoring-discrete-bars/`.

That change was **doc-correction only**, made while the scoring engine was still
greenfield — no `api/` code existed yet. Its trigger was an internal contradiction:
binding text said "1–5 scale with interpolation allowed" while the BARS catalog only
ever defined **three** anchors per indicator, `{anchor_5, anchor_3, anchor_1}`.

Its core argument was purely structural:

> If the LLM has only three anchor descriptions to match against, it cannot legitimately
> emit a value with no anchor behind it.

**Discreteness was a consequence of the catalog shape, not an independently-desired
product property.** This matters: the decision now being reversed was never a product
preference for a coarse scale — it was an inference from a data constraint that still
holds.

The design doc's "unified remapping rule" (mean-preserving → nearest-neighbor, with
sentiment tie-breaks) was a one-time, hand-derived exercise to regenerate
`evaluation-report-example.json`'s illustrative numbers. It is not runtime logic and
has no code embodiment to retire.

Since that change archived, **C9 (scoring-engine) was actually built** on top of the
`{1,3,5,-1}` invariant.

### Which original reasons survive the ratification

| Original reason | Status under the 1–5 ratification |
|---|---|
| No anchor text exists for 2/4, so the LLM cannot select them legitimately | **Still the live blocker.** Genuinely unresolved. Ratifying the wider scale does not, by itself, answer this. |
| Discreteness makes scoring reproducible/traceable | **Does not hold as stated.** Determinism comes from `temperature=0` plus versioned model/prompt/framework — orthogonal to domain size. The original prose conflated the two; this reason never independently justified `{1,3,5}`. |
| `competency.score` = mean of assessed indicators | **Unaffected.** `MeanCalculator` and `AssessableFractionReliability` both filter on `$s !== -1` and do domain-agnostic arithmetic. |
| `-1` sentinel exempt and excluded from the mean | **Fully preserved.** Orthogonal to the domain question. |
| The archived "unified remapping rule" | **Moot.** One-time fixture-regeneration algorithm; no runtime code, nothing to migrate. |

---

## The Anchor Problem

**This is the crux, and it gates the proposal.**

`framework_bars_indicators` (migration `2026_07_17_111652_create_bars_indicators_table.php`)
and `api/app/Models/BarsIndicator.php` define exactly four translatable fields: `text`,
`anchor_5`, `anchor_3`, `anchor_1`. There is **no `anchor_4` / `anchor_2` column**, and
the domain catalog JSON (`docs/app_description/02-domain/framework/bars/*.json`) authors
only three scale entries per indicator. `PromptBuilder` injects exactly those three
anchor lines into the LLM rubric.

Ratifying "1–5 full scale" as a product decision does not tell the LLM — or a human
reviewer auditing a score — what behavior distinguishes a 4 from a 5, or a 2 from a 3.

### Options (no decision made here)

**Option 1 — Author `anchor_4` / `anchor_2` text.**
Adds two translatable columns; requires domain-expert-authored descriptors for every
indicator × role × locale (it/en mandatory, es/fr/de/pt desirable). Catalog and
migration change; `PromptBuilder` rubric rewrite to inject five anchor lines.

- *Pros:* LLM has textual grounding for every level; auditability fully preserved;
  symmetric with the existing three-anchor design.
- *Cons:* Large content-authoring effort before any code lands — comparable to open
  product decision #6 (non-English anchor translations). Touches the global,
  non-tenant catalog; needs expert sign-off per role/competency/indicator.
- *Effort:* **High.**

**Option 2 — Relational scoring on three anchors.**
Instruct the LLM: "if the answer exceeds anchor 3 but does not fully meet anchor 5,
score 4" (and symmetrically for 2). No new anchor text.

- *Pros:* No catalog or migration change; `PromptBuilder` and `IndicatorValidator` are
  the only real code touch points; ships quickly.
- *Cons:* **Reduces auditability.** A human reviewing a "4" has no anchor sentence to
  check it against, and different model versions may draw the exceeds/meets line
  differently. `temperature=0` still gives per-request reproducibility, but reproducible
  is not the same as *interpretable* or *stable across model upgrades* — the archived
  change's determinism argument was about reproducibility, not explainability.
- *Effort:* **Low–Medium.**

**Option 3 — Hybrid: explicit relational rubric, still three anchors.**
Keep three authored anchors but make the relational rule explicit, structured and
versioned in the prompt (e.g. "4 = clearly exceeds the anchor-3 description, does not
yet fully match the anchor-5 description") rather than leaving it to ad hoc LLM
discretion.

- *Pros:* No catalog change; recovers some explainability via a documented, versioned
  rule; smaller footprint than Option 1.
- *Cons:* Still less auditable than authored anchors; the rule itself becomes prompt
  logic that must be versioned and tested like a spec.
- *Effort:* **Medium.**

---

## Affected Areas

### Must change

**Binding / authoritative documents**

- `CLAUDE.md` (Binding domain constraints) — states `{1,3,5}` … "no 2, no 4".
- `DESIGN.md` §8.3 — states verbatim *"A chip rendering `2` or `4` is a bug, not a
  styling choice"* and *"Colored chips map one-to-one: `1 = error`, `3 = warning`,
  `5 = success`"*. Authoritative on UX; CLAUDE.md requires updating it **before** any
  contradicting UI ships.
- `openspec/specs/scoring-model/spec.md` — live main spec with Given/When/Then
  scenarios explicitly asserting *"score is NEVER 4"*. Must be superseded via a
  **MODIFIED Requirement delta**, not edited in place. Unlike the 2026-07-16 change,
  this is a merged main spec.
- `openspec/specs/scoring-engine/spec.md` — likely carries its own domain assertions;
  `sdd-spec` must check.
- `openspec/ROADMAP.md` (C9 row) — "indicators {1,3,5}".
- `docs/app_description/02-domain/02-evaluation.md` — "insieme discreto {1,3,5}".
- `docs/app_description/03-ux-reference/02-evaluation-output.md` — same wording.

**Code**

- `api/app/Services/Scoring/IndicatorValidator.php` — `LEGAL_SCORES = [1,3,5,-1]`.
  Correctness-critical zone (~95% coverage target).
- `api/app/Services/Scoring/PromptBuilder.php` — injects three anchors; system prompt
  says "Do NOT use scores 2, 4, or any other value." Gated on the anchor-problem decision.
- `backoffice/app/utils/bars.ts` — `indicatorChipState()` maps only 1/3/5 and falls
  through to `'unassessable'` for everything else. **Highest-risk item.**
- `backoffice/app/components/atoms/ScoreChip.vue` — `labelKey` handles only
  error/warning/success/default; needs distinct treatment for 2 and 4 (new i18n keys,
  likely new colors — a design decision, see `DESIGN.md` §8.3).
- Docblocks/comments only: `api/app/Models/IndicatorScore.php`,
  `api/app/Services/Admin/AdminEvaluationSerializer.php`,
  `api/database/migrations/2026_07_22_000003_create_indicator_scores_table.php`.

### May change

- `docs/app_description/03-ux-reference/evaluation-report-example.json` — current
  values stay legal (`{1,3,5,-1}` ⊂ `{1,2,3,4,5,-1}`). Adding a 2/4 example has
  documentation and QA value, not correctness value.
- `api/tests/Fixtures/cassettes/col_slf_golden.php` and
  `bars-eval--haiku-4-5--prompt-v1.json` — existing values remain valid. A new cassette
  exercising 2/4 would strengthen coverage but is not required for correctness.
- `api/app/Support/Demo/DemoDataset.php` — hand-authored score vectors stay legal;
  optional to diversify.

### Unaffected — confirmed by source read, not assumed

- `api/app/Services/Scoring/MeanCalculator.php` — `$s !== -1` filter, arithmetic mean,
  no domain check.
- `api/app/Services/Scoring/AssessableFractionReliability.php` — same filter, count ratio.
- `api/app/Services/Webhooks/EvaluationPayloadAssembler.php` — passes
  `$indicator->score` through raw, no validation or enum.
- `api/app/Services/Admin/AdminEvaluationSerializer.php` logic — the `=== -1 ? null`
  mapping is domain-agnostic (only its docblock is stale).
- `api/database/migrations/2026_07_22_000003_create_indicator_scores_table.php` —
  `score` is a bare `smallInteger()` with **no CHECK constraint**. No data migration;
  existing rows stay valid.
- `scripts/ci-guards.sh` (~line 1912) — checks that each BARS catalog indicator's
  `scale` object has exactly the keys `"5"`, `"3"`, `"1"`. This is **anchor structure**,
  a different concern from the scored-indicator domain. Stays as-is — unless Option 1 is
  chosen, in which case this guard needs a separate, deliberate review.
- `api/openapi.json` — grepped for any enum or schema pinning `behaviors[].score`; none
  found. No external API-contract break, consistent with CLAUDE.md's greenfield /
  no-legacy-back-compat stance.

---

## Chip Threshold Analysis

`competencyMeanState()` thresholds (`<2.5 error`, `2.5–3.5 warning`, `>3.5 success`) are
**not derived from the `{1,3,5}` distribution** — they are generic midpoints of a `[1,5]`
scale, symmetric around the centre value 3, and remain mathematically valid for any
real-valued mean. No structural change required.

Worth flagging as a **behavioural surface increase**, however. Under the old domain a
three-indicator competency mean could only land on
`{1.0, 1.67, 2.33, 3.0, 3.67, 4.33, 5.0}` — it could never equal the boundary values 2.5
or 3.5 exactly. Under the full 1–5 domain, means will land at or very near those
boundaries routinely. The two existing boundary-inclusive test cases in `bars.spec.ts`
("warning at exactly 2.5" / "warning at exactly 3.5") move from an edge case that could
never occur to one that will occur in practice. Not a bug — but the proposal should
explicitly re-confirm product intent at those two boundaries now that they are reachable.

**The real UI gap is at indicator level, not mean level:** `indicatorChipState()` has no
defined state for 2 or 4 at all.

---

## Blast Radius on Tests

| File | Classification | Why |
|---|---|---|
| `api/tests/Unit/Services/IndicatorValidatorTest.php` | **must-change** | Asserts 2 and 4 are rejected; must flip to accepted. Add companion tests for what is now illegal (0, 6, decimals). |
| `backoffice/tests/unit/utils/bars.spec.ts` | **must-change** | No cases for 2/4; both `indicatorChipState` and `competencyMeanState` need new assertions. |
| `backoffice/tests/unit/components/atoms/ScoreChip.spec.ts` | **must-change** | No 2/4 render cases; needs new labels/colors once `DESIGN.md` §8.3 is updated. |
| `openspec/specs/scoring-model/spec.md` (via delta) | **must-change** | Binding scenarios assert "score is NEVER 4"; must be superseded via a MODIFIED Requirement. |
| `api/tests/Unit/Services/MeanCalculatorTest.php`, `AssessableFractionReliabilityTest.php` | unaffected | Operate on generic `list<int>`; no domain assumption. A 2/4 case is nice-to-have. |
| `api/tests/Unit/Services/Admin/AdminEvaluationSerializerTest.php` | unaffected | Tests the `-1 → null` mapping and ordering, not the domain. |
| `api/tests/Fixtures/cassettes/*` | unaffected | Values are a subset of the new domain. |
| `api/app/Support/Demo/DemoDataset.php` and demo tests | may-change | Vectors stay legal; optional to diversify. |
| `scripts/ci-guards.sh` (~line 1912) | unaffected — confirmed | Validates BARS catalog anchor-key structure, not scored values. |

---

## Webhook / API Contract

Confirmed by direct source read of `EvaluationPayloadAssembler::renderText()`:
`'score' => $indicator->score` is passed through as a raw integer with no enum or
validation at serialization. `api/openapi.json` carries no schema tying
`behaviors[].score` to a fixed set. There is no committed external contract pinning
`{1,3,5}` for webhook consumers to break. **Widening the domain is safe from an
API-contract perspective.**

---

## Risks

1. **Silent data-integrity masking (highest).** `indicatorChipState()`'s fallthrough
   renders any out-of-`{1,3,5}` value as a neutral "not assessable" chip. If the domain
   widens in the validator before the UI is updated, real 2/4 scores become **invisible
   to operators rather than erroring loudly**. Sequencing matters: UI must ship first,
   or backend and UI must ship together.
2. **The anchor problem is unresolved and blocks design.** `PromptBuilder` and
   `IndicatorValidator` cannot be finalised until Option 1/2/3 is chosen.
3. **Binding spec supersession, not overwrite.** `openspec/specs/scoring-model/spec.md`
   holds live scenarios asserting "score is NEVER 4"; they must be formally MODIFIED per
   openspec convention.
4. **`DESIGN.md` §8.3 becomes authoritative-but-false** the moment this lands. CLAUDE.md
   requires it be updated before any contradicting UI ships.
5. **Boundary threshold exposure.** The 2.5/3.5 mean-chip boundaries move from
   theoretically unreachable to routinely reached; needs explicit product
   re-confirmation, not a silent behaviour change.

Reliability formula and the 90% completion gate are unaffected — confirmed, no
additional open-decision entanglement found.

---

## Out of Scope

Four further divergences from the reference log were identified and are deliberately
**not** part of this change. Each warrants its own:

1. Whole-conversation transcript for the evaluator (today the evaluator sees only the
   single competency's `InterviewSession`).
2. Excerpt elision tolerance and per-indicator failure isolation (today one malformed
   excerpt discards the entire competency).
3. STAR-based interviewer prompt (today `SystemPromptComposer` has no STAR model, no
   same-episode constraint, no minimum question count).
4. Evaluator rigor calibration (today `PromptBuilder` carries no severity guidance).

---

## Ready for Proposal

**Yes — with one precondition.** The proposal MUST resolve the anchor-problem fork
(Option 1 / 2 / 3) as its first architectural decision, since it gates both
`PromptBuilder` and `IndicatorValidator` design.

Everything else is well-scoped and ready to plan once that fork is resolved:

- (a) `IndicatorValidator` / `PromptBuilder` domain widening
- (b) `DESIGN.md` §8.3 UI redesign for 2/4 chips — a design decision, not just code
- (c) binding-doc corrections to `CLAUDE.md` / ROADMAP / domain docs, mirroring but
  reversing the 2026-07-16 change
- (d) a `scoring-model` spec delta that properly supersedes the "score is NEVER 4"
  scenarios rather than silently dropping them

**Next recommended:** `sdd-propose`
