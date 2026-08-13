# Design: SSO Link Inherits the Project Role

## D1 — Default at MINT, not at exchange

Both sides could be made to agree by relaxing the exchange to treat a null
claim as "no opinion". That is the wrong end.

The token is the artifact that outlives the request. A token carrying an
explicit `role_code` states what was agreed when it was issued, and the exchange
comparing it to the project's current value is a real check — it catches a
project whose role changed between mint and redemption, which is possible while
the project is still draft. Relaxing the exchange would delete that check to
paper over the mint.

Defaulting at mint keeps both properties: every token carries an explicit role,
and the exchange keeps comparing it to something.

## D2 — Only for standard projects

Potential projects have no project-level role, and supplying one is already a
422 that surfaces an integration bug. Nothing to default, nothing to change.

## D3 — An explicitly supplied role_code still wins, and is still validated

The default applies only when the field is absent. A supplied value continues to
be checked against the project and rejected with 422 on mismatch.

A caller who states a role is asserting something; silently replacing that
assertion with the project's value would hide the integration bug the existing
422 exists to reveal.

## D4 — The response gains nothing

No new field, no echo of the resolved role. The token already carries it, and
adding a second copy to the response body invites a caller to trust the copy
rather than the credential.
