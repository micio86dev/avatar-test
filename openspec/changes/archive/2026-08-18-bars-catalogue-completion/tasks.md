# Tasks: BARS Catalogue Completion — 44 Missing Role×Competency Pairs

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~4,000–5,000 total (132 indicators × 4 fields × 2 trees + tests + CI); ~200–260/slice per design §8 |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 0 (code) → PR 1 (SRX prereq) → PR 2 (standards/guards) → PR 3–15 (per-competency content, chained) → PR 16 (SRX materialisation, size:exception) → PR 17 (close-out) |
| Delivery strategy | ask-on-risk (default; orchestrator did not supply one) |
| Chain strategy | stacked-to-main, each slice a legal CI-green intermediate state per design §Approach; PR 16 alone carries a documented `size:exception` |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: stacked-to-main
400-line budget risk: High

### Suggested Work Units
| Unit | Goal | PR | Notes |
|---|---|---|---|
| 0 | Seeder fixes (5a+5b), RED-first | PR 0 | No content change; base for the chain |
| 1 | SRX `responsibilities`, both trees + doc line 20 | PR 1 | Gates all SRX pairs |
| 2 | House-voice doc, scope-shift template, `ci-guards.sh` checks + self-tests, crossrole baseline | PR 2 | Judgment + mechanical artefacts before authoring |
| 3–15 | Per-competency content (JDG/TMG first, then PRS/DRV/COL/NET/SLF/COM/ITG/INC, then SRX-only staging) | PR 3–15 | Each: JSON both trees + gap-file lines deleted + count bump; ≤260 lines |
| 16 | SRX materialisation, staging → trees | PR 16 | `size:exception`, byte-verified vs staging |
| 17 | Close-out: gap files, domain doc, promoted spec Non-Goals edit, final assertions | PR 17 | |

---

## Phase 0: Seeder Code Fixes (TDD, no content change) — `api/database/seeders/FrameworkCatalogSeeder.php`

- [x] 0.1 RED: `tests/Feature/Seeders/GapResolutionTest.php` (new) — 4 resolution points fail today (rows stay `pending_authoring`).
- [x] 0.2 GREEN: add `status='resolved'` resolution for `missing_role_meta`, `role_no_bars`, `competency_no_bars` (covered + orphaned), computed from JSON not DB. Run: `./vendor/bin/pest tests/Feature/Seeders/GapResolutionTest.php`.
- [x] 0.3 RED: `tests/Feature/Seeders/LockedRoleMetaFillTest.php` (new) — locked FV + empty `responsibilities` not filled today.
- [x] 0.4 GREEN: fill-empty-only exception at `FrameworkCatalogSeeder.php:159` — under lock, empty stored EN value + non-empty JSON value → write + emit `locked_fill_empty_role_meta` gap + `Log::warning`; non-empty stored value never touched. Run: `./vendor/bin/pest tests/Feature/Seeders/LockedRoleMetaFillTest.php`.
- [x] 0.5 Update `tests/Feature/Seeders/ReseedAfterGapFixTest.php` — tighten the now-false "gap may still exist" assertion to resolution.
- [x] 0.6 Add `tests/Feature/Seeders/SeededCompletenessTest.php` (new) — every `(role, competency)` in JSON has exactly 3 indicator rows.
- [x] 0.7 Full seeder tier green: `./vendor/bin/pest tests/Feature/Seeders/` and `tests/Feature/C4/Seeder/SeederLockGuardTest.php` (never `php artisan test --filter`).

## Phase 1: SRX Responsibilities Prerequisite (deliverable 1)

- [x] 1.1 Author SRX `responsibilities` (design §3 exact sentence) in `docs/app_description/02-domain/framework/roles.json` and vendor into `api/database/framework/roles.json` (byte-identical).
- [x] 1.2 Update `docs/app_description/02-domain/01-roles-and-competencies.md` line 20 (SRX row: replace "responsabilità da definire in configurazione").
- [x] 1.3 Run `./vendor/bin/pest tests/Feature/Seeders/GapResolutionTest.php` unlocked — `missing_role_meta`(SRX) resolves. Run `LockedRoleMetaFillTest.php` — locked path fills + signals.

## Phase 2: Authoring Standards & CI Guards (judgment + mechanical, before any new anchor)

- [x] 2.1 Write house-voice + anti-hedge standard doc under `docs/app_description/02-domain/framework-authoring/` (sibling of `framework/`, never inside it) — design §1–§2 verbatim rules.
- [x] 2.2 Create scope-shift table template at `docs/app_description/02-domain/framework-authoring/scope-shift/`.
- [x] 2.3 RED: `ci-guards.sh` self-test rows (in `wrapper-ci.yml` step (f)) for `catalog_malformed_bars_entries` (exactly 3 entries, non-empty `indicator`, `scale` keys `5,3,1`, no whitespace) and `catalog_crossrole_duplicates` (no identical string across roles per competency) — fail against a known-bad fixture first.
- [x] 2.4 GREEN: implement both functions in `scripts/ci-guards.sh`, wired into `wrapper-ci.yml` step (d). Verify: `shellcheck -s sh scripts/ci-guards.sh && dash -n scripts/ci-guards.sh`.
- [x] 2.5 Generate `scripts/framework-crossrole-baseline.txt` by running the checker against TODAY's catalogue (before any new pairs land) — commit verbatim, never hand-typed. Must contain `MLL.json:142`/`BUL.json:142` (INF) and `FLL.json:176`/`MLL.json:176` (RES). Both-direction enforcement identical to the two existing control files; new pairs add zero entries.
- [x] 2.6 Author `scripts/bars-review-table.mjs` (generated per-PR review table, pasted into PR body — never committed).

## Phase 3: JDG & TMG — no catalogue precedent, authored first (design §4)

- [x] 3.1 Write scope-shift tables for JDG and TMG (`.../scope-shift/JDG.md`, `TMG.md`) — reject if any two role rows are identical before writing prose.
- [x] 3.2 Author {FLL,MLL,BUL}×{JDG,TMG} anchors into `bars/{FLL,MLL,BUL}.json` (both trees); SRX×{JDG,TMG} into `openspec/changes/bars-catalogue-completion/staging/SRX.partial.json`.
- [x] 3.3 Run `catalog_malformed_bars_entries`, `catalog_crossrole_duplicates` locally; delete `FLL:JDG FLL:TMG MLL:JDG MLL:TMG BUL:JDG BUL:TMG` from `scripts/framework-competency-gaps.txt` in the same commit; vendor trees; bump `SeededCountCorrectnessTest.php` counts.
- [x] 3.4 Flag these 8 pairs / 24 indicators for priority specialist review (design §Calibrated Draft requirement) — record marker distinct from standard sign-off.

  **PRIORITY SPECIALIST REVIEW FLAG** — these 8 pairs / 24 indicators / 72
  anchor texts (FLL:JDG, FLL:TMG, MLL:JDG, MLL:TMG, BUL:JDG, BUL:TMG,
  SRX:JDG-staging, SRX:TMG-staging) carry no prior worked example anywhere in
  the catalogue and set the calibration precedent every later competency in
  Phases 4-5 is checked against. Distinct from standard house-voice/CI
  sign-off: a specialist should re-read these against
  `framework-authoring/scope-shift/JDG.md` and `TMG.md` before Phase 4 begins,
  because a ladder error here propagates to every subsequent sweep rather than
  being caught by precedent. Measured hedge rate on the 24 new level-3
  anchors: 0/24 (0%), well under the 30% ceiling — see apply-progress for the
  per-anchor differentiation check.

## Phase 4: Remaining Leader Competencies (PRS, DRV, COL, NET, SLF, COM, ITG, INC)

- [x] 4.1 Per competency, vertically across all assigned roles in one sitting: scope-shift table first (reject on identical rows), then anchors into `bars/{FLL,MLL,BUL}.json` (as assigned) + SRX column into `staging/SRX.partial.json`.
- [x] 4.2 Each competency's commit: gap-file lines deleted from `scripts/framework-competency-gaps.txt`, both trees vendored, `SeededCountCorrectnessTest.php` counts bumped, `catalog_crossrole_duplicates` clean against the baseline.

  **PHASE 4 COMPLETION NOTE** — authored per-competency (not per-role) with
  all four texts (FLL/MLL/BUL/SRX) side by side per the method requirement:
  PRS, DRV, COL, NET (FLL+MLL+BUL+SRX-staged, all 4 roles) and SLF, COM,
  ITG, INC (FLL+MLL+SRX-staged only — BUL does not carry these 4 per
  `roles.json`). 20 role×competency pairs landed in-tree (FLL 8 + MLL 8 +
  BUL 4), completing FLL (18/18) and MLL (18/18) and BUL (14/14) at the
  pair level — `scripts/framework-competency-gaps.txt` is now EMPTY (its
  documentation kept, not deleted, per its own "generated, not typed"
  doctrine). 8 more pairs landed in `staging/SRX.partial.json` only.
  Measured hedge rate on the 84 new level-3 anchors this phase: 0/84 (0%),
  matching Phase 3's 0% and well under the 30% ceiling — see apply-progress
  for the word-count QA pass that caught and fixed a real first-draft
  regression (anchors initially running 19-26 words against the JDG/TMG
  calibration reference's strict 10-18 word ceiling).

## Phase 5: SRX-Only Competencies (STG, INN, CSF, OPX, INS, INF, RES, LRN) — staging only

- [x] 5.1 Scope-shift tables + anchors into `staging/SRX.partial.json` only, batched ~3 competencies per PR. Generated review table (`bars-review-table.mjs`) reads the staging column.

  **PHASE 5 COMPLETION NOTE** — all 8 competencies authored in one sitting
  (not batched into ~3 per PR as originally suggested; the 400-line budget
  stayed well under 260 lines because staging-only content, with no vendored
  tree, gap-file, or count-bump changes, is roughly half the diff weight of
  an in-tree competency PR). Scope-shift tables written FIRST, in
  `docs/app_description/02-domain/framework-authoring/scope-shift/{STG,INN,
  CSF,OPX,INS,INF,RES,LRN}.md` — 5-row tables for STG/INN/CSF/OPX/INF/RES/LRN
  (every role carries these per `roles.json`), 4-row for INS (ICO does not
  carry it). **Correction to this phase's own premise**: the launching brief
  called these competencies "SRX-only... no sibling role to differentiate
  against." That is factually wrong in the literal sense — `roles.json` and
  `bars/{ICO,FLL,MLL,BUL}.json` show all eight already assigned and authored
  for every other role — but the underlying concern was right for a
  different reason, recorded explicitly in each table's header: that
  existing sibling content predates this change and is written in the
  pre-standard register (third-person `-s` verbs, terminal periods, hedge-only
  level differences), so it is not a house-voice model and was not used as
  calibration. Only the SRX row in each table is new; the other rows are
  included for the ladder's completeness per the scope-shift README's own
  rule, not as a style precedent. 24 indicators / 72 anchors added to
  `staging/SRX.partial.json` only — the file now holds all 18 SRX
  competencies (54 of 54 indicator rows), complete and ready for Phase 6
  materialisation. Measured word-count range on the 72 new anchors: 10-18
  (max exactly at the new CI ceiling, min at the new non-blocking floor) —
  see apply-progress for the full QA script output. Zero exact-string
  duplicates against ICO/FLL/MLL/BUL's existing content for the same eight
  competencies, checked directly (not just left to the CI guard, which does
  not see the staging file — see design.md §6, staging is invisible to
  every gate by design).

- [x] 5.2 (added, not in the original plan) Add a blocking CI guard for the
  house-voice standard's own anchor-length rule ("leader anchors run one
  sentence, 10-18 words"), because no guard checked it at all and Phase 4's
  apply-progress records a real first-draft regression that guard would
  have caught mechanically instead of by a throwaway hand-run script. Two
  new `scripts/ci-guards.sh` functions, sharing one raw-fact reader
  (`bars_anchor_word_counts`), same layering as every other check in that
  file:
  - `catalog_overlong_bars_anchors` — BLOCKING, >18 words, wired into
    `wrapper-ci.yml` step (d) exactly where `catalog_malformed_bars_entries`
    and `catalog_crossrole_duplicates` are wired. ICO is exempt — a
    documented, different two-sentence 20-30-word register — and the
    exemption is coded INSIDE the function (not as a role check in the
    workflow step), so its self-test in step (f) proves the exemption
    against the exact function the real gate calls.
  - `catalog_short_bars_anchors` — NON-BLOCKING report, <10 words, same
    doctrine as the hedge-rate report (legacy leader files carry anchors as
    short as 6-7 words and are out of this change's retro-review scope).
  - Both self-tested in step (f) against a genuinely-violating 19-word
    fixture (proves RED) and a genuinely-short 4-word fixture, plus an ICO
    fixture at 22 words proving the exemption is a real skip and not a
    coincidence of a clean fixture, plus fail-closed-on-missing-file rows
    for both functions, plus a full sweep of the committed catalogue.
  - **Bug found and fixed during self-verification, not in the original
    design**: the first implementation leaked the last per-line `[ ]` test's
    truth value as the WHILE loop's own exit status (POSIX: a `while`'s exit
    status is that of the last command run in its body) — so
    `catalog_overlong_bars_anchors` returned failure (1) on BUL's fully
    compliant file purely because BUL's last-checked anchor happened to be
    under 18 words, even though the function printed nothing. Fixed by
    switching every per-line branch to `[ test ] || continue` before the
    `printf`, matching the pattern every sibling function in the file
    already uses (`grep ... && continue`) — verified directly: step (d),
    extracted and run against the real trees, now exits 0.
  - `shellcheck -s sh scripts/ci-guards.sh` and `dash -n scripts/ci-guards.sh`
    both clean.

## Phase 6: SRX Materialisation (structural size exception)

- [x] 6.1 Byte-verify `staging/SRX.partial.json` is complete (18 competencies × 3 indicators = 54).
- [x] 6.2 Move staging content into `docs/.../framework/bars/SRX.json` and vendor to `api/database/framework/bars/SRX.json` in ONE commit; diff must be byte-equal to the reviewed staging file (the mechanical proof for the `size:exception`).
- [x] 6.3 Delete `SRX` from `scripts/framework-known-gaps.txt` in the SAME commit.
- [x] 6.4 Bump `SeededCountCorrectnessTest.php` SRX 0→54; run `./vendor/bin/pest tests/Feature/Seeders/` full.

  **PHASE 6 COMPLETION NOTE** — mechanical move, verified byte-equal, not
  reworded. `staging/SRX.partial.json` was verified first (18 competency
  keys, 54 indicators, every `scale` exactly `{5,3,1}` non-empty, key order
  identical to `roles.json`'s SRX `competencies` array) — zero malformed
  entries. Copied verbatim (no reformatting) to both
  `docs/app_description/02-domain/framework/bars/SRX.json` and
  `api/database/framework/bars/SRX.json`; SHA-256 of staging and both
  materialised copies is IDENTICAL
  (`dad9425e7a677941d0f31b71f5ac758421259fdf9630028178712fb7aeb61174`) — no
  trailing-newline or indentation normalisation was needed because the
  staging file already used the same 2-space/LF convention as every
  committed `bars/*.json`. `scripts/framework-known-gaps.txt`'s `SRX` data
  line was deleted in the same batch; its SRX-specific comment block (which
  asserted the gap in present tense) was rewritten to past tense rather than
  left stale — the file's own thesis ("an exemption that outlives the gap it
  excuses...") applies equally to a comment that outlives its fact.
  `scripts/framework-competency-gaps.txt` had zero active lines already
  (closed in Phases 3–4); its own closing paragraph, which said "...only SRX
  (role-level, the other control file) remains, until
  bars-catalogue-completion Phase 6" as a future event, was updated to past
  tense for the same reason. `wrapper-ci.yml` step (d) — extracted and run
  directly (not merely trusted) — passes exit 0 against the real trees:
  parity, role/pair completeness (both directions), shape, the max-18-word
  ceiling (now scanning `bars/SRX.json` for the first time, clean — the
  staged content already topped out at 18 words per design §7), and the
  cross-role duplicate check (SRX introduces zero new duplicates against the
  committed baseline) all green. Step (f) self-test — all 86 guard rows
  green, including the two rows that read the real committed catalogue and
  baseline. `shellcheck -s sh scripts/ci-guards.sh` and
  `dash -n scripts/ci-guards.sh` both clean (file unchanged by this phase;
  re-verified per the standing constraint anyway).
  `SeededCountCorrectnessTest.php`'s two SRX rows bumped 0→18 (covered
  competencies) and 0→54 (indicator rows);
  `cd api && ./vendor/bin/pest tests/Feature/Seeders/` full tier — see
  Phase 7's completion note for the one failure this surfaced and its fix.

## Phase 7: Close-Out

- [x] 7.1 Confirm `scripts/framework-known-gaps.txt` and `scripts/framework-competency-gaps.txt` are both empty (26 pair lines + SRX line, cumulatively deleted across Phases 3–6 — this is the indivisible fill-and-clear act).
- [x] 7.2 Update `docs/app_description/02-domain/01-roles-and-competencies.md` §Copertura BARS (lines 78–83) to state full coverage; matrix table stays factual.
- [x] 7.3 Update `openspec/specs/framework-catalog/spec.md` `## Non-Goals (Explicit)` bullet "Inventing missing domain data — SRX BARS..." — **direct prose edit**, not a delta Requirement block (deltas cannot touch this section); do after the change's delta is archived, or the archive pipeline leaves a promoted spec contradicting the just-landed change.
- [x] 7.4 Update `tests/Feature/Api/BarsAvailableFlagTest.php` and `PartialCatalogApiTest.php` to fixture-based scenarios (no real pair is `bars_available=false` post-completion); restate `role_no_bars` scenario in `scoring-engine` scope against a fixture.
- [x] 7.5 Final assertion suite: zero pending `competency_no_bars`/`role_no_bars`/`missing_role_meta` rows; per-role counts 45/54/54/42/54; `GET /api/framework/roles/{role}/competencies` → `bars_available=true` for all 83 pairs.

  **PHASE 7 COMPLETION NOTE** — both control files confirmed empty by the
  guards (step (d)/(f) above), not just by eye. **7.3 deviates from its own
  ordering note by explicit user instruction**: it says "do after the
  change's delta is archived, or the archive pipeline leaves a promoted spec
  contradicting the just-landed change" — this apply batch edited it BEFORE
  archive, on direct instruction. Mitigated the dangling-reference risk
  this creates: the promoted spec does not yet contain the delta's ADDED
  Requirement blocks (`SRX Role Responsibilities — Authored Prerequisite`,
  `Complete Role×Competency BARS Coverage`, `Calibrated Draft Pending
  Specialist Sign-Off` all still only exist in the change's delta spec), so
  the Non-Goals edit describes the fact in prose rather than cross-linking
  to Requirement headers that do not exist in this file yet — a real risk
  the archive step should double check once it runs. **7.4 found a FOURTH
  file with the predicted defect class** (after `PerRoleBarsGapTest`,
  `GapResolutionTest`'s docblock precedent, and the two named files):
  `GapResolutionTest.php`'s own `role_no_bars` test asserted
  `is_file("{$barsDir}/SRX.json")` is FALSE as a fixture precondition,
  reading the real tree via `buildGapResolutionFixtures()`'s glob-copy —
  broke the instant SRX.json existed in both trees. Fixed by manufacturing
  the absence in the fixture copy (`unlink` after building, mirroring the
  file's own `competency_no_bars` tests' pattern of stripping FLL:PRS from
  the fixture rather than relying on a real gap). `SeededCompletenessTest`,
  `GracefulMissingFileTest`, `ReseedAfterGapFixTest`, `PerRoleBarsGapTest`,
  and `FrameworkRolesListTest` were swept and found NOT to have the defect —
  the first three already build/omit their own fixture files rather than
  reading real absence, `PerRoleBarsGapTest`'s "all gap rows pending" check
  holds because the seeder's gap-resolution logic is UPDATE-only against
  already-pending rows (a role/pair that is complete on its very first seed
  never gets a gap row created at all — see
  `database/seeders/FrameworkCatalogSeeder.php:192-263`), and
  `FrameworkRolesListTest` only asserts role codes, not coverage.
  `BarsAvailableFlagTest.php` and `PartialCatalogApiTest.php` rewritten onto
  self-contained fixtures (role/pair stripped from a COPY of the real tree,
  never the real tree itself) — same pattern as
  `GapResolutionTest.php`/`GracefulMissingFileTest.php`; the shared
  `beforeEach` real-catalogue seed was removed from `BarsAvailableFlagTest`
  because it would have left leftover real SRX:STG indicator rows in the DB
  underneath the fixture re-seed (the seeder's delete-stale pass never
  touches a competency whose key is absent from the JSON entirely — it is
  never iterated, so its old rows survive), which would have made the
  fixture test pass for the wrong reason; each test now seeds explicitly.
  scoring-engine's `role_no_bars` scenario was already restated against a
  fixture in this change's own delta spec (`specs/scoring-engine/spec.md`,
  written in an earlier phase) and its implementing tests
  (`ScoreEvaluationJobDefensiveBranchesTest.php` and siblings) were already
  fixture-based (manufactured empty-indicator competencies, never real SRX)
  — swept and confirmed clean, no further test change needed there. 7.5
  verified directly against the real (non-test) dev database via
  `php artisan tinker` (no locked `FrameworkVersion` existed, so this was a
  plain unlocked re-seed): zero pending `role_no_bars`/`competency_no_bars`/
  `missing_role_meta` rows (only `missing_potential_competency`×2 and
  `missing_translation`×1 remain, both deferred by design); per-role
  `bars_indicators` counts 45/54/54/42/54 exactly; iterated all 83 declared
  `(role, competency)` pairs from `roles.json`'s own assignments and
  confirmed 0 have zero indicator rows (the DB-level fact `bars_available`
  is defined against). `cd api && composer test` (full suite, config-cache
  cleared) — 1772 tests, 1767 passed, 5 skipped (pre-existing, unrelated),
  0 failed.

## Verification Follow-Up: Two Warnings Closed (post-Phase-7, pre-Phase-8)

- [x] V.1 Stale-note sweep — `.github/workflows/wrapper-ci.yml` step (d)'s
  header comment claimed "it is EXPECTED to turn CI red until SRX.json is
  authored" (a note that outlived its fact: `bars/SRX.json` materialised in
  both trees in Phase 6). Swept `wrapper-ci.yml`, `scripts/ci-guards.sh`,
  `scripts/framework-known-gaps.txt`, `scripts/framework-competency-gaps.txt`
  and `scripts/framework-crossrole-baseline.txt` for the same defect class
  (present-tense/future-tense prose describing SRX as unauthored, staged, or
  "outside every gate"). Both `scripts/framework-*gaps.txt` control files and
  `scripts/framework-crossrole-baseline.txt` were already past-tense-correct
  (fixed in Phases 6-7). Six more stale spots found and fixed in
  `wrapper-ci.yml` (lines ~289, ~344-348, ~365, ~420-424, ~537, ~1206-1207)
  and two in `scripts/ci-guards.sh` (lines ~541-545, ~843-857) — all now
  state the SRX gap as historical (resolved in
  bars-catalogue-completion Phase 6), not current. Re-ran step (d) and step
  (f) locally after the edits (both exit 0); `shellcheck -s sh
  scripts/ci-guards.sh` and `dash -n scripts/ci-guards.sh` both clean.
- [x] V.2 Reopen-scenario coverage — added
  `tests/Feature/Seeders/GapResolutionTest.php`
  ("competency_no_bars gap preserves row identity through a reopen after
  resolution") verifying the seeder's own justification for
  `status='resolved'` over delete: seed with FLL:PRS stripped from BARS →
  row `pending_authoring`; re-author + reseed → SAME row (`id`,
  `created_at` unchanged) → `resolved`; strip again + reseed → SAME row
  reverts to `pending_authoring`, identity preserved, exactly one row for
  the pair throughout. Ran FIRST against the unmodified seeder — result was
  GREEN on the first run (5/5 tests, 20 assertions), because
  `FrameworkGap::updateOrCreate`'s match keys are `(kind, role_code,
  competency_code)` only, never `status`, so a reopen was already routed
  onto the same row by the existing Phase 0 implementation. **This is a
  CHARACTERISATION test, not a TDD RED-first test** — no production code
  change was needed or made. Full tier: `./vendor/bin/pest
  tests/Feature/Seeders/` → 28/28 passed, 161 assertions (was 27/27, 132
  assertions before this test was added).

## Phase 8: Production Deployment (`railway ssh`, api service)

- [ ] 8.1 Before deploy, record lock state: `php artisan tinker --execute="echo App\Models\FrameworkVersion::withoutGlobalScopes()->where('is_locked',true)->count();"`.
- [ ] 8.2 Deploy (catalogue ships in image at `database/framework`).
- [ ] 8.3 `php artisan db:seed --class="Database\Seeders\FrameworkCatalogSeeder" --force`.
- [ ] 8.4 Verify: per-role rows 45/54/54/42/54; SRX `responsibilities` non-empty; `select kind, count(*) from framework_gaps where status='pending_authoring' group by kind` → zero for `role_no_bars`/`competency_no_bars`/`missing_role_meta`; `seeder_lock_guard_active` presence agrees with step 8.1.
- [ ] 8.5 `GET /api/framework/roles/SRX/competencies` → `bars_available=true` × 18.
- [ ] 8.6 If any FV was locked: confirm the deploy is additive-complete per design §8 (new rows land, SRX text lands via fill-empty exception, gaps resolve); no existing anchor text changed (none authored here). If rollback is later needed under lock, a targeted delete scoped to `(role_id, competency_id)` pairs is required — establish the lock state now, not during rollback.

## Phase 9: Full Verification Sweep

- [ ] 9.1 `cd api && composer test` (config:clear + `php artisan test`) and `composer analyse` (phpstan).
- [ ] 9.2 `./vendor/bin/pint --test`; `./vendor/bin/phpstan analyse --no-progress --memory-limit=1G`; `php artisan test --parallel`; `php artisan test --coverage --min=85` (per `api/.github/workflows/ci.yml`).
- [ ] 9.3 `task test:api` from repo root (Taskfile.yml; requires `task up` for postgres/redis).
- [ ] 9.4 Re-run `.github/workflows/wrapper-ci.yml` step (d) and (f) locally or in CI — both control files empty in both directions, crossrole baseline unchanged, malformed-entries guard clean.
- [ ] 9.5 `shellcheck -s sh scripts/ci-guards.sh` and `dash -n scripts/ci-guards.sh` (required — `ci-guards.sh` changes in Phase 2).
