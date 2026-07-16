# Proposal: Discrete BARS Indicator Scoring {1,3,5}

## Intent

The binding domain text currently says the LLM scores each BARS indicator on a **1–5 scale with interpolation allowed (e.g. 4)**. That contradicts the BARS model: each indicator carries exactly **three reference anchors {5,3,1}**, so the LLM must pick the single closest anchor — never a value between them. Left uncorrected, C9 (`scoring-engine`, 8 slices out) would inherit the wrong constraint and build an engine/prompt/schema that emits illegal scores. The scoring engine is fully **greenfield** (no `api/` on disk, no Evaluation model, no tests). This change is a **binding-text correction only** — fix the source-of-truth documents now so C9 starts from the correct invariant.

Success = every binding document states indicator scores are the discrete set **{1,3,5}** (plus the `-1`/null sentinel for unassessable indicators), the UX sample report contains only legal values, and no residual "interpolation"/"tipicamente 1–5" wording remains.

## Scope

### In Scope (text corrections, no code)

- **`CLAUDE.md` (lines 137–144)** — replace "1–5 scale (interpolation allowed, e.g. 4)" with **discrete {1,3,5}, closest-anchor selection, no 2/no 4**; replace the example "COL 3.67 from 4,3,4" with a valid discrete one (e.g. **COL 3.67 from 5,3,3**); add the **unassessable = `-1`/null** rule (exempt from {1,3,5}, excluded from the competency mean).
- **`openspec/ROADMAP.md` (line 42, C9 row)** — "indicators 1–5" → **discrete {1,3,5}**.
- **`docs/app_description/02-domain/02-valutazione.md` (line 33)** — "tipicamente 1–5" → precise **discrete {1,3,5}**.
- **`docs/app_description/03-ux-reference/02-output-valutazione.md` (line 38)** — same correction.
- **`docs/app_description/03-ux-reference/esempio-report-valutazione.json`** — regenerate **all per-indicator scores to {1,3,5}** only; keep the **`-1` sentinel on SLF** (reliability 67%); keep each `competency.score` a fractional mean internally consistent with its regenerated indicators; keep `reliability` values coherent.

### Out of Scope (non-goals)

- **Framework catalog** (`competencies.json`, `roles.json`, `bars/*.json`) — no change; anchors are already `{5,3,1}`.
- **Open product decision #1** — the `reliability` formula and the "valid competency" threshold feeding the 90% completion gate **remain open**. This change settles **indicator-level scoring only**; it does not define reliability or the gate.
- **Missing `bars/SRX.json`** — pre-existing catalog gap (roles.json defines SRX/18 competencies, no BARS file). Not fixed here; recorded as a **C3 dependency/risk**.
- **No implementation code** — C9 owns the engine, prompt, JSON schema, validation, Evaluation model, and tests. This proposal only corrects source-of-truth docs.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None (greenfield; no `openspec/specs/` exist yet). This change corrects binding domain documentation that C9's future `scoring-engine` spec will consume.

## Approach

Doc-correction only — the sole viable approach, since the engine is greenfield. Edit the four binding text locations to state the discrete `{1,3,5}` constraint and the `-1` unassessable rule; hand-regenerate the UX sample JSON so every indicator uses `{1,3,5}` (SLF keeps its `-1`) with competency means and reliability recomputed for internal consistency. Preserve all determinism guarantees already stated (temperature=0; versioned framework/model/prompt; verbatim substring-validated excerpts).

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `CLAUDE.md` (137–144) | Modified | Discrete {1,3,5}, closest-anchor, no interpolation; valid example; add `-1` unassessable rule |
| `openspec/ROADMAP.md` (42) | Modified | C9 row: "indicators 1–5" → discrete {1,3,5} |
| `docs/app_description/02-domain/02-valutazione.md` (33) | Modified | "tipicamente 1–5" → discrete {1,3,5} |
| `docs/app_description/03-ux-reference/02-output-valutazione.md` (38) | Modified | Same |
| `docs/app_description/03-ux-reference/esempio-report-valutazione.json` | Modified | Regenerate all indicator scores to {1,3,5}; keep SLF `-1`; recompute means/reliability |
| Framework catalog `bars/*.json`, `competencies.json`, `roles.json` | Unchanged | Anchors already {5,3,1} — explicitly untouched |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Missing `bars/SRX.json` blocks C9 seeding | Med | Flag as C3 dependency; not introduced/fixed here — documented only |
| `-1` sentinel bleeds into open decision #1 (reliability/gate) | Med | Draw explicit boundary: this change defines the sentinel + mean-exclusion only; reliability formula stays open |
| UX sample regeneration introduces arithmetic drift (means/reliability) | Low | Recompute each mean from regenerated indicators; verify consistency per competency |
| Residual "1–5"/"interpolation" wording left elsewhere | Low | Grep-sweep all four files after edits to confirm no legacy phrasing remains |

## Rollback Plan

Pure documentation edit on a `feature/*` branch — no code, no data, no deploy. Rollback = `git revert` the change commit(s); the binding text returns to its prior wording. Zero production or runtime impact.

## Dependencies

- **C3 (`framework-catalog`)** must create the missing `bars/SRX.json` before C9 can seed SRX scoring (pre-existing gap, flagged here).
- **Downstream:** C9 (`scoring-engine`) inherits this corrected invariant. Forward note for C9: validation MUST reject indicator scores outside **{1,3,5} ∪ {-1 sentinel}**, held to ~95% coverage (correctness-critical).

## Success Criteria

- [ ] `CLAUDE.md` states discrete {1,3,5} closest-anchor scoring, no interpolation, with a valid example and the `-1` unassessable rule (exempt + excluded from the mean).
- [ ] `openspec/ROADMAP.md` C9 row reads "discrete {1,3,5}", not "indicators 1–5".
- [ ] Both domain/UX docs state discrete {1,3,5} (no "tipicamente 1–5").
- [ ] `esempio-report-valutazione.json` contains only `{1,3,5}` indicator scores plus the `-1` on SLF; every `competency.score` equals the arithmetic mean of its assessed indicators; reliability values coherent.
- [ ] The `bars/SRX.json` gap is recorded as a C3 dependency.
- [ ] No framework catalog file changed.
