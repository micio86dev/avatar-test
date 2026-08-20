# Design: Backoffice Session — httpOnly Refresh Cookie, Rotation, Reuse Detection

## Technical Approach

Split the single credential in two. The **access token** stays a `tymon/jwt-auth` JWT
returned in the JSON body and held in a module-scoped `ref` — memory only, never in
`sessionStorage` or `localStorage`. The **refresh credential** becomes a new, opaque,
high-entropy secret delivered only as an `HttpOnly` cookie scoped to
`Path=/api/auth/refresh`, hashed at rest in **PostgreSQL**, rotated on every use, and
organised into a *family* so that a detected replay revokes every descendant at once.

> **Storage corrected 2026-08-20 — Redis rejected, PostgreSQL adopted.** The original
> version of this section stored refresh-token families in Redis (`Cache::` keys with
> self-expiring TTLs) and required `maxmemory-policy = noeviction` on the instance backing
> `CACHE_STORE` (see the former D3, superseded below). That is an architectural error: per
> `api/.env.example`, `CACHE_STORE`, `QUEUE_CONNECTION`, and `SESSION_DRIVER` all point at
> the SAME Redis instance. Forcing `noeviction` on it means that once memory fills, cache
> writes and queue pushes **fail outright** and the application breaks — a cache must stay
> evictable. Refresh tokens are durable authentication state, not cache, and now live in a
> `refresh_tokens` PostgreSQL table (one row per generation), following the same shape
> Laravel already uses for `password_reset_tokens` and Sanctum's `personal_access_tokens`.
> This is the change's first migration; a scheduled `model:prune` (`bootstrap/app.php`'s
> `withSchedule()`, `onOneServer()`) deletes expired/revoked rows. Every behavioural
> guarantee below (rotation on every use, family-wide revoke on reuse, absolute expiry
> computed as `absolute_expires_at - now`, the two-tab concurrency grace, hashed-at-rest)
> is unchanged — only the storage engine moved.

Two findings that predate this change and are closed here as a side effect:

1. **CORS is wide open.** `api/config/cors.php` does not exist, so Laravel merges the
   vendor default (`allowed_origins: ['*']`, `supports_credentials: false`). The
   production multi-tenant API accepts cross-origin requests from **any** origin today.
   D1 closes this and is independently mergeable.
2. **`/api/auth/refresh` cannot refresh an expired token.** The route sits behind
   `auth:api` (`api/routes/api.php:61-62`). Tymon's guard rejects an expired JWT with a
   `TokenExpiredException` *before* the controller runs, so a 31-minute idle period is
   already an unrecoverable logout regardless of where the token is stored. This is a
   **second, independent cause** of the operator's complaint that the exploration did not
   surface. D8 removes `auth:api` from the route, which structurally fixes it.

---

## D1 — `api/config/cors.php`: explicit allowlist, credentials on, no wildcard anywhere

**Choice.** Create a project-owned `config/cors.php`:

| Key | Value | Why this exact value |
|---|---|---|
| `paths` | `['api/*']` | Matches the vendor default's intent; `sanctum/csrf-cookie` dropped — Sanctum is not installed |
| `allowed_methods` | `['GET','POST','PUT','PATCH','DELETE','OPTIONS']` | Enumerated, not `['*']` |
| `allowed_origins` | `explode(',', env('CORS_ALLOWED_ORIGINS', ''))`, filtered non-empty | Env-driven, per environment |
| `allowed_origins_patterns` | `[]` | Deliberately empty and **tested** — a regex is how a wildcard sneaks back in |
| `allowed_headers` | `['Accept','Accept-Language','Authorization','Content-Type','X-Requested-With','X-BEAI-Refresh']` | **Functional, not cosmetic**: per the Fetch spec, `*` in `Access-Control-Allow-Headers` is treated *literally* on a credentialed request. Laravel's default `['*']` would break every preflight the moment `supports_credentials` is true |
| `exposed_headers` | `[]` | Nothing needs reading cross-origin |
| `max_age` | `3600` | Caches the preflight the custom CSRF header forces on every refresh |
| `supports_credentials` | `true` | Required for the cookie; incompatible with `*` origins per Fetch spec |

**The allowlist must contain BOTH Nuxt origins.** The candidate `frontend` also calls
`api/*` (SSO exchange, interview). An allowlist containing only the backoffice origin
would take the candidate app down. This is the primary blast radius of slice 1.

**Alternatives rejected.** Leaving the vendor default (hard functional blocker — `*` +
credentials is refused by every browser, and it is the open-origin hole itself);
reflecting the `Origin` header (a wildcard wearing a costume); `allowed_origins_patterns`
with a `*.up.railway.app` regex (would trust every tenant of Railway's shared domain).

**Enforcement.** `tests/Arch/Config/CorsConfigTest.php` asserts, as a config invariant:
allowlist non-empty, contains no `*`, patterns empty, `supports_credentials === true`,
`allowed_headers` does not contain `*` and does contain `X-BEAI-Refresh`. Same
config-invariant pattern as `config/webhooks.php` (C10 D3).

---

## D2 — PostgreSQL data model for the refresh-token family (storage corrected from Redis)

**Wire format.** `{family_id}.{secret}` — `family_id` = UUIDv4, `secret` = 32 CSPRNG
bytes, base64url. The family id travels in the token so lookup is O(1) with no scan; it
is attacker-controlled and is therefore **cross-checked against the stored row, never
trusted**.

**Hashing.** `hash('sha256', $secret)`. Not bcrypt/argon: those exist to slow brute force
on *low-entropy* secrets. A 256-bit CSPRNG value is not brute-forceable, and bcrypt would
add ~100 ms to every refresh for nothing.

**One table, one row per generation** (`refresh_tokens`, migration
`2026_08_20_000001_create_refresh_tokens_table.php`, model `App\Models\RefreshToken`). A
rotation **inserts** a new row; it never mutates an old generation into a different one —
that is what lets two independent, deliberately distinct nullable timestamps encode the
whole state machine:

| Column | Role |
|---|---|
| `user_id` | FK to `users`, cascade on delete |
| `family_id` | Shared by every generation of the same rotation chain |
| `token_hash` | `sha256(secret)`, unique + indexed — the sole lookup key. The raw secret is **never** persisted |
| `generation` | Monotonically increasing per family |
| `absolute_expires_at` | Copied **unchanged** from generation 0 through every rotation |
| `consumed_at` | Stamped when THIS generation's secret was legitimately rotated away — the tombstone the two-tab concurrency-grace check (D6) reads |
| `revoked_at` | Stamped when the WHOLE family is killed (reuse, logout, or ceiling expiry) — permanent, independent of `consumed_at` |

**Refresh algorithm** (`RefreshTokenStore::rotate()`, inside `DB::transaction()` with
`lockForUpdate()` on the presented row — the same atomicity convention already used
throughout `App\Http\Controllers\Candidate\InterviewController`, replacing the prior
`Cache::add()` SET-NX-EX atomicity):

```
1. parse fid, secret from cookie; h = sha256(secret)
2. presented = RefreshToken::where('token_hash', h)->lockForUpdate()->first()
3. presented === null                        -> 401 invalid. REVOKE NOTHING.
4. presented.family_id !== fid               -> 401 invalid   (tampered; hash is the authority)
5. presented.revoked_at !== null             -> 401 revoked   (logout, or a prior reuse/ceiling kill)
6. presented.consumed_at !== null            -> resolve concurrent-duplicate vs reuse (D6) against
                                                 the family's current live row (unconsumed, unrevoked)
7. now >= presented.absolute_expires_at      -> stamp presented.revoked_at; 401 expired
8. otherwise: stamp presented.consumed_at; INSERT generation+1 row; 200 rotated
```

Step 3 is load-bearing: an unattributable hash must never kill a family, or anyone able
to POST garbage to `/api/auth/refresh` can log families out at will.

**Absolute expiry (A4), mechanically.** Every row's `absolute_expires_at` is stamped once
at login (`issue()`) and copied unchanged through every rotation. Every TTL a caller
derives from it — including cookie `Max-Age` — is `absolute_expires_at - now`, **never** a
re-assertion of the 14-day constant. One rule, one column, one dedicated test — this
single subtraction is the entire difference between absolute and sliding.

**Prune, not TTL expiry.** Unlike the rejected Redis design, rows do not self-expire —
`App\Models\RefreshToken` uses Laravel's `Prunable` trait (`prunable()`: past
`absolute_expires_at`, or `revoked_at` already set) and a scheduled `model:prune`
(`bootstrap/app.php`, daily, `onOneServer()`) deletes dead rows. Steady-state cost is the
same order of magnitude as the rejected design (~672 rotations over 14 days per operator
session ⇒ ~672 rows until the next prune run) but now durable, auditable, and immune to a
misconfigured eviction policy.

**Alternative rejected.** A second `typ: operator-refresh` JWT reusing tymon's blacklist:
the blacklist is per-`jti` with no family concept, so a detected replay cannot
cascade-revoke. That is precisely the requirement.

---

## D3 — SUPERSEDED: storage is PostgreSQL, not Redis with `noeviction` (was: "Redis eviction policy")

**This section originally required `maxmemory-policy = noeviction`** on the Redis instance
backing `CACHE_STORE`, with a `php artisan beai:check-redis-eviction` deploy/CI gate. That
requirement is **rejected and removed**, not merely relaxed.

**Why it was wrong.** Per `api/.env.example`, `CACHE_STORE=redis`, `QUEUE_CONNECTION=redis`
and `SESSION_DRIVER=redis` all point at the SAME Redis instance. `noeviction` is a
promise about the *whole instance*, not one keyspace: once memory fills, `noeviction`
makes **every** write fail loudly, including unrelated cache writes and queue pushes that
have nothing to do with refresh tokens — the application breaks, not degrades. A cache
must remain evictable. The original design's own steady-state estimate (~80 KB/session)
undersold this: it is not the size that is the problem, it is the *policy* asked of a
resource shared with everything else.

**Correction (D2, updated above).** Refresh tokens moved to a `refresh_tokens` PostgreSQL
table — durable authentication state belongs in the database, not cache, following the
Laravel-standard shape already used for `password_reset_tokens` and Sanctum's
`personal_access_tokens`. `beai:check-redis-eviction` and its test are **deleted**
entirely; there is no eviction-policy deploy gate for refresh tokens anymore.
`GET /api/health/queue`'s `redis_eviction_policy` field is **kept** as general
observability of the shared cache Redis's actual policy (which should now normally run an
eviction policy, not `noeviction`), but nothing requires a specific value.

*Alternative considered and rejected (same reasoning as before, now moot):* a boot-time
assertion in a service provider — a misconfigured Redis would take the whole API down
instead of degrading one capability. No longer applicable since refresh-token storage no
longer depends on Redis's eviction policy at all.

---

## D4 — Cookie contract

```
Set-Cookie: beai_refresh={family_id}.{secret};
            HttpOnly; Secure; SameSite=None;
            Path=/api/auth/refresh;
            Max-Age={absolute_expires_at - now}
```

- **No `Domain`** — host-only. Under A1 (separate Railway subdomains) a `Domain` attribute
  would only widen exposure.
- **`SameSite=None; Secure` unconditionally, in every environment including local dev.**
  There is deliberately **no `cookie_secure` config knob**, because a knob is the thing
  someone flips in production. `SameSite=Lax` is not a local fallback either: api (`:8000`)
  and backoffice (`:3001`) are different origins even on localhost, so `Lax` would simply
  never send the cookie. If the localhost secure-context exemption fails (D11), the answer
  is local HTTPS, not a weaker cookie.
- **Name `beai_refresh`, no prefix.** `__Host-` is impossible — it mandates `Path=/`, which
  is the opposite of the narrow scoping that makes this design safe. `__Secure-` was
  considered and rejected: it stacks a *second* secure-origin dependency onto the already
  fragile A2/A3 localhost story, for no gain over `Secure` itself.
- **Logout without widening the Path.** `/api/auth/logout` needs to know which family to
  kill, but the cookie is not sent there. Solved by stamping a `fam` custom claim on the
  operator access token at mint time: logout resolves the family from the Bearer token
  alone. It still *clears* the cookie, because `Set-Cookie` carries its own `Path`
  attribute — `beai_refresh=; Path=/api/auth/refresh; Max-Age=0` in the logout response
  deletes it correctly. (`fam` is inert for the `api-candidate` guard, which keys on
  `typ === 'candidate'` — see D10.)
- Set on: `login` (new family), `refresh` (rotation). Cleared on: `logout`, and on every
  401 from `/refresh`.

---

## D5 — CSRF on `/api/auth/refresh`: required custom header + strict allowlist + server-side Origin check

**Choice.** `RequireRefreshCsrfHeader` middleware on `/api/auth/refresh`, requiring
`X-BEAI-Refresh: 1`, plus a server-side check that any present `Origin` header is in the
CORS allowlist.

**Why the header is sufficient under `SameSite=None`.** A custom request header makes the
request non-simple, so the browser must send a CORS preflight first. Our preflight answers
only allowlisted origins, so an attacker's origin never receives permission and the
browser **never sends the real request**. A `<form>` POST or a simple `fetch` cannot set
the header at all.

**Why the Origin check is not redundant.** Laravel's `HandleCors` does not *block* a
non-preflight cross-origin request from a disallowed origin — it merely omits the
`Access-Control-Allow-Origin` header, so the browser hides the *response* while the
server has already executed the state change. For a rotating, family-revoking endpoint
that is not acceptable. The explicit server-side check makes the defense independent of
browser cooperation.

**Alternative rejected — double-submit cookie.** Requires a second, JS-readable cookie
and a client read path. Unsigned double-submit is forgeable by anyone who can set a
cookie on a sibling subdomain; the signed variant needs a sign/verify path built and
tested. Both buy nothing over header + allowlist + Origin check, for more surface.

Note: `Path=/api/auth/refresh` resolves to a POST-only route, so `SameSite=None` never
exposes the cookie on a top-level cross-site GET.

---

## D6 — Rotation, reuse, and the two-tab race

The client's module-scoped single-flight (`useAuth.ts:79`) is **per JavaScript context =
per tab**. It survives this change unchanged, and it does *not* help across tabs. Two tabs
reloading together will present the same cookie simultaneously. Under a naive model the
loser of the `Cache::add` looks exactly like a replay attacker, and every operator with
two tabs open gets logged out — reproducing the original complaint with a security
citation attached. Unacceptable.

**Choice — bounded concurrency grace, default 10 s (`REFRESH_CONCURRENCY_GRACE_SECONDS`).**
When `Cache::add` returns false (step 3d) or the tombstone is found (step 4a), and *all*
of: the tombstone is younger than the grace window, its `generation` equals the presented
generation, and the family is still alive — then this is a concurrent duplicate, not a
replay. The response mints a fresh access token for `family.user_id`, performs **no
rotation and emits no `Set-Cookie`** (so it cannot clobber the winner's cookie), and logs
`refresh.concurrent_duplicate` at warning level so the rate is observable.

Outside the grace window, or on a generation mismatch, it is reuse: the family dies.

| Situation | Outcome |
|---|---|
| Two tabs, same cookie, <10 s apart | Both get an access token; one rotation; no logout |
| Old token replayed >10 s later | Family revoked; 401 `refresh_token_reused`; cookie cleared |
| Token from an already-revoked family | 401 `refresh_token_revoked`; nothing further revoked |
| Unknown / garbage token | 401 `refresh_token_invalid`; **nothing revoked** |
| Past the 14-day ceiling | Family forgotten; 401 `refresh_token_expired` |

**Tradeoff, stated plainly.** A thief replaying a stolen cookie *within* 10 seconds of a
legitimate use gets one access token and trips no alarm. They would have won that race
under any design. After 10 seconds the alarm fires, and the legitimate client already
holds the rotated cookie so the stolen copy is dead. Ten seconds of exposure is the price
of not logging real operators out several times a day.

---

## D7 — `jwt.ttl` stays at 30 minutes; `jwt.refresh_ttl` stays at 20160 and must not be "cleaned up"

`ttl = 30` is kept. The access token is now memory-only and never persisted, so its
exposure window is a tab's lifetime; shortening it would multiply refresh traffic and the
D6 race probability for negligible gain.

`refresh_ttl = 20160` becomes **dead for the operator refresh flow** (we stop calling
`$guard->refresh()`), and it will look like removable config to the next reader. It is
not. Verified in `vendor/tymon/jwt-auth/src/Blacklist.php:100`, the denylist retention is
`max(exp, iat + refreshTTL) + 1 minute` — so `refresh_ttl` is what keeps a logged-out
`jti` denylisted for 14 days. Lowering it silently shortens revocation retention. A
comment saying exactly this goes in `config/jwt.php`.

---

## D8 — Remove `refresh_token` from the login response; make `/refresh` public

**Confirmed, not overruled.** `AuthController.php:79` (`$refreshToken = $accessToken;`)
advertises a property the API does not have. After this change the real refresh credential
is a cookie the client must *never* read, so a `refresh_token` JSON field would be either
a lie or a vulnerability. It is removed. Greenfield, no back-compat (CLAUDE.md).

Consequences that must land in the *same* commit: the Scramble-generated `openapi.json`
changes shape, and both Nuxt apps run `bun run codegen:check` in CI — the regenerated TS
client must ship with it or CI goes red on drift.

**`/api/auth/refresh` loses `auth:api`.** It is authenticated solely by the refresh cookie
plus the CSRF header. This is required (an expired access token is exactly when you need to
refresh) and it fixes the latent idle-timeout bug named in the Technical Approach.
`/logout` and `/me` keep `auth:api`.

---

## D9 — Nuxt SPA boot: an awaited async plugin, `00.auth-bootstrap.client.ts`

**Choice.** A new `backoffice/app/plugins/00.auth-bootstrap.client.ts` with an `async
setup()`. Nuxt awaits non-`parallel` async plugins before the initial route resolves, so
`02.auth.global.ts` reads `isAuthenticated` only after the silent refresh has settled.
The guarantee comes from that await, **not** from the `00.` prefix — the prefix is there
so the ordering intent is readable next to the existing `i18n-base-url.client.ts`
(`enforce: 'pre'`).

The plugin performs exactly one `POST /api/auth/refresh` with `credentials: 'include'` and
the `X-BEAI-Refresh` header. It cannot know whether a cookie exists (that is the point of
`HttpOnly`), so it always attempts — one extra request per cold load, which is the whole
cost of the design.

**Failure path.** It calls `useAuth().refresh()` **directly**, never through `useApi()`:
`useApi` redirects to `/login` on failure, and a redirect issued during boot risks a loop.
Any rejection is swallowed, the session is left empty, and the plugin resolves normally.
A plugin that throws prevents the app from booting into `/login` at all.

`02.auth.global.ts` itself stays synchronous and nearly unchanged — its public-path
early-return still guards `/login`, `/unsupported`, `/health`. Only its *precondition*
changes, and that is documented in its header comment.

**Alternative rejected.** Making the middleware `async` and awaiting the refresh there: it
would run on every navigation, needs its own de-duplication, and leaves `/login` racing
the guard.

---

## D10 — Candidate flow: asserted with a regression test, not just with prose

Structurally unaffected, on three independent grounds:

1. `api/app/Providers/AppServiceProvider.php:213-243` — the `api-candidate` guard asserts
   `$payload->get('typ') === 'candidate'` as its **primary** defense (line 232), with a
   comment noting tymon does not validate custom claims. Operator tokens carry no such
   claim; the new `fam` claim does not create one.
2. `CandidateTokenFactory::mintCandidateToken()` calls `setTTL(120)` before `fromUser()`,
   and `mintSsoLink()` calls `setTTL(SSO_LINK_TTL_MINUTES)`. Both override the global
   `config/jwt.php` TTLs explicitly, so D7 cannot reach them.
3. The refresh cookie is `Path=/api/auth/refresh`. No candidate or SSO route lives under
   that path, so the browser never sends it there.

"Structurally impossible" claims rot. This one gets a test:
`tests/Feature/Auth/CandidateGuardIsolationTest.php` asserts (a) a candidate JWT posted to
`/api/auth/refresh` is rejected, (b) an operator access token is rejected by the
`api-candidate` guard, (c) the candidate token TTL is unchanged by the operator config.

The one genuine candidate-flow risk is **D1**, not the token model: the CORS allowlist
must include the `frontend` origin.

---

## D11 — Local dev and the WebKit gate (A2/A3), with a pre-decided fallback

**The gate.** `backoffice/tests/e2e/session-cookie.spec.ts`, running in **both** the
`chromium` and `webkit` projects. It does not need the app: it navigates to
`http://127.0.0.1:4173/health`, intercepts `http://localhost:4173/**` with `page.route()`
(a different origin from `127.0.0.1` — same server, genuinely cross-site), fulfils it with
the exact production `Set-Cookie` string, then asserts via `context.cookies()` that the
cookie was **stored** and via a second intercepted request that it was **sent**. This is a
browser-behaviour probe, so it neither depends on nor perturbs the existing suite —
which is important, because `playwright.config.ts` sets no `NUXT_PUBLIC_API_BASE`, so
every other spec is same-origin today.

Acceptance criterion: it fails CI, not Safari, in production.

**Pre-decided fallback if WebKit rejects `Secure` over `http://localhost`** (the most
likely failure in this whole change): serve the Playwright `webServer` and the
docker-compose stack over HTTPS with a locally trusted certificate (mkcert), documented in
`docs/dev-setup.md`. **Do not weaken the cookie.** A3 is therefore a branch with a decided
outcome, not a blocker.

---

## D12 — Slice boundaries

| # | Slice | ~Lines | Notes |
|---|---|---|---|
| 1 | `config/cors.php` + env + preflight Pest + config-invariant arch test + `docs/deploy.md` origins | 155 | **Independently mergeable to `develop`.** Closes the open-origin finding on its own. Must allowlist BOTH Nuxt origins |
| 2 | `RefreshTokenStore`, `RefreshTokenCookie`, `config/refresh_tokens.php`, `beai:check-redis-eviction`, unit tests | 420 | No HTTP surface change; unreferenced but fully tested at merge |
| 3 | `AuthController` login/refresh/logout, `RequireRefreshCsrfHeader`, `fam` claim, route change, **remove `refresh_token`**, regenerate `openapi.json`, feature tests | 400 | **Breaking.** The backoffice is broken from here until slice 5 |
| 4 | `useAuth.ts` rewrite + `00.auth-bootstrap.client.ts` + `useAuth.spec.ts` + `middleware/auth.spec.ts` | 370 | |
| 5 | `useApi.ts` + `login.vue` + their two specs + regenerated TS client | 330 | |
| 6 | `session-cookie.spec.ts` (D11) + no-flash-on-reload E2E + `docs/dev-setup.md` | 180 | |

**Total ≈ 1855 changed lines.**

```
Decision needed before apply: Yes
Chained PRs recommended: Yes
400-line budget risk: High
```

Feature Branch Chain. **Slice 1 merges to `develop` alone.** Slices 2→6 form one chain
(PR #2 targets the feature branch, #3 targets #2, …) and merge to `develop` only as a
whole, because slice 3 leaves the backoffice non-functional until slice 5 — that
brokenness must never exist on `develop`.

**Strict TDD, RED-first, contained per slice.** The four backoffice suites — `useAuth.spec.ts`
(163), `useApi.spec.ts` (183), `middleware/auth.spec.ts` (71), `login.spec.ts` (194) = 611
lines — are RED from day one. They are rewritten inside the slice that owns their subject
(4: useAuth + middleware; 5: useApi + login) and must never be left red across a slice
boundary.

---

## Data Flow

```
LOGIN                                    BOOT (cold reload)
  POST /api/auth/login                     00.auth-bootstrap.client.ts (awaited)
    verify credentials                       POST /api/auth/refresh
    family_id = uuid4()                        credentials:'include' + X-BEAI-Refresh
    secret    = 32B CSPRNG                       |
    RefreshToken::create (gen 0)                 v
    access JWT (+ fam claim)                 [ D2 rotate algorithm, DB::transaction +
      |                                          lockForUpdate ]
      +-- body:  { access_token }                |
      +-- Set-Cookie: beai_refresh          200 -> access token in memory
                                            401 -> empty session, no throw
                                                |
                                                v
                                          02.auth.global.ts reads isAuthenticated
                                          (never sees a false first tick)

REUSE                                     LOGOUT
  token_hash miss on live row,              resolve family from `fam` claim
  hit on an already-consumed row,           -> revoke every unrevoked row in family
  outside grace or generation gap > 1       -> denylist access jti (tymon)
    -> revoke every unrevoked row              -> Set-Cookie ...; Max-Age=0
       in the family, 401
```

---

## File Changes

| File | Action | Description |
|---|---|---|
| `api/config/cors.php` | Create | D1 |
| `api/config/refresh_tokens.php` | Create | Absolute TTL, grace seconds, cookie name/path |
| `api/database/migrations/2026_08_20_000001_create_refresh_tokens_table.php` | Create | D2 — durable storage, storage corrected from Redis |
| `api/app/Models/RefreshToken.php` | Create | D2 — one row per generation, `Prunable` |
| `api/app/Support/Auth/RefreshTokenStore.php` | Create | D2 issue / rotate / revokeFamily against the DB |
| `api/app/Support/Auth/RefreshTokenCookie.php` | Create | D4 build + clear |
| `api/app/Http/Middleware/RequireRefreshCsrfHeader.php` | Create | D5 |
| `api/app/Http/Controllers/Auth/AuthController.php` | Modify | D4/D6/D8; drop `$refreshToken = $accessToken` |
| `api/routes/api.php` | Modify | `/refresh` public + CSRF middleware |
| `api/bootstrap/app.php` | Modify | Middleware alias; `model:prune` scheduled entry (`onOneServer()`) |
| `api/config/jwt.php` | Modify | Comment only — D7 |
| `api/app/Http/Controllers/QueueHealthController.php` | Unchanged | `redis_eviction_policy` field stays as general cache-Redis observability, no longer a refresh-token requirement |
| `api/.env.example`, `docs/deploy.md`, `docs/dev-setup.md` | Modify | Origins, dev cookie story; deploy.md's ops gate replaced with a migration deploy-risk note |
| `api/tests/Unit/Auth/RefreshTokenStoreTest.php` | Create | D2/D6 unit matrix |
| `api/tests/Feature/Auth/RefreshTokenRotationTest.php` | Create | Rotation, reuse, family, ceiling, CSRF |
| `api/tests/Feature/Auth/CorsPreflightTest.php` | Create | D1 |
| `api/tests/Feature/Auth/CandidateGuardIsolationTest.php` | Create | D10 |
| `api/tests/Arch/Config/CorsConfigTest.php` | Create | D1 invariants |
| `api/tests/Feature/C2/Auth/AuthControllerTest.php` | Modify | refresh/logout change shape |
| `backoffice/app/plugins/00.auth-bootstrap.client.ts` | Create | D9 |
| `backoffice/app/composables/useAuth.ts` | Modify | Memory-only; `credentials:'include'`; CSRF header |
| `backoffice/app/composables/useApi.ts` | Modify | Refresh no longer sends a Bearer |
| `backoffice/app/pages/login.vue` | Modify | No storage write |
| `backoffice/app/middleware/02.auth.global.ts` | Modify | Document the boot precondition |
| `backoffice/tests/unit/{composables/useAuth,composables/useApi,middleware/auth,login}.spec.ts` | Modify | 611 RED lines |
| `backoffice/tests/e2e/session-cookie.spec.ts` | Create | D11 gate |
| `backoffice/tests/e2e/session-reload.spec.ts` | Create | No `/login` flash |
| Generated TS client (both apps) | Modify | `bun run codegen:check` drift |

---

## Testing Strategy

| Layer | What | How |
|---|---|---|
| Unit (Pest) | D2 algorithm: first use, replay, cross-family tamper, unknown hash revokes nothing, ceiling never extends | `RefreshTokenStore` against a real migrated `refresh_tokens` table (`RefreshDatabase`); `travel()` for the ceiling |
| Unit (Vitest) | Zero tokens in `sessionStorage`/`localStorage`; single-flight preserved; boot plugin swallows 401 | Stubbed `$fetch` (existing pattern survives) |
| Feature (Pest) | Full rotation chain; replay revokes family; revoked family; missing CSRF header → 403; disallowed `Origin` → 403; preflight for allowed vs unlisted origin; cookie flags **and `Path`** asserted on the raw `Set-Cookie`; login response has no `refresh_token` | HTTP tests + `$response->headers->getCookies()` |
| Arch | CORS config invariants (D1) | Config assertions |
| E2E (Chromium **+ WebKit**) | Cookie stored and replayed cross-site (D11); reload → no `/login` flash | `page.route()` + `context.cookies()` |

Coverage: 85 % overall, ~95 % on the auth path.

---

## Migration / Rollout

**This change carries its first database migration**
(`2026_08_20_000001_create_refresh_tokens_table.php`, storage corrected from Redis to
PostgreSQL). Railway runs `php artisan migrate --force` as a pre-deploy command, so it
executes against the live database on the next deploy. It is purely additive — one new
table, one new foreign key to the existing `users` table, no alteration of any existing
column or table — and safe to run with zero downtime. A revert would need a corresponding
`down()` migration (`DROP TABLE refresh_tokens`, already implemented) rather than relying
on TTL self-expiry as the original Redis design did.

Slices 4–6 revert to the sessionStorage behaviour; slice 3 reverts to today's single
rotating token. **Slice 1 must not be reverted** — reverting it restores the
wildcard-origin regression; fix forward.

Deploy order: slice 1 (with `CORS_ALLOWED_ORIGINS` set for *both* Nuxt origins) first and
alone; the 2–6 chain afterwards. There is no Redis eviction-policy deploy gate anymore —
`beai:check-redis-eviction` was removed along with the rejected Redis-backed design.

---

## Assumptions for user review

The user was unavailable; these were decided rather than asked, and each is reversible.

| # | Assumption | If wrong |
|---|---|---|
| A1 | api and backoffice stay on separate Railway subdomains ⇒ genuinely cross-site ⇒ `SameSite=None; Secure`, no `Domain` | A shared apex would allow `SameSite=Lax` + `Domain=.beai.app`, strictly safer. Revisit before a custom domain is committed |
| A2 | Local dev stays plain `http://localhost`, relying on the secure-context exemption | D11's mkcert fallback, already decided |
| A3 | WebKit honours `SameSite=None; Secure` over `http://localhost` | Highest-risk assumption in the change. D11 is the gate and the fallback |
| A4 | **Absolute** 14-day expiry from first login | Operator re-authenticates every 14 days regardless of activity. Sliding would let a stolen family live forever |
| A5 | Logout revokes the current family only; reuse revokes the whole family | "Sign out everywhere" is a separate capability, deliberately not built here |
| A6 | CSRF = custom header + strict allowlist + server-side Origin check; cookie `Path=/api/auth/refresh` | D5 |
| **A7 (new)** | 10-second concurrency grace (D6) is the right tradeoff: 10 s of replay tolerance in exchange for not logging two-tab operators out | Tightening it toward 0 returns to spurious logouts; widening it lengthens the replay window. Config-driven so it can be tuned without a code change |
| **A8 — SUPERSEDED** | ~~`maxmemory-policy` must be `noeviction` (D3)~~ — **rejected 2026-08-20**: the assumption itself was the error. The shared Redis instance also serves cache and queues, so `noeviction` breaks those the moment memory fills. Corrected to: refresh tokens are durable state and belong in PostgreSQL, not Redis, regardless of eviction policy | N/A — this was the "if wrong" outcome predicted by the original A8 row, and it happened; the durable-store redesign is D2/D3 as they now read above |
| **A9 (new)** | Adding a `fam` claim to the operator access token is acceptable in exchange for keeping the cookie `Path` narrow (D4) | The alternative is widening the cookie to `Path=/api/auth`, sending it on `/me` too |
| **A10 (new)** | Removing `auth:api` from `/api/auth/refresh` is in scope, because the cookie is the credential and the route is otherwise unrefreshable once the access token expires | This is a latent-bug fix riding along; if the user wants it isolated, it can be split out — but it cannot be *omitted*, the new flow depends on it |

## Open Questions

- [x] ~~Confirm Railway's managed Redis permits `CONFIG GET maxmemory-policy` and can be
      set to `noeviction` (A8).~~ **Resolved 2026-08-20 by removing the requirement, not by
      answering it**: the question itself assumed the wrong storage engine. Refresh tokens
      moved to PostgreSQL; Redis's eviction policy is no longer load-bearing for them.
- [ ] Is a `refresh.concurrent_duplicate` warning rate above some threshold worth alerting
      on? It is the only observable signal distinguishing a busy operator from a slow-motion
      replay attack.
- [ ] The missing CSP (`backoffice/nuxt.config.ts` has none, despite `useAuth.ts:9-11`
      naming it as the XSS mitigation) stays out of scope and remains recorded as a
      standing gap.
