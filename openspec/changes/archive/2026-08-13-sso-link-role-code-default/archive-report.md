# Archive report: SSO Link Inherits the Project Role

**Archived** 2026-08-13.

## Verification

| Scenario | Test |
|---|---|
| Omitted role_code inherited for a standard project | `SsoLinkMintTest` — claim equals the project role |
| The inherited token is redeemable | `SsoLinkMintTest` — mint then exchange, 200 |
| A supplied role_code is still asserted | `SsoLinkMintTest` — mismatch still 422 |
| Potential projects untouched | `SsoLinkMintTest` — null claim, 201 |
| The exchange keeps its exact check | Pre-existing `SsoExchange` tests, unchanged |

Both new tests were written first and observed RED with exactly the reported
symptom: 201 from the mint, then `403 Access denied` from the exchange.

Confirmed against the running stack afterwards, not only in the suite: minting
for the demo project without `role_code` now returns 201 and the exchange
returns 200. Yesterday the same two calls returned 201 then 403.

## What the bug actually was

Neither controller was wrong on its own. The mint required a match *if
supplied*; the exchange required equality. The specification covered a WRONG
role_code and any role_code on a potential project, and never contemplated a
standard project omitting it — so two reasonable readings of a silence produced
a credential the system would refuse.

The delta now states the invariant the silence was missing: **a 201 from the
mint means the token in that response is redeemable**, for every reason the mint
can check.

## Deliberately not changed

- **The exchange's exact check.** Relaxing it to accept a null claim would have
  closed the same hole by deleting a real guard — it still catches a role
  changed between mint and redemption, possible while a project is draft.
- **jti-before-gates.** Deliberate replay protection. It is what made this bug
  terminal rather than merely confusing, but it is not the defect; with the mint
  fixed, the case stops arising.

## Gates at archive time

- api: 1531 passed, 5 skipped. pint and phpstan clean.
