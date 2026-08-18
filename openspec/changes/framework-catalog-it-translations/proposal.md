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

## Decisions this proposal takes, or explicitly defers to design

### Decision 1 — Where `it` lives in the catalogue JSON *(deferred to design; constraint fixed here)*

Today: `{"COMP": [{"indicator": "...", "scale": {"5": "...", "3": "...", "1": "..."}}]}`.
Flat, English implied by absence. The fork is **sibling files per locale** versus **a nested
locale key inside one file**, and it is genuinely load-bearing because it touches every
consumer: `CompetencyNormalizer`, the seeder, and six CI guards.

**Measured, so the fork is not argued in the abstract:**

- The **parity gate** enumerates recursively — `find . -name '*.json'` in both directions
  (`wrapper-ci.yml:422, 448`). Any new file under `framework/`, at any depth, is parity-checked
  automatically and must be vendored.
- Every **content** guard enumerates **non-recursively** and derives the role from the
  filename: `for BARS_FILE in "$TREE"/bars/*.json; ROLE=$(basename "$BARS_FILE" .json)`
  (`wrapper-ci.yml:635-637, 686-688`) and
  `readdirSync(barsDir).filter(f => f.endsWith(".json"))` (`ci-guards.sh:1359`).

So the two obvious sibling schemes fail in opposite, equally bad ways:

- `bars/it/{ROLE}.json` — parity-checked, and **invisible** to
  `catalog_malformed_bars_entries`, `catalog_overlong_bars_anchors`,
  `catalog_crossrole_duplicates` and both completeness gates. 996 strings enter the catalogue
  under zero content guards.
- `bars/{ROLE}.it.json` — visible, but read as a **role named `FLL.it`**. The 18-word ceiling
  applies under a fake role name, `CI_ANCHOR_WORDCOUNT_EXEMPT_ROLE="ICO"` no longer matches
  `ICO.it` (`ci-guards.sh:1589, 1615`), and the cross-role duplicate index gains five phantom
  roles it compares against the real ones.

A nested locale key costs more up front — every guard's `typeof val !== "string"` branch and
the normalizer must be rewritten — but it cannot silently skip anything, because a guard that
does not understand the new shape stops reading rather than passes.

**Binding constraint, whichever wins:** every existing guard MUST demonstrably run over the
Italian content, proven by a self-test row in `wrapper-ci.yml` step (f) against the *same
function* the real gate calls — the house pattern `catalog_overlong_bars_anchors`'s own
comment already argues for. A guard that cannot fail on the content it claims to cover is the
defect class `ci-guards.sh`'s header names, and adding a locale is the easiest way in this
repository to create one accidentally.

### Decision 2 — Does the 18-word ceiling apply to Italian? *(deferred to design; must be measured, not guessed)*

`CI_ANCHOR_WORDCOUNT_MAX=18` (`ci-guards.sh:1597`) is blocking, and its own comment records
the basis: *"Measured, not guessed: … FLL, MLL, BUL and the staged SRX content already top out
at 18 words."* Measured **on English**. Italian expands for the same content — English
compounds (`P&L shortfall`, `region-wide problem`) become prepositional chains in Italian —
but the multiplier for *this* corpus is **unmeasured**, and this proposal will not invent one.

Three outcomes, and each has a named cost:

| Option | Cost |
|---|---|
| Same 18-word ceiling | Forces compression the source did not have. A translator who must lose a clause to pass a gate is no longer translating |
| A separate, measured IT ceiling | Honest, but the number must come from a measured pilot, not a guess |
| Exempt IT from the ceiling | The guard silently stops covering half the catalogue — Decision 1's failure mode, chosen deliberately instead of accidentally |

**Position**: measure before deciding. Design authors one competency across all its roles,
measures the real word-count distribution against its English source, and sets the ceiling
from that — the same "measured, not guessed" discipline the English ceiling already claims for
itself. The advisory 10-word floor (`CI_ANCHOR_WORDCOUNT_MIN`) needs the same treatment and is
cheaper, being non-blocking.

### Decision 3 — An Italian authoring standard is required, and it is a prerequisite

`house-voice-and-anti-hedge-standard.md` is explicitly English: bare-infinitive indicators,
`-ize` spellings, ASCII apostrophe, deficit verbs (`Fails to`, `Struggles to`), the 10-18-word
leader shape. Roughly half of it is language-specific and does not survive translation.

**Position**: an Italian sibling document is deliverable #2 and lands **before** any content —
matching how the English standard was Phase 2 of `bars-catalogue-completion`, before Phase 3
authored anything. It must at minimum settle: the Italian indicator form (infinitive
`Individuare…` maps cleanly), the anchor form (subject-elided third person, `Individua…`),
register (**professional/neutral business Italian, never regional** — this is product content
read by candidates and clients), the Italian deficit-verb inventory that carries level 1's
force without inventing severity the English does not have, and orthography (accents,
apostrophes). **Owner**: the same author who produces the content, reviewed by the native
speaker named in Dependencies — an authoring standard nobody owns is a document, not a
standard.

### Decision 4 — All 249 indicators, or the 132 new ones only? *(product decision; recommendation stated)*

**Recommendation: all 249, sliced by role.** Reasons, in order:

1. **132 buys nothing usable.** The 132 new indicators are spread across FLL/MLL/BUL/SRX
   pairs; the 117 legacy ones cover ICO entirely plus 24 leader pairs. Translating only the
   new ones leaves every role with a mix of translated and untranslated pairs, and the
   per-indicator hard-fail means those roles still 422 at interview start. Nobody becomes
   interviewable in Italian.
2. **Slicing by role does buy something usable.** ICO (180 strings) makes every Individual
   Contributor candidate fully interviewable and scorable in Italian, end to end, and is the
   smallest slice with that property.
3. **The completion gate punishes partial coverage.** Unscorable competencies count against
   the 90% gate by default (`gate.count_unscorable_against_total = true`), so a partially
   translated role produces `pending` Evaluations rather than degrading gracefully.

The honest cost of choosing 249: the 117 legacy indicators were **never retro-reviewed** for
the English adverb-of-degree defect, so translating them faithfully carries a known weakness
into a second language. That is Risk 1, and the alternative — fixing it in the Italian only —
is worse, because it makes the two languages score differently.

## Constraints (recorded, binding)

1. **This is a translation, not a re-authoring.** The Italian must say what the English says.
   Where the English is weak — 76% of legacy level-3 anchors are hedge-only, ICO 89% — the
   translator MUST NOT silently improve it. Two languages that score differently is a worse
   outcome than both being equally weak, because a project pins one locale and two candidates
   assessed in different languages would face materially different rubrics with no record of
   why.
2. **Both catalogue trees stay identical.** `docs/app_description/02-domain/framework` is
   authored; `api/database/framework` is vendored; the parity gate compares as canonical JSON
   in both directions.
3. **Both control files stay empty.** `framework-known-gaps.txt` and
   `framework-competency-gaps.txt` are at zero entries and enforced in both directions. If
   partial IT coverage needs to be tracked, that is a **new** control file with the same
   both-direction doctrine — not a line added to either of these, which answer different
   questions (see `framework-competency-gaps.txt`'s own header on why it is a second file).
4. **Calibrated draft, pending review.** Like the English content, the output is a draft
   pending native-speaker and domain review. **No code gate enforces this today** — the
   English precedent made specialist sign-off a spec requirement with no mechanical
   enforcement, and this change inherits that shape.
5. **Neutral professional Italian.** Not regional, not colloquial.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- **`framework-catalog`** — *Translatable Content Columns*: the seeder requirement
  ("MUST use `setTranslation('field','en',$value)`") extends to `it`; the source-shape
  contract gains a locale dimension. *Data-Gap Authoring Requirements*: the standing
  `missing_translation` gap and the "IT locale translations … remain client/expert artifacts"
  deferral are **directly reversed** for the translated scope and must be rewritten, not left
  standing — the same treatment `bars-catalogue-completion` had to give the SRX non-goal.
  *Idempotent Catalog Seeder*: needs a `missing_translation` resolution path, and its
  **New-locale suppression** clause is the blocker in Dependencies. *Split-File and
  Unified-Shape Adapter Tolerance*: the adapter contract now spans locales.
- **`scoring-engine`** — **no behaviour change.** The L-2/M-2 hard-fail, the no-EN-fallback
  rule and the `unscorable_reason` enum all stay exactly as they are. What changes is that
  `anchor_translation_missing` stops firing for `it` on translated pairs. Scenarios written
  against "IT is absent" need restating against fixtures rather than against the real
  catalogue, exactly as `bars-catalogue-completion` had to restate its SRX-named scenarios.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `docs/app_description/02-domain/framework/**` | Modified/New | IT content, shape per Decision 1 |
| `api/database/framework/**` | Modified/New | Vendored copy, canonically identical |
| `docs/…/framework-authoring/` | New | Italian authoring standard (Decision 3) |
| `api/database/seeders/FrameworkCatalogSeeder.php` | Modified | IT `setTranslation`; `missing_translation` resolution |
| `api/app/Services/FrameworkCatalog/CompetencyNormalizer.php` | Modified? | Only if Decision 1 changes the entry shape |
| `scripts/ci-guards.sh` | Modified | Locale-aware readers; word-count policy per Decision 2 |
| `.github/workflows/wrapper-ci.yml` | Modified | Step (d) enumeration; step (f) self-tests |
| `docs/app_description/02-domain/` | Modified | Wherever EN-only is stated as current |
| Production DB (`railway ssh`) | Modified | Re-seed — gated on the locked-FV blocker |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| 1. Translating the known English defect faithfully carries it into Italian | **Certain** | Accepted deliberately. Recorded here and in the IT standard as an inherited weakness, not an Italian one. Fixing it is a separate change that must fix **both** languages in the same commit |
| 2. The translator improves the English while translating, so the two languages score differently | **High** | Named as Constraint 1; enforced at review by reading the pair side by side, not by a gate. No mechanical check can distinguish a faithful translation from an improved one |
| 3. IT content enters the catalogue under zero content guards (Decision 1's sibling-directory trap) | **High** | Binding constraint in Decision 1 — every guard proven against IT via a step (f) self-test |
| 4. The 18-word ceiling forces bad Italian, or is quietly disabled | **High** | Decision 2 — measure on a pilot competency, set the number from the measurement, record which risk was taken |
| 5. **A locked FrameworkVersion silently swallows the entire change** | **High** | See Dependencies. This is a blocker, not a mitigation |
| 6. Partial coverage produces `pending` Evaluations rather than degrading | Med | Slice by role (Decision 4); no role ships partially translated |
| 7. 1042 strings exceed any single review budget | **Certain** | Per-role or per-competency PR chain. `400-line budget risk: High`; `Chained PRs recommended: Yes`; `Decision needed before apply: Yes` |
| 8. IT gaps on `Competency`/`Role` are invisible to the API | Med | `hasTranslationGap()` exists only on `BarsIndicator`; `CompetencyResource` and `RoleResource` expose no `translation_gap`. Either add it or state explicitly that indicator-level is the only tracked signal |
| 9. Draft Italian scores a real candidate before native-speaker review | **High** | Sign-off as a release gate, per the English precedent — and no code enforces it (Constraint 4) |

## Rollback Plan

Content-only at the file layer, so revert both trees, the IT standard, the guard changes and
the doc together — they move as one slice per role, so they revert as one.

**The database does not revert cleanly, and the asymmetry is the reverse of last time.**
Adding `it` to an existing row is an *update* of a `json` translation column, not a new row.
With no locked FV, re-seeding after the revert rewrites `en` but **does not remove the `it`
key** — `setTranslation('field','en',…)` merges into the existing JSON. Removing Italian from
the database therefore needs a targeted `setTranslation`-less strip or a
`forgetTranslation('it')` pass over the affected rows; it is not a re-seed. With a locked FV,
Italian could not have landed in the first place (see Dependencies), so there is nothing to
roll back.

Establish which case production is in **before** seeding, not during rollback.

## Dependencies

- **THE BLOCKER — no `FrameworkVersion` may be locked.** `framework-catalog/spec.md`
  ("New-locale suppression (explicit)") states it directly: *"While ANY FV is locked, adding a
  new locale translation to an EXISTING catalog row IS a mutation of that row. It is
  SUPPRESSED … New-translation authoring for existing catalog rows waits until no FV is
  locked."* The seeder implements it via the per-call-site `$model->exists` gate
  (`FrameworkCatalogSeeder.php:199, 240, 395`). Every one of the 1042 strings targets a row
  that already exists. **If any FV is locked in production, this entire change lands as a
  green deploy that changes nothing.** `bars-catalogue-completion` named this cost when it
  deferred the locale; the bill is now due. Answer
  `FrameworkVersion::withoutGlobalScopes()->where('is_locked',true)->count()` on production
  **before** any authoring starts, not before seeding — it may change the shape of the whole
  change (a narrowed fill-empty-locale exception, mirroring the `Role.responsibilities`
  precedent at `FrameworkCatalogSeeder.php:240-262`, is one possible answer and belongs to
  design).
- **A native Italian speaker with assessment-domain competence** for review. A translator
  without the domain will not catch a BARS-level shift; a domain expert without native
  Italian will not catch register drift. This is the people dependency that decides whether
  the change is finished.
- **The English source is settled.** Any concurrent edit to an English anchor desynchronises
  its Italian silently — nothing checks that the two locales still say the same thing.
- Production `railway ssh` access for the re-seed.

## Success Criteria

- [ ] Every string in the agreed scope exists in `it` in both trees, and the trees are
      canonically identical.
- [ ] For every role in scope, `GET /api/framework/roles/{role}/competencies/{comp}/indicators`
      returns `translation_gap=false` for all of that role's indicators.
- [ ] A participant on an `it`-language project completes an interview end to end for every
      in-scope pair — no 422 `anchor_translation_missing`, no `unscorable_reason` of that kind
      in the resulting `CompetencyResult` rows.
- [ ] The `missing_translation` `framework_gaps` row is no longer `pending_authoring` once its
      scope is complete, and the seeder has a resolution path that survives a re-run.
- [ ] Every CI content guard demonstrably runs over Italian content, proven by a failing
      fixture in its `wrapper-ci.yml` step (f) self-test — not by the absence of errors.
- [ ] Both existing control files remain empty; any new control file is enforced in both
      directions.
- [ ] The anchor-length policy for Italian is a **recorded, measured** decision with its basis
      written down, whatever the number.
- [ ] The Italian authoring standard exists and was committed **before** the first content PR.
- [ ] A native-speaker/domain review is recorded for the shipped content before it assesses a
      real candidate.
- [ ] Spot-check: for a sample of pairs, the Italian carries the same behavioural
      differentiation as the English at each level — including where the English is weak.

## Proposal Question Round

Not asked interactively (delegated execution). Each is a product decision the spec and design
phases must **not** answer alone.

1. **Is any production `FrameworkVersion` locked?** This is not a preference, it is a
   fact-finding question that gates the change's feasibility. If yes: accept a narrowed
   fill-empty-locale seeder exception, or wait, or unlock. Answer before authoring starts.
2. **All 249 indicators or the 132 new ones?** Recommendation above is **all 249, sliced by
   role, ICO first** — because 132 makes nobody interviewable. Confirm, and confirm the role
   order (ICO is the smallest complete slice; it is not necessarily the most commercially
   urgent).
3. **Which risk do we take on anchor length?** Compress the Italian to fit an English-derived
   ceiling, calibrate a separate measured Italian ceiling, or exempt Italian and lose the
   guard. Recommendation: measure a pilot competency first, then choose with the number in
   hand.
4. **Confirm translation-fidelity over quality.** The Italian will reproduce the English's
   measured hedge defect. Confirm that cross-locale score comparability outranks Italian
   quality — or open the retro-fix as its own change that repairs **both** languages together.
5. **Does partial IT coverage need a tracked exemption?** House doctrine says an exemption
   enforced in both directions; that implies a new control file if we ship role by role. Or we
   ship the entire scope in one landing and never have a partial state to track. The first is
   reviewable; the second is not.
