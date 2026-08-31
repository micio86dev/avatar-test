# User exit (post-assessment)

## Purpose

At the end of the interview (or on a handled early exit), redirect the candidate back to the **originating system** with identity confirmation.

## Conceptual flow

1. The candidate completes (or abandons, per the UX rules) the interview;
2. BEAI shows an optional closing / thank-you screen;
3. Automatic redirect to the **return URL** configured for the project or the tenant;
4. Optional: a return token carrying the candidate identifier (the same concept as at ingress).

## Configuration

| Parameter | Description |
|-----------|-------------|
| Destination URL | A landing page on the calling portal (e.g. "Assessment completed") |
| Optional parameters | Candidate identifier, session status, project |

## Expected behaviour

- The return URL is **configurable per project** (not a single global one);
- The candidate must not have to log in again on the portal if the session is still valid;
- The evaluation is **not** synchronous with the redirect: the candidate may be back on the portal before the results are ready;
- The results arrive through the **evaluation webhook** (see `03-webhook-events.md`).

## Special cases

| Case | Suggested behaviour |
|------|-------------------------|
| Evaluation `pending` | Normal redirect; the portal explains that results are partial or a retry is possible |
| Technical error during the interview | Redirect to a configurable error page |
| Ingress token expired mid-session | Graceful handling (save progress where possible) |

## Narrative example

> Mario finishes the interview at 15:42. BEAI redirects him to `https://hr.acme.com/assessment/done?ref=acme-672`. The portal shows "Thank you, you will receive your results shortly". At 15:45 the evaluation webhook arrives.

## Out of scope

- The exact query string or fragment format;
- The route name on the calling portal.
