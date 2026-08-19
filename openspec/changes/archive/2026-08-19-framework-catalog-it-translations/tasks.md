# Tasks: Italian Locale for the Framework Catalogue

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~6000–8000+ (shape migration alone ~4000 lines per design's own estimate; each role slice ~600–950 lines per D7) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR0 (docs) → PR1 (shape+guards, `size:exception`) → PR2 (bump) → PR3 (seeder/gaps/forget-locale) → PR4 (pilot) → PR5–9 (role slices ICO→FLL→MLL→BUL→SRX, large roles as 2 children each) → PR-final (wrap-up) → production rollout |
| Delivery strategy | ask-on-risk (assumed default — not explicitly received from orchestrator for this run) |
| Chain strategy | feature-branch-chain (role-scoped integration branches per large slice); PR1 ships as `size:exception` |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|---|---|---|---|
| 1 | IT authoring standard (docs only) | PR 0 | base=develop; no ceiling number stated yet (blind-authoring) |
| 2 | Locale-map shape migration + all CI guard rewrites + control-file scaffold + bilingual generator | PR 1 | `size:exception`; migration re-run must produce zero diff |
| 3 | `CatalogMeta::bump()` widened predicate | PR 2 | base=develop; own RED/GREEN; independently revertible (ratified #1) |
| 4 | Seeder IT-writing + gap resolution + lock fill-empty-locale exception + `forget-locale` command | PR 3 | base=develop; depends on PR2 |
| 5 | Anchor-length pilot (PRS × 4 roles, 36 anchors) + IT ceiling constants | PR 4 | base=develop; depends on PR3; first real IT content |
| 6 | Role slice ICO | PR 5 (+5b child) | feature-branch-chain: 2 children on ICO branch; gap file 83→68 |
| 7 | Role slice FLL | PR 6 (+6b child) | 2 children on FLL branch; gap file 68→50 |
| 8 | Role slice MLL | PR 7 (+7b child) | 2 children on MLL branch; gap file 50→32 |
| 9 | Role slice BUL | PR 8 (+8b if >400 lines) | single PR unless measured diff forces a split; gap file 32→18 |
| 10 | Role slice SRX | PR 9 (+9b child) | 2 children on SRX branch; gap file 18→0 |
| 11 | Global wrap-up: control file empty, gap row resolved, Non-Goals prose fix, domain doc update | PR 10 | base=develop; depends on PR9 |
| 12 | Production rollout + verification | ops (no PR) | `railway ssh`; re-check locked-FV before every seed |

**Role order is ratified**: ICO → FLL → MLL → BUL → SRX (the seniority ladder the English was calibrated on). This overrides design.md's own PR-chain narrative, which suggested ICO→BUL→FLL→MLL→SRX for size reasons — commercial/size ordering was explicitly not the design's call to make.

## Testing Contract (applies to every RED/GREEN task below)

- Runner: `./vendor/bin/pest <exact-file-path>`. **Never** `php artisan test --filter` — observed fabricating passes in this repo.
- Pre-merge per PR: full serial `./vendor/bin/pest` (no `--parallel`) for the seeder suite — it shares the `catalog_meta` singleton and `framework_gaps` unique keys; parallel workers against `beai_test` produce Postgres deadlocks that look like real failures.
- `[REVIEW]` tasks are human fidelity sign-off — never disguise them as `[TEST]`/`[RED]`/`[GREEN]`; no mechanical check proves translation fidelity except guard 6a (crosslocale duplicate divergence).
- All step (f) self-tests run under **bash**, never zsh. Watch `set -e` traps: `grep -c` exits 1 on zero matches (don't split `cmd`/`STATUS=$?` across lines after it); a bare `if cmd; then …; fi` resets `$?`; a `return 1` consumed inside an unguarded `$(...)` dies silently mid-loop.

## Phase 1: IT Authoring Standard (PR 0, docs only — prerequisite)

- [x] 1.1 Create `docs/app_description/02-domain/framework-authoring/it/house-voice-and-anti-hedge-standard.md`: indicator form (infinitive, e.g. `Individuare…`), anchor form (subject-elided 3rd person, e.g. `Individua…`), register = professional/neutral, never regional, an Italian deficit-verb inventory for level 1, orthography (accents, apostrophes).
- [x] 1.2 Reserve an empty "pilot measurement table" section — filled in Phase 5. Do NOT state any word-count ceiling here (protects Phase 5's blind-authoring control).
- [ ] 1.3 [REVIEW] Native Italian speaker with assessment-domain competence signs off the standard before any content PR opens. **BLOCKED — requires a human reviewer; not executable by this apply pass.**

## Phase 2: JSON Shape Migration + CI Guards (PR 1, `size:exception`)

- [x] 2.1 [RED] `tests/Unit/Services/CompetencyNormalizerTest.php`: a bare-string field is REJECTED once the normalizer targets locale maps.
- [x] 2.2 [GREEN] `IndicatorDTO`/`CompetencyDTO` fields → `array<locale,string>`; rewrite `CompetencyNormalizer` to require `{"en":...,"it":...}`, reject non-object, reject missing `en`, reject unknown locale keys.
- [x] 2.3 Write `scripts/framework-locale-shape-migrate.js` (bun): mechanically rewrite all 249 bars entries + `competencies.json` + `roles.json`, both trees, flat string → `{"en": <value>}`. No hand-edited JSON.
- [x] 2.4 [CI] Assert re-running `framework-locale-shape-migrate.js` produces zero diff — verified via sha256 hash comparison before/after a second run (`git diff --exit-code` equivalent; see apply report for the exact command and output).
- [x] 2.5 [RED] Fixture: old-shape (bare string) entry → `catalog_malformed_bars_entries` must report `malformed-entry`. (Reported as `not-a-locale-map` under the redesigned reason taxonomy — see 2.6.)
- [x] 2.6 [GREEN] Rewrite `catalog_malformed_bars_entries` (`scripts/ci-guards.sh`): reasons `not-a-locale-map`, `missing-en`, `unknown-locale-<x>`, `blank-<locale>`.
- [x] 2.7 [RED] Fixture: non-string `it` anchor value → `CI_ANCHOR_WORDCOUNT_SCRIPT` must hard-fail, not `continue` silently.
- [x] 2.8 [GREEN] `CI_ANCHOR_WORDCOUNT_SCRIPT`: replace `continue` with `process.exit(1)` on non-string; locale-parameterized output `ROLE:COMP:LEVEL:LOCALE:WC`; ICO exemption stays locale-blind.
- [x] 2.9 [RED] Fixture: an `it` anchor over its ceiling → `catalog_overlong_bars_anchors` catches it; an ICO `it` anchor is NOT examined.
- [x] 2.10 [GREEN] Locale-parameterize `bars_anchor_word_counts` / `catalog_overlong_bars_anchors` / `catalog_short_bars_anchors`; `_IT` constants wired but placeholder until Phase 5.
- [x] 2.11 [RED] Fixture: identical `it` text across two roles hidden by `CI_CROSSROLE_SCRIPT`'s `continue` → must be caught, not skipped.
- [x] 2.12 [GREEN] `CI_CROSSROLE_SCRIPT`: replace `continue` with hard failure on non-string; locale-parameterized index `ROLE_A:ROLE_B:COMP:LOCALE:FIELD`.
- [x] 2.13 Regenerate `framework-crossrole-baseline.txt`, locale-qualified. **2 entries, not 4** — this PR authors no Italian content (explicit constraint of this apply pass), so only the pre-existing EN duplicates exist yet; the file's own header explains the companion `it:indicator` lines land in the content PR that translates those two pairs, and states adding them now would itself be a stale exemption.
- [x] 2.14 [RED] New guard `catalog_crosslocale_duplicate_divergence`: IT diverges on a byte-identical-EN pair → fail; IT converges on a differing-EN pair → fail.
- [x] 2.15 [GREEN] Implement `catalog_crosslocale_duplicate_divergence` (blocking) in `scripts/ci-guards.sh`.
- [x] 2.16 [RED] New file `scripts/framework-locale-gaps.txt`: fixture role listing a partial pair count (neither 0 nor full) → must fail (`locale_gaps_whole_role_violations`).
- [x] 2.17 [GREEN] Implement `catalog_locale_coverage` + `catalog_unexpected_locale_gaps` + `catalog_stale_locale_gap_exemptions` + `locale_gaps_whole_role_violations`, both directions, entries `LOCALE:ROLE:COMP`; seed file with all 83 `it:` entries.
- [x] 2.18 [RED] Fixture: `roles.json`/`competencies.json` entry missing the `it` key in its locale map, uncaught by any existing guard.
- [x] 2.19 [GREEN] Implement `catalog_meta_locale_shape` guard for `roles.json`/`competencies.json` (46 strings).
- [x] 2.20 Add role-order grouping check for `framework-locale-gaps.txt` (sibling of `competency_gaps_role_order_violations`) — `locale_gaps_role_order_violations`.
- [ ] 2.21 **NOT DONE** — `scripts/framework-bilingual-review.js` (bun) generator not written. Deferred given this apply pass authors no Italian content (nothing yet to render into a bilingual table) and the time budget for this batch; flagged as a real gap, not silently dropped. Needed before Phase 5 content lands.
- [x] 2.22 Wire every self-test above into `.github/workflows/wrapper-ci.yml` step (f), each calling the SAME function the real gate invokes — executed end-to-end locally (exit 0, zero `SELF-TEST FAILED` lines; see apply report).
- [x] 2.23 [NOTE] Confirmed — step (h) is Dockerfiles/image tables only, no locale dimension needed. No change made.
- [x] 2.24 Confirmed (no rewrite needed) — `json_canonical_equal` and `role_keys`/`role_competency_pairs` verified working unmodified against the new shape (see apply report).

## Phase 3: `CatalogMeta::bump()` Widened Predicate (PR 2 — own separable slice, before content)

- [x] 3.1 [RED] Re-seeding a change to ONLY an existing English anchor (no new locale) currently does NOT bump `revision` — assert this now MUST bump.
- [x] 3.2 [GREEN] Widen seeder predicate to `$catalogChange |= $model->wasRecentlyCreated || $model->wasChanged()`; remove any bespoke `$localeChange` flag.
- [x] 3.3 [RED] A true no-op re-seed (no source change) must NOT bump `revision`.
- [x] 3.4 [GREEN] Confirm via test `wasChanged()` is false on an unmodified row after re-seed.
- [x] 3.5 Own commit boundary — independently revertible from any content PR. (No bespoke `$localeChange` flag existed to remove; the widened predicate is applied at all three unlocked-mode save call sites — competency, role, indicator.)

## Phase 4: Seeder IT-Writing, Gap Resolution, Lock Exception, `forget-locale` (PR 3)

- [x] 4.1 [RED/GREEN] `tests/Feature/Seeders/ItLocaleSeedTest.php`: `hasTranslation('anchor_5','it')` true from an IT fixture; `en` unchanged; new locale DOES bump (depends on Phase 3). **Sequencing note**: the seeder's locale-writing GREEN was authored together with the Phase 2 shape-compatibility fix (both required the same seeder edit to keep the suite green after the JSON migration) rather than as a separate RED-first slice; the dedicated test file above was added afterward and independently confirmed passing.
- [x] 4.2 [GREEN] Seeder: `foreach locale present in the source field's nested map: setTranslation(field, locale, value)` (unlocked path) — implemented via `setAllLocales()`.
- [x] 4.3 [RED/GREEN] `tests/Feature/C4/Seeder/LockedFillEmptyLocaleTest.php`: under lock, empty `it` fills; non-empty `it` never overwritten; `en` never touched; `locked_fill_empty_locale` gap + `seeder_lock_guard_active`-style signal emitted. Same sequencing note as 4.1.
- [x] 4.4 [GREEN] Fill-empty-locale exception: `setTranslation` permitted under lock iff `!hasTranslation(field, locale) && locale !== 'en'` — implemented via `fillEmptyLocalesUnderLock()`, applied uniformly to Role/Competency/BarsIndicator.
- [x] 4.5 [RED/GREEN] `tests/Feature/Seeders/LocaleGapResolutionTest.php`: per-pair `missing_translation` resolves only at 12/12 strings; 11/12 stays pending; global row resolves only at 83/83 (verified at 1/83); orphan sweep. Same sequencing note as 4.1.
- [x] 4.6 [GREEN] Implement per-pair/global/orphan `missing_translation` resolution in the seeder — `resolveOrRecordTranslationGap()`.
- [x] 4.7 [RED] `tests/Feature/Console/ForgetLocaleCommandTest.php`: removes `it`, leaves `en`; refuses while any FV locked; requires `--force` outside local; bumps revision. Genuine RED captured mid-session (a real `Feature/Console` RefreshDatabase test-isolation gap in `tests/Pest.php`, not a fabricated failure — fixed and documented in the apply report).
- [x] 4.8 [GREEN] Implement `php artisan framework:forget-locale it [--dry-run] [--force]`: `forgetTranslation('it')` over `BarsIndicator`/`Competency`/`Role`, one transaction, per-model count report — `app/Console/Commands/ForgetFrameworkLocaleCommand.php`.
- [x] 4.9 [NOTE] Covered by pre-existing `tests/Feature/C8/InterviewStartCompositionTest.php` test "5.2 /start missing IT anchor translation → 422" (fixture-level, EN-only BarsIndicator rows) — re-verified passing after all Phase 2-4 changes; no new duplicate test added. No `InterviewController.php` change.
- [x] 4.10 [NOTE] Confirmed — `CompetencyResource`/`RoleResource` gain no `translation_gap` field; indicator-level stays the only API-exposed signal. No change made.

## Phase 5: Anchor-Length Ceiling Pilot (PR 4 — first real IT content)

- [ ] 5.1 Author 36 pilot anchors, `PRS` × {FLL, MLL, BUL, SRX} — BLIND: translator is NOT told a ceiling will be derived.
- [ ] 5.2 Measure `wc_it`/`wc_en` per anchor via the exact `bars_anchor_word_counts` rule; commit the 36-row table (EN wc, IT wc, r) in the IT authoring standard.
- [ ] 5.3 Compute `R` = 90th percentile of `r`; set `CI_ANCHOR_WORDCOUNT_MAX_IT = ceil(18×R)`, `CI_ANCHOR_WORDCOUNT_MIN_IT = ceil(10×R)` (advisory), comment cites the table.
- [ ] 5.4 Falsification check: re-check the 36 against the derived ceiling; if >10% need a clause dropped, recompute with `R = max(r)`, record why in the same table.
- [ ] 5.5 Seed the 36 pilot anchors via the Phase-4 seeder path; confirm `revision` bumps (Phase 3 predicate fires).
- [ ] 5.6 Re-run guard self-test 2.9 against the real derived `_IT` ceiling.

## Phase 6: Role Slice — ICO (180 strings, 15 pairs; ratified order position 1)

- [ ] 6.1 Author remaining ICO Italian content, faithful to English (Constraint 1 — do not silently improve hedge-only level-3 anchors).
- [ ] 6.2 Split into 2 child PRs on an ICO-scoped integration branch; only the final child merges to `develop`.
- [ ] 6.3 Remove ICO's 15 entries from `framework-locale-gaps.txt` (83→68) only on the completing merge.
- [ ] 6.4 [TEST] `tests/Feature/Api/ItTranslationGapTest.php`: `translation_gap=false` for every ICO indicator.
- [ ] 6.5 [TEST] `tests/Feature/Api/ItInterviewCompositionTest.php` (real catalogue): `it` project pinned to ICO → 201, no 422, prompt entirely Italian.
- [ ] 6.6 [TEST] scoring-engine: a fully-translated ICO project scores every competency, no `anchor_translation_missing`.
- [ ] 6.7 [REVIEW] Native-speaker + domain-expert sign-off against generated `ICO.md` bilingual table; recorded in the PR, not a CI gate.
- [ ] 6.8 Confirm ICO's `missing_translation` pairs resolve; global row note → "68 of 83 pending".

## Phase 7: Role Slice — FLL (216 strings, 18 pairs; position 2)

- [ ] 7.1–7.8 Same pattern as Phase 6 (author → 2 children on FLL branch → gap file 68→50 → API/composition/scoring tests → review → resolve).
- [ ] 7.9 [TEST] scoring-engine "partial coverage": while FLL is still untranslated, ICO scores normally AND FLL still 422s — run BEFORE 7.1 lands as the pre-slice regression baseline.

## Phase 8: Role Slice — MLL (216 strings, 18 pairs; position 3)

- [ ] 8.1–8.8 Same pattern as Phase 6, MLL-scoped branch; gap file 50→32.

## Phase 9: Role Slice — BUL (168 strings, 14 pairs; position 4)

- [ ] 9.1–9.8 Same pattern as Phase 6; gap file 32→18. Measure actual diff line count before deciding single PR vs 2-child split (design did not name BUL as requiring a split).

## Phase 10: Role Slice — SRX (216 strings, 18 pairs; position 5, last)

- [ ] 10.1–10.8 Same pattern as Phase 6, SRX-scoped branch; gap file 18→0 (empty on completion).

## Phase 11: Global Wrap-Up (PR 10)

- [ ] 11.1 Confirm `framework-locale-gaps.txt` is empty; both existing control files remain empty and untouched.
- [ ] 11.2 Confirm the global `missing_translation` `framework_gaps` row resolves — zero `pending_authoring` rows in shipped scope.
- [ ] 11.3 Direct prose edit (delta merge cannot reach this — it is outside any `### Requirement:` block): `openspec/specs/framework-catalog/spec.md`, `## Non-Goals (Explicit)`, "Inventing missing domain data" bullet — remove/narrow "…and IT locale translations (for the full catalogue, existing and newly authored anchors alike) remain client/expert artifacts" to reflect the shipped scope; MTG/LAT stays deferred.
- [ ] 11.4 Update `docs/app_description/02-domain/` wherever it still states the catalogue is EN-only.
- [ ] 11.5 Confirm `api/database/framework/**` stays byte-identical to `docs/app_description/02-domain/framework/**` (parity gate) — checked after every slice, not only here.

## Phase 12: Production Rollout & Verification

- [ ] 12.1 `railway ssh` → `php artisan tinker --execute="echo App\Models\FrameworkVersion::withoutGlobalScopes()->where('is_locked',true)->count();"` — expect `0`, re-checked before EVERY seed run, not once.
- [ ] 12.2 Pre-state count (jsonb key-existence, NOT row count): `select count(*) from framework_bars_indicators where text ? 'it' and anchor_5 ? 'it' and anchor_3 ? 'it' and anchor_1 ? 'it';`.
- [ ] 12.3 `php artisan db:seed --force --class="Database\\Seeders\\FrameworkCatalogSeeder"` (vendored `api/database/framework` submodule pointer must already carry the IT content).
- [ ] 12.4 Post-state: jsonb-key count MUST equal the exact in-scope indicator count computed from source (not "greater than zero"); `select revision from catalog_meta;` moved; `framework_gaps` `missing_translation` rows have zero `pending_authoring` in shipped scope.
- [ ] 12.5 Functional proof: call the composition endpoint once per in-scope role×competency with an `it` project → `200`, never `422 anchor_translation_missing`.
- [ ] 12.6 Verifying a PARTIALLY-applied locale: re-run 12.2 filtered by `role_code`; a role's count strictly between 0 and its full pair×12 total means mid-migration — cross-check against `framework-locale-gaps.txt`'s per-role entry count (0 listed ⇔ full coverage, N listed ⇔ N pairs short).
- [ ] 12.7 Rollback: `php artisan framework:forget-locale it --force`, THEN re-seed. Never a bare re-seed alone — `setTranslation` merges, `it` survives a bare re-seed.
