# Proposal: Italian Locale for the Framework Catalogue

> **Artifact language**: English. **Content language produced by this change**: Italian.
> Every artifact in this change folder — proposal, spec, design, tasks — is written in
> English. The *deliverable* is Italian catalogue content. That distinction holds
> throughout: nothing below is an instruction to write Italian documentation.

## Intent

**An Italian-language project cannot run an interview at all today.** Not "falls back to
English" — it returns HTTP 422.

`InterviewController::composePromptForCompetency()` calls `SystemPromptComposer::compose()`
with `projectLocale: $project->language`. `buildCoverageSection()` checks
`hasTranslation($field, $locale)` on all four fields of every indicator and throws
`AnchorTranslationMissingException` on the first miss; the controller converts that to
`422 {"error":"anchor_translation_missing"}`
(`InterviewController.php:353`, `SystemPromptComposer.php:110-114`). Since **no `it`
translation exists anywhere in the catalogue**, that throw fires on the first indicator of
the first competency, for every `it` project, every time. Scoring has the same hard-fail one
layer down (`PromptBuilder.php:73` → `ScoreEvaluationJob.php:594` → `CompetencyResult` with
`unscorable_reason='anchor_translation_missing'`), but scoring is never reached, because the
interview never starts.

Both Nuxt apps ship `i18n/locales/{it,en}.json` and `config/app.php` declares
`'supported_locales' => ['it','en']`. The product offers Italian at every layer the
candidate can see, and the one layer that actually carries the assessment content is
English-only.

**The gap is structural, not merely unauthored.** `FrameworkCatalogSeeder` calls
`setTranslation(..., 'en', ...)` at every one of its seven call sites
(`FrameworkCatalogSeeder.php:205-206, 264-265, 402-405`) and contains no `'it'` anywhere. The
catalogue JSON has no locale dimension to hold one. The seeder then unconditionally upserts a
`missing_translation` gap row noted `"it locale not yet authored"`
(`FrameworkCatalogSeeder.php:461-464`) — one of only **three** gaps left pending in
production, alongside `missing_potential_competency` for MTG and LAT.

## Volume — counted, not estimated

Counted from `docs/app_description/02-domain/framework/{roles,competencies}.json` and the
five `bars/*.json` files:

| Layer | Rows | Translatable fields each | IT strings |
|---|---|---|---|
| Competencies | 18 | 2 — `name`, `definition` | **36** |
| Roles | 5 | 2 — `name`, `responsibilities` | **10** |
| BARS indicators | 249 | 4 — `text`, `anchor_5`, `anchor_3`, `anchor_1` | **996** |
| | | | **1042 total** |

249 indicators = 83 declared role×competency pairs × 3. Per role: **ICO 45, FLL 54, MLL 54,
BUL 42, SRX 54**. Of the 996 indicator strings, 747 are anchor texts and 249 are indicator
texts. The 117 pre-existing indicators account for 468 strings; the 132 authored by
`bars-catalogue-completion` account for 528.

**The unit of usable coverage is the pair, not the string.** The hard-fail is per-indicator
across all four fields, so a pair becomes interviewable and scorable in `it` only when all
**12** of its strings exist. 83 × 12 = 996. Eleven of twelve is worth exactly as much as
zero. Per role, to make that role's candidates whole: ICO 180 strings, BUL 168, FLL/MLL/SRX
216 each.

## Scope

### In Scope

| # | Deliverable |
|---|---|
| 1 | A locale dimension in the catalogue JSON — the shape decision itself (see Decision 1) |
| 2 | An Italian authoring standard, sibling to the English house-voice document (Decision 3) |
| 3 | Italian content: the strings the scope decision in Decision 4 selects, in both trees |
| 4 | Seeder writes `setTranslation(..., 'it', ...)` from the new locale dimension |
| 5 | `missing_translation` gap resolution — the row has no resolution path today |
| 6 | CI guards updated so IT content is actually checked, not accidentally exempted |
| 7 | Production re-seed, conditional on the locked-FV blocker (Dependencies) |
| 8 | Domain doc updated where it states the catalogue is EN-only |

### Out of Scope

- **Re-authoring the English.** This is a translation. See Constraints.
- **Retro-fixing the English hedge defect** (76% of legacy level-3 anchors; ICO 89%).
  Deferred by `bars-catalogue-completion` and still deferred — but see Risk 1, because
  translating it faithfully propagates it.
- **Locales beyond `it`.** The schema needs no migration for es/fr/de/pt; authoring them is
  a separate change per locale.
- **MTG / LAT** — untranslated because unauthored in any language.
- **Nuxt UI strings** — `i18n/locales/it.json` already exists and is not catalogue content.
- **Changing the hard-fail semantics.** No-EN-fallback is correct and must survive: a
  half-Italian rubric scores worse than a refused interview.

## Constraints (recorded, binding)

1. **This is a translation, not a re-authoring.** The Italian must say what the English says.
2. **Both catalogue trees stay identical.**
3. **Both control files stay empty.** If partial IT coverage needs to be tracked, use a new control file.
4. **Calibrated draft, pending review.** No code gate enforces sign-off; it's a release gate.
5. **Neutral professional Italian.** Not regional, not colloquial.

## Success Criteria

- [x] Every string in the agreed scope exists in `it` in both trees, and the trees are canonically identical.
- [x] For every role in scope, `GET /api/framework/roles/{role}/competencies/{comp}/indicators` returns `translation_gap=false` for all indicators.
- [x] A participant on an `it`-language project completes an interview end to end for every in-scope pair — no 422 `anchor_translation_missing`.
- [x] The `missing_translation` `framework_gaps` row is no longer `pending_authoring` once its scope is complete.
- [x] Every CI content guard demonstrably runs over Italian content, proven by failing step (f) self-test fixtures.
- [x] Both existing control files remain empty; any new control file is enforced in both directions.
- [x] The anchor-length policy for Italian is a recorded, measured decision with its basis written down.
- [x] The Italian authoring standard exists and was committed before the first content PR.
- [x] A native-speaker/domain review is recorded for the shipped content before it assesses a real candidate.
- [x] Spot-check: for a sample of pairs, the Italian carries the same behavioural differentiation as the English at each level.

---

*Full proposal details archived in the openspec change folder.*
