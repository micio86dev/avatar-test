# Archive Report: operator-interview-link

**Date**: 2026-08-17  
**Status**: Complete  
**Archive Path**: `openspec/changes/archive/2026-08-17-operator-interview-link/`

## Executive Summary

The operator-interview-link change has been fully implemented, verified, and archived. The change ships operator-facing entry link minting for backoffice (new `POST /api/entry-links` endpoint), with UI controls on participant detail (re-issue) and participants list (invite new). All 44 implementation tasks completed with comprehensive testing: 1741/1741 API tests passing, 714/714 backoffice unit tests passing, 131/131 E2E tests passing (Playwright pinned container).

## Specs Synced

| Domain | Changes | Details |
|--------|---------|---------|
| participant-sso | Added 6 requirements | Shared minting logic extraction, operator-facing mint endpoint, entry URL composition and configuration, no-revocation semantics |
| admin-backoffice | Added 4 requirements | Entry link actions (re-issue + invite), single-use/expiry disclosure, no-revocation wording, disabled-state reasons |

### Specification Details

#### participant-sso Delta → Main Spec
- **Requirement: Shared Entry Link Minting Logic** — extraction of mint decision into `EntryLinkMinter`, byte-identity proof across M2M and operator mints
- **Requirement: Operator-Facing Entry Link Mint Endpoint** — `POST /api/entry-links` on `auth:api` + `TenantContext`, `ParticipantPolicy::create` authorization, project accessibility gates
- **Requirement: Entry Link Response Composes the Absolute URL** — response shape `{ entry_url, expires_at }`, no bare token field
- **Requirement: Entry URL Locale Prefixing Is Owned by the Minter** — locale prefix resolution, `it` omitted vs `en` prefixed, project language fallback
- **Requirement: CANDIDATE_APP_URL Fails Loud When Unset** — fail-loud configuration, never falls back to `config('app.url')`
- **Requirement: No Revocation Semantics** — unexpired links remain valid, no jti consumption pre-exchange

#### admin-backoffice Delta → Main Spec
- **Requirement: Entry Link Actions on Participant Detail and Participants List** — re-issue on detail (pre-filled), invite on list, viewer visibility gate
- **Requirement: Single-Use and Expiry Are Disclosed Before the Copy** — disclosure renders before copy control, expiry through date-render convention
- **Requirement: Re-Issue Action Never Claims Revocation** — wording "Generate new link", no revoke/regenerate terminology in `it` + `en`
- **Requirement: Entry Link Action Disabled With a Stated Reason When Unusable** — disabled states for draft/not-yet-live/expired projects, API enforcement independent of UI

## Archive Contents

### Artifacts Moved
- ✅ `proposal.md` — original proposal, change intent and scope
- ✅ `design.md` — technical approach, architecture decisions, implementation flow
- ✅ `tasks.md` — 44 tasks across 6 phases (config rename, minter extraction, mint endpoint, backoffice UI, verification, coverage gaps), all marked complete
- ✅ `specs/participant-sso/spec.md` — delta spec, 6 ADDED requirements
- ✅ `specs/admin-backoffice/spec.md` — delta spec, 4 ADDED requirements

### Task Completion Summary

**All 44 implementation tasks marked complete.**

- Phase 1 (Config Rename Sync): 3/3 complete — `FRONTEND_URL` → `CANDIDATE_APP_URL` in design and specs
- Phase 2 (Minter Extraction): 15/15 complete — `EntryLinkMinter`, `EntryLinkUrlComposer`, both unit tests RED→GREEN, golden test proof, controller refactor, OpenAPI sync byte-identity
- Phase 3 (Human-Facing Mint Endpoint): 10/10 complete — policy authorization, `POST /api/entry-links` endpoint, resource contract extension with nested project, OpenAPI sync
- Phase 4 (Backoffice Surface): 13/13 complete — project-accessibility utility, form component, panel component with clipboard handling, field validation, both list and detail surfaces, i18n (`it` + `en`), arch guards (form-contract, date-render, destructive-action), E2E tests
- Phase 5 (Verification): 8/8 complete — full test suite (1734/1734 + pre-existing skips), coverage gate (94.7%), Pint formatting, PHPStan (0 errors), OpenAPI idempotency, backoffice typecheck/lint/format/codegen
- Phase 6 (Coverage Gaps Closed): 6/6 complete — CRITICAL: "superseded link remains valid" test added, CRITICAL: participant-detail re-issue surface fully tested (unit + E2E), WARNING: lang-fallback end-to-end coverage, WARNING: shared-minter consistency test, cosmetic: handler rename (`onRequestAnotherLink`), attribution: Playwright 3-flake correction (unreproducible, cause unconfirmed)

### Verification Status

**Independent verification** (mutation-proven):
- **Pass**: Byte-identity of M2M response confirmed by three mechanical proofs (zero-edit test, golden response test, OpenAPI diff)
- **Pass**: RBAC gate enforcement — `ParticipantPolicy::create` correctly authorizes admin/operator, denies viewer
- **Pass**: `EntryLinkPanel.vue` naming satisfies date-render arch guard
- **Pass**: Fail-loud behavior at mint time for unset `CANDIDATE_APP_URL` (exit 0 on `config:cache` unless set)
- **Pass**: `ParticipantPolicy::MODEL` is a real security distinction (arch test would fail without it)

**5 CRITICAL findings closed**: (1) no revocation test added, (2) participant-detail re-issue unit + E2E tests added, (3) lang-fallback end-to-end test added, (4) shared-minter consistency test added, (5) flake attribution corrected (unreproducible, cause unconfirmed)

## Source Folders

**NOTE: Source folders remain in openspec/changes/**

The following directories contain the complete change artifacts and have **NOT been deleted** per tool limitations:
- `openspec/changes/operator-interview-link/` — contains proposal, design, tasks, specs

**Action required**: Remove `openspec/changes/operator-interview-link/` manually after verifying the archive copy is complete.

## Main Specs Updated

- `openspec/specs/participant-sso/spec.md` — 6 ADDED requirements appended
- `openspec/specs/admin-backoffice/spec.md` — 4 ADDED requirements appended

Both specs now reflect the new capabilities for operator-minted entry links and backoffice UI.

## Carry-Forward Notes

**Critical limitations (design constraints, not defects):**
1. A candidate whose 120-minute candidate JWT expires while paused is STUCK — no recovery path exists. Participant status `in_corso` (paused) blocks even a freshly minted link from re-exchange. No new mechanism invented; limitation is visible in `terminal.vue` copy.
2. Operator-only signal for stranded candidate: participant at `in_corso` whose `question_index` stops advancing. No active alert wired; identified as a named follow-up.
3. Entry link is single-use and unrevokable; re-issued link leaves the previous one live for its remaining 30-minute TTL.
4. Production carries NO mail configuration on either `api` or `worker`, so notifications are not deliverable.

## SDD Cycle Status

**Complete.** The change has been fully planned (proposal), specified (delta specs merged into main specs), designed, implemented across all three services (44 tasks), independently verified with mutation testing (5 CRITICAL findings closed), and archived with full traceability. Ready for the next change.
