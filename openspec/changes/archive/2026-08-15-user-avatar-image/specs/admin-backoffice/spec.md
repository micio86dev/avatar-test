# Delta for Admin Backoffice

## MODIFIED Requirements

### Requirement: Signed-In Identity In The Shell

`SidebarNav.vue` MUST gain a `SidebarFooter` rendering the signed-in user's
avatar and name, built from the vendored `ui/avatar/` primitives, linked to
`/profile`. This replaces the literal `BEAI` header as the shell's only
identity element, and is the shell's ONLY identity element overall — this
fixes the prior lack of any user identity in the shell (`NavBar.vue` shows
only the organization name, `HelpSheet`, and Logout, and stays exactly that;
it does NOT also render identity).

`NavBar.vue` is deliberately left untouched (design D7): it already carries
a truncating ORGANIZATION string plus Help plus Logout in one 56px row, and
a second truncating identity string there would make "who" (identity) and
"where" (organization) compete in a surface operators already misread. The
usual counter — that the sidebar collapses to a mobile sheet, so an
always-visible NavBar identity would be needed as a fallback — does not
apply here: `01.browser-gate.global.ts` redirects small viewports to
`/unsupported` before auth, so an authenticated user always has an expanded
desktop sidebar, and `SidebarFooter` is never hidden from them.

The avatar renders the user's uploaded photo when `profile_photo_path` is
present, resolved through a presigned URL; it renders INITIALS via
`AvatarFallback` when no photo is set, and MUST also fall back to initials
if the photo URL fails to load. This uses the already-vendored `ui/avatar/`
primitives (`Avatar`, `AvatarImage`, `AvatarFallback`).

(Previously: avatar rendered INITIALS only, via `AvatarFallback`; uploaded
avatar images were named as an explicit, out-of-scope follow-up.)

#### Scenario: A user with no avatar image shows initials

- GIVEN a signed-in user named "Ada Lovelace" with no avatar image
- WHEN the shell renders
- THEN the avatar shows the initials "AL" via `AvatarFallback`

#### Scenario: A user with an uploaded photo shows it in the shell

- GIVEN a signed-in user with a stored `profile_photo_path`
- WHEN the shell renders
- THEN the avatar shows the uploaded photo, resolved through a presigned URL

#### Scenario: A failed photo load falls back to initials in the shell

- GIVEN a signed-in user with a `profile_photo_path` whose resolved URL
  fails to load
- WHEN the shell renders
- THEN the avatar falls back to initials via `AvatarFallback`, not a broken
  image

#### Scenario: Clicking the identity opens the profile page

- GIVEN the shell identity element is rendered
- WHEN the operator clicks it
- THEN the app navigates to `/profile`

### Requirement: Profile Page

`/profile` MUST render the signed-in user's name, email, and role (via the
existing `AccessLevelBadge`, read-only), an account form (`name`/`email`/
`locale`) backed by `PATCH /api/profile`, a separate password-change form
backed by `PUT /api/profile/password`, and a photo management control
(upload/replace/remove) backed by the dedicated photo upload/removal
endpoints — never by `PATCH /api/profile`. The role MUST be visible but MUST
NOT be editable from this page under any circumstance — role changes remain
exclusively an admin action on `user-management`. Removing a photo MUST go
through `ConfirmDialog`, consistent with the "Consequence-Driven
Confirmation On State-Changing Actions" requirement.

(Previously: rendered name/email/role, the account form, and the
password-change form; had no photo management control since uploaded
avatar images did not exist as a capability.)

#### Scenario: Role is visible but never editable

- GIVEN the profile page is rendered
- WHEN the role badge is inspected
- THEN it displays the caller's role
- AND no control on the page can change it

#### Scenario: Account and password forms submit independently

- GIVEN both forms are rendered
- WHEN the operator submits the account form
- THEN only `PATCH /api/profile` is called, never `PUT /api/profile/password`

#### Scenario: Photo upload does not go through the account form

- GIVEN the profile page's photo control
- WHEN the operator uploads a new photo
- THEN a request is sent to the dedicated photo upload endpoint, never
  `PATCH /api/profile`

#### Scenario: Removing a photo requires confirmation

- GIVEN a user with an existing photo, viewing `/profile`
- WHEN they trigger the remove-photo action
- THEN `ConfirmDialog` appears before the removal request is sent
