# Tasks: BARS Coverage Visibility

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~750-950 (C1 gate+fixtures largest; C2 defect+picker second) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 (defect) → PR 2 (CI gate) → PR 3 (picker UI) → PR 4 (list surface + doc) |
| Delivery strategy | ask-on-risk (default; not overridden by caller) |
| Chain strategy | stacked-to-main (each unit independently revertible per design's Rollback Plan) |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: stacked-to-main
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Defect fix: hydrate + submit `competency_ids` | PR 1 | Base: main/develop. Ships alone, safe standalone (see Phase 1). |
| 2 | Per-pair CI catalog gate | PR 2 | Base: main/develop. Independent of PR 1; order in this file is deliberate, not a dependency. |
| 3 | Picker disable-for-selection UI + i18n | PR 3 | Base: main/develop, requires PR 1 merged (needs real hydration/submission to test "removable" scenario). |
| 4 | List-surface count + doc pointer | PR 4 | Base: main/develop, requires PR 3 merged (`barsAvailable` type). |

## Phase 1 — Defect Fix: `competency_ids` Hydration + Submission (BLOCKING, land first)

**Why first**: `competencyIds` never reads `props.project.competencies` and never appears in either
payload (`ProjectForm.vue:421,634-663,711`). Every real project has zero persisted competencies
regardless of what the picker shows. The Phase 3 selection guard is inert until this lands — "a
channel that transmits nothing protects nothing."

**1.1-1.3 form ONE indivisible commit** — submitting `competency_ids` without hydrating current
values first makes the next edit of any existing project call `sync([])` and wipe its competencies.

- [x] 1.1 (RED, Pest) Add to `api/tests/Feature/C4/ProjectCrudTest.php`: `PATCH /api/projects/{id}`
      omitting `competency_ids` leaves `project_competencies` unchanged (documents current safety net).
- [x] 1.2 (RED, Vitest) In `backoffice/tests/unit/components/organisms/ProjectForm.spec.ts`: mount
      in edit mode with `project.competencies = [{id: 7, ...}]`, assert picker `modelValue` is `[7]`;
      submit unmodified, assert `updateProject` called with `competency_ids: [7]` (not omitted, not `[]`).
- [x] 1.3 (GREEN) `ProjectForm.vue`: hydrate `competencyIds` from `props.project.competencies` on
      mount/watch; include `competency_ids: competencyIds.value` in both `createProject` and
      `updateProject` payloads (`:634-663`).
- [x] 1.4 Run `./vendor/bin/pest api/tests/Feature/C4/ProjectCrudTest.php` and
      `bun run test:unit` (backoffice) filtered to `ProjectForm.spec.ts` — both green before Phase 2.

## Phase 2 — CI Per-Pair Coverage Gate (independent; order is deliberate, not a dependency)

Uses **26 entries, not 44** — the pair gate only asks its question of roles whose `bars/<ROLE>.json`
exists; SRX's 18 pairs stay under the existing role-level exemption (`framework-known-gaps.txt`,
unchanged). Composition: ICO 0, FLL 10, MLL 10, BUL 6, SRX 0 = 26.

- [x] 2.1 (RED, sh) Add fixture trees under the ci-guards self-test harness: `pair-incomplete`,
      `pair-closed-gap`, `pair-empty-anchor`, `pair-orphan`, `pair-no-file`, `pair-malformed`
      (bars-is-array + competencies-not-array variants), plus both real trees. Wire `expect_caught`
      rows in `.github/workflows/wrapper-ci.yml` step (f). Observe failing (functions undefined).
- [x] 2.2 (GREEN) Add to `scripts/ci-guards.sh`: `known_gap_pairs`, `role_competency_pairs <tree>`,
      `bars_competency_keys <tree> <ROLE>`, `catalog_missing_bars_pairs <tree>`,
      `catalog_unexpected_missing_bars_pairs <tree>`, `catalog_stale_competency_gap_exemptions <tree>`.
      Failure propagates via captured variable before any loop (mirror `:519-525`'s fix). Fail loudly
      on malformed JSON/shape (`process.exit(1)`, no bun on PATH = guard failed to run). Empty array
      (`"PRS": []`) counts as missing.
- [x] 2.3 Create `scripts/framework-competency-gaps.txt` (new, `ROLE:COMP` per line, `#` comments,
      grouped by role then competency) via
      `catalog_missing_bars_pairs docs/app_description/02-domain/framework`, committed verbatim — 26 lines.
- [x] 2.4 Wire `.github/workflows/wrapper-ci.yml` step (d): two new direction blocks (undeclared pair,
      stale exemption) using `CI_COMPETENCY_GAPS_FILE` override, mirroring the role-level blocks.
- [x] 2.5 Self-test all 8 fixtures green: `pair-incomplete` passes with `FLL:PRS` listed; emptied list
      is caught; `pair-closed-gap` and `pair-orphan` caught as stale; `pair-no-file` emits nothing;
      malformed trees non-zero and not swallowed; both real trees clean under
      `catalog_stale_competency_gap_exemptions`.
- [x] 2.6 `shellcheck -s sh scripts/ci-guards.sh` and `dash -n scripts/ci-guards.sh` clean, plus every
      new `run:` block in `wrapper-ci.yml` that sources it.
- [x] 2.7 **Merge prerequisite, not optional**: deliberate RED run on a scratch branch, both
      directions — delete one line from `framework-competency-gaps.txt` → wrapper job red; add a
      competency key to `bars/FLL.json` → wrapper job red on the stale-exemption direction. Screenshot
      or link both red runs in the PR, then restore. "A guard nobody has watched fail is not a guard."
      (Simulated via scratch copies + restore, not a real git branch, per apply-phase constraint of
      not creating branches — both directions confirmed RED on both trees, see apply-progress report.)

## Phase 3 — Picker Coverage UI (requires Phase 1 merged)

- [x] 3.1 (RED, Vitest) `backoffice/tests/unit/components/molecules/CompetencyPicker.spec.ts`: option
      with `barsAvailable: false` NOT in `persistedIds` → checkbox `disabled`; same option WITH id in
      `persistedIds` AND `modelValue` → not disabled, clicking emits `update:modelValue` without that id.
- [x] 3.2 (RED, Vitest) Same spec: disabled checkbox's `aria-describedby` resolves to the `noBars`
      text; an attached-but-uncovered option renders `attachedNoBars` instead.
- [x] 3.3 (RED, Vitest) `ProjectForm.spec.ts`: mock `fetchRoleCompetencies` with different coverage
      for FLL/ICO, **drive the role `Select`** (not call `loadCompetencyOptions` directly) — assert
      options' flags flip and `persistedIds` collapses to `[]` on role change.
- [x] 3.4 (GREEN) `CompetencyPicker.vue`: add `barsAvailable: boolean | null` (required field on
      `CompetencyOption`, never optional) and `persistedIds: number[]` props; predicate
      `selectable(option) = option.barsAvailable !== false || persistedIds.includes(option.id)`.
      Deselection stays inside the existing `toggle(option, checked)` — do not name anything
      `removeCompetency(` (would trip `destructive-action` R1's regex).
- [x] 3.5 (GREEN) Per-option `FieldDescription` bound via `aria-describedby` on the `Checkbox`
      (mirrors `immutableWhenLive` pattern at `:106-108`, `:150-152`); group-level `FieldDescription`
      in `FieldSet`, `v-if` missing-count > 0.
- [x] 3.6 (GREEN) `ProjectForm.vue`: stop dropping `bars_available` at `:555`; compute `persistedIds`
      scoped to `roleCode.value === props.project?.role_code ? project.competencies.map(c=>c.id) : []`
      (unscoped leaks past the existing role-change selection-clearing watcher).
- [x] 3.7 Add 4 i18n keys to **both** `backoffice/i18n/locales/it.json` and `en.json`:
      `projects.competencyPicker.{noBars,attachedNoBars,coverageSummary}`,
      `projects.table.uncoveredCompetencies`. No bare literals — assert both files contain all 4 keys
      in a Vitest test.
- [x] 3.8 Run `backoffice/tests/unit/arch/` — confirm `form-contract`, `destructive-action`,
      `date-render` guards stay green (no new `.vue` file matches their regexes).

## Phase 4 — List-Surface Coverage + Documentation (requires Phase 3 merged)

- [x] 4.1 (RED, Vitest) `backoffice/tests/unit/pages/projects/index.spec.ts`: mocked coverage → row
      shows uncovered count; fully covered project shows nothing; failed coverage fetch shows nothing
      (never `0` — an advisory count that is silently wrong is worse than absent).
      **CRITICAL FIX (post-verify)**: the first fixture always set `competencies: []` and only varied
      the ROLE's coverage, so it passed whether the count was per-project or per-role — a false
      positive. Rewrote with a dedicated regression test: two projects sharing one role with mixed
      coverage but DIFFERENT `competencies` holdings, asserting the counts differ per row. Confirmed
      genuine RED against the pre-fix implementation (reverted to it, re-ran, restored) before
      re-confirming GREEN.
- [x] 4.2 (GREEN) Create `backoffice/app/composables/useBarsCoverage.ts`: per-role-code coverage cache
      over the catalog endpoint (`/framework/roles/{roleCode}/competencies`), ≤5 requests for ≤5 role
      codes. `pages/projects/index.vue` resolves it for each distinct non-null `role_code` loaded;
      `ProjectTable.vue` renders the per-row count.
      **CRITICAL FIX (post-verify)**: the count was ROLE-scoped, not PROJECT-scoped —
      `uncoveredCounts[role_code]` was rendered unmodified, so every project sharing a role showed the
      identical number regardless of what it actually held (contradicted the admin-backoffice spec's
      own "fully covered project shows no debt notice" / "holding 2 competencies states 2" scenarios).
      Fixed: `useBarsCoverage` now exposes `uncoveredIdsByRole: Record<string, number[]>` (the role's
      uncovered competency IDS, not a count); `ProjectTable.uncoveredCount(project)` intersects
      `project.competencies` against that set. See apply-progress report for the RED/GREEN evidence.
- [x] 4.3 (E2E) Extend `backoffice/tests/e2e/projects-crud.spec.ts` only. Mock
      `/framework/roles/*/competencies` with mixed `bars_available`: uncovered checkbox disabled on
      create; open a project holding an uncovered competency → checked and enabled; untick, save,
      reopen, gone. NOTE: `autocomplete-hygiene.spec.ts` has no framework-endpoint mock to reuse — this
      file's own `mockAdminApi()` already owned that mock and was extended in place instead (see
      apply-progress report). CORRECTED (post-verify): the 58%+ E2E failure rate originally reported
      was an orphaned Playwright container holding stale resources, not a real `login()` blocker — full
      local suite (chromium + webkit + mobile, 129 tests) now runs 100% green, including this scenario.
- [x] 4.4 Update `docs/app_description/02-domain/01-roles-and-competencies.md:78` — replace the "File
      completi" claim with the Italian pointer paragraph naming `scripts/framework-known-gaps.txt` and
      `scripts/framework-competency-gaps.txt` as the exact source of truth. **No numbers in prose.**
      Land last — it describes the state the gate now enforces.

## Phase 5 — Final Verification (all phases merged)

- [x] 5.1 API: `./vendor/bin/pest` (full, unfiltered — `--filter` was observed fabricating passes;
      do not use it) from `api/`. Also `composer test` (runs `artisan config:clear` + `artisan test`).
      RESULT: `composer test` (bare `artisan test`, no `--parallel`) — 1705 tests, 1700 passed, 5
      skipped (pre-existing), 0 failures. CORRECTION (flagged by verify): bare `./vendor/bin/pest` is
      NOT parallel by default; the two flaky runs (4-12 failures, Postgres deadlocks tearing down
      schema between test files, plus a `password_changed_at` migration-race in
      `AdminPasswordResetRevocationTest`) were something ELSE in this environment's default pest
      config/plugin causing concurrent DB teardown — mechanism not fully pinned down, but every one of
      those files re-run in isolation passed cleanly, and none touches Project/Competency code.
      Verify independently ran the REAL CI gate, `php artisan test --parallel`, and it passed cleanly
      (1705 tests, 1700 passed, 5 skipped, 0 failures) — reproduced here too, which corroborates
      "parallel-teardown artefact, not a regression" without depending on the earlier imprecise claim.
      See apply-progress report for full detail.
- [x] 5.2 Backoffice: `bun run format:check`, `bun run typecheck`, `bun run lint`,
      `bun run codegen:check` (no API change expected — must report zero drift). ALL GREEN — `format:write`
      was run once to apply Prettier's own formatting to the 5 newly-touched files, then `format:check`
      confirmed clean; `codegen:check` reported zero drift (no API change, as expected).
- [x] 5.3 Backoffice unit: `node node_modules/.bin/vitest run --coverage --coverage.thresholds.lines=85`
      (matches `backoffice/.github/workflows/ci.yml`), or `bun run test:unit:coverage`. RESULT: 89 files,
      688 tests, all green; 94.79% line coverage (threshold 85%). (89/688 after the critical-fix and
      coverage-gap tests added post-verify; was 88/680 before.)
- [x] 5.4 Backoffice E2E: `node node_modules/.bin/playwright test` with `--workers=1`, or
      `task e2e:backoffice` (pinned container, matches CI screenshot baselines). CORRECTED (post-verify):
      the original 58%+ container-run failure rate was an orphaned Playwright container holding
      resources, NOT the documented `login()` blocker. Full local suite (real `playwright.config.ts`
      webServer, not the container) is 100% green: chromium 60/60, webkit+mobile 69/69 — 129/129 total,
      including the new uncovered-competency scenario. `sidebar-navigation.spec.ts`'s `/projects` test —
      the one real failure verify's clean container run reported (1 of 129) — reproduced as a genuine
      pass on every local run (single run, 3x `--repeat-each`, and the full 60-test chromium run):
      confirmed a one-off timing flake under heavy parallel/container load, not a regression from the
      list-surface work (which, for an EMPTY-competencies fixture as this spec's mock uses, calls
      `loadRoles([])` — a no-op that touches no new network path at all).
- [x] 5.5 Wrapper: confirm `.github/workflows/wrapper-ci.yml` step (d) and (f) green on the real tree,
      and that Phase 2.7's two deliberate red runs are linked in the PR before merge. Simulated locally
      (scratch copies, not a real git branch/PR per apply-phase constraint) — both directions confirmed
      RED, then GREEN restored. Actual GitHub Actions run + PR linking is outside this apply batch's
      reach (no branch/PR created here per explicit instruction).
- [x] 5.6 `task test:backoffice` (host Vitest + containerized Playwright) as the combined local gate.
      See apply-progress report.

## Verification Follow-Up (post sdd-verify, fixed in this apply session)

Independent verification reproduced the RED-first evidence for Phases 1-4 (hydration/submission,
disabled-checkbox binding, the three-layer `role_code` immutability check, the 26-entry file recomputed
byte-for-byte, both gate directions in both the verifier's own and this apply's runs, and confirmed
`known_gap_roles()` really does mis-parse a `FLL:PRS`-shaped line as a role code — the two-file
separation is load-bearing). It found one CRITICAL defect and 4 WARNING-level coverage gaps, all fixed:

- **CRITICAL** — the list-row count was ROLE-scoped, not PROJECT-scoped (see 4.1/4.2 above for the fix
  and the regression test that would have caught it).
- **WARNING** — `CompetencyPicker.spec.ts`'s flat `$t` stub discarded interpolation params, so
  `coverageSummary`'s actual numbers were never verified. Fixed: `tMock` now echoes params (mirrors
  `avatar-templates-page.spec.ts`'s convention); added FLL (10 of 18) and ICO (0 of 15) numeric
  assertions. Verified this genuinely catches a hardcoded `missingCount` (mutated the source to `0`,
  confirmed RED, restored).
- **WARNING** — "No override control exists" was true by inspection only. Fixed:
  `tests/unit/arch/competency-override.spec.ts`, a new repo-wide source-scanning arch guard (mirrors
  `destructive-action.spec.ts`'s pattern) plus a deliberately non-compliant fixture proving detection.
- **WARNING** — nothing clicked a disabled checkbox and asserted no emit. Fixed: added that exact test
  to `CompetencyPicker.spec.ts`.
- **WARNING** — ci-pipeline's "entries are grouped by role" had no automated check. Fixed:
  `competency_gaps_role_order_violations` in `scripts/ci-guards.sh`, wired into step (f)'s self-test
  with an interleaved-role fixture (proves detection) plus a real assertion against the committed
  `scripts/framework-competency-gaps.txt` (currently clean).

Also corrected: task 5.1's "direct `./vendor/bin/pest` parallel" wording was imprecise (bare pest is
not parallel by default); re-stated with `php artisan test --parallel` (the real CI gate) as the
corroborating run instead. And the E2E "58%+ failure" finding was traced to an orphaned Playwright
container, not a real blocker — see 5.4 above.

## Pre-Commit Review Follow-Up (guards mechanically re-run, not just read)

Pre-commit review confirmed the mechanics: shellcheck/dash clean, all four pair-level catalog functions
green on both trees, the committed 26-pair list byte-identical to `catalog_missing_bars_pairs` output,
the grouping guard clean, malformed-JSON paths failing closed. Found 1 real defect and 4 stale-reference
/ missing-spec items, all fixed:

1. **REAL DEFECT — a third stale-exemption shape was mute in BOTH directions.** A pair naming a role
   that IS declared in `roles.json` but has NO `bars/{ROLE}.json` file at all (SRX's actual shape) fell
   through both `catalog_missing_bars_pairs` (skips no-file roles by design) and
   `catalog_stale_competency_gap_exemptions`'s two directions (Direction 1 needs the file to exist;
   Direction 2 finds the pair legitimately declared). Fixed: added Direction 3 to
   `catalog_stale_competency_gap_exemptions` in `scripts/ci-guards.sh`, plus a new
   `stale_competency_gap_exemption_reason` helper so callers can name the specific shape. Proved BY
   CONSTRUCTION with the exact fixture from the finding — `SRX:PRS` / `ZZZ:PRS` / `FLL` (malformed) in
   one gaps file: PRE-FIX, `unexpected=[]` and `stale=[ZZZ:PRS, FLL]` (SRX:PRS silently mute); POST-FIX,
   `stale=[SRX:PRS, ZZZ:PRS, FLL]` — the mute case now caught, the two already-caught cases still
   caught, `unexpected=[]` unchanged (still correctly the role-level gate's business). Self-test row
   `pair-role-no-file-exemption` added, wired into `.github/workflows/wrapper-ci.yml` step (f).
2. **Stale line-number references** (the class this file exists to prevent, found in its own tooling):
   `wrapper-ci.yml`'s pair-malformed self-test comment cited `:983-1009` as the role-level rows — those
   were actually the pair-level fixtures; the real role-level rows are elsewhere and drift with every
   edit. Fixed: references by FUNCTION NAME (`catalog_missing_bars` / `catalog_unexpected_missing_bars`)
   instead of line numbers.
3. `ci-guards.sh`'s `catalog_missing_bars_pairs` comment cited `:519-525` as the fix `catalog_missing_bars`
   needed; those lines are prose inside a comment block, not the fix itself. Fixed: dropped the number
   entirely, kept the function-name reference.
4. Step (d)'s success message still said only "every declared role has BARS or a committed known gap"
   after the step started also asserting per-pair coverage and staleness in both lists. Fixed: message
   now names both. Related, same class: step (a)'s `echo "All 8 compose services present"` hardcoded a
   count in the very step arguing a count must not be asserted by a comment. Fixed: derived from
   `CI_EXPECTED_COMPOSE_SERVICES` at run time (`wc -w`), verified it prints "All 8 compose services
   present" — the same number, now computed rather than typed.
5. `bars_competency_keys` treats `"COMP": []` as a stub, not coverage, and the self-test has a
   `pair-empty-anchor` row proving it — but neither the delta spec nor the promoted
   `openspec/specs/ci-pipeline/spec.md` had a scenario for it. Fixed: added "An empty anchor array is
   not coverage" to BOTH the archived delta copy (this file's sibling `specs/ci-pipeline/spec.md`) and
   the promoted `openspec/specs/ci-pipeline/spec.md` — verified byte-identical between the two on the
   whole requirement section. Also added, proactively, for the SAME reason (enforced behaviour with
   nothing written down) applied to fix #1 above: "A per-pair exemption for a role with no bars file at
   all fails CI" — this one was not explicitly requested but follows the identical principle for the
   Direction 3 behaviour just added in fix #1, so leaving it undocumented would reproduce the exact
   defect class this fix round exists to close.

All gates re-run after these fixes: `shellcheck -s sh` / `dash -n` clean on `ci-guards.sh` and every new
`run:` block; full self-test 65 "ok" rows, 0 FAILED; both deliberate red-run directions re-confirmed
(delete `FLL:PRS` → undeclared on both trees; author `FLL:PRS`'s anchors in both trees → `stale=[FLL:PRS]
reason=anchored` on both); backoffice unit 89/688 unaffected and still green (94.79% coverage);
typecheck/lint/format:check unaffected and still clean.

## Notes on Contradictions Carried From Design (RESOLVED — corrected by explicit orchestrator instruction during apply)

- `specs/ci-pipeline/spec.md` said "44 known gaps" in its scenario text; Phase 2 implements design's
  corrected **26** (SRX's 18 pairs stay under the role-level exemption, not double-declared). Spec text
  corrected in place with a recorded-departure note, not silently rewritten — see
  `specs/ci-pipeline/spec.md`'s "Corrected count" callout.
- `specs/admin-backoffice/spec.md`'s "Project Detail Surfaces Uncovered-Competency Debt" requirement
  said "detail page" / "detail view"; design D1 states no detail page exists and satisfies this via
  the existing list surface (`ProjectTable.vue` row count). Phase 4 implements the list-row count as
  the detail-debt surface; the requirement was renamed to "Project List Surfaces Uncovered-Competency
  Debt" and its scenarios rewritten to name the list row, with a recorded-departure note — see
  `specs/admin-backoffice/spec.md`'s "Corrected surface" callout.
