# Tasks: Framework Catalogue Authoring

> Strict TDD active. Correctness-critical zones (~95% coverage): revision
> resolution, `ProjectInterviewability`, `ApplyCompetencySelection`, the
> publish sweep, the superadmin gate — this change touches two of the three
> high-integrity zones (scoring, candidate state machine). 85% overall in
> every submodule touched. This breakdown follows `design.md`'s PR slicing
> **verbatim** — 12 PRs, not re-sliced. Where a slice looks wrong the design
> already says so explicitly (Contradictions surfaced 1–7); this file does
> not silently change the split.

**Ordering dependency, stated once, load-bearing:** within PR 3, the runtime
invariant twin (FormRequest validation + DB CHECK constraints + the blocking
publish sweep — Phase 8/9 below) MUST be implemented and GREEN **before** the
CRUD controllers are wired to accept writes (Phase 10). Reversing this order
opens a window where a superadmin can write a catalogue `scripts/ci-guards.sh`
would reject. This is not a suggestion — it is the reason PR 3 groups
`OpenDraftRevision`/`PublishRevision`/CRUD/FormRequest twins/`catalogue.manage`
into one PR rather than splitting CRUD from its guard.

**Open questions (OQ-A/B/C) are non-blocking for every task below**, per
design. No task in PRs 1–12 depends on their answers:
- OQ-A (JSON-ingress after publish) — RESOLVED by the product owner
  2026-09-15: `catalogue:import --into-draft`. Delivered in PR 4 (task 15.5).
- OQ-B ("copy from revision X" affordance) — not built; PR 4/PR 10 ship the
  plain per-revision default-question editor only.
- OQ-C (`TurnClassifier` false-follow-up rate) — PR 7 ships the conservative
  (over-report) behavior as specified and discloses the residual; no task
  waits on a measured rate.

## API Verification Commands (run at the gate of every `api` PR: 1, 2, 3, 4, 5, 6, 7, 8)

```
cd api
./vendor/bin/pint --test
./vendor/bin/phpstan analyse --memory-limit=1G
php artisan migrate:fresh --seed=false   # or the repo's test-DB migration step
./vendor/bin/pest --parallel
./vendor/bin/pest --coverage --min=85
# fresh OpenAPI export, Postgres only, diffed against the committed snapshot:
DB_CONNECTION=pgsql php artisan scramble:export && git diff --exit-code openapi.json
# VERSION / composer.json / openapi.json agreement (wrapper guard)
scripts/ci-guards.sh   # must stay green, unmodified, exactly as strict
```

`task openapi:sync` (wrapper `Taskfile.yml`) is the required step whenever a
PR changes the API surface (PRs 3, 4, 6*, 7*, 8*) — it runs
`scramble:export`, copies `openapi.json` into `frontend/` and `backoffice/`,
and regenerates both typed clients. **It MUST run with `DB_CONNECTION=pgsql`
— never sqlite**, which silently produces a wrong export (JSON-column
introspection differs). Follow with `task verify:openapi` before any PR is
considered gate-clean. (*PRs 6/7/8 change response payload shapes on
existing routes but add no new routes; re-run the export and diff regardless
— a shape change is still a contract change.)

Pest is run as `cd api && ./vendor/bin/pest <exact-file>` or a full run —
never `php artisan test --filter` (observed fabricating passes in this repo).

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | PR1 ~420 · PR2 ~260 · PR3 ~400 · PR4 ~200 · PR5 ~380 · PR6 ~340 · PR7 ~360 · PR8 ~120 · PR9 ~150 · PR10 ~420 · PR11 ~60 · PR12 ~140 · **Total ≈ 3250** (design's own ≈2,500–3,500 estimate) |
| 400-line budget risk | High — PR1, PR3, PR5, PR6, PR7, PR10 are at or above the 400-line budget on their own |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → PR 2 → PR 3 → PR 4 → PR 5 → PR 6 → PR 7 → PR 8 (`api`, each on the previous slice's branch) → PR 9 (wrapper, before PR 10) → PR 10 (`backoffice`) → PR 11 (`frontend`) → PR 12 (`backoffice`, on PR 10's branch) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain — PR 1 targets `feature/framework-catalogue-authoring`; each later `api` slice targets the previous `api` slice's branch; PR 9 (wrapper) lands before PR 10; PR 10/PR 12 (`backoffice`) and PR 11 (`frontend`) each target their own tracker branch, requiring the wrapper's PR 9 merged first per `CLAUDE.md`'s "`DESIGN.md` before any UI code" |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Repo / Base | Focused test command | Runtime harness | Rollback boundary |
|------|------|-------------|-----------------------|------------------|--------------------|
| 1 | Revisions table, composite FKs, baseline migration, `BarsIndicatorLoader` resolution | `api`, base = tracker | `./vendor/bin/pest tests/Feature/Migration/` | Railway-like staging against a copy of real data — **required before PR 2 starts**, per Migration/Rollout | `down()` restores single-revision schema (tested); not cheap after a 2nd revision exists |
| 2 | Seeder against revision state; `SeederLockGuardTest` rewritten | `api`, base = PR1 branch | `./vendor/bin/pest tests/Feature/C4/Seeder/` | N/A — seeder-only, no external call | Revert restores prior seeder + test file |
| 3 | `OpenDraftRevision`/`PublishRevision`, CRUD, FormRequest twins, `catalogue.manage`, 403s, OpenAPI ×3 | `api`, base = PR2 branch | `./vendor/bin/pest tests/Feature/Catalogue/` | `task openapi:sync` against Postgres | Additive routes/tables; revert removes with no residue, regenerate 3 snapshots |
| 4 | `framework_default_questions` CRUD + `catalogue:export` | `api`, base = PR3 branch | `./vendor/bin/pest tests/Feature/Catalogue/DefaultQuestion* tests/Feature/Catalogue/CatalogueExportTest.php` | `Storage::fake()` proves zero filesystem writes | Additive; revert removes command + table |
| 5 | `operator_modified`, `ApplyCompetencySelection`, restore renumber | `api`, base = PR4 branch | `./vendor/bin/pest tests/Feature/Project/` | N/A — runs inside existing `DB::transaction` scopes | Revert restores prior `ProjectController` selection code path |
| 6 | `ProjectInterviewability`, 3 ingress refusals, `/start` use-time check | `api`, base = PR5 branch | `./vendor/bin/pest tests/Feature/Interview/` | Manual: mint an entry link, empty a competency, confirm use-time refusal | Additive predicate + guard clauses; revert removes both cleanly |
| 7 | Composer budget reversal, `primary_questions` snapshot, `TurnClassifier` | `api`, base = PR6 branch | `./vendor/bin/pest tests/Unit/Conversation/ tests/Feature/Interview/TranscriptAuditTest.php` | A real `/start` → `/utterance` round trip against a seeded competency | Revert restores additive-budget composer and drops the two new columns |
| 8 | `audit_logs.organization_id` nullable, `PlatformAuditWriter` | `api`, base = PR7 branch | `./vendor/bin/pest tests/Feature/Catalogue/PlatformAuditWriterTest.php` | N/A — DB-only write path | Additive column + writer class; revert is clean |
| 9 | `DESIGN.md`, `CLAUDE.md`, the two other "4 fixed" documents | wrapper, base = tracker | N/A — documentation only | N/A | Pure doc revert |
| 10 | `QuestionListEditor` extraction, `/catalogue` page, nav, guard, i18n | `backoffice`, base = PR9 merged + tracker | `bun run test:unit` | `bun run test:e2e -- catalogue` (chromium) | Revert drops the page/nav entry; `ProjectQuestionsPanel` stays functional (extraction, not rewrite) |
| 11 | `[token].vue` consumes `redirect_url` | `frontend`, base = tracker | `bun run test:unit` | Manual: trigger a `403` from `/sso/exchange` with a configured `error_redirect_url` | ~60-line revert to the existing null-fallback branch |
| 12 | Playwright: chromium + webkit + mobile SA-11 gate | `backoffice`, base = PR10 branch | `bun run test:e2e` | Full Playwright run, 3 projects | Pure test-file revert, no production code |

---

## PR 1 — `api`: Revisions, Composite FKs, Baseline Migration, Loader Resolution

> Base: `feature/framework-catalogue-authoring`. **Nothing downstream ships
> until this PR is verified in a Railway-like environment against real
> data** (Migration/Rollout). Must not break: every existing scoring test;
> `SeederLockGuardTest` in its **old** form (seeder untouched here);
> `scripts/ci-guards.sh`.

### Phase 1: RED — the highest-value test in the change, written before the migration exists

- [x] 1.1 RED `api/tests/Feature/Migration/BaselineRevisionMigrationTest.php`: seed an evaluation against the pre-revision schema, snapshot `getTranslation()` for all four fields of its indicators, migrate, re-resolve through `Evaluation → FrameworkVersion → revision`, assert byte-identical text. Written against schema that does not exist yet — confirm it fails to compile/resolve (RED) before any migration in Phase 2 lands.

### Phase 2: Foundation — schema

- [x] 2.1 Create migration `api/database/migrations/*_create_framework_catalog_revisions_table.php`: `id`, `state` (`draft`|`published`), `is_baseline` bool, `label` nullable, `published_at` nullable, `published_by_user_id` nullable FK `nullOnDelete`, timestamps; partial unique indexes `framework_catalog_revisions_one_draft` (`WHERE state = 'draft'`) and `framework_catalog_revisions_one_baseline` (`WHERE is_baseline`).
- [x] 2.2 Create migration `api/database/migrations/*_add_revision_to_framework_catalog.php`: `revision_id NOT NULL` on `framework_roles`, `framework_competencies`, `framework_bars_indicators`, `framework_role_competency`; `UNIQUE (id, revision_id)` on roles and competencies; composite FKs per the design's table (`role_competency`, `bars_indicators` → `(role_id, revision_id)`/`(competency_id, revision_id)`); drop-and-recreate `framework_role_competency`'s PK to `(revision_id, role_id, competency_id)`, repopulated from existing pivot contents in the same migration; partial unique `(revision_id, competency_id, position) WHERE role_id IS NULL` on BARS indicators. **No row is copied.** — implemented as a nullable-add-then-tighten split across this migration and `*_backfill_baseline_revision.php` (2.4): Postgres cannot add a NOT NULL column with no default to an already-populated table, and there is no revision row to point at until the backfill migration creates one. See both files' docblocks.
- [x] 2.3 Create migration `api/database/migrations/*_create_framework_default_questions_table.php`: revision-scoped, `{en,it}` json text, `position`, `UNIQUE (revision_id, competency_id, position)`, composite FK `(competency_id, revision_id)` → competencies. — **corrected post-review**: the auto-generated unique-constraint name for `(revision_id, competency_id, position)` is 69 characters, over Postgres's 63-byte identifier limit; it was being silently truncated to a name ending in a bare underscore. Given an explicit short name (`framework_default_questions_rev_competency_position_unique`).
- [x] 2.4 Create migration `api/database/migrations/*_backfill_baseline_revision.php`: insert ONE revision row (`is_baseline = true`); stamp its id onto every existing catalogue row and every existing `framework_versions` row. No anchor text copied, rewritten, or re-keyed; `framework_bars_indicators.id` values unchanged. — **corrected post-review**: inserted as `state = 'published'` (`published_at = now()`), not `'draft'`. Draft was a review-gate-caught defect: `framework_catalog_revisions_one_draft` permits at most one draft platform-wide, so a draft baseline occupies that slot PERMANENTLY and PR 3's `OpenDraftRevision` could never open a real draft; the baseline is also, simply, already-shipped/already-scored content, which is what `published` means. Also carries the NOT NULL/composite-key tightening deferred from 2.2/2.5 (see those tasks' notes); sets a literal `DEFAULT <baseline id>` on the four catalog-content tables so every pre-existing factory/direct-create call site across the suite (none of which knows about revisions) keeps working unmodified. A second **post-review correction**: the raw `CREATE UNIQUE INDEX` for `framework_bars_indicators (revision_id, role_id, competency_id, position)` used a 66-character name, over Postgres's 63-byte identifier limit and silently truncated to a name ending in a bare underscore; given an explicit short name (`framework_bars_indicators_rev_role_comp_position_unique`).
- [x] 2.5 Create migration `api/database/migrations/*_add_revision_to_framework_versions.php`: `revision_id` FK `restrictOnDelete`; guard refusing a `draft` target (DB-level or model-level, whichever the migration's own test proves — see 4.4, not 4.3 as originally cross-referenced). — `revision_id` is left NULLABLE here (not NOT NULL): the `framework-catalog` spec text itself says "set when the version is resolved", and a DEFAULT (the way the four catalog tables get one) would silently repoint every unscoped `FrameworkVersion` creation across the suite at a real revision it never asked to pin. NULL states "not resolved to anything", independent of the baseline's state. The guard (2.8) fires only on an explicit `revision_id` assignment.
- [x] 2.6 Create `api/app/Models/FrameworkCatalogRevision.php`, `api/app/Models/FrameworkDefaultQuestion.php`. — also added `database/factories/FrameworkCatalogRevisionFactory.php` (not separately itemized above), required for `HasFactory<FrameworkCatalogRevisionFactory>` to satisfy PHPStan/Larastan generics checking, and its `draft()` state now has real call sites (`FrameworkCatalogRevisionInvariantsTest`, `BaselineRevisionRollbackTest`, `FrameworkVersionRefusesDraftRevisionTest`) after the review-gate fixes below. Also added `App\Exceptions\PublishedRevisionImmutableException` and a `FrameworkCatalogRevision::booted()` guard (mirrors `FrameworkVersion`'s `is_locked` shape) refusing any mutation once `state` was `published`, and a DB `CHECK (state IN ('draft','published'))` constraint on `framework_catalog_revisions.state` (migration 2.1) — both review-gate fixes, covered by `api/tests/Feature/Catalogue/FrameworkCatalogRevisionInvariantsTest.php`.
- [x] 2.7 Modify `api/app/Models/{Role,Competency,BarsIndicator}.php`: `revision_id` fillable + `revision()` `belongsTo` relation.
- [x] 2.8 Modify `api/app/Models/FrameworkVersion.php`: `revision()` relation; refuse a `draft` target on assignment. — new `App\Exceptions\DraftRevisionPinRejectedException` (422), mirroring `LockedFrameworkVersionException`'s shape; guard fires on `creating` and `updating`, only when `revision_id` is dirty.
- [x] 2.9 Modify `api/app/Services/Conversation/BarsIndicatorLoader.php`: resolve indicators through `Project → FrameworkVersion → revision_id`, never the single live catalogue. — `forRoleCompetency()` gained an OPTIONAL trailing `?int $revisionId = null`; omitted, it preserves today's exact query (every existing caller, including `SystemPromptComposer` and `tests/Unit/C8/BarsIndicatorLoaderTest.php`, is unaffected). Wiring a real revision id through the live interview call path (`SystemPromptComposer`/`InterviewController`) is D7/D8's job in PR7, not this PR's file list — see the loader's updated docblock.

### Phase 3: GREEN — run the Phase 1 test

- [x] 3.1 Run migrations against the test DB; run 1.1 GREEN. This is the correctness proof for "an already-scored evaluation still means what it meant" — do not weaken the assertion to "the chain resolves" if it fails; fix the migration.

### Phase 4: RED — the remaining PR 1 tests

- [x] 4.1 RED `api/tests/Feature/Migration/BaselineRevisionRollbackTest.php`: `down()` drops `revision_id` columns and the revisions table, restoring the pre-revision shape with the baseline rows intact — an explicit test, not an assumption. Document inline that this only restores a **single-revision** catalogue; reverting after a second revision exists is a reseed (stated, not silently true).
- [x] 4.2 RED `api/tests/Feature/Catalogue/CrossRevisionCompositeFkTest.php`: a `framework_bars_indicators` row whose `role_id` belongs to revision 1 and whose `revision_id` says 2 is refused by PostgreSQL (composite FK), not by application code.
- [x] 4.3 RED `api/tests/Feature/Catalogue/BarsIndicatorLoaderRevisionResolutionTest.php`: two revisions with divergent anchor text; a project pinned to revision 1 always resolves revision 1's text regardless of revision 2's later publish.
- [x] 4.4 RED `api/tests/Feature/Catalogue/FrameworkVersionRefusesDraftRevisionTest.php`: creating/resolving a `FrameworkVersion` against a `draft` revision is rejected. — after the review-gate fix (2.4), it can no longer read the baseline as its draft fixture (the baseline is published); rewritten to mint an explicit draft/reuse the published baseline directly where each subtest calls for it.
- [x] 4.5 (added post-review, not in the original breakdown) RED `api/tests/Feature/Catalogue/FrameworkCatalogRevisionInvariantsTest.php`: the baseline is `published` not `draft`; `framework_catalog_revisions_one_draft` actually refuses a second draft (previously zero test coverage); `state` has a real DB CHECK, not only a PHP comment; a `published` revision refuses any mutation (`PublishedRevisionImmutableException`); a `draft` revision may still be freely mutated.
- [x] 4.6 **Second post-review correction** (2nd gate pass): 4.1, 4.2, and 4.5's five DB-constraint assertions used the anti-pattern `rules.design` names verbatim — `toThrow(QueryException::class)` / `toThrow(Exception::class)`, which passes just as happily against a missing table as against the specific constraint each test exists to prove. Replaced with a shared `assertPostgresConstraintViolation(callable, sqlstate, constraintName)` helper (`api/tests/Pest.php`) pinning the exact SQLSTATE (`23505` unique, `23503` FK, `23514` CHECK) and the constraint name from the driver message. Each of the five was then MUTATED (the targeted constraint temporarily removed from its migration, `migrate:fresh`, run, confirm the test fails with "none was thrown" rather than passing vacuously, then reverted) to prove it actually watches the constraint it claims to.

### Phase 5: GREEN + Gate

- [x] 5.1 Run 4.1–4.4 GREEN; run `php artisan migrate:rollback` on the test DB and confirm the schema matches pre-PR-1 exactly.
- [x] 5.2 Run the full existing scoring test suite; zero regressions.
- [x] 5.3 Confirm `api/tests/Feature/C4/Seeder/SeederLockGuardTest.php` still passes in its **old** form — the seeder is not touched in this PR.
- [x] 5.4 Run the API Verification Commands block above. No new API routes in this PR — the OpenAPI diff should be empty; still run it.
- [ ] 5.5 Deploy/verify this migration against a Railway-like environment with a copy of real data before any PR 2 work starts (Migration/Rollout hard gate). — NOT performed in this session: requires an actual Railway-like staging environment with a copy of real production data, which is an infrastructure/ops action outside a local implementation session. Local verification (fresh migrate, rollback, re-migrate, full Pest suite against real Postgres) all passed — see the apply report — but this specific hard gate still needs a human-operated staging deploy before PR2 work starts.

---

> **PR 1 REVIEW ADVISORIES (RDD lineage `review-b179a28cd3bb34b3`, approved, non-blocking).**
> Recorded as follow-up work, not reasons to reopen PR 1:
>
> - [ ] R3-001 (WARNING, relevant to PR 3) — the literal `DEFAULT <baseline id>` on
>       `revision_id` for the four catalogue-content tables routes every insert that omits
>       `revision_id` into the PUBLISHED baseline, so content writes to a published revision
>       are not refused. The model guard covers the revision row, not its content. Drop the
>       default (or enforce content immutability in the DB) once PR 3's writers always name
>       a revision.
> - [ ] R3-002 (WARNING) — `down()` of the backfill does not check for a second revision
>       before mutating; with non-colliding codes it silently merges revisions. Add a
>       pre-flight refusal.
> - [ ] R3-003 (WARNING) — `BaselineRevisionMigrationTest` rolls back a hard-coded 5 steps
>       and never asserts the rollback happened; a later migration will shift the window
>       silently. Roll back by named migration and assert `revision_id` is gone.
> - [ ] R3-004 — `BarsIndicatorLoaderRevisionResolutionTest` never builds a Project or
>       FrameworkVersion; the pin-based resolution is unproven until PR 7 wires it.
> - [ ] R3-005 — same gap as 13.0/13.1: new `FrameworkVersion` rows keep a NULL pin.
> - [ ] R3-006 — `is_baseline`/`published_at` immutability and the `one_baseline` index are
>       untested; query-builder bulk writes bypass the Eloquent guard (document or enforce).
> - [ ] R3-007 — `BaselineRevisionRollbackTest` uses `DB::` without importing the facade.
>
> Second pass on the committed diff (RDD lineage `review-6fd6d9e45d1b0abc`, approved,
> non-blocking), new items only:
>
> - [ ] R3-1 (WARNING) — the revision-scoped uniqueness that replaced the global indexes
>       (`framework_bars_indicators_rev_role_comp_position_unique`, the rebuilt role-less
>       partial index, `revision_code_unique` on roles/competencies) has no test proving it
>       refuses a duplicate inside one revision.
> - [ ] R3-3 — the rollback test compares row counts but never inserts known catalogue rows;
>       if the catalogue is not seeded both counts are zero and the check proves nothing.
> - [ ] R3-4 — the draft-pin update-path test does not re-read the row to prove `revision_id`
>       stayed null; raw query updates bypass the Eloquent guard.
> - [ ] R3-5 — `BarsIndicatorLoaderRevisionResolutionTest` finds the baseline with an
>       unordered `first()` instead of `is_baseline`.

## PR 2 — `api`: Seeder Against Revision State

> Base: PR 1 branch. Must not break: idempotence; per-role seeded counts;
> `framework_gaps` reconciliation.

> **Fresh-install contradiction, resolved (not the migration-conditional
> shape this file originally implied).** Combining "PR1's baseline is always
> inserted `published`" (corrected during PR1 review — see PR1's Phase 2.4
> note) with "the seeder writes zero rows against a published baseline"
> (D2, this file's original Phase 6/7 wording) breaks a fresh install: the
> backfill migration creates a published baseline over an EMPTY catalogue,
> `DatabaseSeeder::run()` calls `FrameworkCatalogSeeder` immediately after,
> and a bare `state === 'published'` gate refuses to write anything — a
> fresh environment ships with no catalogue at all.
>
> **Rejected fix**: making the backfill migration insert the baseline as
> `draft` when the catalogue is empty and `published` when it already holds
> content (the shape this file originally sketched), with the seeder
> publishing a synced draft. This was rejected on evidence, not preference:
> several already-committed PR1 tests assert the baseline is
> UNCONDITIONALLY `published` immediately after migration, with NO seeding —
> `FrameworkCatalogRevisionInvariantsTest::test('the baseline revision is
> published, not draft')` and `FrameworkVersionRefusesDraftRevisionTest`'s
> "published by construction" tests chief among them (both run against a
> freshly migrated, unseeded test database, per `tests/Pest.php`'s
> `RefreshDatabase` wiring — migrations run once, before any test-specific
> seeding). Making the migration conditional would reopen and change
> already-shipped, already-tested PR1 behaviour to solve a PR2-only gap.
>
> **Implemented fix**: the backfill migration is UNCHANGED — the baseline
> stays unconditionally `published`. The seeder's write gate
> (`FrameworkCatalogSeeder::writesAreBlocked()`) checks not merely "is the
> baseline published" but "is the baseline published AND does it already
> carry content" (`Competency::where('revision_id', $baselineId)->exists()`
> — competencies are this seeder's own first catalogue write on every
> mutating run, so their presence is a sufficient proxy for "already
> populated"). A published-but-empty baseline is populated normally, exactly
> once; a published baseline that already carries content is immutable, full
> stop. No mutation to `framework_catalog_revisions.state` ever happens in
> the seeder — the "publishing is the draft→published transition, allowed
> because the original state was draft" invariant from PR1 is therefore
> never exercised by this seeder at all, because the seeder never needs to
> transition the revision's state. A **draft** baseline — never produced by
> this schema today, only constructible via a raw `DB::table()` write that
> bypasses the Eloquent immutability guard — still runs the full
> delete-stale sync unconditionally, matching this section's literal
> "draft baseline still syncs" wording; see
> `tests/Feature/C4/Seeder/SeederLockGuardTest.php`'s forced-draft scenario.
>
> **Undocumented fallout, discovered and resolved while implementing this
> PR**: the ENTIRE old platform-wide `FrameworkVersion.is_locked` per-row
> additive-lock machinery (`hasLockedVersions()`,
> `fillEmptyLocalesUnderLock()`, `recordLockedFillEmptyLocaleGap()`, and the
> "fix 5b" role-responsibilities fill-empty-only precedent) is deleted by D2,
> not merely the two files this section originally named
> (`SeederLockGuardTest.php`, `LockedFillEmptyLocaleTest.php`). One more file
> exercised the SAME deleted machinery via the SAME `$locked` gate and is
> deleted alongside it: `tests/Feature/Seeders/LockedRoleMetaFillTest.php`
> (its subject, the role-responsibilities fill-empty-only exception under a
> locked `FrameworkVersion`, no longer exists — `FrameworkVersion.is_locked`
> has no bearing on this seeder any more). `tests/Feature/C4/PinLockTest.php`
> was checked and is UNAFFECTED: it exercises `is_locked` only against
> `FrameworkVersion` mutation/deletion guards, never against a seeder
> re-run. The "keep the existing cross-tenant `withoutGlobalScopes()`
> assertions where they still mean something" instruction below turned out
> to have nothing left to keep: the new gate reads only
> `FrameworkCatalogRevision.state` and `Competency.revision_id`, neither of
> which is tenant-scoped or reads `FrameworkVersion` at all.
>
> **A second, larger category of fallout, also undocumented in this file**:
> D2's own wording ("a published revision now accepts NO writes at all,
> additive or otherwise") is not limited to the old `is_locked` machinery —
> it closes a door that was open, unconditionally, for every catalogue test
> in `tests/Feature/Seeders/` that seeds once, edits the source JSON, and
> re-seeds expecting the second run to apply the change. Before this PR that
> was always safe (nothing gated it while no `FrameworkVersion` was locked);
> after this PR the SECOND run is, by construction, a run against an
> already-populated published baseline, and the write gate blocks it. Seven
> files hit this and needed a one-line fix — not a rewrite of their actual
> subject (delete-stale sync, translation-merge semantics, the
> revision-bump predicate, crash-atomicity, gap-fix-triggers-insertion),
> which is unchanged and still correctly proven, but each needed its
> baseline forced to `draft` (the same `DB::table(...)->update(['state' =>
> 'draft', ...])` technique `SeederLockGuardTest`'s own forced-draft
> scenario introduced) immediately before the re-seed that exercises it:
> `RevisionBumpOnMutationTest` (both tests — the no-op case was left
> un-forced initially and passed for the WRONG reason, the gate rather than
> the predicate, before being corrected), `CrashLostRevisionBumpTest`,
> `ItLocaleSeedTest` (first test only), `TranslationSurvivalReseedTest`
> (both tests — same "passing vacuously" risk as above), `DeleteStalePivotTest`,
> `ReseedAfterGapFixTest`. `IdempotentSeedTest` needed a different fix (not
> draft-forcing): its second run is now genuinely blocked, which is
> correctly idempotent for catalogue content, but the write-gate's OWN
> `seeder_lock_guard_active` signal is a real, expected `framework_gaps`
> write on that run — the test now proves idempotence across three runs
> instead of two, with the signal accounted for.

> **PR 1 review-gate landmine, FIXED (was: annotated not fixed, out of PR 1's scope):**
> `api/database/seeders/FrameworkCatalogSeeder.php` resolves natural-key rows
> by CODE ALONE, not by `(revision_id, code)`: `Competency::firstOrNew(['code'
> => $code])` (`:245`) and `Role::firstOrNew(['code' => $roleCode])` (`:307`).
> Safe today — only the baseline revision exists, so `code` is still
> effectively unique platform-wide. The moment this PR's own migration
> ships **and** PR 3's `OpenDraftRevision` clones the catalogue, `code` is
> unique PER REVISION (`UNIQUE(revision_id, code)`, `*_add_revision_to_
> framework_catalog.php`) — TWO rows can legitimately share a code (baseline's
> "ICO" and a draft's own cloned "ICO"), and `firstOrNew(['code' => ...])`
> with no `revision_id` in the lookup binds to WHICHEVER of them Postgres
> happens to return first, silently. Whichever PR touches the seeder next
> (this one) MUST scope every one of these lookups to the seeder's target
> revision (the baseline) before that ambiguity becomes reachable — a
> `Role::where('revision_id', $baselineId)->where('code', $roleCode)
> ->firstOrNew()` shape, not a bare `firstOrNew(['code' => ...])`.

### Phase 6: RED

- [x] 6.1 RED rewrite `api/tests/Feature/C4/Seeder/SeederLockGuardTest.php` against the draft/published pair (not deleted — rewritten): draft baseline still syncs (full delete-stale, as before); published baseline performs **zero writes** (no additive insert, no gap-row update) and emits the `seeder_lock_guard_active`-equivalent structured signal + `Log::warning`; `framework_gaps` and `catalog_meta` are unaffected by the gate either way. — **corrected**: rewritten against the published-but-empty / published-with-content pair, not a draft/published pair (see the fresh-install contradiction annotation above — the baseline is never naturally draft). The "keep cross-tenant `withoutGlobalScopes()` assertions" instruction had nothing left to keep — see the same annotation. Also added `tests/Feature/C4/Seeder/SeederRevisionScopedLookupTest.php` for the landmine fix (task list did not originally name a file for it).
- [x] 6.2 Confirm `api/tests/Feature/C4/Seeder/LockedFillEmptyLocaleTest.php`'s only subject (`fillEmptyLocalesUnderLock()`) will no longer exist post-GREEN — mark the file for deletion in Phase 7, not now (deletion happens once the code it tests is gone). — also identified `tests/Feature/Seeders/LockedRoleMetaFillTest.php` as sharing the same fate (undocumented fallout, see annotation above); marked for deletion alongside it.

### Phase 7: GREEN

- [x] 7.1 Modify `api/database/seeders/FrameworkCatalogSeeder.php` (`:708`): replace `hasLockedVersions()` with `baselineRevisionIsPublished()`. Draft path: existing delete-stale sync runs unchanged. Published path: zero writes; emit the `seeder_lock_guard_active` `FrameworkGap` row and `Log::warning`, kept with their existing kind/shape. — implemented as `resolveBaselineRevision()` + `writesAreBlocked()` (published AND already has content — see the fresh-install annotation above, not a bare `state === 'published'` check) + `baselineHasContent()`. Every natural-key lookup (`Competency`, `Role`, `BarsIndicator` ×2 call sites) scoped to `(revision_id, code|role_id|competency_id|position)` — the landmine fix. The entire old per-row additive-lock branch structure (`if ($locked && $model->exists)`) is removed; content mutation is now a single `if (! $writesBlocked)` per write site, while `framework_gaps`/`catalog_meta` bookkeeping runs unconditionally (D2 exemption).
- [x] 7.2 Delete `fillEmptyLocalesUnderLock()` and `recordLockedFillEmptyLocaleGap()` from `FrameworkCatalogSeeder.php` — the new rule has no partially-writable state, so they exist for nothing now. Also deleted the unused `hasLockedVersions()` method and the now-unused `use App\Models\FrameworkVersion;` import.
- [x] 7.3 Delete `api/tests/Feature/C4/Seeder/LockedFillEmptyLocaleTest.php`. — also deleted `api/tests/Feature/Seeders/LockedRoleMetaFillTest.php` (6.2 annotation).
- [x] 7.4 Run 6.1 GREEN; confirm idempotence and per-role seeded counts (ICO 45, FLL 54, MLL 54, BUL 42, SRX 54) are unchanged against the draft baseline. — run against the published (fresh-install) baseline instead, per the annotation above; counts verified GREEN (`tests/Feature/C4/Seeder/SeederLockGuardTest.php`'s per-role-counts and idempotence tests). `./vendor/bin/pest tests/Feature/C4/Seeder/` — 9/9 passed, 33 assertions.

### Phase 8: Gate

- [x] 8.1 Run the API Verification Commands block. Confirm `scripts/ci-guards.sh` stays green, unmodified — the seeder change is invisible to it by design. — see the apply report's Verification section for verbatim output.

---

## PR 3 — `api`: Draft/Publish Lifecycle, CRUD, Runtime Invariant Twin, `catalogue.manage`

> Base: PR 2 branch. Must not break: `scripts/ci-guards.sh` unmodified; no
> tenant read widens; `AdminTenancySafetyArchTest`. **This PR is the
> ordering-dependency PR** — Phase 8/9 (the twin) MUST be GREEN before Phase
> 10 (CRUD) wires write routes; see the top-of-file note.

### Phase 9: Foundation

- [x] 9.1 Create migration `api/database/migrations/*_add_catalogue_nonblank_locale_checks.php`: `CHECK (anchor_5 ? 'en' AND length(btrim(anchor_5->>'en')) > 0)` × 4 anchor/text fields on `framework_bars_indicators`, and the equivalent non-blank/edge-whitespace CHECK on `framework_roles.name`/`responsibilities` and `framework_competencies.name`/`definition`. — **corrected**: `framework_roles.responsibilities` is deliberately EXCLUDED. `?` is a `jsonb`-only operator; these columns are `json` (2026_07_17 migrations), so every CHECK uses `->>'en'` (`IS NOT NULL AND length(btrim(...)) > 0`) instead, which works identically on either type. Excluding `responsibilities` preserves `FrameworkCatalogSeeder::readLocaleMap()`'s own `$allowBlankEn` sentinel for "not yet authored" (already tested, `tests/Feature/Seeders/GapResolutionTest.php`'s `missing_role_meta` scenario) — a CHECK forbidding it would have broken that already-shipped, still-correct behaviour.
- [x] 9.2 Create `api/app/Actions/Catalogue/OpenDraftRevision.php`: if no open draft exists, clone the latest published revision (~5 roles + 85 competencies + 249 indicators + 83 pivot rows + defaults, one `INSERT … SELECT` per table inside one transaction) into a new `draft` revision; if a draft already exists, continue it. — **corrected**: NOT a literal `INSERT … SELECT` per table, which cannot satisfy the composite FKs (a cloned pivot/BARS/default row must reference the NEWLY inserted role/competency ids, not the parent's). Implemented as an in-memory old-id → new-id map built while roles/competencies are cloned first — same one-transaction, ~450-row shape, correct against the composite FK constraints. Also sets the new `parent_revision_id` column (see design.md's PR3 corrections) so the cross-role duplicate delta check has a concrete parent to diff against.
- [x] 9.3 Create `api/app/Actions/Catalogue/PublishRevision.php`: `SELECT … FOR UPDATE` on the revision row inside the transaction that flips `state`; `violations(FrameworkCatalogRevision): list<array{rule:string, subject:string, detail:string}>` — every blocking check named at once, not the first failure only.
- [x] 9.4 Modify `api/app/Support/Authorization/UserAbilities.php`: add `'catalogue' => ['manage' => $gate->allows('manageCatalogue')]`.
- [x] 9.5 Modify `api/app/Providers/AppServiceProvider.php::boot()`: `Gate::define('manageCatalogue', fn (User $u) => $u->is_superadmin === true)`.
- [x] 9.6 Modify `api/app/Http/Controllers/Auth/AuthController.php::me()`: `@scramble-return` gains the `catalogue` ability group.
- [x] (added, foundation) Migration `*_enforce_catalogue_published_content_immutability.php`: DB trigger refusing INSERT/UPDATE/DELETE on the five catalogue-content tables for a published, NON-BASELINE revision — see design.md's PR3 corrections for why the baseline is deliberately exempt (a blanket rule broke 100+ unrelated pre-existing tests that use the baseline as a generic factory-default bucket).
- [x] (added, foundation) Migration `*_drop_catalogue_revision_defaults.php`: drops the literal `DEFAULT <baseline id>` on `revision_id` for `framework_roles`/`framework_competencies` only (review advisory R3-001) — see design.md's PR3 corrections for why `framework_bars_indicators`/`framework_role_competency` are excluded (measured, not assumed: dropping the BARS default broke 223 tests via dozens of per-file ad-hoc fixture helpers with no shared call site to fix centrally).
- [x] (added, foundation) Migration `*_add_parent_revision_id_to_framework_catalog_revisions.php` — see 9.2's note.

### Phase 10: RED — the invariant twin (before CRUD is wired)

- [x] 10.1 RED `api/tests/Feature/Catalogue/PublishSweepTest.php`: a pair with 2 or 4 indicators, an unanchored competency, a `potential` competency present in the pivot, and a role-scoped MTG/LAT indicator — each refuses publish (422 naming every violation) and leaves `state = 'draft'`.
- [x] 10.2 RED `api/tests/Feature/Catalogue/CatalogueBaselineLiteralCountsTest.php`: 83 role×competency pairs (15/18/18/14/18) and 85 anchored competencies, asserted against the **baseline revision only**, against the database.
- [x] 10.3 RED `api/tests/Feature/Catalogue/CatalogueFormRequestTwinTest.php`: a 6th role, a 4th indicator for a pair, a blank `it` locale value → 422 at the FormRequest layer. — the "default question missing `it`" scenario belongs to PR4's `DefaultQuestionController` (Phase 14/15), not built in this PR; not asserted here.
- [x] 10.4 RED `api/tests/Feature/Catalogue/CrossRoleDuplicateDeltaTest.php`: a duplicate anchor text **new to the revision** is refused, in both directions; an inherited (parent) duplicate publishes fine. — asserted against a minimal manufactured parent/child pair rather than the real `MLL.json:142`/`BUL.json:142` baseline pairs specifically (same rule, proven either way; the manufactured fixture isolates the delta logic from the real catalogue's specific content).
- [x] 10.5 RED `api/tests/Feature/Catalogue/CatalogueAbilityEquivalenceTest.php`: across superadmin/admin/operator/viewer, `allows('manageCatalogue')` is true **iff** a catalogue-write route returns non-403.
- [x] 10.6 RED `api/tests/Feature/Catalogue/CatalogueOpenApi403ContractTest.php`: the generated `openapi.json` declares 403 on **every** catalogue-write operation.

### Phase 11: GREEN — the invariant twin

- [x] 11.1 Create `api/app/Http/Requests/Catalogue/{Store,Update}RoleRequest.php`: refuses a 6th role.
- [x] 11.2 Create `api/app/Http/Requests/Catalogue/{Store,Update}CompetencyRequest.php`, `{Store,Update}BarsIndicatorRequest.php`: refuses a 4th indicator for `(revision, role, competency)`; non-blank `{en,it}` shape validation. Run 10.3 GREEN.
- [x] 11.3 Implement `PublishRevision::violations()` body: `GROUP BY` over the revision's pivot refuses any pair ≠ 3; a pivot row with zero indicators refuses publish; a `potential` competency in the pivot refuses; role-scoped MTG/LAT indicator check mirrors `CI_NON_ROLE_BARS_FILES`; the delta cross-role duplicate check compares against the revision's parent (`parent_revision_id`), refusing only duplicates new to this revision, matched by COMPETENCY/ROLE CODE (not numeric id — a clone's ids differ from its parent's). Run 10.1, 10.4 GREEN. — **review-gate correction**: the first cut only checked indicator counts for ROLE-SCOPED pairs (`whereNotNull('role_id')`) and empty pairs via the PIVOT, so a `potential` competency's own 3-indicator rule (MTG/LAT, no pivot row, `role_id IS NULL`) was never enforced — deleting one of MTG's three indicators and publishing passed the sweep silently. Added `potentialIndicatorCountViolations()`, a LEFT JOIN from `framework_competencies` so a zero-indicator `potential` competency is also caught. Also fixed, same review pass: the content-immutability trigger read the revision's state with a plain `SELECT`, which does not wait for `PublishRevision`'s own `SELECT … FOR UPDATE` lock — a concurrent content write mid-publish could still see `draft` and commit; changed to `SELECT … FOR SHARE`.
- [x] 11.4 Run 10.2 GREEN (literal counts against the baseline revision only — never enforced on every publish, which would refuse the first competency a superadmin ever adds).

### Phase 12: RED + GREEN — CRUD, wired only after Phase 11 is GREEN

- [x] 12.1 Create `api/app/Http/Controllers/Api/Catalogue/{Competency,Role,BarsIndicator,Revision}Controller.php`: every action opens `abort_unless($this->isSuperadmin($request), Response::HTTP_FORBIDDEN);` inline, copied verbatim from `PlatformUserController:87,102` — never a shared helper. Create/update/pre-publish-only-delete, scoped to the open draft revision (`store()` auto-opens one via `OpenDraftRevision` on first edit if none is open). — **scope note**: no `reorder` endpoint and no `framework_role_competency` pivot-management endpoint were built — the task list names exactly these four controllers and neither the design's Interfaces/Contracts section nor its File Changes table names a pivot endpoint; flagged as a real design gap rather than invented. **Review-gate corrections**: `update()` no longer opens a draft at all (only `store()` does) — the target row either already belongs to an existing draft or does not exist to update, and opening a fresh clone first copied ~450 rows only to 404 immediately after, since a newly-cloned row's id can never equal the id in the URL; `UpdateRoleRequest`/`UpdateCompetencyRequest` gained a read-only `existingOpenDraftRevisionId()` counterpart for the same reason. `RevisionController::current()` is READ-ONLY (was auto-opening/cloning on every GET, which broke HTTP safety for a prefetch/retry/monitoring probe). Raw model serialization (`response()->json(['data' => $model])`) replaced with dedicated `Catalogue{Role,Competency,BarsIndicator,Revision}Resource` classes (`api/app/Http/Resources/Catalogue/`) — separate from the existing `RoleResource`/`CompetencyResource`/`BarsIndicatorResource`, which resolve translatable fields to the current locale for the candidate-facing read surface; authoring needs the full `{en, it}` map. Numeric route parameters gained `->whereNumber(...)` so a non-numeric id 404s instead of a 500 `TypeError`.
- [x] 12.2 Wire `PublishRevision` into `RevisionController::publish`; a failing sweep returns 422 with the full violations list.
- [x] 12.3 RED `api/tests/Feature/Catalogue/PublishedRevisionImmutabilityTest.php`: a published revision refuses update, delete, **and insert** — proven at two layers: the CRUD surface 404s (never reaches a published revision — every write is scoped to the open draft), and the DB trigger refuses a raw, Eloquent-bypassing write naming a published revision directly.
- [x] 12.4 Append superadmin catalogue routes to `api/routes/api.php`.
- [x] 12.5 Run 10.5, 10.6, 12.3 GREEN.
- [x] 12.6 Ran `DB_CONNECTION=pgsql php artisan scramble:export`; committed `openapi.json`. **Deliberately did NOT** run `task openapi:sync` / `bun run codegen` in `frontend`/`backoffice` — this session's explicit instructions say "Do NOT sync it into frontend/backoffice ... that happens at release", which supersedes this task's literal wording for this session. Follow-up work before archive.

### Phase 13: Gate

- [x] 13.1 Full Pest suite; confirm `AdminTenancySafetyArchTest` stays green — no tenant read widens; no `organization_id` appears anywhere in this surface. — see apply report for verbatim output.
- [x] 13.2 Run the API Verification Commands block, including `scripts/ci-guards.sh` unmodified. — see apply report.

---

> **GAP FOUND DURING PR 1, CLOSED IN PR3.** No task anywhere assigned
> `framework_versions.revision_id` when a NEW `FrameworkVersion` is created. PR 1's
> backfill stamps every row that existed at migration time, so nothing is null
> today — but a project created after this change ships would pin a version with
> no revision, and `Evaluation → FV → revision → rows` would have nothing to
> resolve. That chain is the entire point of the change. The column is
> deliberately nullable at the end of PR 1 (the baseline is still `draft`, and the
> draft-pin guard would reject every existing creation), so the assignment belongs
> AFTER the baseline is published in PR 3. **Renumbered G1/G2** — the original
> `13.0`/`13.1` numbering collided with this PR's own `13.1` gate task.
>
> - [x] G1 RED `api/tests/Feature/Catalogue/FrameworkVersionPinsPublishedRevisionTest.php`:
>       a newly created `FrameworkVersion` resolves the latest PUBLISHED revision,
>       never null and never a draft; an existing version keeps the revision it was
>       stamped with.
> - [x] G2 Assign the pin on creation wherever `FrameworkVersion` rows are minted
>       (`FrameworkVersion::booted()`'s `creating` listener, `assignLatestPublished
>       RevisionIfUnset()` — fires only when `revision_id` was never set at all, so
>       an explicit caller is never overridden). **Decided, not assumed**: the
>       column STAYS NULLABLE at the DB level rather than becoming `NOT NULL` — a
>       blanket `NOT NULL` would require a default for every creation path,
>       including pre-revision-schema tests that construct a `FrameworkVersion`
>       against the rolled-back schema before the column exists at all, and any
>       environment where migrations ran but no published revision exists yet. The
>       application-level guard is what actually closes the gap in the ordinary
>       path; `NOT NULL` would only forbid legitimate no-revision-yet states this
>       guard does not need to forbid to be correct. One pre-existing test
>       (`FrameworkVersionRefusesDraftRevisionTest`'s "unaffected by the guard"
>       scenario) asserted the OLD gap behaviour (`revision_id` stays null) and was
>       updated to assert the closed-gap behaviour instead.

> **PR 3b — hardening slice, inserted before PR 4 (RDD lineage `review-5a526c3a5a293368`,
> four lenses, approved with 23 non-blocking advisories on PR 1–3).** The findings below are
> correctness or safety defects in the foundation every later PR builds on, so they are fixed
> now rather than carried:
>
> - [x] H1 (R1-001, R3-007) — committed at `24df083`. once a draft is open, every role/competency code exists twice
>       (baseline + draft) and tenant-facing catalogue readers still resolve by code without a
>       revision filter, so live interviews/scoring can read DRAFT content. Scope every reader
>       to the project's pinned revision, or to the latest published revision where no project
>       context exists. Never resolve a draft outside the catalogue authoring surface. —
>       implemented as `App\Support\Catalogue\CatalogueRevisionResolver` (`forProject()`,
>       `forFrameworkVersion()`, `latestPublished()`), consumed by every reader the audit found:
>       `BarsIndicatorLoader::forRoleCompetency()`'s no-argument default now resolves the latest
>       published revision instead of "no filter at all" (callers with a project still pass their
>       own pin explicitly); `SystemPromptComposer::compose()` gained a trailing optional
>       `$revisionId`, threaded through by `InterviewController` (resolved ONCE per `/start`
>       request from the project's own pin, used for the role/competency-by-code lookups at both
>       the opening-greeting site and `composePromptForCompetency()`); `FrameworkController`'s four
>       catalogue-browse actions (no project context — scoped to `latestPublished()`);
>       `ValidatesProjectComposition` (new `compositionRevisionId()` abstract method — `Store
>       ProjectRequest` resolves it from the `framework_version_id` being submitted,
>       `UpdateProjectRequest` from the project's own already-pinned version — and the
>       `competency_ids.*`/`framework_competencies` `Rule::exists` in both FormRequests is now
>       scoped by it, closing the actual gap: an unscoped `exists` accepted a draft's competency id
>       outright); `StoreProjectQuestionRequest`'s `competency_id` exists rule (scoped to the
>       project's own pin); `AdminEvaluationSerializer::indicatorCatalogue()` (scoped to the
>       participant's project's pin); `DemoWriter`/`DemoDatasetValidator` (scoped to the demo's own
>       FrameworkVersion / latest published, respectively). Verified SAFE BY CONSTRUCTION and left
>       unchanged: `ScoreEvaluationJob` and the webhook payload assemblers resolve indicators
>       through a numeric id already bound to a specific revision at project-creation time, never
>       by code — the composite FKs on `framework_bars_indicators`/`framework_role_competency`
>       guarantee a row's `role_id`/`competency_id` and its own `revision_id` always agree, so once
>       a starting id is revision-correct every relation traversed from it is automatically safe.
>       Proof: `tests/Feature/Catalogue/DraftContentIsolationTest.php` (4 tests — FrameworkController
>       browse ×2, live interview via `/start`, project creation) and one added case in
>       `tests/Unit/Services/Admin/AdminEvaluationSerializerTest.php`, each seeding a role/
>       competency/indicator that exists ONLY in a draft (the deterministic shape — a code shared
>       identically between a published and a draft revision can pass or fail depending on
>       incidental Postgres row-scan order, confirmed empirically while writing these tests) and
>       asserting every reader treats it as absent. All 5 new tests confirmed genuinely RED against
>       the pre-fix source (via `git stash` of only the production files) before the fix, GREEN
>       after. **`gga` review-gate corrections (1st pass, before this landed):** the resolver's
>       `forProject()`/`forFrameworkVersion()` silently fell back to `latestPublished()` when a
>       REAL, already-pinned entity carried no `revision_id` — an already-pinned project would then
>       drift onto every later publish, violating CLAUDE.md ruling 3 ("pinned once, never
>       retargeted"). Split into a strict path (`pinnedRevisionOrThrow()` — an existing project/
>       version with no resolvable pin now THROWS, matching `AdminEvaluationSerializer::meta()`'s
>       own posture for the identical failure class) and a graceful path (`tryLatestPublished()`,
>       returning `null` instead of throwing) for callers with no entity to pin against at all.
>       `compositionRevisionId()` (trait + both FormRequests) was calling the STRICT path inside
>       `rules()` — which runs before any input is validated — so an unseeded platform (zero
>       published revisions) 500'd on every project create/update instead of answering the 422 the
>       whole trait exists to produce; changed to `?int`, feeding `Rule::exists(...)->where(
>       'revision_id', null)` / `Builder::where('revision_id', null)`, both of which Laravel
>       converts to `whereNull` — already the correct "match nothing" behaviour on a NOT NULL
>       column, not a special case. `FrameworkController` similarly switched to
>       `tryLatestPublished()` behind an impossible-id sentinel, honouring its own documented "a
>       missing FrameworkVersion MUST return 200" contract instead of 500ing when unseeded.
>       `DemoDatasetValidator`'s scoping was reverted (unscoped, as before this task): it is a
>       pre-write fixture sanity check with no FrameworkVersion to pin against, and scoping it to
>       `latestPublished()` independently of `DemoWriter`'s own `forFrameworkVersion($version)`
>       traded one revision mismatch (draft leakage) for another (validator/writer disagreeing on a
>       top-up run reusing an older-pinned project) — `DemoWriter` gained a fail-loud
>       `RuntimeException` instead for the "role scoped out of existence by the new filter" case,
>       matching the file's own "checked, never assumed" contract. A stray, duplicate docblock
>       immediately above `AdminEvaluationSerializer::indicatorCatalogue()` (pre-existing, orphaned
>       from `serializeCompetencyResult()`'s own copy) was deleted. Added
>       `tests/Feature/Catalogue/DraftContentIsolationTest.php`'s 5th test proving the "zero
>       published revisions" graceful-degradation path (baseline forced to `draft` the same way
>       `SeederLockGuardTest`'s own forced-draft scenario does) never 500s.
>       **`gga` round 2 corrections:** `CatalogueRevisionResolver` split into a throwing family
>       (`forProject()`/`forFrameworkVersion()`, reserved for contexts that may legitimately 500 on
>       a genuine data-integrity failure — `DemoWriter` only) and a non-throwing family
>       (`tryForProject()`/`tryForFrameworkVersion()`/`tryLatestPublished()`, degrading to `null`
>       — never a substitute revision, never a throw). `StoreProjectQuestionRequest`'s `rules()`
>       call switched to the non-throwing path (was calling the throwing one inside `rules()`,
>       same class of 500 the sibling FormRequests' own docblocks explicitly rule out) and its
>       `project()` lookup memoized (was three fresh `findOrFail()` per request).
>       `AdminEvaluationSerializer::indicatorCatalogue()` stopped calling the resolver entirely —
>       it resolves the project's `frameworkVersion` directly and degrades to the existing
>       empty-map fallback, because the resolver's "no context" branch would have substituted
>       "latest published" for an evaluation report, which is the exact ruling-3 drift H1 exists
>       to close, arriving through the wrong door. `InterviewController`'s revision resolution
>       moved BELOW the `assessment_type`/`no_competency_remaining` guards (was pre-empting both
>       with an unrelated failure) and switched to the non-throwing path, with
>       `composePromptForCompetency()` treating a `null` revision identically to "role/competency
>       not found" (`composition_error`, degrading gracefully on RESUME). `BarsIndicatorLoader`'s
>       no-argument default switched to the non-throwing path plus an impossible-id sentinel
>       (matching `FrameworkController::latestPublishedOrSentinel()`'s own pattern) — its declared
>       contract has no `@throws`, and its one caller's `@throws` list does not name this failure.
>       `DemoDatasetValidator`'s scoping was RE-APPLIED (reversing the round-1 revert) using
>       `tryLatestPublished()` — a "lower severity" review note judged the round-1 revert an
>       overcorrection given the non-throwing path costs nothing here; the validator/writer
>       top-up-run mismatch this trades for is documented as a known, accepted, non-tenant-facing
>       gap. **`gga` round 3 corrections:** `AdminEvaluationSerializer::serializeCompetency()`
>       took a bare `int $participantId` and called `Participant::find()` with no
>       `organization_id` filter — `Participant` carries no global scope, so this was a genuine
>       cross-tenant read with no query-level boundary (its one caller's own upstream
>       verification was the only thing making it safe in practice). Changed the signature to
>       accept the resolved `Participant` model instead, and its one caller
>       (`SessionEvidenceReader::forSession()`) now passes `$session->participant` — the SAME
>       org-verified trust chain the session itself was already resolved through, with no second,
>       independently-scoped lookup. Also: `CompetencyResult::indicatorScores()` gained a default
>       `orderBy('position')->orderBy('id')` — `serialize()`'s eager load carried no order while
>       `serializeCompetency()` declared one ad hoc, so the full report and the single-competency
>       session view could render the same three indicators in different orders (a positional-list
>       reshuffle, not a scoring defect — indicator names stay correct, keyed `CODE:position`) — now
>       ordered once, on the relation, inherited by both. All three `gga` rounds' findings were
>       fixed and re-verified (full suite: 3332 passed / 7 pre-existing skips, 0 failed; Pint
>       clean; PHPStan 0 errors) after each round, but the THIRD `git commit` attempt also failed
>       `gga run`, exhausting this session's 3-round retry budget (`sdd-apply`'s own instructions:
>       "max 3 rounds per commit, then stop uncommitted and report"). All H1 changes are staged
>       (`git add`) but NOT committed. No code-quality objection remains open in any reviewed
>       file as of the last round; the next apply session (or a human) should re-run
>       `git commit` directly — `gga run` may pass on a fresh invocation, or the remaining
>       friction may be intrinsic to the review tool's own budget/timeout behavior rather than
>       the code.
> - [x] H2 (R3-008) — `OpenDraftRevision` cloning is untested: prove id remapping for pivot,
>       BARS and default-question rows against a SEEDED baseline, role-less indicators staying
>       role-less, and `parent_revision_id`. — `tests/Feature/Catalogue/OpenDraftRevisionCloningTest.php`.
> - [x] H3 (R3-004, R4 concurrent publish) — `PublishRevision` must re-check the locked row is
>       still `draft` after `FOR UPDATE`; a queued second publish returns a clean 422 (rule
>       `revision_already_published`). Proven with a genuinely separate OS process holding the
>       `FOR UPDATE` lock open — `tests/Feature/Catalogue/PublishRevisionConcurrentPublishTest.php`.
> - [x] H4 (R3-001, R4 open-draft race, G3.4) — `OpenDraftRevision::open()` concurrent first
>       edit: the loser of the one-draft unique index continues the winner's draft. Proven with a
>       genuinely separate OS process via `tests/Helpers/CatalogueRevisionRaceActor.php` —
>       `tests/Feature/Catalogue/OpenDraftRevisionConcurrencyTest.php`.
> - [x] H5 (R3-002) — controllers reuse the draft id the FormRequest validated against, via the
>       now-public `ResolvesOpenDraftRevision::openDraftRevisionId()`. A failed-validation
>       request that CREATED the draft now discards it via the new `DiscardUnusedDraftRevision`
>       (a `content_version` counter, bumped by `BumpsRevisionContentVersion` on every real
>       Eloquent write, distinguishes a genuinely untouched clone from one a concurrent request
>       is already using) — `tests/Feature/Catalogue/CatalogueControllerReusesFormRequestDraftTest.php`.
>       **Evidence gap, deliberate and open (H12):** that discard heuristic is the same shape of
>       race H3, H4 and H6 each close with a separate-OS-process proof, and it is backed here by an
>       ordinary feature test only. Until H12 lands, treat "a concurrent request's draft is never
>       discarded" as argued, not proven.
> - [x] H6 (R3-003) — a DB-level cap of 3 indicators per (revision, role, competency) pair, and
>       per (revision, competency) for role-less potential indicators. A first version used a
>       bare `SELECT count(*)`, insufficient under concurrent writers (READ COMMITTED cannot see
>       a concurrent uncommitted insert); `pg_advisory_xact_lock()` keyed by the exact group
>       closes it, proven with a genuinely separate OS process —
>       `tests/Feature/Catalogue/BarsIndicatorPairCapTest.php`,
>       `tests/Feature/Catalogue/BarsIndicatorPairCapConcurrencyTest.php`.
> - [x] H7 (R3-005) — the immutability trigger also refuses an UPDATE whose OLD row belongs to
>       a published, non-baseline revision — `tests/Feature/Catalogue/PublishedContentCannotBeMovedOutTest.php`.
> - [x] H8 (R3-009) — the CRUD immutability test opens a draft so the draft-scoped
>       `findOrFail` is what produces the 404 — `tests/Feature/Catalogue/PublishedRevisionImmutabilityTest.php`.
> - [x] H9 (R3-010) — publish sweep checks indicators against the pivot (no indicator set for an
>       undeclared pair; no role-less indicator for a standard competency), and a role count
>       check (a gap `CatalogueRules::MAX_ROLES`'s own docblock exposed) —
>       `tests/Feature/Catalogue/PublishSweepUndeclaredPairTest.php`,
>       `tests/Feature/Catalogue/PublishSweepRoleCountTest.php`.
> - [x] H11 (gga on H1) — dead code and an unreachable branch: unused `use App\Jobs\FinalizeInterview;`
>       in `InterviewController` and `use App\Models\Role;` in `StoreProjectRequest` (Pint's
>       `no_unused_imports` misses both because the short names appear in docblock prose);
>       `composePromptForCompetency(?Project $project, …)`'s null branch is unreachable from its
>       only call site; `indicatorCatalogue()` computes `$roleCode` two lines before returning
>       `[]` on that same path. Also hoisted the duplicated lookups in `/start` (opening greeting,
>       `composePromptForCompetency()`'s own competency resolution, and the authored-questions
>       lookup all resolved the identical row independently) into the one `$nextCompetencyRow`
>       lookup, passed through rather than re-queried. **Criterion widened during delivery:** the
>       original ask was hoisting ONE duplicated `authoredQuestionsFor()` call; three lookups were
>       collapsed instead. Recorded so the record shows what was asked and what was delivered.
> - [x] H10 (readability R2-001..R2-008) — stale docblocks (seeder step-5 comment and
>       `resolveOrRecordTranslationGap()`, the "5 migrations" wording in both migration tests, the
>       immutability migration's "CI note below" reference), `App\Support\Catalogue\CatalogueRules`
>       for "3 indicators" and "5 roles", deduplicated the baseline-default mechanism (kept
>       `Role`/`Competency::booted()`'s `creating` listener, removed the factories' own duplicate
>       default) and the controller/FormRequest draft lookup (`FrameworkCatalogRevision::openDraft()`).
>       Two of those are behaviour-touching, not cosmetic: the removed factory default and the
>       shared draft lookup are covered by
>       `tests/Feature/Catalogue/CatalogueControllerReusesFormRequestDraftTest.php` and by the
>       existing factory-driven suites (3369 green, so every path the factory default used to
>       cover is exercised by the `creating` listener instead).
> - [x] H12 — closed by K3 (PR 4b). Proven by closing the underlying race at the WRITE side rather
>       than only widening the discard-on-failed-validation proof: every catalogue-content write
>       now locks the draft revision row (`BumpsRevisionContentVersion::withRevisionLockedForWrite()`)
>       before writing, in the SAME transaction as its `content_version` bump — see K3 below and
>       `tests/Feature/Catalogue/DiscardRaceWithConcurrentWriteTest.php`.
> - Not in 3b: R3-006 is G3; R4-rollback-not-refixable and R4-seeder-silent-noop are accepted
>   under beta and addressed by `catalogue:import` (PR 4, 15.5).

> **REQUIRED BEFORE ARCHIVE — consolidated hardening from the PR 1–4b checkpoint review (RDD
> lineage `review-4d693d11ef9ebd6d`, four lenses, approved with 11 advisories).** Recorded here
> rather than as another inter-PR slice: every checkpoint review runs over the whole cumulative
> diff and will keep surfacing findings, so these are closed together with G3 in one final
> hardening pass before archive.
>
> - [x] Z1 (R3-export-position-loss) — `catalogue:export` reindexes indicators with
>       `array_values`, discarding stored positions; a CRUD-authored set at 1,2,3 exports as 0,1,2 and
>       an export→import round-trip does not preserve positions. Export the stored position. —
>       fixed: `CatalogueExportCommand::indicatorsByCompetencyCode()` now emits each entry's stored
>       `position`; `CompetencyNormalizer::normalizeBars()` reads it back, falling back to array
>       order only when absent (the vendored trees). `api/tests/Feature/Catalogue/CatalogueExportTest.php`
>       (2 new tests), commit `4709a01`.
> - [x] Z2 (R3-responsibilities-missing-en) — `StoreRoleRequest` accepts `responsibilities` with
>       an `it` value and no `en` key; the locale-map invariant requires `en` whenever the map is
>       present. — fixed in the shared `ValidatesLocaleMaps::localeMapRules()` trait (`required_with:{field}`
>       instead of a bare `sometimes` on `.en` when the map itself is optional) — also closes the
>       identical gap on every OTHER FormRequest using `required: false`
>       (`Update{Role,Competency,BarsIndicator}Request`), not only `StoreRoleRequest`.
>       `api/tests/Feature/Catalogue/CatalogueFormRequestTwinTest.php` (2 new tests), commit `4709a01`.
> - [x] Z3 (R1-001) — `ValidatesLocaleMaps` validates the parent map only as `array`, so keys beyond
>       `en`/`it` and non-string values are stored. Restrict the map to known locales and strings. —
>       fixed: the parent field rule now refuses any key outside the declared `$locales` allowlist.
>       `api/tests/Feature/Catalogue/CatalogueFormRequestTwinTest.php` (1 new test), commit `4709a01`.
> - [x] Z4 (R3-validate-then-lock-500) — FormRequest checks (4th-indicator count, position and code
>       uniqueness) run before `withRevisionLockedForWrite` takes the lock and are not re-checked
>       under it; two concurrent stores both pass and the loser 500s on the DB constraint. Re-check
>       under the lock, or map the constraint violation to 422. — fixed via the "map to 422" option:
>       new `App\Support\Catalogue\CatalogueConstraintViolation` maps a recognized DB constraint/trigger
>       violation to the same stable error code the FormRequest layer already uses; wired into
>       `Role`/`Competency`/`BarsIndicator`/`DefaultQuestion` controllers' `store()`/`update()`.
>       Unit coverage plus a genuine 2-OS-process HTTP race proof for the pair-cap case
>       (`api/tests/Feature/Catalogue/BarsIndicatorPairCapConcurrentHttpTest.php`), commit `07391c3`.
> - [x] Z5 (R4-import-bypasses-revision-lock) — `catalogue:import` is the one content writer that
>       does not take the revision-row lock, so a concurrent discard can race it. Route it through
>       the same lock. — fixed: the whole content-writing phase now runs inside
>       `Competency::withRevisionLockedForWrite($draft->id, ...)` (a nested transaction/savepoint),
>       failing closed with `RevisionPublishedDuringWriteException` if the lock unblocks onto a
>       revision no longer draft. Proven with a genuine 2-OS-process race
>       (`api/tests/Feature/Catalogue/CatalogueImportRevisionLockTest.php`), commit `07391c3`.
> - [x] Z6 (R2-publish-violations-spread-contract) — `PublishRevision::violations()` spreads nine
>       helper results and Scramble documents the 422 `violations` as a fixed nine-element tuple.
>       Give it a `list<…>` return shape so the published OpenAPI contract is a list. — VERIFIED
>       ALREADY FIXED (PR8b, 32b.5): both `violations()` and `publish()` already carry an explicit
>       `@scramble-return list<array{rule:string, subject:string, detail:string}>`
>       (`api/app/Actions/Catalogue/PublishRevision.php:39-41,63-79`), and the committed
>       `api/openapi.json`'s `/catalogue/revisions/publish` 422 schema is `type: array, items: {...}`
>       — no `prefixItems` anywhere in the file. No code change needed.
> - [x] Z8 (PR 5 disclosed residual, decided by the orchestrator under the product owner's
>       "the operator's work is sacred" principle) — `ApplyCompetencySelection::restore()` resurrects
>       EVERY trashed row on reselection, including questions the operator deleted on purpose,
>       because nothing records why a row was soft-deleted. Deleting is operator work exactly like
>       writing. Record the cause (e.g. `deleted_by_deselection`) and restore only rows removed by a
>       deselection; an individually deleted question stays deleted. — fixed: new
>       `project_questions.deleted_by_deselection` column, stamped by `softDeleteLive()`'s own bulk
>       soft-delete and CLEARED by `restore()` on the row it brings back (a gga review finding on the
>       first cut: leaving it `true` reopened the bug on a restore→individual-delete→reselect second
>       cycle). `api/tests/Feature/Project/ApplyCompetencySelectionTest.php` (2 new tests, one
>       specifically for the second-cycle case, confirmed genuinely RED against the unfixed code),
>       commit `74c71e8`.
> - [x] Z9 (PR 6 interpretation, decided) — the whole-project interviewability gate applies only
>       at a TRUE first start (no `InterviewSession` anywhere on the project); once an interview is
>       under way, each competency start gates only itself. The alternative re-checked the whole
>       project on every transition and stranded candidates mid-interview. Record this in the
>       `project-config` delta spec as a scenario so the spec states what the code does. — VERIFIED
>       ALREADY IMPLEMENTED in code (`api/app/Http/Controllers/Candidate/InterviewController.php:163-198`,
>       the exact "TWO different gates, deliberately" comment). Added the scenario this task asks for
>       to `openspec/changes/framework-catalogue-authoring/specs/project-config/spec.md` ("Once a
>       participant has any session on the project, a later competency's own emptying gates only
>       itself") — a wrapper-repo edit, not committed from the api session per this session's scope.
> - [x] Z10 (PR 1–6 checkpoint, R3-mint-refuses-midinterview-candidate) — the three mint/enrol
>       ingresses refuse a non-interviewable project unconditionally, while the SSO exchange and
>       `/start` exempt a candidate who already has an `InterviewSession` (Z9). A mid-interview
>       candidate whose token expired therefore cannot be issued a new link. Apply the same
>       exemption at mint for a participant who already has a session. — fixed: new
>       `ProjectInterviewability::evaluateForCandidate()`, wired into `EntryLinkController`,
>       `M2m\SsoLinkController`, `M2m\ParticipantController`. gga review finding, blocking (1st
>       pass): the lookup queried `Participant` (plain `Model`, no tenant global scope) by
>       `project_id` alone — added an explicit `organization_id` filter, with a regression test
>       proving a participant row that disagrees on `organization_id` is ignored.
>       `api/tests/Feature/Interview/InterviewabilityIngressRefusalTest.php` (4 new tests, one
>       confirmed genuinely RED against the pre-fix query), commit `963d8ba`.
> - [x] Z11 (R3-indicator-scores-default-order-aggregate) — the default `orderBy` on
>       `CompetencyResult::indicatorScores()` makes a direct aggregate on the relation fail on
>       Postgres ("must appear in GROUP BY"). Move the ordering to the read sites or use
>       `reorder()` in aggregate paths, with a test. — investigated: a bare `avg()`/`sum()`/`count()`
>       on the relation, and Eloquent's `withAvg()`/`withCount()`, do NOT reproduce this in the
>       installed Laravel 13.20 (both `Builder::setAggregate()` and `QueriesRelationships::
>       withAggregate()` already strip `orders` themselves). The real trap is a HAND-WRITTEN
>       `groupBy()` + `selectRaw('avg(...)')` query built directly on the relation, which neither
>       helper protects — reproduced and fixed with `reorder()`. No current call site hits this (the
>       scoring mean is computed in PHP, not via DB aggregate); added a docblock warning on
>       `indicatorScores()` plus a test proving both the failure and the fix, for the first future
>       caller. `api/tests/Feature/Scoring/CompetencyResultIndicatorScoresAggregateTest.php`, commit
>       `7b39415`.
> - [x] Z12 (R3-draft-orphan-on-post-validation-failure) — a freshly cloned draft is discarded only
>       from `failedValidation()`; a write that fails AFTER validation (409 or any exception)
>       leaves the clone holding the single draft slot. — fixed: `ResolvesOpenDraftRevision::
>       openedNewDraftThisRequest()` made public; each of the 4 catalogue controllers'
>       `store()` gained a `finally` block calling the already-self-guarding
>       `DiscardUnusedDraftRevision::discard()` unconditionally when this request opened a fresh
>       draft — safe on every exit path (success no-ops via `content_version`). Proven via a
>       deterministic reproduction (real `FormRequest::validateResolved()` genuinely clones the
>       draft, then a raw-SQL insert simulates a concurrent writer's already-committed collision,
>       then the real controller method runs) — confirmed genuinely RED without the fix.
>       `api/tests/Feature/Catalogue/CatalogueDraftDiscardOnPostValidationFailureTest.php`, commit
>       `70b0cd1`.
> - [x] Z13 (R2-misleading-exception-name) — `RevisionPublishedDuringWriteException` /
>       `revision_published_during_write` is also thrown when a concurrent discard deleted the
>       draft; name the exception and code for both causes. — fixed: new `RevisionWriteConflictCause`
>       enum (`Published`/`Discarded`), set at the `withRevisionLockedForWrite()` throw site;
>       `errorCode()` returns `revision_published_during_write` or `revision_discarded_during_write`
>       accordingly. Class name kept (renaming touches every catalogue controller catch + the
>       exported OpenAPI 409 shape for no behavioral gain). `api/tests/Unit/Models/Concerns/
>       BumpsRevisionContentVersionCauseTest.php`, commit `2e363b5`.
> - [ ] Z7 (readability) — `NO_PUBLISHED_REVISION = -1` declared twice (loader, FrameworkController);
>       stale comments in `InterviewController` (competency resolution), the drop-defaults migration
>       (pivot `withPivotValue` now exists), `CompetencyResult::indicatorScores()` (serializer ordering
>       removed), and `DemoSeedCommand`'s "here" vs "there" warning.
>
> Added from the PR 1–8 checkpoint review (lineage review-49d7160e052754b0, approved,
> advisories only). R3-ordered-relation-aggregate (`CompetencyResult.php:118`) is Z11.
>
> - [x] Z14 (R4-sso-gate-burns-link) — `SsoExchangeController.php:171-173` consumes the SSO
>       link before the `ProjectInterviewability` 403, so a candidate whose project is later
>       completed can no longer use the link; gate before consuming, with a test. — fixed:
>       reordered so project resolution + interviewability (with its existing InterviewSession
>       exemption) run BEFORE jti consumption; every other gate (entry gates, role_code,
>       participant status) still burns the jti on failure, unchanged, per the class's own "by
>       design" doctrine for those. Proven end to end (refused once, fixed, SAME token succeeds)
>       and confirmed genuinely RED against the pre-fix ordering.
>       `api/tests/Feature/C6/SsoExchange403Test.php`, commit `2e6862f`.
> - [x] Z15 (R4-turn-kind-check-lock) — the `turn_kind` CHECK in
>       `2026_09_16_110000_add_turn_kind_to_utterances.php:33-36` validates under an ACCESS
>       EXCLUSIVE lock; add it `NOT VALID` and `VALIDATE CONSTRAINT` separately. — fixed:
>       `NOT VALID`/`VALIDATE CONSTRAINT` split PLUS `public $withinTransaction = false` — a gga
>       review finding, blocking: Laravel's default single-transaction wrapping holds the SAME
>       lock through both statements regardless of the split, making it a no-op without this (this
>       repo's own `add_provider_session_ref_to_utterances` migration already names the trap).
>       `api/tests/Feature/Migration/UtteranceTurnKindCheckTest.php` (structural guard on
>       `withinTransaction`, confirmed genuinely RED without it, plus constraint-enforcement and
>       `convalidated` tests), commit `99d7a61`.
> - [x] Z16 (R4-utterance-lock-latency) — `UtteranceController.php:114-125` holds the session
>       `FOR UPDATE` across classify-then-insert; keep the critical section minimal and bound
>       it (lock timeout) so a slow write never stalls the live turn loop. — fixed: `SET LOCAL
>       lock_timeout` (2000ms, under the product's own voice-latency NFR) inside the transaction;
>       critical section unchanged (already minimal — lock, one COUNT query, one INSERT); the
>       resulting `55P03` maps to a distinct, retriable 503 `utterance_lock_timeout` instead of
>       the generic 500. Proven with a genuinely separate Postgres session (a second raw PDO
>       connection, no separate OS process needed since the block happens server-side) holding
>       the row lock while the real HTTP request blocks on it; asserted the response times out
>       within a bounded window (confirmed via a mutation test that a wrong timeout value fails
>       the same assertion). `api/tests/Feature/C7a/UtteranceLockTimeoutTest.php`, commit
>       `7ccb974`.
> - [x] Z17 (R3-publish-audit-vacuous) — `PlatformAuditWriterTest.php:204-218` does not
>       prove the `revision.published` row; assert actor, subject and payload. Also
>       strengthen the dashboard-feed assertion at `:242-261` (R3-dashboard-feed-weak). — fixed:
>       the publish test's `if ($response->status() === 200)` wrapper removed (PAWPUB1 is a
>       harmless unassigned competency none of `PublishRevision::violations()`'s checks examine,
>       so publish is always achievable) and now asserts the actual `after` payload
>       (`revision_id`/`label`/`published_at`), not just row existence. The dashboard-feed test now
>       asserts the feed's actual content (exactly the tenant's own participant) instead of a bare
>       200. Discovered and fixed a genuine test-infrastructure trap along the way: authenticating
>       two identities in one test needs BOTH `app('tymon.jwt')->unsetToken()` AND
>       `app('auth')->forgetGuards()` between logins, confirmed via an isolated minimal
>       reproduction, or every later request keeps resolving the FIRST identity regardless of its
>       own Bearer token — the original vacuous test never surfaced this because it never checked
>       WHICH identity answered. commit `0e4e437`.
> - [x] Z18 (R2-001) — readability at `M2m/SsoLinkController.php:27`. — fixed: reordered the
>       comment above `evaluateForCandidate()` so the "single query for one refusal either way"
>       claim sits next to the Z9/Z10 exemption it actually depends on; comment-only, no
>       behavior change. commit `ab49ada`.
> - [ ] Z19 (suggestions, optional) — R1-001 nullable-org migration `down()` with platform
>       rows present; R3 `TurnClassifier.php:128` byte-wise rtrim on multibyte text; R4
>       `CatalogueImportCommand.php:68-74` TOCTOU; R2-002..R2-005. — PARTIAL, this session's
>       assigned scope was the R3 item only: `rtrim()` → `preg_replace('/[.!?,;:。！？]+$/u',
>       ...)` — `rtrim()`'s mask is byte-wise, not multibyte-aware, and corrupts a CJK ideograph
>       sharing a byte value with a multibyte punctuation mark's own bytes (empirically confirmed
>       on `一。`). Regression test via reflection on `normalize()`, since `classify()`'s own
>       containment check corrupts both sides identically and cannot observe the defect on its
>       own. `api/tests/Unit/Interview/TurnClassifierTest.php`, commit `5738b95`. Left unchecked
>       — R1-001 (migration `down()`), R4 (`CatalogueImportCommand.php` TOCTOU) and R2-002..
>       R2-005 remain untouched, outside this session's assigned scope.
> - [ ] Z20 — bump `CONVERSATION_PROMPT_VERSION` in `api/.env.example` and the
>       `config/conversation.php` default together (PR 7 changed the prompt template;
>       `ConversationConfigTest` pins their parity). — BLOCKED: `api/.env.example` is denied by this
>       session's sandbox (Read/Edit tools refuse the path outright), per this session's explicit
>       instructions not worked around. Both sides currently read `conv-2026-09-04` and
>       `ConversationConfigTest`'s own parity test (d) passes as-is — there is no CURRENT drift
>       between the two files, only a version string that needs bumping together (PR 7's template
>       change). Never touched `config/conversation.php` alone, which would break the very parity
>       this test guards. Needs a session with `.env.example` access.
>
> Added from the PR 1–8b api review (lineage review-bf4e5675bd476125, approved) and the
> PR 10–10c backoffice review (lineage review-964fab3e371293be, approved). Repeats of
> Z7/Z11/Z16/Z18/Z19 are not listed again.
>
> - [x] Z21 (R2-discard-closed-claim-overstated) — `DiscardUnusedDraftRevision.php:49-52`
>       docblock claims more than the code guarantees; make it true or make the code match.
>       — fixed: the "every catalogue-content write" claim was false —
>       `ForgetFrameworkLocaleCommand` writes `Role`/`Competency`/`BarsIndicator` rows on ANY
>       revision, including an open draft, through a plain `->save()` that never takes
>       `withRevisionLockedForWrite()`'s lock (verified empirically via a `DB::listen()`
>       lock-query count before touching the docblock). Narrowed the claim to the four catalogue
>       controllers and `catalogue:import` (which do take the lock) and disclosed
>       `ForgetFrameworkLocaleCommand` as a genuine, accepted exception, with the reasoning for
>       leaving it unlocked rather than retrofitting a per-revision lock into its whole-platform
>       iteration shape. Regression test proves both halves: zero lock queries, and
>       `content_version` still bumps via the ordinary `saved` event regardless.
>       `api/tests/Feature/Console/ForgetLocaleCommandTest.php`, commit `1cf8d20`.
> - [x] Z22 (R3-interviewability-rollout-existing-projects) — `ProjectInterviewability.php:117-127`
>       blocks every existing project that has a selected competency with no questions the
>       moment it deploys; ship a backfill (copy defaults) or an explicit reseed step in the
>       release runbook, with a test that proves the backfill. — fixed as an ARTISAN COMMAND
>       (`beai:backfill-project-questions [--org=] [--dry-run]`) run from the release runbook,
>       not a migration: the decision needs `ApplyCompetencySelection`'s own business logic
>       (pinned revision, per-assessment-type cap, restore/no-op/copy branch), which does not
>       belong duplicated into a schema migration, and a migration runs unattended with no room
>       to preview impact first. Exposed
>       `ApplyCompetencySelection::ensureCompetencyHasQuestions()` as a public wrapper over the
>       existing private decision method so the backfill reuses the SAME branches a fresh
>       selection takes — including the Z8 exemption that never resurrects an operator-deleted
>       row — instead of a second, drifting copy. `--dry-run` runs the identical write path
>       inside a transaction it then rolls back, so a preview can never diverge from a real run.
>       A competency whose pinned revision has no catalogue defaults at all is reported by name
>       as "still incomplete" rather than silently left broken — never attempted as a migration
>       (judged unsafe: cross-tenant, business-logic-dependent, unattended, no preview). Tests
>       cover copying defaults, reporting a catalogue-empty competency without erroring,
>       `--dry-run` writing nothing, idempotent re-runs, restoring a deselection-trashed row over
>       a fresh copy, and `--org` scoping. `api/tests/Feature/Console/
>       BackfillProjectQuestionsCommandTest.php`, commit `adf52f2`.
> - [x] Z23 (R3-turn-classifier-substring-false-primary) — `TurnClassifier.php:96-116`
>       substring containment marks a follow-up that quotes the next primary as that primary;
>       tighten the match (e.g. the primary must be the turn's final question) with tests.
>       — fixed: `str_contains()` → `str_ends_with()` — the next unmatched primary must now be
>       the turn's own trailing content, not merely somewhere inside it, closing the false
>       positive where a follow-up only QUOTES the upcoming primary ("we may later ask: :primary.
>       But first...") without actually asking it. Still accepts the retry-apology prefix wrapper
>       (the primary IS the turn's last clause there). The one pre-existing test asserting genuine
>       mid-string containment (primary followed by "Take your time.") tested exactly the
>       false-positive shape this closes, so its fixture lost the trailing filler and now proves
>       the prefix-only wrapper case instead. Regression tests for both the false-positive and the
>       retry case. `api/tests/Unit/Interview/TurnClassifierTest.php`, commit `384ba9b`.
> - [ ] Z24 (backoffice, fixed in the PR 12 branch) — R3-default-questions-no-revision-refresh,
>       R3-role-competencies-silent-detach, R3-indicators-create-test-unproved.
> - [x] Z25 (backoffice, lineage review-10843434416cdd27, approved; fixed in `33fb85a`, `0d4e491`) —
>       R3-default-questions-load-failure-claims-empty (`CatalogueDefaultQuestionsPanel.vue:38-40`:
>       a failed load renders the empty state instead of the error state) and
>       R3-indicator-move-no-inflight-guard (`CatalogueIndicatorsPanel.vue:60-78`: move up/down
>       stays enabled during the multi-request swap, so a double click can race it).
> - [x] Z22b (api, lineage review-a1fd77693a0cc8dc, CRITICAL R4-interviewability-rollout-unrecoverable,
>       corrected in `32e37dc` and validated) — the backfill falls back to the latest published
>       revision's defaults (matched by competency code) when the pinned revision has none.
>       Release runbook: author defaults in a draft → publish → `php artisan
>       beai:backfill-project-questions --dry-run` → run it for real.
> - [x] Z28 (api, same lineage, WARNINGs; fixed in `1a42886`, `662040b`, `5e0f70a`, `a7da2eb`,
>       `df5fd63`, `1855334`, `4b3f426`) — R1-001/R4-audit-rollback-deletes-platform-rows
>       (`2026_09_16_120000_make_audit_logs_organization_nullable.php:43-48`: `down()` refuses
>       with a `RuntimeException` and deletes nothing when a platform row exists, `1a42886`);
>       R3-backfill-includes-soft-deleted-projects (`BackfillProjectQuestionsCommand.php:89-92`:
>       `withoutGlobalScopes()` → `withoutGlobalScope('tenant')`, keeping `SoftDeletingScope`
>       active, `662040b`); R3-import-not-a-sync (`CatalogueImportCommand.php:196-206`: additive
>       by design — `CatalogueImportTest`'s own `--continue` case already asserts a competency
>       added outside the import survives a subsequent import, which a real sync would delete —
>       documented explicitly in the class docblock and `$description` rather than changed,
>       `5e0f70a`); R3-test-pins-500 (`InterviewabilityIngressRefusalTest.php:311`:
>       `ParticipantController::store()` now catches the duplicate-participant `QueryException`
>       inside its own savepoint and returns a clean 409 with a machine-readable `reason`,
>       matching `SsoLinkController`'s own conflict shape; the test now asserts 409, `a7da2eb`);
>       R2-duplicated-controller-scaffolding (`BarsIndicatorController.php:36-41`: left as-is —
>       `RoleController`'s own docblock already documents that hiding `abort_unless()` behind a
>       shared helper previously dropped the 403 from Scramble's OpenAPI output on 3 of 5 routes,
>       `PlatformUserController`'s own docblock corroborates it, so this duplication is
>       deliberate, not an oversight). R3-z4-422-shape-diverges (`RoleController.php:116-130`) —
>       investigated, NOT REPRODUCIBLE: every catalogue CRUD controller's Z4 `QueryException`
>       catch (`RoleController`/`CompetencyController`/`DefaultQuestionController`/
>       `BarsIndicatorController`) returns the byte-identical `{"error": <code>}` 422 shape today,
>       confirmed by direct diff and by `CatalogueDraftDiscardOnPostValidationFailureTest`'s own
>       passing assertion on this exact shape for `RoleController::store()`; no divergence found
>       against HEAD `32e37dc`. Suggestions, all applied: R2-discard-cascade-implicit (documented
>       the FK-cascade chain `DiscardUnusedDraftRevision` relies on, `4b3f426`); R2-duplicated-
>       sentinel (`NO_PUBLISHED_REVISION` moved onto `CatalogueRevisionResolver`, shared by
>       `FrameworkController` and `BarsIndicatorLoader`, `df5fd63`); R2-exception-default-cause
>       (`RevisionPublishedDuringWriteException`'s `$cause` constructor arg is no longer
>       defaulted, `1855334`); R2-factory-docblock-position-claim (`BarsIndicatorFactory`'s
>       docblock corrected — `position` is run-wide unique via `faker->unique()`, not scoped to
>       the (revision, role, competency) group, `4b3f426`). Also fixed, surfaced by `gga` on the
>       R3-test-pins-500 commit: an M2M-supplied `status` reached `Participant::create()`
>       unvalidated, bypassing the candidate lifecycle's `updating`-only transition guard —
>       hardcoded to `in_attesa` on create, `a7da2eb`. Full coverage (94.0%), Pint, PHPStan,
>       `ci-guards.sh`, and a fresh Postgres OpenAPI export (byte-identical, `openapi.json`
>       committed with the 409/`status` schema changes) all verified against the final state.
> - [x] Z22c (api, lineage review-aa64c2e793b3a3ea → recovered as -r1, approved) — CRITICAL
>       R4-interviewability-deploy-cutover corrected in `e23099c`: `interview.interviewability_gate`
>       (`BEAI_INTERVIEWABILITY_GATE`, default on) disables the gate in `ProjectInterviewability`
>       only; fresh selections auto-fill from the latest published defaults. Release runbook:
>       gate off → deploy → author defaults → publish → backfill `--dry-run` → backfill → gate on.
>       Human follow-up: add `BEAI_INTERVIEWABILITY_GATE=true` to `api/.env.example`.
> - [ ] Z29 (api, lineages review-aa64c2e793b3a3ea and -r1, WARNINGs) —
>       R4-utterance-lock-contends-with-end (`UtteranceController.php:140-150`, `/end` waits on
>       the same row lock); R3-turn-classifier-suffix-no-word-boundary (`TurnClassifier.php:127`,
>       suffix match without a word boundary); R2-import-docblock-writes-blocked-claim
>       (`CatalogueImportCommand.php:36-40`); R2-constraint-violation-shape-claim
>       (`CatalogueConstraintViolation.php:22-25`); R3-locked-translation-path-removed
>       (`FrameworkCatalogSeeder.php:240-243`). Suggestions: R3-restore-cap-ignores-live-rows,
>       R4-row-by-row-insert-extends-lock-hold, R3-lock-timeout-test-commits-refreshdb-txn,
>       R3-import-sync-orphans-indicators, R2-pair-cap-literal-duplicated,
>       R2-stale-step-6b-reference, R2-duplicated-catalogue-controller-boilerplate.
> - [ ] Z27 (api) — a catalogue locale value (e.g. a role's optional `it` name) cannot be
>       cleared over HTTP: `ValidatesLocaleMaps` rejects `null`/`''`, and
>       `HasTranslations::setTranslations()` merges, so omitting the key keeps the old value
>       (only `ForgetFrameworkLocaleCommand` can remove a locale). Decide the clear semantics
>       (e.g. `nullable` → `forgetTranslation`), then let `RoleForm.vue:212-219` send it.
> - [x] Z26 (backoffice, lineage review-444ad9407f86043d, approved; the test part fixed in
>       `5e3b0cf`, the RoleForm part moved to Z27 because the API cannot express a clear) —
>       R3-catalogue-page-setdata-script-setup (`tests/unit/pages/catalogue/index.spec.ts:262-280`
>       drives `<script setup>` state through `setData`, which does not reach it; drive the
>       UI instead) and, optional, R3-role-form-cannot-clear-optional-locale
>       (`RoleForm.vue:212-219`: an optional `it` value cannot be cleared once set).

> **DEFERRED 2026-09-17 by the product owner to a dedicated follow-up change** (G3.1–G3.3;
> G3.2's factory and G3.4 are already done). The API already refuses these writes; the
> residual risk is raw SQL or an insert that omits `revision_id`. This block no longer gates
> archiving this change.
>
> **Baseline immutability at the database layer (G3).**
> PR 3's content-immutability trigger (`2026_09_15_201434_enforce_catalogue_published_content_immutability.php`)
> exempts the BASELINE revision, and the literal `DEFAULT <baseline id>` on `revision_id`
> survives on `framework_bars_indicators` and `framework_role_competency`. Together that
> leaves the one revision every already-scored evaluation resolves writable by any raw
> write or any insert that omits `revision_id` — the exact failure PR 1's zero-copy
> design exists to prevent (review advisory R3-001 on PR 1, still open). The exemption
> exists because hundreds of pre-existing tests use the baseline as a scratch fixture,
> which is a test-suite convenience, not a product rule.
>
> - [ ] G3.1 Give the suite a non-baseline scratch revision (fixture/factory state) and
>       migrate tests that write catalogue content off the baseline. — BLOCKED, not attempted:
>       investigated in depth (2026-09-16 api session). The `is_baseline` trigger exemption is a
>       blanket bypass; narrowing it safely (G3.3) needs an EXPLICIT signal — a per-row "is the
>       baseline still empty" check breaks after the seeder's own FIRST content row within one
>       seeding run, because a Postgres trigger fires per-row, not once per logical operation, so a
>       session-scoped GUC set only around the seeder's write phase is the only mechanism found that
>       survives a multi-row seed. Separately, ~46 test files build `Role`/`Competency`/`BarsIndicator`
>       fixtures via the baseline-default model listener (measured via `rg`, not guessed) and would need
>       migrating to a scratch revision once that default stops resolving to a writable baseline; at
>       least one (`api/tests/Feature/Api/PotentialCompetenciesEndpointTest.php`, "driven by TYPE not
>       hardcoded codes") has a scenario fundamentally incompatible with G3's own goal — it adds
>       content DIRECTLY to the published baseline post-seed, which is exactly what G3 exists to
>       forbid — and needs a REDESIGNED scenario (open + publish a second revision), not a mechanical
>       `revision_id` substitution. Attempting this under time pressure risked either leaving the
>       baseline still writable (defeating G3.3) or breaking the then-3480-passing suite. Needs a
>       dedicated follow-up session or an explicit decision on the exemption mechanism.
> - [ ] G3.2 Give `BarsIndicator` a factory; stop constructing it via per-file
>       `forceFill`/raw inserts; drop the remaining `DEFAULT`s. — PARTIAL: `BarsIndicatorFactory`
>       added (`api/database/factories/BarsIndicatorFactory.php`, `HasFactory` wired onto the model,
>       commit `4709a01`), used by this session's own new Z1/Z4 tests via a per-test scratch draft
>       revision. The DB-level `DEFAULT <baseline id>` on `revision_id` is NOT dropped and per-file
>       `forceFill`/raw-insert call sites are NOT migrated — both depend on G3.1/G3.3 first (see G3.1's
>       note); dropping the default before the baseline is genuinely immutable would just move today's
>       DEFAULT-based baseline writes onto a still-writable baseline via the model listener instead.
> - [ ] G3.3 Extend the trigger to the baseline, with the seeder's one-time bootstrap of
>       an EMPTY baseline as the only permitted path (explicit, tested, not a blanket
>       bypass). — BLOCKED, not attempted: see G3.1's note (same investigation, same blocker — the
>       exemption mechanism needs an explicit decision before this can be implemented safely).
> - [x] G3.4 Close `OpenDraftRevision`'s concurrent first-edit race (second caller gets
>       a 500 from the one-draft unique index instead of continuing the draft). — VERIFIED ALREADY
>       FIXED: this is H4 (PR3b), which explicitly names G3.4 in its own title. The loser of the race
>       continues the winner's draft (`api/app/Actions/Catalogue/OpenDraftRevision.php:66-82`,
>       `isOneDraftUniqueViolation()`), proven with a genuine separate-OS-process race
>       (`api/tests/Feature/Catalogue/OpenDraftRevisionConcurrencyTest.php`, confirmed still passing
>       in this session's full-suite runs). No code change needed.

## PR 4 — `api`: Catalogue Default Questions + Export Command

> Base: PR 3 branch. Must not break: published-revision immutability. OQ-B
> (cross-revision "copy from" affordance) is explicitly NOT built here.

### Phase 14: RED

- [x] 14.1 RED `api/tests/Feature/Catalogue/DefaultQuestionCrudTest.php`: a default authored with `en`+`it` text and a position persists and is orderable among that competency's other defaults, scoped to the open draft; a default missing a required locale is rejected (422).
- [x] 14.2 RED `api/tests/Feature/Catalogue/CatalogueExportTest.php`: `Storage::fake()` proves the export command makes zero filesystem writes; it writes only to STDOUT; a published revision's exported JSON round-trips its role×competency×indicator content byte-for-byte.

### Phase 15: GREEN

- [x] 15.1 Create `api/app/Http/Requests/Catalogue/{Store,Update}DefaultQuestionRequest.php`: `{en,it}` both required.
- [x] 15.2 Create `api/app/Http/Controllers/Api/Catalogue/DefaultQuestionController.php`: superadmin-only 403 per action, scoped to the open draft revision.
- [x] 15.3 Create `api/app/Console/Commands/CatalogueExportCommand.php`: `php artisan catalogue:export {revision?}` — writes the split-file JSON shape to STDOUT, takes no path argument at all (no `--dir`, no `--write` mode). Run 14.1, 14.2 GREEN. — implemented as one merged JSON envelope (`roles`/`competencies`/`bars`) since a single STDOUT stream cannot carry the multi-file tree directly; `catalogue:import` (15.5) and the round-trip test split it back into the exact file shape.
- [x] 15.5 Create `api/app/Console/Commands/CatalogueImportCommand.php`: `php artisan catalogue:import --into-draft` — reads the vendored split-file JSON trees (the same shape `catalogue:export` writes), opens or continues the ONE draft revision via `OpenDraftRevision`, and writes the JSON's content into that draft only. It NEVER writes a published revision (the immutability trigger and `writesAreBlocked()` must both stay untouched) and NEVER publishes: publishing stays a separate, reviewable act through `PublishRevision` and its sweep. Round-trip test: export a revision, import it into a draft, and the draft's content equals the source revision's. Refuses cleanly when a draft already holds unrelated edits unless told to continue it. This is the ingress for ruling 6's expert-authored translations now that a published baseline takes no seeder writes. — added a `--path=` testing-only override (default `config('framework_catalog.catalog_path') ?: database_path('framework')`, the same resolution `FrameworkCatalogSeeder` uses) and a `--continue` flag for the dirty-draft refusal; the refusal signal reuses `content_version !== 0`, the same "genuinely untouched" test `DiscardUnusedDraftRevision` already uses. Also added `BumpsRevisionContentVersion` to `FrameworkDefaultQuestion` (a gap the PR3b machinery left open — a draft touched ONLY by a default-question write stayed at `content_version = 0` and looked discardable).
- [x] 15.4 Append default-question routes to `api/routes/api.php`; run `DB_CONNECTION=pgsql php artisan scramble:export` + `task openapi:sync` + `bun run codegen:check` in all three repos. — `scramble:export` run against Postgres and `openapi.json` committed; per this session's explicit instructions, `task openapi:sync`/`bun run codegen:check` into `frontend`/`backoffice` deliberately NOT run this session (same deferral PR3's 12.6 already recorded) — follow-up work before archive.

### Phase 16: Gate

- [x] 16.1 RED then GREEN a threat-matrix test (Git repo selection / push state row, "Applicable — answered by removal"): assert the export command's filesystem-write assertion proves no repository tree is reachable at all. — covered by `CatalogueExportTest.php`'s `Storage::fake()` test, the exact RED test this Threat Matrix row names; no separate file needed.
- [x] 16.2 Run the API Verification Commands block; confirm published-revision immutability holds for default questions the same as for anchors (OQ-2 answered: they freeze with the revision). — `DefaultQuestionCrudTest.php`'s own immutability test proves the CRUD-surface 404 and the DB trigger refusal, mirroring `PublishedRevisionImmutabilityTest.php`.

---

> **PR 4b — hardening slice, inserted before PR 5 (RDD lineage
> `review-9c1fa69c1a9536cc-r1`, four lenses, approved with 15 advisories on PR 1–4).**
> Correctness first, cosmetics last:
>
> - [x] K1 (R3-import-pivot-revision) — `catalogue:import` writes the draft's pivot with
>       `Role::competencies()->sync()`, and `revision_id` is not a pivot attribute, so every newly
>       attached row takes the column DEFAULT (the baseline) instead of the draft. The import can
>       therefore write pivot rows into the PUBLISHED baseline. Fix the write path and prove the
>       draft's pivot belongs to the draft. — fixed via `Role::competencies()->withPivotValue(
>       'revision_id', $this->revision_id)`, guarded for the eager-load "blank instance" case
>       (`Role::with('competencies')` builds the relation against a freshly-instantiated model with
>       no `revision_id` yet — `withPivotValue()` refuses a null value outright, caught by the full
>       suite, not assumed). The actual pre-fix failure mode is a composite-FK violation (23503), not
>       a silent baseline write — the DEFAULT baseline id never matches a draft role's own
>       `(id, revision_id)` pair, so Postgres refuses the INSERT outright; still a genuine defect
>       (the import crashes on any newly-attached pivot pair), just not silent corruption. Proof:
>       `tests/Feature/Catalogue/CatalogueImportTest.php` ("a new pivot attachment written by import
>       lands in the draft, never the baseline").
> - [x] K2 (R3-bars-store-position-500, R3-bars-update-position-500) — POST and PATCH on
>       bars-indicators accept a `position` already taken in the same (revision, role, competency)
>       group, hit the partial unique index and return 500 instead of 422. Same defect class gga
>       already caught on default questions in PR 4; fix both verbs with a draft-scoped
>       `Rule::unique()->ignore()` and cover them. — POST fixed with a closure (mirrors
>       `StoreDefaultQuestionRequest`'s own guarded-closure shape: `competency_id`/`role_id` can each
>       fail their own rule independently, so the check must not assume either is numeric before
>       querying); PATCH fixed with `Rule::unique()->ignore()` scoped to the target row's own
>       `revision_id`/`role_id`/`competency_id`, `whereNull('role_id')` for a role-less indicator.
>       Proof: `tests/Feature/Catalogue/BarsIndicatorPositionUniquenessTest.php`.
> - [x] K3 (R1-001, R4-discard-race-window; widens H12) — `DiscardUnusedDraftRevision`'s race is
>       wider than its docblock claims: a concurrent request that CONTINUES the freshly cloned
>       draft can still read `content_version = 0` between another request's row insert and the
>       separate statement that bumps it, so real saved work can be discarded. Close it (bump in
>       the same statement/transaction as the write, or take the draft row's lock) and prove it
>       with the separate-OS-process actor, then close H12 with it. — closed via
>       `BumpsRevisionContentVersion::withRevisionLockedForWrite()`, a new trait method every
>       catalogue-write controller action (`Role`/`Competency`/`BarsIndicator`/
>       `FrameworkDefaultQuestion` × store/update/destroy) now routes its write through: locks the
>       draft revision row `FOR UPDATE` FIRST, in the SAME transaction as the write and its
>       `content_version` bump. This also closes K8 for free (same lock, same re-check) — a write
>       that unblocks onto a no-longer-draft revision (published OR discarded) throws a new, typed
>       `RevisionPublishedDuringWriteException` (409, machine-readable `error` code) instead of
>       either a silent loss or the content-immutability trigger's own uncaught SQLSTATE 23514.
>       Proof: `tests/Feature/Catalogue/DiscardRaceWithConcurrentWriteTest.php` (separate-OS-process
>       actor, the same shape H3/H4/H6 use, plus a single-process proof the real controller path
>       issues the lock query, plus the write-side refusal).
> - [x] K4 (R3-import-orphan-draft, R4-import-orphan-clone) — `OpenDraftRevision::open()` commits
>       the clone BEFORE the import transaction, so a malformed file leaves an orphan draft
>       occupying the single draft slot. Open the draft inside the same transaction, or discard it
>       on failure. — `open()` is now called INSIDE the same `DB::transaction()` the content writes
>       already run in; a throw anywhere in the import (including from `open()`'s own H4 race
>       recovery, which still works correctly nested — Laravel uses a SAVEPOINT) rolls back the
>       clone together with whatever content had already been written. Proof:
>       `tests/Feature/Catalogue/CatalogueImportTest.php` ("a malformed bars file leaves no orphan
>       draft behind").
> - [x] K5 (R4-loader-default-latest-published) — `BarsIndicatorLoader::forRoleCompetency()` with
>       no revision now reads the latest PUBLISHED revision. Once a non-baseline revision is
>       published, any remaining caller that does not pass a revision silently changes catalogue.
>       Enumerate those callers and make them pass the project's pinned revision (PR 7 wires the
>       interview path; anything else must be named here, not left implicit). — audited via
>       CodeGraph (`codegraph_explore`) plus `rg -n "forRoleCompetency"` across `app/` and `tests/`:
>       there is exactly ONE production call site,
>       `SystemPromptComposer::compose()` (`app/Services/Conversation/SystemPromptComposer.php:100`),
>       and it ALREADY passes `$revisionId` explicitly on every call — never the no-argument
>       default. `BarsIndicatorLoader` itself has no other instantiation site in `app/`
>       (constructor-injected into `SystemPromptComposer` only; `rg -n "new BarsIndicatorLoader"`
>       across `app/` returns nothing). `SystemPromptComposer::compose()` in turn has exactly ONE
>       caller, `InterviewController::composePromptForCompetency()`
>       (`app/Http/Controllers/Candidate/InterviewController.php:770-789`), which resolves
>       `$revisionId` from `CatalogueRevisionResolver::tryForProject($project)` — this IS "PR 7's
>       interview wiring" named by this task, and it was already built and wired during H1 (PR 3b),
>       not deferred. `ScoreEvaluationJob` and the webhook payload assemblers were independently
>       confirmed (H1's own audit, unchanged since) to resolve indicators through a numeric id
>       already bound to a specific revision, never through this loader at all. No production caller
>       reaches the no-argument default; the six `tests/Unit/C8/BarsIndicatorLoaderTest.php` and
>       `tests/Feature/Catalogue/BarsIndicatorLoaderRevisionResolutionTest.php` call sites that omit
>       the argument are deliberately testing that DEFAULT'S OWN behaviour, not production callers
>       needing a fix. No code change required; this entry records the audit result so the "no
>       remaining caller" claim is evidenced rather than assumed.
> - [x] K6 (readability) — stale or contradictory docblocks: the `composePromptForCompetency`
>       comment describing a lookup that moved out; `BumpsRevisionContentVersion` and
>       `DiscardUnusedDraftRevision` listing three models when `FrameworkDefaultQuestion` also uses
>       the trait; the seeder comment claiming translation-gap resolution "proceeds even while
>       writes are blocked" when the same change gates it; the drop-defaults migration claiming the
>       factories were updated to default `revision_id` when they were deliberately not. — the
>       `BumpsRevisionContentVersion`/`DiscardUnusedDraftRevision` docblocks were already corrected
>       as part of K3 (both now name all four models). The other three: `InterviewController`'s
>       `$nextCompetencyRow` comment now says `composePromptForCompetency()` "no longer resolves its
>       own competency at all" instead of claiming it still does; the seeder's per-pair
>       `missing_translation` comment now states the actual split (recording proceeds
>       unconditionally, resolving is gated on `$writesBlocked`) instead of the old, corrected-
>       elsewhere "proceeds even while writes are blocked" line; the drop-defaults migration now
>       attributes the baseline default to `Role`/`Competency::booted()`'s `creating` listener
>       (H10), not the factories, which deliberately do NOT set it (see their own docblocks).
> - [x] K7 (R2-latest-published-duplicated, R2-import-duplicates-seeder-logic) — the "latest
>       published revision" query is copied into four new places, and `catalogue:import`
>       re-declares `POTENTIAL_CODES` and mirrors the seeder's locale-map and indicator-upsert
>       logic. Two readers of the same JSON that must agree forever is the drift this repo keeps
>       paying for: extract one. — `FrameworkCatalogRevision::latestPublished()` is now the ONE
>       "latest published revision" query, mirroring that model's own `openDraft()` precedent;
>       `CatalogueRevisionResolver::tryLatestPublished()`, `OpenDraftRevision::open()`,
>       `CatalogueExportCommand::resolveRevision()`, and
>       `FrameworkVersion::assignLatestPublishedRevisionIfUnset()` all resolve through it.
>       `CatalogueRules::POTENTIAL_CODES` replaces the two identical private constants in
>       `FrameworkCatalogSeeder` and `CatalogueImportCommand`. The seeder's locale-map reader
>       (`readLocaleMap()`/`knownLocales()`) and writer (`setAllLocales()`) — `CatalogueImportCommand`
>       carried a byte-for-byte duplicate of both, its own docblock said so explicitly — are now one
>       shared trait, `App\Support\Catalogue\Concerns\ReadsCatalogueLocaleMaps`, parameterized by a
>       `$sourceLabel` for the one thing that genuinely differed (the error-message prefix). The
>       indicator-upsert logic itself (the `CompetencyNormalizer::normalize()` + per-indicator
>       find-or-new + `setAllLocales()` loop) was NOT further merged: `catalogue:import` already
>       calls the SAME `CompetencyNormalizer` the seeder uses for this exact purpose, so the
>       remaining duplication is orchestration around identical logic, not a second implementation
>       of the logic itself — collapsing it further would couple a seeder-specific method signature
>       to a console command for a marginal readability gain, not close a genuine drift risk.
> - [x] K8 (R4-publish-race-500) — a catalogue `store()` racing a publish waits on the trigger's
>       `FOR SHARE` and then 500s once the publish commits. Return a clean 409/422 instead. —
>       closed as a byproduct of K3's own lock (see K3's note above): a write that unblocks onto a
>       revision no longer in `draft` state (published OR discarded) now throws
>       `RevisionPublishedDuringWriteException`, caught explicitly by every catalogue-write
>       controller action and rendered `409 {error: "revision_published_during_write", message}` —
>       never reaching the content-immutability trigger's own uncaught SQLSTATE 23514. `openapi.json`
>       re-exported against Postgres; every catalogue-write route now documents `409`. Proof:
>       `tests/Feature/Catalogue/DiscardRaceWithConcurrentWriteTest.php` ("K8: a store() request over
>       HTTP refuses cleanly with 409 when the revision was published while it waited for the
>       lock") — a real HTTP request via the separate-OS-process actor (`lock-revision-row`, the same
>       actor `PublishRevisionConcurrentPublishTest` uses), asserting the exact 409 body.

## PR 5 — `api`: `operator_modified`, `ApplyCompetencySelection`

> Base: PR 4 branch. Must not break: the partial unique index
> (`project_questions_position_unique WHERE deleted_at IS NULL`);
> `ProjectQuestionController` and `ProjectQuestionsPanel` behaviour; the cap
> as a ceiling (zero stays legal).

### Phase 17: Foundation + RED

- [x] 17.1 Create migration `api/database/migrations/*_add_operator_modified_to_project_questions.php`: boolean `NOT NULL DEFAULT false`; backfill `true` for every existing row (every row that exists today was typed by an operator).
- [x] 17.2 Modify `api/app/Models/ProjectQuestion.php`: `operator_modified` cast + fillable. — **not fillable, deliberately**: it is set by direct attribute assignment at each write path (`ProjectQuestionController::store()`/`update()`), never through mass assignment, so a request payload can never propose its own provenance value; the model docblock states this explicitly.
- [x] 17.3 RED `api/tests/Feature/Project/OperatorModifiedProvenanceTest.php`: `store` → `true`; `update` → `true` unconditionally, no `isDirty('text')` check; `destroy` → soft delete only, flag untouched; a catalogue-default edit performs **zero** writes to `project_questions` (query-count assertion).
- [x] 17.4 RED `api/tests/Feature/Project/SelectedCompetencyQuestionRuleTest.php`: `StoreProjectQuestionRequest` refuses a question for a competency not currently in `project_competencies` (422) — closes the hole that would otherwise collide on restore.
- [x] 17.5 RED `api/tests/Feature/Project/ApplyCompetencySelectionTest.php`: select → copies ≤ cap, in the defaults' authored order; re-save with the same set → no duplicates; deselect → soft-delete; reselect → operator's own text and `operator_modified` restored untouched, defaults NOT re-copied; reselect with an occupied position slot → renumbered defensively above the current max, no constraint violation. — the occupied-slot case is exercised by calling the action directly against a deliberately corrupted fixture (documented inline as unreachable through the ordinary HTTP flow once 18.2 closes the one known collision path).

### Phase 18: GREEN

- [x] 18.1 Modify `api/app/Http/Controllers/Api/ProjectQuestionController.php`: `store`/`update` set `operator_modified = true`. Run 17.3 GREEN.
- [x] 18.2 Modify `api/app/Http/Requests/StoreProjectQuestionRequest.php`: add the unselected-competency rule. Run 17.4 GREEN. — **required updating 6 pre-existing tests** in `tests/Feature/ProjectQuestions/ProjectQuestionCrudTest.php` that POSTed a question without ever attaching the competency to the project's pivot; added a shared `pqAttach()` helper and called it at each affected call site — a foreseeable, direct consequence of closing the gap, not a design deviation.
- [x] 18.3 Create `api/app/Actions/Project/ApplyCompetencySelection.php`: `apply(Project $project, array $attached, array $detached): void`. Per detached competency: soft-delete live rows. Per attached competency, in order: (1) `onlyTrashed()` rows exist → restore, stop, renumber any restored row whose original position collides with a live row; (2) live rows exist → no-op; (3) otherwise → copy `framework_default_questions` for the competency from `$project->frameworkVersion->revision_id`, ordered by `position`, positions `0..n-1`, capped by `PlatformSettings::maxQuestionsPerCompetency($project->assessment_type)`, `operator_modified = false`. All three branches inside the one transaction the caller already opened. Run 17.5 GREEN. — **gga review correction (1st pass, before this landed)**: the defensive renumber's "next free slot" counter was computed ONCE before the loop and only advanced on a bump, so a second trashed row kept at its own (now-occupied) original position was never accounted for, and the following bump collided with it — a 500 exactly where the docblock promised one couldn't happen. Fixed by recomputing `$next = max(array_keys($occupied)) + 1` from the full occupied set after EVERY row, bumped or not. Same pass also caught that restoring EVERY trashed row unconditionally could resurrect more than the platform cap (an operator's own deleted row and a deselection-soft-deleted row both restoring past the ceiling); `restore()` now caps the number of rows it brings back at `PlatformSettings::maxQuestionsPerCompetency()`, restoring lowest-position-first and leaving the remainder trashed — documented as a disclosed residual, since nothing on a trashed row records WHY it was trashed, so which rows come back past the cap is decided by position alone. Regression proof: `tests/Feature/Project/ApplyCompetencySelectionTest.php` ("two trashed rows sharing the SAME stored position both restore cleanly, capped, no 500").
- [x] 18.4 Modify `api/app/Http/Controllers/Api/ProjectController.php::store` (`:107`): call `ApplyCompetencySelection::apply()` after `attach($attach)`, inside the existing `DB::transaction`.
- [x] 18.5 Modify `api/app/Http/Controllers/Api/ProjectController.php::update` (`:184`): `$changes = $resolved->competencies()->sync($attach)`; call `apply()` with `$changes['attached']`/`$changes['detached']` — the `sync()` return value IS the observation, never a pre-read diff. `updated` is ignored (a position change, not a selection change).

### Phase 19: Gate

- [x] 19.1 Full Pest suite; confirm the partial unique index survives every restore/renumber path; confirm `ProjectQuestionController`/`ProjectQuestionsPanel`-adjacent existing tests are unaffected. — 3411 tests, 3404 passed, 7 pre-existing skips, 0 failed.
- [x] 19.2 Run the API Verification Commands block. — see the apply report's Verification section for verbatim output; `openapi.json` diff empty (no new routes, no response-shape change).

---

## PR 6 — `api`: `ProjectInterviewability`, the Three (Four) Ingress Refusals

> Base: PR 5 branch. Must not break: `GENERIC_403` disclosure doctrine on
> `SsoExchangeController`; in-flight (`in_corso`) sessions never severed; no
> participant/session/webhook created on any refusal path.

### Phase 20: RED — the predicate

- [x] 20.1 RED `api/tests/Feature/Interview/ProjectInterviewabilityTest.php`: a zero-live-question selected competency → not interviewable; all-soft-deleted rows for a selected competency → not interviewable; a deselected competency (no `project_competencies` row) → ignored entirely, out of scope for the check; zero selected competencies → not interviewable (extension beyond the spec's literal wording, per Contradiction 5 — stated, not invented silently).

### Phase 21: GREEN — the predicate

- [x] 21.1 Create `api/app/Support/Project/ProjectInterviewability.php`: `unsatisfiedCompetencyCodes(Project): list<string>`, `isInterviewable(Project): bool`. Built with `DB::table()`, never `ProjectQuestion::query()` — an Eloquent read through `TenantScoped` would fail on the SSO path, which resolves with no ambient tenant. Organization taken from `$project->organization_id`, stated explicitly in the query's `ON` clause, never ambient. `deleted_at IS NULL` in the `LEFT JOIN`, not a `WHERE`. No cache, no `static` memo, no `relationLoaded()` shortcut — resolved from the container at each call site, queried every call. Run 20.1 GREEN.

### Phase 22: RED — the four ingresses

- [x] 22.1 RED `api/tests/Feature/Interview/InterviewabilityIngressRefusalTest.php`: all four ingresses refuse with the exact payloads from the design's interface contract; `candidate_ref` echoed byte-for-byte on the M2M refusal; **no** participant row, no `InterviewSession` row, no webhook fires on the M2M or SSO refusal paths.
- [x] 22.2 RED `api/tests/Feature/Interview/StandingExemptionTest.php`: mint an entry link (or SSO token) while interviewable, then make the project non-interviewable, then use the link/token → still refused at use — the mint-time check is not a standing exemption.
- [x] 22.3 RED `api/tests/Feature/Interview/InFlightSessionSurvivesTest.php`: a candidate with an `in_corso` competency session continues uninterrupted when a *different* competency is emptied; the predicate only blocks a new `/start`.

### Phase 23: GREEN — the four ingresses

- [x] 23.1 Modify `api/app/Http/Controllers/Api/EntryLinkController.php::store` (`:78`): predicate call after `Project::findOrFail`, before `$this->minter->mint(...)`; `422 {"error":"PROJECT_NOT_INTERVIEWABLE","competency_codes":[...]}`.
- [x] 23.2 Modify `api/app/Http/Controllers/M2m/ParticipantController.php::store` (`:64`): predicate after the org-scoped `findOrFail`, **before** `$participant->save()`; same 422 body plus `"candidate_ref"` echoed byte-for-byte from the request.
- [x] 23.3 Modify `api/app/Http/Controllers/M2m/SsoLinkController.php::store` (`:82`): predicate after the org-scoped `findOrFail`, before `mint`; same 422 shape as 23.1.
- [x] 23.4 Modify `api/app/Http/Controllers/Sso/SsoExchangeController.php::exchange`: new Step 6b, after `projectIsAccessible()`, before the Step 9 upsert; `403` with the existing `GENERIC_403` message; `redirect_url` (`$project->error_redirect_url`, nullable) added to **every** 403 branch of `exchange` uniformly (`projectIsAccessible`, `checkRoleCode`, blocked-status, interviewability) — a field present only on this one branch would disclose which gate fired. — implemented as a shared `generic403(Project)` helper every 403 return statement in the controller now goes through, including the post-upsert `$participant === null` defensive branch (not one of the four named gates, but included for the same uniformity reason).
  **gga review corrections**: (1st pass) carries the SAME whole-interview-vs-per-competency exemption as 23.5 — a returning/recovered candidate re-exchanging mid-interview is exempted from the full-project gate once they already have an `InterviewSession` on this project, the existing-participant lookup moved earlier and reused (not a second query) for both the exemption and the Step 8 blocked-status check. (2nd pass) that exemption read used a PLAIN `InterviewSession::where(...)` query — `InterviewSession extends TenantModel`, and this endpoint runs with NO tenant context at all (`->withoutMiddleware(TenantContext::class)`), so the ambient-scoped query silently compared `organization_id IS NULL` and matched zero rows forever, meaning the exemption never actually fired in production. Fixed with `InterviewSession::withoutGlobalScope('tenant')->where('organization_id', $project->organization_id)`, the same shape Step 5's own `Project` resolution already uses on this identical path — the exact trap `ProjectInterviewability`'s own class docblock warns about. Proof, with the `TenantResolver` explicitly cleared before the assertion-bearing call (a resolver left set from fixture setup would mask this exact bug): `tests/Feature/Interview/StandingExemptionTest.php` ("SSO exchange exempts a candidate who already has an InterviewSession from an UNRELATED, not-yet-reached competency losing its question").
- [x] 23.5 Modify `api/app/Http/Controllers/Candidate/InterviewController.php::start`: predicate evaluated only when `InterviewSession::where(participant_id, competency_code)->doesntExist()`; `422 {"error":"project_not_interviewable"}`. — **placement decided, not assumed**: placed AFTER the existing `assessment_type !== 'standard'` guard, not before it. Several pre-existing tests (`InterviewStartCompositionTest.php`'s W1 potential-type cases) assert `assessment_type_not_supported` fires first for a `potential` project with no competency/question fixture at all; interviewability is a property of a `standard` project's competency/question state, and a type the composer does not support at all must still answer that specific refusal first.
  **gga review correction (2nd pass)**: the first cut re-evaluated the WHOLE project on every competency transition, not only on a genuine first start — a candidate finishing competency 1 and moving to competency 2 would be refused solely because competency 5, not yet reached, lost its only question later. Split into two cases: a TRUE fresh start (no `InterviewSession` row exists anywhere yet for this participant+project) gates on the full-project predicate, matching the spec's "a competency emptied of its questions blocks the whole project, not just itself"; once any session already exists on the project, only the competency actually being started gates itself (`unsatisfiedCompetencyCodes()`, not `isInterviewable()`) — an unrelated, not-yet-reached competency's later misconfiguration no longer strands the candidate. Proof: `tests/Feature/Interview/InFlightSessionSurvivesTest.php` ("a NEW competency start is not blocked by an UNRELATED, not-yet-reached competency losing its question mid-interview").
- [x] 23.6 Run 22.1–22.3 GREEN.

### Phase 24: Gate

- [x] 24.1 Full Pest suite; confirm `GENERIC_403` disclosure doctrine unchanged on every `exchange` branch; run the API Verification Commands block (this PR changes response payload shapes on existing routes — re-run `scramble:export`/`task openapi:sync` and diff, even with no new routes). — 3425 tests, 3418 passed, 7 pre-existing skips, 0 failed. `openapi.json` diff is 9 lines (`redirect_url` added to `SsoExchangeController`'s 403 shape); `task openapi:sync` into `frontend`/`backoffice` deliberately NOT run this session, per this session's explicit instructions (same deferral PR3/PR4 already recorded) — follow-up work before archive.
  - **Size exception, recorded explicitly**: this PR's own production diff is ~213 changed lines across 6 files (`ProjectInterviewability` + 5 controllers), inside budget. Wiring the predicate into 4 live endpoints retroactively invalidates an assumption ~30 pre-existing test fixtures across the ENTIRE candidate-facing suite depended on ("a project with no authored questions still mints/exchanges/starts") — the ratified rule (CLAUDE.md, project-config spec) makes that assumption wrong, not the new code. Splitting production from fixture repair into two PRs was rejected: the production-only PR would land with the full suite red, which is not a state any PR in this chain leaves the base branch in. Total diff ~1138 changed lines; `size:exception` applied per the review workload guard's own instruction ("implement it honestly, then report the final authored line count... do not iterate trying to reach the number").

---

> **FOUND DURING PR 3b (gga on H1) — belongs to this PR's model reversal.** In
> `InterviewController`'s authored-opening block the comment says "Only the FIRST is handed
> over. The rest stay in the prompt's must-ask section", but `composePromptForCompetency()`
> receives the FULL list, so the first authored question is spoken as the opening AND sits in
> the prompt's `REQUIRED QUESTIONS` section under "You MUST ask every one of them" — the
> candidate can be asked it twice. The product owner's ratified model ("the avatar asks only
> the questions associated with each competency, no hidden ones, follow-ups are the only
> generated questions") makes this PR the place to fix it: the opening IS the competency's
> first primary, not an extra channel.

## PR 7 — `api`: Composer Budget Reversal, `primary_questions` Snapshot, `TurnClassifier`

> Base: PR 6 branch. Must not break: `prompt_version` stamping; the
> advance-phrase/minimum interaction; `replaceUtteranceStretch`'s
> ref-bounded DELETE. OQ-C (false-follow-up rate) is accepted as an
> unmeasured, disclosed residual — no task here waits on it.

### Phase 25: Foundation

- [x] 25.1 Create migration `api/database/migrations/*_add_turn_kind_to_utterances.php`: `turn_kind` nullable string.
- [x] 25.2 Create migration `api/database/migrations/*_add_primary_questions_to_interview_sessions.php`: `primary_questions` jsonb + `follow_up_budget` int.
- [x] 25.3 Modify `api/app/Models/Utterance.php`: `turn_kind` attribute. Modify `api/app/Models/InterviewSession.php`: `primary_questions` array cast.

### Phase 26: RED — the composer reversal

- [x] 26.1 RED `api/tests/Unit/Conversation/SystemPromptComposerBudgetTest.php`: 1 primary + `follow_up_budget = 4` → the composed prompt states 5 total questions, never 9 (the deleted `$effectiveBudget = $budget + count($authoredQuestions)` arithmetic); `effectiveMinimum()` clamps to `max(1, min($configured, count($primaryQuestions) + $followUpBudget))`; the primaries section grants no latitude to invent, substitute, reorder, or reword a primary. — new file, required a new `Unit/Conversation` Pest binding (`extend(TestCase::class)->use(RefreshDatabase::class)`, `tests/Pest.php`) since no directory binding existed for it.
- [x] 26.2 RED `api/tests/Feature/Interview/SinglePrimariesResolutionTest.php`: `OpeningTextComposer`'s opening question and `SystemPromptComposer`'s primary 1 come from the **same array** — a divergence test that fails if the two queries diverge (proves the dual channel is collapsed).

### Phase 27: GREEN — the composer reversal

- [x] 27.1 Modify `api/app/Services/Conversation/SystemPromptComposer.php::compose()`: new signature per design D7 (`followUpBudget` fed raw to `buildBudgetSection()`, `primaryQuestions` param renamed from `authoredQuestions`, `openingSpokeFirstPrimary` flag); delete the `$effectiveBudget` addition at `:124`; `buildAuthoredQuestionsSection()` → `buildPrimaryQuestionsSection()` with the "complete primary set, asked as written, only latitude is follow-ups" framing; when `$openingSpokeFirstPrimary` is true, state primary 1 was already spoken and continue from primary 2. Run 26.1 GREEN. — `buildPrimaryQuestionsSection()` keeps the FULL numbered list unconditionally (never truncates primary 1 out of it) and only ADDS the "already spoken, continue from primary 2" sentence when the flag is true — the numbered list stays the transcript-facing complete-set record either way.
- [x] 27.2 Modify `api/app/Http/Controllers/Candidate/InterviewController.php`: rename `authoredQuestionsFor()` (`:1386`) → `primaryQuestionsFor()`; call it **once** in `start()` into `$primaries`; `$primaries[0]` → `OpeningTextComposer` (`:295-301`, unchanged in shape); `$primaries` → `composePromptForCompetency()` as a parameter (stops self-loading at `:722`); compute `$openingSpokeFirstPrimary = $openingVariant !== 'resume' && $primaries !== []` at `:272-277`; write `interview_sessions.primary_questions` + `follow_up_budget` in the same request that composed the prompt, never recomputed later. Run 26.2 GREEN. Do not touch `api/app/Services/Conversation/OpeningTextComposer.php` — already correct. — the dual-channel bug the blockquote above PR 7 describes was ALREADY partly collapsed by PR6 (H11 dead-code finding): `primaryQuestionsFor()`/`authoredQuestionsFor()` was already called once into `$primaries`, feeding both composers from the same array. What was still missing, and what this task closes, is `$openingSpokeFirstPrimary` — the two composers agreed on the LIST but not on whether primary 1 had already been spoken, so the full list (including primary 1) was passed to `SystemPromptComposer` unconditionally. `$isReoffer`/`$openingVariant` hoisted above the `composePromptForCompetency()` call (previously computed only afterward, next to `OpeningTextComposer`); `$followUpBudget` hoisted the same way so the SAME number feeds the prompt and the `interview_sessions.follow_up_budget` snapshot. `primary_questions`/`follow_up_budget` are written only inside `createOrResumeSession()`'s `InterviewSession::create()` call — a genuine write-once, since the `UNIQUE(participant_id, competency_code)` constraint routes every RESUME (in_corso or still-pending) to the `UniqueConstraintViolationException` branch, which re-queries the EXISTING row untouched.
- [x] (added, review-adjacent) Renamed `$authoredOpening` → `$firstPrimary` in `start()` and updated its stale docblock ("Only the FIRST is handed over. The rest stay in the prompt's must-ask section, so opening on question one does not consume the others" — no longer true; the full list stays in the prompt either way, distinguished only by the new "already spoken" sentence).

### Phase 28: RED + GREEN — `TurnClassifier`

- [x] 28.1 RED `api/tests/Unit/Interview/TurnClassifierTest.php`: an avatar turn matching the next **unmatched** entry in `primary_questions` under casefold + whitespace-collapse + trailing-punctuation-strip normalization → `primary`; otherwise → `follow_up`. Not a similarity score, not a word list. — required a new `Unit/Interview` Pest binding (`extend(TestCase::class)->use(RefreshDatabase::class)`, `tests/Pest.php`), distinct from the already-bound `Unit/Support/Interview` (different directory, per this task's literal path).
- [x] 28.2 Create `api/app/Support/Interview/TurnClassifier.php`: `classify(InterviewSession, string $text): string`. Run 28.1 GREEN.
- [x] 28.3 RED `api/tests/Feature/Interview/TranscriptAuditTest.php`: primaries marked, follow-ups marked, snapshot matches `project_questions` 1:1 in order; a session ending with `matched < count(primary_questions)` produces a violation, not a silent reclassification (the conservative, over-reporting direction — OQ-C's disclosed residual).
- [x] 28.4 Wire `TurnClassifier::classify()` into both write paths: the live `/utterance` write and the provider harvest (`replaceUtteranceStretch`, `harvestOutgoingTranscript`) — setting `turn_kind` only on `speaker = 'avatar'` rows. Run 28.3 GREEN. — `insertUtterances()` (the ONE method both `replaceUtteranceStretch` and, transitively, `harvestOutgoingTranscript` funnel through) changed from a single bulk `DB::table('utterances')->insert($rows)` to a per-row loop, classifying and inserting one row at a time: `classify()` counts already-persisted `primary`-marked rows, so a bulk insert would classify every avatar row in a multi-turn harvest batch against the SAME pre-batch count, silently misclassifying a genuine second primary as a follow-up. `UtteranceController::store()` (the live path) classifies once, before its existing atomic conditional INSERT, and threads the value through as a new bound column.

### Phase 29: Gate

- [x] 29.1 Full Pest suite; confirm `prompt_version` stamping unchanged; confirm `replaceUtteranceStretch`'s ref-bounded DELETE unchanged; confirm the advance-phrase/minimum interaction (`:100-121`'s ADDITIVE comment) still holds under the new arithmetic. — 3445 tests, 3438 passed, 7 pre-existing skips, 0 failed (`php artisan test --parallel --compact`). See apply report for verbatim output.
- [x] 29.2 Run the API Verification Commands block. — see apply report's Verification section.

---

## PR 8 — `api`: Nullable Audit Org, `PlatformAuditWriter`

> Base: PR 7 branch. Must not break: the dashboard activity feed; tenant
> audit reads (a NULL-org row must stay invisible to every tenant-scoped
> read).

### Phase 30: RED

- [x] 30.1 RED `api/tests/Feature/Catalogue/PlatformAuditWriterTest.php`: every catalogue write and `revision.published` produce exactly one `audit_logs` row with NULL `organization_id`, actor, `before`/`after`; a tenant-scoped read (`TenantScoped` filtering `organization_id = X`) never returns the row; the dashboard activity feed is unaffected. — the "dashboard activity feed" endpoint (`DashboardController::activity()`) reads recently-updated `Participant` rows, not `audit_logs` at all; the assertion proves a platform audit write has no side effect on it (trivially true by construction, since `PlatformAuditWriter` touches only `audit_logs`), which is the literal claim this task names.
- [x] 30.2 RED extend `CrossTenantReaderInventoryArchTest`: files under `api/app/Support/Superadmin/` that write `audit_logs` directly = exactly `{PlatformAuditWriter.php}` — pins the bypass so it cannot grow quietly. — added as a second, separate test in the same file (distinct regex/inventory from the existing `withoutGlobalScopes(` one, which is blind to a raw `DB::table()` write).

### Phase 31: GREEN

- [x] 31.1 Create migration `api/database/migrations/*_make_audit_logs_organization_nullable.php`: `organization_id` becomes nullable; NULL means platform scope. The two composite indexes still lead with `organization_id`.
- [x] 31.2 Create `api/app/Support/Superadmin/PlatformAuditWriter.php`: `DB::table('audit_logs')->insert([...])` — no Eloquent, no global scope to bypass. `action` values: `catalogue.competency.updated`, `catalogue.role.updated`, `catalogue.indicator.created`, `catalogue.default_question.deleted`, `revision.published`, …; `subject_type`/`subject_id` name the row; `before`/`after` restricted to changed attributes; the revision id rides in `after.revision_id`. Run 30.1, 30.2 GREEN. — **also extracted `App\Support\Audit\AuditRedactor`** from the pre-existing tenant-scoped `AuditRecorder` (not separately itemized above, required by design D13's own "subject to this capability's existing redaction ... rules" — `PlatformAuditWriter` and `AuditRecorder` now share the one denylist rather than a second, independently-maintained copy; `AuditRecorder`'s public behaviour is unchanged, it delegates instead of redacting inline).
- [x] 31.3 Wire `PlatformAuditWriter` calls into every catalogue-write controller action (Competency/Role/BarsIndicator/DefaultQuestion controllers) and into `PublishRevision`. — 3 actions × 4 controllers (created/updated/deleted) plus `PublishRevision::publish()`'s `revision.published`, inside the SAME transaction as the state flip.

### Phase 32: Gate

- [x] 32.1 Run the API Verification Commands block. `api` PRs 1–8 complete — every existing scoring test, `ci-guards.sh`, and tenant isolation must all still be green at this checkpoint. — 3455 tests, 3448 passed, 7 pre-existing skips, 0 failed (`php artisan test --parallel --compact`); `ci-guards.sh` exit 0, unmodified; OpenAPI export diff empty (no new routes, no response-shape change). See apply report's Verification section for verbatim output.

---

## PR 8b — `api`: Role×Competency Pivot Authoring

> `catalogue-authoring/spec.md` ("Superadmin CRUD Over Competencies, Roles, And BARS
> Indicators") requires create/update/delete over `framework_role_competency`, but PR 3
> shipped role CRUD with no way to change a role's competency set, so a new role can
> never be made usable. PR 10b surfaced it. Branch `feature/catalogue-role-competencies`
> from `feature/platform-audit`.

- [x] 32b.1 Endpoint(s) to attach, detach and reorder a role's competencies in the open
      draft (draft opened on first write, `withRevisionLockedForWrite`, `content_version`
      bump, `catalogue.manage`), and `CatalogueRoleResource` exposes the role's competency
      set so the backoffice can render it. — implemented as ONE idempotent
      `PUT /catalogue/roles/{role}/competencies` taking the full ordered `competency_ids`
      list (attach/detach/reorder in one `sync()` against the pivot's own `position`
      column — the schema already supports it, per `create_role_competency_table.php`).
      **Corrected, not literally "opened on first write"**: this action targets an
      EXISTING role named in the URL, the exact shape `RoleController::update()`'s own
      review-gate correction (PR3, task 12.1) already resolved — auto-opening a fresh
      draft clone here would copy ~450 rows only to 404 immediately after, since a
      freshly-cloned role's id can never equal the id in the URL. Uses
      `existingOpenDraftRevisionId()` (read-only), matching `update()`/`destroy()`
      exactly. `content_version` is bumped explicitly and ONLY when the set actually
      changed (`sync()` writes through the pivot directly and fires no `Role`
      `saved`/`deleted` event, so the trait's own listeners never see it) — a gga review
      finding on the first commit attempt caught an unconditional bump letting a no-op
      PUT stop `DiscardUnusedDraftRevision` from ever discarding a genuinely untouched
      draft; see `BumpsRevisionContentVersion::bumpRevisionContentVersionForRevision()`.
      `RoleController::index()` eager-loads the relation (a second gga finding: the
      resource's per-role `competencies` read was one query per role, otherwise).
- [x] 32b.2 Rules: a `potential` competency is refused (design.md row `CI_NON_ROLE_BARS_FILES`);
      attach/detach against a published revision is refused like every other write;
      duplicate attach is 422 not 500; composite FKs stay revision-scoped. — a third gga
      finding on the first commit attempt: `array`/`list` are not
      `Validator::shouldStopValidating()` rules, so a non-array `competency_ids` payload
      (a string, `null`) reached the detach-refusal closure and crashed with an uncaught
      `TypeError` under `declare(strict_types=1)` — a 500 for exactly the 422 this
      FormRequest exists to produce. Fixed with an explicit `is_array()` guard; covered by
      a dedicated test.
- [x] 32b.3 Detaching a competency whose pair still has indicators in the draft: refuse
      with 422 naming them (the publish sweep would otherwise report orphans). —
      implemented as a closure rule on `competency_ids` naming the still-anchored
      competency CODES (not raw ids) in the failure message.
- [x] 32b.4 `PlatformAuditWriter` records attach/detach/reorder with before/after. — ONE
      audit row per write (`catalogue.role.competencies.updated`), `before`/`after` each
      the role's full ordered `competency_ids` list — attach, detach and reorder are the
      same one-call diff, not three separate log lines for what the endpoint itself
      treats as one operation. Skipped, like every other catalogue write's audit call,
      when the submitted set exactly matches the current one (no-op PUT).
- [x] 32b.5 Give `PublishRevision::violations()` a Scramble-readable return annotation so
      the generated client models the violations tuple (backoffice `publish-violations.ts`
      currently hand-types it). — `@scramble-return list<array{rule: string, subject:
      string, detail: string}>` added to BOTH `violations()` and `publish()`: Scramble was
      tracing straight into `violations()`'s own body (nine `[...$violations, ...
      $this->someCheck(...)]` concatenations) and modelling it as a nine-slot POSITIONAL
      TUPLE rather than a flat homogeneous list — confirmed by inspecting the committed
      `openapi.json` before the fix (a `prefixItems` array of length 9 for the 422 body)
      and after (a plain `array<{rule,subject,detail}>`).
- [x] 32b.6 Pest (Postgres), PHPStan, coverage ≥ 85%, OpenAPI re-export committed. — see
      apply report's Verification section for verbatim output.

---

## PR 9 — wrapper: `DESIGN.md`, and the "4 fixed" Correction in All Three Documents

> Base: wrapper tracker branch. **Must land before PR 10** — `CLAUDE.md`
> requires `DESIGN.md` updated before any UI code. Resolves Contradiction 7
> (seeder ingress loss under D2) as an explicit note, not silently. —
> **corrected while implementing**: by the time this PR landed, Contradiction 7
> was no longer open to merely note. It is the same issue as OQ-A (design.md's
> "Contradictions surfaced" §7 says so directly: "Left as OQ-A rather than
> invented"), and OQ-A was RESOLVED 2026-09-15 by the product owner
> (`catalogue:import --into-draft`), delivered in PR 4 (tasks.md task 15.5,
> already committed). See 33.8 below for the corrected note.

### Phase 33: Documentation

- [x] 33.1 Update `DESIGN.md` §8.1 sidebar diagram: add `Catalogue ·p`.
- [x] 33.2 Update `DESIGN.md` §8.2 Key Views table: add a Catalogue row (superadmin only, `catalogue.manage`).
- [x] 33.3 Add `DESIGN.md` new §8.2.10: the revision header (state, label, Publish action behind `ConfirmDialog`), the vertical section rail (Competencies · Roles · Indicators · Default questions — **not** a tab strip, per §8.2.1's ruling), and the publish confirmation flow.
- [x] 33.4 Add a `DESIGN.md` §8.2 sentence on the project-questions affordance: the panel stays in the project edit drawer; the drawer gains a named "Questions" section-rail entry; the projects table gains a per-row deep-link action (OQ-3 answered — no relocation).
- [x] 33.5 Correct `CLAUDE.md`'s binding domain constraints: "4 fixed questions" → "up to 4, default 4" for `potential`'s question count. — worded as "up to 4 questions per competency — a platform-configured maximum, default 4" to match the delta spec's `PlatformSettings::maxQuestionsPerCompetency()` framing exactly; `AGENTS.md` is a symlink to `CLAUDE.md`, so no separate edit was needed or made there.
- [x] 33.6 Correct `docs/app_description/02-domain/03-assessment-types.md:23`: the identical correction — the PO confirmed `CLAUDE.md`; this is the same sentence in a second place.
- [x] 33.7 Correct `openspec/specs/interview-conversation/spec.md:25`: the identical correction — the third place. Fixing all three in one PR is the point: this repo has already paid for fixing one of three (`AGENTS.md` drifting from `CLAUDE.md`, an indicator-count guard disagreeing with the spec and the data) twice.
- [x] 33.8 **Corrected, not implemented as originally worded.** This task's original wording ("left as OQ-A, not resolved by this PR or any other in this change") describes a state that no longer held by the time PR 9 was implemented: PR 4 (already committed, per tasks.md's own task 15.5 and the file's top-of-file OQ-A resolution note) delivered `catalogue:import --into-draft`, which is the resolution design.md's "Contradictions surfaced" §7 points at via OQ-A. Writing the originally-specified note here would restate a defect this same file already records as closed — the identical "two documents, one truth" drift `CLAUDE.md` warns about with the `AGENTS.md` symlink and the indicator-count guard. The corrected note, recorded here in place of the stale one: **Contradiction 7 (the seeder loses its only ingress after the baseline is published, and D2 deletes `fillEmptyLocalesUnderLock`) is RESOLVED, not left open** — JSON-authored content reaches a published catalogue via `catalogue:import --into-draft` into a new draft revision, reviewed and published through the backoffice's `PublishRevision` sweep like any other draft edit (PR 4, task 15.5).

### Phase 34: Gate

- [x] 34.1 Confirm PR 9 is merged to the wrapper's tracker branch before any PR 10 branch is created (hard ordering dependency, not advisory). — recorded here; the actual merge-before-PR-10 sequencing is enforced when PR 10's branch is created, not by this task itself.
- [x] 34.2 Confirm `scripts/ci-guards.sh` stays green — this PR touches none of the files it governs.

---

## PR 10 — `backoffice`: `QuestionListEditor` Extraction, `/catalogue` Page

> Base: PR 9 merged + `backoffice` tracker branch. Must not break:
> `ProjectQuestionsPanel`'s existing tests must pass unchanged against the
> refactor (extraction, not rewrite — duplicating 625 lines is this repo's
> named, already-paid-for failure mode).

### Phase 35: Foundation

- [x] 35.1 Run `task openapi:sync` (Postgres, against the merged PR 1–8 `api` state) to pull the merged `openapi.json` into `backoffice/openapi.json`; `bun run codegen`; confirm `bun run codegen:check` green. — done directly against `api`'s `feature/platform-audit` branch (aca1b16, the PR 1–8 state as instructed for this session) rather than the wrapper `task openapi:sync` target, per this session's explicit setup instructions; `bun run codegen:check` confirmed green.

### Phase 36: RED — extraction

- [x] 36.1 RED `backoffice/app/components/organisms/QuestionListEditor.spec.ts`: competency-grouped list, dual-locale `{en,it}` fields, drag reorder, cap display — the extracted presentational core. — confirmed RED (component did not exist) before 37.1.
- [x] 36.2 Confirm `backoffice/app/components/organisms/ProjectQuestionsPanel.spec.ts` (existing suite) is run as-is first, to establish the pre-refactor baseline before extraction begins. — 19/19 green pre-refactor.

### Phase 37: GREEN — extraction

- [x] 37.1 Create `backoffice/app/components/organisms/QuestionListEditor.vue`: extracted from `ProjectQuestionsPanel.vue`'s presentational core (competency-grouped list, dual-locale fields, drag reorder, cap display). Run 36.1 GREEN. — also widened `QuestionList.vue`'s prop type from `ProjectQuestion` to the new shared `QuestionListEntry` (not separately itemized above) so it stays reusable by `CatalogueDefaultQuestionsPanel` in Phase 38.
- [x] 37.2 Modify `backoffice/app/components/organisms/ProjectQuestionsPanel.vue`: becomes a thin container over `QuestionListEditor`. Run 36.2 (the pre-existing suite) GREEN against the refactor, unchanged. — 19/19 unchanged, plus new coverage for remove/reorder-failure/edit-submit paths the extraction exposed as untested. `gga` review (1st pass) found the submit/reorder/remove failure paths collapsed 403/404/409/network into one generic message; corrected to route through the shared `resolveResourceErrorState`/`resourceErrorKey` D4 mapper (same as `load()`), 2nd pass approved.

### Phase 38: RED + GREEN — the catalogue page

- [x] 38.1 RED `backoffice/app/components/organisms/CatalogueDefaultQuestionsPanel.spec.ts`: a thin container over `QuestionListEditor`, revision-scoped (no "copy from revision X" affordance — OQ-B not built). — placed under `backoffice/tests/unit/components/organisms/` per this repo's Vitest `include` glob (`tests/unit/**/*.spec.ts`), same convention as `ProjectQuestionsPanel.spec.ts`; a literal `app/`-colocated spec would never run.
- [x] 38.2 Create `backoffice/app/components/organisms/CatalogueDefaultQuestionsPanel.vue`. Run 38.1 GREEN. — also created `backoffice/app/composables/useCatalogue.ts` and `useCatalogueDefaultQuestions.ts` (not separately itemized above, required for this container and for the page's revision header/publish action) and extracted `backoffice/app/utils/action-error-message.ts` from `ProjectQuestionsPanel.vue`'s own D4 mapping (also not separately itemized — a small DRY refactor to avoid a second copy of the same 403/404/409 distinction this container also needs). Two real API divergences from `ProjectQuestionsPanel`, both driven by the generated client: `POST /catalogue/default-questions` requires `position` (computed client-side, the server assigns none); there is no bulk reorder endpoint for catalogue defaults (PR3's own scope note), so reorder is N individual `PATCH` calls, and on any failure this reloads from the server rather than trusting a local rollback (a partial batch can leave the server ahead of a blind revert).
- [x] 38.3 RED `backoffice/app/pages/catalogue/index.spec.ts`: revision header (state, label, Publish behind `ConfirmDialog`); vertical section rail (Competencies · Roles · Indicators · Default questions), never a tab strip. — placed at `backoffice/tests/unit/pages/catalogue/index.spec.ts`, same Vitest-include reasoning as 38.1.
- [x] 38.4 Create `backoffice/app/pages/catalogue/index.vue`, following `pages/avatar-templates/index.vue`'s shape. Run 38.3 GREEN. — **DESIGN.md ambiguity resolved, noted per this session's instructions**: "following avatar-templates/index.vue's shape" (page scaffolding: custom h1+intro header, no `PageHeader`, `definePageMeta`/`useHead` noindex, `onMounted` load) is read as page-level convention, not a literal second instance of that page's own list layout — the BODY follows §8.2.1's vertical-rail ruling instead, via the same reka-ui `Tabs`/`orientation="vertical"` primitive `/settings/index.vue` already uses, which §8.2.10 explicitly cross-references. **Competencies/Roles/Indicators sections render an honest "not available yet" placeholder, not a read or write surface** — flagged as a real DESIGN.md-vs-design.md/tasks.md gap, not silently resolved: DESIGN.md's descriptive text calls these three "list" shapes, but neither design.md's File Changes table nor this file's own Phase 35–39 breakdown names a single file for a competency/role/indicator list or CRUD component, only `CatalogueDefaultQuestionsPanel`. Building three unrequested read surfaces (own composables, own components, own i18n) was judged the wrong side of that ambiguity to guess on for an already `400-line budget risk: High` PR; the honest placeholder keeps the rail's four-section shape §8.2.10 requires without inventing scope no task names.
- [x] 38.5 RED nav/guard test: the Catalogue nav entry is present only for `catalogue.manage`; direct navigation to `/catalogue` is blocked for a non-superadmin, and the nav entry was never shown to them.
- [x] 38.6 Modify `backoffice/app/components/organisms/SidebarNav.vue`: add `{ to: '/catalogue', labelKey: 'nav.catalogue', requires: 'catalogue.manage', scope: 'platform' }`.
- [x] 38.7 Modify `backoffice/app/middleware/03.abilities.global.ts`: add `catalogue: 'catalogue.manage'` (keyed by first path segment — covers `/catalogue`, `/en/catalogue`, and future children). Run 38.5 GREEN.

### Phase 39: Gate

- [x] 39.1 Modify `backoffice/i18n/locales/{en,it}.json`: every new string, both locales — no hardcoded copy. — `nav.catalogue` plus a new top-level `catalogue` namespace (`sections`, `revision`, `defaultQuestions`); the shared `QuestionListEditor`'s own copy continues to read the existing `projectQuestions.*` keys (unchanged, intentional — the words are project-agnostic, see the component's own docblock).
- [x] 39.2 `bun run typecheck` clean; `bun run test:unit` green; `bun run codegen:check` green in all three repos. — `typecheck`/`test:unit` (151 files, 2130 tests)/`lint`/`codegen:check` all green in `backoffice`; `frontend` and `api` untouched this session (out of PR10's own scope) so their own `codegen:check` was not re-run here — see the apply report.

---

## PR 10b — `backoffice`: Competency, Role and BARS Indicator Authoring Sections

> The original request was superadmin CRUD for competencies, roles, BARS indicators AND
> default questions. The API side shipped in PR 3 (`/catalogue/competencies`, `/roles`,
> `/bars-indicators`, `/revisions/current`, `/revisions/publish`), but Phases 35–39 named
> only `CatalogueDefaultQuestionsPanel`, so PR 10 rendered the other three rail sections as
> placeholders. This PR closes that planning gap on the same `feature/catalogue-authoring`
> branch. DESIGN.md §8.2.10 already describes the three sections as list shapes.

### Phase 39b: Sections

- [x] 39b.1 `CatalogueCompetenciesPanel` — list the open/current revision's competencies
      (code, bilingual name/definition, potential flag if the contract exposes it); create,
      edit, delete through `/catalogue/competencies`, delete behind `ConfirmDialog`. —
      `type` (`standard`/`potential`) is the exposed potential flag; name shown in the
      operator's own UI locale, falling back to English.
- [x] 39b.2 `CatalogueRolesPanel` — list roles with their competency set; create, edit,
      delete, and edit the role→competency assignment through `/catalogue/roles`. —
      **contract gap, not built as written**: neither `CatalogueRoleResource` nor
      `StoreRoleRequest`/`UpdateRoleRequest` carries a competency list or a
      `competency_ids` field at all (verified against `types/api.ts` and the api source,
      `RoleController::store()`'s own docblock: "no ... pivot-management endpoint were
      built" — the same PR3 scope note task 12.1 already recorded). There is nothing to
      read or write for "competency set" / "role→competency assignment" through this
      contract. Built code/name/responsibilities CRUD only; `RolesPanel`'s own
      `assignmentNote` states the gap to the superadmin rather than hiding it. Session
      instructions say STOP and report a contract gap rather than invent — this is that
      report, not a silent narrowing.
- [x] 39b.3 `CatalogueIndicatorsPanel` — per competency, its BARS indicators with the
      `{5, 3, 1}` anchors in both locales; create, edit, delete, reorder through
      `/catalogue/bars-indicators`. The UI never lets a published revision drop below the
      exactly-3-indicators rule silently: surface the publish sweep's violation instead. —
      grouped by competency then by role/competency pair; reorder is Move up/down buttons
      (not drag), each a 3-step PATCH dance per swap (`UpdateBarsIndicatorRequest`
      validates `position` uniqueness per-request, same collision class
      `CatalogueDefaultQuestionsPanel`'s own reorder already works around). Delete never
      blocked client-side even below 3 — the sweep is what refuses publish, per this
      task's own wording.
- [x] 39b.4 Replace the three placeholders in `pages/catalogue/index.vue`; the first write
      against a published revision opens a draft (header reflects it) exactly as the
      default-questions panel does. — each panel's write paths emit `refresh-revision`,
      reloaded by the page.
- [x] 39b.5 Publish refusal (422) names the violated rules — render
      `PublishRevision::violations()`'s tuple shape instead of a generic banner. —
      `extractPublishViolations()` (`app/utils/publish-violations.ts`) parses the 422 body
      defensively (the generated `PublishRevisionViolationsResponse` type mismodels the
      real wire shape — see that file's own docblock for the exact tuple evidence); rule
      name translated where copy exists, `subject`/`detail` shown verbatim and monospaced
      (server-computed diagnostic locators, not authored copy, same treatment DESIGN.md
      already gives BARS transcript excerpts).
- [x] 39b.6 Types only from the generated client; D4 error states on every failure path;
      it/en for every string; Vitest for each panel; typecheck, lint, test:unit,
      codegen:check green. — one narrow, documented exception:
      `PublishViolation`/`extractPublishViolations()` (39b.5's note above) is hand-typed
      against `PublishRevision.php`'s own `@return` PHPDoc because the generated type
      cannot express the real shape; every other request/response type in this PR10b
      slice derives from the generated client. `bun run typecheck`/`lint`/`test:unit`/
      `codegen:check` all green — see the apply report's Verification section for
      verbatim output.

---

## PR 10c — `backoffice`: Role Competency Assignment

> Depends on PR 8b. Same `feature/catalogue-authoring` branch.

- [x] 39c.1 Sync `openapi.json` + codegen from PR 8b. — pulled from `api`'s
      `feature/catalogue-role-competencies` (commit 8d80ebf); `codegen:check` green
      against the live `../api` checkout.
- [x] 39c.2 `CatalogueRolesPanel` edits a role's competency set (attach, detach, reorder);
      replace the "not supported yet" notice; detach refusal (32b.3) shows the named
      indicators. — new `RoleCompetenciesForm.vue` (a second `FormDrawer` per row,
      `useCatalogue().updateRoleCompetencies`), one idempotent PUT per save; the save
      is confirmed only when it would detach an already-assigned competency (adding/
      reordering never destroys anything already in the draft); the 422 detach refusal
      is rendered verbatim via `translateServerCode`'s raw-value fallback, same
      "server-computed diagnostic" treatment DESIGN.md gives publish violations.
- [x] 39c.3 `publish-violations.ts` uses the generated violations type instead of its
      hand-written one. — the api's OpenAPI model for the publish 422 body was fixed to
      the real flat `array<{rule, subject, detail}>` shape by 39c.1's sync, so
      `PublishViolation` is now `PublishRevisionViolationsResponse['violations'][number]`;
      the 39b.5 hand-written exception is gone.
- [x] 39c.4 Vitest, typecheck, lint, codegen:check green; it/en for every string. — 160
      test files / 2226 tests, `bun run typecheck`/`lint`/`codegen:check` all green; every
      new `catalogue.roles.competencies.*`/`catalogue.serverError.*` key present in both
      `en.json`/`it.json` (verified programmatically, not just by inspection).

---

## PR 11 — `frontend`: `[token].vue` Consumes `redirect_url`

> Base: `frontend` tracker branch, after PR 6 (`api`) is merged. Must not
> break: the 401 spent-link branch; the null fallback to
> `/interview/terminal?reason=403`. Resolves Contradiction 1 — `frontend`
> IS touched, contrary to the proposal's "not touched" claim.

### Phase 40: RED

- [x] 40.1 RED `frontend/tests/unit/pages/interview-token.spec.ts` (extend): a `403` response carrying `redirect_url` navigates there via `useExitRedirect`'s existing `redirectTo` safety rules; a `403` with `redirect_url: null` falls through to `/interview/terminal?reason=403` (today's shipped behavior becomes the null case, not a replacement); the existing 401 spent-link branch is unaffected. Extended in place in the existing `frontend/tests/unit/interview-entry.spec.ts` (the real, already-existing test for this page — `tests/unit/pages/interview-token.spec.ts` does not exist in this repo).
- [x] 40.2 RED a threat-matrix test (process integration / external routing row): a project with a `javascript:` or relative `error_redirect_url` value never reaches navigation.

### Phase 41: GREEN

- [x] 41.1 Modify `frontend/app/pages/interview/[token].vue:110-112`: the 403 branch reads `redirect_url` and routes through `useExitRedirect`'s existing safety rules. Run 40.1, 40.2 GREEN — `error_redirect_url` is already `url`-validated and length-bounded at the FormRequest layer (`Store/UpdateProjectRequest`), so 40.2 should already pass; add coverage if the existing rules do not already reject unsafe values. Implemented via a new `app/utils/safe-redirect.ts` (`safeExternalRedirect`) applying the same https-only/well-formed rule as `useExitRedirect`'s internal `redirectTo`, rather than exporting `redirectTo` from `useExitRedirect.ts` itself — see apply-progress for why.

### Phase 42: Gate

- [x] 42.1 `bun run typecheck` clean; `bun run test:unit` green.

---

## PR 12 — `backoffice`: Playwright E2E

> Base: PR 10 branch. No production code in this PR.

### Phase 43: E2E

- [x] 43.1 `backoffice/tests/e2e/catalogue-edit-publish.spec.ts` (chromium + webkit): superadmin edits an anchor, publishes, sees it frozen (a subsequent write attempt to the published revision is refused); an org admin gets no nav entry and is blocked on direct navigation to `/catalogue`. — also covers, in the same file, competency create/edit/delete behind `ConfirmDialog`, role competency assignment including the detach confirmation, BARS indicator create, and a publish 422 rendering the full violations list (translated rule name + raw fallback). A default-question write auto-opening a draft is covered in its own `describe` block in the same file, exercising the Unit 1 `refresh-revision` fix end to end. The project edit drawer's predefined-questions panel (post-`QuestionListEditor`-extraction regression proof) is covered separately in `backoffice/tests/e2e/project-questions-panel.spec.ts` — a `/projects` concern, not a `/catalogue` one, kept out of this file for that reason.
- [x] 43.2 **Not implemented as a standalone `catalogue-unsupported-gate.spec.ts`.** `playwright.config.ts`'s `mobile` project restricts `testMatch` to `unsupported-gate.spec.ts` only (documented in that file's own comment on why `/clients` was added there rather than in `clients.spec.ts`) — a scenario living only in a new file would never actually run under the `mobile` project. `/catalogue` added to that file's existing `ADMIN_ROUTES` list instead, the same already-`mobile`-covered mechanism `/clients` uses; confirmed green under the `mobile` project.

### Phase 44: Gate

- [x] 44.1 Full Playwright suite green across chromium, webkit, and the mobile project. — `bunx playwright test` (all specs, all 3 projects): 261 passed, 0 failed.
- [x] 44.2 **Partially confirmed, scope stated rather than assumed.** This session's scope was the `backoffice` repo only (PR 12), so only the criteria observable from it were re-verified end-to-end: superadmin CRUD over competencies/roles/indicators/default-questions, org admin 403 + no nav entry, publish freezing a revision (a subsequent write refused), the mobile `/unsupported` redirect, and every string used by the new specs resolving in `en`/`it` (existing catalogue locale keys, unchanged by this PR). `bun run codegen:check` confirmed green in `backoffice` only — `frontend`/`api` were not touched this session, matching PR10's own task 39.2 precedent for the same scope boundary. The API-side/cross-repo criteria (byte-identical anchor resolution across the migration, audit-log entries, the DB-level literal counts, `scripts/ci-guards.sh`) are outside this session's repo scope and were not re-run here.
