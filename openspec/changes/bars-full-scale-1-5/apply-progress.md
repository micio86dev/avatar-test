# Apply Progress: BARS Full 1–5 Indicator Scale

Strict TDD active throughout. Ship order per AD-2/D10: **1 (wrapper) → 2a (api,
`meta`) → 2 (backoffice) → 3 (api, domain)**. This batch completed **1, 2a, 2**
and stopped at the slice boundary before 3, per the size-management guidance
("stop at a slice boundary, save progress, report — do not push through").

## Batch 1 summary (this session)

- Repo/branch state verified: wrapper, `api/`, `backoffice/` were already on
  `feature/bars-full-1-5-scale` with clean trees (task 0.1 confirmed, not
  re-done). `frontend/` was NOT on that branch (detached HEAD at `v0.9.3`,
  no `feature/bars-full-1-5-scale` branch existed) — task 1.8 required a
  frontend edit with no branch prepared for it, so a new local branch
  `feature/bars-full-1-5-scale` was created off frontend's current HEAD and
  the doc fix committed there. This is a deviation from "all repos already
  prepared" worth flagging to the human before release sequencing.
- PR 1 (wrapper docs, zero runtime effect): DONE, tasks 1.1–1.12 all `[x]`.
  Commit `9d23083` in wrapper. Companion doc-only commits in `api` (`5dd8441`),
  `backoffice` (`3995e08`), `frontend` (`bc34fcb`) for their respective
  `AGENTS.md` restatements.
- PR 2a (api, `meta.scoring`, additive/domain-independent): DONE, tasks
  2a.1–2a.4 all `[x]`. Commit `82c3fa3` in `api`.
- PR 2 (backoffice, chip states + provenance render): DONE, tasks 2.1–2.12
  all `[x]`. Commit `999176d` in `backoffice`.

## Remaining (next batch)

- PR 3 (api domain widening): tasks 3.1–3.14, ALL still `[ ]` — not started.
  **Hard gate unchanged: MUST NOT merge/deploy before PR 2 is merged AND
  deployed.**
- Phase 4 (drift detection, `@ai` group): task 4.1, `[ ]`.
- Phase 5 (ops follow-up, human-only): task 5.1, `[ ]` — cannot be completed
  from code; flag to the human at/before PR 3 deploy.
- Phase 6 (final sweep, after PR 3 merges): tasks 6.1–6.4, `[ ]` — blocked on
  PR 3 landing first.

## TDD Cycle Evidence

| Task | Test File | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-----------|-------|------------|-----|-------|-------------|----------|
| 1.1–1.12 | N/A (docs only, no test runner applies) | N/A | N/A | N/A | N/A | N/A | N/A |
| 2a.1–2a.4 | `api/tests/Feature/Admin/EvaluationMetaTest.php` | Feature (HTTP) | ✅ 19/19 (`AdminEvaluationSerializerTest` + `AdminLifecycleGateMatrixTest`) | ✅ Written | ✅ Passed | ✅ 2 cases (single-org meta shape; cross-regime distinguishability) | ➖ None needed |
| 2.1–2.2 | `backoffice/tests/unit/utils/bars.spec.ts` | Unit | ✅ 10/10 | ✅ Written | ✅ Passed | ✅ 6 new cases (2, 4, 0, 6, 2.5, NaN) | ➖ None needed |
| 2.3–2.4 | `backoffice/tests/unit/components/atoms/ScoreChip.spec.ts` | Component (Vue Test Utils) | ✅ 6/6 | ✅ Written | ✅ Passed | ✅ 5 new cases (2, 4, invalid, invalid≠unassessable, i18n data completeness) | ➖ None needed |
| 2.6–2.7 | `backoffice/tests/unit/theme.spec.ts` | Unit (real Tailwind compile + happy-dom) | ✅ 11/11 | ✅ Written | ✅ Passed | ➖ Single pairing (D2 scope) | ➖ None needed |
| 2.8 | `backoffice/tests/unit/composables/useEvaluationReport.spec.ts` | Unit | ✅ 2/2 | ✅ Written | ✅ Passed | ➖ Single (return-shape change) | ➖ None needed |
| 2.9 | `backoffice/tests/unit/pages/participants/detail.spec.ts` | Component (Vue Test Utils) | ✅ 51/51 baseline before this task's edit (1 pre-existing failure caused BY the D7 prop change, fixed same task) | ✅ N/A (approval-test refactor — existing tests updated to new contract) | ✅ Passed | ➖ N/A | ➖ None needed |
| 2.10–2.11 | `backoffice/tests/unit/components/organisms/EvaluationReport.spec.ts` | Component (Vue Test Utils) | ✅ 5/5 | ✅ Written | ✅ Passed | ✅ 2 cases (literal values; en/it identity) | ✅ Rescoped a pre-existing bare-zero regex assertion to `table.text()` to avoid an incidental collision with the new footnote's own "2.0.0"-shaped content |

### Test Summary
- **Total tests written this batch**: 2 (api, PR2a) + 6+5+2+2+2 = 17 (backoffice, PR2) = 19 new test cases, plus 1 approval-test-style fixture update (detail.spec.ts) and 1 rescoped pre-existing assertion.
- **Total tests passing**: api full suite 2094/2099 (5 skipped, `@ai` group, unrelated) · backoffice full suite 812/812.
- **Layers used**: Unit (backoffice bars.ts, theme.spec.ts, useEvaluationReport.spec.ts), Component/Vue Test Utils (ScoreChip, EvaluationReport, detail page), Feature/HTTP (api EvaluationMetaTest).
- **Approval tests** (refactoring): 1 — `detail.spec.ts`'s `EVALUATION_FIXTURE` updated from a flat competency map to `{data, meta}` to match the new `useEvaluationReport` contract; this also fixed a real regression the D7 prop change introduced into that page's mount.
- **Pure functions created/modified**: `indicatorChipState` (widened to total function over 7 states).

## Gotchas discovered (worth remembering)

1. **`auth('api')->login($user)` caches the guard's authenticated user for the
   process.** Authenticating two identities in one Pest test makes every
   subsequent `withToken()` call resolve to the SECOND identity regardless of
   which bearer token is attached to the request — surfaced as an inexplicable
   404 on the FIRST of two sequential requests. Fix: one org/token per test
   (already this codebase's house style in `AdminLifecycleGateMatrixTest`;
   this batch's `EvaluationMetaTest` follows the same pattern).
2. **Ripgrep `-rln` is not "recursive + line-numbers + files-with-matches"** —
   `-r` is `--replace`. `rg -rln "pattern" ...` parses as `-r ln` (replace
   with the literal string "ln"), which only affects DISPLAYED output, never
   the file. Confirmed no file damage; just don't combine flags into `-rln`.
3. **A test's own new fixture data can collide with an unrelated pre-existing
   assertion.** The provenance footnote's version strings ("2.0.0") contain
   dot-separated "0" tokens that satisfied a pre-existing `/\b0\b/` guard
   meant for a completely different concern (competency mean never rendering
   as literal `0`). Fixed by scoping that assertion to the `<table>` subtree.

## Commits (per repo, in order)

- wrapper: `9d23083` docs (PR 1)
- `api/`: `5dd8441` docs (PR 1) → `82c3fa3` feat (PR 2a)
- `backoffice/`: `3995e08` docs (PR 1) → `999176d` feat (PR 2)
- `frontend/`: `bc34fcb` docs (PR 1) — new local branch created, see deviation note above

## Release sequencing — NOT performed, human decision

Per the hard boundary in the launch prompt: no merge, no push, no deploy was
performed. The binding 1 → 2a → 2 → 3 order (and PR 3's hard gate on PR 2
being merged AND deployed) is unenforceable from a single working-tree apply
session — it is stated here again so it is not lost before the next batch.
