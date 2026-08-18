# Design: Italian Locale for the Framework Catalogue

> **Artifact language**: English. **Content produced**: Italian. Nothing below asks
> for Italian documentation.

## Technical Approach

Give every translatable leaf in the catalogue JSON an explicit locale map, make every
reader of that JSON fail closed on any other shape, and let the seeder write whatever
locales the map carries. Content then lands role by role behind a new both-direction
control file that proves, mechanically, that no role ever ships half-translated.

Verified against production before designing: `FrameworkVersion` locked count is **0**.
The blocker is clear. The locked-FV path is still designed (D4) because a silent no-op
over 1042 strings is the worst available outcome.

---

## D1 — JSON shape: explicit locale map at the leaf

**Choice.** Every translatable string becomes an object keyed by locale. Both locales
explicit; `en` mandatory; unknown locale keys rejected.

```jsonc
// bars/{ROLE}.json
{ "PRS": [ { "indicator": { "en": "...", "it": "..." },
            "scale": { "5": { "en": "...", "it": "..." },
                       "3": { ... }, "1": { ... } } } ] }
// competencies.json   { "PRS": { "name": {"en":…,"it":…}, "definition": {"en":…,"it":…} } }
// roles.json          { "ICO": { "name": {"en":…,"it":…}, "responsibilities": {"en":…,"it":…},
//                                "competencies": ["PRS", …] } }   // competencies stays a plain array
```

| Option | Why rejected |
|---|---|
| `bars/it/{ROLE}.json` | Ratified out. Parity-checked, invisible to every content guard. |
| `bars/{ROLE}.it.json` | Ratified out. Read as a role named `FLL.it`. |
| Entry-level `"it": {…}` block beside the English | **Silently ignored** by all four bars guards — they read `entry.indicator` / `entry.scale` and never enumerate other entry keys. Decision-1's failure mode, wearing a nested-key disguise. |
| File-level `{"en": {…}, "it": {…}}` | Fails loudly (good) but separates each English string from its translation by hundreds of lines — destroying the one artefact review actually needs (D7). |
| Implied English + explicit `it` | Cannot be made fail-loud: an absent locale key is indistinguishable from "shape regressed". Leaves the asymmetry the next author trips on. |

**Rationale.** Only the leaf map does three things at once: (a) a guard that has not been
updated **stops reading** rather than passing — `catalog_malformed_bars_entries`'s
`isBlank()` sees an object and reports `malformed-entry`; (b) the git diff of adding
Italian is *interleaved with the English it translates*, so the PR diff is itself
bilingual; (c) adding es/fr/de/pt later is content, not migration.

**Honest cost.** 249 entries × 4 fields × 2 trees, plus 18 competencies and 5 roles, are
rewritten mechanically — ~4000 diff lines in one PR. Mitigated by making the migration a
committed script whose re-run must produce **no diff** (same doctrine as
`framework-crossrole-baseline.txt`: generated, never typed).

**The one guard that would go silently blind.** `CI_ANCHOR_WORDCOUNT_SCRIPT` does
`if (typeof text !== "string") continue` — under the new shape it would emit nothing and
`catalog_overlong_bars_anchors` would pass vacuously. That line becomes a hard
`process.exit(1)`. `CI_CROSSROLE_SCRIPT` has the same `continue`, but there the
`framework-crossrole-baseline.txt` stale-entry direction catches it (its 2 entries stop
matching → build fails). Both are fixed anyway; neither relies on luck.

---

## D2 — Guard-by-guard disposition

`$TREE` ∈ {`docs/app_description/02-domain/framework`, `api/database/framework`}.

| # | Guard (`scripts/ci-guards.sh`) | Disposition | How we know it still bites |
|---|---|---|---|
| 1 | `json_canonical_equal` parity, `find -name '*.json'`, both directions | **Unchanged** | Compares parsed JSON wholesale; already covers content it does not understand. Existing self-test row suffices. |
| 2 | `role_keys`, `role_competency_pairs` | **Unchanged** | Read only keys + `competencies` array. Never read `name`/`responsibilities`. Stated, not assumed. |
| 3 | `bars_competency_keys` → `catalog_missing_bars_pairs` → `catalog_unexpected_missing_bars_pairs` / `catalog_stale_competency_gap_exemptions` | **Locale-parameterised**, 3rd arg, default `en` (byte-identical current behaviour) | Runs twice per tree. `en` against `framework-competency-gaps.txt` (stays empty); `it` against the new file (D6). Self-test: a fixture whose pair has 11 of 12 IT strings MUST be reported. |
| 4 | `catalog_malformed_bars_entries` | **Rewritten**; single guard, all locales | New reasons: `not-a-locale-map`, `missing-en`, `unknown-locale-<x>`, `blank-<locale>`. Self-test: old-shape fixture (bare string) must be CAUGHT, not passed. |
| 5 | `bars_anchor_word_counts` → `catalog_overlong_bars_anchors` (blocking) / `catalog_short_bars_anchors` (advisory) | **Locale-parameterised**; output `ROLE:COMP:LEVEL:LOCALE:WC` (word count stays last so `${LINE##*:}` is untouched); non-string → hard fail | Ceiling per locale (D3). ICO exemption stays role-level and locale-blind — ICO's 20-30-word register is inherited by its translation. Self-test: an IT anchor over the IT ceiling must be caught; an ICO IT anchor must not be examined. |
| 6 | `catalog_crossrole_duplicates` + `catalog_unexpected_crossrole_duplicates` + `catalog_stale_crossrole_baseline_entries` | **Locale-parameterised index**; entry format `ROLE_A:ROLE_B:COMP:LOCALE:FIELD`; baseline regenerated | See D2a. Self-test rows re-pointed at locale-qualified fixtures. |
| 6a | **NEW** `catalog_crosslocale_duplicate_divergence` | **New, blocking** | Prints any (roles, comp, field) duplicated in `en` but not `it`, or vice versa. See D2a. |
| 7 | **NEW** `catalog_locale_coverage` + `catalog_unexpected_locale_gaps` + `catalog_stale_locale_gap_exemptions` + `locale_gaps_whole_role_violations` | **New**, both directions | D6. |
| 8 | **NEW** `catalog_meta_locale_shape` (roles.json / competencies.json locale maps) | **New** | 46 strings; nothing else reads those fields, so without this they are unguarded. |
| 9 | `competency_gaps_role_order_violations` | **Unchanged**; sibling added for the new file | Grouping-by-role is a review property, needed identically on the new file. |
| — | **wrapper-ci step (h)** `docs/version-catalog.md` | **No change** | See Disagreement 1 — step (h) reads Dockerfiles and a Docker-image table. It touches no framework JSON. Listing it here as a catalogue guard is a misidentification, and pretending otherwise would create a guard that claims coverage it does not have. |

**Binding**: every row above lands with a `wrapper-ci.yml` step (f) self-test calling the
**same function** the real gate calls, against a fixture built to trip it. A guard with no
failing fixture is treated as not delivered.

### D2a — Cross-role duplicates and the "closed" baseline

`framework-crossrole-baseline.txt` is **not empty** (`BUL:MLL:INF:indicator`,
`FLL:MLL:RES:indicator`) and declares itself closed to new entries. A *faithful*
translation of two byte-identical English sentences produces two byte-identical Italian
sentences — so Italian legitimately adds exactly 2 entries.

**Choice**: regenerate the baseline in the locale-qualified format and let it carry 4
entries (`BUL:MLL:INF:en:indicator`, `…:it:indicator`, `FLL:MLL:RES:en:indicator`,
`…:it:indicator`). The "closed" clause is restated as *closed to new **source**
duplicates; a faithful translation of a recorded duplicate inherits its entry*.
**Rejected**: rewording the Italian to break the duplicate — that would differentiate
Italian where English does not, i.e. score the two locales differently on those exact two
indicators, invisibly. Constraint 1 wins.

This yields the **one mechanical fidelity check that actually exists** (guard 6a): if the
Italian pair diverges where the English is identical, the translator improved the source;
if it converges where the English differs, the translator flattened a scope shift. Both
are Constraint-1 violations and both are now build failures. The proposal states no
mechanical check can distinguish faithful from improved — true in general, **false for
this class**, and this is the class the scope-shift discipline cares most about.

---

## D3 — The Italian anchor-length ceiling: pilot design

**Do not guess a multiplier. Fix the decision rule before the measurement exists.**

| | |
|---|---|
| **Pilot corpus** | `PRS` across `FLL, MLL, BUL, SRX` — the 4 non-exempt roles. 12 indicators, **36 anchors**. PRS is assigned to all five roles; ICO is excluded because its register is exempt and would contaminate the ratio. |
| **Blind authoring** | The translator authors these 36 anchors **without being told any ceiling exists**. A translator who knows the number produces compliance, not language, and the measurement then measures itself. |
| **Measurement** | For each anchor, word count exactly as `bars_anchor_word_counts` counts (trim, split `/\s+/`, drop empties), EN and IT. Record the per-anchor ratio `r = wc_it / wc_en`. |
| **Decision rule (fixed now)** | `R` = 90th percentile of `r` over the 36 pairs — not the max, so one compound-noun outlier cannot set policy. `CI_ANCHOR_WORDCOUNT_MAX_IT = ceil(18 × R)`. `CI_ANCHOR_WORDCOUNT_MIN_IT = ceil(10 × R)`, advisory, same as EN. |
| **Falsification** | Then re-check the 36 against the derived ceiling. If **>10%** need a clause dropped to comply, the ceiling is wrong, not the Italian: recompute with `R = max(r)` and record why in the same table. |
| **Artefact** | The full 36-row table (EN wc, IT wc, r) is committed in the IT authoring standard, and `CI_ANCHOR_WORDCOUNT_MAX_IT`'s comment cites it — mirroring the EN constant's own "measured, not guessed" comment. A later revision requires a new table, never a silent bump. |

**Recommendation**: a per-locale measured ceiling (option 2 of proposal Decision 2).
**Rejected**: reusing 18 (forces compression = re-authoring, breaks Constraint 1);
exempting IT (the guard silently stops covering half the catalogue — the exact defect
class this repo keeps re-creating).

**Risk accepted, named**: the ceiling is calibrated on 36 of 747 anchors (~5%). A later
role slice may produce a natural Italian anchor above it. That is a recorded amendment
with a fresh measurement table and a reviewer, not a bump in the PR that hit it.

---

## D4 — Seeder

```
bars/{ROLE}.json ──► CompetencyNormalizer ──► IndicatorDTO{ text: array<locale,string>, … }
                                                   │
                     FrameworkCatalogSeeder ───────┘
                       └─ foreach locale ⇒ setTranslation(field, locale, value)
                            └─ under lock: fill-empty-locale only  ⇒ FrameworkGap(locked_fill_empty_locale)
                       └─ per-pair missing_translation gap (D5)
                       └─ $catalogChange |= wasRecentlyCreated || wasChanged()  ⇒ CatalogMeta::bump()
```

`IndicatorDTO`/`CompetencyDTO` string fields become `array<string,string>` locale maps.
Blast radius is contained: the normalizer's only consumers are the seeder and
`tests/Unit/Services/CompetencyNormalizerTest.php`.

**Locked-FV behaviour — the fill-empty-locale exception.** Extends the existing
`Role.responsibilities` precedent (`FrameworkCatalogSeeder.php:240-262`).

> Under lock, on an EXISTING row, `setTranslation($field, $locale, $v)` is permitted
> **iff** `hasTranslation($field, $locale)` is false **and** `$locale !== 'en'`.
> Never overwrite a non-empty value in any locale. Never touch `en`.

**Defence.** The lock protects a locked FrameworkVersion's rubric from moving under a
candidate. An `en` project reads only `en`, so filling `it` cannot move an `en` score. An
`it` project under a locked FV **cannot be interviewed at all today** (422 on the first
indicator) — there is no score to protect, because the slot is empty by definition. The
fill is strictly monotone: no assessment previously producible changes.
**Counter-argument, recorded**: an `it` project pinned to a locked FV goes from 422 to
interviewable. That is the intended fix, not a regression — but it must never be silent,
so it emits `FrameworkGap kind=locked_fill_empty_locale` per (role, competency) plus a
`Log::warning`, exactly like `locked_fill_empty_role_meta`. This **directly reverses**
`framework-catalog/spec.md` "New-locale suppression (explicit)" and needs a MODIFIED
requirement in the spec delta.

**`CatalogMeta::bump()` — yes, a new locale is structural.** `revision` is documented as a
*"catalog changed"* cache-busting signal, not a row-count. `BarsIndicatorResource` emits
`translation_gap`, which flips from `true` to `false` when Italian lands: the response
body changes. A response body that changes while its cache key does not is precisely the
stale-cache bug `bump()` exists to prevent, and caches keyed on the revision would serve
EN-only payloads to `it` clients indefinitely.

Predicate: `$catalogChange |= $model->wasRecentlyCreated || $model->wasChanged()` —
Eloquent's own answer to "did this row actually change". **Rejected**: a bespoke
`$localeChange` flag — a second bookkeeping mechanism that can drift from the first, which
is the exact defect the seeder's 60-line atomicity docblock exists to prevent.
Idempotency survives: a true no-op re-seed leaves `wasChanged()` false. **Named side
effect**: an English anchor edit now bumps the revision, which it does **not** today — a
latent stale-cache bug fixed in passing. Separable into its own slice if the tasks phase
wants it isolated; it needs its own RED test either way.

---

## D5 — `missing_translation` resolution, and rollback

**Today**: unconditionally upserted `pending_authoring`, global (`role_code=null`,
`competency_code=null`), no resolution path.

**Choice** — mirror the fix-5a pattern (computed from JSON/filesystem, never DB state, so
it proceeds under lock):

| Row | Computed from | Resolves when |
|---|---|---|
| `missing_translation` per (role, comp) | all 12 IT strings present in the source JSON for that pair | that pair is complete → `status='resolved'` |
| `missing_translation` global (nulls) | count of pending per-pair rows | zero pending → `resolved`; otherwise note updated to `"it locale: N of 83 pairs pending"` |
| orphan per-pair rows | `roles.json` no longer assigns the pair | `resolved` (mirrors the `competency_no_bars` orphan sweep) |

Unique key `(kind, role_code, competency_code)` with `NULLS NOT DISTINCT` already
supports coexisting global and per-pair rows of the same kind.

**Rollback is asymmetric and needs a mechanism, not a paragraph.** `setTranslation`
MERGES into the JSON column (proved by
`tests/Feature/Seeders/TranslationSurvivalReseedTest.php`), so deleting `it` from source
and re-seeding leaves `it` in the database forever.

**Deliverable**: `php artisan framework:forget-locale it [--dry-run] [--force]` —
`forgetTranslation($field,'it')` over `BarsIndicator`, `Competency`, `Role` inside one
transaction; reports per-model counts; **refuses to run while any FV is locked** (removing
a translation from a locked-FV row IS destructive — an `it` project mid-interview would
start 422ing); requires `--force` in production; calls `CatalogMeta::bump()`. A rollback
nobody can execute is not a rollback.

---

## D6 — Partial coverage

**New control file `scripts/framework-locale-gaps.txt`**, entries `LOCALE:ROLE:COMP`
(e.g. `it:FLL:PRS`), same parsing discipline, same `CI_LOCALE_GAPS_FILE` override seam,
same both-direction doctrine as its two siblings — and one addition:

| Direction | Failure |
|---|---|
| Pair IT-incomplete and NOT listed | fail |
| Listed pair now fully IT-translated, or no longer declared in `roles.json` | fail |
| **Per role×locale, listed-gap count is neither 0 nor the role's full pair count** | fail — *no role ships half-translated, mechanically* |
| Role entries interleaved | fail (sibling of `competency_gaps_role_order_violations`) |

It starts at **83 `it:` entries** in the shape PR and shrinks by exactly one role per
content slice, hitting empty at the last. Every content PR therefore carries a
CI-verified scoreboard: "did this PR actually complete the role" becomes a fact, not a
claim. The two existing control files stay empty and untouched.

**`InterviewController` mid-migration: no code change.** The per-indicator hard fail and
the no-EN-fallback rule survive exactly as they are — a half-Italian rubric scores worse
than a refused interview, and a test asserting the 422 still fires on an untranslated pair
is what stops someone "fixing" this later with a fallback. The bad mid-migration state
(competency A composes, competency B 422s, `pending` Evaluations) is prevented at the
**slice** level by the whole-role rule above, not in the controller.

**Risk 8 — IT gaps on `Competency`/`Role` are invisible to the API.** Decision:
**indicator-level stays the only API-exposed signal**, stated explicitly rather than left
ambiguous. A role-level flag needs a full-catalogue scan per list request; the aggregate
is already available, better shaped, in the new per-pair `framework_gaps` rows the
backoffice can read. Refusing to create an `it` project for an uncovered role is better
UX and is a deliberate non-goal here.

---

## D7 — Making 1042 strings reviewable

**Artefact**: `docs/app_description/02-domain/framework-authoring/it/bilingual/{ROLE}.md`
— **generated, never hand-maintained**, by `scripts/framework-bilingual-review.js`
(bun, like every other catalogue reader), committed, with a CI check that regenerating
produces no diff. Same doctrine as `framework-crossrole-baseline.txt`.

Per indicator, one table: EN | IT for `indicator` and the three anchors, plus per row
`wc_en`, `wc_it`, `r`, and a **hedge-marker count delta** (EN markers vs IT markers, from
the inventories in the two authoring standards).

The reviewer's job is **fidelity to the English**, not Italian quality in isolation, so
the artefact must be side-by-side or it cannot be done. The `Δhedge` column is the cheap
proxy for "did the translator silently improve the source" — Constraint 1's most likely
violation, and 76% of legacy level-3 anchors (ICO 89%) are hedge-only, so an Italian that
de-hedges will show a negative delta immediately.

**Budget**: a role slice is JSON diff (~180-540 lines) + generated table (~400 lines) ≈
600-950 lines, over the 400-line budget. Therefore FLL/MLL/SRX (18 pairs) split into two
child PRs of 9 pairs on a role-scoped integration branch; only the merge of the last child
into `develop` removes that role's `framework-locale-gaps.txt` entries, so the
half-translated state never reaches `develop` and the whole-role guard never has to lie.

---

## D8 — Testing strategy (strict TDD)

**Runner**: `./vendor/bin/pest <exact-file-path>`. **Never `php artisan test --filter`** —
it has been observed fabricating passes in this repo. Pre-merge: full serial
`./vendor/bin/pest`, not `--parallel`, for the seeder suite: it shares the `catalog_meta`
singleton and `framework_gaps` unique keys, and parallel workers over a global singleton
is a flake generator.

| Layer | What it proves | Where |
|---|---|---|
| Unit | Normalizer returns locale maps; **rejects** a bare string; rejects an unknown locale key | `tests/Unit/Services/CompetencyNormalizerTest.php` |
| Feature (seeder) | `hasTranslation('anchor_5','it')` true from an IT fixture; `en` unchanged; no-op re-seed does not bump; a new locale **does** bump | `tests/Feature/Seeders/ItLocaleSeedTest.php` |
| Feature (lock) | Under lock: empty `it` slot filled; non-empty `it` never overwritten; `en` never touched; `locked_fill_empty_locale` gap emitted | `tests/Feature/C4/Seeder/LockedFillEmptyLocaleTest.php` |
| Feature (gaps) | Per-pair `missing_translation` resolves; global row resolves only at 83/83; orphan sweep | `tests/Feature/Seeders/LocaleGapResolutionTest.php` |
| Feature (API) | `translation_gap=false` for every indicator of a translated role | `tests/Feature/Api/ItTranslationGapTest.php` |
| Feature (interview) | Translated pair composes with **no 422**; untranslated pair **still 422s** | `tests/Feature/Api/ItInterviewCompositionTest.php` |
| Command | `forget-locale` removes `it`, leaves `en`, refuses under lock | `tests/Feature/Console/ForgetLocaleCommandTest.php` |
| CI self-test (step f) | Every guard in D2 rejects an IT-specific bad fixture **and** fails closed on the pre-migration shape | `.github/workflows/wrapper-ci.yml` |

**What no test proves — stated so nobody mistakes green for done**: translation fidelity,
register, and whether the Italian says what the English says. Those are review, performed
against D7's artefact by a native speaker with assessment-domain competence, recorded in
the PR. The only mechanical fidelity signals in existence here are guard 6a
(cross-locale duplicate divergence, blocking) and the `Δhedge` column (advisory). Neither
is a fidelity test, and neither will be described as one.

---

## RED-first order of work

| # | RED (fails first) | GREEN |
|---|---|---|
| 1 | Normalizer returns a locale map / rejects a bare string | DTO + normalizer |
| 2 | Seeder writes `it` from an IT fixture | seeder locale loop |
| 3 | Locked FV: fill empty `it`; never overwrite; never touch `en`; gap emitted | lock branch |
| 4 | New locale bumps `revision`; true no-op does not | `wasChanged()` predicate |
| 5 | Each guard rejects an IT-bad fixture; each fails closed on the old shape | guard rewrites (D2) |
| 6 | Locale-gaps both directions + whole-role rule + grouping | new guard + control file (83 entries) |
| 7 | Per-pair + global `missing_translation` resolution | seeder gap logic (D5) |
| 8 | `translation_gap=false`; 422 gone on translated pair; 422 survives on untranslated | content slices |
| 9 | `forget-locale` behaviour incl. lock refusal | artisan command |

**PR chain**: (0) IT authoring standard + hedge inventory — docs only. (1) shape
migration, EN only, both trees, all guards + self-tests + control file + generator —
`size:exception`, justified as mechanical and script-reproducible (re-run ⇒ no diff).
(2) pilot: PRS × 4 roles + the 36-row measurement table + both IT ceiling constants.
(3…N) role slices — **ICO first** (45 indicators, 2 child PRs), then BUL, FLL, MLL, SRX.
(final) global gap resolves, control file empty, domain doc updated.

`400-line budget risk: High` · `Chained PRs recommended: Yes` ·
`Decision needed before apply: Yes`

---

## D9 — Production rollout and verification

A row count cannot detect a partially-applied locale. The verification must count
**locale keys**, not rows.

```sh
railway ssh
# 1. Re-confirm the blocker, and record it
php artisan tinker --execute="echo App\Models\FrameworkVersion::withoutGlobalScopes()->where('is_locked',true)->count();"   # expect 0

# 2. Pre-state (Postgres jsonb key-existence — the only honest count)
#    select count(*) from framework_bars_indicators
#     where text ? 'it' and anchor_5 ? 'it' and anchor_3 ? 'it' and anchor_1 ? 'it';

# 3. Seed (vendored api/database/framework is what production reads — the wrapper
#    submodule pointer must already carry the IT content)
php artisan db:seed --force --class="Database\\Seeders\\FrameworkCatalogSeeder"

# 4. Post-state: the count above must equal the in-scope indicator count EXACTLY
#    (249 at completion), computed from the source tree, not eyeballed.
#    select revision from catalog_meta;                                  -- must have moved
#    select role_code, competency_code, status from framework_gaps
#     where kind='missing_translation';                                  -- zero pending_authoring
```

5. **Functional proof** — a count cannot show this: point an `it` project at each in-scope
   role and call the composition endpoint once per competency. `200`, not
   `422 anchor_translation_missing`.
6. **Rollback**: `php artisan framework:forget-locale it --force`, then re-seed. Never a
   bare re-seed — that leaves `it` in place (D5).

The seeder is fully transactional, so a partial *apply* is impossible. A partially
*complete source* applies cleanly and looks green — which is exactly why step 4 asserts an
exact expected number rather than "greater than zero".

---

## Open Questions

- [ ] Native Italian speaker with assessment-domain competence — named, and available per
      slice. This is the people dependency that decides whether the change is finished
      (no code gate enforces sign-off; Constraint 4 inherits that shape).
- [ ] Confirm the widened `bump()` predicate (D4) ships in this change or is split out.
- [ ] Confirm the role order after ICO (ICO is the smallest complete slice; it is not
      necessarily the most commercially urgent).
