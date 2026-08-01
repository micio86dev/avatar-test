# Tasks: Discrete BARS Indicator Scoring {1,3,5}

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~35–55 lines across 5 files |
| 400-line budget risk | Low |
| Chained PRs recommended | No |
| Suggested split | Single PR |
| Delivery strategy | ask-on-risk |
| Chain strategy | pending |

Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: pending
400-line budget risk: Low

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | All 5 text edits + JSON regeneration + verification | PR 1 | Single atomic doc-correction commit on `feature/assessment-engine` → `develop` |

---

## Phase 1: Binding Text Edits (independent, any order)

- [x] 1.1 **`CLAUDE.md` lines 139–140**: Replace `"1–5" scale (interpolation allowed, e.g. 4)` with discrete `{1,3,5}` wording (closest anchor, no 2/4); replace example `"COL 3.67 from 4,3,4"` with `"COL 3.67 from 5,3,3"`; insert -1/null unassessable-sentinel rule (exempt from {1,3,5}, excluded from mean) inline after the set statement. Spec ref: Requirement "Indicator Score Domain" + "Unassessable Indicator Sentinel" + Scenario "CLAUDE.md states discrete {1,3,5}".

- [x] 1.2 **`openspec/ROADMAP.md` C9 row (~line 42)**: Replace `"indicators 1–5, competency mean"` with `"indicators {1,3,5}, competency mean (assessed only)"`. Spec ref: Scenario "ROADMAP.md C9 row references discrete {1,3,5}".

- [x] 1.3 **`docs/app_description/02-domain/02-valutazione.md` line ~33**: Replace `"Punteggio assegnato (tipicamente 1–5)"` with `"Punteggio assegnato sull'insieme discreto {1,3,5}; -1 se non valutabile"` in the indicator table. Spec ref: Requirement "Binding Document Correctness".

- [x] 1.4 **`docs/app_description/03-ux-reference/02-output-valutazione.md` line ~17**: Inside the illustrative JSON code block, change `"score": 4` → `"score": 3` (removes the illegal out-of-set value from the example). Spec ref: Requirement "Binding Document Correctness".

- [x] 1.5 **`docs/app_description/03-ux-reference/02-output-valutazione.md` line ~38**: Replace `"I punteggi per indicatore sono tipicamente su scala 1–5;"` with the discrete-set wording + -1/null description; append the non-normative reliability note (`"i valori di reliability nell'esempio sono illustrativi e non normativi (in attesa della decisione aperta #1)"`). Spec ref: Decision "reliability values kept as illustrative / non-normative".

---

## Phase 2: JSON Regeneration

- [x] 2.1 **`docs/app_description/03-ux-reference/esempio-report-valutazione.json` — set indicator scores**: Apply the AUTHORITATIVE breakdown from `design.md` exactly (do NOT re-derive sentiment): COL→[5,3,3], COM→[5,3,3], CSF→[5,3,3], DRV→[5,3,3], INF→[5,3,5], INN→[5,5,3], LRN→[5,5,3], OPX→[3,3,5], PRS→[5,5,3], RES→[5,5,3], SLF→[5,3,-1], STG→[5,3,3]. Keep -1 sentinel on SLF indicator 3 unchanged. Preserve `excerpts` and `explanation` fields verbatim. Spec ref: Scenario "esempio-report-valutazione.json contains only legal indicator scores".

- [x] 2.2 **`docs/app_description/03-ux-reference/esempio-report-valutazione.json` — recompute competency means**: Update each `competency.score` to the arithmetic mean of its assessed indicators (excluding -1), rounded to 2dp: COL/COM/CSF/DRV/STG→3.67; INF/INN/LRN/PRS/RES→4.33; OPX→3.67; SLF→4.0. Do NOT recompute `reliability` fields — keep them as-is. Spec ref: Requirement "Competency Score Arithmetic" + Decision "competency.score = recomputed mean of assessed indicators only".

- [x] 2.3 **Cross-check CLAUDE.md consistency**: Confirm CLAUDE.md's example `"COL 3.67 from 5,3,3"` matches the COL entry in the regenerated JSON exactly (indicators [5,3,3], score 3.67). Spec ref: Scenario "CLAUDE.md states discrete {1,3,5}" + design ordering/atomicity rule 3.

---

## Phase 3: Verification Sweeps (run before commit)

- [x] 3.1 **Grep sweep — stray continuous-scale language**: Run `rg -n "1.5|interpolation|e\.g\. 4|tipicamente 1" CLAUDE.md openspec/ROADMAP.md docs/app_description/02-domain/02-valutazione.md docs/app_description/03-ux-reference/02-output-valutazione.md docs/app_description/03-ux-reference/esempio-report-valutazione.json` — expect zero matches. Spec ref: Requirement "Binding Document Correctness"; Testing Strategy "Doc grep".

- [x] 3.2 **Grep sweep — illegal `"score"` values in JSON/code blocks**: Run `rg -n '"score":\s*(2|4)' CLAUDE.md openspec/ROADMAP.md docs/app_description/02-domain/02-valutazione.md docs/app_description/03-ux-reference/02-output-valutazione.md docs/app_description/03-ux-reference/esempio-report-valutazione.json` — expect zero matches (catches any leftover 4 in illustrative snippets). Spec ref: Testing Strategy "Doc grep — no bare `score: N` where N ∉ {1,3,5,-1}".

- [x] 3.3 **JSON invariant — indicator set membership**: Parse `esempio-report-valutazione.json`; assert every per-indicator `score` field ∈ {1, 3, 5, -1}. Spec ref: Scenario "esempio-report-valutazione.json contains only legal indicator scores".

- [x] 3.4 **JSON invariant — competency mean arithmetic**: For each competency in `esempio-report-valutazione.json`, compute `mean(indicators where score != -1)` rounded to 2dp and assert it equals the stored `competency.score`. Spec ref: Requirement "Competency Score Arithmetic"; Testing Strategy "JSON invariant — each competency.score == mean".

- [x] 3.5 **Consistency check — CLAUDE.md example vs COL JSON**: Confirm the string `"5,3,3"` appears in CLAUDE.md and COL's indicators in the JSON are exactly [5,3,3] with `score: 3.67`. Spec ref: Testing Strategy "Consistency".
