# Delta for Identity & Authentication

## ADDED Requirements

### Requirement: Out-of-Session Password Reset Invalidates Prior Sessions

When `password-recovery`'s reset command changes a user's password outside
any authenticated session, the system MUST set `password_changed_at` on the
same write, so every previously issued token for that user is rejected on
its next authenticated request via `RejectStaleCredentials` — exactly as it
already does for the in-session and admin-`PATCH` paths.

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
