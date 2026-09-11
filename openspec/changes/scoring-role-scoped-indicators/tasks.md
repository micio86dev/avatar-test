# Tasks: Role-Scoped (and Potential-Aware) BARS Indicator Loading in Scoring

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~170 + ~250 + ~110 + ~90 + ~380 ≈ 1,000 total, ≤400 per slice |
| 400-line budget risk | Low per slice; High if 1a+1b are combined |
| Chained PRs recommended | Yes |
| Suggested split | PR 1a → PR 1b → PR 2 → PR 3 → PR 4 (separate feature/*) |
| Delivery strategy | auto-chain |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Low per slice; High if 1a+1b are combined

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1a | Shared role-optional loader moved to `FrameworkCatalog`, zero behaviour change for C8 | PR 1a (base: `feature/scoring-role-scoped-indicators`) | `php artisan test --parallel --filter=BarsIndicatorLoaderTest` | Real PostgreSQL (RefreshDatabase) — the `whereNull` trap is unprovable against a double | Revert: prior `Conversation\BarsIndicatorLoader` returns, `SystemPromptComposer` import reverts |
| 1b | Scoring pipeline resolves role and consumes the shared loader; sentinel removed | PR 1b (base: PR 1a branch) | `php artisan test --parallel --filter=RoleScopedIndicatorsTest` | FakeLLMProvider + C9Fixtures, real PostgreSQL | Revert: `ScoreEvaluationJob` returns to competency-only query; PromptBuilder regains `$roleId` param |
| 2 | Arch guard forbidding competency-only `BarsIndicator` query, with self-tested matcher | PR 2 (base: PR 1b branch) | `php artisan test --parallel --filter=BarsIndicatorRoleScopeArchTest` | N/A — static source scan, no runtime scenario | Revert: delete the guard test file; no production code affected |
| 3 | Spec deltas: scoring-engine + interview-conversation (reverse RV-2) | PR 3 (base: PR 2 branch) | N/A — docs-only; validated by SDD artifact review | N/A — no code | Revert: spec files only, no code coupling |
| 4 | `beai:purge-miscored-evaluations` — destructive remediation, separate `feature/*` off `develop` | PR 4 (independent branch, NOT chained to 1a-3) | `php artisan test --parallel --filter=PurgeMiscoredEvaluationsTest` | Dry-run against a seeded corrupt fixture + real PostgreSQL; NEVER against production data in this phase | NOT revertible once run live — see Slice 4 rollback note below |

## Git Flow

Branch: `feature/scoring-role-scoped-indicators` off `develop` (NOT `hotfix/*` off `main`).
Rationale (per design): ~420 lines for the correctness fix (1a+1b), a cross-namespace
class move, a public signature change on `PromptBuilder`, and a touch to
`SystemPromptComposer.php` which `db-driven-conversation-prompts` also owns — a hotfix
diff cannot be made smaller without a second inline query, which this change forbids.
Slice 4 (purge) ships on its own `feature/*` off `develop`, independent of 1a-3.

Urgency is answered operationally, not by branch type: **pausing scoring dispatch
needs no code** (hold `ScoringRequested` / stop the queue worker) — this prevents new
corrupt evaluations while 1a-3 go through the ordinary release gate.

---

## Phase 1a: Shared Role-Optional Loader (PR 1a, base: `feature/scoring-role-scoped-indicators`)

- [x] 1a.1 RED — `tests/Unit/FrameworkCatalog/BarsIndicatorLoaderTest.php`: role-scoped call (`forRoleCompetency($roleId, $competencyId)`) returns exactly the 3 rows where `role_id = $roleId`, none from other roles (real PostgreSQL, RefreshDatabase).
- [x] 1a.2 GREEN — create `app/Services/FrameworkCatalog/BarsIndicatorLoader.php` with `forRoleCompetency(?int $roleId, int $competencyId): Collection`; `where('competency_id', $competencyId)->where('role_id', $roleId)` branch only (whereNull comes in 1a.4).
- [x] 1a.3 RED — same test file: passing `$roleId = null` for a role-scoped pair (sanity — must return zero rows, proving no accidental fallthrough).
- [x] 1a.4 GREEN — add explicit `whereNull('role_id')` branch: `$roleId === null ? $query->whereNull('role_id') : $query->where('role_id', $roleId)`. Never `where('role_id', null)`.
- [x] 1a.5 RED — potential-type scenario: `forRoleCompetency(null, $mtgCompetencyId)` returns exactly the 3 role-less MTG rows seeded by `FrameworkCatalogSeeder::seedPotentialIndicators()`.
- [x] 1a.6 RED — order scenario: repeated loads of the same `(roleId, competencyId)` return an identical, reproducible total order.
- [x] 1a.7 GREEN — `orderBy('position')->orderBy('id')` (mirrors `scoring-engine/spec.md:244-246`); document the id tiebreaker as unreachable-while-constraints-hold, not load-bearing today.
- [x] 1a.8 RED — unanchored pair scenario: a `(roleId, competencyId)` pair with no catalogue rows returns an empty collection (no exception).
- [x] 1a.9 Delete `app/Services/Conversation/BarsIndicatorLoader.php` (moved, not duplicated).
- [x] 1a.10 Modify `app/Services/Conversation/SystemPromptComposer.php`: replace the import with `use App\Services\FrameworkCatalog\BarsIndicatorLoader;` — exactly one `use` line, no alias (coordinate with `db-driven-conversation-prompts`; whoever lands second rebases the single import line).
- [x] 1a.11 Register the moved test directory in `tests/Pest.php` if required by directory-based config binding.
- [x] 1a.12 Verify: `php artisan test --parallel --filter=BarsIndicatorLoaderTest` green; `php artisan test --parallel --filter=SystemPromptComposer` green (C8 behaviour unchanged, int still passes through `?int`).
- [x] 1a.13 Run `./vendor/bin/pint --test` and PHPStan on changed files.

## Phase 1b: Scoring Pipeline Consumes the Shared Loader (PR 1b, base: PR 1a branch)

- [x] 1b.1 RED — `tests/Feature/Jobs/RoleScopedIndicatorsTest.php`: per role (ICO/FLL/MLL/BUL/SRX) scenario — pinned role X + competency → exactly 3 rows, all `role_id = X`, none from the other four roles reach `EvaluationParser`.
- [x] 1b.2 GREEN — in `ScoreEvaluationJob::runScoringPipeline()`, resolve `?int $roleId` immediately after `$project` loads (before the competency loop): `role_code` null → `roleId = null` (legal, potential); `role_code` set + `Role` found → `(int) $role->id`; `role_code` set + `Role` NOT found → abort (log + return, no writes, mirroring the existing `project === null` arm) — must NOT fall through to null.
- [x] 1b.3 GREEN — replace the inline competency-only `BarsIndicator` query with `BarsIndicatorLoader::forRoleCompetency($roleId, $competencyId)`; remove the false "indicators are shared across roles" comment and its `TODO(PR3)`.
- [x] 1b.4 RED — `PromptBuilder` scenario in `tests/Unit/Services/PromptBuilderTest.php`: `build()` called without a `$roleId` argument; rubric renders exactly the 3 passed indicators.
- [x] 1b.5 GREEN — delete the `int $roleId` parameter (position 4) and its docblock line from `PromptBuilder::build()`; remove the `roleId: 0` sentinel call site in `ScoreEvaluationJob.php:605`.
- [x] 1b.6 RED — potential-type scenario in `RoleScopedIndicatorsTest.php`: `potential` project scoring MTG and LAT → `role_id IS NULL` rows reach the parser (via `whereNull`, never `where('role_id', null)`) — run against real PostgreSQL (unprovable against a double per design D4).
- [x] 1b.7 RED — reliability-domain regression: `competency_results.reliability` for a scored competency is only ever `{0, 1/3, 2/3, 1}` (as the literal decimal strings `'0.0000'`, `'0.3333'`, `'0.6667'`, `'1.0000'`); assert `0.4` (5-15ths) is never producible. Cheapest guard against this exact defect returning.
- [x] 1b.8 RED — D6 arm scenario: 3 indicators pinned, `FakeLLMProvider` returns a behaviors array of a different length → `EvaluationParser` throws `IndicatorCountMismatchException` → `ScoreEvaluationJob` persists `CompetencyResult(unscorable_reason: llm_parse_error)`, records one `ai_requests` row with `failure_reason: indicator_count_mismatch`, does NOT queue-retry.
- [x] 1b.9 RED — `role_no_bars` reachability scenario: a genuinely unanchored `(roleId, competencyId)` pair (fixture with the pair's rows deleted) → `role_no_bars`, no LLM call, no `ai_requests` row.
- [x] 1b.10 GREEN — confirm 1b.6-1b.9 pass with the pipeline changes from 1b.2-1b.5 (no separate production code expected beyond what 1b.2/1b.3/1b.5 already introduced).
- [x] 1b.11 Bump `config/scoring.php` `prompt_version` (traceability only, per D7 — decoupled from the purge predicate).
- [x] 1b.12 Record follow-up (do NOT fix here): `app/Http/Controllers/Candidate/InterviewController.php:688-695` resolves `Role::where('code', $project->role_code)->first()` and returns HTTP 422 `composition_error` when null — a `potential` project cannot start an interview today. `app/Http` is owned by the concurrent `superadmin-acting-organization-context` change; note this as a named follow-up only (e.g. in the PR description and a tracked TODO comment referencing the change name), no code change.
- [x] 1b.13 Verify: `php artisan test --parallel --filter=RoleScopedIndicatorsTest` green; `php artisan test --parallel --filter=PromptBuilderTest` green; full `php artisan test --parallel` green.
- [x] 1b.14 Run `./vendor/bin/pint --test` and PHPStan on changed files.

## Phase 2: Arch Guard (PR 2, base: PR 1b branch)

- [ ] 2.1 RED — `tests/Arch/C9/BarsIndicatorRoleScopeArchTest.php`, matcher self-test case 1: literal string fixture `BarsIndicator::where('competency_id', $x)->orderBy('position')` MUST be flagged.
- [ ] 2.2 GREEN — implement the named matcher closure (source scan, following `tests/Arch/C2/TenantModelArchTest.php`'s glob + collected-violations shape), scan root `app/` only.
- [ ] 2.3 RED — matcher self-test case 2: same fixture plus `->where('role_id', $r)` MUST NOT be flagged.
- [ ] 2.4 GREEN — refine matcher to accept any of `where('role_id', ...)`, `whereNull('role_id')`, `whereIn('role_id', ...)` as satisfying the invariant.
- [ ] 2.5 RED — matcher self-test case 3: the real `app/` tree produces zero violations.
- [ ] 2.6 GREEN — confirm 2.5 passes given 1a/1b's changes (no separate production code expected).
- [ ] 2.7 RED — liveness assertion 1: the scan visited a non-zero file count.
- [ ] 2.8 RED — liveness assertion 2: the scan found at least one `BarsIndicator` occurrence.
- [ ] 2.9 GREEN — implement both liveness assertions in the same test file (prevents "no violations" being indistinguishable from "read no files").
- [ ] 2.10 Verify: `php artisan test --parallel --filter=BarsIndicatorRoleScopeArchTest` green.
- [ ] 2.11 Run `./vendor/bin/pint --test` and PHPStan on changed files.

## Phase 3: Spec Deltas (PR 3, base: PR 2 branch)

- [ ] 3.1 Update `openspec/specs/scoring-engine/spec.md`: Per-Competency Scoring Pipeline requirement — role-scoped load, total order (`orderBy('position')->orderBy('id')`), D6 behaviour table (reliability denominator 3 not 15; `indicator_count_mismatch` now reachable; `role_no_bars` now reachable for genuinely unanchored pairs).
- [ ] 3.2 Update `openspec/specs/interview-conversation/spec.md`: reverse the RV-2 carve-out ("C9's inline competency-only query is left untouched, MUST NOT be refactored"); re-point `BarsIndicatorLoader` to `App\Services\FrameworkCatalog\BarsIndicatorLoader` as the single shared implementation for both C8 and C9; update the stale Non-Goals prose line referencing "C8 introduces its own BarsIndicatorLoader".
- [ ] 3.3 Update `openspec/changes/scoring-role-scoped-indicators/proposal.md`: fix the D-1 artifact drift — replace the "unratified, three options" framing with the user-ratified decision (PURGE, in local AND production, product is in beta).
- [ ] 3.4 Verify: spec deltas reviewed for consistency with 1a/1b/2 behaviour (no code verification — docs only).

## Phase 4: Purge Command (separate `feature/*` off `develop`, NOT chained to 1a-3)

- [ ] 4.1 RED — `tests/Feature/Console/PurgeMiscoredEvaluationsTest.php`: primary predicate — a scored `CompetencyResult` with 15 `IndicatorScore` rows is flagged corrupt, its parent `Evaluation` is purged; a healthy 3-indicator result is left; an `UNSCORABLE` result with 0 indicator scores is LEFT (the mandatory `unscorable_reason IS NULL` conjunct); a `processing` evaluation with 0 competency results is LEFT.
- [ ] 4.2 GREEN — create `app/Console/Commands/PurgeMiscoredEvaluationsCommand.php` following `PurgeExpiredDataCommand`'s shape: predicate `unscorable_reason IS NULL AND (SELECT count(*) FROM indicator_scores WHERE competency_result_id = competency_results.id) <> 3`; purge unit is the parent `evaluations` row (`WHERE id IN (SELECT DISTINCT evaluation_id FROM competency_results WHERE <corrupt>)`); `withoutGlobalScopes()` throughout.
- [ ] 4.3 RED — cross-check scenario: `count = 3` AND reliability NOT in the literal string set `{'0.0000','0.3333','0.6667','1.0000'}` → command reports the alarm, purges NOTHING, exits non-zero.
- [ ] 4.4 GREEN — implement the reconciliation cross-check (never as a delete predicate); compare against the literal Postgres-returned string set, never a rounded PHP float.
- [ ] 4.5 RED — false-negative acceptance scenario: `count = 3` AND reliability `0.3333` (legal-looking, matches production's real PRS row) → still purged if it also matches the primary structural predicate elsewhere in the fixture set; document this as an accepted false negative, not a bug.
- [ ] 4.6 RED — `--dry-run` scenario: reports the per-result indicator-count distribution (3→n, 15→m, other→…), alarm-arm rows in full, affected evaluation/participant counts PER ORGANIZATION, summed `ai_requests.estimated_cost_usd` about to be lost — and deletes NOTHING.
- [ ] 4.7 GREEN — implement `--dry-run` as the default/first-class mode (not an optional flag), following `PurgeExpiredDataCommand`'s dry-run report shape.
- [ ] 4.8 RED — idempotency scenario: running the command twice in a row — second run finds nothing to purge, no error.
- [ ] 4.9 RED — cascade scenario: purging an evaluation removes its `competency_results` (DB cascade), `indicator_scores` (DB cascade), and `ai_requests` (DB cascade) — verify via direct row absence, not a hand-written child predicate.
- [ ] 4.10 GREEN — confirm cascade reach relies solely on existing `cascadeOnDelete()` migrations; sum `ai_requests.estimated_cost_usd` into the audit row BEFORE the cascading delete removes those rows.
- [ ] 4.11 RED — participant rewind scenario: a participant owning a purged evaluation and currently `completato` transitions to `in_valutazione`; a participant currently `errore` is LEFT ALONE (untouched); no participant outside the affected set changes status.
- [ ] 4.12 GREEN — implement the rewind as a direct, scope-bypassing update (`Participant::withoutGlobalScopes()->whereIn('id', ...)->update(['status' => 'in_valutazione'])`), explicitly NOT going through any lifecycle state-machine transition method.
- [ ] 4.13 RED — not-touched scenario: `organizations`, `users`, `projects`, all `framework_*` tables, `participants` identity columns (`email`, `candidate_ref`, `display_name`, `project_id`), `interview_sessions`, `utterances`, `interview_snapshots`, `integrity_events`, `webhook_deliveries`, `audit_logs`, `notification_logs` are byte-for-byte unchanged after a purge run.
- [ ] 4.14 RED — demo safety scenario: a `DemoWriter`-seeded evaluation (already `role_id`-scoped, 3 indicator scores, legal reliability) survives a purge run untouched.
- [ ] 4.15 RED — audit scenario: an `AuditRecorder` row is written per purged class, carrying the row count and the summed `ai_requests.estimated_cost_usd` lost.
- [ ] 4.16 GREEN — implement the `AuditRecorder` call, batch limit, and `--force` + interactive confirmation guard before any live (non-dry-run) delete.
- [ ] 4.17 Document the operator precondition the code cannot enforce: a full database backup is REQUIRED before any live (non-dry-run) run. Add this as an explicit warning printed by the command before requesting `--force` confirmation, and in the command's help text / PR description.
- [ ] 4.18 Verify: `php artisan test --parallel --filter=PurgeMiscoredEvaluationsTest` green; full `php artisan test --parallel` green.
- [ ] 4.19 Run `./vendor/bin/pint --test` and PHPStan on changed files.

### Slice 4 rollback note

NOT revertible — deletion has no undo. Safety nets, all already tasked above: the
mandatory `--dry-run` distribution report (4.6/4.7), the structural predicate that
cannot match a healthy row (4.1/4.2), the halting cross-check on disagreement
(4.3/4.4), batch limits and `--force` confirmation (4.16), and the operator
precondition — a database backup before any live run — that only a human step, not
code, can enforce (4.17).

---

## Verification (all slices)

- `php artisan test --parallel` (Pest, full suite) from `api/` — green with 0 failures.
- `./vendor/bin/pint --test` — PSR-12 clean on every changed file.
- PHPStan (repo-configured level) — clean on every changed file.
- Each slice's focused filter command (listed in Suggested Work Units) proving that slice green in isolation before opening its PR.

## Orchestrator amendment to Slice 4 — ALLOWLIST, not denylist (user-driven, 2026-09-10)

The user authorised the production purge and named what must survive: "templates,
configurazioni, utenti, progetti, templates". Two of those — `avatar_templates` and the
configuration tables (`llm_credentials`, `platform_settings`, `api_clients`,
`project_questions`) — are NOT in the spec's MUST-NOT-touch list. That list is a DENYLIST,
and a denylist on a destructive command protects only what someone remembered to write
down: add a table tomorrow, forget the list, and it is unprotected by default.

Invert it. Slice 4 MUST:

- [ ] 4.x Enumerate in code the EXCLUSIVE set of tables the command may delete from
      (the corrupted `evaluations` and their dependent `competency_results` /
      `indicator_scores`), and touch nothing else. The participant status rewind to
      `in_valutazione` is a documented, tested exception — an UPDATE, not a DELETE.
- [ ] 4.x RED: a whole-schema invariant test — snapshot `COUNT(*)` for EVERY table in the
      database before the purge and assert every count is unchanged afterwards EXCEPT the
      enumerated ones (and `participants`, whose count is unchanged but whose status column
      moves). Drive it off the live table list from `information_schema`, never a
      hand-maintained array, so a table added later is covered automatically.
- [ ] 4.x The dry-run report MUST name every table it will touch and the row count for each,
      so the operator sees the blast radius before authorising, not after.

Rationale recorded because it is the whole point: the defect this change fixes exists
because someone misread this data model. The same misreading inside a DELETE predicate is
unrecoverable, and a denylist is the shape that lets it happen silently.

## Follow-up from the PR 1b pre-commit review (gga), not fixed in this slice

- [ ] `tests/Feature/Jobs/RoleScopedIndicatorsTest.php` calls
      `(new ScoreEvaluationJob($id))->handle()` directly in all nine role-scoping
      cases, after setting `TenantResolver::setOrgId()`. In a real worker
      `Queue::before` NULLS the ambient resolver — which is the entire reason
      `TenantContextScope::runFor()` exists inside `handle()`. With ambient context
      left set, those tests pass whether or not that wrapper is present, so the
      tenancy path goes unexercised. The role-scoping assertions themselves are
      sound; it is the tenancy wrapper that has never been seen to fail.
      Fix by dispatching through the queue, or by nulling the resolver before
      calling `handle()` so the wrapper is what restores it.
