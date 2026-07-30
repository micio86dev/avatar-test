# Delta: interview-frontend — Root Landing

## ADDED Requirements

### Requirement: Root route is an informational dead end

`GET /` MUST render a static, localized orientation screen. It MUST NOT return
404.

The screen MUST tell the visitor exactly one thing: that access to an interview
happens through the link they were sent. That is the whole content, because it
is the only true and actionable statement BEAI can make to somebody standing at
the root — the platform does not know who they are, cannot look them up, and
holds no contact data for them.

The page MUST NOT contain:

- any `<input>`, `<form>`, or `<button>` that submits
- any link or affordance suggesting login, sign-up, or "request access"
- any support contact (email, phone, chat)

These prohibitions are requirements, not guidance. BEAI has no candidate
account, enrolment belongs to the calling system, and BEAI is not the
candidate's support channel — a support address here would route confused people
to the wrong party and imply BEAI can identify them. The absence is asserted by
test, because an absence nobody tests is an absence nobody maintains.

The page MUST make no API call and hold no reactive state.

#### Scenario: A visitor reaches the root

- WHEN `GET /` is requested with a supported desktop browser
- THEN HTTP 200 is returned
- AND the rendered document contains the orientation message
- AND the document contains no form control and no login or sign-up affordance

#### Scenario: The root is not indexed

- WHEN `GET /` is rendered
- THEN the document declares `<meta name="robots" content="noindex, nofollow">`

Consistent with every other candidate-facing route: nothing in this application
should appear in a search result, and a page inviting orientation is exactly the
one a search engine would otherwise surface to the wrong audience.

#### Scenario: The root is localized

- GIVEN the active locale is `it`
- WHEN `GET /` is rendered
- THEN the orientation message is the Italian copy
- AND GIVEN the active locale is `en`, the English copy is rendered instead

#### Scenario: The root has a non-empty document title

- WHEN `GET /` is rendered
- THEN `<title>` is non-empty

WCAG 2.4.2 (Page Titled), the same obligation `/unsupported` already carries.

#### Scenario: The root passes the accessibility gate

- WHEN `GET /` is rendered
- THEN an `axe` scan reports no WCAG 2.1 Level AA violation

#### Scenario: An unsupported browser never sees the root

- GIVEN a Firefox user agent, or a viewport narrower than 1024px
- WHEN `GET /` is requested
- THEN the visitor is redirected to `/unsupported`

The existing global browser gate already produces this: it skips only paths
ending in `/unsupported`, so the root is gated like any other route. Asserted
here so a future change to the gate's skip list cannot silently expose the root
to a device the product does not support — and because telling a phone user to
switch device is more actionable than orientation copy they cannot use yet.
