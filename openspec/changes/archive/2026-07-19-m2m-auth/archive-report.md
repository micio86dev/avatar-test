# Archive Report: M2M API Authentication (C5)

**Date**: 2026-07-19
**Change**: `m2m-auth`
**Status**: ARCHIVED
**Store mode**: Hybrid (openspec/hybrid)

---

## Executive Summary

M2M API Authentication (C5) has been completed, verified, and archived. The change delivers opaque API-key authentication for external machine clients via an `ApiClient` model, custom `api-m2m` guard, `TenantContextM2m` middleware, ability model, and credential-management API. Implementation: DONE (merge commit `39160a6` on `api/develop`). Verification: PASS WITH WARNINGS (406/406 tests, 96.3% coverage, no CRITICAL issues). Specs: merged into main spec tree with delta tenancy requirements integrated.

---

## Verification Status

| Metric | Value |
|---|---|
| Implementation branch | `feature/c5-m2m-auth` (api submodule) |
| Final merge commit | `39160a6` (merged to `api/develop` via PR #4) |
| Tests | 406/406 PASSED |
| Coverage | 96.3% (target ~95%) |
| C5 security-critical zone | 100% core classes; defensive branches 81.8% (unreachable) |
| Verdict | PASS WITH WARNINGS (2 coverage gaps, no security exposure) |
| Tasks complete | 33/33 ✓ |

---

## Capabilities Shipped

### NEW: `m2m-auth`

Opaque API-key authentication for external machine clients (HR/LMS/ATS systems).

**Components**:
- `ApiClient` Eloquent model (org_id-first indexes per D22, unscoped, Authenticatable via trait)
- `api_clients` migration (key_hash unique, is_active, expires_at, last_used_at)
- `Auth::viaRequest('api-m2m', ...)` guard (bearer → sha256 → unique index lookup)
- Redis denylist check (fail-safe to DB re-query on outage)
- `TenantContextM2m` middleware (fail-closed, `setBypass(false)` → `setOrgId` → `setPermissionsTeamId`)
- Flat JSONB `abilities` array (6 canonical abilities: participants:create/read, evaluations:read, progress:read, projects:read, sso_link:generate)
- `CheckAbility` middleware (per-route ability enforcement, runs before SubstituteBindings)
- Credential-management API: POST|GET|DELETE `/api/m2m/clients` (admin-only)
- Machine endpoint: GET `/api/m2m/whoami` (M2M group, no ability required)

**Key Security Properties**:
- Raw API key: `beai_live_` + 48-byte random, returned ONCE in 201 response, never retrievable
- Storage: SHA-256 hash at rest in `key_hash` (unique index)
- Guard non-interchangeability: M2M key rejected by human `auth:api`, human JWT rejected by `auth:api-m2m`
- Revocation: DB write (is_active=false) BEFORE Redis denylist, immediate (no grace)
- Cross-org isolation: org from client record ONLY (request input ignored)
- M2M routes isolated: `->withoutMiddleware(TenantContext::class)` + inline stack

---

### MODIFIED: `tenancy` (C2)

**Delta Requirements Added**:

1. **TenantContextM2m — Second Org-Resolution Path**
   - Sibling (not subclass) of TenantContext
   - Resolves org from ApiClient record for M2M requests
   - Intentional reversal: `setBypass(false)` BEFORE `setOrgId($orgId)` (belt-and-suspenders hardening)
   - Fail-closed: null client or org → 401 (no fallback)
   - Scenarios: client org resolved, null client/org fail-closed, bypass cleared before org set, stale bypass prevention, tampered org ignored

2. **M2M Route Group Does Not Inherit Global TenantContext**
   - M2M routes call `->withoutMiddleware(TenantContext::class)` (explicit strip)
   - Inline stack: auth:api-m2m → TenantContextM2m → SubstituteBindings
   - Admin mgmt routes use global `api` group TenantContext (no inline duplication)
   - Isolation prevents silent org-context bypass (TenantContext would pass through on null User)
   - Scenarios: TenantContext NOT invoked on M2M routes, no silent bypass, withoutMiddleware proven, null-passthrough does NOT affect M2M

**Impact on Existing C2 `tenancy` Content**:
- All existing C2 requirements preserved (Organization model, Platform Superadmin, TenantScoped isolation, TenantContext middleware, cross-tenant write isolation, DB-verified org claim, migrations, RefreshDatabase scoping)
- Two new requirements appended (TenantContextM2m, M2M Route Group isolation)
- C2's human TenantContext untouched (`setOrgId()` then `setBypass(false)` order unchanged)
- C2 boundary intact: no breaking changes

---

## Specs Synced to Main Tree

### Created: `/openspec/specs/m2m-auth/spec.md`

**10 requirements, 24 scenarios** (all scenarios passing tests):

1. **REQ-1**: ApiClient Model and Schema (org_id-first indexes, key_hash unique, is_active default, unscoped)
2. **REQ-2**: Opaque API-Key Issuance (raw key returned once, SHA-256 at rest, never retrievable)
3. **REQ-3**: `api-m2m` Guard via `Auth::viaRequest` (minimal config entry, bearer lookup, Redis denylist, fail-safe DB re-query)
4. **REQ-4**: TenantContextM2m Middleware (org resolution fail-closed, `setBypass(false)` reversal)
5. **REQ-5**: M2M Route Group Isolation (withoutMiddleware TenantContext, inline stack ordering)
6. **REQ-6**: Ability Model (6 canonical abilities, strict in_array, CheckAbility before SubstituteBindings)
7. **REQ-7**: Revocation (immediate, DB before Redis, Redis-down fail-safe, full active() scope re-query)
8. **REQ-8**: Credential Management Endpoints (admin-only POST|GET|DELETE /api/m2m/clients, no show endpoint)
9. **REQ-9**: Machine `whoami` Endpoint (GET /api/m2m/whoami, client_id + org_id + abilities)
10. **REQ-10**: Cross-Org Isolation (org always from record, never input)

### Modified: `/openspec/specs/tenancy/spec.md`

**Delta merge outcome**:

Appended 2 new requirements after existing C2 tenancy content:

- **REQ-T1**: TenantContextM2m — Second Org-Resolution Path (5 scenarios)
- **REQ-T2**: M2M Route Group Does Not Inherit Global TenantContext (4 scenarios)

**Preserved**: All 8 existing C2 requirements (Organization Model, Platform Superadmin, TenantScoped Read/Create, Cross-Tenant Write, Superadmin Bypass, TenantContext Middleware, DB-Verified Org Claim, Migration/Index Compliance, RefreshDatabase Scoping).

**Rationale**: C5 introduces a second identity (ApiClient) and a second org-resolution path (TenantContextM2m) on isolated routes. These are additive to C2's human-user tenancy; they do not modify C2's behavior. The tenancy spec now documents both paths and their isolation guarantee.

---

## Archive Contents

| Artifact | Location | Status |
|----------|----------|--------|
| proposal.md | `openspec/changes/archive/2026-07-19-m2m-auth/proposal.md` | ✓ |
| design.md | `openspec/changes/archive/2026-07-19-m2m-auth/design.md` | ✓ |
| tasks.md | `openspec/changes/archive/2026-07-19-m2m-auth/tasks.md` | ✓ |
| verify-report.md | `openspec/changes/archive/2026-07-19-m2m-auth/verify-report.md` | ✓ |
| specs/m2m-auth/spec.md | `openspec/changes/archive/2026-07-19-m2m-auth/specs/m2m-auth/spec.md` | ✓ |
| specs/tenancy/spec.md | `openspec/changes/archive/2026-07-19-m2m-auth/specs/tenancy/spec.md` | ✓ |
| archive-report.md | `openspec/changes/archive/2026-07-19-m2m-auth/archive-report.md` | ✓ |

**Main spec tree promoted**:
- `/openspec/specs/m2m-auth/spec.md` ← NEW (created from change spec)
- `/openspec/specs/tenancy/spec.md` ← MODIFIED (delta merged)

---

## Test Coverage

### Verdict: PASS WITH WARNINGS

- **0 CRITICAL issues**
- **2 WARNINGS** (both non-security):
  1. TenantContextM2m fail-closed branches (lines 53, 60) unreachable because auth guard fires 401 first + FK constraint. Defensive guards; security invariant still enforced by auth guard + DB schema.
  2. ApiClientController destroy TTL branch + Redis catch untested (lines 139, 143). Revocation correctness fully tested; these are edge cases (TTL calc on non-null expires_at, Redis failure during revoke).
- **1 SUGGESTION** (S1): Direct unit test for `active()` scope (currently covered indirectly)

### Test Summary

| Suite | Total | Passed | Coverage |
|-------|-------|--------|----------|
| Feature (C5) | ~100 | 100 ✓ | ~98% |
| Unit (C5) | ~50 | 50 ✓ | ~99% |
| Arch (C5) | ~5 | 5 ✓ | ~100% |
| Full suite (all C1-C4+C5) | 406 | 406 ✓ | 96.3% |

**C5 Security-Critical Zone** (100% coverage):
- ApiClient model: 100%
- ApiKeyGenerator: 100%
- AbilitiesValidator: 100%
- CheckAbility: 100%
- WhoamiController: 100%
- ApiClientResource: 100%
- ApiClientPolicy: 100%
- Guard closure logic: 100% (unique index lookup, Redis denylist, DB re-query)
- Revocation ordering: 100% (DB before Redis)
- Cross-org isolation: 100%
- No-silent-bypass: 100% (RouteIsolationTest + TenantContextM2m)

---

## Merge Commit & Implementation

| Detail | Value |
|--------|-------|
| Feature branch | `feature/c5-m2m-auth` (api submodule) |
| Merge commit | `39160a6` |
| Target | `api/develop` |
| PR | #4 |
| Status | MERGED ✓ |
| Coverage post-merge | 96.3% (406/406 tests) |

**Note on "405-vs-404" scenario**: The spec requirement is that no show endpoint exists (key never retrievable). A GET /api/m2m/clients/{id} returns HTTP 405 (DELETE route exists on that URI pattern), not 404. Both statuses prove the security invariant (key not retrievable); test accepts either. No security exposure.

---

## Task Completion

All 33 tasks marked complete across 4 phases:

- Phase 1 — Foundation (1.1–1.11): Migration, ApiClient model, guard wiring, unit tests ✓
- Phase 2 — Middleware + Routes (2.1–2.11): TenantContextM2m, route isolation, whoami, isolation tests ✓
- Phase 3 — Credential Mgmt (3.1–3.11): Controller, policy, resource, admin-only tests ✓
- Phase 4 — Arch + Cleanup (4.1–4.4): Architecture assertions, abilities config, coverage validation ✓

**No unchecked implementation tasks remain**.

---

## SDD Cycle Complete

Change `m2m-auth` (C5) has progressed through all SDD phases:

1. **Proposal** ✓ (Intent, scope, capabilities, approach, affected areas, risks, rollback, dependencies, success criteria)
2. **Spec** ✓ (10 requirements, 24 scenarios, non-goals, security notes)
3. **Design** ✓ (Technical approach, architecture decisions, data flow, interfaces, testing strategy, delivery forecast)
4. **Tasks** ✓ (Review workload forecast, 4 phases, 33 tasks, delivery note)
5. **Apply** ✓ (Implementation DONE: merge commit 39160a6, api/develop, PR #4)
6. **Verify** ✓ (406/406 tests, 96.3% coverage, PASS WITH WARNINGS, no CRITICAL)
7. **Archive** ✓ (Specs synced to main tree, change folder archived, audit trail complete)

---

## Traceability

**Engram observation IDs** (hybrid mode artifacts):

| Artifact | Engram ID | Topic Key |
|----------|-----------|-----------|
| Proposal | 383 | sdd/m2m-auth/proposal |
| Design | 395 | sdd/m2m-auth/design |

**Openspec artifacts** (filesystem):

- `openspec/changes/archive/2026-07-19-m2m-auth/proposal.md`
- `openspec/changes/archive/2026-07-19-m2m-auth/design.md`
- `openspec/changes/archive/2026-07-19-m2m-auth/tasks.md`
- `openspec/changes/archive/2026-07-19-m2m-auth/verify-report.md`
- `openspec/changes/archive/2026-07-19-m2m-auth/specs/m2m-auth/spec.md`
- `openspec/changes/archive/2026-07-19-m2m-auth/specs/tenancy/spec.md`

**Promoted main specs**:

- `openspec/specs/m2m-auth/spec.md` (NEW)
- `openspec/specs/tenancy/spec.md` (MODIFIED: delta merged)

---

## Notes

1. **C5 is fully isolated additive code**: No existing C1–C4 auth, tenancy, or routing behavior is changed. TenantContext remains untouched; C2 tests continue to pass.

2. **Tenancy delta merge preserves C2**: The new TenantContextM2m requirements do not modify C2's human TenantContext. C2's org resolution (setOrgId THEN setBypass(false)) is unchanged. C5 deliberately reverses the order for M2M (setBypass THEN setOrgId) as a hardening — no conflict.

3. **Route isolation is explicit and tested**: M2M routes call `->withoutMiddleware(TenantContext::class)` — this is proven by RouteIsolationTest, which asserts human TenantContext is NOT in the resolved middleware stack for M2M whoami.

4. **No spec requirements deferred**: All 10 C5 requirements + 2 tenancy deltas implemented and tested. Open questions (ability vocabulary for C6/C10, TTL window, Redis fallback) are noted in design but do not block C5 closure.

5. **Ready for next slice**: C6 (candidate magic-link SSO) can now rely on M2M org resolution and the ability model for permission gates. C10 (webhooks) can use M2M credentials for org-scoped secret management.

---

## Sign-Off

**Change**: m2m-auth (C5)  
**Status**: ARCHIVED  
**Date**: 2026-07-19  
**Verdict**: PASS WITH WARNINGS → ARCHIVED  
**Next**: Begin C6 (participant SSO) or continue with blocked C7+ scope definition  

The SDD cycle for C5 is COMPLETE. All artifacts are in the archive and the main spec tree.
