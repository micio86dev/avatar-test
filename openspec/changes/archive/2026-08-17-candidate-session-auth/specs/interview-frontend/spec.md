# Delta: interview-frontend — candidate session authentication and resume

## ADDED Requirements

### Requirement: Single-use entry-route exchange

The system MUST expose `/interview/{token}` as an entry route that performs the
sso-link exchange **at most once** and renders no durable UI of its own.

On mount, the entry route MUST, in order:
1. Read the stored candidate session, if any. If it exists, is unexpired, and its
   `candidate_ref` + `project_id` claims match the sso-link's own claims, the exchange
   MUST be skipped and the candidate MUST be navigated directly to the session route.
2. Otherwise call `GET /api/sso/exchange` exactly once, persist the returned candidate
   JWT, and `navigateTo` the token-free session route with `replace: true`.

The session route MUST carry no token in its URL. Refreshing the entry route after
step 2 has completed, or refreshing the session route at any point, MUST NOT trigger a
second exchange call.

`useInterviewSession` MUST NOT read the route token itself; it accepts only
`{ competencies, getPendingIntegrityEvents, onIntegrityEventsFlushed }`. No comment,
code, or documentation MAY claim it reads the token internally.

#### Scenario: First visit exchanges once and lands on a token-free URL

- GIVEN a candidate with no stored session opens a fresh, unspent `/interview/{token}` link
- WHEN the entry route mounts
- THEN exactly one `GET /api/sso/exchange` request is made, the returned JWT is
  persisted, and the browser is navigated to the session route with the sso-link
  token no longer present in the URL or browser history entry

#### Scenario: Refresh after exchange does not burn the link

- GIVEN a candidate has already exchanged and is on the token-free session route
- WHEN the candidate refreshes the page
- THEN no additional `GET /api/sso/exchange` request is made and the interview session survives

#### Scenario: A valid stored session skips the exchange entirely

- GIVEN a candidate has a stored, unexpired candidate session whose `candidate_ref`
  and `project_id` claims match a freshly opened sso-link
- WHEN the entry route mounts
- THEN no `GET /api/sso/exchange` request is made; the candidate is routed directly
  to resume (see Resume on entry)

#### Scenario: useInterviewSession does not read the route token

- WHEN the source of `useInterviewSession` is inspected
- THEN its exported factory accepts only `{ competencies, getPendingIntegrityEvents,
  onIntegrityEventsFlushed }`, and no call to `useRoute()` or a route-token read
  exists inside it
- AND no comment in `frontend/app/pages/interview/[token].vue` or in
  `useInterviewSession` claims the composable reads the token internally

---

### Requirement: Candidate session persistence

The system MUST persist the candidate JWT returned by the exchange in `localStorage`,
bounded by the interview's lifecycle rather than the browser's:
- Cleared on reaching `done`, on reaching `terminal`, on any `401` response from a
  candidate call, and immediately before an exit or error redirect fires.
- Purged on read when the token's `exp` claim has already passed — an abandoned
  session self-cleans on next load without a network round-trip.

The composable MUST expose store, read, clear, and expiry-check operations; no other
module MAY read or write the candidate token directly.

#### Scenario: Token persists across a tab close and reopen

- GIVEN a candidate has an unexpired persisted candidate session
- WHEN the tab is closed and the app is reopened at the session route
- THEN the stored token is still present and is used to resume (see Resume on entry)

#### Scenario: Token cleared on terminal

- GIVEN an active candidate session
- WHEN the session reaches `terminal` for any reason
- THEN the stored candidate token is cleared before any redirect fires

#### Scenario: Token cleared on 401

- GIVEN an active candidate session
- WHEN any candidate API call returns `401`
- THEN the stored candidate token is cleared

#### Scenario: Expired token purged on read

- GIVEN a stored candidate token whose `exp` claim is in the past
- WHEN the composable reads the stored session
- THEN the stored value is discarded and reading returns "no session", without a network call

---

### Requirement: Every candidate request is authenticated

Every request the frontend makes to a candidate-scoped endpoint — the five interview
endpoints (`/start`, `/utterance`, `/integrity`, `/snapshot`, `/end`),
`GET /api/candidate/session`, and the `pagehide` integrity flush — MUST carry
`Authorization: Bearer <candidate JWT>`. No candidate request MAY be issued without
it. A missing or expired stored session MUST prevent the call from being attempted at
all, rather than being sent unauthenticated.

Satisfying this requirement makes two already-specified behaviors reachable for the
first time: the `done`-state exit redirect and the `error`/`terminal`-state error
redirect both depend on `GET /api/candidate/session` succeeding; today that call is
unauthenticated, returns `401`, and is swallowed as non-fatal, so neither redirect has
ever fired in production.

#### Scenario: /start carries the Authorization header

- GIVEN a persisted candidate session
- WHEN the session machine calls `POST /api/candidate/interview/start`
- THEN the request carries `Authorization: Bearer <token>` and does not receive
  `401` for that reason

#### Scenario: No candidate request is ever issued without the header

- WHEN every call site that issues a candidate-scoped request is inspected
- THEN each one is routed through the single authenticated request path; none
  constructs a candidate request without attaching the header

#### Scenario: /candidate/session succeeds and the exit redirect fires

- GIVEN a persisted candidate session and a project with a non-empty `exit_redirect_url`
- WHEN the candidate reaches `done`
- THEN `GET /api/candidate/session` is called with the Authorization header,
  succeeds, and the exit redirect fires (previously unreachable — the call 401'd
  and was swallowed)

#### Scenario: Unauthenticated call never silently succeeds

- GIVEN no stored candidate session
- WHEN a candidate-scoped endpoint is called
- THEN the call is either not attempted, or attempted and the resulting `401` is
  handled by the `401` state (see Honest failure states) — the UI never treats it
  as success

---

### Requirement: pagehide integrity flush is authenticated or its failure is visible

The end-of-session `pagehide` integrity flush MUST deliver the proctoring evidence
batch to the server authenticated, or its failure MUST be surfaced rather than
silently dropped. `navigator.sendBeacon` cannot set request headers, so the
authentication mechanism for this specific call is a design-time decision; this
requirement constrains only the observable outcome.

#### Scenario: pagehide flush reaches the server

- GIVEN pending integrity events at the moment `pagehide` fires
- WHEN the flush is sent
- THEN the server records the batch against the correct candidate session — not a
  silent `401`

#### Scenario: A failed pagehide flush is not silently lost

- GIVEN the pagehide flush cannot be delivered (network failure, rejected auth)
- WHEN the failure occurs
- THEN it is observable (logged, retried, or surfaced) rather than indistinguishable
  from a successful flush

---

### Requirement: Resume on entry via /start

Reaching the session route with a valid stored candidate session MUST trigger a call
to `POST /api/candidate/interview/start` and MUST render a determinate loading state
while the response is pending — never a blank screen. The response governs whether a
session resumes at the persisted `question_index` (backend `RESUME in_corso` path) or
a new competency session is created; the frontend MUST NOT infer or guess this
outcome client-side.

#### Scenario: Reopening after a tab close resumes at the persisted competency

- GIVEN a candidate with a stored, unexpired session who paused mid-interview and
  closed the tab
- WHEN the candidate reopens the app and lands on the session route
- THEN `POST /start` is called, a loading state is shown while it is pending, and
  the interview resumes at the `question_index` the backend returns
- AND the candidate is never shown a blank screen while resuming

#### Scenario: A brand-new candidate proceeds to device check, not resume

- GIVEN a freshly exchanged candidate session with no prior competency progress
- WHEN the session route is reached
- THEN the existing consent/device-check flow governs entry as before; no
  resume-specific screen is shown

---

### Requirement: Honest failure states, including for a paused candidate who cannot be rescued

The system MUST map failure conditions to distinct, honest screens; no condition MAY
produce a silently broken page.

| Condition | Screen |
|---|---|
| Spent link, no stored session (`401` from exchange) | Terminal, no retry — retry cannot succeed |
| Gate or status refusal (`403` from exchange) | Terminal, generic message — no gate detail disclosed |
| Stored session expired (`401` from any candidate call) | Terminal, distinct "session expired" copy |
| Provider / `502` / network | Unchanged — existing retryable `error` |

`401` MUST be a distinct, non-retryable state in the session machine; it MUST NOT
fall into the retryable `error` state and MUST NOT retry indefinitely.

**A newly minted replacement link does NOT rescue a paused candidate.** The
exchange's pre-flight read only proceeds when the participant's status is
`in_attesa`; a paused candidate's status is `in_corso`, so any new, valid, unspent
sso-link presented for that candidate is refused with a generic `403` at the
exchange, identical to any other blocked status. Combined with the 120-minute
candidate JWT and no revocation mechanism, a candidate whose stored session expires
after pausing has no self-serve path back into the interview from this change. The
expired-session terminal screen MUST state this honestly and MUST NOT suggest that
requesting or receiving a new link will help.

**`error_redirect_url` routing is scoped to terminals reached AFTER a candidate JWT
exists — it is structurally impossible before one does.** `GET /api/candidate/session`
(the endpoint `error_redirect_url` is resolved from) requires an authenticated
candidate JWT (`auth:api-candidate` guard), and this proposal's backend-unchanged
constraint (see Proposal, "Out of Scope") forbids adding an unauthenticated variant
of it. Concretely:

- **CAN route through `error_redirect_url`**: terminals reached via `session.vue`'s
  state machine while a candidate JWT is (or very recently was) valid — the existing
  `403`-from-`/start`-or-`/end` path, `absent_phrase`, `malformed_response`, and a
  mid-session `session_expired` (a live `401` on an authenticated call). For all of
  these, `useExitRedirect.fetchSession()` already resolved `error_redirect_url` once,
  authenticated, at page mount — the redirect uses that already-cached value; it does
  not need a new authenticated call at the moment of failure.
- **CANNOT route through `error_redirect_url`**, by construction, not by omission:
  - The entry route's own exchange failures — spent link (`401`) and gate/status
    refusal (`403`). No candidate JWT has ever existed for this attempt; there is
    nothing to authenticate `GET /api/candidate/session` with.
  - The `candidate-session` middleware's gate on `/interview/session` (no valid
    stored session — absent or already expired). By definition, no valid candidate
    JWT exists at this exact point either.

  Both cases show the static, honest terminal screen (`terminal.vue`, keyed by the
  `reason` query param) with no external-redirect capability. This is the correct,
  final behavior for this proposal, not a gap to close later.

#### Scenario: Spent link with no stored session shows terminal, no retry

- GIVEN a candidate opens an already-spent sso-link and has no stored candidate session
- WHEN the exchange returns `401`
- THEN the terminal screen is shown with no retry control

#### Scenario: Gate refusal discloses no detail

- GIVEN the exchange returns `403` for any gate or status reason
- WHEN the terminal screen is shown
- THEN its copy is the generic message; it does not name the specific gate or
  status that blocked it

#### Scenario: Expired stored session is distinct from a spent link

- GIVEN a stored candidate session whose token has expired
- WHEN a candidate call returns `401`
- THEN a terminal screen distinct from the spent-link terminal is shown, with
  "session expired" copy

#### Scenario: 401 does not retry indefinitely

- GIVEN any candidate call returns `401`
- WHEN the session machine processes the response
- THEN it transitions to the non-retryable `401`/terminal state, not to the
  retryable `error` state, and no automatic retry is attempted

#### Scenario: A paused candidate's fresh replacement link is refused, not honored

- GIVEN a candidate whose status is `in_corso` (paused mid-interview, stored
  session since expired)
- WHEN a newly minted, unspent sso-link is exchanged for that same candidate
- THEN the exchange returns `403` with the generic body, exactly as any other
  non-`in_attesa` status; the candidate is not re-admitted

#### Scenario: The expired-session terminal screen does not imply a new link will help

- GIVEN a candidate reaches the expired-session terminal screen, by any path
- WHEN its copy is inspected
- THEN it does not instruct the candidate to request or use a new link

#### Scenario: A mid-session expired terminal (candidate JWT existed) routes through error_redirect_url

- GIVEN a candidate's session was valid when `session.vue` mounted (so
  `useExitRedirect.fetchSession()` already resolved `error_redirect_url`, if
  configured) and the candidate JWT subsequently expires or is rejected mid-session
- WHEN the session machine reaches the `session_expired` terminal
- THEN the candidate is routed through the already-cached `error_redirect_url`
  when configured, and shown the inline expired-session screen otherwise

#### Scenario: A pre-authentication expired/spent terminal does NOT route through error_redirect_url

- GIVEN a candidate reaches `/interview/session` with no valid stored session
  (the `candidate-session` middleware gate), OR the entry route's own exchange
  returns `401` (spent link) or `403` (gate refusal)
- WHEN the terminal screen is shown
- THEN it is the static `terminal.vue` screen with no external-redirect
  capability — no `GET /api/candidate/session` call is attempted, because no
  candidate JWT exists to authenticate it with, and none MAY be attempted
  unauthenticated

---

### Requirement: Genuine authentication is exercised by tests, not mocked

At least one test MUST exercise the full genuine chain — minting an sso-link,
exchanging it for a candidate JWT, and making an authenticated candidate call —
without mocking ANY step of that chain. **This test lives in the api Pest suite**
(`MintExchangeAuthenticatedCallTest.php`), not in the frontend E2E suite — see
"Where the ownership splits" below for why, decided and recorded here rather than
left as an unstated contradiction between this spec and the frontend test files.

**Where the ownership splits.** `frontend/playwright.config.ts`'s `webServer` boots
the Nuxt app alone — no PHP, no Postgres, no Redis (a real API is a named, costed,
NOT-built-here follow-up: standing one up here means new service containers, new
migrations, a seeded org/project, an artisan mint command, and a new class of CI
flake, for a suite that currently has none). There is therefore no real `/api/sso/exchange`
endpoint for the frontend E2E suite to call unmocked; `page.route()` stubs it in
every scenario. This is not a partial implementation of this requirement — it is
the deliberate, permanent shape: **the api Pest test owns the genuine,
end-to-end, nothing-mocked chain; the frontend E2E suite owns the browser-side
half that Pest cannot reach — does the client actually attach the header, and
does a refresh re-exchange — proven via REQUEST-side assertions that a stubbed
RESPONSE does not weaken:** the exchange is called exactly once across a reload
or a stored-session revisit, and the very next candidate call carries
`Authorization: Bearer <the token the stub returned>`. The one residual seam (the
field name on the wire, `access_token`) is covered separately by
`scripts/check-client-drift.sh`.

#### Scenario: The genuine chain is exercised end to end (api Pest)

- GIVEN a minted sso-link
- WHEN it is exchanged and the returned token is used to call a candidate endpoint
- THEN the call succeeds using the real backend chain, with no endpoint in this
  chain intercepted or faked — verified in `MintExchangeAuthenticatedCallTest.php`,
  not in the frontend E2E suite

#### Scenario: The frontend E2E suite proves request-side behavior against a stubbed exchange response

- GIVEN the frontend E2E suite's `webServer` has no real backend to exchange
  against, and `GET /api/sso/exchange` is stubbed via `page.route()` in every
  scenario that needs to get past the entry route
- WHEN the entry route exchanges and the first `POST /candidate/interview/start`
  request is inspected
- THEN it carries `Authorization: Bearer <the token the stub's response
  returned>` — proving the token is genuinely propagated from the exchange
  response into the next authenticated call, not merely that the stub was
  reachable
- AND a reload or a stored-session revisit of the entry URL triggers no more
  than the expected number of exchange calls, asserted by an exchange-call
  counter that is provably sensitive to disabling the stored-session-match
  guard (a test that cannot fail on the thing it names is not kept)
