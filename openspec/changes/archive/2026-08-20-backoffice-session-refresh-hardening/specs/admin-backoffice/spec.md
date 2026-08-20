# Delta for Admin Backoffice

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

(Previously: mandated "Bearer JWT storage" without specifying the storage
medium — the implementation used `sessionStorage`, wiped on tab close. This
delta replaces it with memory-only storage plus cookie-backed continuity via
an awaited boot-time refresh.)

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

## ADDED Requirements

### Requirement: WebKit SameSite=None Verification Gate

The cross-site behavior of the refresh cookie (`SameSite=None; Secure`)
MUST be verified empirically — never assumed — in BOTH the Chromium and
WebKit Playwright projects, via a test that stores and re-sends the
production `Set-Cookie` string across a genuinely cross-site request. This
is an ACCEPTANCE CRITERION that MUST fail CI if WebKit rejects the cookie;
it MUST NOT be treated as an assumption to note and move past.

#### Scenario: The cookie is stored and resent in Chromium

- GIVEN the production `Set-Cookie` string is delivered across a cross-site
  request
- WHEN the Chromium Playwright project runs the verification test
- THEN the cookie is confirmed stored and resent on the follow-up request

#### Scenario: The cookie is stored and resent in WebKit

- GIVEN the same cross-site setup
- WHEN the WebKit Playwright project runs the verification test
- THEN the cookie is confirmed stored and resent — if WebKit rejects it,
  this test FAILS CI

#### Scenario: A WebKit failure blocks the change, it is not silently accepted

- GIVEN the WebKit verification test fails
- WHEN CI evaluates the pipeline
- THEN the change is blocked from merging until resolved (e.g. a local
  HTTPS fallback), never merged with a known-broken WebKit cookie story
