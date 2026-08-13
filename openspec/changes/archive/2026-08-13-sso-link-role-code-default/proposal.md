# Proposal: SSO Link Inherits the Project Role

## Intent

`POST /api/m2m/sso-link` returns **201 with a token that can never be redeemed**
when `role_code` is omitted for a standard project.

Found by using the API, not by reading it: minting a link for the demo project
without `role_code` succeeded, and the exchange answered `403 Access denied`.

## The two halves that disagree

| | Rule | Source |
|---|---|---|
| Mint | role_code must match **if supplied**; omitting it is fine | `SsoLinkController::validateRoleCode` |
| Exchange | role_code must **equal** the project's; `null !== 'ICO'` | `SsoExchangeController::checkRoleCode` |

Both are reasonable read alone. Together they issue a credential the system
will refuse.

The specification does not settle it: `participant-sso/spec.md` covers a WRONG
role_code at mint (422) and any role_code on a potential project (422), and
never contemplates a standard project omitting it. Two controllers filled the
silence differently.

## Why this is worse than an ordinary 403

The exchange **consumes the jti before evaluating the gates** — deliberately,
as replay protection, and that stays. So the failure is not merely confusing,
it is terminal: the link is spent, retrying the same URL cannot work, and the
calling system already recorded a success. A candidate is left on "Access
denied" with a link nobody can make work again.

## Decision

The mint **defaults `role_code` from the project** when a standard project's
request omits it.

The project already knows its role, and `role_code` freezes once a project goes
live (D9), so there is nothing for the caller to disambiguate. A 201 must mean
the token in the response is usable.

**Rejected: requiring `role_code` at mint (422 when absent).** It closes the
same hole, but `role_code` is documented and validated as nullable today, so
demanding it would break every integrator currently omitting it — and would
make them repeat a value the server holds. Fixing a broken success by turning
it into a new failure is not an improvement for the caller.

## Non-goals

- **The exchange is not relaxed.** Its check stays exact. It still catches a
  token minted before a role changed, which remains possible while a project is
  draft.
- **jti-before-gates is not touched.** Consuming the link before the gates is
  deliberate replay protection; with the mint fixed, the case that made it hurt
  stops arising.
- **Potential projects are unchanged.** Supplying any role_code there is still
  422, and it is still never silently nulled — that 422 surfaces a real
  integration bug.
