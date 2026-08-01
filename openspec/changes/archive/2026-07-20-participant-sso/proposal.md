# Proposal: Participant + SSO Ingress (C6)

## Intent

External M2M clients (C5) must be able to enrol candidates and hand them a link
that lets them enter the interview — the candidate ingress path. C6 delivers the
`Participant` domain model, its lifecycle column, the SSO ingress mechanism, and a
dedicated candidate auth guard that later slices (C7 interview, C9 scoring,
C10 webhooks) build on. Without C6 no candidate can authenticate; the interview
engine has no identity to attach to. Binding sources:
`docs/app_description/04-integration-surface/01-ingresso-sso.md`,
`05-business-rules/01-lifecycle-candidato.md`, `CLAUDE.md` (SSO ingress, lifecycle).

## Scope

### In Scope
- `Participant` model (plain `Model` + `Authenticatable` trait, mirrors `ApiClient`) + migration:
  unique `(project_id, candidate_ref)`, org_id-first composite indexes (D22), `status`
  enum (default `in_attesa`), `display_name` NOT NULL, `organization_id` set EXPLICITLY
  from `$project->organization_id` at creation (NOT TenantScoped.creating — Participant
  is NOT a TenantModel), NOT fillable from input or token claims. No SoftDeletes in C6.
- M2M endpoints: participant create/read (`participants:create`/`participants:read`) +
  `POST /api/m2m/sso-link` (mints short-lived `typ:sso-link` JWT, RAW custom claims),
  gated by C5 abilities; refuses past-deadline projects; 422 if role_code supplied for
  potential project; 422 if role_code mismatches project.role_code for standard project;
  422 if display_name absent; **MINT GATE: 409 if a participant already exists for
  (project_id, candidate_ref) with status ∈ {completato, errore}** (prevents flooding a
  finished candidate with tokens; in_attesa mints normally). M2M participant index/show
  scope MANUALLY by org via explicit `->where('organization_id', $orgId)` (no global
  TenantScoped scope).
- Public `GET /api/sso/exchange` (`->withoutMiddleware(TenantContext::class)`):
  verify (sig+exp+`typ`) → **ATOMIC jti consume via Redis `SET sso_jti:<jti> 1 NX EX <ttl>`
  BEFORE gates/upsert** (TTL = max(token.exp - now, 60s); NX failure = replay → 401; token
  spent even if gate fails — deliberate security choice; `sso_jti:` prefix is DISTINCT from
  tymon's blacklist key namespace). **The mint does NOT store the jti in Redis** — the EXCHANGE
  performs the sole atomic consume. Project resolved via `Project::withoutGlobalScope('tenant')->findOrFail($projectId)`
  (MANDATORY — `Project` extends `TenantModel`; TenantScoped is registered as named scope `'tenant'`;
  at this public endpoint TenantResolver is NOT set, so plain `findOrFail()` becomes
  `WHERE organization_id = null` → 0 rows → 100% broken. `withoutGlobalScope('tenant')` bypasses
  ONLY the tenant filter, KEEPING SoftDeletingScope active — a soft-deleted project is NOT findable
  → 401 (correct). `withoutGlobalScopes()` plural MUST NOT be used — it strips SoftDeletes too.
  The `project_id` claim is HMAC-signed and trusted). Non-existent project → 401 (NOT 404).
  display_name claim MUST be non-empty in the sso-link JWT; absent/empty → 401 (invalid token,
  before the Project resolve). Defense against DB NOT NULL constraint violation → 500.
  **Pre-flight read** (primary blocked-status check): `SELECT status FROM participants WHERE
  project_id=? AND candidate_ref=?` — if status ≠ 'in_attesa' (ANY of: in_corso, in_valutazione,
  completato, errore) → 403 generic. Entry gates (NULL-safe: `status='active' AND
  (goes_live_at IS NULL OR <=now()) AND (deadline_at IS NULL OR >now())`) → role_code belt check
  → atomic upsert (`org_id` from `$project->organization_id`; ON CONFLICT SET clause MUST NOT
  include `organization_id`, `project_id`, or `candidate_ref`; WHERE status='in_attesa' as
  secondary safety net) → mint `typ:candidate` JWT via `JWTAuth::fromUser($participant)`
  (model-bound, stamps `prv = hash(App\Models\Participant)`). ALL 403 responses use a generic
  "Access denied" body (no gate reason disclosed).
- `api-candidate` guard (viaRequest + minimal `config/auth.php` entry, no provider key) —
  closure: SINGLE decode `$payload = JWTAuth::setToken($rawToken)->checkOrFail()` (returns
  validated Payload; NOT two separate setToken calls — JWTAuth singleton staleness risk) →
  assert `typ==='candidate'` from returned `$payload` (PRIMARY defense; tymon does NOT check
  custom claims) → validate sub positive int → `Participant::find($sub)` (unscoped).
  Candidate JWT minted via `JWTAuth::fromUser($participant)` carries `prv = hash(App\Models\Participant)` —
  SECONDARY defense: `api` guard rejects candidate JWT via prv MISMATCH (token prv ≠
  hash(App\Models\User); this is via subject validation in authenticate(), NOT required_claims —
  `prv` is NOT in required_claims `[iss,iat,exp,nbf,sub,jti]`).
  SSO-link JWT on `api` guard: rejected via `User::find(candidate_ref)` → null (non-numeric
  sub), NOT via "prv absent → required_claims rejects it" (that claim is incorrect).
- `TenantContextCandidate` middleware (fail-closed, org from record); candidate route group
  AND public exchange route both declare `->withoutMiddleware(TenantContext::class)`.
- `GET /api/candidate/session` whoami (participant + project config + `exit_redirect_url`).
- Lifecycle: `→ in_attesa` creation + model transition-guard backstop (throws
  `ParticipantTransitionException` → HTTP 422, NOT RuntimeException → 500).

### Out of Scope
- Interview engine / avatar / proctoring / utterance ingestion (C7).
- Conversation orchestration (C8); scoring + 90% gate + retry evaluation (C9).
- Webhook DELIVERY + HMAC signing (C10) — C6 only stores `candidate_ref` verbatim.
  **`ParticipantCreated` event dispatch is NOT part of C6** — C10 will add the
  dispatch point. C6 does not dispatch any domain events.
- Backoffice UI (C11); notifications (C12); retry-token re-issuance (C9);
  the exit-redirect TRIGGER itself (C7 — C6 only surfaces the URL).
- SoftDeletes on Participant (C13/GDPR concern; if added later, the guard returns 401
  for soft-deleted participants holding live tokens).
- Candidate JWT revocation pre-expiry (C7/C9 routes gated on `auth:api-candidate` MUST
  add a status check to block post-`completato`/`errore` calls — forward dependency).

## Capabilities

### New Capabilities
- `participant-sso`: Participant model + lifecycle, M2M participant CRUD +
  SSO-link mint, public SSO exchange, candidate JWT guard, entry gating,
  candidate session endpoint.

### Modified Capabilities
- `tenancy`: candidate org-resolution delta — `TenantContextCandidate` resolves
  org from the `Participant` record on the candidate guard path. Lives in
  `participant-sso` (candidate-guard-specific), referenced from `tenancy`. CLOSED.

## Success Criteria

- [x] `Participant` plain Model + Authenticatable (mirrors ApiClient); migration (unique
  `(project_id, candidate_ref)`, org_id-first indexes, display_name NOT NULL, no SoftDeletes);
  org_id set EXPLICITLY from project at creation, NOT TenantScoped.creating, NOT fillable.
- [x] M2M participant CRUD (explicit org scoping via ->where) + sso-link mint gated by C5
  abilities; both `SsoLinkController` and `ParticipantController::store` resolve project
  scoped to caller org (`Project::where('organization_id', $clientOrgId)->findOrFail`); cross-org
  project → 404; 422 for role_code (standard mismatch, any for potential), 422 for absent
  display_name; sso-link refuses past-deadline; **mint gate: 409 if participant exists with
  status ∈ {completato, errore}**.
- [x] Public exchange steps (canonical order): (1) parse+verify sig+exp → 401; (2) assert
  typ==='sso-link' → 401; (3) atomic jti consume `SET sso_jti:<jti> 1 NX EX <ttl>` BEFORE
  gates (`sso_jti:` prefix distinct from tymon blacklist namespace; mint does NOT pre-store jti);
  (4) assert non-empty `display_name` in claims → 401 if absent/empty (defense against NOT NULL
  constraint violation; jti already consumed at step 3 — token cannot be replayed); (5) resolve
  **`Project::withoutGlobalScope('tenant')->findOrFail($projectId)`** (NOT plain findOrFail —
  TenantScoped scope would filter to org=null → 0 rows → 401; NOT `withoutGlobalScopes()` plural
  — strips SoftDeletes); (6) entry gates NULL-safe → 403 generic; (7) role_code belt check → 403 generic; (8) **pre-flight read: if participant status ≠
  'in_attesa' (including in_corso, in_valutazione, completato, errore) → 403 generic** (primary
  blocked-status check; race-safe because jti already consumed at step 3); (9) atomic upsert
  (org from project; ON CONFLICT SET clause excludes org_id/project_id/candidate_ref;
  WHERE status='in_attesa' as secondary net — forward dep: 0-row upsert if C7+ moves status
  between step 8 and upsert; C7 MUST handle 0-row case; language = sso-link lang →
  project.language → 'en') → (10) candidate JWT via `JWTAuth::factory()->setTTL(120)->fromUser()`
  (REQUIRED — config default 30 min; `role_code` claim name, not `role`; prv-bound).
  Replayed/expired/wrong-typ/missing-project/empty-display_name → 401; failed gate → 403 generic
  body. Exchange route: withoutMiddleware(TenantContext).
- [x] `api-candidate` guard: viaRequest closure uses SINGLE decode `$payload = JWTAuth::setToken($raw)->checkOrFail()`
  (returns validated Payload; NOT two separate setToken calls; NOT `authenticate()`); read `typ` and
  `sub` from returned `$payload`; typ assert primary + sub positive-int check + `Participant::find`
  unscoped; no provider key in config/auth.php; candidate JWT minted via fromUser carries
  `prv = hash(App\Models\Participant)` — SECONDARY defense: `api` guard rejects via prv MISMATCH
  (subject validation in authenticate(), NOT via required_claims — `prv` is NOT in required_claims);
  sso-link JWT rejected by `api` guard via `User::find(candidate_ref)` → null (not "prv absent →
  required_claims").
- [x] `organization_id` NOT in `$fillable` on Participant (named security invariant — structural
  analog to ApiClient; ApiClient protects `key_hash` with `organization_id` IS fillable; Participant
  protects `organization_id`); set only from `$project->organization_id` via forceFill/direct assignment.
- [x] `participants.language` always a non-null supported locale: sso-link lang claim → project.language → config('app.fallback_locale').
- [x] `TenantContextCandidate` fail-closed org-from-record; candidate route group AND exchange
  route both withoutMiddleware(TenantContext); explicit middleware-stack test.
- [x] Guard non-interchangeability (4 guards, 2 layers) proven; cross-tenant isolation
  (explicit org filter in M2M controllers + dedicated test); `candidate_ref` stored verbatim.
- [x] Lifecycle: `→ in_attesa` creation + model transition-guard backstop (ParticipantTransitionException
  → HTTP 422; registered in bootstrap/app.php); C6 fires nothing beyond `in_attesa`.
- [x] No ParticipantCreated event in C6 (C10 concern). No SoftDeletes in C6.
