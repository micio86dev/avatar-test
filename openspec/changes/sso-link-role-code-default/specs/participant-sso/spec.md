# Delta: participant-sso — sso-link inherits the project role

## ADDED Requirements

### Requirement: An omitted role_code is filled from the project at mint

When `POST /api/m2m/sso-link` is called for a **standard** project without
`role_code`, the minted token MUST carry the project's `role_code`.

Until now the mint accepted the omission and the exchange refused the result:
the exchange requires the claim to equal the project's role, and `null` never
does. The API returned 201 with a credential it would later refuse.

That failure is terminal rather than merely confusing. The exchange consumes the
token's `jti` BEFORE evaluating the gates — deliberate replay protection, which
this change does not touch — so a refused link is also a spent one. Retrying the
same URL cannot succeed, and the calling system has already recorded a success.

**A 201 from the mint MUST mean the token in that response is redeemable**, for
every reason the mint is able to check.

The default applies ONLY when the field is absent. A supplied `role_code` is
still validated against the project and still rejected with 422 on mismatch: a
caller who states a role is asserting something, and silently overwriting that
assertion would hide the integration bug the 422 exists to reveal.

Potential projects are unchanged: any supplied `role_code` remains a 422, and it
is never silently nulled.

#### Scenario: Omitted role_code is inherited for a standard project

- GIVEN a standard project with `role_code = "ICO"`
- WHEN `POST /api/m2m/sso-link` is called without `role_code`
- THEN HTTP 201 is returned
- AND the minted token carries `role_code = "ICO"`

#### Scenario: The inherited token is redeemable

- GIVEN a token minted without an explicit `role_code` for a standard project
- WHEN it is presented to `GET /api/sso/exchange`
- THEN the exchange succeeds
- AND does not fail the role_code belt check

#### Scenario: A supplied role_code is still asserted, not replaced

- GIVEN a standard project with `role_code = "ICO"`
- WHEN the mint request supplies `role_code = "BUL"`
- THEN HTTP 422 is returned
- AND no token is minted

#### Scenario: Potential projects are untouched

- GIVEN a potential project
- WHEN the mint request omits `role_code`
- THEN HTTP 201 is returned
- AND the minted token carries a null `role_code`

#### Scenario: The exchange keeps its exact check

- GIVEN a token whose `role_code` claim no longer matches the project's
- WHEN it is presented to the exchange
- THEN HTTP 403 with a generic body is returned

The exchange is NOT relaxed to accept a null claim. It still catches a token
minted before a project's role changed, which remains possible while the project
is draft.
