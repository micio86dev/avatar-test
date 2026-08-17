# Archive Report: interview-error-redirect

**Change**: interview-error-redirect  
**Archived**: 2026-08-17  
**Status**: Complete  
**Tasks**: 13/13 complete  

## Summary

Configurable error redirect for failed interviews (C15). When an interview reaches `error` or `terminal` state and the project has a configured `error_redirect_url`, the frontend redirects the candidate to that URL. The binding doc places the query-string format out of scope; inventing one would be a contract nobody agreed to and no caller reads.

Mirrors `exit_redirect_url` exactly — same validation terms, per-project, nullable, max 2048 characters.

## Artifacts Verified

- **Proposal**: openspec/changes/interview-error-redirect/proposal.md ✅
- **Specs**: openspec/changes/interview-error-redirect/specs/ (2 delta specs) ✅
  - interview-frontend/spec.md (ADDED: Failed interviews return candidate to calling system)
  - project-config/spec.md (ADDED: Projects carry configurable error redirect URL)
- **Design**: Not present (inline rationale in proposal and specs) ✅
- **Tasks**: openspec/changes/interview-error-redirect/tasks.md (13/13 complete) ✅
- **Verify Report**: Engram #1062 ✅

## Promoted Specs (Merged)

1. `/openspec/specs/interview-frontend/spec.md`
   - ADDED: "Failed interviews return the candidate to the calling system" requirement
   - 4 scenarios: configured project redirects on error, terminal redirects identically, unconfigured project keeps inline screen, redirect carries no diagnostic payload

2. `/openspec/specs/project-config/spec.md`
   - ADDED: "Projects carry a configurable error redirect URL" requirement
   - 3 scenarios: project accepts error redirect URL, malformed URL rejected, field is optional

## Test Coverage

- API: ProjectErrorRedirectTest.php (fixed: replaced substring assertion with HTTP-level 422 tests on both POST and PATCH)
- Frontend: useExitRedirect composable tests (fixed: added 3 page-level tests for error/terminal watch wiring)
- Full suite: 1275 API tests green, 422 unit + 83 E2E frontend tests green
- OpenAPI snapshot synced to both Nuxt apps

## Code Quality

- PHPStan: 0 errors
- Pint: clean
- Typecheck: clean
- All tests passing with verified coverage of wiring (watch handler invocation on error/terminal state)

## Known Issues Resolved

Per verify-report (Engram #1062):
1. **API validation test false positive** — test assertion used substring match on field name itself; replaced with HTTP-level validation tests (422 on malformed URL for both POST and PATCH)
2. **Frontend page-level coverage gap** — added 3 tests asserting `redirectToError()` invocation on error/terminal state transition

## Migration & Database

- `api/database/migrations/2026_07_31_000002_add_error_redirect_url_to_projects_table.php`
- Column: nullable string, max 2048, validated identically to `exit_redirect_url`

## Deliverables Status

- micio86dev/backend#40 ✅ merged
- micio86dev/frontend#12 ✅ merged
- micio86dev/frontend#13 ✅ merged
- micio86dev/backoffice#5 ✅ merged

## SDD Cycle

✅ **Propose** → **Spec** → **Design** → **Tasks** → **Apply** → **Verify** → **Archive**

All 13 tasks delivered against merged PRs with green CI. Verification confirmed every claimed artifact exists at its claimed path and the wiring is end-to-end correct. Two test coverage gaps identified by mutation testing have been fixed before archive.

**Change is ready for archive.**

---

Observation IDs for traceability:
- Proposal: (embedded in proposal.md)
- Verify Report: Engram #1062
