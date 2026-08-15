# Delta for Admin Backoffice

## ADDED Requirements

### Requirement: Signed-In Identity In The Shell

`SidebarNav.vue` MUST gain a `SidebarFooter` rendering the signed-in user's
initials avatar and name, built from the vendored `ui/avatar/` primitives,
linked to `/profile`. This replaces the literal `BEAI` header as the shell's
only identity element, and is the shell's ONLY identity element overall —
this fixes the prior lack of any user identity in the shell (`NavBar.vue`
shows only the organization name, `HelpSheet`, and Logout, and stays exactly
that; it does NOT also render identity).

`NavBar.vue` is deliberately left untouched (design D7): it already carries
a truncating ORGANIZATION string plus Help plus Logout in one 56px row, and
a second truncating identity string there would make "who" (identity) and
"where" (organization) compete in a surface operators already misread. The
usual counter — that the sidebar collapses to a mobile sheet, so an
always-visible NavBar identity would be needed as a fallback — does not
apply here: `01.browser-gate.global.ts` redirects small viewports to
`/unsupported` before auth, so an authenticated user always has an expanded
desktop sidebar, and `SidebarFooter` is never hidden from them.

Avatar = INITIALS only for this slice, via the already-vendored, currently
unused `ui/avatar/` primitives (`Avatar`, `AvatarFallback`). Uploaded avatar
images are an explicit follow-up, out of scope here.

#### Scenario: A user with no avatar image shows initials

- GIVEN a signed-in user named "Ada Lovelace" with no avatar image
- WHEN the shell renders
- THEN the avatar shows the initials "AL" via `AvatarFallback`

#### Scenario: Clicking the identity opens the profile page

- GIVEN the shell identity element is rendered
- WHEN the operator clicks it
- THEN the app navigates to `/profile`

### Requirement: Profile Page

`/profile` MUST render the signed-in user's name, email, and role (via the
existing `AccessLevelBadge`, read-only), an account form (`name`/`email`/
`locale`) backed by `PATCH /api/profile`, and a separate password-change
form backed by `PUT /api/profile/password`. The role MUST be visible but
MUST NOT be editable from this page under any circumstance — role changes
remain exclusively an admin action on `user-management`.

#### Scenario: Role is visible but never editable

- GIVEN the profile page is rendered
- WHEN the role badge is inspected
- THEN it displays the caller's role
- AND no control on the page can change it

#### Scenario: Account and password forms submit independently

- GIVEN both forms are rendered
- WHEN the operator submits the account form
- THEN only `PATCH /api/profile` is called, never `PUT /api/profile/password`

### Requirement: Current-User State Is Fetched Once And Shared

`useCurrentUser` MUST hold module-scoped shared state, mirroring the
`useAuth` pattern (`useAuth.ts:24-29` — state declared outside the composable
function body so every call site shares it), so `GET /auth/me` is fetched at
most once per page load regardless of how many components consume it.
`NavBar.vue`'s existing uncached organization fetch pattern MUST NOT be
repeated for identity: the new shell-identity consumer and the `/profile`
page MUST both read from this shared state rather than each issuing an
independent `/auth/me` request.

#### Scenario: Multiple consumers on one page trigger one request

- GIVEN a page renders both the shell identity (`NavBar`/`SidebarNav`) and
  another component that also needs the current user
- WHEN the page loads
- THEN exactly one `GET /auth/me` request is issued

#### Scenario: Cached state is reused across navigations within the session

- GIVEN `useCurrentUser` has already fetched the current user once
- WHEN the operator navigates to another protected route
- THEN no new `/auth/me` request is issued to re-read already-cached data
