# Backend authorization test matrix

## Objective
Every `/api` route (147) is exercised for every actor with a durable, declarative matrix, so
regressions on authN/authZ/tenancy fail loudly instead of reappearing.

## Problem
Baseline 2026-09-29 (api develop 383fbea): 4498 tests, 1 red, 7 skipped. Coverage audit found:
no 401 test on most routes, non-superadmin 403 checked on 1 of ~20 catalogue writes,
zero coverage on `POST /avatar-templates/{id}/deactivate`, `/evaluations*` without role matrix,
`/v1/exports` and `/v1/usage` without scope/cross-org checks, weak status-only assertions.

## Constraints
- Repo language English; tests in Pest; strict TDD (runner: `vendor/bin/pest --parallel --no-coverage`), source: project config.
- Tests must assert real policy behaviour. If code disagrees with intended behaviour: report as a
  bug, never bend the test. 403/401 tests also assert NO state change (DB unchanged).
- Actors: unauthenticated, admin/operator/viewer (own org), same roles cross-tenant, org user w/o role,
  superadmin (bare + acting-as-org via `platform`), candidate JWT, M2M client, Public API key.
- No `Gate::before` masking: role helpers must not silently pass as superadmin.
- Helpers used by >1 file go in `tests/Helpers` + composer `autoload-dev.files` (ParaTest).
- Branch: `feature/authorization-matrix-tests` (api submodule). Work-unit commits, conventional, no AI attribution.
- Delivery strategy: ask-on-risk.

## Tasks
- [x] T1 Make `AuditConfigTest` hermetic (env leak: real API key in local env) — route: delegated — 87c100b
- [x] T2 Matrix infra: declarative `AuthMatrix` catalogue + guard test failing when any registered route has no entry — f8b1ef3
- [x] T3 401 for every protected route (driven by matrix) — c96b6d7 (312 cases)
- [x] T4 Org-scoped (301 cases, 43 routes; ae0b68e 301a869 954da59 58e8258 ca12f8d; 6 mutations caught; full suite 5122/0 failed)
- [x] T5 (c6e990c 10f12df; 60 routes, 420 cases, 6 mutations caught, suite 5568/0 failed) Superadmin-only domains: catalogue (21), avatar-templates (12), framework, admin/*, llm-credentials/models — non-superadmin 403 on every write
- [x] T6 (eaba2ce 73477cd e562edc; 514 cases; 13 mutations, 2 survivors explained; KQ-5/KQ-6 found) Candidate JWT (cross-participant/org isolation), M2M, Public API `/v1/*` scopes + cross-org
- [x] T7 (b8665e1 75a2d99; suite 6138/0 failed; 5 skips legit: redis/live LLM) Health/embed/sso/entry-links exposure; triage the 7 skipped tests
- [x] T8 (api backend#122, 6af3134; per-task mutation checks T4-T6 + EvaluationPolicy/ParticipantStatusGuard; suite 7857/0 failed/18 skipped, 95.7% lines; critical-zone classes 98.5-100%; native review approved+acknowledged after one bounded correction) Mutation check, full suite green, coverage on scoring/tenant/state-machine zones

## Acceptance
Full suite green, no route without matrix entry, mutation of any policy/middleware is caught.

## Progress / evidence
- Baseline: /private/tmp scratchpad baseline.txt (1 failure AuditConfigTest, 7 skipped).
- Route declaration: T1-T2 delegated writer (mapping trigger already used for audit).

## Next step
All tasks done (2026-10-02). Unreachable lines: ScoreCompetency 138-141 (dead catch), AdminEvaluationSerializer 384 (FK-enforced).
