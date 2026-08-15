# Proposal: User Profile Self-Service

## Intent

A signed-in backoffice user cannot see who they are and cannot change anything about themselves.
`NavBar.vue` shows the ORGANIZATION name, a help sheet and Logout — no identity at all (`:16-37`);
`SidebarNav.vue` header is the literal `BEAI` (`:14`), with no `SidebarFooter`. There is no
profile/account/me route. Worse, the API blocks self-service by design: the only user write is
admin-scoped `PATCH /api/users/{user}`, gated by `UserPolicy` (`:33-36` — `hasRole('admin')`, no
self branch), so an operator or viewer cannot change their own name, email or password by ANY
route, and no password-change flow exists anywhere (zero `password` routes in `api/routes/api.php`).

## Scope

### In Scope
- Self-resolving profile API: read + update `name`, `email` for the authenticated user.
- Password change API requiring the CURRENT password.
- Backoffice `/profile` page: identity, role badge, account form, password form.
- Shell identity: avatar + name in `NavBar`/`SidebarNav`, linked to `/profile`.
- Avatar = INITIALS via the already-vendored, currently unused `ui/avatar/` primitives.
- Promote `useCurrentUser` to module-scoped shared state + its first tests.

### Out of Scope
- Uploaded avatar images (new column, storage disk, upload endpoint, MIME/size validation,
  deletion path — real greenfield; deliberate follow-up, not silently built here).
- Email-change verification, forgot/reset password, MFA, self-deactivation.
- Any relaxation of admin user management; `nfr-hardening` files.

## Capabilities

### New Capabilities
- `user-self-service`: authenticated user reads/updates own profile and changes own password.

### Modified Capabilities
- `user-management`: state the boundary — this surface STAYS admin-only on every verb; self-service
  is a separate route/policy path, never a self-branch inside `UserPolicy`.
- `admin-backoffice`: shell MUST render the signed-in user's identity linked to a profile page.
- `identity-auth`: `/auth/me` payload and post-password-change session semantics (pending O1/O2).

## Approach

Follow the `organization-settings` precedent exactly: a SINGULAR self-resolving resource with no id
in the path (`GET|PATCH /api/profile`, `PUT /api/profile/password`), org and subject resolved from
the token. `User::$fillable` already permits `name|email|password|locale`; the blocker is purely
route+policy. Password change gets its own request with a `current_password` rule — the admin
`UpdateUserRequest` (no current-password check) MUST NOT be reused. Frontend consumes shared
`useCurrentUser`; `AccessLevelBadge` already renders `roles` from `/auth/me`.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `api/routes/api.php` | Modified | 3 self-scoped routes under `auth:api` + `TenantContext` |
| `api/app/Http/Controllers/` | New | `ProfileController` (show/update/updatePassword) |
| `api/app/Http/Requests/` | New | `UpdateProfileRequest`, `UpdatePasswordRequest` |
| `api/app/Policies/UserPolicy.php` | Unchanged | Admin-only invariant preserved |
| `backoffice/app/pages/profile.vue` | New | Account + password forms |
| `backoffice/app/components/organisms/NavBar.vue` | Modified | Identity trigger → `/profile` |
| `backoffice/app/components/organisms/SidebarNav.vue` | Modified | Footer identity |
| `backoffice/app/composables/useCurrentUser.ts` | Modified | Module-scoped state + tests |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Privilege escalation via self-service body (`role`, `organization_id`, `is_superadmin`, `deactivated_at`) | High | Allow-list `name`/`email` only; assert exclusions in tests |
| IDOR from a self endpoint that accepts an id | Med | No id in path, ever; subject from token |
| Weakening the admin path | Med | Separate controller/request; `UserPolicy` untouched |
| Password changed without proving identity | High | Mandatory `current_password`; never reuse `UpdateUserRequest` |
| Duplicate auth-gated fetches per page load (`NavBar` org fetch + `fetchMe`) | High | Shared `useCurrentUser` state is a PREREQUISITE, not a nicety |
| `useCurrentUser` has zero tests today | High | Tests land before it gains consumers |
| Delivering less than "il mio avatar" implied | Med | Initials now, image upload recorded with its cost |

## Rollback Plan

Frontend and backend are independently revertable. Removing the `/profile` page and the NavBar/
SidebarNav identity block restores today's shell. Dropping the three routes + `ProfileController` +
the two FormRequests removes the whole write surface, but this is **not code-only**: a migration adds
the nullable `users.password_changed_at` column (design D3), and rollback must also drop that column
(and the `RejectStaleCredentials` middleware registration). `useCurrentUser` caching is the one change
worth keeping either way.

## Dependencies

- None external. API work is a hard prerequisite: NO frontend account/password form is possible
  until `GET|PATCH /api/profile` and `PUT /api/profile/password` exist.

## Open Questions (for sdd-spec — do NOT decide here)

- **O1**: Does a password change invalidate the user's OTHER active sessions? The jti denylist
  already exists (logout uses it), so this is a real product/security decision.
- **O2**: Is `locale` editable on the profile (column + `$fillable` allow it; `/auth/me` simply does
  not return it today), or does it stay a UI-only preference?

## Success Criteria

- [ ] Signed-in user sees their initials avatar + name in the shell on every backoffice page.
- [ ] Clicking it opens `/profile`, showing name, email and role badge.
- [ ] An `operator` and a `viewer` can change their own name, email and password — a capability
      that does not exist today by any route.
- [ ] A wrong `current_password` rejects the change with 422.
- [ ] A self-service request carrying `role`, `organization_id`, `is_superadmin` or
      `deactivated_at` changes none of them; admin-only user management still returns 403 to
      non-admins on every verb.
- [ ] `useCurrentUser` is shared state with tests; one page load triggers one `/auth/me`.

## Proposal question round

Could not ask interactively (sub-agent). These need user review before spec:
1. Initials-only avatar accepted for this slice, or is image upload required now (new column,
   storage disk, upload endpoint, validation, deletion path)?
2. Should email changes take effect immediately, or is verification required later?
3. O1 — must a password change log out the user's other devices?
4. O2 — is language/locale part of "i miei dati account" or a separate preference?
