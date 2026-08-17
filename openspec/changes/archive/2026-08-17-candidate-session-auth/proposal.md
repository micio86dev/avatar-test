# Proposal: Candidate Session Authentication and Resume

## Intent

The candidate interview journey has **never run against the real API**. Measured, not inferred:

| Probe | Result |
|---|---|
| `POST {api}/api/candidate/interview/start`, no token | **401** |
| `GET {frontend}/interview/anything-at-all` | **200** — the page renders for any string; nothing validates the route param |
| `Authorization` anywhere in `frontend/app` | **no match** — the frontend never attaches a bearer token |
| `GET /api/sso/exchange` called from `frontend/app` | **never** — there is no exchange step anywhere |
| `useInterviewSession(options)` | `{ competencies, getPendingIntegrityEvents, onIntegrityEventsFlushed }` — the token does not enter it |

The comment at `frontend/app/pages/interview/[token].vue:245` — *"useInterviewSession reads it
internally"* — is **false**. The composable never calls `useRoute()` at all; grep it. Correcting
that comment is in scope, because a false comment is why nobody looked.

So the operator entry link that just shipped (`openspec/changes/operator-interview-link/`) hands
a candidate a URL to a page that cannot do anything.

**Second casualty, same root cause.** `useExitRedirect.fetchSession()` calls
`GET /api/candidate/session` with no credential (`frontend/app/composables/useExitRedirect.ts:57`),
receives 401, catches it, and logs a warning. Its `catch` is explicitly documented as *"non-fatal:
a fetch failure degrades to the inline screens"* — so it degrades silently, always. **The C10 exit
redirect and the C15 error redirect are therefore also dead in production.** This change is what
makes them fire for the first time.

`frontend/tests/e2e/interview-flow.spec.ts` intercepts all five candidate endpoints via
`page.route()`. The suite proves the UI works against a fake and has never exercised
authentication. Same defect class as the S3 disk fixed earlier in this project: a green suite over
a path that cannot run.

## The central design argument

The requirement is **pause, resume, and survive an accidental tab close**. The requested mechanism
was a **reusable entry link**. The requirement is granted; the mechanism is refused, and this is
the change's central decision.

- A reusable entry link is a bearer credential living in a URL — in a chat message, an address
  bar, a browser history, whatever forwarded it. Anyone who intercepts it replays it for its whole
  lifetime, unauthenticated, against a deliberately public endpoint.
- **A single-use link plus a persisted 120-minute candidate session produces the identical
  behaviour** with a far smaller attack surface: the candidate closes the tab, reopens the app, the
  stored session resumes.
- And **resume already exists server-side**. `POST /api/candidate/interview/start` is documented as
  *"create or resume a provider session for the next competency"* and carries a full `RESUME
  in_corso` path with graceful degradation when prompt composition fails
  (`api/app/Http/Controllers/Candidate/InterviewController.php:60-118`). `Participant` has an
  `in_corso` status; `interview_sessions` persists `question_index` under a unique
  `(participant_id, competency_code)`.

Nothing about resume is being built. It is being **reached** for the first time.

## Scope

### In Scope

| # | Deliverable |
|---|---|
| 1 | Entry route that exchanges the sso-link token **exactly once** and `replace`-redirects to a token-free session route (D1) |
| 2 | Candidate-session composable: persist / read / clear the candidate JWT, expose expiry (D2) |
| 3 | Every candidate API call (all five interview endpoints, `/candidate/session`, and the `sendBeacon` flush) carries `Authorization: Bearer` (D3) |
| 4 | Resume on entry: stored valid session → skip the exchange entirely and resume via `/start` (D1, D4) |
| 5 | Honest failure screens for spent link, refused gate, and expired session — no silent failure (D5) |
| 6 | `401` becomes a distinct non-retryable state in the session machine; today it falls into retryable `error` and retries forever (D5) |
| 7 | Correct the false comment at `[token].vue:245`; `it` + `en` locale keys for every new screen |
| 8 | Tests that exercise the **genuine** chain — mint → exchange → authenticated call — plus a guard that no candidate request leaves without the header (D6) |

### Out of Scope

- **A reusable entry link.** See the central argument.
- **Changing the 120-minute candidate TTL.** Decided, with reasons, in D6 — deliberately not changed.
- **Backend changes of any kind.** The exchange, the mint, the guard, the resume path and
  `/candidate/session` all already do exactly what is needed. If a backend change appears necessary
  during design, that is a signal to re-read this proposal, not to widen it.
- **Self-serve re-entry after the candidate JWT expires.** Open question 1 — a different security
  posture, recorded not decided.
- **Persisting consent / device-check state across a reload.** Open question 2.

## Approach

### D1 — Exchange on a dedicated entry route, then redirect. This is the sharpest hazard.

**The sso-link is single-use and the exchange consumes its `jti` BEFORE evaluating the gates**
(`participant-sso/spec.md` step 3; `SsoExchangeController.php:44`). A page that re-exchanges on
every mount **burns the link on the candidate's first refresh** — and a refresh is exactly what
somebody does when a page looks stuck. Naming this is not enough; the route shape must make it
impossible.

`/interview/{token}` becomes an **entry route that renders nothing durable**:

1. Read the stored candidate session. If one exists, is unexpired, and its `candidate_ref` +
   `project_id` claims match the sso-link's, **skip the exchange entirely** — the link stays
   unspent. (Reading unverified claims client-side is safe here: the decision is only *"may I reuse
   what I already have"*; the server re-validates everything on the next call.)
2. Otherwise `GET /api/sso/exchange?token=…` — once.
3. Persist the returned `access_token`, then `navigateTo(sessionRoute, { replace: true })`.

`replace: true` is load-bearing: it removes the token URL from the history entry, so neither Back
nor a refresh can land on it again. The session route carries **no token in its URL**, so refresh,
Back, and restore-tab are all safe by construction rather than by a flag someone must remember to
check. Secondary benefit: the sso-link stops living in the address bar and browser history.

### D2 — Where the candidate JWT lives: `localStorage`. Position, with the asymmetry that decides it.

`backoffice/app/composables/useAuth.ts:5-11` documents its choice: sessionStorage, because it
*"survives a page reload without persisting across tab close/browser restart"*, and because *"the
real XSS mitigation is the existing CSP/security headers … not the storage mechanism itself — an
accepted risk (D11)"*.

That reasoning has two halves. **The first half transfers; the second half inverts.**

- *Transfers*: XSS reads `localStorage` and `sessionStorage` identically — same origin, same JS.
  Storage choice is not an XSS control in either app. The real controls are the CSP/security
  headers already set in `frontend/nuxt.config.ts` and never using `v-html`.
- *Inverts*: sessionStorage's value in the backoffice is that a lost token costs an **operator a
  re-login**. A candidate cannot re-login. There is no candidate account. Their entry link is
  single-use and spent, and even an unspent replacement link is **refused** — the exchange
  pre-flight read returns a generic 403 for any status other than `in_attesa`, and a paused
  candidate is `in_corso`. For the candidate, ephemeral storage is not a modest inconvenience; it
  is **terminal, unrecoverable lockout, in the exact scenario the requirement names**.

So: `localStorage`, with the persistence window bounded by the interview's lifecycle rather than by
the browser's:

- Cleared on `done`, on `terminal`, on any `401`, and before the exit redirect fires.
- Purged on read when the stored `exp` has passed, so an abandoned session self-cleans on next load.
- The residual risk, stated plainly: an abandoned interview leaves a bearer token on disk for up to
  its remaining TTL (≤120 min), on a device the organisation does not control, with **no
  revocation mechanism** for candidate tokens. Accepted — bounded, and smaller than a lockout the
  product has no support channel to answer (`interview-frontend` spec: BEAI is not the candidate's
  support channel).

A sessionStorage + localStorage mirror was considered and rejected: identical XSS surface, more code.

### D3 — One place attaches the header

`apiUrl()` already exists as the single URL builder precisely because eight hand-built template
strings drifted. The header gets the same treatment: **one** authenticated fetch wrapper, used by
every candidate call. The `pagehide` `sendBeacon` flush is included and is the trap —
`navigator.sendBeacon` **cannot set headers**, so that call needs its own answer (design phase),
and today it is silently 401-ing every integrity batch at the end of every session.

### D4 — Resume is triggered by the existing `/start`, not by new state

Reaching the session route with a stored token: render the connecting/loading state, call `/start`,
and let the backend decide. `RESUME in_corso` reissues a fresh provider session, tears down the
stale one, and returns the persisted `question_index`. The frontend's job is to **stop guessing**
and show a determinate loading state while it asks — never a blank screen, which is what a
candidate sees today.

### D5 — Honest failure paths

Today all of these produce a silently failing page. The mapping:

| Condition | Screen |
|---|---|
| Spent link, no stored session (`401` from exchange) | Terminal, **no retry** — retry cannot succeed |
| Gate or status refusal (`403` from exchange) | Terminal, **generic** message — the API returns a deliberately generic body; the frontend MUST NOT invent a specific reason |
| Stored session expired (`401` from any candidate call) | Terminal, distinct "session expired" copy |
| Provider / `502` / network | Unchanged — existing retryable `error` |

All terminal paths route through `error_redirect_url` when configured, reusing the C15 mechanism
already built in `useExitRedirect.redirectToError()` — which, per the Intent, has never once fired.

**`interview/error.vue` must not be reused for these.** Its retry calls `router.back()`
(`error.vue:38`), which returns to the spent entry URL and re-exchanges into another 401.
`interview/terminal.vue` is the correct surface; by spec contract it carries no retry control.

### D6 — The 120-minute TTL stays. Decided, not skipped.

`CandidateTokenFactory::mintCandidateToken` calls `setTTL(120)`, deliberately overriding the
30-minute global default, with a comment explaining itself
(`CandidateTokenFactory.php:85-109`). Changing it is a decision, not a tweak. **Keep it**, because:

- A candidate token **cannot be revoked**. Extending its life extends an unrevokable bearer
  credential on an uncontrolled device. That trades a bounded, visible problem (a long pause
  outlives the session) for an unbounded, invisible one.
- The correct answer for a long pause is a **re-entry mechanism**, not a longer bearer token.
  Extending the TTL is the shortcut that looks like the fix and is not; it would also quietly
  reduce the pressure to answer open question 1 properly.
- We have **no data** on real interview wall-clock duration, and `paused` is client-side only with
  no server-side tracking — there is nothing to measure against. Changing a security parameter by
  guess is the wrong order of operations.

Cost of changing it later, recorded so the next person does not re-derive it: one constant, plus
the whole revocation question this change deliberately does not open.

### D7 — Testing the genuine chain, because nothing ever did

This change exists because a green suite covered a path that could not run. The tests are therefore
part of the argument, not an afterthought:

1. **Backend integration (Pest)** — mint an sso-link, `GET /api/sso/exchange`, take the returned
   `access_token`, and call `GET /api/candidate/session` with `Authorization: Bearer`. Asserts the
   real chain end to end with no provider involved. This is the test whose absence this whole
   change is downstream of.
2. **E2E with the exchange NOT mocked** — the entry route performs a real exchange; assert the
   candidate lands on the session route and that the **first `/start` request carries an
   `Authorization` header**. Provider-side mocking may stay; the header assertion is the point.
3. **Guard test** — no candidate request may be issued without the header, in the style of the
   repo's existing `CandidateCannotReadProctoringArchTest.php`.
4. **Refresh-does-not-burn-the-link** — exchange once, reload, assert exactly **one** exchange
   request was made and the session survived. This is D1's hazard, asserted.

## Capabilities

### New Capabilities

None. The single-use, `jti`-consume and entry-gate invariants must stay in one document; a second
spec would be a second place for them to drift.

### Modified Capabilities

- `interview-frontend`: entry/exchange route and its single-exchange guarantee, candidate-session
  persistence and its storage decision, authenticated candidate calls, resume trigger, the new
  `401` state and the three terminal failure paths.

**`participant-sso` is NOT modified.** No backend change is required — the exchange, mint, guard,
`/candidate/session` and the resume path already provide everything. Stated explicitly so that a
backend edit appearing in design or apply is treated as a scope breach.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `frontend/app/pages/interview/[token].vue` | Modified | Becomes the entry route; false comment at `:245` corrected |
| `frontend/app/pages/interview/` (session route) | New | Token-free route the candidate actually sits on |
| `frontend/app/composables/useCandidateSession.ts` | New | Store / read / clear / expiry |
| `frontend/app/composables/useInterviewSession.ts` | Modified | Auth header; `401` state; resume entry |
| `frontend/app/composables/useExitRedirect.ts` | Modified | Auth header — starts working for the first time |
| `frontend/app/composables/useIntegrityFlush.ts`, `useProctor.ts` | Modified | Auth on flush; `sendBeacon` header problem |
| `frontend/app/utils/api-url.ts` (or sibling) | Modified/New | Single authenticated fetch wrapper |
| `frontend/app/pages/interview/terminal.vue` | Modified | New failure copy variants |
| `frontend/i18n/locales/{it,en}.json` | Modified | Both mandatory; no bare literals |
| `frontend/tests/e2e/interview-flow.spec.ts` | Modified | Stop mocking the exchange |
| `api/tests/Feature/...` | New | Genuine mint → exchange → authenticated call |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| A re-exchange on refresh burns the link and locks the candidate out | **High** | D1 — exchange only on the entry route, `replace`-redirect to a token-free URL, stored-session check *before* the exchange, plus a dedicated refresh test |
| Candidate JWT on disk, unrevokable, on an uncontrolled device | **High** | D2 — lifecycle-bounded clearing + purge-on-expiry; residual risk accepted and stated |
| A paused candidate outlives 120 min and is stranded with no self-serve route | **High** | Honest expired-session terminal + `error_redirect_url`; the durable fix is open question 1, deliberately not guessed at |
| `sendBeacon` cannot carry an `Authorization` header — end-of-session integrity keeps 401-ing | **High** | Named here as a design-phase deliverable, not discovered in apply |
| Shared/kiosk device leaves a token for the next candidate | Med | Cleared on every terminal state; purged on expiry at next load |
| E2E stays fake-green because the exchange is convenient to mock | Med | D7.2 and D7.4 forbid mocking the exchange; D7.1 has no browser at all |
| Two tabs resume the same interview | Low | Backend already governs: unique `(participant_id, competency_code)`, and `RESUME in_corso` tears down the prior provider session |

## Rollback Plan

Frontend-only and cleanly separable — **no backend change, no migration, no data**.

Reverting the entry-route commit restores today's behaviour exactly: a page that renders and cannot
authenticate. Nothing downstream depends on the new route, because nothing downstream works today.
The exchange endpoint, the mint, the guard and the resume path are untouched by any revert here.

If only the storage decision is at fault, the persistence composable reverts independently of the
route split; the entry route still exchanges once and still redirects.

## Dependencies

- `operator-interview-link` merged, so an operator can actually mint a link to test with.
- `FRONTEND_URL` set per environment (introduced by that change) — a wrong value produces an entry
  URL that 404s before any of this is reached.
- Tests run as `./vendor/bin/pest <exact-file>` or full runs — **never**
  `php artisan test --filter`, observed fabricating passes in this repo. Playwright `--workers=1`.

## Success Criteria

- [ ] A candidate opens a minted link and reaches a live interview against the **real** API.
- [ ] `POST /api/candidate/interview/start` from the browser carries `Authorization: Bearer` and does not 401.
- [ ] Refreshing the interview page does **not** re-exchange and does **not** burn the link — asserted by test.
- [ ] Closing the tab and reopening the app resumes the interview at the persisted `question_index`.
- [ ] A spent link with no stored session shows a terminal screen with no retry control — never a silent failure.
- [ ] A `403` from the exchange shows a **generic** message; the frontend discloses no gate detail.
- [ ] An expired candidate JWT shows a distinct expired-session terminal, and redirects when `error_redirect_url` is configured.
- [ ] The exit redirect (C10) and error redirect (C15) fire for the first time.
- [ ] At least one test exercises mint → exchange → authenticated call with nothing mocked.
- [ ] `[token].vue:245` no longer claims the composable reads the token internally.
- [ ] `it` and `en` complete; no bare literals.

## Proposal question round

Not asked interactively (delegated execution). **Recorded for the spec phase — NOT decided here.**

1. **Should a candidate who returns after their token has expired be able to self-serve a new
   entry?** Today they cannot, and it is not an oversight: a new sso-link would be **refused** by
   the exchange pre-flight read, because their status is `in_corso` and only `in_attesa` proceeds.
   Making it possible requires a durable per-participant secret that survives token expiry — a
   different security posture, not a smaller version of this one, and it would change what "single
   use" means. This proposal's answer is an honest terminal screen. Confirm that, or open it as its
   own change.

2. **Should proctoring consent and the device-check result survive a reload?** They do not today —
   both are in-memory only (`useInterviewSession.acceptConsent()` transitions state; the
   `localStorage` in `ConsentBanner.vue` is the *analytics* cookie banner, explicitly stood down on
   interview routes). So a resuming candidate re-consents and re-checks devices every time. Two
   readings, and they conflict: re-consenting is friction on the exact flow this change exists to
   smooth, **or** re-consenting is correct because consent to being recorded should be given at the
   start of each sitting. That is a product/compliance call, not a technical one, and it should be
   made by whoever owns the consent language.

### Assumptions this proposal makes, open to correction

- The candidate device is untrusted but not hostile — the threat is interception and shared
  devices, not a candidate attacking their own assessment.
- A candidate's pause is minutes-to-an-hour, not overnight. If overnight pauses are a real product
  expectation, D6 (TTL) and open question 1 both change, and this proposal should be revisited
  before the spec phase rather than patched after it.
