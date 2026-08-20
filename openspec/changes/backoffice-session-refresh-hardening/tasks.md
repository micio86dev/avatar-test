# Tasks: Backoffice Session — httpOnly Refresh Cookie, Rotation, Reuse Detection

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | ~1855 (1: 155 · 2: 420 · 3: 400 · 4: 370 · 5: 330 · 6: 180) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR1 (slice 1, standalone) → PR2 → PR3 → PR4 → PR5 → PR6 (chain) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

```text
Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High
```

### Suggested Work Units

| Unit | Goal | PR | Base branch | Notes |
|---|---|---|---|---|
| 1 | CORS allowlist, both Nuxt origins | PR1 | `develop` | Merges alone — independently valuable, closes open-origin finding |
| 2 | Refresh token store (no HTTP wiring) | PR2 | `feature/backoffice-session-refresh-hardening` (tracker) | **Storage corrected 2026-08-20: PostgreSQL (`refresh_tokens` table), not Redis** — see design.md's superseded-D3 note. Unreferenced, fully tested |
| 3 | Controller/cookie/CSRF/remove `refresh_token` | PR3 | PR2 branch | Breaking: backoffice non-functional from here to PR5 |
| 4 | `useAuth` + boot plugin + middleware | PR4 | PR3 branch | Needs PR3's contract to pass tests |
| 5 | `useApi` + `login.vue` + client regen | PR5 | PR4 branch | Needs PR3's `openapi.json` |
| 6 | WebKit gate + no-flash E2E + docs | PR6 | PR5 branch | Last child; only the tracker merges to `develop` |

Only the tracker branch merges to `develop` after PR6. If a child diff shows a prior slice's changes, retarget/rebase before review.

---

## Slice 1 — CORS Allowlist (api) — PR1 → `develop`

- [x] 1.1 RED: `api/tests/Feature/Auth/CorsPreflightTest.php` — allowlisted origin gets `Access-Control-Allow-Origin`; unlisted origin does not; BOTH `backoffice` and `frontend` origins present (api-cors spec Req 1)
- [x] 1.2 RED: `api/tests/Arch/Config/CorsConfigTest.php` — no `*` in origins/patterns, `allowed_headers` enumerated (contains `X-BEAI-Refresh`, no `*`), `supports_credentials === true` (api-cors spec Req 2, 3)
- [x] 1.3 GREEN: create `api/config/cors.php` (env `CORS_ALLOWED_ORIGINS`, `allowed_origins_patterns: []`, `allowed_headers` enumerated, `max_age: 3600`, `supports_credentials: true`)
- [x] 1.4 GREEN: `api/.env.example`, `docs/deploy.md` — document `CORS_ALLOWED_ORIGINS` must list both Nuxt origins per environment (docs/deploy.md edit written but NOT committed — see apply-progress note on wrapper-repo dirty state)
- [x] 1.5 REFACTOR: confirm 1.1–1.2 pass; run `cd api && ./vendor/bin/pest --filter=Cors` (44/44 green)

**Acceptance**: api-cors spec 3 requirements, 8 scenarios all green. No wildcard anywhere.
**Ordering**: none — self-contained, no dependency on other slices.

---

## Slice 2 — Refresh Token Store (api, no HTTP wiring) — PR2 → tracker

> **Storage corrected 2026-08-20** — the original Redis-backed store (`Cache::add()`
> NX-EX, self-expiring keys, `noeviction` requirement) was rejected: the same Redis
> instance also backs `CACHE_STORE`/`QUEUE_CONNECTION`/`SESSION_DRIVER`, and `noeviction`
> would make unrelated cache writes and queue pushes fail loudly the moment memory fills.
> Reworked against a `refresh_tokens` PostgreSQL table instead. Tasks below reflect the
> corrected implementation; struck items were removed outright, not merely reworked.

- [x] 2.1 RED (corrected): `api/tests/Unit/Auth/RefreshTokenStoreTest.php` — rewritten against the `refresh_tokens` table (real `User` fixtures via `RefreshDatabase`, now wired into `Unit/Auth` in `tests/Pest.php`): first use consumes atomically; replay outside grace fails and kills the whole family (including the still-live generation); cross-family tamper (family_id mismatch) rejected; unknown hash revokes nothing; ceiling never extends on rotation (`travel()` to assert `Max-Age` shrinks, not resets); a family already dead returns `Revoked` on any further presentation
- [x] 2.2 GREEN: `api/config/refresh_tokens.php` — absolute TTL, `REFRESH_CONCURRENCY_GRACE_SECONDS` default 10, cookie name/path (comment updated: durable DB state, not Redis-only)
- [x] 2.2b GREEN (new): `api/database/migrations/2026_08_20_000001_create_refresh_tokens_table.php` — `user_id` (FK, cascade), `family_id` (indexed), `token_hash` (unique, indexed), `generation`, `absolute_expires_at`, `consumed_at`, `revoked_at`, timestamps
- [x] 2.2c GREEN (new): `api/app/Models/RefreshToken.php` — one row per generation, `Prunable` (`prunable()`: past ceiling OR revoked); NOT tenant-scoped (excluded in `tests/Arch/C2/TenantModelArchTest.php`, same reasoning as `Participant` — `/refresh` runs before any tenant context exists)
- [x] 2.3 GREEN (reworked): `api/app/Support/Auth/RefreshTokenStore.php` — `issue()`/`rotate()`/`revokeFamily()` against the DB, atomic via `DB::transaction()` + `lockForUpdate()` (the same convention already used throughout `InterviewController`), replacing the `Cache::add()` NX-EX convention
- [x] 2.4 GREEN: `api/app/Support/Auth/RefreshTokenCookie.php` — build/clear cookie per D4 contract (unchanged — storage-layer-agnostic)
- [x] ~~2.5~~ REMOVED: `api/app/Console/Commands/CheckRedisEvictionPolicy.php` (`beai:check-redis-eviction`) and its test deleted entirely — the requirement it enforced no longer applies.
- [x] ~~2.6~~ REMOVED (was a GATE): "verify Railway managed Redis permits `CONFIG GET maxmemory-policy` and can be set to `noeviction`" — moot; refresh-token durability no longer depends on Redis's eviction policy at all.
- [x] 2.7 GREEN (new): `api/bootstrap/app.php` — `model:prune --model=RefreshToken` registered in `withSchedule()`, `dailyAt('03:30')->onOneServer()` (passes `tests/Arch/Queue/SchedulerOnOneServerArchTest.php`)

**Acceptance**: full D2 unit matrix green (13/13, including the new "dead family stays Revoked" and "exactly one gen-1 row" assertions).
**Ordering**: independent of HTTP layer; blocks slice 3 (controller wiring depends on the store).

---

## Slice 3 — Controller Wiring, Cookie, CSRF, Remove `refresh_token` (api) — PR3 → PR2 branch — BREAKING

- [x] 3.1 RED (corrected first): update `api/tests/Feature/C2/Auth/AuthControllerTest.php` (14 existing tests) — remove `refresh_token`-field assertions, add `fam` claim assertion, assert `Set-Cookie` on login
- [x] 3.2 RED: `api/tests/Feature/Auth/RefreshTokenRotationTest.php` — full rotation chain, replay revokes family, revoked-family rejection, missing CSRF header → 403, disallowed `Origin` → 403 (non-preflight), preflight allowed vs unlisted, raw `Set-Cookie` flags **and `Path`** asserted, login response has no `refresh_token` key
- [x] 3.3 RED: `api/tests/Feature/Auth/CandidateGuardIsolationTest.php` — candidate JWT rejected at `/api/auth/refresh`; operator token rejected by `api-candidate` guard; candidate TTL unaffected (D10, 3 scenarios)
- [x] 3.4 GREEN: `api/app/Http/Middleware/RequireRefreshCsrfHeader.php` — require `X-BEAI-Refresh: 1` + server-side `Origin` allowlist check
- [x] 3.5 GREEN: `api/routes/api.php` — `/api/auth/refresh` drops `auth:api`, adds `RequireRefreshCsrfHeader`; `/logout`, `/me` keep `auth:api`
- [x] 3.6 GREEN: `api/bootstrap/app.php` — register middleware alias + `encryptCookies(except: ['beai_refresh'])` (undocumented-in-design necessity: Laravel's default cookie encryption would otherwise obscure the documented wire format)
- [x] 3.7 GREEN: `api/app/Http/Controllers/Auth/AuthController.php` — `login` mints family + `fam` claim + cookie; `refresh` calls `RefreshTokenStore::rotate()`; `logout` resolves family from `fam` claim, clears cookie; **deleted line 79 (`$refreshToken = $accessToken`)** and the `refresh_token` response key. Also re-checks `isDeactivated()` explicitly on the refresh path (TenantContext's kill switch no longer covers it — see D9 note in `TenantContext.php`).
- [x] 3.8 GREEN: `api/config/jwt.php` — comment-only, document why `refresh_ttl=20160` stays (D7, denylist retention)
- [x] 3.9 GREEN: `api/app/Http/Controllers/QueueHealthController.php` — `redis_eviction_policy` field (both `down` and `ok`/`degraded` branches). **Kept unchanged in the 2026-08-20 storage correction**: it now reports the shared cache Redis's actual policy for general observability only — no longer a refresh-token requirement, and nothing asserts it must equal `noeviction`.
- [x] 3.10 SAME COMMIT (D8 hard requirement): regenerate `openapi.json` via Scramble; do not defer to slice 5
- [x] 3.11 REFACTOR: `cd api && ./vendor/bin/pest` full run green — 1869 total, 1864 passed, 5 pre-existing skips, 0 failed. Re-confirmed on the final restructured PR3 branch as a clean, isolated, non-concurrent run.

**Acceptance**: identity-auth spec — Login/Token Refresh/Logout MODIFIED + Refresh Cookie Contract/Storage Model/Reuse Detection/Absolute Expiry/CSRF/Concurrent Grace/Database Durability and Scheduled Prune/Candidate Isolation ADDED — all scenarios green. ("Refresh Token Redis Durability" renamed/superseded by "Refresh Token Database Durability and Scheduled Prune" in the 2026-08-20 storage correction.)
**Ordering**: depends on slice 2's store. `openapi.json` regeneration here is a hard precondition for slice 5's client regen. Backoffice is non-functional from this point — **must never merge to `develop` alone**.
**Size note**: slice 2 measured ~861 changed lines (est. 420) and slice 3 measured ~850 (est. 400) — both ~2x the tasks.md forecast, driven mostly by comment density and the interface-based probe refactor. Flagged for `size:exception` / further review-lens attention on these two child PRs specifically.

---

## Slice 4 — `useAuth` + Boot Plugin + Middleware (backoffice) — PR4 → PR3 branch

- [x] 4.1 RED (corrected first): rewrite `backoffice/tests/unit/composables/useAuth.spec.ts` (163→) — remove `sessionStorage.getItem` assertions; assert memory-only ref, `credentials:'include'`, `X-BEAI-Refresh` header sent
- [x] 4.2 RED (corrected first): rewrite `backoffice/tests/unit/middleware/auth.spec.ts` (71→) — remove synchronous `isAuthenticated` assumption; assert compatibility with async boot rehydration
- [x] 4.3 RED: add boot-plugin unit test (`tests/unit/plugins/auth-bootstrap.spec.ts`) — swallows 401/network error without throw, resolves normally, session left empty
- [x] 4.4 GREEN: rewrite `backoffice/app/composables/useAuth.ts` — module-scoped `ref` only, no `sessionStorage`/`localStorage`, `credentials:'include'`, CSRF header on refresh calls; preserve existing single-flight
- [x] 4.5 GREEN: create `backoffice/app/plugins/00.auth-bootstrap.client.ts` — async `setup()`, awaited `POST /api/auth/refresh`, calls `useAuth().refresh()` directly (never `useApi()`), swallows rejection
- [x] 4.6 GREEN: `backoffice/app/middleware/02.auth.global.ts` — stays synchronous; updated header comment documenting the new precondition
- [x] 4.7 REFACTOR: `cd backoffice && bun run test:unit` (**Bun only**) — 748/748 green at the time (749/749 after the slice-6 race-condition fix added one more test)

**Acceptance**: admin-backoffice Authenticated Session — memory-only storage, awaited boot refresh, no throw/no redirect on failed boot refresh, zero tokens in browser storage (all 5 scenarios).
**Ordering**: requires PR3 merged into this branch (needs the real `fam`-claim/cookie/no-`refresh_token` contract to test against).
**Collateral fixes (out of original task scope, required for correctness, both root-caused via manual debugging)**:
1. Two PRE-EXISTING E2E specs (`unsupported-gate.spec.ts`, `sidebar-navigation.spec.ts`) bypassed login by writing directly to `sessionStorage` before boot — a technique that silently stopped working once the token became memory-only. Both were updated to mock `POST /auth/refresh` instead (the new equivalent bypass).
2. **Real production bug, not just a test artifact**: `useAuth.ts`'s `refresh()` unconditionally called `clearSession()` on failure. Since `00.auth-bootstrap.client.ts`'s boot-time refresh can still be in flight when a direct `login()` → `setSession()` establishes a session on a different code path, a slow/failed boot refresh resolving AFTER a successful login would wipe it — a genuine race, reproduced first via a corrected-first unit test (RED), then fixed by only clearing the session if nothing else changed it while the attempt was in flight (GREEN). All 6 login()-then-goto() E2E specs (`profile`, `settings-tabs`, `projects-crud`, `reports-index`, `entry-link`, `autocomplete-hygiene` — 25 tests) exposed a SEPARATE, related discovery while chasing this: `page.goto()` to a new route after login is a REAL browser navigation in this `ssr:false` SPA, not a client-side transition, so it reboots the app and re-fires the boot refresh; none of those specs' `login()` helpers mocked `/auth/refresh`, so the reboot always failed and bounced back to `/login`. Fixed by adding the same `/auth/refresh` mock to each. 25/25 green on both `chromium` and `webkit`.

---

## Slice 5 — `useApi` + `login.vue` + Client Regen (backoffice) — PR5 → PR4 branch

- [x] 5.1 RED (corrected first): rewrite `backoffice/tests/unit/composables/useApi.spec.ts` (183→) — remove `Authorization`-header refresh assumption; assert 401→`credentials:'include'` refresh→retry, no Bearer on refresh (test already green post-slice-4 — `useApi.ts` delegates its refresh path entirely to `useAuth().refresh()`, so no additional code change was needed there)
- [x] 5.2 RED (corrected first): rewrite `backoffice/tests/unit/login.spec.ts` (194→) — remove `sessionStorage.getItem('beai_access_token')` assertion; assert no storage write anywhere
- [x] 5.3 GREEN: `backoffice/app/composables/useApi.ts` — verified already correct (no code change needed, see 5.1 note)
- [x] 5.4 GREEN: `backoffice/app/pages/login.vue` — remove token persistence (interface no longer types `refresh_token`); add `credentials:'include'` to the login `$fetch` call (load-bearing: api/backoffice are different origins, and a cross-origin response's `Set-Cookie` is silently dropped by the browser without credentialed mode)
- [x] 5.5 GREEN: regenerate TS client from slice 3's `openapi.json`; `bun run codegen:check` clean in `backoffice`. **`frontend` NOT touched** — explicit orchestrator scope restricted this apply session to `api` and `backoffice`; `frontend`'s committed `openapi.json`/`types/api.ts` will show drift until a human runs `bun run codegen && commit` there (candidate app functionality itself is unaffected — it never calls the operator `/auth/login` endpoint).
- [x] 5.6 REFACTOR: `cd backoffice && bun run test:unit` full run green (748/748 at the time), `bun run typecheck` and `bun run lint` clean (0 errors)

**Acceptance**: login/refresh client contract matches the no-`refresh_token` API shape; `codegen:check` clean in `backoffice`; `frontend` codegen deferred (see 5.5).
**Ordering**: depends on slice 3's `openapi.json` (already produced, not regenerated here) and slice 4's `useAuth` shape.

---

## Slice 6 — WebKit Gate + No-Flash E2E + Docs — PR6 → PR5 branch, final child

- [x] 6.1 NEW: `backoffice/tests/e2e/session-cookie.spec.ts` — **both** `chromium` and `webkit` projects; `127.0.0.1` vs `localhost` cross-site probe via `page.route()`; assert stored (`context.cookies()`) and resent (D11). **RESULT: `chromium` PASSES; `webkit` FAILS — A3 (WebKit honours SameSite=None+Secure over http://localhost) is CONFIRMED FALSE in this environment.** The failure is left RED (per D11, this must fail CI, never silently pass or skip) pending 6.3.
- [x] 6.2 NEW: `backoffice/tests/e2e/session-reload.spec.ts` — reload with valid refresh cookie never renders `/login`. 4/4 green on both `chromium` and `webkit`.
- [ ] 6.3 IF 6.1 fails on WebKit: apply pre-decided fallback — serve Playwright `webServer` + docker-compose over HTTPS via mkcert; document in `docs/dev-setup.md`. **Do not weaken the cookie.** **NOT IMPLEMENTED**: `mkcert` is not in the pinned toolchain (D37/docs/version-catalog.md) and installing new local/CI tooling mid-apply was judged out of scope for an unattended session — this is a human decision (which tool, whether CI needs it too, docker-compose wiring), not an implementation one. The cookie itself was NOT weakened. **This is the single most significant open item in this change.**
- [x] 6.4 DOCS: `docs/dev-setup.md` — local dev cookie story (A2/A3) written, including the empirical WebKit failure and the exact unimplemented mkcert fallback steps (wrapper-repo edit, not committed — see apply-progress)
- [x] 6.5 DOCS (superseded 2026-08-20): `docs/deploy.md` — production origins section. Its `beai:check-redis-eviction` deploy-order gate section was **replaced**, not merely updated, with a "Refresh Tokens Are Database-Backed, Not Redis" section explaining the correction and a migration deploy-risk note (`2026_08_20_000001_create_refresh_tokens_table.php` is additive and safe on a live database) — wrapper-repo edit, not committed, see apply-progress.
- [~] 6.6 Playwright full run, `--workers=1`, both projects — a full-suite run was attempted but overlapped with concurrent branch-restructuring `git` operations in this session; its 47-failure count was contamination, NOT signal, and led to finding (and fixing) two real bugs via targeted isolated re-runs instead (see slice 4's collateral-fixes note). What IS verified clean, isolated, non-concurrent, on the FINAL commit: `session-cookie.spec.ts` + `session-reload.spec.ts` + `unsupported-gate.spec.ts` + `sidebar-navigation.spec.ts` together = 37/38 (the one failure is the documented `webkit` gate, D11/6.1); `profile.spec.ts` + `settings-tabs.spec.ts` + `projects-crud.spec.ts` + `reports-index.spec.ts` + `entry-link.spec.ts` + `autocomplete-hygiene.spec.ts` = 25/25 on BOTH `chromium` and `webkit`; `admin-flow.spec.ts`'s 4 report-viewer failures confirmed identical against the unmodified `b1fe248` baseline (pre-existing, unrelated). A single fully-clean ALL-FILES run in one process is still owed before this chain ships (every file has now been verified in smaller clean batches, but never all together in one pass) — recommend the orchestrator or a follow-up session run it as a final gate.

**Acceptance**: admin-backoffice WebKit SameSite=None Verification Gate — 3 scenarios; failure blocks merge, is not silently accepted. **Gate is currently RED on `webkit` by design (6.3 pending) — this chain must NOT merge to `develop` until 6.3 is resolved or the maintainer explicitly accepts the Chromium-only interim state.**
**Ordering**: last child PR; only the tracker branch (after this merges) goes into `develop`.

---

## Assumptions for user review (tasks-level)

- **T1 (word-budget deviation)**: this artifact exceeds the sdd-tasks skill's 530-word guideline. The orchestrator's directive explicitly required per-slice changed-line estimates, corrected-vs-added test breakdown, acceptance criteria, and cross-submodule ordering for all 6 slices — completeness was prioritized, consistent with the same tradeoff recorded in spec.md's S2.
- **T2 (SUPERSEDED 2026-08-20)**: originally, 2.6 was written as a hard blocking gate task ("verify Railway's Redis can be set to `noeviction`, escalate if not") on the theory that a `noeviction`-incapable Redis would invalidate the storage choice. The user ratified that exact outcome as having occurred — not because Railway's Redis rejected `noeviction`, but because requiring it at all was the error: the same Redis instance also serves `CACHE_STORE`/`QUEUE_CONNECTION`, so `noeviction` would break unrelated cache/queue writes under memory pressure. Task 2.6 is removed (not merely resolved); the storage choice moved to PostgreSQL per design.md's D2/D3 correction.
- **T3**: task numbering intentionally mirrors design.md's D-numbers where a 1:1 mapping exists, to keep design ↔ tasks traceable without restating rationale.
