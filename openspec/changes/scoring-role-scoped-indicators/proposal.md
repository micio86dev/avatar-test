# Proposal: Role-Scoped (and Potential-Aware) BARS Indicator Loading in Scoring

## Intent

`ScoreEvaluationJob.php:374-379` loads BARS indicators filtered by `competency_id`
only. `framework_bars_indicators` is keyed `(role_id, competency_id, position)`
UNIQUE, so a competency code has 3 rows **per role**: PRS/STG/COL return **15**
rows where 3 are required. The comment asserting indicators are shared across
roles is false; its `TODO(PR3)` framed an active defect as a future feature.

Production-confirmed (worker logs, 2026-09-10 08:39-08:40): `PRS score 2.8,
reliability 0.3333…` = 5/15; `STG score 2.67, reliability 0.4` = 6/15 — `0.4` is
not expressible as `assessed/3`.

Live consequences:

| # | Effect |
|---|---|
| 1 | Competency mean computed over 15 cross-role rows, not the project role's 3 |
| 2 | `reliability = assessed/15` ~5x too low → under T=0.5 → `valid:false` → evaluations finalize `pending`, `valid_count: 0` (the reported symptom) |
| 3 | `EvaluationParser` maps `behaviors[i] → $indicators[i]` by POSITION and persists canonical text — scores attached to **other roles'** indicator text |
| 4 | `orderBy('position')` over 15 rows repeats positions 0,1,2 five times with no tiebreaker → non-deterministic order, breaking the `temperature=0` + versioned determinism guarantee |
| 5 | `max_tokens` truncation is a SYMPTOM (~5x output). `config/scoring.php` truncation retry is correct; do NOT raise `max_tokens` |
| 6 | `IndicatorCountMismatchException` never fires: parser compares against `count($indicators)` = 15. The guard is intact, fed a wrong expectation — do not "fix" it |

Additional finding: the job never reads `$project->role_code`, and passes
`roleId: 0` to `PromptBuilder` (line 605) with the same false premise in a comment.

Scoring is a ~95% correctness-critical zone (CLAUDE.md).

## Scope

### In Scope

- Role-scoped indicator lookup in the scoring pipeline, resolving the role from
  `project.role_code`; removal of the false comment, its `TODO(PR3)`, and the
  `roleId: 0` sentinel.
- **Potential-type support** (see Trap): `role_id IS NULL` lookup for MTG/LAT.
- **Shared placement** of the existing correct query — move/extract
  `BarsIndicatorLoader::forRoleCompetency()` out of the C8-only
  `App\Services\Conversation` namespace so both paths use ONE implementation.
  A second inline query is forbidden: a duplicated invariant caused this defect.
- **Total ordering** for the returned rows so positional mapping is reproducible.
- Regression tests per role AND per assessment type, asserting exactly 3
  indicators reach the parser (would have caught this).
- An **arch guard** making a competency-only indicator query impossible to
  reintroduce (precedent: `tests/Arch/C2/TenantModelArchTest.php`).

### Out of Scope

- `superadmin-acting-organization-context` and `db-driven-conversation-prompts`
  (concurrently planned — do not touch their files).
- Raising `max_tokens`; modifying `IndicatorCountMismatchException`.
- The missing `framework_bars_indicators.framework_version_id` (pre-existing gap,
  already owned by a future change).
- Remediation of already-stored evaluations (decision D-1 below, unratified).

## The `potential` Trap (verified — first-class requirement)

A naive `where('role_id', $roleId)` breaks `potential`:

- `2026_09_02_170332_make_bars_indicator_role_nullable.php` made `role_id`
  NULLABLE; role-less rows are constrained by a PARTIAL unique index
  `(competency_id, position) WHERE role_id IS NULL`.
- MTG/LAT belong to `potential` and to NO role (85 anchored = 83 role x
  competency pairs + MTG + LAT).
- `ValidatesProjectComposition::validatePotential()` enforces
  `role_code_must_be_null`, so a potential project has no role.
- `forRoleCompetency(int $roleId, ...)` is non-nullable — it cannot serve this path.

The lookup MUST branch on assessment type, and the null branch MUST emit an
explicit `IS NULL` predicate (`whereNull`), never `where('role_id', null)`.
One scenario per assessment type is required.

## Deterministic Ordering

Once scoped, `(role_id, competency_id)` + UNIQUE `(role_id, competency_id,
position)` makes `position` **total by construction** — no two rows can tie. The
role-less branch gets the same property from the partial unique index. Specify
`orderBy('position')` plus an explicit `orderBy('id')` tiebreaker, matching the
precedent the spec already sets for transcript assembly (`orderBy('ts')
->orderBy('id')`, "determinism-critical").

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `scoring-engine`: **Requirement: Per-Competency Scoring Pipeline** must state
  that indicators are loaded scoped by role (or `role_id IS NULL` for
  `potential`) in a total order, and that exactly the pinned role's indicator set
  reaches the parser. Note a behavioral consequence: `role_no_bars` becomes
  genuinely reachable for an unanchored role x competency pair, where today such a
  pair is silently scored against other roles' text.
- `interview-conversation`: reverse the RV-2 carve-out ("C9's inline
  competency-only query is left untouched") and re-point the
  `BarsIndicatorLoader` requirement at its shared location.

## Approach

Extract the single correct lookup into a neutral, shared unit with a
role-optional signature (`?int $roleId`), have both the conversation and scoring
paths consume it, and lock the invariant with an arch test. Strict TDD: each
regression test RED before its fix, vertical slices.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `api/app/Jobs/ScoreEvaluationJob.php` | Modified | Role-scoped lookup; drop false comment, TODO, `roleId: 0` |
| `api/app/Services/Conversation/BarsIndicatorLoader.php` | Moved/Modified | Shared placement; role-optional signature |
| `api/app/Services/Conversation/SystemPromptComposer.php` | Modified | Import path only (coordinate: `db-driven-conversation-prompts` owns this file) |
| `api/tests/Unit/C8/BarsIndicatorLoaderTest.php` | Modified | Follows the move; add null-role cases |
| `api/tests/Arch/` | New | Guard against competency-only indicator queries |
| `openspec/specs/{scoring-engine,interview-conversation}/spec.md` | Modified | Delta specs |

## D-1: Stored Evaluations — REQUIRES USER RATIFICATION (not decided here)

Every evaluation already produced was computed on the wrong indicator set.
Fixing the query does **not** repair stored rows. Each `Evaluation` records
`framework_version` / `model_version` / `prompt_version`, so affected rows are
identifiable.

| Option | Consequence |
|---|---|
| **A. Recompute** | Correct data; re-delivers webhooks (idempotent + HMAC) — calling systems may see a changed verdict for a candidate already actioned; consumes LLM cost; interacts with the "exactly 1 retry" rule, which was not designed as a backfill budget |
| **B. Invalidate** | Honest (marks results unusable) but strands candidates with no result and no re-interview path |
| **C. Mark-and-leave** | Cheapest, no webhook churn; leaves knowingly-wrong scores readable in the backoffice, and most are already `pending` with `valid_count: 0` |

Bearing constraints: results already delivered by webhook; completion gate is
>=90% valid competencies; exactly ONE retry is permitted. **Do not implement any
option until the user ratifies one.**

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Corrupted stored evaluations remain live and readable | **High (certain)** | D-1 ratification gate; ship the query fix regardless so no NEW corruption is produced |
| `potential` path broken by a naive role filter | **High** | First-class requirement + per-type scenario + explicit `whereNull` |
| Shared-placement move collides with `db-driven-conversation-prompts` | Medium | Import-path-only touch; coordinate ordering with that change |
| Cross-role text already persisted in `indicator_scores.indicator_text` | High | In D-1 scope, not repairable by the query fix |
| Fixing the count re-arms `IndicatorCountMismatchException`, surfacing latent LLM parse failures | Medium | Expected and correct; verify the unscorable/failure path in tests |

## Rollback Plan

Revert the hotfix commit(s). The change is query-scoping + tests + an arch test;
no migration, no schema change, no data mutation (D-1 is deliberately excluded),
so revert restores prior behavior exactly. Config untouched.

## Delivery (Git Flow)

**Recommended: `hotfix/*` off `main`** for the correctness fix. Justification: the
defect corrupts the product's primary output in production on every scoring run;
the code change is small and additive-by-subtraction; no schema or data change is
involved. The asymmetry is deliberate — the **query fix is severe and small**
(hotfix), while **D-1 is a product question** and MUST NOT ride the hotfix: it
becomes a separate `feature/*` change off `develop` after ratification. Merge the
hotfix back to `develop` per Git Flow. No deploy unless explicitly requested.

## Dependencies

- D-1 ratification blocks remediation only, NOT the query fix.
- Ordering coordination with `db-driven-conversation-prompts` (shared file).

## Success Criteria

- [ ] For a `standard` project pinned to role R, exactly **3** indicators — all with `role_id = R` — reach `EvaluationParser` for every competency.
- [ ] For a `potential` project, exactly **3** indicators with `role_id IS NULL` reach the parser for MTG and LAT.
- [ ] No indicator belonging to a non-pinned role is ever loaded or persisted.
- [ ] `reliability` denominators equal 3; values previously impossible (e.g. 0.4) cannot recur.
- [ ] Returned order is total and reproducible across runs.
- [ ] An arch test fails if any code queries `BarsIndicator` by `competency_id` without a role predicate.
- [ ] Regression tests exist per role and per assessment type, and each failed RED first.
- [ ] `max_tokens` and `IndicatorCountMismatchException` are unchanged.

## Proposal question round (unanswered — execution mode `auto`)

Interactive asking was unavailable; these need user review:

1. **D-1**: which option (A recompute / B invalidate / C mark-and-leave)?
2. If A: may webhooks be re-delivered to calling systems that already actioned a
   result, and does a backfill count against the one-retry rule?
3. Is a `potential` project live in production today (does the trap affect real
   data, or only future runs)?
4. Should `role_no_bars` becoming reachable be operator-visible (surfaced in the
   backoffice) or silent audit-only as today?

Assumptions pending correction: the query fix ships without waiting for D-1; no
data is mutated by this change; `hotfix/*` off `main` is accepted.
