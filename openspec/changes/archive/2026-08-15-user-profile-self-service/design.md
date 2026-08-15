# Design: User Profile Self-Service

## Technical Approach

A **separate self-service path** beside admin user management, never a self-branch inside it.
`UserPolicy` (`api/app/Policies/UserPolicy.php:33-36`) stays `hasRole('admin')` on every verb; the new
surface has no policy at all because there is no object to authorize — the subject IS the token.
Password change revokes every OTHER session via a `password_changed_at`/`iat` comparison and re-mints
the acting session's token in the response. The backoffice promotes `useCurrentUser` to module-scoped
shared state (the `useAuth.ts:22-29` "poor-man's store" precedent), renders initials identity in a new
`SidebarFooter`, and ships `/profile` as two independent forms that satisfy the form-contract arch
guard from the first commit.

## Architecture Decisions

### D1 — Endpoint shape: singular self-resolving `/api/profile`

| Option | Tradeoff | Verdict |
|---|---|---|
| `GET\|PATCH /api/profile` + `PUT /api/profile/password` | Mirrors `/api/organization` (`api/routes/api.php:87-96`) exactly: no id in the path, subject from the token, **zero IDOR surface to test** | **Chosen** |
| Extend `/api/auth/me` to accept `PATCH` | `me` is a session-introspection endpoint returning a nested `{user, organization, roles}` envelope; a write would need an asymmetric flat body, would put profile writes in `AuthController` (which has no FormRequest discipline, only inline `$request->validate`), and would couple the read contract of `identity-auth` to every future profile field | Rejected |

Middleware group: a **new `Route::middleware(['auth:api', TenantContext::class])->group(...)` block placed
immediately after the Organization Settings block**, byte-identical in shape to `api.php:93-96`. Not the
`auth` prefix group (`:54-62`) — that group contains the one PUBLIC route in the file and must stay
minimal. `TenantContext` is listed inline even though `bootstrap/app.php:79` appends it globally, because
every human block in this file lists it; re-execution is idempotent.
The password route additionally carries `throttle:6,1` (see D5).

`PUT /api/profile/password` returns `200 {access_token, token_type}` — the same shape as
`AuthController::refresh` (`:100-103`), so the client has one known token-swap contract.

### D2 — Allow-list: `safe()->only()` is the enforcement point, `$fillable` is the backstop

Three layers, each catching what the others cannot:

| Layer | Catches | Fails to catch |
|---|---|---|
| `UpdateProfileRequest::rules()` — only `name`, `email`, `locale` declared | Bad *shapes* | **Nothing on its own.** A FormRequest does not strip unknown keys; `$request->all()` still carries `role` |
| `$user->update($request->safe()->only(['name','email','locale']))` in the controller | Every unlisted key in the body, **silently dropped** | A future controller line that writes an attribute directly |
| `User::$fillable` (`api/app/Models/User.php:46-54`) | `organization_id`, `is_superadmin`, `deactivated_at` mass assignment, model-wide | `role` — not a column at all (Spatie pivot), so `$fillable` is blind to it |

Rejected: `prohibited` rules returning 422 on a `role` key — `OrganizationController.php:41-45` explicitly
chose "silently dropped rather than validated-then-rejected", and a 422 turns the endpoint into a probe
for which attributes exist. Rejected: relying on `$fillable` alone — it is a MODEL-global setting shared
with the admin path, so widening it for a future importer would silently widen self-service too.

### D3 — Session revocation: `password_changed_at` vs `iat`, needs a migration

Verified: there is **no per-user token registry**. `config/jwt.php:227` enables the jti denylist, and
`JWTGuard::logout()` denylists exactly ONE jti — the presented one. The API therefore cannot enumerate a
user's live jtis, so "revoke all other sessions" is unimplementable on the denylist alone.

**Chosen**: a new nullable `users.password_changed_at` column, compared against the token's `iat` claim by a
new `RejectStaleCredentials` middleware appended to the `api` group. **This is a migration — the proposal's
"code-only rollback" claim is now false** and the rollback plan must drop the column.

Two verified facts make this sound:
- `Manager::buildRefreshClaims()` (`vendor/tymon/jwt-auth/src/Manager.php:164-180`) **preserves the original
  `iat` across refresh**. A revoked session cannot refresh its way back to a fresh `iat`.
- `iat` is second-precision. `password_changed_at` MUST be stored `->startOfSecond()` and compared with a
  strict `iat < password_changed_at`, or the token minted in the same wall-clock second as the change is
  born dead. Accepted residual: a foreign token minted in the same second survives.

Placed in its own middleware, **not** inside `TenantContext`, despite that class documenting itself as "the ONE
enforcement point" for the deactivation kill switch: three route groups call
`withoutMiddleware(TenantContext::class)`, so piggybacking would let a future tenancy exemption silently
revoke credential revocation too.

Status code: `401 {"error":"credentials_changed"}` — honest semantics (stale credential, not a forbidden
request), paired with a check in `useApi.ts` placed **before** `isUnauthorized()`, exactly where
`isAccountDeactivated()` already sits (`:38-45,70-76`), so it clears the session and redirects without
burning a pointless refresh round-trip.

**The acting session survives** by re-minting, not by exemption: the controller sets the password and
timestamp, calls `$guard->logout()` (denylists the acting jti — the SAME mechanism), then
`$guard->login($user)` for a brand-new token whose `iat >= password_changed_at`, returned in the body.
`ProfilePasswordForm` hands it to `useAuth().setSession()`.

### D4 — Password validation

`UpdatePasswordRequest` (new; `UpdateUserRequest` is never touched or reused):

```php
'current_password' => ['required', 'string', 'current_password:api'],
'password'         => ['required', 'string', 'min:8', 'confirmed', 'different:current_password'],
```

`current_password` **is confirmed present** in this version
(`Validation/Concerns/ValidatesAttributes.php:554-566`). The `:api` parameter is not decoration: the rule
resolves `auth()->guard($param)` and the default guard is `env('AUTH_GUARD', 'api')` (`config/auth.php:19`) —
an env change would make the rule read the wrong guard and fail closed on every request. `min:8` matches the
admin path deliberately; a stricter self-service floor than the admin floor would be theatre.

### D5 — Rate limiting: yes, `throttle:6,1` on the password route only

The repo has **no** `throttle` middleware today; this is the first. Without it the endpoint is a
**current-password oracle**: `useAuth.ts:5-11` documents sessionStorage tokens as an accepted XSS risk, so a
stolen 30-minute token becomes an unlimited online cracker for the victim's current password — which is the
password most likely reused on other systems. Throttling turns 30 minutes of unlimited guesses into ~180.

### D6 — `useCurrentUser` shared state

Module-scoped `ref<CurrentUser | null>` plus a module-scoped in-flight promise, copying
`useAuth.ts:27-29`'s `refreshInFlight` single-flight shape. API: `ensureLoaded()`, `refresh()` (force),
`user`/`roles` computeds. Cleared by a module-scoped `watch(accessToken, …)` on `useAuth`'s ref — safe,
because `useAuth.ts` imports nothing from these modules, so no import cycle.

Invalidation after a profile edit: the page calls `refresh()` (one `/auth/me`). Rejected: patching the cache
from the PATCH response — `/profile`'s resource shape and `/auth/me`'s envelope would drift into two sources
of truth.

Skipping this breaks three things: (a) SPA client-side routing re-mounts `NavBar` per navigation, so identity +
the existing bare `onMounted` org fetch (`NavBar.vue:46-54`) fire on EVERY route change, failing the
"one page load, one `/auth/me`" criterion; (b) after a successful rename the shell shows the OLD name until a
hard reload, which reads as a failed save; (c) `/profile` and the shell can disagree on screen simultaneously.

### D7 — Shell surface: new `SidebarFooter`, not `NavBar`

`SidebarFooter.vue` is already vendored and unused (`app/components/ui/sidebar/`), and `SidebarNav.vue` ends
after `SidebarContent` (`:29-30`). Identity goes there, using the SAME `SidebarMenuButton as-child` +
`NuxtLink` pattern as the nav items (`:20-24`).

Rationale: `NavBar` already carries a truncating ORGANIZATION string (`:12-18`) plus Help plus Logout in one
56px row; a second truncating string beside it makes "who" and "where" compete in the surface operators
already misread. The usual counter — the sidebar becomes a mobile sheet — **does not apply here**:
`01.browser-gate.global.ts` redirects small viewports to `/unsupported` before auth, so an authenticated user
always has an expanded desktop sidebar. Logout stays in `NavBar`.

Initials derived by a pure, unit-tested `app/utils/initials.ts`:

| Input | Output | Rule |
|---|---|---|
| `"Ada Lovelace"` | `AL` | first + LAST token, not first two |
| `"Ada Byron King Lovelace"` | `AL` | first + last |
| `"Ada"` | `A` | single token → one letter |
| `"  Ada   Lovelace  "` | `AL` | trim, split on `/\s+/` |
| `"李雷"` | `李` | no Latin assumption; take the first grapheme as-is |
| `""` / whitespace-only | `?` | never render an empty circle |

Uses `Array.from(token)[0]`, never `token[0]` — indexing splits a surrogate pair and emits a replacement
glyph. `toLocaleUpperCase()`, not `toUpperCase()`.

Exposure: `<NuxtLink to="/profile">` wrapping `<Avatar><AvatarFallback>{{ initials }}</AvatarFallback></Avatar>`
plus the visible name. The avatar is `aria-hidden="true"` (initials are decorative duplication of the adjacent
name); the link's accessible name comes from `:aria-label="$t('nav.profileLabel', { name })"`, so the
E2E locator is a role+name query, never a CSS selector (AGENTS.md).

### D8 — `/profile` page

`app/pages/profile.vue`, default layout, `PageHeader` + `Separator`-divided stacked sections — **not** Tabs.
`settings/index.vue:25` uses Tabs for four heterogeneous destinations; two short forms stacked is less
machinery for the same job.

| Element | Treatment |
|---|---|
| Avatar (lg) + name + email | Read-only header block |
| Role | `AccessLevelBadge :role="roles[0] ?? 'viewer'"` — read-only; editable role is admin-only, by design |
| Organization name | Read-only |
| `name`, `email`, `locale` | Editable, `ProfileDetailsForm.vue` (`locale` = `Select` over `['it','en']`, validated server-side with `Rule::in(config('app.supported_locales'))`) |
| `current_password`, `password`, `password_confirmation` | `ProfilePasswordForm.vue` |

**Two separate `<form>` organisms**, not one — a details save must not require the password, and each file then
owns its own `novalidate` + `FieldError` import + `applyServerFieldErrors(...)` call, satisfying
`tests/unit/arch/form-contract.spec.ts` R1/R2/R3 independently. **No allowlist entry is added to that spec** —
the guard going green with an unchanged allowlist is the acceptance signal.

Autocomplete: `ProfileDetailsForm` keeps `autocomplete="off"` (the ratified rule, and `UserForm.vue:9,29`'s
precedent — the fields arrive pre-populated from the server, so autofill adds nothing). `ProfilePasswordForm`
is the second legitimate exception after `login.vue`: `current-password`, then `new-password` on both new
fields — `new-password` is what makes a password manager OFFER to generate and then SAVE the rotated
credential. It also renders one `sr-only`, `readonly`, `tabindex="-1"` input with `autocomplete="username"`
carrying the email, without which managers routinely file the new credential under no account. All three
carry a non-empty `autocomplete`, so `tests/e2e/autocomplete-hygiene.spec.ts:114-129` passes.

## Data Flow — password change

    ProfilePasswordForm ──PUT /api/profile/password──▶ throttle:6,1 ─▶ auth:api
                                                                          │
                        UpdatePasswordRequest (current_password:api) ◀────┘
                                       │ valid
                                       ▼
                        password = new (hashed cast, User.php:120-128)
                        password_changed_at = now()->startOfSecond()
                                       │
                        $guard->logout()   ← denylists the ACTING jti (same
                                       │      mechanism as AuthController:118)
                        $guard->login($user) → fresh iat >= password_changed_at
                                       │
                        200 {access_token} ─▶ useAuth().setSession(token)

    Any OTHER live token ─▶ auth:api ─▶ RejectStaleCredentials
                                          iat < password_changed_at
                                          └─▶ 401 {"error":"credentials_changed"}
                                              └─▶ useApi clears session → /login

Multi-tenancy: every route sits behind `TenantContext`, and the subject is `$request->user()` — no query in
this change takes an id from the request, so there is no scope to get wrong. `RejectStaleCredentials` reads
the already-resolved user (no extra query).

## File Changes

| File | Action | Description |
|---|---|---|
| `api/database/migrations/2026_08_14_000001_add_password_changed_at_to_users_table.php` | Create | Nullable `timestampTz`, mirrors `…_add_deactivated_at_to_users_table.php` |
| `api/app/Http/Middleware/RejectStaleCredentials.php` | Create | `iat < password_changed_at` → 401 `credentials_changed` |
| `api/app/Http/Controllers/Api/ProfileController.php` | Create | `show` / `update` / `updatePassword` |
| `api/app/Http/Requests/UpdateProfileRequest.php` | Create | `name`, `email` (unique-ignoring-self), `locale` |
| `api/app/Http/Requests/UpdatePasswordRequest.php` | Create | D4 rules |
| `api/app/Http/Resources/Admin/ProfileResource.php` | Create | `id, name, email, locale, role, organization` |
| `api/routes/api.php` | Modify | New block after `:96`; `throttle:6,1` on the password route |
| `api/bootstrap/app.php` | Modify | `appendToGroup('api', RejectStaleCredentials::class)` after `TenantContext` |
| `api/app/Models/User.php` | Modify | `password_changed_at` cast + docblock invariant |
| `api/app/Http/Controllers/Auth/AuthController.php` | Modify | `me()` returns `locale` (ratified) |
| `api/openapi.json` | Modify | 3 paths + `/auth/me` `locale`; then `bun run codegen` in `backoffice/` |
| `backoffice/app/composables/useCurrentUser.ts` | Modify | Module-scoped state, single-flight, `refresh()` |
| `backoffice/app/composables/useProfile.ts` | Create | Typed wrapper, `useOrganization.ts` shape |
| `backoffice/app/composables/useApi.ts` | Modify | `isCredentialsChanged()` before `isUnauthorized()` |
| `backoffice/app/utils/initials.ts` | Create | D7 table |
| `backoffice/app/components/organisms/SidebarNav.vue` | Modify | `SidebarFooter` identity link |
| `backoffice/app/components/organisms/ProfileDetailsForm.vue` | Create | Form-contract compliant |
| `backoffice/app/components/organisms/ProfilePasswordForm.vue` | Create | Form-contract compliant + token swap |
| `backoffice/app/pages/profile.vue` | Create | `/profile` |
| `backoffice/i18n/locales/{it,en}.json` | Modify | `profile.*`, `nav.profileLabel` |
| `api/app/Policies/UserPolicy.php` | **Unchanged** | Admin-only invariant preserved — asserted by test |

## Testing Strategy (strict TDD — RED first, API before frontend)

| Claim to prove | Layer | Test |
|---|---|---|
| The allow-list holds | Pest Feature | `PATCH /api/profile` with `role`, `organization_id`, `is_superadmin`, `deactivated_at` in the body → 200, and `$user->fresh()` shows all four unchanged (`hasRole('admin')` false) while `name`/`email`/`locale` did change |
| Other sessions actually die | Pest Feature | Mint tokens A and B for one user; change the password with A; B on `GET /api/auth/me` → 401 `credentials_changed`; B on `POST /api/auth/refresh` → 401 too (proves `iat` preservation closes the refresh escape) |
| The acting session survives | Pest Feature | Same test: the `access_token` from A's response → 200 on `GET /api/auth/me`; A's ORIGINAL string → 401 |
| An operator still cannot touch another user | Pest Feature | Operator `PATCH /api/users/{other}` → 403 (unchanged); operator `PATCH /api/profile` leaves the other user's row byte-identical |
| No IDOR can be introduced later | Pest Arch | Assert no route whose URI starts `api/profile` declares any parameter |
| Wrong current password | Pest Feature | 422 keyed on `current_password`; 7th attempt → 429 |
| One page load, one `/auth/me` | Vitest | `useCurrentUser.spec.ts` (the file's FIRST tests): two calls → one fetch; concurrent calls share one promise; `refresh()` forces a second; clearing the token clears the cache |
| Initials edge cases | Vitest | `initials.spec.ts` — every row of the D7 table, including the surrogate-pair case |
| 422 lands on the field | Vitest | Each form: `current_password` / `email` 422 → `aria-invalid` + `aria-describedby` on the control; unmapped message → banner |
| Forms are contract-compliant | Vitest arch | `form-contract.spec.ts` green with an UNCHANGED allowlist |
| The flow works end to end | Playwright | ONE new `profile.spec.ts` (mocked API, `getByRole` locators) + one case appended to `autocomplete-hygiene.spec.ts`. `--workers=1` on this machine, so new E2E files are serial wall-clock — hence one file, not four |

**Order of work**: (1) RED API — allow-list, password, revocation, throttle; (2) GREEN API — migration,
middleware, controller, requests, routes, `openapi.json` + `codegen`; (3) RED `useCurrentUser` + `initials`;
(4) GREEN composable + util; (5) RED/GREEN the two forms and `/profile`; (6) RED/GREEN shell identity;
(7) E2E last.

## Migration / Rollout

One additive, nullable column. Existing rows get `NULL`, which the middleware treats as "never changed" — every
live token stays valid across deploy. Rollback drops the column, the middleware, the routes, the controller and
the two FormRequests; **not code-only, contrary to the proposal's rollback plan.**

## Open Questions

- [ ] Should `password_changed_at` also be set by the ADMIN path (`UserController::update` with a `password`),
      so an admin-forced reset kicks the target's sessions? Out of scope here, but the column makes it a
      one-line follow-up.
- [ ] `throttle:6,1` is the repo's first rate limiter; confirm the limits belong here rather than in
      `nfr-hardening`.
