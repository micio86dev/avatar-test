# Delta: participant-sso — operator-minted entry link

## ADDED Requirements

### Requirement: Shared Entry Link Minting Logic

The entry-gate evaluation, `role_code` inheritance/validation, and terminal-status
(`completato`/`errore`) mint refusal MUST be implemented in exactly one place,
consumed by both the M2M mint (`POST /api/m2m/sso-link`) and the operator mint
(below). Two independent implementations of the mint decision are a defect class,
not a stylistic preference: one of them decides whether a candidate can start.

The M2M endpoint's request contract, response contract, and observable behavior
MUST remain byte-identical after this extraction.

#### Scenario: M2M mint response is unchanged after the extraction

- GIVEN a valid M2M mint request that succeeded before this change
- WHEN `POST /api/m2m/sso-link` is called with the same input after the extraction
- THEN the response body, status code, and headers are byte-identical to before

#### Scenario: A gate refusal reason is consistent across both mints

- GIVEN a project that fails the same entry gate (inactive, before goes_live_at,
  past deadline_at, terminal participant status, or role_code mismatch)
- WHEN either the M2M mint or the operator mint is called for that project
- THEN both refuse minting for the same underlying reason

### Requirement: Operator-Facing Entry Link Mint Endpoint

`POST /api/entry-links` MUST mint a candidate entry token for an authenticated
backoffice operator, on the `auth:api` guard plus `TenantContext`. It MUST accept
`project_id`, `candidate_ref`, `display_name`, and optional `role_code` and `lang`,
mirroring the M2M mint's body.

Minting an entry link starts an assessment for a candidate; it is not a read
operation. Authorization MUST be `ParticipantPolicy::create`: `admin` and
`operator` MAY mint; `viewer` MUST be denied.

`project_id` MUST be resolved scoped to the caller's tenant (via `TenantContext`),
consistent with the M2M mint's own-organization scoping.

#### Scenario: Admin mints an entry link

- GIVEN an authenticated user with the `admin` role
- WHEN `POST /api/entry-links` is called with a valid project and candidate
- THEN HTTP 201 is returned with a redeemable entry link

#### Scenario: Operator mints an entry link

- GIVEN an authenticated user with the `operator` role
- WHEN `POST /api/entry-links` is called with a valid project and candidate
- THEN HTTP 201 is returned with a redeemable entry link

#### Scenario: Viewer is denied — minting is not a read

- GIVEN an authenticated user with the `viewer` role
- WHEN `POST /api/entry-links` is called
- THEN HTTP 403 is returned
- AND no token is minted

#### Scenario: Cross-tenant project is not found

- GIVEN an authenticated operator whose tenant does not own `project_id`
- WHEN `POST /api/entry-links` is called with that `project_id`
- THEN HTTP 404 is returned, matching the M2M mint's cross-org behavior
- AND no token is minted

#### Scenario: A project that cannot accept a candidate refuses the mint

- GIVEN a project that is not `active`, or is before `goes_live_at`, or past
  `deadline_at`
- WHEN `POST /api/entry-links` is called for that project
- THEN HTTP 403 is returned
- AND no token is minted

### Requirement: Entry Link Response Composes the Absolute URL

The response to a successful operator mint MUST contain `entry_url` (an absolute
URL) and `expires_at`. It MUST NOT contain the bare token as a separate field: a
raw token in an operator-facing payload is a second copyable artifact that can
land in the wrong place.

#### Scenario: Response carries a composed URL, not a bare token

- GIVEN a successful `POST /api/entry-links` call
- WHEN the response body is inspected
- THEN it contains `entry_url` and `expires_at`
- AND it contains no separate bare-token field

### Requirement: Entry URL Locale Prefixing Is Owned by the Minter

The entry URL's locale prefix MUST be derived from the same `lang` resolution
chain the mint already uses to stamp the token (`$validated['lang'] ??
$project->language ?? fallback`), computed once, inside the minter. A caller of
`POST /api/entry-links` MUST NOT be required to re-derive this chain to know
which URL shape is correct.

For the resolved language `it` (the frontend's default locale, `strategy:
prefix_except_default`), the path MUST be `/interview/{token}`. For any other
resolved language (e.g. `en`), the path MUST be `/{lang}/interview/{token}`.

#### Scenario: Resolved language it omits the locale prefix

- GIVEN a mint request whose resolved language is `it`
- WHEN the entry link is composed
- THEN `entry_url` ends in `/interview/{token}` with no locale segment

#### Scenario: Resolved language en carries the locale prefix

- GIVEN a mint request whose resolved language is `en`
- WHEN the entry link is composed
- THEN `entry_url` ends in `/en/interview/{token}`

#### Scenario: lang omitted falls back to the project's language

- GIVEN a mint request with no `lang` field, for a project with `language = "en"`
- WHEN the entry link is composed
- THEN the resolved language is `en` and the URL is prefixed accordingly

### Requirement: CANDIDATE_APP_URL Fails Loud When Unset

The entry link's origin MUST come from a dedicated configuration value
(`config('interview.candidate_app_url')`, sourced from `CANDIDATE_APP_URL`). When this
value is unset or empty, minting an operator entry link MUST fail loudly (an
error, never a 201 with a malformed link). The origin MUST NOT fall back to
`config('app.url')` under any circumstance — that value is the API's own origin,
and a link composed from it resolves against the wrong application.

#### Scenario: Unset CANDIDATE_APP_URL fails the mint, not silently

- GIVEN `CANDIDATE_APP_URL` is unset
- WHEN `POST /api/entry-links` is called with an otherwise valid request
- THEN the request fails with an explicit configuration error
- AND no `entry_url` is composed from `config('app.url')`

#### Scenario: A configured CANDIDATE_APP_URL is used verbatim as the origin

- GIVEN `CANDIDATE_APP_URL` is set to `https://interview.example.com`
- WHEN `POST /api/entry-links` succeeds
- THEN `entry_url` begins with `https://interview.example.com`

### Requirement: No Revocation Semantics

Minting a new entry link for a participant MUST NOT invalidate any previously
minted, unexpired entry link for that same participant. There is no mechanism
that consumes a jti before its own exchange or expiry; each minted link remains
independently valid until it is either exchanged once or its 30-minute TTL
elapses.

#### Scenario: A superseded link remains valid until its own expiry

- GIVEN an entry link minted for a participant, not yet exchanged or expired
- WHEN a new entry link is minted for the same participant
- THEN the previous link's token can still be exchanged successfully until its
  own `expires_at`, unless it is exchanged first
