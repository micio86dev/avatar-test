# Proposal: Backoffice Session — httpOnly Refresh Cookie, Rotation, Reuse Detection

## Intent

The operator loses their backoffice session constantly. **The TTL is not the cause.**
`api/config/jwt.php:108,127` already grants `ttl=30` min and `refresh_ttl=20160` min
(exactly 14 days). The cause is one line: `backoffice/app/composables/useAuth.ts:40`
writes the token to **`sessionStorage`**, which the browser wipes on tab close. The
14-day window has never been reachable in practice.

The cheap fix — `localStorage` — was offered and **rejected by the user**, for a reason
verified in code: `AuthController.php:79` sets `$refreshToken = $accessToken`. The two
strings are literally identical. Today's access token **is** its own refresh credential.
Persisting it in JS-readable storage for 14 days makes any XSS a 14-day multi-tenant
admin takeover. That is not a session-length problem, it is a credential-design problem.

**Second finding, independent of the above and arguably more urgent.**
**`api/config/cors.php` does not exist.** Verified: `api/config/` holds 25 config files
and `cors.php` is not among them. Laravel 11+ merges the framework's vendor default for
any unpublished key, so the production multi-tenant API is running with
`allowed_origins: ['*']` — **it accepts CORS from any origin on the internet today**.
That is worth stating on its own terms, before it becomes this change's blocker.

And it is this change's blocker. Per the Fetch spec, `Access-Control-Allow-Origin: *` is
flatly incompatible with `Access-Control-Allow-Credentials: true`; browsers reject the
pair. A project-owned `config/cors.php` with an explicit origin allowlist plus
`supports_credentials: true` is **mandatory new infrastructure**, not hardening. No
cookie can work until it exists.

## Ratified decision (not re-opened here)

httpOnly refresh cookie + rotation on every use + reuse detection revoking the whole
token family; access token in memory only. Recorded 2026-08-19.

## Scope

### In Scope

| # | Deliverable |
|---|---|
| 1 | Project-owned `api/config/cors.php`: explicit env-driven origin allowlist, `supports_credentials: true`, no wildcard — closes the open-origin finding **and** unblocks cookies |
| 2 | Opaque refresh token: cryptographically random, **hashed at rest**, Redis-backed, carrying `family_id` + generation counter and an absolute expiry ceiling |
| 3 | Rotation on every `/api/auth/refresh`; reuse of an already-rotated token revokes the **entire family** (OWASP shape) |
| 4 | Delivery as `HttpOnly; Secure; SameSite=None; Path=/api/auth/refresh` — path-scoped, distinct cookie name, never `Path=/` |
| 5 | CSRF defense on `/api/auth/refresh`: strict CORS allowlist **plus** a required custom request header (A6) |
| 6 | Remove the `refresh_token` field from the login response (A-extra below) |
| 7 | Access token stays a short-TTL jwt-auth JWT in the JSON body, held **in memory only** by the SPA — no `sessionStorage`, no `localStorage` |
| 8 | Nuxt client plugin performing an **awaited** silent refresh before `02.auth.global.ts` evaluates auth, so a reload does not flash `/login` |
| 9 | Pest coverage for rotation / reuse / family revocation / CORS preflight (none exists); rewrite of the four backoffice Vitest suites |
| 10 | Empirical WebKit verification of `SameSite=None` in the existing Playwright WebKit project — an acceptance criterion, not a footnote |
| 11 | Documented local-dev cookie story in `docs/dev-setup.md`; production origin config in `docs/deploy.md` |

### Out of Scope

- **Changing the 14-day figure.** It is already correct in config and already ratified.
- **Candidate/frontend auth.** Untouched, and asserted below.
- **"Sign out everywhere."** The family model makes it possible for the first time; it is
  a distinct user-facing capability and should be scoped as its own change (A5).
- **The missing CSP.** `useAuth.ts:9-11` claims "the real XSS mitigation is the existing
  CSP/security headers" — `backoffice/nuxt.config.ts` sets X-Frame-Options,
  X-Content-Type-Options, Referrer-Policy and Permissions-Policy and **no CSP at all**.
  The claim is false. Recorded here, fixed elsewhere; this change removes the reliance on
  it rather than papering over it.
- **A per-user session/device registry.** `RejectStaleCredentials.php` documents its
  absence. The family model is a step toward it, not the thing itself.

## Capabilities

### New Capabilities

- `api-cors`: the API's browser-origin trust boundary — allowed origins, methods, headers,
  `supports_credentials`, preflight max-age, and the prohibition on wildcard origins. It is
  app-wide policy affecting every endpoint, so it does not belong inside `identity-auth`.

### Modified Capabilities

- `identity-auth`: refresh-credential model changes from "the access token is its own
  refresh credential" to a separate opaque, hashed, family-scoped refresh token delivered
  by cookie. Affects the existing **Token Refresh** and **Logout (Denylist)** requirements;
  adds rotation, reuse detection, absolute expiry, and the CSRF header on `/auth/refresh`.
- `admin-backoffice`: the **Authenticated Session** requirement (`spec.md:45`) currently
  mandates "Bearer JWT storage". It becomes: access token in memory only, session
  continuity from the cookie via an awaited boot-time refresh.

`project-skeleton`'s **Security Headers** requirement is *not* modified — CORS is a
separate concern and gets its own spec rather than being appended there.

## Approach

Adopted from exploration, with no reason found to deviate.

**Reuse the existing atomic-consume convention.**
`api/app/Support/Jwt/CandidateTokenFactory::consumeJti()` already establishes the pattern:
`Cache::add()` → Redis `SET NX EX`. The refresh-token store uses the same primitive for
single-use consumption rather than inventing a second convention. Rotation is therefore
atomic by construction: the consume either wins or the token was already spent — and
"already spent" **is** the reuse signal.

**Why opaque rather than a second JWT.** A second distinct-claim JWT would reuse more
existing infrastructure, but jwt-auth's denylist is per-`jti` with no family concept — a
detected replay could not cascade-revoke. Reuse detection with family revocation is
precisely what was ratified, so the JWT option cannot deliver the requirement.

**Candidate flow is UNAFFECTED — verified, then asserted.**
`api/app/Providers/AppServiceProvider.php:213-243` registers the `api-candidate` guard and
asserts `$payload->get('typ') === 'candidate'` as its **primary** defense (line 232), with
an explicit code comment that tymon does not check custom claims. Any token lacking that
claim is rejected regardless of validity. `CandidateTokenFactory` calls `setTTL(120)`,
overriding the global `config/jwt.php` values, so nothing here reaches candidate token
lifetimes. Conflating operator and candidate auth would be a serious regression; it is
structurally impossible, and that is the reason it is safe — not an assumption.

**A-extra — the `refresh_token` field: REMOVE it, do not fix it.** It currently duplicates
the access token, so the API advertises a security property it does not have. After this
change the real refresh credential is an httpOnly cookie the client must **never** read;
a JSON field of the same name would invite exactly the storage behaviour being removed.
Breaking-change cost is nil: CLAUDE.md ratifies "no legacy backward compatibility —
greenfield", and the only consumer is `backoffice`, changed in this same work.

## Assumptions for user review

The user was unavailable. These six are **defaults adopted to keep moving**, each with the
evidence behind it and the cost of overruling. Every one is cheap to change at design time
and expensive to change after apply.

| # | Assumption | Evidence | If wrong |
|---|---|---|---|
| **A1** | **`api` and `backoffice` stay on separate Railway subdomains** → genuinely cross-site, so `SameSite=None; Secure` is required and `Domain=` scoping to a shared apex is unavailable | `docs/deploy.md` D34 + per-service `railway.json` (DOCKERFILE builder, no custom domain committed anywhere in the repo) | If both later sit behind one apex, `SameSite=Lax` + `Domain=.example.com` becomes possible and is **strictly safer** — worth revisiting; it would also make A6's CSRF work lighter |
| **A2** | **Local dev keeps plain `http://localhost`**, relying on the browser secure-context exemption for `Secure` cookies; a dev story is documented in `docs/dev-setup.md` | `docker-compose.yml` serves plain HTTP; backoffice `:3001` and api `:8000` are already different origins locally | If the exemption proves unreliable (see A3), local dev needs an HTTPS proxy — a real toolchain change |
| **A3** | **WebKit `SameSite=None`+localhost behaviour is VERIFIED empirically**, never assumed from Chromium | CLAUDE.md mandates a WebKit desktop Playwright project; Safari's historical handling differs from Chrome's | This is the assumption most likely to break A2. It is written as an **acceptance criterion** so it fails loudly in CI rather than quietly in Safari |
| **A4** | **ABSOLUTE 14-day expiry from first login, not sliding** | mirrors jwt-auth's own `refresh_ttl` semantics ("within 2 weeks of the ORIGINAL token") | Tradeoff stated plainly: the operator re-authenticates every 14 days regardless of activity. A sliding window would let a stolen refresh token be kept alive **indefinitely**; absolute expiry bounds the damage. Overrule if the UX cost is judged higher than that risk |
| **A5** | **Normal logout revokes the CURRENT family only**; reuse detection revokes the whole family. "Sign out everywhere" is proposed as a separate capability | preserves today's per-token logout UX (`AuthController::logout`) while making reuse a hard stop | If logout should mean all devices, that is a one-line policy change at design time — but it is a **user-visible behaviour change** and should be a deliberate product call, not a side effect |
| **A6** | **CSRF = strict CORS origin allowlist + a required custom header on `/api/auth/refresh`**, with the cookie scoped to `Path=/api/auth/refresh` **only** | `SameSite=None` provides **zero** CSRF protection by itself; browsers will not attach a custom header cross-origin without a successful preflight | Path scoping is the detail that silently rots: `Path=/` would ship the cookie on every API call and enlarge exposure for no benefit. If a synchronizer-token scheme is preferred instead, decide it in design |

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/config/cors.php` | **New** | Origin allowlist + `supports_credentials`; replaces the merged vendor wildcard |
| `api/app/Support/Auth/RefreshToken*` | New | Opaque token mint/hash/consume, family + generation, absolute ceiling |
| `api/app/Http/Controllers/Auth/AuthController.php` | Modified | `login`/`refresh`/`logout`; `refresh_token` field removed (`:79`) |
| `api/app/Http/Middleware/` | New | Custom-header CSRF check on the refresh route |
| `api/routes/api.php` | Modified | `/auth/refresh` leaves `auth:api` — the cookie, not a bearer, is now the credential |
| `api/config/jwt.php` | Modified | Access-token `ttl` unchanged/short; `refresh_ttl` no longer the session ceiling |
| `api/tests/Feature/C2/Auth/AuthControllerTest.php` (219 lines) | Modified | 14 existing tests; refresh/logout cases change shape |
| `api/tests/Feature/.../Refresh*`, `Cors*` | New | Rotation, reuse→family revocation, absolute expiry, preflight |
| `backoffice/app/composables/useAuth.ts` (135 lines) | **Rewritten** | sessionStorage removed; in-memory only; `credentials:'include'` |
| `backoffice/app/composables/useApi.ts` | Modified | `credentials:'include'`; refresh no longer sends `Authorization` |
| `backoffice/app/plugins/auth-bootstrap.client.ts` | **New** | Awaited silent refresh before route middleware (only `i18n-base-url` + `analytics` exist today) |
| `backoffice/app/middleware/02.auth.global.ts` | Modified | Must not evaluate `isAuthenticated` before the boot refresh settles |
| `backoffice/app/pages/login.vue` | Modified | No token persistence |
| `backoffice/tests/unit/{composables/useAuth,composables/useApi,middleware/auth,login}.spec.ts` | **Rewritten** | 611 lines total — see Test Impact |
| `backoffice/tests/e2e/` | New | WebKit + Chromium cookie survival across reload/tab-close (A3) |
| `docs/dev-setup.md`, `docs/deploy.md`, `.env.example` ×2 | Modified | Origin allowlist config + dev cookie story |

## Test Impact under strict TDD — sized honestly

All four backoffice Vitest suites assert the mechanism being removed and are **RED from
day one**, not incrementally:

| Suite | Lines | Why it breaks |
|---|---|---|
| `composables/useAuth.spec.ts` | 163 | Asserts `sessionStorage.getItem(KEY)` after `setSession()` |
| `composables/useApi.spec.ts` | 183 | 401→refresh→retry assumes the refresh carries `Authorization` |
| `middleware/auth.spec.ts` | 71 | Asserts `isAuthenticated` **synchronously** after `setSession()`; incompatible with async boot rehydration |
| `login.spec.ts` | 194 | Asserts `sessionStorage.getItem('beai_access_token')` directly |

This is a rewrite of ~611 lines of test code, not a tweak. The single-flight `$fetch`/
`useRuntimeConfig` stubbing pattern survives; the storage and synchronicity assertions do
not. Pest has **zero** coverage of rotation families, reuse, or cookies — entirely new ground.

## Changed-line forecast and slice boundaries

Two submodules, new infrastructure, and a full test rewrite. This will not fit one PR.

| Slice | Content | Est. lines |
|---|---|---|
| **1** | `config/cors.php` + env + preflight Pest tests | ~155 |
| **2** | Refresh-token store (mint/hash/consume/family) + unit tests — **no controller wiring** | ~380 |
| **3** | `AuthController` wiring, cookie emission, `refresh_token` removal, CSRF header middleware + feature tests | ~390 |
| **4** | `useAuth` rewrite + `auth-bootstrap` plugin + middleware; `useAuth.spec` / `auth.spec` rewrite | ~370 |
| **5** | `useApi` + `login.vue` + their spec rewrites | ~330 |
| **6** | Playwright WebKit/Chromium cookie verification (A3) + docs | ~180 |

**Total forecast: ~1,800 changed lines.**
`Decision needed before apply: Yes`
`Chained PRs recommended: Yes`
`400-line budget risk: High`

Feature Branch Chain: PR 1 targets the feature branch; each later PR targets its
predecessor. Slice 1 is independently valuable and independently mergeable — it closes the
open-origin finding whether or not the rest ships. Slices 2→3 and 4→5 are hard-ordered.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| CORS allowlist misconfigured in production → **total backoffice lockout**, not a degraded feature | **High** | Slice 1 ships first and alone; env-driven; documented in `docs/deploy.md`; preflight asserted by test |
| WebKit rejects `SameSite=None` over `http://localhost`, breaking local dev for every developer | **High** | A3 is an acceptance criterion verified in the existing WebKit project **before** slice 4 |
| Boot plugin not awaited → every reload flashes `/login` | **High** | Nuxt awaits a promise-returning plugin; asserted by an E2E reload test, not by inspection |
| Redis eviction silently drops refresh-token keys → mass phantom logouts | Med | Confirm the production `maxmemory-policy` is not `allkeys-*` before design sign-off; treat as a slice-2 gate |
| Reuse detection false-positives on a genuine double-submit (double-click, retry) and logs the operator out | Med | Single-flight refresh already exists client-side (`useAuth.ts:79`); atomic consume makes the race deterministic; keep a short grace on the immediately-previous generation if evidence demands |
| Removing `refresh_token` breaks an unknown consumer | Low | Greenfield, no external consumers; `backoffice` is the only caller and changes in-flight |
| 611 lines of RED tests tempt a "fix the tests to pass" shortcut | Med | Slice boundaries keep each RED set small; strict TDD ordering enforced in `sdd-tasks` |

## Rollback Plan

Per slice, and deliberately ordered so rollback never strands the operator.

- **Slices 4–6 (backoffice)**: revert restores in-memory + `sessionStorage` behaviour. The
  API still accepts a bearer token on `/auth/refresh` if slice 3 kept that path alive
  during transition — design must decide whether to keep it briefly for exactly this reason.
- **Slice 3**: reverting the controller restores today's single-rotating-token behaviour.
  No migration, no persistent schema — the refresh store is Redis-only, so a revert leaves
  orphaned keys that expire on their own TTL. Nothing to un-migrate.
- **Slices 1–2**: independently revertible. Reverting slice 1 restores the wildcard CORS
  default, which is a **security regression**, so it should be re-fixed forward rather than
  rolled back.

No database migration is introduced anywhere in this change.

## Dependencies

- **Production Redis `maxmemory-policy` must not evict** the refresh-token keyspace (slice 2 gate).
- Deployment origins known per environment before slice 1 ships (`docs/deploy.md`).
- Tests: `cd api && ./vendor/bin/pest`, `cd backoffice && bun run test:unit`. Run exact
  files or full runs — never `php artisan test --filter`, observed fabricating passes in
  this repo. Playwright `--workers=1`.

## Success Criteria

- [ ] The operator closes the tab, reopens the backoffice up to 14 days later, and is still signed in.
- [ ] No access token is present in `sessionStorage` or `localStorage` at any point — asserted by test.
- [ ] `api/config/cors.php` exists, names explicit origins, sets `supports_credentials: true`, and contains **no wildcard**; a request from an unlisted origin is refused — asserted by test.
- [ ] A refresh token replayed after rotation revokes the **entire family** and forces re-authentication — asserted by test.
- [ ] The refresh cookie is `HttpOnly`, `Secure`, `SameSite=None`, and scoped to `Path=/api/auth/refresh` — asserted by test, path included.
- [ ] A cross-origin `POST /api/auth/refresh` without the required custom header is refused.
- [ ] A page reload never renders `/login` for an authenticated operator — asserted by E2E.
- [ ] The cookie flow passes in **both** the Chromium and WebKit Playwright projects (A3).
- [ ] The login response no longer contains `refresh_token`.
- [ ] Candidate interview flow passes unchanged; a candidate token still cannot authenticate an operator route, and vice versa.
- [ ] Coverage gates hold: 85% overall, ~95% on the auth path.

## Proposal question round

Not asked interactively — the user was unavailable and execution mode is `automatic`. The
six assumptions above (A1–A6) are the questions, each answered with a documented default,
its evidence, and the cost of overruling. **A1 and A4 are the two worth a human minute
before design**: A1 changes the cookie's security posture outright, and A4 is a UX/security
tradeoff no amount of code reading can settle.
