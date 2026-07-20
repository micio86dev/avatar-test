# Participant + SSO Ingress Specification (C6)

## Purpose

Delivers the `Participant` domain model, candidate lifecycle column, SSO ingress
mechanism, and the `api-candidate` guard that C7/C9/C10 build on. Enables an M2M
client to enrol a candidate and hand them a single-use entry link; the candidate
exchanges it for a session JWT that identifies them for the rest of the interview.

Coverage target: 95% (security-critical path).

---

## Non-Goals

- Interview engine / avatar / utterance ingestion (C7)
- Conversation orchestration (C8)
- Scoring, 90% gate, evaluation retry (C9)
- Webhook DELIVERY and HMAC signing (C10) — C6 stores `candidate_ref` verbatim only
- Backoffice UI (C11)
- Notifications (C12)
- Retry-token re-issuance (C9)
- Exit-redirect trigger (C7) — C6 surfaces `exit_redirect_url` in the session response; the redirect fires in C7
- `in_corso` / `in_valutazione` / `completato` / `errore` transitions (C6 writes `in_attesa` only; later slices drive the rest)
- `ParticipantCreated` event dispatch (C10 will add the dispatch point; C6 does NOT dispatch it)
- Candidate JWT revocation pre-expiry (forward dependency: C7/C9 routes gated on `auth:api-candidate` MUST add a status check to block post-`completato`/`errore` calls; without it a live token can reach candidate routes after completion)
- SoftDeletes on Participant (C6 does NOT add SoftDeletes; forward note: if C13/GDPR adds SoftDeletes, `Participant::find($sub)` in the guard returns null for a soft-deleted participant, yielding 401)

---

## Requirements

### Requirement: Participant Model and Schema

The `Participant` model MUST extend `Illuminate\Database\Eloquent\Model` (plain Model)
and implement `Illuminate\Contracts\Auth\Authenticatable` via the
`Illuminate\Auth\Authenticatable` trait. It MUST be: NOT TenantModel, NOT
Foundation\Auth\User, NO HasRoles, NO TenantScoped global scope.

The analogy to `ApiClient` is STRUCTURAL — each model has exactly ONE protected field
excluded from `$fillable`:
- `ApiClient`: `key_hash` is NOT fillable (note: `organization_id` IS in
  `ApiClient.$fillable`).
- `Participant`: `organization_id` is NOT fillable (the protected field differs per
  model).

Do NOT copy `ApiClient.$fillable` verbatim. The invariant is that each model's
security-critical field is excluded from mass-assignment; the specific field differs.

The `participants` table MUST contain: `id`, `organization_id` (FK to organizations,
indexed, NOT NULL), `project_id` (FK cascadeOnDelete), `candidate_ref` (string,
verbatim from caller), `display_name` (NOT NULL), `role_code` (nullable),
`language` (nullable), `status` enum (`in_attesa|in_corso|in_valutazione|completato|errore`,
default `in_attesa`), `started_at` / `completed_at` (nullable `timestampTz`),
`created_at`, `updated_at`. No SoftDeletes column in C6.

`timestampTz` for `started_at`/`completed_at` is intentional (timezone-aware, best
practice) even though the C4 `projects` migration used plain `timestamp`. This
divergence is acceptable; keep `timestampTz` here.

Unique constraint: `(project_id, candidate_ref)`. All composite indexes MUST lead
with `organization_id` (D22).

`organization_id` MUST NOT be in `$fillable` on the `Participant` model. This is a
**named security invariant**: the field MUST NOT be mass-assignable from request input
or token claims. It MUST be set EXPLICITLY from `$project->organization_id`
server-side at creation — in the exchange upsert INSERT and in the M2M create path —
using `forceFill` or direct assignment. It is NOT stamped by TenantScoped.creating
(Participant is not a TenantModel), NOT derived from request input, and NOT derived
from JWT claims.

#### Scenario: Table created with required columns and constraints

- GIVEN the `participants` migration is applied
- WHEN the schema is inspected
- THEN `UNIQUE(project_id, candidate_ref)` exists
- AND composite indexes lead with `organization_id`
- AND `organization_id` has a NOT NULL FK to organizations
- AND there is NO `deleted_at` column (no SoftDeletes in C6)

#### Scenario: organization_id stamped from project, not fillable, not from token

- GIVEN a `Participant` is created for `project_id=7` which belongs to `organization_id=3`
- WHEN the record is saved with `organization_id=99` in the payload or JWT claim
- THEN the persisted `organization_id` is `3`
- AND `99` is discarded — server always reads from `$project->organization_id`

#### Scenario: candidate_ref stored verbatim

- GIVEN an SSO link mint supplies `candidate_ref="EXT-ABC-001"`
- WHEN the participant is created or updated
- THEN `candidate_ref` in the DB equals `"EXT-ABC-001"` byte-for-byte

---

### Requirement: Participant Model Lifecycle Guard

The `Participant` model MUST expose a transition-guard backstop in `booted()` that
rejects status transitions outside the defined state machine. Illegal transitions MUST
throw a `ParticipantTransitionException` (domain exception), which MUST be registered
in `bootstrap/app.php` to render HTTP 422. It MUST NOT throw a bare `RuntimeException`
(which would yield HTTP 500). This mirrors `ImmutableProjectException`/
`LockedFrameworkVersionException` from C4.

C6 MUST only write `in_attesa`; no other status transition may be triggered by C6 code.

#### Scenario: New participant starts in in_attesa

- GIVEN the exchange endpoint creates a participant
- WHEN the record is first inserted
- THEN `status` is `in_attesa`
- AND `started_at` and `completed_at` are null

#### Scenario: Transition guard rejects illegal jump — throws domain exception

- GIVEN a `Participant` with `status = in_attesa`
- WHEN code attempts to set `status = completato` directly (bypassing normal flow)
- THEN `ParticipantTransitionException` is thrown
- AND the model guard renders HTTP 422 (NOT 500)
- AND the record is not mutated

#### Scenario: C6 never sets status beyond in_attesa

- GIVEN the full C6 code path executes (mint → exchange → upsert → session)
- WHEN all operations complete
- THEN no `Participant` record has a status other than `in_attesa`

---

### Requirement: M2M SSO-Link Mint

The endpoint `POST /api/m2m/sso-link` MUST be accessible only to M2M clients
authenticated via the `api-m2m` guard and holding the `sso_link:generate` ability.
It MUST mint a `typ:sso-link` JWT as RAW custom claims (NOT via `JWTAuth::fromUser`
— the sso-link is not bound to an Authenticatable model). TTL: 30 minutes.
It MUST refuse minting when entry gates are not met.

**MINT GATE**: Before minting, the endpoint MUST check whether a `Participant` already
exists for `(project_id, candidate_ref)` with `status ∈ {completato, errore}`. If such
a record exists → HTTP 409 Conflict (do NOT mint). Rationale: prevents an M2M client
from flooding a finished candidate with useless single-use tokens and causing Redis key
churn. A participant that does not yet exist, or has `status = in_attesa`, mints
normally. `status ∈ {in_corso, in_valutazione}` is NOT blocked at mint (interview in
progress or being scored — reconnect scenarios are possible); only terminal statuses
block minting.

The sso-link JWT MUST carry `sub = candidate_ref` (a string value). This is REQUIRED
because `config/jwt.php` lists `'sub'` in `required_claims`; a RAW mint without `sub`
causes `TokenInvalidException` at parse time, making the exchange 100% broken. The
`candidate_ref` is also carried in its own dedicated claim; `sub` is present solely to
satisfy tymon's required_claims. `iss`, `iat`, `exp`, `nbf`, and `jti` are
auto-populated by tymon's factory for RAW mints; only `sub` requires explicit setting.

The `jti` is NOT stored in Redis at mint time. The EXCHANGE endpoint performs the
sole atomic consume: `SET sso_jti:<jti> 1 NX EX <ttl>` (NX succeeds on first use →
proceed; key already exists → 401 replay). The HMAC signature alone proves BEAI minted
the token; no mint-time pre-store is needed.

`display_name` MUST be present and non-empty — absent or empty → HTTP 422.

**Claim name for role**: the sso-link JWT MUST use the claim name `role_code` (not `role`)
for the candidate's role. The candidate JWT MUST also use `role_code`. This name MUST be
consistent in both token types and in exchange validation logic.

#### Scenario: Valid M2M client mints SSO link

- GIVEN an `ApiClient` authenticated with `sso_link:generate` ability
- AND the target project has `status = active`,
  `(goes_live_at IS NULL OR goes_live_at <= now())`,
  `(deadline_at IS NULL OR deadline_at > now())`
- WHEN `POST /api/m2m/sso-link` is called with valid project/candidate data including `display_name`
- THEN HTTP 201 is returned
- AND the response body contains a `token` field holding a `typ:sso-link` JWT
- AND the JWT carries `sub = candidate_ref` (satisfying tymon's required_claims)
- AND no Redis write is performed at mint time (the jti is consumed only at exchange)

#### Scenario: Missing ability returns 403

- GIVEN an `ApiClient` authenticated but WITHOUT `sso_link:generate`
- WHEN `POST /api/m2m/sso-link` is called
- THEN HTTP 403 is returned
- AND no token is minted

#### Scenario: Past-deadline project returns 403

- GIVEN the target project has `deadline_at = yesterday`
- WHEN `POST /api/m2m/sso-link` is called by a valid M2M client
- THEN HTTP 403 is returned
- AND no token is minted

#### Scenario: display_name absent returns 422

- GIVEN a valid M2M client with `sso_link:generate`
- WHEN `POST /api/m2m/sso-link` is called WITHOUT `display_name` (or with empty string)
- THEN HTTP 422 is returned
- AND no token is minted

#### Scenario: role_code validated for standard project at mint time

- GIVEN a standard-type project with `role_code = "FLL"`
- AND the mint request supplies `role_code = "BUL"`
- WHEN `POST /api/m2m/sso-link` is called
- THEN HTTP 422 is returned
- AND no token is minted

#### Scenario: role_code rejected for potential project at mint time

- GIVEN a potential-type project (no project-level role_code)
- AND the mint request supplies ANY `role_code` (e.g. `"MLL"`)
- WHEN `POST /api/m2m/sso-link` is called
- THEN HTTP 422 is returned
- AND no token is minted
- NOTE: role_code is NEVER silently nulled for potential projects — 422 surfaces the integration bug

#### Scenario: goes_live_at NULL does not block mint

- GIVEN a project with `goes_live_at = NULL` (no go-live restriction)
- WHEN `POST /api/m2m/sso-link` is called
- THEN the gate passes (NULL = no restriction)

#### Scenario: deadline_at NULL does not block mint

- GIVEN a project with `deadline_at = NULL` (no expiry)
- WHEN `POST /api/m2m/sso-link` is called
- THEN the gate passes (NULL = no expiry)

#### Scenario: Mint gate — participant status completato blocks mint (409)

- GIVEN a `Participant` exists for `(project_id, candidate_ref)` with `status = completato`
- WHEN `POST /api/m2m/sso-link` is called for that same `(project_id, candidate_ref)`
- THEN HTTP 409 Conflict is returned
- AND no sso-link token is minted
- AND no Redis write occurs

#### Scenario: Mint gate — participant status errore blocks mint (409)

- GIVEN a `Participant` exists for `(project_id, candidate_ref)` with `status = errore`
- WHEN `POST /api/m2m/sso-link` is called for that same pair
- THEN HTTP 409 Conflict is returned
- AND no sso-link token is minted

#### Scenario: Mint gate — participant status in_attesa does NOT block mint

- GIVEN a `Participant` exists for `(project_id, candidate_ref)` with `status = in_attesa`
- WHEN `POST /api/m2m/sso-link` is called for that same pair
- THEN minting proceeds normally (HTTP 201)
- NOTE: in_corso and in_valutazione also do NOT block mint (reconnect scenarios)

#### Scenario: M2M client of Org A cannot mint an sso-link for an Org B project

- GIVEN an `ApiClient` for Org A with `sso_link:generate`
- AND `project_id` in the mint request belongs to Org B
- WHEN `POST /api/m2m/sso-link` is called
- THEN HTTP 404 is returned (project not found in Org A's tenant)
- AND no sso-link token is minted

---

### Requirement: M2M Participant CRUD

`POST /api/m2m/participants` (ability `participants:create`) MUST create or return
a `Participant` (upsert on `(project_id, candidate_ref)`). `organization_id` MUST
be set explicitly from `$project->organization_id` — NOT from request input.

The `project_id` input MUST be resolved scoped to the authenticated client's organization:
`Project::where('organization_id', $clientOrgId)->findOrFail($projectId)`. A project
in another org returns 404 (not found in the caller's tenant).

`GET /api/m2m/participants` and `GET /api/m2m/participants/{id}` (ability
`participants:read`) MUST scope results MANUALLY by the authenticated client's
`organization_id` via an explicit `->where('organization_id', $orgId)` filter
(mirrors `ApiClientController`). There is no global TenantScoped scope on Participant.

#### Scenario: M2M create participant

- GIVEN an `ApiClient` with `participants:create`
- WHEN `POST /api/m2m/participants` with valid project/candidate data
- THEN HTTP 201 is returned
- AND the participant exists with `status = in_attesa` and `organization_id` from the project
- AND `organization_id` from request body (if any) is ignored

#### Scenario: M2M list participants scoped to caller org

- GIVEN an `ApiClient` for Org A
- WHEN `GET /api/m2m/participants` is called
- THEN only participants with `organization_id = A` are returned
- AND no Org B participants are present in the response

#### Scenario: M2M read participant — cross-tenant blocked

- GIVEN an `ApiClient` for Org A
- WHEN `GET /api/m2m/participants/{id}` where `id` belongs to Org B
- THEN HTTP 404 is returned
- AND no Org B data is disclosed

#### Scenario: M2M client of Org A cannot create a participant in an Org B project

- GIVEN an `ApiClient` for Org A with `participants:create`
- AND `project_id` in the request body belongs to Org B
- WHEN `POST /api/m2m/participants` is called
- THEN HTTP 404 is returned (project not found in Org A's tenant)
- AND no participant is created in Org B's project

---

### Requirement: Public SSO Exchange

`GET /api/sso/exchange?token=...` MUST be publicly accessible (no auth guard).
It MUST declare `->withoutMiddleware(TenantContext::class)` (see tenancy spec).

Exchange MUST execute in this exact order:

1. Parse and verify JWT signature and expiry (tymon) — fail: HTTP 401.
2. Assert `typ === 'sso-link'` — fail: HTTP 401.
3. **CONSUME the jti atomically**: Redis `SET sso_jti:<jti> 1 NX EX <ttl>` where
   `ttl = max(token.exp - now, 60)` seconds (60s floor). If the key already existed
   (NX fails) → HTTP 401 (replay). This is the SOLE Redis write for the jti — the
   mint endpoint does NOT pre-store the jti; the HMAC signature alone proves BEAI
   minted the token. The key prefix `sso_jti:` is DISTINCT from tymon's blacklist key
   namespace (avoids collision with tymon's internal denylist). This step MUST occur
   BEFORE all subsequent checks. **Security tradeoff**: the sso-link is spent even if a
   subsequent gate returns 403. This is intentional — a token leaked in server logs
   cannot be replayed even after a failed exchange. The TTL floor is NOT delegated to
   tymon's blacklist TTL (which shrinks near-expiry).
4. **Validate `display_name` claim**: assert the JWT claims contain a non-empty
   `display_name` string — fail: HTTP 401 (invalid token). This MUST occur AFTER jti
   consume (step 3) and BEFORE Project resolution. Rationale: `display_name` is NOT
   NULL in the `participants` schema; a missing or empty value reaching the INSERT
   would produce a DB constraint violation → 500. Treating a malformed sso-link as an
   invalid token (401) is the correct response. NOTE: this is defense-in-depth against
   a malformed token; the mint endpoint already rejects absent `display_name` with 422.
5. Resolve Project: `Project::withoutGlobalScope('tenant')->findOrFail($projectId)`.
   **MANDATORY** — `Project` extends `TenantModel` (TenantScoped global scope is
   registered as the named scope `'tenant'`). At this public endpoint, `TenantResolver`
   is NOT set (org = null), so a plain `Project::findOrFail($projectId)` becomes
   `WHERE organization_id = null → 0 rows → every exchange returns 401` (100% broken).
   `withoutGlobalScope('tenant')` bypasses ONLY the TenantScoped filter while KEEPING
   the `SoftDeletingScope` active — a soft-deleted project is NOT findable and correctly
   returns 401. **`withoutGlobalScopes()` (plural, no-arg) MUST NOT be used** — it strips
   `SoftDeletes` too, making soft-deleted projects findable at the public exchange.
   The `project_id` claim is HMAC-signed and trusted.
   If project not found → HTTP 401 (treats a non-existent project reference as an invalid
   token; NOT 404, which would leak project existence).
   NOTE: M2M endpoints (`SsoLinkController`, `ParticipantController::store`) do NOT need
   `withoutGlobalScope` — they run under `TenantContextM2m` which sets the resolver, so
   `Project::where('organization_id', $clientOrgId)->findOrFail($projectId)` is correctly
   scoped there.
6. Evaluate entry gates (NULL-safe): `status = 'active' AND (goes_live_at IS NULL OR
   goes_live_at <= now()) AND (deadline_at IS NULL OR deadline_at > now())` — fail:
   HTTP 403, generic body.
7. Validate `role_code` from sso-link claims against project:
   - standard: must match project's current DB `role_code` — mismatch: HTTP 403, generic body.
   - potential: any non-null `role_code` in claims → HTTP 403, generic body.
8. **PRE-FLIGHT READ (PRIMARY blocked-status mechanism)**:
   ```sql
   SELECT status FROM participants WHERE project_id = ? AND candidate_ref = ?
   ```
   If a row exists with `status ≠ 'in_attesa'` (i.e. `in_corso`, `in_valutazione`,
   `completato`, or `errore`) → HTTP 403, generic body. ALL statuses other than
   `in_attesa` block re-exchange with the same generic 403 response.
   This is the PRIMARY detection mechanism. It is race-safe because the jti was already
   consumed at step 3 (no replay possible regardless of the pre-flight outcome).
   If no existing row is found, proceed to the upsert.
9. Execute atomic upsert:
   ```sql
   INSERT INTO participants (organization_id, project_id, candidate_ref, display_name,
                             role_code, language, status, ...)
   VALUES (...)
   ON CONFLICT (project_id, candidate_ref) DO UPDATE
     SET display_name = EXCLUDED.display_name,
         role_code    = EXCLUDED.role_code,
         language     = EXCLUDED.language,
         updated_at   = now()
   WHERE participants.status = 'in_attesa'
   ```
   The SET clause MUST NOT include `organization_id`, `project_id`, or `candidate_ref`
   (no org/identity mutation on re-entry). `organization_id` MUST be set from
   `$project->organization_id` in the INSERT (never from request input or claims).
   The `WHERE status = 'in_attesa'` on the ON CONFLICT clause is a SECONDARY
   belt-and-suspenders safety net for any concurrent status change between the
   pre-flight read (step 8) and the upsert.
   **FORWARD DEPENDENCY (C7)**: if a concurrent status transition driven by C7+ moves a
   participant out of `in_attesa` between step 8 and this upsert, the `WHERE status =
   'in_attesa'` predicate makes the upsert affect 0 rows. C6 does NOT trigger this race
   (only C6 writes `in_attesa`). C7 MUST handle the 0-row upsert case explicitly.
10. Mint a `typ:candidate` JWT via `CandidateTokenFactory`:
    ```php
    JWTAuth::factory()->setTTL(120); // 120 minutes — REQUIRED override
    $token = JWTAuth::fromUser($participant); // + custom claims
    ```
    Custom claims: `typ:candidate`, `candidate_ref`, `project_id`, `organization_id`,
    `role_code`, `lang`, `exp ~2h`.
    **TTL override is REQUIRED**: `config/jwt.php` default TTL = 30 min (`env('JWT_TTL',
    30)`). Without `setTTL(120)`, candidate tokens expire at 30 min — mid-interview.
    The claim name MUST be `role_code` (not `role`) in both the sso-link and candidate JWTs.
    tymon stamps `prv = hash(App\Models\Participant)`.

**All HTTP 403 responses on this public endpoint MUST use a generic "Access denied" body**,
regardless of which gate or block triggered (inactive / before-live / past-deadline /
role_code mismatch / completato / errore). Project operational state MUST NOT be disclosed.

On any step 1–4 failure: HTTP 401 (parse/typ/replay/display_name — invalid token).
On any step 5–9 failure: HTTP 403 (generic — access denied).

#### Scenario: Missing display_name in sso-link claims returns 401

- GIVEN a `typ:sso-link` JWT whose claims contain no `display_name` field (or an empty string)
- AND the jti is valid and not yet consumed
- WHEN `GET /api/sso/exchange?token=<token>` is called
- THEN the jti IS consumed in Redis (step 3 runs before the display_name check)
- AND HTTP 401 is returned (malformed token — invalid token, not an access gate failure)
- AND no participant INSERT is attempted
- NOTE: defense-in-depth; the mint endpoint already rejects absent display_name with 422;
  this belt catches a malformed token that bypassed or predates the mint validation

#### Scenario: Soft-deleted project returns 401 at exchange

- GIVEN a `typ:sso-link` JWT whose `project_id` references a project that has been soft-deleted
- AND `TenantResolver` is NOT set (public endpoint)
- WHEN the exchange calls `Project::withoutGlobalScope('tenant')->findOrFail($projectId)`
- THEN HTTP 401 is returned (SoftDeletingScope is still active — soft-deleted project is not findable)
- NOTE: `withoutGlobalScopes()` (plural, no-arg) MUST NOT be used — it would strip SoftDeletes
  and make soft-deleted projects findable, allowing exchange against a deleted project

#### Scenario: Happy path exchange

- GIVEN a valid `typ:sso-link` JWT, not expired, `jti` not yet consumed
- AND project is active, within deadline, after goes_live_at
- WHEN `GET /api/sso/exchange?token=<token>` is called
- THEN HTTP 200 is returned
- AND the response body contains a `typ:candidate` JWT
- AND the `jti` is now consumed in Redis
- AND a `Participant` record exists with `status = in_attesa`

#### Scenario: jti consumed BEFORE gates are evaluated

- GIVEN a valid `typ:sso-link` JWT whose jti has not been consumed
- AND the project is inactive (gate will fail)
- WHEN the exchange is called
- THEN the jti IS consumed in Redis (SET NX succeeds)
- AND HTTP 403 is returned (gate failure)
- WHEN the same token is presented again
- THEN HTTP 401 is returned (jti already consumed — replay rejected)

#### Scenario: Project not found at exchange returns 401

- GIVEN a valid `typ:sso-link` JWT whose `project_id` claim references a project that
  no longer exists (deleted after mint, cross-environment, or mismatched)
- WHEN `GET /api/sso/exchange?token=<token>` is called
- THEN HTTP 401 is returned (NOT 404 — 404 would leak that a project with that id once existed)
- AND no participant is created or modified

#### Scenario: Expired token returns 401

- GIVEN a `typ:sso-link` JWT whose `exp` is in the past
- WHEN the exchange endpoint is called
- THEN HTTP 401 is returned
- AND no participant is created or modified

#### Scenario: Wrong typ — candidate JWT presented at exchange

- GIVEN a `typ:candidate` JWT (not sso-link)
- WHEN `GET /api/sso/exchange?token=<candidate_token>` is called
- THEN HTTP 401 is returned

#### Scenario: Wrong typ — user JWT presented at exchange

- GIVEN a standard user JWT (`typ:user` or no custom typ)
- WHEN `GET /api/sso/exchange?token=<user_token>` is called
- THEN HTTP 401 is returned

#### Scenario: Wrong typ — M2M API-key presented at exchange

- GIVEN an M2M bearer key
- WHEN it is submitted as the `token` query parameter
- THEN HTTP 401 is returned

#### Scenario: Replayed jti returns 401

- GIVEN a valid `typ:sso-link` JWT exchanged successfully once
- WHEN the same token is submitted again
- THEN HTTP 401 is returned (jti already consumed)
- AND no second participant record is created

#### Scenario: Project not active returns 403 with generic body

- GIVEN the project `status = inactive` (or `draft`)
- WHEN exchange is attempted with a valid sso-link token
- THEN HTTP 403 is returned
- AND the response body does NOT reveal the specific reason (generic "Access denied")

#### Scenario: Before goes_live_at returns 403 with generic body

- GIVEN the project `goes_live_at` is tomorrow
- WHEN exchange is attempted
- THEN HTTP 403 is returned with generic body

#### Scenario: goes_live_at NULL does not block exchange

- GIVEN the project `goes_live_at = NULL`
- WHEN exchange is attempted with a valid token and all other gates pass
- THEN HTTP 200 is returned (NULL = no restriction)

#### Scenario: Past deadline_at returns 403 with generic body

- GIVEN the project `deadline_at` is yesterday
- WHEN exchange is attempted with a valid (not-yet-expired) sso-link token
- THEN HTTP 403 is returned with generic body

#### Scenario: deadline_at NULL does not block exchange

- GIVEN the project `deadline_at = NULL`
- WHEN exchange is attempted with all other gates passing
- THEN HTTP 200 is returned (NULL = no expiry)

#### Scenario: status completato blocks re-entry — 403 generic body

- GIVEN a `Participant` with `status = completato` for `(project_id, candidate_ref)`
- WHEN exchange is attempted with a valid sso-link for the same candidate
- THEN HTTP 403 is returned with generic "Access denied" body
- AND the pre-flight READ detects the blocked status BEFORE the upsert is attempted
- AND the participant record is not modified

#### Scenario: status errore blocks re-entry — 403 generic body

- GIVEN a `Participant` with `status = errore` for `(project_id, candidate_ref)`
- WHEN exchange is attempted
- THEN HTTP 403 is returned with generic body
- AND the pre-flight READ detects the blocked status BEFORE the upsert is attempted

#### Scenario: re-exchange while status = in_corso — 403 generic body

- GIVEN a `Participant` with `status = in_corso` for `(project_id, candidate_ref)`
- WHEN exchange is attempted with a new valid sso-link for the same candidate
- THEN HTTP 403 is returned with generic "Access denied" body
- AND the pre-flight READ (step 8) detects status ≠ 'in_attesa' → 403 (same path as completato/errore)
- AND the participant record is not modified
- NOTE: in_corso is an active interview — re-exchange is blocked, NOT silently re-admitted

#### Scenario: re-exchange while status = in_valutazione — 403 generic body

- GIVEN a `Participant` with `status = in_valutazione` for `(project_id, candidate_ref)`
- WHEN exchange is attempted
- THEN HTTP 403 is returned with generic body (same pre-flight READ path)

#### Scenario: Project resolved via withoutGlobalScope('tenant') at public exchange

- GIVEN a valid `typ:sso-link` JWT whose `project_id` claim references an active project
- AND `TenantResolver` is NOT set (public endpoint, no auth context)
- WHEN the exchange calls `Project::withoutGlobalScope('tenant')->findOrFail($projectId)`
- THEN the project is resolved correctly (TenantScoped named scope 'tenant' is bypassed)
- AND the SoftDeletingScope remains active (soft-deleted projects are NOT findable)
- AND the exchange proceeds normally
- WHEN the exchange instead calls `Project::findOrFail($projectId)` (plain, without withoutGlobalScope)
- THEN 0 rows are returned (WHERE organization_id = null) and every exchange would fail with 401
- WHEN the exchange calls `Project::withoutGlobalScopes()->findOrFail($projectId)` (plural, no-arg)
- THEN SoftDeletes is also stripped — a soft-deleted project becomes findable (WRONG; MUST NOT use this form)
- NOTE: this test MUST validate the withoutGlobalScope('tenant') call is present and that soft-deleted projects return 401 (e.g. assert on query log or override TenantScoped in test; also add a soft-delete scenario)

---

### Requirement: Idempotent Upsert (in_attesa)

Re-exchange for the same `(project_id, candidate_ref)` while the participant is
`in_attesa` MUST update `display_name`, `role_code`, and `language` without
creating a duplicate record. Concurrent exchanges MUST result in exactly one
participant row.

#### Scenario: Idempotent re-exchange while in_attesa

- GIVEN a `Participant` with `status = in_attesa` for `(project_id, "EXT-001")`
- WHEN exchange is called again (new valid sso-link, same candidate_ref)
- THEN HTTP 200 is returned with a new candidate JWT
- AND there is still exactly ONE participant row for `(project_id, "EXT-001")`
- AND `display_name` / `role_code` / `language` are updated to the new values

#### Scenario: Concurrent exchanges produce exactly one participant

- GIVEN two simultaneous valid exchange requests for the same `(project_id, candidate_ref)`
- WHEN both hit the upsert
- THEN exactly one `Participant` row exists after both complete
- AND no duplicate key error is surfaced to either caller

---

### Requirement: role_code Validation

**At mint**: see Requirement M2M SSO-Link Mint (role_code 422 scenarios).

**At exchange** (belt check against project's current DB value):

For `assessment_type = standard` projects, the SSO-supplied `role_code` in the sso-link
claims MUST match `project.role_code` — mismatch → HTTP 403 (generic body).
For `assessment_type = potential` projects, any non-null `role_code` in the sso-link
claims → HTTP 403 (generic body). There is NO silent nulling at any stage.

#### Scenario: Standard project — matching role_code accepted

- GIVEN a standard project with `role_code = "ICO"`
- WHEN exchange is called with `role_code = "ICO"` in the sso-link claims
- THEN the exchange succeeds and `participants.role_code = "ICO"`

#### Scenario: Standard project — mismatched role_code rejected at exchange

- GIVEN a standard project with `role_code = "ICO"`
- WHEN exchange is called with `role_code = "FLL"` in the sso-link claims
- THEN HTTP 403 is returned with generic body
- AND no participant is created or modified

#### Scenario: Potential project — role_code in claims rejected at exchange

- GIVEN a potential project
- WHEN exchange is called with `role_code = "MLL"` in the sso-link claims
  (this token should have been rejected at mint — belt check catches it)
- THEN HTTP 403 is returned with generic body
- AND `participants.role_code` is NOT set to "MLL"

---

### Requirement: language Defaulting

`participants.language` MUST always be a valid supported locale — never null.
The resolution chain at exchange (applied before the upsert INSERT):

1. Use the `lang` claim from the sso-link JWT if present and non-null.
2. Else fall back to `$project->language` (`Project.language` is NOT NULL — C4
   `api/app/Models/Project.php` declares `@property string $language` without nullable).
3. Else fall back to `config('app.fallback_locale')` (default `'en'`) as the final guard.

Step 3 is a belt-and-suspenders safeguard: because `Project.language` is NOT NULL,
step 2 should always succeed in practice. The fallback ensures correctness even if the
schema changes. The `participants.language` column MAY be declared nullable in the DB
schema (to allow future null migrations), but the code MUST NEVER store null in C6.

#### Scenario: language absent defaults to project language

- GIVEN a project with `language = "it"` and an sso-link with no language claim
- WHEN exchange succeeds
- THEN `participants.language = "it"`

#### Scenario: language present overrides project default

- GIVEN a project with `language = "it"` and an sso-link with `language = "en"`
- WHEN exchange succeeds
- THEN `participants.language = "en"`

#### Scenario: language is never null in participants

- GIVEN any valid exchange (with or without lang claim in sso-link)
- WHEN the upsert INSERT is executed
- THEN `participants.language` is a non-null, non-empty supported locale
- AND the stored value is either the sso-link lang claim, project.language, or 'en' (fallback)

---

### Requirement: api-candidate Guard

The `api-candidate` guard MUST be registered via `Auth::viaRequest('api-candidate',
$closure)` and listed in `config/auth.php` as:

```php
'api-candidate' => ['driver' => 'api-candidate'],
```

NO `provider` key — same pattern and same warning as `api-m2m` (adding a provider key
causes `AuthManager` to attempt provider resolution before the custom driver, breaking
the guard).

The viaRequest closure MUST execute in this exact order:

1. Extract Bearer token.
2. Validate sig + exp AND obtain the payload in a **SINGLE decode call**:
   `$payload = JWTAuth::setToken($rawToken)->checkOrFail();`
   `checkOrFail()` returns the validated `Payload` object directly. Any failure →
   return null → 401.
   MUST NOT use `JWTAuth::authenticate()`, which resolves via the User provider and
   enforces `prv` against the User model — wrong for a candidate token.
   MUST NOT call `setToken()->getPayload()` as a second separate call after
   `checkOrFail()` — the `JWTAuth` facade is a singleton; if another guard resolved
   first it may carry stale state. Read `typ` and `sub` from the `$payload` returned
   by `checkOrFail()`.
3. Assert `$payload->get('typ') === 'candidate'` EXPLICITLY — this is the PRIMARY defense;
   tymon does NOT check custom claims. Any other typ (user, m2m, sso-link, absent) →
   return null → 401.
4. Validate `sub` is a positive integer: `(int) $payload->get('sub') > 0` — non-integer
   or ≤ 0 → return null → 401.
5. `Participant::find((int) $payload->get('sub'))` — unscoped (no global scope; TenantResolver
   not stamped yet, same reason as ApiClient in M2M guard). Return Participant|null. Null → 401.

Because `config/jwt.php` has `lock_subject = true`, candidate JWTs minted via
`JWTAuth::fromUser($participant)` carry `prv = hash(App\Models\Participant)`. A
candidate JWT presented to the `api` (User) guard is ALSO rejected by tymon via `prv`
MISMATCH: tymon's `authenticate()` compares the token's `prv` against
`hash(App\Models\User)` — they differ → `TokenInvalidException` → null → 401.
This is the SECONDARY layer that closes the reverse direction (candidate JWT on `api`
guard). NOTE: `prv` is NOT in `required_claims`; tymon does NOT reject via the
required-claims check. The rejection is through subject validation in `authenticate()`.
Both layers apply:

- Layer 1 (primary): typ assertion in the `api-candidate` closure.
- Layer 2 (secondary, prv MISMATCH): model-binding via `fromUser` rejects candidate JWT
  on `api` guard via prv mismatch (User prv ≠ Participant prv).

SSO-link JWTs do NOT carry `prv` (minted RAW, not via fromUser) and are NEVER a guard
credential — they are consumed once only at the exchange endpoint only. On the `api` guard,
sso-link JWTs are rejected via `User::find(sub = candidate_ref) → null` (sub is a
non-numeric string; `prv` is NOT in required_claims — its absence alone does NOT reject).

#### Scenario: Valid candidate JWT resolves participant

- GIVEN a valid `typ:candidate` JWT with `sub = participant_id`
- WHEN a request to `GET /api/candidate/session` is made
- THEN HTTP 200 is returned
- AND `Auth::guard('api-candidate')->user()` returns the correct `Participant`

#### Scenario: User JWT on api-candidate route returns 401

- GIVEN a valid human user JWT (`typ:user` or no typ claim)
- WHEN `GET /api/candidate/session` is called with it
- THEN HTTP 401 is returned (typ check fails)
- AND no participant data is leaked

#### Scenario: M2M bearer key on api-candidate route returns 401

- GIVEN a valid M2M bearer key
- WHEN `GET /api/candidate/session` is called with it as Bearer
- THEN HTTP 401 is returned

#### Scenario: sso-link JWT on api-candidate route returns 401

- GIVEN a valid `typ:sso-link` JWT
- WHEN `GET /api/candidate/session` is called
- THEN HTTP 401 is returned (sso-link is not a session credential; typ ≠ 'candidate')

#### Scenario: Missing Authorization header returns 401

- GIVEN no Authorization header
- WHEN `GET /api/candidate/session` is called
- THEN HTTP 401 is returned

#### Scenario: candidate JWT on api or api-m2m route returns 401

- GIVEN a valid `typ:candidate` JWT
- WHEN `GET /api/some-human-route` is called (api guard): HTTP 401 via prv mismatch
- OR `GET /api/m2m/whoami` is called (api-m2m guard): HTTP 401 (not an opaque key)
- THEN HTTP 401 is returned in both cases (guard mismatch)

#### Scenario: Guard confusion — user sub equals participant id

- GIVEN a user JWT whose `sub` value happens to equal an existing `participant.id`
- WHEN `GET /api/candidate/session` is called with that JWT
- THEN HTTP 401 is returned (typ !== 'candidate')
- AND the participant is NOT returned as authenticated user

#### Scenario: sub is not a positive integer — 401

- GIVEN a `typ:candidate` JWT whose `sub` claim is `0`, negative, or a non-integer string
- WHEN `GET /api/candidate/session` is called
- THEN HTTP 401 is returned
- AND no DB query for participant is attempted

#### Scenario: Candidate JWT prv rejected by api guard

- GIVEN a valid `typ:candidate` JWT minted via `JWTAuth::fromUser($participant)`
  (carries `prv = hash(App\Models\Participant)`)
- WHEN the jwt is presented to a route protected by the `api` (User) guard
- THEN HTTP 401 is returned (tymon prv mismatch — User prv ≠ Participant prv)
- AND the user guard does NOT authenticate the candidate

---

### Requirement: Candidate Session Endpoint

`GET /api/candidate/session` MUST be protected by `auth:api-candidate →
TenantContextCandidate → SubstituteBindings`. It MUST return a JSON payload
containing: participant fields, project config (non-sensitive subset), and
`exit_redirect_url` (from C4 `Project`). The redirect trigger is NOT fired here.

#### Scenario: Session returns participant + project + exit_redirect_url

- GIVEN a valid `typ:candidate` JWT for participant P in project J
- WHEN `GET /api/candidate/session` is called
- THEN HTTP 200 is returned
- AND the body includes participant id, candidate_ref, status, role_code, language
- AND the body includes project id, role_code, language, assessment_type
- AND the body includes `exit_redirect_url` from the project record (may be null)

#### Scenario: Cross-tenant: candidate JWT for org A cannot access org B data

- GIVEN a `typ:candidate` JWT scoped to `organization_id = A`
- WHEN `GET /api/candidate/session` is called
- THEN only participant and project data for org A is returned
- AND no Org B data is accessible or disclosed

---

### Requirement: Four Guards Mutually Non-Interchangeable

The system MUST enforce that credentials issued for one guard type are rejected by
all other guard types. The four guards are: `api` (user JWT), `api-m2m` (M2M
opaque key), `api-candidate` (candidate JWT), and the sso-link exchange endpoint
(consumes `typ:sso-link` once only).

Non-interchangeability is enforced by TWO independent layers:

1. **typ assertion** in each viaRequest closure (primary — explicit custom-claim check).
2. **prv model-binding** via `lock_subject = true` in `config/jwt.php` (secondary —
   tymon rejects a candidate JWT on the `api` User guard via prv hash mismatch).

SSO-link JWTs are minted RAW (NOT via `JWTAuth::fromUser`). They carry NO `prv` claim.
The `api` guard rejects them because `User::find(sub = candidate_ref)` returns null
(`sub` is a non-numeric string like `"EXT-abc-123"`; `User::find` cannot resolve it).
**Correction**: stating "prv absent → lock_subject requires prv → rejected via
required_claims" is WRONG. `prv` is NOT listed in `required_claims` (`[iss, iat, exp,
nbf, sub, jti]`); its absence alone does NOT cause rejection. The actual rejection
mechanism on the `api` guard is sub-resolution failure (`User::find` returns null).
SSO-link JWTs are never a guard credential — they are consumed once only at the
exchange endpoint.

#### Scenario: All four credential types tested against all four guards

- GIVEN tokens of all four types (user, M2M, candidate, sso-link) are available
- WHEN each is presented to a protected route on each guard
- THEN only the matching credential type succeeds (HTTP 2xx)
- AND all mismatches return HTTP 401

---

### Requirement: Cross-Tenant Isolation

A candidate JWT scoped to Org A MUST NOT grant access to resources belonging to
Org B. M2M clients of Org A MUST NOT read participants of Org B.

Cross-tenant isolation for Participants is enforced by EXPLICIT `->where('organization_id', $orgId)`
filtering in M2M controllers (no global TenantScoped scope — Participant is a plain Model).
The explicit filter must be covered by a dedicated cross-tenant test.

#### Scenario: Candidate JWT for org A cannot read org B participant

- GIVEN a `typ:candidate` JWT with `organization_id = A, project_id = pA`
- WHEN a request targets a participant in `project_id = pB` (Org B)
- THEN HTTP 403 or 404 is returned
- AND no Org B data is disclosed

#### Scenario: M2M client of org A cannot read org B participants

- GIVEN an `ApiClient` for Org A with `participants:read`
- WHEN `GET /api/m2m/participants/{id_from_org_B}` is called
- THEN HTTP 404 is returned (explicit where('organization_id', A) filters out Org B)
- AND no Org B data is disclosed

#### Scenario: Explicit org filter test — no global scope

- GIVEN `Participant` has no TenantScoped global scope
- WHEN `Participant::all()` is called without any where clause in a test
- THEN participants from all orgs are returned (confirming there is no hidden scope)
- AND cross-org isolation relies entirely on the explicit ->where() in controllers
