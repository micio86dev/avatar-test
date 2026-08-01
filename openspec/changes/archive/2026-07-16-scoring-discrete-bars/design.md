# Design: Discrete BARS Indicator Scoring {1,3,5}

## Technical Approach

Documentation-only correction (C9 engine is greenfield; no code exists). Four binding
text locations are edited to state that each BARS indicator is scored on the **discrete
set {1,3,5}** (closest single anchor, no interpolation, never 2/4), plus a **-1
unassessable sentinel** rule. The UX sample JSON is hand-regenerated so every indicator
score lands in {1,3,5} ∪ {-1} and each `competency.score` equals the mean of its
**assessed** indicators. Excerpts and explanations stay verbatim; only numeric scores and
derived means change. Determinism guarantees (temperature=0, versioned
model/prompt/framework, substring-validated verbatim excerpts) are preserved unchanged.

## Architecture Decisions

### Decision: Unified remapping rule — mean-preserving-where-possible, nearest-neighbor fallback

**Choice**: For each competency, apply the following single deterministic rule over its
ASSESSED indicators only (exclude any -1 sentinel; sentinels stay -1 and are excluded
from the mean):

1. Compute the original assessed mean.
2. If that mean is **REACHABLE** by some assignment of assessed indicators from {1,3,5}:
   choose the assignment that hits it exactly. If multiple assignments reach it, tie-break
   by explanation sentiment (the strongest / most unqualified explanation keeps the higher
   anchor; explicit hedges such as "room for improvement", "occasionally", "though…",
   "some oversight" drop to the lower anchor).
3. If **UNREACHABLE**: choose the NEAREST reachable mean by |Δ|. If two reachable means
   are equidistant, choose the **HIGHER** one. Realize it by upgrading the minimal number
   of indicators (preference: upgrade 4s to 5 first, keep non-4 indicators unchanged
   where possible); tie-break by sentiment.

This single rule **supersedes any "all-4 → 5" special case**. It is deterministic except
for the sentiment tie-break, for which **the breakdown below is authoritative** — apply and
verify phases must follow the breakdown exactly, not re-derive sentiment independently.

**Alternatives considered**: (a) blanket 4→5 or 4→3; (b) pure per-indicator sentiment
independent of the mean; (c) round-half-up of the interpolation; (d) map all-4 → 5.0
(rejected — see rationale).
**Rationale**: This rule reproduces the proposal's **locked** example exactly — COL
[4,3,4], displayed mean 3.67, is reachable as {5,3,3} (sum 11 / 3 = 3.67), giving "COL
3.67 from 5,3,3". Pure per-indicator sentiment (b) would push COL to [5,3,5]=4.33 and
BREAK the locked example, so it is rejected. All-`4` competencies (mean 4.0) are
**unreachable** with discrete {1,3,5} on 3 indicators: no triple from {1,3,5} sums to 12
— reaching 12 would require a 2 (e.g. 5+5+2), which is NOT an anchor value. The nearest
reachable means for a triple targeting 4.0 are 3.67 (sum 11, e.g. {5,3,3}) and 4.33 (sum
13, e.g. {5,5,3}). Both are |Δ| = 0.33 from 4.0 → tie → pick HIGHER = 4.33 → realized
as [5,5,3], `competency.score` 4.33. The old "all-4 → 5.0" rationale ("honestly
recomputed to 5.0") is **arithmetically false**: 5.0 is |Δ| = 1.0 from 4.0, which is 3×
farther than the nearest-neighbor choice of 4.33.

**SLF derivation (C1)**: assessed indicators [4,4] (third is -1). Original assessed mean
= (4+4)/2 = 4.0. For a pair from {1,3,5}: 4.0 IS reachable as {5,3} ((5+3)/2 = 4.0).
→ assign [5,3,-1], `competency.score` 4.0. Sentiment tie-break: indicator 1 ("Describe
products and services accurately") has a strong, unqualified explanation → keeps 5;
indicator 2 ("Link own arguments to customer needs") explanation is comparative and
slightly softer → drops to 3.

**OPX derivation (W1)**: assessed indicators [3,3,4], original mean = (3+3+4)/3 = 3.33.
3.33 is unreachable from {1,3,5} triples (no triple sums to exactly 10). Nearest reachable
means: 3.0 (3+3+3=9; |Δ|=0.33) and 3.67 (3+3+5=11; |Δ|=0.33). Equidistant → pick
HIGHER = 3.67 → realized as [3,3,5] (upgrade the single 4 to 5, keep the two 3s).
`competency.score` = (3+3+5)/3 = 3.67. This demonstrates that the unified rule handles
non-all-4 unreachable cases without any special case.

### Decision: competency.score = recomputed mean of ASSESSED indicators only

**Choice**: Recompute each `competency.score` as the arithmetic mean of regenerated
indicator scores, **excluding any -1**. Round to 2 decimals (existing sample convention:
3.67, 3.33). SLF = mean of its two assessed indicators, -1 excluded.
**Rationale**: The proposal locks "-1 exempt from {1,3,5} and EXCLUDED from mean". Deriving
the mean from the regenerated indicators (not preserving old means) guarantees arithmetic
consistency by construction and prevents drift.

### Decision: reliability values kept as illustrative / non-normative

**Choice**: Do NOT recompute `reliability` ("100%", "67%"). Keep existing values and add a
one-line note in the two UX docs that sample `reliability` is illustrative and
**non-normative pending open product decision #1**.
**Alternatives considered**: recompute reliability from an assessed/total ratio.
**Rationale**: The reliability formula + valid-competency threshold is **open decision #1
(out of scope)**. Recomputing would implicitly define that formula. Keeping values as-is
with an explicit non-normative note settles indicator scoring only and leaves #1 open —
the exact boundary the proposal demands. (SLF's "67%" ≈ 2 of 3 assessed already reads
illustratively; left untouched.)

## Data Flow

    Binding text (CLAUDE.md, ROADMAP, 2 domain/UX .md)  ──► state {1,3,5} + -1 rule
    UX sample JSON ──► map each 4→{5|3} by unified rule ──► recompute mean (excl -1)
                                                         └─► reliability kept (noted)

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `CLAUDE.md` (137–144) | Modify | Replace 1–5/interpolation wording + example; add -1 rule |
| `openspec/ROADMAP.md` (line 42) | Modify | C9 row "indicators 1–5" → "indicators {1,3,5}" |
| `docs/app_description/02-domain/02-valutazione.md` (line 33) | Modify | "tipicamente 1–5" → discrete {1,3,5} |
| `docs/app_description/03-ux-reference/02-output-valutazione.md` (line 17) | Modify | Illustrative JSON block: `"score": 4` → `"score": 3` (inside indicator object) so the code block does not show an out-of-set value |
| `docs/app_description/03-ux-reference/02-output-valutazione.md` (line 38) | Modify | Same + reliability non-normative note |
| `docs/.../esempio-report-valutazione.json` | Modify | Regenerate all indicator scores + means |

### Exact edits (quote → replacement)

**CLAUDE.md 139–140** — replace:
> `anchors and scores each indicator on a **1–5** scale (interpolation allowed, e.g. 4).`
> `` `competency.score` = **mean of indicator scores** (e.g. COL 3.67 from 4,3,4), plus a``
with:
> `anchors and scores each indicator on the **discrete set {1,3,5}** — the single closest`
> `anchor, never an in-between value (no 2, no 4). An indicator with no assessable evidence`
> `is scored **-1** (unassessable: exempt from {1,3,5} and **excluded** from the competency`
> `mean). ` `competency.score` = **mean of the assessed indicator scores** (e.g. COL 3.67`
> `from 5,3,3), plus a`

**ROADMAP.md 42** — `indicators 1–5, competency mean` → `indicators {1,3,5}, competency mean (assessed only)`.

**02-valutazione.md 33** — `| `score` | Punteggio assegnato (tipicamente 1–5) |`
→ `| `score` | Punteggio assegnato sull'insieme discreto {1,3,5}; -1 se non valutabile |`.

**02-output-valutazione.md line ~17** (inside the illustrative JSON code block, indicator `score` field) — `"score": 4` → `"score": 3` so the code block does not exhibit an illegal value that contradicts the updated note below it.

**02-output-valutazione.md 38** — `- I punteggi per indicatore sono tipicamente su scala 1–5;`
→ `- I punteggi per indicatore usano l'insieme discreto {1,3,5} (ancora più vicina, mai valori intermedi); -1 = non valutabile (escluso dalla media);`
and append: `- i valori di `reliability` nell'esempio sono illustrativi e non normativi (in attesa della decisione aperta #1);`.

### Regenerated JSON scores (deterministic)

Derivation rule applied to each competency's **assessed** indicators only; -1 excluded.
Mean verified arithmetically (2dp) from the new indicators.

| Comp | old indicators | old mean | new indicators | new mean | reliability | derivation |
|------|---------|------|------|------|------|------|
| COL | 4,3,4 | 3.67 | 5,3,3 | 3.67 | 100% | 3.67 reachable as {5,3,3}; locked example |
| COM | 4,3,4 | 3.67 | 5,3,3 | 3.67 | 100% | 3.67 reachable as {5,3,3} |
| CSF | 4,3,4 | 3.67 | 5,3,3 | 3.67 | 100% | 3.67 reachable as {5,3,3} |
| DRV | 4,3,4 | 3.67 | 5,3,3 | 3.67 | 100% | 3.67 reachable as {5,3,3} |
| INF | 4,4,4 | 4.0 | 5,3,5 | 4.33 | 100% | 4.0 unreachable; nearest tie 3.67/4.33 → higher = 4.33; ind 2 is most-hedged → drops to 3 |
| INN | 4,4,4 | 4.0 | 5,5,3 | 4.33 | 100% | 4.0 unreachable; nearest tie 3.67/4.33 → higher = 4.33; ind 3 is most-routine → drops to 3 |
| LRN | 4,4,4 | 4.0 | 5,5,3 | 4.33 | 100% | 4.0 unreachable; nearest tie 3.67/4.33 → higher = 4.33; ind 3 ("hungry to learn") narrower context → drops to 3 |
| OPX | 3,3,4 | 3.33 | 3,3,5 | 3.67 | 100% | 3.33 unreachable; nearest tie 3.0/3.67 → higher = 3.67 |
| PRS | 4,4,4 | 4.0 | 5,5,3 | 4.33 | 100% | 4.0 unreachable; nearest tie 3.67/4.33 → higher = 4.33; ind 3 ("analyzes/applies new info") narrower than diagnosis/hypothesis → drops to 3 |
| RES | 4,4,4 | 4.0 | 5,5,3 | 4.33 | 100% | 4.0 unreachable; nearest tie 3.67/4.33 → higher = 4.33; ind 3 ("acknowledge mistakes") overlaps with ind 2 framing; ind 2 stronger → ind 3 drops to 3 |
| SLF | 4,4,-1 | 4.0 | 5,3,-1 | 4.0 | 67% | pair: 4.0 reachable as {5,3} |
| STG | 4,3,4 | 3.67 | 5,3,3 | 3.67 | 100% | 3.67 reachable as {5,3,3} |

**Arithmetic verification** (all confirmed via Python):
- [5,3,3]: (5+3+3)/3 = 11/3 = 3.67 ✓
- [5,5,3]: (5+5+3)/3 = 13/3 = 4.33 ✓
- [3,3,5]: (3+3+5)/3 = 11/3 = 3.67 ✓
- [5,3,-1]: (5+3)/2 = 8/2 = 4.0 ✓

**Which indicator drops to 3 in each competency** (the sentiment tie-break; apply/verify
must follow this breakdown, not re-derive sentiment):

- **COL**: indicator 3 ("Demonstrate commitment/dedication to team goals") explanation is
  softer than indicator 1 ("effective collaboration… project success") → ind 3 drops to 3;
  ind 1 → 5; ind 2 stays 3. Result: [5,3,3].
- **COM**: indicator 2 ("Keep people interested", explicit "room for improvement") was
  already 3 in the original and stays 3. Of the two original 4s, ind 1 ("Get the point
  across clearly") has an unqualified strong result → keeps 5; ind 3 ("Speak effectively
  in a group") required repeated explanations before the idea was accepted → more hedged,
  drops to 3. Result: [5,3,3].
- **CSF**: indicator 2 ("Keep commitments", "room for improvement in proactive
  communication") → 3; ind 1 → 5; ind 3 → 3. Result: [5,3,3].
- **DRV**: indicator 2 ("Organize own work", "occasional prioritization issues were
  implied") → 3 (already 3 in original; stays 3); ind 1 → 5; ind 3 → 3. Result: [5,3,3].
- **INF**: all three explanations are positive; ind 3 ("Provide sound rationale")
  uses "drew on discussions… personal research… helped convince" (factual, strong) and
  ind 2 ("Ensure that own positions address others' needs") uses "tailored their proposal…
  fostering cooperation" (process, moderately strong). Ind 2 is relatively softer →
  ind 2 drops to 3; ind 1 → 5; ind 3 → 5. Result: [5,3,5] = (5+3+5)/3 = 4.33 ✓.
- **INN**: ind 3 ("Quickly adapt to new ways", description of rapid research) is
  competent but most routine of the three → drops to 3. Result: [5,5,3] = 4.33 ✓.
- **LRN**: ind 1 ("Accept feedback openly") "asking for advice and applying feedback"
  strong; ind 2 ("Seeks opportunities") "proactive approach… strong commitment" strong;
  ind 3 ("Prove hungry to learn") "quickly acquiring knowledge" is comparative but
  narrower context → drops to 3. Result: [5,5,3] = 4.33 ✓.
- **OPX**: ind 3 ("Contribute to team goals") the 4 in original; unified rule upgrades
  it to 5. Inds 1 and 2 (both 3 in original) stay 3. Result: [3,3,5] = 3.67 ✓.
- **PRS**: ind 3 ("Analyzes, incorporates and applies new information") describes rapid
  research and application; solid but slightly narrower than the diagnosis (ind 1) and
  hypothesis (ind 2) indicators → drops to 3. Result: [5,5,3] = 4.33 ✓.
- **RES**: ind 3 ("Acknowledge own mistakes") description overlaps heavily with ind 2
  explanation; ind 2 ("Keep calm") "reassured their team and ensured continuity" is
  slightly stronger framing → ind 3 drops to 3. Result: [5,5,3] = 4.33 ✓.
- **SLF**: ind 1 ("Describe products and services accurately") "detailed and engaging
  description… solid understanding" → 5; ind 2 ("Link own arguments to customer needs")
  "effectively linked… demonstrating understanding" → softer relative to ind 1 → 3.
  Result: [5,3,-1] = 4.0 ✓.
- **STG**: ind 2 ("Understand hierarchical and organizational relationships") already 3
  in original (stays 3); ind 1 → 5; ind 3 → 3. Result: [5,3,3] = 3.67 ✓.

**Apply-phase rule (authoritative)**: for each competency, (1) target the original
displayed assessed mean; (2) if reachable with {1,3,5}, pick the assignment that hits it,
tie-broken by sentiment per this breakdown; (3) if unreachable, apply nearest-neighbor
(prefer higher on tie), realize by upgrading minimal 4s to 5 first.
`competency.score` is ALWAYS recomputed from the final assessed indicators (excl -1),
rounded to 2 dp. Record any per-indicator deviation from this breakdown with its justification.

## Interfaces / Contracts

No schema change. Indicator `score ∈ {1,3,5} ∪ {-1}`; `competency.score ∈ [1,5]` = mean of
assessed indicators. Forward note for C9: validation MUST reject any indicator score outside
{1,3,5} ∪ {-1}; ~95% coverage (correctness-critical).

## Testing Strategy

| Layer | What to Test | Approach |
|-------|-------------|----------|
| Doc grep | No stray "1–5"/"interpolation"/"e.g. 4"/"tipicamente 1" in the 4 edited files | `rg` sweep, expect zero |
| Doc grep | No bare `"score": N` where N ∉ {1,3,5,-1} inside JSON/code blocks (catches stray 4s in illustrative snippets, not only the phrase "e.g. 4") | `rg` sweep on all edited docs |
| JSON invariant | Every indicator score ∈ {1,3,5,-1} | parse JSON, assert set membership |
| JSON invariant | Each `competency.score` == mean of assessed indicators (excl -1), 2dp | parse + recompute + assert |
| Consistency | CLAUDE.md example "5,3,3" mean == 3.67 and matches COL in JSON | manual assert |

## Migration / Rollout

No migration. Pure doc edit on `feature/*`; rollback = `git revert`. Zero runtime impact.

## Ordering / Atomicity

1. Edit the text files (independent, any order): CLAUDE.md, ROADMAP.md, 02-valutazione.md,
   02-output-valutazione.md (both line ~17 and line ~38 edits).
2. Regenerate JSON (scores → recompute means → keep reliability + note).
3. Ensure CLAUDE.md's "COL 3.67 from 5,3,3" matches the JSON COL indicators exactly.
4. Run grep + JSON-invariant checks before commit. Single atomic commit (doc correction).

## Open Questions

- [ ] Open product decision #1 (reliability formula + valid-competency threshold) stays
  OUT of scope; sample reliability flagged non-normative.
- [ ] Missing `bars/SRX.json` is a pre-existing C3 dependency; NOT fixed here.
