# Delta: interview-frontend — error redirect

## ADDED Requirements

### Requirement: Failed interviews return the candidate to the calling system

When the interview reaches `error` or `terminal` and the project has a non-empty
`error_redirect_url`, the frontend MUST redirect the browser there.

This closes the gap this spec already records as open, and it matters more than
the success redirect it mirrors. On completion the candidate is finished; on
failure they are stranded on a BEAI screen, on a domain they have no account on,
belonging to a company they have no relationship with. The calling system is the
only party that can tell them whether the interview will be re-issued, who to
contact, or whether their application is affected — BEAI can answer none of
those and must not imply otherwise.

The redirect MUST NOT append an error code, reason or any query parameter. The
binding doc places the query-string format out of scope; inventing one would be
a contract nobody agreed to and no caller reads.

When `error_redirect_url` is null or empty the existing inline screen MUST be
shown unchanged, including its retry affordance. This requirement adds a route
out; it never removes the one that already exists.

#### Scenario: A configured project redirects on error

- GIVEN a project with a non-empty `error_redirect_url`
- WHEN the interview reaches the `error` state
- THEN the browser is redirected to that URL

#### Scenario: The terminal state redirects identically

- GIVEN the same project
- WHEN the interview reaches `terminal` for any reason
- THEN the browser is redirected to the same URL

The candidate's need is identical in both: they cannot continue and they need to
get back to whoever sent them. Splitting the destinations would ask the operator
to configure a distinction their candidates cannot perceive.

#### Scenario: An unconfigured project keeps the inline screen

- GIVEN a project whose `error_redirect_url` is null
- WHEN the interview reaches `error`
- THEN the existing inline error screen is rendered, with its retry button

#### Scenario: The redirect carries no diagnostic payload

- WHEN the redirect fires
- THEN the target URL is used verbatim, with no appended query string
