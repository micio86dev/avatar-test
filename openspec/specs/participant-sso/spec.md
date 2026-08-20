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

The transition map additionally permits exactly one further edge: `errore =>
['in_attesa']`. This edge MUST be written ONLY by the dedicated recovery action (see
Requirement: Atomic Participant and Session Recovery from Errore), under its own
authorization, locking, and refusal guards — no other write path may trigger it.
`errore => in_corso` and `errore => in_valutazione` remain illegal.
(Previously: `errore` was terminal with no outbound edge.)

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

#### Scenario: errore recovers to in_attesa only via the recovery action

- GIVEN a `Participant` at `status = errore`
- WHEN the recovery action transitions it to `in_attesa`
- THEN the guard permits the write
- AND no other code path setting `status = in_attesa` on an `errore` participant is
  permitted

#### Scenario: errore still cannot jump directly to in_corso or in_valutazione

- GIVEN a `Participant` at `status = errore`
- WHEN code attempts `status = in_corso` or `status = in_valutazione` directly
- THEN `ParticipantTransitionException` is thrown

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

---

## ADDED Requirements (participant-error-recovery)

### Requirement: Atomic Participant and Session Recovery from Errore

`POST /api/participants/{id}/recover` (`auth:api` + `TenantContext`, its own write
route group) MUST atomically reset a participant at `status = errore` to `in_attesa`
together with every `InterviewSession` of that participant at `status = error`, inside
one `DB::transaction` holding `lockForUpdate` on the participant row; status MUST be
re-read inside the lock before any write.

Each reset session MUST return to `status = pending` with `provider_session_ref`,
`ended_reason`, and `ended_at` cleared, and its `utterances` MUST be deleted. Sessions
at `completed`, `timeout`, or `skipped` MUST NOT be touched — this is what makes the
recovery a resume: `resolveNextCompetency()` continues to skip already-answered
competencies. The response MUST report `competencies_reset` (codes) and
`utterances_discarded` (count).

#### Scenario: Recovery resets the participant and only the errored session

- GIVEN a participant at `errore` with one `error` session for `COL` and two
  `completed` sessions
- WHEN an authorized call recovers the participant
- THEN `participant.status` becomes `in_attesa`
- AND the `COL` session becomes `pending` with refs/reason/ended_at cleared and its
  utterances deleted
- AND the two `completed` sessions are untouched

#### Scenario: Resume, not restart

- GIVEN the recovered participant above re-enters via a freshly minted entry link
- WHEN the interview resumes
- THEN `resolveNextCompetency()` returns the reset `COL` competency
- AND no already-answered competency is re-asked

#### Scenario: A full recovery cycle reaches in_valutazione and dispatches scoring

- GIVEN a participant fails at competency 2 of 3 and is recovered
- WHEN the candidate re-enters and finishes competencies 2 and 3
- THEN the participant reaches `in_valutazione` and `FinalizeInterview` is dispatched

### Requirement: Recovery Refusal Guards

Recovery MUST be refused with HTTP 409, evaluated inside the transaction before any
write, guard 1 first:

1. `evaluation_already_delivered` — a `WebhookDelivery` row exists for the participant
   with `event_type = evaluation`. No scoring-stage failure ever leaves an `error`
   session (scoring runs only once every session is `completed`), so this is the sole
   detection rule needed for scoring-stage refusal.
2. `nothing_to_recover` — no `InterviewSession` of the participant is at `status =
   error`.

After the guards, status is re-read inside the lock:

| In-lock status | Result |
|---|---|
| `errore` | Proceed |
| `in_attesa` | HTTP 200, idempotent no-op |
| any other status | HTTP 409 `not_failed` |

#### Scenario: Evaluation already delivered refuses recovery

- GIVEN a participant with a `WebhookDelivery` row where `event_type = evaluation`
- WHEN recovery is called
- THEN HTTP 409 `reason: "evaluation_already_delivered"` is returned
- AND no field is modified

#### Scenario: No errored session refuses recovery

- GIVEN a participant at `errore` with no `error` session
- WHEN recovery is called
- THEN HTTP 409 `reason: "nothing_to_recover"` is returned

#### Scenario: Concurrent recovery is idempotent

- GIVEN two operators call recover for the same `errore` participant nearly
  simultaneously
- WHEN both are processed
- THEN exactly one performs the reset and returns 200
- AND the second observes `in_attesa` inside its own lock and returns 200 with no
  second utterance deletion

#### Scenario: A live participant cannot be recovered

- GIVEN a participant at `in_corso`, `in_valutazione`, or `completato`
- WHEN recovery is called
- THEN HTTP 409 `reason: "not_failed"` is returned

### Requirement: Recovery Authorization

`ParticipantPolicy` MUST expose a `recover` ability granted to `admin` and `operator`;
`viewer` MUST be denied. Authorization MUST be checked before the participant is
resolved by id; a denied caller MUST NOT learn whether the id exists in another
organization. The participant MUST then be resolved scoped to the caller's
`organization_id`; a participant in another organization MUST return HTTP 404.

#### Scenario: Viewer is denied before the participant is resolved

- GIVEN an authenticated `viewer`
- WHEN recovery is called with an id belonging to another organization
- THEN HTTP 403 is returned, not 404

#### Scenario: Cross-tenant recovery is not found

- GIVEN an authenticated `operator` of Org A
- WHEN recovery is called with an id belonging to Org B
- THEN HTTP 404 is returned

#### Scenario: Admin and operator can both recover

- GIVEN an authenticated `admin` or `operator` of the participant's organization
- WHEN recovery is called for a participant at `errore`
- THEN the recovery proceeds

### Requirement: Interim Recovery Audit Logging

Every recovery that reaches authorization success MUST emit a structured log line —
`participant.recovered` — carrying actor, participant id, organization id, project id,
previous status, new status, operator-supplied reason (nullable, max 500 chars), the
reset competency codes, the discarded utterance count, and an ISO-8601 timestamp. This
log is explicitly INTERIM: it does NOT satisfy CLAUDE.md's admin-audit-log NFR — not
append-only, not tenant-queryable, not retained, not policy-redacted — and MUST be
superseded by the ratified `audit-log` capability when implemented.

#### Scenario: A successful recovery is logged

- GIVEN an authorized recovery that resets the participant
- WHEN the transaction commits
- THEN a `participant.recovered` log line is emitted with actor, participant,
  organization, previous/new status, reset competencies, and utterance count

### Requirement: Mint Refusal Reason Disambiguation

The terminal-status mint refusal already required by "Shared Entry Link Minting
Logic" MUST distinguish `completato` from `errore` with a distinct `reason` and
message, in BOTH `POST /api/entry-links` and `POST /api/m2m/sso-link`. Both cases
remain HTTP 409 — only the body changes. `reason` (`"completed"` | `"failed"`) is
machine-facing and MUST NOT be localized (CLAUDE.md). A crashed candidate (`errore`)
MUST NEVER be reported as having completed the assessment.

#### Scenario: A completed participant is refused with the completed reason

- GIVEN a `Participant` at `completato`
- WHEN either mint endpoint is called
- THEN HTTP 409 `reason: "completed"` is returned with a message stating the
  assessment was already completed

#### Scenario: An errored participant is refused with the failed reason, not completed

- GIVEN a `Participant` at `errore`
- WHEN either mint endpoint is called
- THEN HTTP 409 `reason: "failed"` is returned with a message stating the assessment
  failed and must be re-opened by an operator
- AND the message does NOT state the assessment was completed

### Requirement: Provider Client/Throttle Failures Never Mark the Participant

A provider `ClientError` or `Throttle` classification during interview start MUST
write only the `InterviewSession` status, never `participant.status`, regardless of
`in_attesa` or `in_corso` origin. This already-shipped behavior MUST stay pinned by a
regression test as recovery is introduced, so recovery scope cannot silently expand to
failures that never mark the participant.

#### Scenario: ClientError leaves the participant untouched

- GIVEN a provider call fails and is classified `ClientError`
- WHEN the failure is handled, for either origin status
- THEN `participant.status` is unchanged and only the session reflects the failure

#### Scenario: Throttle leaves the participant untouched

- GIVEN a provider call fails and is classified `Throttle`
- WHEN the failure is handled, for either origin status
- THEN `participant.status` is unchanged

---

## ADDED Requirements (C10)

### Requirement: SSO exchange — participant-created progress event (C10 addendum)

`GET /api/sso/exchange` MUST dispatch a `progress` domain event (webhook trigger) for
participant creation when, at the pre-flight read (step 8 of the existing Public SSO
Exchange requirement — `SsoExchangeController.php:119-121`), `$existingStatus === null`
(no prior `Participant` row for this `(project_id, candidate_ref)`). The event MUST be
dispatched AFTER the reload+null-check confirms the upserted participant
(`SsoExchangeController.php:161-167`), which is already past the durability point: this
file contains NO enclosing `DB::transaction` (verified) — the atomic upsert at
`:137-158` runs in autocommit, so reaching the reload+null-check means the row is
already durable and there is no rollback risk to guard against at this seam.

This is purely additive: it does NOT alter the existing 10-step exchange contract, the
raw `ON CONFLICT ... WHERE status = 'in_attesa'` upsert statement, any HTTP status code,
or any existing scenario in the Public SSO Exchange or Idempotent Upsert requirements.

**Idempotent re-exchange is NOT treated as creation.** If the pre-flight read at step 8
finds an existing row with `status = 'in_attesa'` (idempotent re-exchange — see the
Idempotent Upsert requirement), `$existingStatus !== null` and NO new `progress` event
is dispatched for that request; only the display_name/role_code/language fields are
updated by the existing upsert.

**TOCTOU race is absorbed by dedupe, not by weakening the upsert** (per D4 in the
webhooks-integration spec): if two concurrent exchange requests for the same
`(project_id, candidate_ref)` both observe `$existingStatus === null` at their
respective pre-flight reads, both attempt to record a creation trigger; the unique
`(organization_id, project_id, event_type, dedupe_key)` index on `webhook_deliveries`
collapses this into exactly one delivery row. The exchange endpoint's own atomicity
(the `ON CONFLICT` upsert) is unmodified by this addendum.

#### Scenario: First exchange for a new candidate dispatches a progress event

- GIVEN no `Participant` row exists for `(project_id, "EXT-NEW-001")`
- WHEN `GET /api/sso/exchange?token=<valid-sso-link>` is called
- THEN the exchange succeeds (HTTP 200) exactly as before, AND a `progress` event for participant creation is dispatched after the reload+null-check confirms the new row

#### Scenario: Idempotent re-exchange (status still in_attesa) does not dispatch a new progress event

- GIVEN a `Participant` with `status = in_attesa` already exists for `(project_id, "EXT-001")`
- WHEN exchange is called again for the same candidate (idempotent re-exchange, per the existing Idempotent Upsert requirement)
- THEN the exchange succeeds as before (updated display_name/role_code/language) AND no new participant-creation `progress` event is dispatched for this request

#### Scenario: Concurrent creation race collapses into one progress delivery

- GIVEN two simultaneous valid exchange requests for the same `(project_id, candidate_ref)` both observe `$existingStatus === null` at their pre-flight read
- WHEN both requests complete their upserts and both attempt to dispatch a creation `progress` event
- THEN both requests still succeed HTTP-wise as today (Concurrent exchanges produce exactly one participant), AND exactly ONE `webhook_deliveries` row results for the `progress`/creation dedupe key

#### Scenario: Exchange failure before the reload+null-check dispatches no progress event

- GIVEN an exchange request that fails an earlier gate (e.g. expired token, past-deadline project, blocked participant status) and returns HTTP 401 or 403
- WHEN the exchange handler returns before reaching step 9's reload+null-check
- THEN no `progress` event is dispatched and no `webhook_deliveries` row is created for that request

### Requirement: An omitted role_code is filled from the project at mint

When `POST /api/m2m/sso-link` is called for a **standard** project without
`role_code`, the minted token MUST carry the project's `role_code`.

Until now the mint accepted the omission and the exchange refused the result:
the exchange requires the claim to equal the project's role, and `null` never
does. The API returned 201 with a credential it would later refuse.

That failure is terminal rather than merely confusing. The exchange consumes the
token's `jti` BEFORE evaluating the gates — deliberate replay protection, which
this change does not touch — so a refused link is also a spent one. Retrying the
same URL cannot succeed, and the calling system has already recorded a success.

**A 201 from the mint MUST mean the token in that response is redeemable**, for
every reason the mint is able to check.

The default applies ONLY when the field is absent. A supplied `role_code` is
still validated against the project and still rejected with 422 on mismatch: a
caller who states a role is asserting something, and silently overwriting that
assertion would hide the integration bug the 422 exists to reveal.

Potential projects are unchanged: any supplied `role_code` remains a 422, and it
is never silently nulled.

#### Scenario: Omitted role_code is inherited for a standard project

- GIVEN a standard project with `role_code = "ICO"`
- WHEN `POST /api/m2m/sso-link` is called without `role_code`
- THEN HTTP 201 is returned
- AND the minted token carries `role_code = "ICO"`

#### Scenario: The inherited token is redeemable

- GIVEN a token minted without an explicit `role_code` for a standard project
- WHEN it is presented to `GET /api/sso/exchange`
- THEN the exchange succeeds
- AND does not fail the role_code belt check

#### Scenario: A supplied role_code is still asserted, not replaced

- GIVEN a standard project with `role_code = "ICO"`
- WHEN the mint request supplies `role_code = "BUL"`
- THEN HTTP 422 is returned
- AND no token is minted

#### Scenario: Potential projects are untouched

- GIVEN a potential project
- WHEN the mint request omits `role_code`
- THEN HTTP 201 is returned
- AND the minted token carries a null `role_code`

#### Scenario: The exchange keeps its exact check

- GIVEN a token whose `role_code` claim no longer matches the project's
- WHEN it is presented to the exchange
- THEN HTTP 403 with a generic body is returned

The exchange is NOT relaxed to accept a null claim. It still catches a token
minted before a project's role changed, which remains possible while the project
is draft.

### Requirement: Shared Entry Link Minting Logic

The entry-gate evaluation, `role_code` inheritance/validation, and terminal-status
(`completato`/`errore`) mint refusal MUST be implemented in exactly one place,
consumed by both the M2M mint (`POST /api/m2m/sso-link`) and the operator mint
(below). Two independent implementations of the mint decision are a defect class,
not a stylistic preference: one of them decides whether a candidate can start.

The M2M endpoint's request contract, response contract, and observable behavior
MUST remain byte-identical after this extraction.

#### Scenario: M2M mint response is unchanged after the extraction

- GIVEN a valid M2M mint request that succeeded before this change
- WHEN `POST /api/m2m/sso-link` is called with the same input after the extraction
- THEN the response body, status code, and headers are byte-identical to before

#### Scenario: A gate refusal reason is consistent across both mints

- GIVEN a project that fails the same entry gate (inactive, before goes_live_at,
  past deadline_at, terminal participant status, or role_code mismatch)
- WHEN either the M2M mint or the operator mint is called for that project
- THEN both refuse minting for the same underlying reason

### Requirement: Operator-Facing Entry Link Mint Endpoint

`POST /api/entry-links` MUST mint a candidate entry token for an authenticated
backoffice operator, on the `auth:api` guard plus `TenantContext`. It MUST accept
`project_id`, `candidate_ref`, `display_name`, and optional `role_code` and `lang`,
mirroring the M2M mint's body.

Minting an entry link starts an assessment for a candidate; it is not a read
operation. Authorization MUST be `ParticipantPolicy::create`: `admin` and
`operator` MAY mint; `viewer` MUST be denied.

`project_id` MUST be resolved scoped to the caller's tenant (via `TenantContext`),
consistent with the M2M mint's own-organization scoping.

#### Scenario: Admin mints an entry link

- GIVEN an authenticated user with the `admin` role
- WHEN `POST /api/entry-links` is called with a valid project and candidate
- THEN HTTP 201 is returned with a redeemable entry link

#### Scenario: Operator mints an entry link

- GIVEN an authenticated user with the `operator` role
- WHEN `POST /api/entry-links` is called with a valid project and candidate
- THEN HTTP 201 is returned with a redeemable entry link

#### Scenario: Viewer is denied — minting is not a read

- GIVEN an authenticated user with the `viewer` role
- WHEN `POST /api/entry-links` is called
- THEN HTTP 403 is returned
- AND no token is minted

#### Scenario: Cross-tenant project is not found

- GIVEN an authenticated operator whose tenant does not own `project_id`
- WHEN `POST /api/entry-links` is called with that `project_id`
- THEN HTTP 404 is returned, matching the M2M mint's cross-org behavior
- AND no token is minted

#### Scenario: A project that cannot accept a candidate refuses the mint

- GIVEN a project that is not `active`, or is before `goes_live_at`, or past
  `deadline_at`
- WHEN `POST /api/entry-links` is called for that project
- THEN HTTP 403 is returned
- AND no token is minted

### Requirement: Entry Link Response Composes the Absolute URL

The response to a successful operator mint MUST contain `entry_url` (an absolute
URL) and `expires_at`. It MUST NOT contain the bare token as a separate field: a
raw token in an operator-facing payload is a second copyable artifact that can
land in the wrong place.

#### Scenario: Response carries a composed URL, not a bare token

- GIVEN a successful `POST /api/entry-links` call
- WHEN the response body is inspected
- THEN it contains `entry_url` and `expires_at`
- AND it contains no separate bare-token field

### Requirement: Entry URL Locale Prefixing Is Owned by the Minter

The entry URL's locale prefix MUST be derived from the same `lang` resolution
chain the mint already uses to stamp the token (`$validated['lang'] ??
$project->language ?? fallback`), computed once, inside the minter. A caller of
`POST /api/entry-links` MUST NOT be required to re-derive this chain to know
which URL shape is correct.

For the resolved language `it` (the frontend's default locale, `strategy:
prefix_except_default`), the path MUST be `/interview/{token}`. For any other
resolved language (e.g. `en`), the path MUST be `/{lang}/interview/{token}`.

#### Scenario: Resolved language it omits the locale prefix

- GIVEN a mint request whose resolved language is `it`
- WHEN the entry link is composed
- THEN `entry_url` ends in `/interview/{token}` with no locale segment

#### Scenario: Resolved language en carries the locale prefix

- GIVEN a mint request whose resolved language is `en`
- WHEN the entry link is composed
- THEN `entry_url` ends in `/en/interview/{token}`

#### Scenario: lang omitted falls back to the project's language

- GIVEN a mint request with no `lang` field, for a project with `language = "en"`
- WHEN the entry link is composed
- THEN the resolved language is `en` and the URL is prefixed accordingly

### Requirement: CANDIDATE_APP_URL Fails Loud When Unset

The entry link's origin MUST come from a dedicated configuration value
(`config('interview.candidate_app_url')`, sourced from `CANDIDATE_APP_URL`). When this
value is unset or empty, minting an operator entry link MUST fail loudly (an
error, never a 201 with a malformed link). The origin MUST NOT fall back to
`config('app.url')` under any circumstance — that value is the API's own origin,
and a link composed from it resolves against the wrong application.

#### Scenario: Unset CANDIDATE_APP_URL fails the mint, not silently

- GIVEN `CANDIDATE_APP_URL` is unset
- WHEN `POST /api/entry-links` is called with an otherwise valid request
- THEN the request fails with an explicit configuration error
- AND no `entry_url` is composed from `config('app.url')`

#### Scenario: A configured CANDIDATE_APP_URL is used verbatim as the origin

- GIVEN `CANDIDATE_APP_URL` is set to `https://interview.example.com`
- WHEN `POST /api/entry-links` succeeds
- THEN `entry_url` begins with `https://interview.example.com`

### Requirement: No Revocation Semantics

Minting a new entry link for a participant MUST NOT invalidate any previously
minted, unexpired entry link for that same participant. There is no mechanism
that consumes a jti before its own exchange or expiry; each minted link remains
independently valid until it is either exchanged once or its 30-minute TTL
elapses.

#### Scenario: A superseded link remains valid until its own expiry

- GIVEN an entry link minted for a participant, not yet exchanged or expired
- WHEN a new entry link is minted for the same participant
- THEN the previous link's token can still be exchanged successfully until its
  own `expires_at`, unless it is exchanged first
