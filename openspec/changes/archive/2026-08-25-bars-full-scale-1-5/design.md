# Design: BARS Full 1–5 Indicator Scale

## Technical Approach

Domain widening, not restructuring. Four moving parts, in AD-2's binding order:

1. **`DESIGN.md` §8.3** is rewritten to describe seven chip states, spending **zero new
   colour tokens** — the two residual levels inherit the hue of the anchor they are
   subordinate to and are distinguished in the icon and border-style channels (D1/D2).
2. **`backoffice`** widens `indicatorChipState()` to a total function over
   `number | null` with an explicit `invalid` terminal state (D6), and surfaces the
   already-persisted scoring provenance under the report table (D7).
3. **`api`** replaces the "Do NOT use scores 2, 4" instruction with an **ordered scoring
   procedure** whose control flow *is* the anchor-primacy tie-break (D4), pinned by a
   prompt fingerprint test and a `prompt_version` parity guard (D8).
4. **Drift** is addressed honestly: cassettes pin our pipeline, not the model, so
   intermediate-level drift needs a real-LLM band assertion in the existing `@ai` group (D9).

`MeanCalculator`, `AssessableFractionReliability` and `EvaluationPayloadAssembler` are
untouched — confirmed domain-agnostic. No migration, no CHECK constraint, no catalog edit,
no OpenAPI break.

---

## Architecture Decisions

### D1 — Seven chip states, zero new colour tokens

**Choice.** Residual levels inherit the *adjacent anchor's* text token and are separated by
two independent non-colour channels.

| Score | State | Text token | Icon (`@heroicons/vue/24/outline`) | Border | Display |
|---|---|---|---|---|---|
| `5` | `success` | `--color-success-dark` `#166534` (7.1:1) | `CheckCircleIcon` | solid | `5` |
| `4` | `above-mid` | `--color-success-dark` (same) | `ArrowUpCircleIcon` | **dashed** | `4` |
| `3` | `warning` | `--color-warning-dark` `#92400e` (7.1:1) | `ExclamationTriangleIcon` | solid | `3` |
| `2` | `below-mid` | `--destructive` `#b91c1c` (≈6.5:1) | `ArrowDownCircleIcon` | **dashed** | `2` |
| `1` | `error` | `--destructive` (same) | `XCircleIcon` | solid | `1` |
| `-1`/`null` | `unassessable` | `--muted-foreground` | `MinusCircleIcon` | solid | `–` |
| anything else | `invalid` | `--destructive` on `--color-error-light` fill | `ExclamationCircleIcon` | solid, full-opacity | **raw value** |

**Alternatives considered.** (a) Five fully independent hues. (b) Softer/lighter tints of
error and success for 2 and 4.

**Rationale.** This *confirms* AD-3's position and strengthens it — the reason is stronger
than "busier table". The three existing tokens already span red (`#b91c1c`) →
brown-orange (`#92400e`) → green (`#166534`). There is almost no perceptual room left
between `#b91c1c` and `#92400e`: a fourth hue inserted there differs by a few degrees of
hue at 14 px chip size, is unreliable under deuteranomaly, and would have to be a *new*
§9.1 row carrying a *new* contrast liability. Option (b) is worse: "softer" means lighter,
and lighter is exactly the direction that fails the 4.5:1 floor — the failure §9.1 already
records twice (`--color-success`, `--color-warning`).

So the contrast budget is not spent at all. Both residual states reuse a token §9.1 has
**already verified**, and no existing row changes.

Two further gains fall out. The border channel (**dashed = residual, solid = on an
authored anchor**) encodes AD-1's own semantics — a 4 is not "a bit less than 5", it is a
level with no authored behaviour behind it, and the chip says so. And colour is never the
sole signal: numeral, icon and border style all carry the distinction independently
(WCAG 2.1 AA 1.4.1). The border is decorative reinforcement here, not the sole carrier, so
it is not itself gated on 3:1.

**Dark theme — verified, and the answer is "not applicable".**
`backoffice/app/assets/css/main.css:233` states dark mode is out of C11 scope and **no view
toggles `.dark`**; the block holds shadcn's unbranded defaults, deliberately, so that no
unratified dark-brand palette gets invented. The `-dark` tokens this design reuses are
tuned for light surfaces and would fail on `oklch(0.145 0 0)`. Introducing `dark:` variants
for chips now would ship a brand decision nobody made, for a theme that cannot be reached.
**Decision: no `dark:` classes.** The chips inherit whatever the eventual dark-mode change
decides for all seven states at once, which is the correct place for that work.

### D2 — Exact `DESIGN.md` §8.3 edit (lands first, no runtime effect)

`DESIGN.md:654-657` (the indicator-score bullet) and `DESIGN.md:643-646` (the ASCII mock)
are the only false surfaces. §8.3 needs, verbatim:

- **Delete** *"Indicator scores are the discrete set `{1, 3, 5}` — never 2, never 4, never a
  decimal"*, *"picks the single closest one"*, *"A chip rendering `2` or `4` is a bug, not a
  styling choice"*, and *"Colored chips map one-to-one: `1 = error`, `3 = warning`,
  `5 = success`"*.
- **Replace** with: the domain `{1,2,3,4,5}` ∪ `{-1}`, integers only, no decimals; a
  one-line statement that 4 and 2 are **residual** levels selected only when neither
  bounding anchor matches (pointing at the `scoring-model` spec, not restating the rubric —
  one source of truth); and the D1 table above, including the `invalid` row.
- **Add** an explicit line: *an out-of-domain value renders as a loud invalid chip showing
  the raw value; it MUST NOT be laundered into the neutral unassessable chip.*
- **Update** the ASCII mock so at least one row shows a `4` and one a `2` (e.g. `STG` →
  `[4] [3] [1]`, mean `2.67`) — a reader who only skims the diagram must not come away
  believing the old domain.
- **Leave unchanged**: the `-1` bullet, the mean-threshold bullet (AD-4 assumed
  unchanged — see Open Questions), the reliability bullet, the excerpts bullet.

`DESIGN.md` §9.1 gains **one** new row — the only new pairing this design introduces:

| Text color | Background | Ratio | Pass |
|---|---|---|---|
| `--destructive` (`#b91c1c`) | `--color-error-light` (`#fee2e2`) | ≈5.30:1 | ✓ AA (invalid `ScoreChip`) |

The `≈5.30:1` is a computed expectation, not evidence. Per §9.1's own rule ("verify with a
real contrast calculation, never by eye"), `backoffice/tests/unit/theme.spec.ts` MUST assert
this numerically with the existing WCAG relative-luminance helper, as it already does for
the select-highlight pairing. If the test disagrees with this document, the test wins and
§9.1 is corrected.

### D3 — i18n keys: confirm `belowMid` / `aboveMid`, add `invalid`

**Choice.** Keep the proposed names; add one.

```jsonc
"report": { "chip": {
  "low":          "Score 1 out of 5 (needs improvement)",   // unchanged
  "belowMid":     "Score 2 out of 5 (below expectations)",  // new
  "mid":          "Score 3 out of 5 (developing)",          // unchanged
  "aboveMid":     "Score 4 out of 5 (exceeds expectations)",// new
  "high":         "Score 5 out of 5 (strong evidence)",     // unchanged
  "unassessable": "Not assessable — no evidence in the transcript", // unchanged
  "invalid":      "Invalid score {score} — outside the 1–5 scale"   // new, interpolated
}}
```

**Alternatives considered.** Numeric keys (`score1`…`score5`); rubric-derived names
(`exceedsMid`, `belowAnchor3`).

**Rationale.** The existing keys are positional (`low`/`mid`/`high`), not numeric.
`belowMid`/`aboveMid` slot into that register without churning three shipped keys and their
`en`/`it` values. The *copy* carries the product owner's ratified wording ("exceeding
expectations" / "below expectations"), so the semantic load sits in the string, where
translators can work, not in the key. `invalid` interpolates `{score}` — the label is
user-facing and localized, the interpolated numeral is data and is not.

### D4 — The rubric is an ordered procedure, not a table

**Choice.** `PromptBuilder` gains a `private const SCORING_PROCEDURE` string, injected
between the RULES block and the indicator rubric:

```
SCORING PROCEDURE — apply these steps in this exact order for each indicator:
  1. If the transcript contains no assessable evidence for this indicator,
     score -1 and stop.
  2. If the evidence matches the Score 5 anchor, score 5 and stop.
  3. If the evidence matches the Score 3 anchor, score 3 and stop.
  4. If the evidence matches the Score 1 anchor, score 1 and stop.
  5. Only if steps 2, 3 and 4 were ALL rejected, the evidence falls between two
     anchors. Then, and only then:
       - score 4 if it clearly exceeds the Score 3 anchor but does not fully
         match the Score 5 anchor;
       - score 2 if it is clearly below the Score 3 anchor but is not as weak as
         the Score 1 anchor.

Scores 4 and 2 are RESIDUAL levels. They are legal ONLY at step 5. If the
evidence is equally consistent with an authored anchor (5, 3 or 1) and with an
intermediate level, the authored anchor WINS — score the anchor, never the
intermediate.
```

**Alternatives considered.** The proposal's six-row score/rule table, restated verbatim in
the prompt.

**Rationale.** A table of six equal rows presents all six values as peers and leaves the
tie-break as a sentence the model may weigh or ignore. Rendering it as an **ordered
procedure with early stop** makes the tie-break *structural*: a tie between 5 and 4 is
resolved at step 2 before step 5 is ever reached, because step 5 is gated on steps 2–4
having been rejected. The explicit RESIDUAL paragraph is then redundant reinforcement
rather than the sole mechanism — which is the whole point of the task's "must constrain,
not hint". The semantics are identical to AD-1's table; only the encoding changed.

Also in `PromptBuilder`: the `IMPORTANT RULES` line becomes *"assign a score from EXACTLY
one of: 1, 2, 3, 4, 5, OR -1"*; the *"Do NOT use scores 2, 4, or any other value. Do NOT
interpolate between anchors."* line is **deleted**; the output-format comment becomes
`<1, 2, 3, 4, 5, or -1>`.

### D5 — Residual scores must name both bounding anchors

**Choice.** The explanation contract tightens for 4 and 2 only:
`"explanation": "<brief explanation referencing the anchor; for a score of 4 or 2, name BOTH anchors the evidence falls between>"`.

**Rationale.** AD-1 books partial auditability as an accepted cost. This recovers part of it
for free. A reviewer auditing a `4` currently has a rule but no artefact; requiring the
explanation to name the two bounding anchors gives them a checkable statement in the record
at zero schema, storage or UI cost. It is a prompt-copy line, not a validated field — we do
**not** add a parser rule for it, because a rejected competency over explanation phrasing
would be a worse failure than a vague explanation.

### D6 — `indicatorChipState` becomes a total function with a loud terminal state

**Choice.** Permanent structural fix, not a transition mitigation:

```ts
export type BarsChipState =
  | 'error' | 'below-mid' | 'warning' | 'above-mid' | 'success'
  | 'unassessable' | 'invalid'

export function indicatorChipState(score: number | null): BarsChipState {
  if (score === null || score === UNASSESSABLE_SENTINEL) return 'unassessable'
  if (!Number.isInteger(score)) return 'invalid'   // 2.5, NaN, Infinity
  switch (score) {
    case 5: return 'success'
    case 4: return 'above-mid'
    case 3: return 'warning'
    case 2: return 'below-mid'
    case 1: return 'error'
    default: return 'invalid'                       // 0, 6, -2, …
  }
}
```

`ScoreChip.vue` handles `invalid` by rendering **`String(props.score)` verbatim** — never
`–` — with `ExclamationCircleIcon`, the `--color-error-light` fill from D1, a full-opacity
`--destructive` border, and `$t('report.chip.invalid', { score })`.

**Alternatives considered.** Throw / `console.error` and render nothing; keep the
`unassessable` fallthrough and rely on the ship order alone.

**Rationale.** The failure that made sequencing load-bearing was **silent masking**: an
unhandled value became a neutral chip that reads "we looked and found nothing", which is a
lie about the data. Throwing is worse — one bad indicator would blank an entire report the
operator otherwise needs. Rendering loudly with the raw value preserves the report, tells
the operator this specific chip is not trustworthy, and gives support the actual value to
report. `Number.isInteger` is a separate branch because `-1` and `null` are legitimate and
must be caught *before* it, while `2.5` must not fall into the `default` by accident of
`switch` semantics. This survives the transition permanently: any future domain change that
forgets the UI fails visibly instead of quietly.

### D7 — Scoring provenance: response-level `meta`, verbatim, no derived taxonomy

**Choice.** `AdminEvaluationSerializer` gains a `meta(Participant): array` returning the
three values already persisted on `Evaluation`; `EvaluationResource::with()` emits them as a
**sibling of `data`**, never inside it:

```json
{
  "data": { "COL": { … }, "SLF": { … } },
  "meta": { "scoring": {
    "prompt_version": "2.0.0",
    "model_version": "claude-haiku-4-5-20251001",
    "framework_version": "1.4.0"
  }}
}
```

`framework_version` is `FrameworkVersion.version` (the string), resolved through the
existing FK under the ambient tenant scope — never the raw `framework_version_id`, which
means nothing to an operator.

**Alternatives considered.** (a) A reserved key inside the competency map. (b) A derived
`score_scale: "1-5" | "1,3,5"` field. (c) A new stamped `evaluations.score_domain` column.

**Rationale.** (a) is rejected because the map is keyed by competency code and frameworks
are **custom and versioned per tenant** (CLAUDE.md) — betting that no tenant ever authors a
code colliding with our reserved key is a latent bug. `meta` as a response sibling is
Laravel's own idiom, is additive, and `response.data` consumers are untouched.

(b) is rejected as a **derived product claim**. It would need a `prompt_version → domain`
lookup maintained in two repos forever — the exact drift class this change exists to
remove — and it would imply a comparability semantics the product explicitly does not claim
(proposal Q3, assumed no). The API exposes what was stamped; it does not editorialize.

(c) is the *correct* long-term answer and is deliberately deferred: a `score_domain` column
written at scoring time is authoritative rather than inferred. It requires a migration,
which this change forbids. Named here so the option is not lost.

**Where it renders.** `EvaluationReport.vue`, as a footnote row between the `<Table>` and
the excerpts block: a `text-muted-foreground text-xs` line reading
`{{ $t('report.provenance.label') }}: prompt 2.0.0 · model claude-haiku-4-5-20251001 · framework 1.4.0`.
The **label is localized; the three values are literal in every locale** (CLAUDE.md —
machine-facing values are not localized). Unobtrusive (muted, small, below the fold of the
table) but unmissable (always present, never collapsed behind a disclosure, inside the
report card itself). It is provenance, not a headline, and it deliberately does **not**
interpret the versions — see (b).

`useEvaluationReport.fetchEvaluation()` changes return type from `EvaluationReportData` to
`{ data: EvaluationReportData; meta: EvaluationScoringMeta }`; `pages/participants/[id].vue`
and `EvaluationReport.vue` update accordingly. `GET /participants/{id}/evaluation/download`
is **not** in scope — the download payload shape is a separate contract.

### D8 — The `prompt_version` bump is a two-file change with a parity guard

**Choice.** Bump `api/config/scoring.php:101` default `1.0.0 → 2.0.0` **and**
`api/.env.example:75` `SCORING_PROMPT_VERSION=1.0.0 → 2.0.0`, plus a Pest test asserting the
two agree.

**Rationale — this was not in the proposal's file list and is a real defect.**
`prompt_version` is `env('SCORING_PROMPT_VERSION', '1.0.0')`. Bumping only the config
default leaves every environment provisioned from `.env.example` stamping `1.0.0` onto
Evaluations produced by the 2.0.0 rubric. That is silent traceability corruption — the same
failure class as D6, in the audit trail instead of the UI, and it would make D7's provenance
line actively misleading. The parity test makes the coupling structural so the next prompt
edit cannot reintroduce it. Deployment environments that pin `SCORING_PROMPT_VERSION`
explicitly must be updated at deploy time; this is called out in the slice-3 checklist.

### D9 — Cassettes pin the pipeline; only the `@ai` group can catch model drift

**Choice.** Three tiers, with an explicit statement of what each cannot do.

| Tier | Addition | Catches |
|---|---|---|
| Golden cassette (new file `tests/Fixtures/cassettes/intermediate_golden.php`) | competency A `{4,2,3}` → mean `3.00`, reliability `1.0`; competency B `{5,4,-1}` → mean `4.50`, reliability `2/3` | residual scores surviving parse → validate → persist → mean → serialize, end to end |
| Golden cassette, boundary | competency C `{2,3,4,5}` → mean **exactly `3.50`** | AD-4's newly-reachable chip boundary, asserted on both sides (`3.50` stored; `competencyMeanState(3.5) === 'warning'` in `bars.spec.ts`) |
| `DeterminismTest` | extend `detCassetteForCompetencyCode` to `{5,4,2}` | run-twice invariance over residual levels |
| `@ai` group (`ai-integration` workflow only) | new rubric-adherence test | **model drift** |

`api/tests/Fixtures/cassettes/col_slf_golden.php` and `GoldenCassetteTest.php` stay
**byte-unchanged**: they are the anchors-only regression pin and must keep passing to prove
the widening broke nothing.

**Rationale — the honest part.** A cassette replays a recorded response. It can never
detect that a *new model version* draws the exceeds/meets line differently, because the
model is not in the loop. Claiming cassettes cover intermediate-level drift would be false
assurance. The only mechanism that can is the real-LLM `@ai` group already established in
D36/D7 of the archived scoring-engine design, which runs solely in the `ai-integration`
workflow and never on PR or `develop` — so this costs zero AI spend on the delivery path.

That test asserts **bands, not values**: given a fixed transcript with one deliberately
mid-band answer, (a) every returned score ∈ `{1,2,3,4,5,-1}`, (b) at least one residual
score is emitted, (c) no score is out of domain. An exact-value assertion against a live
model is a flaky test, not a drift detector. A drift *magnitude* signal (distribution shift)
is monitoring, not testing, and belongs to the post-go-live watch already named in the
proposal risk table.

### D10 — Slice boundaries and independent merge safety

Three chained PRs on `feature/bars-full-1-5-scale`, matching AD-2 exactly. All three are
small; the chain exists for **sequencing safety**, not line count.

| # | Slice | Repos | Safe to merge alone? | Why |
|---|---|---|---|---|
| 1 | Docs + spec deltas: `DESIGN.md` §8.3 + §9.1 row, `CLAUDE.md`, `ROADMAP.md`, 2 domain docs, 4× `AGENTS.md`, the three spec deltas | wrapper | **Yes, unconditionally** | Zero runtime effect. Also the *only* slice whose absence blocks the others (CLAUDE.md forbids UI contradicting `DESIGN.md`). |
| 2 | `bars.ts` (D6), `ScoreChip.vue` (D1), i18n `en`+`it` (D3), provenance render (D7 frontend half), `theme.spec.ts` contrast row, Vitest | `backoffice` | **Yes**, after slice 1 | Harmless while the API cannot emit 2/4: the new branches are simply never reached. The provenance line renders whatever the API stamps, including `1.0.0`. Requires the D7 API half to exist first if `meta` is consumed — see note. |
| 3 | `IndicatorValidator` (D4 domain), `PromptBuilder` (D4/D5), `prompt_version` + `.env.example` + parity test (D8), cassettes (D9), `AdminEvaluationSerializer` + `EvaluationResource` (D7 API half), stale docblocks, Pest | `api` | **No — hard gate** | MUST NOT merge or deploy before slice 2 is merged **and deployed**. Merging first makes real 2/4 render neutral (pre-D6) — the exact silent-masking failure. |

**One ordering wrinkle the proposal did not have.** D7 adds an API half (serializer `meta`)
and a backoffice half (consume + render). The API half is a *read-only additive* `meta` key
with no dependence on the widened domain, so it can — and should — be split forward into
**slice 2a**, a tiny `api` PR merged *before* the backoffice slice, keeping slice 2 purely
frontend and keeping the "api last" rule intact for everything that touches the *domain*.
Alternative: `useEvaluationReport` tolerates a missing `meta` and the footnote hides — this
adds a defensive branch that lives forever to save one small PR. Rejected; split the PR.

Resulting chain: **1 (wrapper, docs+specs) → 2a (api, `meta` only) → 2 (backoffice) → 3 (api, domain)**.
Rollback reverses it: 3 → 2 → 2a → 1.

`Chained PRs recommended: Yes` · `400-line budget risk: Low` · `Decision needed before apply: No`

---

## Data Flow

```
  BarsIndicator {anchor_5,3,1}          config: prompt_version 2.0.0
            │                                    │
            ▼                                    ▼
      PromptBuilder ──── SCORING_PROCEDURE (D4) ──┤ fingerprint test (D8)
            │                                    │
            ▼  temperature=0                     │
        LLMProvider ──► score ∈ {1,2,3,4,5,-1}   │
            │                                    │
            ▼                                    │
   IndicatorValidator  LEGAL_SCORES [1,2,3,4,5,-1]│
            │  (reject 0, 6, decimals → llm_parse_error — unchanged path)
            ▼                                    │
   IndicatorScore.score (smallint, no CHECK) ────┘ stamped on Evaluation
            │
            ├──► MeanCalculator ──► CompetencyResult.score   (untouched)
            ├──► AssessableFractionReliability               (untouched)
            ├──► EvaluationPayloadAssembler ──► webhook      (untouched, raw passthrough)
            │
            ▼  AdminEvaluationSerializer (-1 → null)
   { data: {CODE: …}, meta: {scoring: {prompt,model,framework}} }   (D7)
            │
            ▼
   indicatorChipState()  ── total function, 7 states ──►  ScoreChip
            │                                              (D1/D6)
            └── out-of-domain ──► 'invalid' (loud, raw value, NEVER 'unassessable')
```

---

## File Changes (deltas introduced by this design, beyond the proposal's list)

| File | Action | Description |
|---|---|---|
| `api/.env.example` | Modify | `SCORING_PROMPT_VERSION=2.0.0` — D8, missing from the proposal |
| `api/tests/Unit/Services/PromptBuilderTest.php` | Modify | Fingerprint of `SCORING_PROCEDURE`; absence of "Do NOT use scores 2, 4"; config/`.env.example` parity (D8) |
| `api/tests/Fixtures/cassettes/intermediate_golden.php` | Create | `{4,2,3}`, `{5,4,-1}`, `{2,3,4,5}` (D9) |
| `api/tests/Feature/Jobs/IntermediateScaleCassetteTest.php` | Create | Drives the above; `col_slf_golden.php` stays byte-unchanged |
| `api/app/Http/Resources/Admin/EvaluationResource.php` | Modify | `with()` emits `meta.scoring` (D7) |
| `api/app/Services/Admin/AdminEvaluationSerializer.php` | Modify | `meta()` method + stale-docblock fix (D7) |
| `backoffice/app/composables/useEvaluationReport.ts` | Modify | Return `{ data, meta }`; new `EvaluationScoringMeta` type (D7) |
| `backoffice/app/components/organisms/EvaluationReport.vue` | Modify | Provenance footnote (D7) |
| `backoffice/app/pages/participants/[id].vue` | Modify | Destructure the new return shape (D7) |
| `backoffice/tests/unit/theme.spec.ts` | Modify | Numeric assertion of the new §9.1 pairing (D2) |
| `DESIGN.md` §9.1 | Modify | One new contrast row (D2) |

---

## Testing Strategy

| Layer | What | Approach |
|---|---|---|
| Unit (api, ~95%) | `LEGAL_SCORES` accepts `{1,2,3,4,5,-1}`; rejects `0`, `6`, `-2`, decimals-cast | Pest, RED first per `strict_tdd` |
| Unit (api) | `SCORING_PROCEDURE` fingerprint; "Do NOT use scores 2, 4" absent; `prompt_version`/`.env.example` parity | Pest, D8 |
| Unit (backoffice) | `indicatorChipState` over `{-1,null,1,2,3,4,5}` **and** `{0,6,2.5,NaN}` → `invalid`; assert 2/4 are never `unassessable`; `competencyMeanState(2.5)`/`(3.5)` | Vitest |
| Unit (backoffice) | `ScoreChip` renders numeral + icon + border per state; `invalid` shows the raw value, never `–`; SR label resolves in `en` **and** `it` | Vue Test Utils |
| Unit (backoffice) | New §9.1 pairing ≥4.5:1 by calculation | `theme.spec.ts` |
| Integration (api) | Residual cassettes → `3.00`, `4.50`, `3.50`; determinism run-twice with `{5,4,2}` | Pest + `CassetteLLMProvider` |
| Integration (api) | `meta.scoring` present, values verbatim, `data` shape unchanged | Pest feature test |
| Drift (api, `@ai`) | Band assertions only — domain membership + at least one residual emitted | `ai-integration` workflow only, never PR/develop |
| E2E | None new | No new route or flow; chip rendering is unit-covered |

---

## Migration / Rollout

No data migration. `indicator_scores.score` is a bare `smallInteger()` with no CHECK
constraint, so `{1,3,5,-1} ⊂ {1,2,3,4,5,-1}` needs nothing. No backfill, no re-scoring:
historical Evaluations keep `prompt_version 1.0.0` and their original scores, and D7 now
makes that visible instead of implicit. Rollout is the D10 chain; rollback reverses it.

---

## Open Questions

- [ ] **AD-4 / proposal Q1 (product).** With `2.5` and `3.5` now routinely reachable, is
      `mean == 3.5 → warning` (not `success`) still the intent? This design **assumes
      unchanged** and pins the assumption with a cassette landing exactly on `3.50` (D9), so
      a future change of intent breaks a test rather than sliding silently.
- [ ] **Deployment env vars (ops).** Any environment that sets `SCORING_PROMPT_VERSION`
      explicitly (Railway) must be updated with slice 3, or D8's guard passes in CI while
      production still stamps `1.0.0`. Confirm before deploy.
- [ ] **`report.provenance.label` copy (product/i18n).** Proposed `en`: "Scored with".
      Needs an `it` translation authored with the rest of D3.
