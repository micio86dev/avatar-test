# Design: Candidate Session Authentication and Resume

## Technical Approach

Three primitives, one seam each: a **storage composable** (`useCandidateSession`), a **single
authenticated transport** (`candidateFetch`), and a **route split** that separates the
link-consuming entry from the token-free session the candidate sits on. Everything else in the
proposal is a consequence of those three. No backend production code changes; one new Pest test.

The split is the load-bearing part. `frontend/app/pages/interview/[token].vue` stops being the
interview and becomes a ~120-line entry route that renders nothing durable. The interview UI moves
verbatim to a new sibling, `frontend/app/pages/interview/session.vue`.

---

## Architecture Decisions

### D-A — Route topology: keep `/interview/{token}` as the entry, add `/interview/session`

| Option | Cost |
|---|---|
| `/interview/{token}` entry → **`/interview/session`** | **Chosen.** Zero API change. |
| `/interview/{token}` entry → `/interview` (index) | Relies on Nitro's `/interview/**` matching zero segments — unverified. A wrong guess silently drops `camera=(self)` and the interview cannot start. |
| New entry route (`/interview/enter/{token}`) | Forces a lockstep edit to `EntryLinkUrlComposer.php:39-41`, `api/config/interview.php`, `EntryLinkUrlComposerTest`, and both `nuxt.config.ts` routeRules — for no security gain. |

**Rationale.** `terminal.vue` and `error.vue` already sit as static siblings of `[token].vue`;
Nuxt ranks static segments above dynamic ones, so `session.vue` is the *established* shape in this
directory, not a new one. `/interview/session` and `/en/interview/session` are unambiguously inside
the existing `Permissions-Policy` grant (`frontend/nuxt.config.ts:25-40`) — a child segment, so no
dependence on wildcard-matches-empty semantics. **`EntryLinkUrlComposer` does not move and is not
touched.** An sso-link JWT can never collide with the literal `session` (it contains dots).

### D-B — Transport: one ofetch instance behind one function

New `frontend/app/utils/candidate-api.ts` exports `candidateFetch(path, options)`: it calls
`apiUrl(path)` (unchanged, still the single URL builder) through an `ofetch.create()` instance whose
`onRequest` attaches `Authorization: Bearer` and whose `onResponseError` maps 401 → clear session +
throw `CandidateUnauthorizedError`.

| Option | What it fails to catch |
|---|---|
| **ofetch instance + `candidateFetch` wrapper** | `sendBeacon` (→ D-C) and any raw `fetch()`. Both are enumerable and migrated in the same commit. |
| Explicit header per call site | Every future call site. This is exactly how eight hand-built URLs drifted before `apiUrl()` existed. Also centralises no 401 handling, which the change also requires. |
| Bare fetch wrapper without an interceptor | Same coverage, but the 401 rule lives in the caller — six copies of one security decision. |

**Transfers from `backoffice/app/composables/useApi.ts`**: the single-wrapper shape, and
`isUnauthorized()` reading **both** `status` and `statusCode` (ofetch populates them
inconsistently — `useInterviewSession.ts:242` already compensates). **Does not transfer**: the
single-flight refresh and `navigateTo('/login')` — a candidate has no refresh endpoint and no login
page, so 401 is terminal, not recoverable; and `isAccountDeactivated()`, because the candidate 403
body is deliberately generic and the frontend MUST NOT introspect it.

**Guard.** A Vitest source-scan (precedent: `tests/unit/token-parity.spec.ts` reads source with
`readFileSync`) asserts no file under `frontend/app/` reaches a `/candidate/` URL except through
`candidate-api.ts`. This catches the raw `fetch()` at `useProctor.ts:518` — which must migrate in
the same commit or snapshots silently 401.

### D-C — `sendBeacon` → `fetch(..., { keepalive: true })`

| Option | Trade |
|---|---|
| **`fetch` + `keepalive` + header** | **Chosen.** Only option carrying a header with no backend change. Precedent already in-repo: `useProctor.ts:518-527`. |
| Token in the request body | Moves a bearer credential into a body captured by proxy/APM logs, **and** requires the API to read it — a backend change the proposal declares a scope breach. |
| Token in the query string | Token in every access log. Same backend breach. |

**Honest trade.** `keepalive` caps the total in-flight body at ~64 KiB — the same practical limit
`sendBeacon` already has (`useIntegrityFlush.ts:108` warns about exactly this), so no regression.
Both are best-effort on `pagehide`; neither guarantees delivery.

**Real behavioural change, named:** `sendBeacon` returned a synchronous boolean used to decide
whether to acknowledge events (`useInterviewSession.ts:209`). `fetch` returns a promise that will
not settle before the page dies. On the `pagehide` path we therefore **acknowledge on dispatch** —
the buffer dies with the page, and `acknowledge` exists only to prevent double-send *within a live
page*. The `!sent` warning becomes a `try/catch`.

Two call sites, and the second is the hazard: `useIntegrityFlush.flushViaBeacon()` and a hand-built
duplicate of the same payload inside `useInterviewSession.attachResizeListener()` (lines 196-213).
Extract one module-scope `flushIntegrityKeepalive(payload)` in `useIntegrityFlush.ts` and call it
from both. Patching both copies was rejected: two copies is two chances to miss the header.

### D-D — `useExitRedirect`: non-fatal stays, silent goes

A redirect that cannot resolve *is* still non-fatal — the inline screen is a correct fallback. What
was wrong is that "operator configured no URL" (supported) and "we are not authenticated" (defect)
shared one code path and one `console.warn` containing the word *non-fatal*, which is the sentence
that let this survive.

**Choice**: `fetchSession()` keeps its never-throws contract (`[token].vue:287` calls it with
`void`), gains `sessionFetchFailed: Ref<null | 'unauthenticated' | 'unavailable'>`, and logs a
message that names the consequence — `/candidate/session 401 — exit and error redirects are
unavailable for this session` — with the word *non-fatal* deleted. No retry: a candidate 401 is
unrecoverable by construction. **Surfaced**, not just logged: when the machine reaches
`terminal`/`error` with `sessionFetchFailed === 'unauthenticated'` and no URL, the terminal renders
the expired-session variant instead of no-opping.

### D-E — Resume: a synchronous gate, then the existing connecting screen

**Choice**: a client-only route middleware on `/interview/session` reads `localStorage`
**synchronously** — no network — and `replace`-redirects to `/interview/terminal?reason=session_expired`
when absent or expired. Cost: zero milliseconds, so there is no flash, no skeleton-for-a-decision,
and no optimistic render to unwind. The candidate then sees the **existing** determinate connecting
skeleton (`[token].vue:37-44`, moving to `session.vue`) while `/start` is in flight. No new loading
UI is invented.

**Malformed `/start` response.** Today `startSession` reads `response.question_context.end_phrase`
unguarded (`useInterviewSession.ts:368`); a bad body throws inside the `try`, `status` is
`undefined`, and it lands in retryable `error` — retrying forever against a server that will answer
identically. That is the same defect class as the 401 this change fixes. **Choice**: an explicit
shape guard → `terminal`, new reason `malformed_response`, mapped to the **existing**
service-unavailable copy (`interview.terminal.absent_phrase.*`). No new i18n keys; retry cannot fix
a contract violation.

### D-F — Expired-while-paused: no self-serve recovery, and the honest reason

Confirmed by reading the code, not inferred: `SsoExchangeController.php:118-126` returns a generic
403 for any status other than `in_attesa`, and a paused candidate is `in_corso`. A replacement link
is refused.

**Choice**: no recovery is invented. The frontend half is designed — a distinct expired-session
terminal that routes through `error_redirect_url` (C15), which is the only channel that reaches the
system that knows who the candidate is and can re-issue.

**Disagreement, recorded.** A genuinely *new* operator-visible signal (an alert, a webhook, a
status) is a backend change, which this proposal declares a scope breach. So the signal designed
here is the one that already exists and nobody was told to watch: **a participant stalled at
`in_corso` whose `interview_sessions.question_index` stops advancing**, visible in the backoffice
participant list. Making that an active alert is a named follow-up change, not something smuggled
into a frontend-only commit.

### D-G — Consent and device check across a reload

| | Decision | Why |
|---|---|---|
| Device check | **Must re-run.** | Not a preference — a `MediaStream` is a live handle, not serialisable. Persisting "device check passed" produces exactly the broken session: a resumed interview with no stream and proctoring silently dead (`useProctor.start(stream)`). It is a stream to re-acquire, not state to persist. |
| Consent | **Status quo — in-memory, re-consent each sitting.** | Open question 2 is a compliance call this design must not make. Conservative default: persisting a recording consent that should not have been persisted is a compliance problem; un-persisting is one line. |

**Consequence, stated plainly because the naive reading of "resume" is wrong**: a resuming candidate
still walks `idle (consent) → device_check → connecting → /start`. Resume skips the **exchange**,
not the gates. `/start`'s `RESUME in_corso` path then returns the persisted `question_index`, so
they land on the right question after two clicks.

---

## Data Flow

```
FIRST ENTRY                                    RESUME (stored, unexpired)
───────────                                    ─────────────────────────
/interview/{sso}                               /interview/{sso}
  │                                              │
  ├─ read localStorage → none                    ├─ read localStorage → hit
  │                                              ├─ compare unverified claims
  ├─ GET /sso/exchange?token=…  ◄── ONCE         │   candidate_ref + project_id
  │    ├ 401 → terminal(spent, no retry)         │   (match → reuse; link UNSPENT)
  │    └ 403 → terminal(generic)                 │
  ├─ store { access_token, exp }                 │
  └─ navigateTo('/interview/session',{replace})  └─ navigateTo(session,{replace})
                        │                                    │
                        └────────────┬───────────────────────┘
                                     ▼
                  /interview/session   ← no token in the URL.
                  middleware: sync localStorage read
                     none/expired → terminal(session_expired)
                                     │
                  consent → device_check → connecting
                                     │
                  candidateFetch('/candidate/interview/start')
                     Authorization: Bearer <candidate JWT>
                     ├ 200 → live (resumes at question_index)
                     ├ 401 → clear session → terminal(session_expired)  ← NEW
                     ├ 403 → terminal(generic)
                     ├ bad shape → terminal(malformed_response)         ← NEW
                     └ 429/502 → retryable error (unchanged)
```

`replace: true` is load-bearing: the token URL leaves the history entry, so neither Back nor a
refresh can re-enter the exchange. Refresh-safety is structural, not a flag someone must check.

**Multi-tenancy**: unchanged and entirely server-side — `TenantContextCandidate` scopes every
`/candidate/*` call from the JWT's `organization_id`/`project_id` claims
(`CandidateTokenFactory.php:98-105`). The frontend reads `candidate_ref` and `project_id` from the
stored token **only** to answer "may I reuse what I already hold"; the server re-validates the
signature on every call. No client-side claim is ever trusted for scoping.

---

## File Changes

| File | Action | Description |
|---|---|---|
| `frontend/app/composables/useCandidateSession.ts` | Create | store / read / clear / `exp` purge-on-read. `localStorage`, per proposal D2. |
| `frontend/app/utils/candidate-api.ts` | Create | `candidateFetch` + `CandidateUnauthorizedError` + `flushIntegrityKeepalive` consumer surface. |
| `frontend/app/pages/interview/session.vue` | Create | The interview. Body moved verbatim from `[token].vue`. |
| `frontend/app/middleware/candidate-session.ts` | Create | Sync gate on the session route (D-E). |
| `frontend/app/pages/interview/[token].vue` | Modify | Becomes the entry route. False comment at `:245` deleted. |
| `frontend/app/composables/useInterviewSession.ts` | Modify | `candidateFetch`; `session_expired` + `malformed_response` terminal reasons; resize-flush duplicate removed. |
| `frontend/app/composables/useIntegrityFlush.ts` | Modify | `keepalive` fetch replaces `sendBeacon`; shared flush helper. |
| `frontend/app/composables/useExitRedirect.ts` | Modify | Auth header; `sessionFetchFailed`; honest log copy. |
| `frontend/app/composables/useProctor.ts` | Modify | Raw `fetch` at `:518` → `candidateFetch`. |
| `frontend/app/pages/interview/terminal.vue` | Modify | `session_expired` + `spent_link` variants. |
| `frontend/i18n/locales/{it,en}.json` | Modify | Both mandatory. |
| `frontend/tests/e2e/interview-flow.spec.ts` | Modify | Stop mocking the exchange; assert request headers. |
| `api/tests/Feature/CandidateSessionAuth/MintExchangeAuthenticatedCallTest.php` | Create | Test only — no production backend change. |
| `EntryLinkUrlComposer.php`, `nuxt.config.ts`, `api/routes/api.php` | **Unchanged** | Stated explicitly: an edit here is a scope breach. |

---

## Interfaces / Contracts

```ts
// app/composables/useCandidateSession.ts
export interface CandidateSession { accessToken: string; exp: number; candidateRef: string; projectId: number }
export interface UseCandidateSessionReturn {
  /** Purges and returns null when `exp` has passed. Never returns an expired session. */
  read(): CandidateSession | null
  store(accessToken: string): void   // decodes claims; no signature verification (server re-validates)
  clear(): void
}

// app/utils/candidate-api.ts
export class CandidateUnauthorizedError extends Error {}   // thrown after clear(); never retried
export function candidateFetch<T>(path: string, options?: FetchOptions): Promise<T>
export function flushIntegrityKeepalive(payload: unknown): void  // fetch+keepalive, header attached
```

---

## Testing Strategy

`strict_tdd: true`. Command discipline from the proposal: `./vendor/bin/pest <exact-file>` (never
`--filter`), Playwright `--workers=1`.

| Layer | What | Where |
|---|---|---|
| Integration | **The real chain**: `mintSsoLink` → `GET /api/sso/exchange` → `Authorization: Bearer` → `GET /api/candidate/session` **and** `POST /candidate/interview/start` — no browser, nothing mocked. Precedent: `SsoExchangeHappyPathTest.php:42`. | **api Pest** |
| Contract | Frontend/API agreement on the `access_token` field. **Already guarded** — `scripts/check-client-drift.sh` stage 1 diffs `frontend/openapi.json` against `../api/openapi.json`; `/sso/exchange` with required `access_token` is at `openapi.json:3336-3367`. Reuse it; do not invent a third suite. | frontend CI (existing) |
| E2E | Exchange **not** mocked in response shape only — assertions are **request-side**: exchange called exactly **once** across a reload; first `/start` carries `Authorization`; `/interview/session` serves `camera=(self)`. Request-side assertions are not weakened by a stubbed response. | frontend Playwright |
| Unit | `useCandidateSession` purge-on-expiry; `candidateFetch` header + 401→clear; entry-route single-exchange and stored-session skip; `401`/`malformed_response` terminals; keepalive flush; i18n key parity. | Vitest |
| Guard | Source scan: no `/candidate/` request outside `candidate-api.ts`. | Vitest |

### Where the real-chain test lives — and why not the frontend

`frontend/playwright.config.ts:54-77` runs a self-contained `webServer` with
`NUXT_PUBLIC_API_BASE` pointed at **its own origin**; `frontend/.github/workflows/ci.yml:19` runs in
a bare Playwright container with no Postgres, no Redis, no PHP; and `frontend/` is a separate git
submodule with its own CI. Standing the real API up there means adding PHP 8.5 + Postgres 17/pgvector
+ Redis 8 service containers, migrations, a seeded org/project, and an artisan mint command — a new
CI topology plus a new class of flake (two services, health waits) in a suite that currently has
none, at roughly 3-6 extra minutes per run.

**Decision: the api Pest suite.** It exercises mint → exchange → authenticated call genuinely and
end to end; it simply has no browser. The browser half — "does the client attach the header, and
does a refresh re-exchange" — is exactly what request-side Playwright assertions prove without an
API. The only residual seam (the field name on the wire) is covered by the drift check that already
runs. A compose-based wrapper E2E is recorded as a **named follow-up with its cost written down**,
not built here.

**Stated honestly**: the Pest test is **green on first run**. That is the point — it locks in that
the API half was never the defect, and it is a characterisation test, not a RED one. Calling it TDD
would be a lie.

### RED-first order

1. RED `use-candidate-session.spec.ts` — store / read / clear / purge on stale `exp`.
2. RED `candidate-api.spec.ts` — header attached; 401 clears + throws typed; no token → no network call.
3. RED guard scan — no `/candidate/` call outside the wrapper.
4. GREEN 1-3, migrating **every** call site including `useProctor.ts:518` and both beacon paths.
5. RED `interview-entry.spec.ts` — stored session → **zero** exchanges; none → **exactly one**, then `replace` to `/interview/session`; 401/403 → their terminals.
6. RED `use-interview-session.spec.ts` — 401 → `session_expired`, cleared, no retry; bad shape → `malformed_response`, not `error`.
7. RED `use-exit-redirect.spec.ts` — header; 401 → `sessionFetchFailed`, still no throw.
8. RED `use-integrity-flush.spec.ts` — keepalive + header replaces `sendBeacon`.
9. RED `i18n-interview-keys.spec.ts` — new keys in **it and en**.
10. GREEN 5-9 in that order, then the E2E refresh-does-not-burn-the-link spec.
11. Characterisation: the Pest chain test (expected green — write it anyway).

---

## Migration / Rollout

No migration, no data, no feature flag. Reverting restores today's behaviour exactly, because
nothing downstream works today.

**Atomicity.** `useCandidateSession` + `candidateFetch` + **every** call-site migration + the guard
test must land together. A partial landing ships a build where some candidate calls carry the header
and some 401 — strictly worse than today, where they fail uniformly and visibly.

**Suggested slices** (exact guard lines are `sdd-tasks`' job): PR1 = the transport commit above
(self-contained: headers attach when a token exists; no way to get one yet, so behaviour is
unchanged-but-ready). PR2 = route split + entry exchange + resume + the refresh test. PR3 = failure
screens, i18n, redirect surfacing, E2E rewrite. **400-line budget risk: High** — PR1 alone is ~450
lines with tests.

---

## Open Questions

- [ ] Proposal open question 1 (self-serve re-entry after expiry) — D-F answers the frontend half
      only; the operator alert is a backend change deliberately not opened here.
- [ ] Proposal open question 2 (consent persistence) — D-G holds the status quo pending the
      compliance owner. Reversal cost recorded: one persisted flag.
- [ ] Compose-based wrapper E2E (real API + real browser) — costed above, not scheduled.
