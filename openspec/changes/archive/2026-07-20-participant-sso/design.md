# Design: Participant + SSO Ingress (C6)

## Technical Approach

C6 adds a **fourth credential type** (candidate) beside `web` (user JWT), `api`
(user JWT), and `api-m2m` (opaque key). It mirrors C5's `api-m2m` mechanics
**exactly** but for a BEAI-minted JWT rather than an opaque key. tymon/jwt-auth
(already wired in C2, `api/config/jwt.php`, `AuthController`) mints two custom-claim
token types: a short-lived `typ:sso-link` (M2M → candidate handoff) and a
`typ:candidate` session token. The public exchange endpoint verifies the sso-link,
consumes its `jti` via an **atomic Redis SET NX** (single-use), applies entry gates,
atomically upserts the `Participant`, and mints the candidate JWT. A dedicated
`api-candidate` guard + `TenantContextCandidate` middleware isolate the candidate
path, mirroring `TenantContextM2m` (`api/app/Http/Middleware/TenantContextM2m.php`).

Grounded in C5 conventions: `ApiClient` (plain `Model`, Authenticatable-via-trait,
not-User, not-TenantModel, not-HasRoles, manual org-scoping in controllers), `TenantContextM2m`
(setBypass(false) first, fail-closed), the `Auth::viaRequest('api-m2m', …)` + minimal
`config/auth.php` entry pairing (`AppServiceProvider::boot`), and the C5 route isolation
(`->withoutMiddleware(TenantContext::class)` + inline stack, `bootstrap/app.php`).

## Architecture Decisions

See openspec/changes/participant-sso/design.md for full architecture decisions table and detailed file changes.

## Key Implementation Points

- 4 credential types: api (user), api-m2m (M2M key), api-candidate (candidate JWT), sso-link (consumed-once mint token).
- Candidate JWT TTL override: `JWTAuth::factory()->setTTL(120)` (2 hours; config default is 30 minutes).
- SSO link jti: consumed ATOMICALLY via Redis `SET sso_jti:<jti> 1 NX EX <ttl>` BEFORE gates (even if gate fails, token is spent).
- Org always from participant record, never from JWT claims or request input.
- Project at exchange: `Project::withoutGlobalScope('tenant')->findOrFail` (NOT plain findOrFail, NOT plural withoutGlobalScopes).
- Participant is plain Model with explicit org filters in M2M controllers (no global TenantScoped scope).
- All 403 responses on public exchange use generic "Access denied" body.

## Files Delivered

1. Migration: create_participants_table
2. Model: Participant (plain Model + Authenticatable)
3. Exception: ParticipantTransitionException
4. Middleware: TenantContextCandidate
5. Controllers: M2m/{Participant,SsoLink}Controller, Sso/SsoExchangeController, Candidate/SessionController
6. Service: CandidateTokenFactory
7. Resource: ParticipantResource
8. Modified: config/auth.php, AppServiceProvider, routes/api.php, bootstrap/app.php

## Testing Summary

- 558/558 tests PASS
- 97.4% overall coverage
- ≥95% coverage on all C6 security-critical paths
- All 40/40 tasks complete
- 1 WARNING: non-numeric sso-link sub → 500 on api guard (not an auth bypass; security invariant holds; deferred to C13 hardening)
- 2 SUGGESTIONS: role_code null-at-mint cosmetic, participant org_id not individually indexed (FK implicit index sufficient)

## Non-Goals (Locked)

- Interview engine / avatar / proctoring / utterances (C7)
- Conversation orchestration (C8)
- Scoring / 90% gate / evaluation retry (C9)
- Webhook DELIVERY + HMAC (C10) — C6 only stores candidate_ref
- Backoffice UI (C11)
- Notifications (C12)
- SoftDeletes (C13/GDPR)
- Candidate JWT revocation pre-expiry (forward dep: C7/C9 MUST add status checks)
- ParticipantCreated event dispatch (C10 owns this)
