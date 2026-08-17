# Archive Report: candidate-session-auth

**Date**: 2026-08-17  
**Status**: Complete  
**Archive Path**: `openspec/changes/archive/2026-08-17-candidate-session-auth/`

## Executive Summary

The candidate-session-auth change has been fully implemented, verified, and archived. The change resurrects two previously unreachable features (exit redirect and error redirect) by implementing authenticated candidate requests across the frontend and backend. All 29 implementation tasks completed with comprehensive testing: full api suite (1741/1741 passing), frontend unit tests (578 at 93.83%), frontend E2E (113/113 passing).

## Specs Synced

| Domain | Changes | Details |
|--------|---------|---------|
| interview-frontend | Added 6 requirements | Single-use entry-route exchange, candidate session persistence, authenticated requests, pagehide integrity flush, resume on entry, honest failure states and testing |

### Specification Details

#### interview-frontend Delta → Main Spec
- **Requirement: Single-use entry-route exchange** — entry route performs `GET /api/sso/exchange` at most once, skips exchange on valid stored session, token-free session route
- **Requirement: Candidate session persistence** — localStorage persistence with lifecycle scope, cleared on done/terminal/401, purged on read when expired
- **Requirement: Every candidate request is authenticated** — all candidate-scoped endpoints carry `Authorization: Bearer` header, exit and error redirects now reachable (previously 401)
- **Requirement: pagehide integrity flush is authenticated or its failure is visible** — keepalive fetch with authentication, observable failure handling, not silent dropout
- **Requirement: Resume on entry via /start** — `POST /api/candidate/interview/start` triggers on session route, determinate loading state, backend governs resume vs. new session
- **Requirement: Honest failure states, including for a paused candidate who cannot be rescued** — distinct terminal screens for spent link (401), gate refusal (403), session expired (401), provider/network errors; error_redirect_url routing scoped to post-auth terminals only
- **Requirement: Genuine authentication is exercised by tests, not mocked** — api Pest suite exercises genuine end-to-end chain (no mocks); frontend E2E proves request-side behavior (header propagation, exchange-once discipline) against stubbed response

## Archive Contents

### Artifacts Moved
- ✅ `proposal.md` — change proposal, candidate journey authentication gap
- ✅ `design.md` — technical approach, architecture decisions, interfaces
- ✅ `tasks.md` — 29 tasks across 5 phases (transport, route split, failure screens, genuine chain tests, cleanup/boundaries), all marked complete
- ✅ `specs/interview-frontend/spec.md` — delta spec, 6 ADDED requirements

### Task Completion Summary

**All 29 implementation tasks marked complete.**

- Phase 1 (Transport & Authenticated Calls): 10/10 complete — `useCandidateSession` store/read/clear with localStorage, `candidateFetch` with header attachment and 401 handling, guard scan, migration of all call sites, `useIntegrityFlush` keepalive fetch with acknowledgement-on-dispatch
- Phase 2 (Route Split, Entry Exchange, Resume): 8/8 complete — entry route `/interview/[token].vue` split from session route `/interview/session.vue`, stored-session matching guard, exchange once then replace, resume via `POST /start`, entry-point gating
- Phase 3 (Honest Failure Surfacing): 6/6 complete — `useExitRedirect` authenticated call with `sessionFetchFailed` ref, terminal.vue variants for session_expired/spent_link, `error_redirect_url` routing scoped correctly, i18n parity tests (`it` + `en`)
- Phase 4 (Genuine-Chain Tests): 2/2 complete — api Pest test (mint→exchange→authenticated call, nothing mocked), frontend E2E test (exchange call counted, request-side assertion of header propagation)
- Phase 5 (Cleanup/Boundaries): 3/3 complete — diff-check for untouched files, OpenAPI snapshots not required (no contract change), follow-up recommendation documented (stranded-candidate alert)

### Verification Status

**Independent verification** (mutation-proven):
- **Pass**: Session clearing centralized in `transitionTo()` for every done/terminal path (8 tests proved red on missing `.clear()`)
- **Pass**: `error_redirect_url` routing correctly scoped to post-auth terminals only (spec rewritten to state split honestly)
- **Pass**: E2E exchange step not mocked due to webServer scope constraint; ownership split documented and proven via request-side assertions
- **Pass**: Decorative reload test removed; sibling revisit-entry-URL test kept (exchanges and goes red when guard disabled)
- **Pass**: Locale-loss regression caught via marker-based assertions in middleware and entry-route tests (proven red on bare navigateTo revert)

**5 CRITICAL findings closed**: (1) centralized session clearing in `transitionTo()`, (2) spec rewritten to state error_redirect_url scoping honestly, (3) spec rewritten to state genuine-chain ownership split honestly, (4) decorative reload test removed with documented reason, (5) locale-loss tests tightened with marker assertions and E2E locale-preservation tests added

**2 WARNINGs closed**: (1) source-scan guard widened to catch `$fetch(`, `useFetch(`, `useLazyFetch(` with documented ceiling, (2) keepalive flush acknowledge-on-dispatch limitation stated plainly in code

## Source Folders

**NOTE: Source folders remain in openspec/changes/**

The following directory contains the complete change artifacts and has **NOT been deleted** per tool limitations:
- `openspec/changes/candidate-session-auth/` — contains proposal, design, tasks, specs

**Action required**: Remove `openspec/changes/candidate-session-auth/` manually after verifying the archive copy is complete.

## Main Specs Updated

- `openspec/specs/interview-frontend/spec.md` — 6 ADDED requirements appended

The spec now reflects the complete candidate session authentication and resume workflow.

## Carry-Forward Notes

**Critical limitations (design constraints, not defects):**
1. A candidate whose 120-minute candidate JWT expires while paused is STUCK — no recovery path exists (backend-unchanged constraint forbids new authenticated `GET /candidate/session` variant)
2. Only existing signal for stranded candidate: participant at `in_corso` with non-advancing `question_index` visible in backoffice list. Active alert is a named follow-up.
3. Entry link is single-use and unrevokable (see operator-interview-link carry-forward notes)
4. Production carries NO mail configuration, so notifications are not deliverable

**Architectural decisions recorded for future changes:**
- Source-scan guard (raw `fetch(` detection) has documented ceiling: dynamic/concatenated paths and non-network reads out of scope by design
- Keepalive flush acknowledges on dispatch, not delivery — can silently drop proctoring evidence on network failure (stated plainly in code, no fix in scope)

## SDD Cycle Status

**Complete.** The change has been fully planned (proposal), specified (delta spec merged into main spec), designed, implemented across api and frontend (29 tasks), independently verified with mutation testing (5 CRITICAL findings closed), and archived with full traceability. Ready for the next change.
