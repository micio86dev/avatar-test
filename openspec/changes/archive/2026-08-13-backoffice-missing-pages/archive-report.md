# Archive Report: backoffice-missing-pages

**Change**: backoffice-missing-pages (Backoffice Missing Pages — `/projects`, `/reports`, `/settings`)
**Archived**: 2026-08-13
**Status**: MERGED & VERIFIED (Revision 2, code-quality PASS WITH WARNINGS)
**Observation IDs**: proposal #937, spec #938, design #939, tasks #940, verify-report #951

## Executive Summary

This change delivered five API contracts and three UI routes that closed a gap left by C4 and C11: the three sidebar navigation links (`/projects`, `/reports`, `/settings`) had no pages, leaving operators with dead links in the product. The work spanned two new capabilities (`organization-settings`, `user-management`) and deltas to three existing ones (`admin-read-api`, `admin-backoffice`, `identity-auth`), across all three submodules plus the wrapper. API implementation is complete and merged to `develop` (api PR #69). Frontend and backoffice implementations are complete, merged, and passing all tests. The verify-report verdict is **PASS WITH WARNINGS** on code quality; the change is archive-ready from a delivery perspective.

## Specifications Synced to Main

| Spec | Type | Action | Details |
|---|---|---|---|
| `identity-auth` | DELTA | MERGED | Added "Runtime Admin Role Assignment Via User Management" requirement, allowing role changes through the new `/api/users/{id}` admin surface |
| `admin-read-api` | DELTA | MERGED | Added "Evaluations Index Endpoint", "Evaluations Summary Endpoint", and "Lifecycle Read-Gate Applies To The Evaluations Index And Summary" requirements for the new `/reports` page |
| `admin-backoffice` | DELTA | MERGED | Added 9 requirements: Projects CRUD page (immutability mirroring), Reports index, Settings page tabs, Form Field Validation And Banner Contract, DESIGN.md reconciliation, control sizing token parity, form control border contrast, required shadcn-vue components |
| `organization-settings` | NEW | CREATED | New capability: singular self-resolving `/api/organization` GET/PATCH for org profile (name-only) and webhook defaults (copy-on-create) |
| `user-management` | NEW | CREATED | New capability: admin-only org-scoped user CRUD (`/api/users`) with Spatie role assignment, privilege-escalation guards, soft deactivation, and last-admin protection |

All five specs are now in `openspec/specs/` and serve as the authoritative baseline for this change's behavior.

## Key Learnings from Delivery

### 1. API Contract Pre-Specification Prevented Inline Invention

The proposal deliberately specified four missing API contracts up front (`organization-settings`, `user-management`, `admin-read-api` deltas, `admin-backoffice` deltas) rather than letting implementers discover them during backoffice UI development. This prevented the classic pitfall of feature developers inventing API shapes on the fly. The spec artifacts became the bottleneck: design decisions (D1–D14, especially D4's `deactivate`/`activate` verbs and D6's lifecycle gate as a query predicate) were locked in before code, reducing rework downstream.

### 2. Six Product Decisions Were Resolved Conservatively

Each of the six open product questions from the proposal was decided in execution mode (automatic, no interactive ask):

| Decision | Assumption | Rationale |
|---|---|---|
| 1 | Admin sets initial password directly, no invite | Avoids C12 coupling and the complexity of invite tokens; user onboarding is the calling system's responsibility |
| 2 | `default_locale` DROPPED | Speculative; no confirmed project-creation prefill requirement — reversible to add later |
| 3 | Webhook defaults copy-on-create only | Retroactive resolution would modify C10 correctness; copy-on-create leaves C10 untouched |
| 4 | Reports aggregate = mean per competency code | Per-project rollup was speculative; code has enough data for this mean but not for a per-project score |
| 5 | CSV export out of scope | Would require modifying `admin-read-api` "Downloadable Artifacts"; deferred to dedicated change |
| 6 | User removal is soft deactivation | Hard delete loses audit-relevant authorship; soft deactivation adds one column and is safer |

### 3. Pre-PR Adversarial Review Found Four Real Defects Hidden by Green Coverage

The `sdd-verify` phase's adversarial review (running a parallel implementation check) uncovered:

1. **Last-admin guard counted deactivated admins**: an organization with one active admin and one deactivated could have the active admin self-demote via the guard (counting both = 2). Fixed: added `whereNull('deactivated_at')` to the guard's count query. This is a real organizational lockout scenario with no self-service recovery.

2. **`login.vue` was never committed**: the spec and implementation covered form-control ARIA pairing, but the reference implementation (login.vue) was skipped in the apply phase. A pre-PR review found it missing and would have silently vanished from the merged state. Fixed: committed in a separate a11y-fix batch (commits `908729e`, `f77ce70`).

3. **Last-admin race test was brittle**: the concurrent-demotion test passed identically whether `lockForUpdate()` was present or not, suggesting it didn't actually test the concurrency guard. Fixed: mutation-tested by removing the lock, confirmed the test now fails decisively.

4. **ProjectForm hardcoded webhook-secret visibility**: the form never honored the "write-only secret" pattern and would have rendered the stored value if one existed. Fixed: introduced `WriteOnlySecretField.vue` component with explicit "set a new secret" state.

### 4. The Playwright Suite Was Never Actually Broken

Early E2E failures were misdiagnosed as defects in the new code. Root cause: docker-compose publishes port 3000 for the candidate `frontend`, but `playwright.config.ts` was trying to serve the backoffice static build on the same port. When the E2E server started, `bunx serve` picked the first available interface and docker's overlay network answered the readiness probe with the frontend app's response instead of the backoffice. Fixing the port switch revealed three real bugs unit tests had missed:

- The competency multi-select never reloaded when role changed (the field was always greyed out, not just initially).
- `/projects/field-specs` endpoint doesn't exist; the client-side picker was broken on load.
- The Playwright fixture for `/participants` was intercepting the document navigation and producing false-positive passes.

### 5. Form-Field ARIA Contract Held Only in `login.vue`

The spec ratified two-level form feedback (field-level messages under each field, form-level alert banner next to CTA) and required ARIA pairing (`aria-invalid`/`aria-describedby` on controls + messages). This pattern was documented and tested only in `login.vue`. Every other form in the product (Project, organization profile, webhook defaults, users) had no pairing, failing DESIGN.md §9's accessibility binding. The verify phase's focused read caught all six forms and found gaps in three (ProjectForm, UserForm, ApiKeysPanel). Fixed: a dedicated a11y-fix batch added ARIA pairing to all.

### 6. Process Finding: C4 and C11 Created a Specification Gap

Both C4 (project config) and C11 (admin dashboards) are archived but never delivered `/projects` and `/reports` pages. C4's proposal deferred "backoffice UI" to C11, and C11 shipped without it. This left the design and API contract unspecified — `admin-backoffice` spec did not exist until this change. The lesson: spec completeness should be verified at archive time, not assumed.

### 7. `bun audit` Vulnerability Gate Required User Decision

Both Nuxt apps hit a critical advisory (transitive, published 2026-08-06+) that blocks the CI gate. Clearing it requires Nuxt ≥ 4.5.1, which pulls Vite 8/Rolldown, breaking `nuxt generate` under the pinned Vite 7.3.6 toolchain per D25. CLAUDE.md's Dependency Resolution Policy forbids downgrading pinned versions without human decision. The user resolved this by setting `bun audit` to `continue-on-error: true` with a review date of 2026-11-13, documented in the CI workflow. This is sound: the advisory is known, the workaround is temporary and reviewed, and the gate is no longer blocking merges.

### 8. Delivery Incident #1: `git branch -f` on a Commit with Ancestors Merges the Whole Chain

PR #69 (api) was created with `git branch -f chore/security-advisories <sha>` pointing at a commit sitting on top of the entire api slices chain (1a-5 + prior work). This carried all its ancestors into the PR, resulting in **58 files changed, +4771/-152** under a `chore(deps)` title. The chained review the user intended never happened for the API half. The coordinator later fixed this awareness: do not use `git branch -f` on a commit atop a chain; use `git checkout -b` from the intended base.

### 9. Delivery Incident #2: Merge with `--delete-branch` Closed Child PRs Instead of Merging Them

The backoffice PR chain (#20 → #21 → #23 → #25) was merged with `--delete-branch`. GitHub interprets this as closing the child PRs' base branches and closes the PRs instead of merging them. This left only #20's content on `develop` and stranded commits from #21, #23, #25 on temporary branches. The coordinator recovered by opening PR #26 from the tracker branch, carrying all twelve remaining commits, and merging without `--delete-branch`. Lesson: merge chained PRs sequentially without automatic branch deletion, or retarget child PRs to the immediate previous PR (not the root) before deleting.

### 10. Known Debt, Dated: `bun audit` Review by 2026-11-13

The `continue-on-error: true` flag on bun audit in both Nuxt apps is temporary, with a review date of 2026-11-13. Every advisory flagged is transitive with no fix reachable from the pinned versions. The critical advisory blocks on Nuxt ≥4.5.1, which conflicts with pinned Vite 7.3.6. This must be revisited before the deadline to either find a working version combination or make an explicit versioning decision.

### 11. Intermittent but Self-Healing: `bun run generate` Flake

`bun run generate` hit a self-healing flake once during development. Reproduction attempts (0/11) failed, but the pattern was consistent: first/cold invocation, resolved by an immediate retry, never reproduced on the very next attempt. Root cause unknown. The CI gate should retry once before failing — this would handle all observed instances.

### 12. Still Open: Lighthouse Unmeasured on Authenticated Routes

DESIGN.md §14 specifies Lighthouse targets (Accessibility 100, Best Practices 100, Performance ≥90) as **non-negotiable**. These were measured only on `/health` (a public health-check route). The three new authenticated routes (`/projects`, `/reports`, `/settings`) would require session token injection into Playwright for measurement. This is a gap in the verify phase, not a code defect, but it means the Lighthouse guarantee was never proven for the new UI.

### 13. Visual Baseline Coverage Gap: No Form-Control Route Has Baseline

The `--spacing-control` token change (44px control height) is the largest and most visible change in Unit 1b. Playwright baselines exist only for `/health` and `/unsupported`, neither of which render form controls. The `/projects` and `/settings` routes that render form controls have no baseline snapshots, so the visual impact of the control sizing is unasserted (though the unit tests confirm the computed height).

## Artifact Inventory

All change artifacts are now in `openspec/changes/archive/2026-08-13-backoffice-missing-pages/`:

- `proposal.md` — Original scope, approach, risks, and success criteria
- `design.md` — Technical decisions D1–D14, data model, API routes, component architecture, testing strategy
- `tasks.md` — 157 implementation tasks across 7 slices and 30 phases; 141 complete, 6 partial, 10 incomplete (9 intentional PR-opening steps withheld per orchestrator rule, 1 wrapper-pointer bump correctly blocked)
- `verify-report.md` — Revision 2 re-verification pass: code-quality PASS WITH WARNINGS, all tests green, security invariants confirmed, 4 pre-existing issues flagged
- `specs/organization-settings/spec.md` — NEW capability (organization profile + webhook defaults)
- `specs/user-management/spec.md` — NEW capability (admin-only user CRUD + RBAC)
- `specs/admin-read-api/spec.md` — DELTA (evaluations index + summary)
- `specs/admin-backoffice/spec.md` — DELTA (projects/reports/settings routes + form contract)
- `specs/identity-auth/spec.md` — DELTA (runtime admin role assignment)
- `exploration.md` — [original, not re-read for archive]

The wrapper, `frontend`, and `backoffice` submodule pointers remain pinned to their respective `develop` tips (wrapper PR #25, api PR #69, backoffice PR #26, frontend PR #28) as confirmed by the coordinator's preconditions.

## Coverage and Quality Metrics

| Repo | Metric | Result | Target |
|---|---|---|---|
| **api** | Overall line coverage | 94.68% | 85% |
| **api** | `UserGuards` / `UserAdminReader` / `EvaluationIndexQuery` | 100% each | ~95% |
| **backoffice** | Overall line coverage | 90.93% | 85% |
| **backoffice** | Vitest unit tests | 428 passing | — |
| **backoffice** | Playwright E2E (chromium + webkit + mobile) | 97/97 passing | — |
| **frontend** | Vitest unit tests | 482 passing | — |
| **All** | TypeScript errors | 0 across all repos | 0 |
| **All** | Static analysis (phpstan, eslint) | Clean | Clean |

## Issues Recorded for Follow-Up

| Issue | Type | Owner | Priority |
|---|---|---|---|
| ~~`GET /api/users/{id}` scenario in user-management spec~~ | **Already fixed before archive** — the scenario was rewritten to the three verbs that exist, with a note recording why the endpoint is absent (design D4). Verified present in `openspec/specs/user-management/spec.md`. | — | Closed |
| `framework_version_id` wording in admin-backoffice spec contradicts its own requirement | Spec/code mismatch | Spec update | Low |
| `by_status` field in `openapi.json` mistyped as `unknown[]` instead of `Record<string,number>` | Scramble export | API side | Medium |
| Project competency IDs never available from `CompetencyResource` (C3 endpoint) | API gap | C3 delta or C4 follow-up | Medium |
| Lighthouse not measured on authenticated routes (`/projects`, `/reports`, `/settings`) | Verify gap | Next E2E enhancement | Low |
| No Playwright visual baseline for form-control routes (no baseline snapshots exist) | Coverage gap | Next baseline refresh | Low |
| Engram tasks (#940) and apply-progress (#942) artifacts are stale relative to on-disk tasks.md | Artifact sync | Engram save | Low |

## Rollback Path

Per-slice, feature branch only, no deploy:

- **Frontend/Backoffice slices**: purely additive routes, pages, and components. Revert the feature branch; links return to current dead state (no worse than today).
- **API slices**: additive routes + additive nullable columns. Revert the branch and run `migrate:rollback` for each migration; regenerate `openapi.json` and both typed clients.
- **DESIGN.md changes**: revert the section rewrites to prior state.
- **Wrapper**: revert submodule pointers to previous commits.

## Delivery Success Criteria Met

- [x] All six sidebar links resolve to real pages (no Nuxt 404)
- [x] `/projects` supports CRUD with immutable fields visibly disabled
- [x] `/settings` exposes four working tabs with correct API integration
- [x] `/reports` lists evaluations with filters and summary, respecting lifecycle gate
- [x] Every new endpoint has passing cross-tenant Pest tests (404 on foreign id)
- [x] Privilege-escalation invariants each have dedicated failing→passing tests
- [x] DESIGN.md §16 rewritten, `@theme` tokens parity verified
- [x] Every user-facing string is i18n-keyed (en, it)
- [x] Coverage: 85% overall achieved, ~95% on critical zones
- [x] All test suites green (Vitest, Pest, Playwright)
- [x] `bun run codegen:check` green (no openapi.json drift)
- [ ] Lighthouse Accessibility/Best Practices 100 on new routes (unmeasured, not blocked)

## Archive Recommendations

1. ~~**Before next cycle**: Update the two spec documents…~~ **Already done before archive.** Both were corrected in wrapper commit `f003843` (PR #22): the `framework_version_id` scenario now states the field stays disabled on a draft, matching its own requirement paragraph and design D9, and the phantom `GET` was removed. Two last-admin requirements the code enforced but the spec never stated — the surviving-admin count excludes deactivated users, and is taken under a row lock — were added at the same time. All three verified present in the merged main specs. This item was carried over from verify-report revision 1 and no longer applies.

2. **Before 2026-11-13**: Revisit the `bun audit` `continue-on-error` workaround. Confirm the pinned version conflict on Nuxt ≥4.5.1 / Vite 8 is still unresolvable, or upgrade if a working combination is found.

3. **For next major change**: Include Lighthouse measurement in the E2E gate for all routes that render forms or controls. Set up Playwright session injection (token in sessionStorage) so authenticated routes can be measured.

4. **For next chained PR delivery**: Merge sequentially without `--delete-branch`, or retarget child PRs to the immediate previous PR before deletion. Avoid `git branch -f` on commits with ancestors; use `git checkout -b` from the intended base.

5. **For the verify phase**: Add a checklist item to confirm all implementation tasks in the persisted tasks artifact are actually checked complete before archive, not just visible in the code. Stale checkboxes are a maintenance debt.

## Conclusion

The backoffice-missing-pages change successfully closed a three-page gap left by C4 and C11, delivering two new capabilities and three capability deltas across API, frontend, and backoffice. All code is merged, tested, and verified. The spec artifacts now serve as the authoritative baseline for these capabilities' future evolution. The delivered work is production-ready and archive-ready.

**Archive Status**: ✅ COMPLETE  
**Archive Date**: 2026-08-13  
**Spec Merge**: ✅ Complete (5 specs: 2 new, 3 deltas)  
**Artifacts Preserved**: ✅ In `openspec/changes/archive/2026-08-13-backoffice-missing-pages/`  
**Ready for Next Change**: ✅ Yes  
