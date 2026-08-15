# Delta for User Management

## ADDED Requirements

### Requirement: Admin-Initiated Password Write Invalidates The Target's Sessions

The system MUST set the target user's password-change timestamp
(`password_changed_at`) whenever an admin sets or replaces that user's
password, on both `PATCH /api/users/{id}` (`UserController::update`) and, for
consistency, `POST /api/users` (`UserController::store`) at creation. This is
the same field `identity-auth`'s stale-credential rejection mechanism reads;
setting it on the admin write path is what makes that existing mechanism
apply here — it is not a separate implementation.

At `store()`, the created user has no prior tokens to reject. Setting the
timestamp there is about the field's meaning staying consistent (every user
has a `password_changed_at` reflecting their current password), not a
security control, since there is nothing yet to invalidate.

#### Scenario: Admin password reset on update() retires the target's prior token

- GIVEN target user U holds token X, issued before an admin resets U's password via `PATCH /api/users/{U}`
- WHEN the admin submits a new password for U and the request succeeds
- THEN U's `password_changed_at` is updated to the time of the reset
- AND token X is rejected `401` on its next use, per `identity-auth`'s stale-credential mechanism

#### Scenario: A newly created user's password_changed_at is set with nothing to invalidate

- GIVEN an admin creates a new user via `POST /api/users` with an initial password
- WHEN the user is created
- THEN `password_changed_at` is set to the creation time
- AND no prior token exists for that user to reject — the field is set for consistency, not because a session is being revoked

#### Scenario: The resetting admin's own session survives the target's reset

- GIVEN an admin holds token A and resets another user's password via `PATCH /api/users/{id}`
- WHEN the reset succeeds
- THEN token A remains valid for the admin's own subsequent requests
