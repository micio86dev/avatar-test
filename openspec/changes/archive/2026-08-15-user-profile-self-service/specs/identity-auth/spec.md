# Delta for Identity & Authentication

## MODIFIED Requirements

### Requirement: Me Endpoint

**Scenario: Retrieve authenticated user info**
- Given a valid access token
- When GET /api/auth/me
- Then the response is 200 OK
- And response includes user object with id, name, email, locale, organization_id, roles

**Scenario: Me endpoint with denylisted token**
- Given a denylisted access token
- When GET /api/auth/me
- Then the response is 401 Unauthorized

**Scenario: locale is included and reflects the stored preference**
- Given a user with `locale = "it"`
- When GET /api/auth/me
- Then the response's `user.locale` equals `"it"`

(Previously: the `user` object did not include `locale` — the column and
`$fillable` entry existed, but `/auth/me` simply never returned it.)

## ADDED Requirements

### Requirement: Password Change Rejects Prior Sessions, Replaces The Acting Token

When `user-self-service`'s password-change endpoint succeeds, the system
MUST reject every other previously issued token for that user on its next
authenticated request. This is enforced by comparing each token's `iat`
claim against the user's recorded password-change timestamp — not by
enumerating and denylisting individual `jti`s, since there is no per-user
token registry to enumerate (see design D3).

The token that authenticated the password-change request is NOT exempt from
this: it is explicitly denylisted (the same logout mechanism `POST
/auth/logout` already uses) as part of completing the change. What survives
is the SESSION, not that token string — the response body carries a
brand-new `access_token`, minted with a fresh `iat` no earlier than the
change, which the caller MUST adopt. A client that keeps presenting the
original token after this response is rejected exactly like any other stale
token.

#### Scenario: Prior tokens are rejected on password change

- GIVEN a user holds tokens X (older session) and Y (used to change the
  password)
- WHEN the password change succeeds
- THEN token X is rejected `401` on its next use

#### Scenario: The response replaces the acting token, which is then rejected

- GIVEN token Y performed the password change
- WHEN the response is inspected
- THEN it carries a new `access_token`, distinct from Y, that is accepted on
  its next use
- AND the ORIGINAL token Y is rejected on any request made after this
  response
