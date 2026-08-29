# Delta for Admin Backoffice

> **Modification to**: `openspec/specs/admin-backoffice/spec.md`.
> Written after the implementation shipped (see the process note in the
> `password-recovery` delta).

## MODIFIED Requirements

### Requirement: Authenticated Session

The system MUST provide a login page, an access token held in MEMORY ONLY
(never `sessionStorage` or `localStorage`), a `$fetch` interceptor attaching
the in-memory token, and a route guard redirecting unauthenticated users to
login. Session continuity across a page reload or new tab MUST come from an
AWAITED silent refresh — a `POST /api/auth/refresh` call with credentials
and the required CSRF header — performed by a boot-time plugin BEFORE the
route guard middleware evaluates authentication state, so a reload never
renders `/login` for an operator whose refresh cookie is still valid. If the
boot-time refresh fails (401, network error), the plugin MUST swallow the
failure, leave the session empty, and resolve normally — it MUST NOT throw
and MUST NOT redirect during boot.

The guard MUST decide public access by the route's **first path segment**, skipping an
`@nuxtjs/i18n` locale prefix, matched against an explicit set of pre-auth roots:
`unsupported`, `login`, `health`, `forgot-password`, `reset-password`. A suffix match over the
full path MUST NOT be used: the emailed reset link carries its token as a **path segment**, so
`/reset-password/{token}` ends with the token and never with the route name — a locked-out
user clicking their own link would be bounced to `/login`, making the recovery flow
unreachable by the only people who need it. The first-segment predicate is also strictly
tighter than a suffix match, which would have made a hypothetical `/projects/login` public.

(Previously: mandated "Bearer JWT storage" without specifying the storage
medium — the implementation used `sessionStorage`, wiped on tab close. This
delta replaces it with memory-only storage plus cookie-backed continuity via
an awaited boot-time refresh.)
(Previously, as of this change: the public-route predicate was a `to.path.endsWith(...)` match
over a three-entry list, which no token-bearing path could ever satisfy.)

#### Scenario: Unauthenticated user is redirected to login

- GIVEN no valid refresh cookie and no in-memory access token
- WHEN the user navigates to any protected route
- THEN they are redirected to the login page

#### Scenario: Expired in-memory token triggers refresh, not logout

- GIVEN the in-memory access token has expired but the refresh cookie is
  valid
- WHEN a protected request is made
- THEN the session is silently refreshed and the request retried
- AND the user is not redirected to login

#### Scenario: A page reload never flashes the login page for a valid session

- GIVEN a valid refresh cookie survives a tab close/reopen or full reload
- WHEN the app boots
- THEN the boot plugin's awaited refresh completes before the route guard
  evaluates
- AND the operator lands on the requested protected route, never a flash of
  `/login`

#### Scenario: A failed boot-time refresh degrades to logged-out, not a crash

- GIVEN the refresh cookie is absent, expired, or revoked
- WHEN the boot plugin's refresh call returns 401
- THEN the plugin resolves without throwing
- AND the app proceeds to redirect via the route guard, exactly as the "no
  valid session" scenario

#### Scenario: No access token is ever written to browser storage

- GIVEN any point in the session lifecycle — login, refresh, or boot
- WHEN `sessionStorage` and `localStorage` are inspected
- THEN neither contains an access token or any session credential

#### Scenario: A token-bearing reset link is reachable without a session

- GIVEN no session at all
- WHEN the visitor opens `/reset-password/{token}` or its locale-prefixed form
- THEN the guard permits it and does not redirect to `/login`

#### Scenario: The widened predicate exposes no authenticated route

- GIVEN a protected path whose LAST segment happens to be a public root name
- WHEN the guard evaluates it without a session
- THEN it is still redirected to `/login`

## ADDED Requirements

### Requirement: The Recovery Pages Never Undo The API's Anti-Enumeration Contract

`/forgot-password` MUST render an outcome that is identical for a real address, an unknown
address, and a deactivated account: it MUST NOT name the submitted address, MUST NOT claim an
inbox was reached, and MUST be phrased conditionally. A "check your inbox" confirmation would
rebuild in the UI the oracle the API refuses to be. There MUST be no client-side
"does this address exist" probe on this page.

The success copy MUST be the application's own localized string, not the API's `202` body,
which is English-only by design because it has no recipient to localize for.

`/login` MUST offer a locale-aware link into the flow, so an operator who cannot sign in has a
way out of the form.

#### Scenario: Every address produces the same rendered outcome

- GIVEN any address is submitted
- WHEN the request succeeds
- THEN one identical, non-committal message is shown, naming no address and asserting no delivery

#### Scenario: The recovery entry point exists on the sign-in page

- WHEN the login page is rendered
- THEN it links to `/forgot-password` through the locale-aware path helper

### Requirement: Both Recovery Pages Distinguish A Rate-Limit Refusal From A Failure

A `429` from either reset endpoint MUST surface its own copy, distinct from the generic error
message. The route limit is low enough that a user who mistypes twice will meet it, and a
generic failure there reads as a broken product rather than "wait a minute".

A server `422` naming a field the page renders MUST land on that field; a `422` naming a field
the page renders **no** control for — the generic token refusal — MUST NOT be silently
dropped, and MUST surface at form level with a way to request a new link.

#### Scenario: A throttled request explains itself

- GIVEN the endpoint answers `429`
- WHEN the response is handled on either recovery page
- THEN the rate-limit copy is shown, not the generic error copy

#### Scenario: The generic token refusal reaches the operator

- GIVEN the confirm endpoint answers `422` keyed on `token`
- WHEN the reset page handles it
- THEN the message is shown at form level AND a link to request a new link is offered

### Requirement: The Reset Page Reads The Emailed Link Shape And Discards The Token After Use

The reset page MUST accept the link shape the API actually mints:
`{origin}/reset-password/{token}?email={urlencoded address}` — token in a **path segment**,
address as a query parameter. It MUST match both `/reset-password` and
`/reset-password/{token}`, so a link truncated by a mail client reaches an explanation and a
way to request a new one, not a `404` and not a form that could never succeed.

The prefilled address MUST be **visible and editable**: visible so the operator can see which
account the link resets, editable so a mail client that mangles the query parameter does not
turn a valid token into a dead end.

On success the page MUST present a terminal state with no submit control — the token has just
been spent and a control that can only fail is a control that lies — and MUST **clear the
token out of the address bar**, so it does not survive in browser history or a screen share.

The page MUST mirror the API's minimum password length client-side, so a typo does not spend
the single-use token.

#### Scenario: The emailed link opens prefilled without a session

- GIVEN the full emailed link
- WHEN it is opened with no session
- THEN the form renders with the address prefilled from the query parameter

#### Scenario: The submission carries the token from the path

- WHEN the form is submitted
- THEN the request body carries the token taken from the path segment and the address from the form field

#### Scenario: A truncated link explains itself

- GIVEN `/reset-password` with no token
- WHEN the page renders
- THEN an invalid-link explanation and a request-a-new-link action are shown, with no submittable form

#### Scenario: The spent token leaves the address bar

- GIVEN a successful reset
- WHEN the success state renders
- THEN the URL no longer contains the token or the query string
- AND the success state is not replaced by the invalid-link state as a result

#### Scenario: A mismatched confirmation is caught before the token is spent

- GIVEN a password that does not match its confirmation
- WHEN the form is submitted
- THEN no request is sent and the token remains usable
