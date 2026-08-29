# Delta for Identity Auth

> **Modification to**: `openspec/specs/identity-auth/spec.md`.
> Written after the implementation shipped (see the process note in the
> `password-recovery` delta): this records the contract the shipped code and its
> tests already hold, not a forward-looking design.

## MODIFIED Requirements

### Requirement: Out-of-Session Password Reset Invalidates Prior Sessions

When a user's password is changed **outside any authenticated session** — by
`password-recovery`'s operator command **or** by the self-service HTTP reset flow — the system
MUST do **both** of the following, atomically with the password write:

1. Set `password_changed_at` on the same write, using second precision
   (`now()->startOfSecond()`), so every previously issued **access** token for that user is
   rejected on its next authenticated request via `RejectStaleCredentials` — exactly as it
   already does for the in-session and admin-`PATCH` paths.
2. Revoke **every refresh-token family the user holds**, user-scoped rather than family-scoped.

The second half is not belt and braces. `POST /api/auth/refresh` runs **outside**
`RejectStaleCredentials` deliberately and load-bearingly — an expired access token is exactly
when refresh must still work — so `password_changed_at` is **never consulted on the refresh
path**, and a stolen refresh cookie would otherwise survive the reset and keep minting fresh
access tokens. Family-scoped revocation is insufficient: an out-of-session reset has no
session and therefore no `fam` claim to scope by, and a user holds one family **per login**, so
a two-device operator holds two families.

Revocation MUST NOT re-stamp an already-revoked row, which would move the recorded revocation
time forward and misdate the incident in the very row that records it.

The fix MUST NOT be achieved by placing `RejectStaleCredentials` on `/api/auth/refresh`: that
re-breaks the session-refresh behaviour that exemption exists to protect.

(Previously: `password_changed_at` alone, set only by the reset command — which provably did
not cover `/api/auth/refresh`, the one endpoint where a surviving credential still mints new
ones.)

#### Scenario: A token minted before the reset is rejected afterward

- GIVEN a user holds an access token issued before the reset
- WHEN an operator resets that user's password via the command
- THEN the token is rejected `401` on its next use, regardless of its
  remaining TTL

#### Scenario: The second-precision comparison window is honored

- GIVEN `password_changed_at` is stored via `->startOfSecond()` and compared
  with a strict `<` against the token's `iat`
- WHEN a token is minted in the same second as the reset
- THEN its acceptance follows the existing `iat < password_changed_at`
  rule — not a new one introduced by this command

#### Scenario: Every refresh family the user holds is revoked, not just one

- GIVEN a user holds two refresh families, one per device, from two separate logins
- WHEN a self-service reset completes
- THEN rotating **either** family's refresh token is refused as revoked

#### Scenario: A stolen refresh cookie cannot mint a fresh access token after a reset

- GIVEN a refresh cookie captured before the reset
- WHEN `POST /api/auth/refresh` is called with it after the reset completes
- THEN the response is `401`

#### Scenario: The self-service and command paths produce the same outcome

- GIVEN the same two-family fixture
- WHEN the password is reset once through the HTTP flow and once through the artisan command
- THEN both revoke every family and both stamp `password_changed_at` at second precision

#### Scenario: A rolled-back reset logs nobody out

- GIVEN the password write fails partway
- WHEN the transaction rolls back
- THEN `password_changed_at` is unchanged AND no refresh family is revoked

## ADDED Requirements

### Requirement: The Auth Surface Gains Exactly Two Public, Throttled Reset Routes

`POST /api/auth/forgot-password` and `POST /api/auth/reset-password` MUST be **public** — the
caller cannot log in, which is the entire reason the routes exist — and MUST each carry an
inline route throttle. A `401` on either would make recovery unreachable for exactly the
person it is for.

Adding these two routes MUST NOT change the middleware, throttling, or timing of `login`,
`refresh`, `logout`, or `me`. Throttling the rest of the `/api/auth` prefix is a separate
change with its own verification: `refresh` in particular is called on every cold load of the
backoffice, so a limit added there is a session-hardening decision, not a side effect of
password recovery.

#### Scenario: Both routes work with no session and no token

- GIVEN a caller with no access token and no refresh cookie
- WHEN either route is called with a valid payload
- THEN the request is processed, never answered `401`

#### Scenario: The rest of the auth surface is untouched

- WHEN the auth route definitions are inspected after this change
- THEN `login`, `refresh`, `logout`, and `me` carry the same middleware and throttling as before
