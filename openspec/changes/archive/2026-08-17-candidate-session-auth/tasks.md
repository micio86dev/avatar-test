# Tasks: Candidate Session Authentication and Resume

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | PR1 ~450 (incl. tests) · PR2 ~350 · PR3 ~300 |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR1 transport → PR2 route split + resume → PR3 failure screens/i18n/E2E |
| Delivery strategy | **Resolved**: single branch, no PR chaining, size exception granted (orchestrator decision, recorded before apply) |
| Chain strategy | **Resolved**: N/A — size exception, not chained |

Decision needed before apply: **No — resolved** (size:exception)
Chained PRs recommended: Yes (forecast stands; overridden by explicit size exception)
Chain strategy: N/A (size exception)
400-line budget risk: High (forecast stands; accepted via size exception)

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|---|---|---|---|
| 1 | `candidateFetch` + storage + **every** call-site migration + guard test | PR1 | Self-contained: no token source yet, so headers stay absent — behaviour unchanged, ready. MUST land as one commit (see Phase 1). |
| 2 | Route split, entry exchange, sync resume gate, refresh-safety test | PR2 | Depends on PR1's `candidateFetch`/`useCandidateSession`. |
| 3 | Failure screens, i18n, redirect surfacing, E2E exchange rewrite | PR3 | Depends on PR2's terminal reasons. |

## Phase 1: Transport & Authenticated Calls (PR1 — single commit, no partial landing)

- [x] 1.1 RED `tests/unit/use-candidate-session.spec.ts` — store/read/clear, purge on stale `exp` (persistence req)
- [x] 1.2 GREEN `frontend/app/composables/useCandidateSession.ts` — `localStorage`, `CandidateSession` shape, purge-on-read
- [x] 1.3 RED `tests/unit/candidate-api.spec.ts` — header attached; 401 → clear + throw `CandidateUnauthorizedError`; no token → no network call
- [x] 1.4 GREEN `frontend/app/utils/candidate-api.ts` — `ofetch.create()` via `apiUrl()`, `onRequest`/`onResponseError`
- [x] 1.5 RED `tests/unit/candidate-fetch-guard.spec.ts` — source-scan (precedent `token-parity.spec.ts`): no `/candidate/` URL outside `candidate-api.ts`
- [x] 1.6 GREEN migrate `useInterviewSession.ts`, `useExitRedirect.ts`, and the raw `fetch` at `useProctor.ts:518` to `candidateFetch`
- [x] 1.7 RED `tests/unit/use-integrity-flush.spec.ts` additions — `keepalive` fetch + header replaces `sendBeacon`; acknowledge-on-dispatch on `pagehide`
- [x] 1.8 GREEN `useIntegrityFlush.ts` — module-scope `flushIntegrityKeepalive(payload)`; `!sent` warning → `try/catch`. **Deviation**: implemented in `candidate-api.ts` (matches the Interfaces/Contracts section) rather than literally inside `useIntegrityFlush.ts` (D-C's file reference) — keeps the guard's exemption list to one file and matches D-B's "one ofetch instance behind one function" shape. `useIntegrityFlush.ts` imports and calls it.
- [x] 1.9 GREEN `useInterviewSession.attachResizeListener()` (lines 196-213) calls the shared `flushIntegrityKeepalive` instead of its hand-built `sendBeacon` duplicate — **scope expansion**: two copies were two chances to miss the header
- [x] 1.10 Run guard scan + full Vitest suite; confirm 1.1-1.9 ship as ONE commit — a partial landing leaves some calls authenticated and some 401ing, strictly worse than today. **Also required, discovered in-flight**: migrated the pre-existing tests that exercised the now-migrated call sites (`use-exit-redirect.spec.ts`, `use-proctor.spec.ts` snapshot tests, `use-interview-session.spec.ts` resize/beacon tests) from mocking raw `ofetch`/`sendBeacon` to mocking `candidate-api.ts` — required for "full suite green," not scope creep.

## Phase 2: Route Split, Entry Exchange, Resume (PR2)

- [x] 2.1 Create `frontend/app/pages/interview/session.vue` — interview UI moved verbatim from `[token].vue`. Also migrated `tests/unit/interview-page.spec.ts` → `interview-session-page.spec.ts` (import target moved with the UI).
- [x] 2.2 RED `tests/unit/interview-entry.spec.ts` — stored+valid session → zero exchanges; none → exactly one, then `replace` to `/interview/session`; 401/403 → their terminals
- [x] 2.3 GREEN `frontend/app/pages/interview/[token].vue` becomes the entry route: read stored session, compare `candidate_ref`+`project_id`, `GET /api/sso/exchange` once, store token, `navigateTo(session, {replace:true})`; delete false comment at `:245` (superseded — the whole script was rewritten, so the false claim has nothing left to attach to)
- [x] 2.4 RED `tests/unit/candidate-session-middleware.spec.ts` — sync `localStorage` gate on `/interview/session`; `replace` → `terminal?reason=session_expired` when absent/expired
- [x] 2.5 GREEN `frontend/app/middleware/candidate-session.ts` — client-only, synchronous, no network. **Note**: does not import from `#imports` (unresolvable under plain Vitest); uses the same Nuxt-global-auto-import convention as `definePageMeta`/`useHead` elsewhere in this codebase, which is what makes 2.4's unit test runnable at all.
- [x] 2.6 RED `tests/unit/use-interview-session.spec.ts` additions — 401 → `session_expired` (cleared, no retry); malformed `/start` body → `malformed_response` — reuses existing `interview.terminal.absent_phrase.*` copy for `malformed_response` (falls through to session.vue's existing `v-else` terminal branch); no new i18n keys for that reason
- [x] 2.7 GREEN `useInterviewSession.ts` — resume calls `/start` via `candidateFetch`; explicit shape guard (`isValidStartResponse`) before reading `question_context.end_phrase`; both new reasons wired as non-retryable via `instanceof CandidateUnauthorizedError` checks in `sendUtterance`/`callEnd`/`startSession`
- [x] 2.8 Extend `frontend/tests/e2e/interview-flow.spec.ts` — refresh-does-not-burn-the-link: exactly one `GET /api/sso/exchange` across a reload. **Also required, discovered in-flight**: every existing test in `interview-flow.spec.ts` and `interview-exit-redirect.spec.ts` that navigates to `/interview/{token}` needed `GET /api/sso/exchange` mocked (added `mockSsoExchange()` helper) — without it none of the existing happy-path/error-path E2E tests could reach the consent screen at all post-route-split.

## Phase 3: Honest Failure Surfacing (PR3)

- [x] 3.1 RED `tests/unit/use-exit-redirect.spec.ts` — header attached (via `candidateFetch`, already true post-1.6); 401 → `sessionFetchFailed:'unauthenticated'`, still never throws
- [x] 3.2 GREEN `useExitRedirect.ts` — `candidateFetch`; add `sessionFetchFailed` ref; delete "non-fatal" from the log; log names the consequence ("exit and error redirects are unavailable for this session")
- [x] 3.3 GREEN `frontend/app/pages/interview/terminal.vue` — `session_expired`/`spent_link` variants; expired copy states no self-serve path and never suggests a new link will help (enforced by a structural i18n test); routes through `error_redirect_url` **only via session.vue's existing inline mechanism** — see Deviations note below.
- [x] 3.4 GREEN wire `sessionFetchFailed === 'unauthenticated'` at `terminal`/`error` in `session.vue` → render expired-session variant instead of no-opping (`showExpiredSessionVariant` computed, unifies with `terminalReason === 'session_expired'` from 2.7)
- [x] 3.5 RED/GREEN `tests/unit/i18n-interview-keys.spec.ts` — it+en parity for all new terminal copy, plus a structural D-F guard (session_expired copy never contains the word "link")
- [x] 3.6 `frontend/i18n/locales/{it,en}.json` — added `interview.terminal.session_expired.{title,body}` and `interview.terminal.spent_link.{title,body}` in both; no bare literals

## Phase 4: Genuine-Chain Tests

- [x] 4.1 Create `api/tests/Feature/CandidateSessionAuth/MintExchangeAuthenticatedCallTest.php` — mint → `GET /api/sso/exchange` → `Authorization: Bearer` → `GET /api/candidate/session` + `POST /candidate/interview/start`, nothing mocked in the auth chain (HeyGen provider still `Http::fake()`d, per every other C7a `/start` test), no provider issue skipped. Run via `./vendor/bin/pest tests/Feature/CandidateSessionAuth/MintExchangeAuthenticatedCallTest.php` (never `--filter`). **Honesty, confirmed**: GREEN on first run — 3 tests, 17 assertions, 0 failures. Characterisation test, not TDD — recorded as such in the file's own docblock.
- [x] 4.2 Modify `frontend/tests/e2e/interview-flow.spec.ts` — added a dedicated test asserting the first `POST /start` carries `Authorization: Bearer <the exchanged token>`; kept provider-side mocking. **Deviation, documented in the test file itself**: did NOT remove the `GET /api/sso/exchange` `page.route()` mock. `playwright.config.ts`'s `webServer` is frontend-only (no PHP/Postgres/Redis), and `design.md`'s own "Where the real-chain test lives — and why not the frontend" section explicitly scopes the genuine (unmocked) chain to the api Pest suite (4.1), recording a real-API frontend E2E wrapper as a named, costed, NOT-built-here follow-up. The exchange response stays stubbed; the request-side behavior (token propagation into the next authenticated call, exactly-once exchange across a reload) is asserted directly and is not weakened by the stub.

## Phase 5: Cleanup / Boundaries

- [x] 5.1 Diff-check before commit: `EntryLinkUrlComposer.php`, `api/config/interview.php`, `nuxt.config.ts` routeRules, `api/routes/api.php` are untouched by this change. Confirmed via `git diff --stat`: `EntryLinkUrlComposer.php` and `nuxt.config.ts` show zero diff; `api/config/interview.php` and `api/routes/api.php` show diffs that predate this session entirely (the uncommitted `operator-interview-link`/entry-link change already applied to those working trees — `CANDIDATE_APP_URL` config and `EntryLinkController` route, neither touched by candidate-session-auth).
- [x] 5.2 OpenAPI snapshots (`api/`,`frontend/`,`backoffice/openapi.json`): confirmed not required to move — `bun run codegen:check` reports `[drift-check] OK` on both the snapshot-vs-api comparison and the generated-client-vs-snapshot comparison. No backend production code change, no Resource/endpoint/contract edit.
- [x] 5.3 Follow-up change proposal (operator-visible alert for a participant stalled at `in_corso` with non-advancing `question_index`, D-F disagreement): **documented as a recommendation in the apply report, not filed as a formal `openspec` proposal** — filing a new SDD change is outside this apply session's mandate (implementing candidate-session-auth's own tasks); recorded here so the next planning session picks it up.

## Verification Findings (post-apply adversarial review — mutation-proven)

Independent verification (`judgment-day`-style, mutation testing not inference)
found 5 CONFIRMED CRITICAL findings and 2 warnings against the apply above. All
7 are fixed. Each critical fix carries a test proven sensitive to the exact
regression by disabling the fix and confirming the test goes red, then
re-confirming green after restoring the fix — not merely "a test exists."

1. **Session clearing existed ONLY on the 401 path** (`candidate-api.ts:49`).
   No clearing on `done`, on 403/absent_phrase/malformed_response terminals in
   `useInterviewSession.ts`, none in `useExitRedirect.redirect()`/`redirectToError()`.
   **Fix**: centralized `useCandidateSession().clear()` inside
   `useInterviewSession.ts`'s `transitionTo()` for every `done`/`terminal`
   transition (not scattered per-branch — a per-branch patch is exactly the
   shape the next new terminal reason could forget), plus a defensive,
   independent `clear()` in `useExitRedirect.ts`'s shared `redirectTo()`
   (fires only on the path that actually navigates). 8 new tests across
   `use-interview-session.spec.ts` (6) and `use-exit-redirect.spec.ts` (2),
   RED-confirmed before the fix (6/6 and 2/2 failed on the missing `.clear()`
   call), GREEN after.
2. **"All terminal paths route through `error_redirect_url`" was false** for
   pre-authentication failures (entry-route exchange 401/403, and the
   candidate-session middleware's session-absent/expired gate) — no candidate
   JWT exists yet at either point, and `GET /api/candidate/session` requires
   one (backend-unchanged constraint forbids an unauthenticated variant).
   **Fix**: `specs/interview-frontend/spec.md`'s "Honest failure states"
   requirement rewritten to state the split explicitly (CAN: mid-session
   terminals reached after `useExitRedirect.fetchSession()` already resolved
   the URL once, authenticated, at page mount; CANNOT: pre-auth failures,
   structurally, not by omission) — with a new scenario for each side. No
   code changed; the artefact was wrong, not the behavior.
3. **`spec.md` said "the E2E exchange step is not mocked"; every E2E test
   mocks it.** **Fix**: the "Genuine authentication is exercised by tests, not
   mocked" requirement rewritten to state the actual, decided ownership split
   — the api Pest test (`MintExchangeAuthenticatedCallTest.php`) owns the
   genuine, nothing-mocked chain; the frontend E2E suite (whose `webServer` is
   frontend-only, no backend to call) owns request-side proof against a
   stubbed response (header propagation, exchange-once discipline) — with the
   rationale spelled out and two rewritten scenarios.
4. **The "reload after exchange" E2E test was decorative** — by reload time
   the browser is already on `/interview/session`, a route that structurally
   never imports the exchange transport, so the test could not fail on the
   thing it named (proven: disabling `storedSessionMatchesLink` left it
   green). **Fix**: removed, with an explanatory comment pointing at the
   sibling "revisit entry URL with a stored session" test, which DOES
   exercise `storedSessionMatchesLink` and DOES go red when it is disabled
   (unchanged, already correct).
5. **Locale-loss regression uncaught** — both unit tests stubbed
   `useLocalePath` as identity, so a revert to bare `navigateTo(path)` (the
   exact real bug found during apply) produced the same-looking assertion and
   stayed green. **Fix**: both stubs (`candidate-session-middleware.spec.ts`,
   `interview-entry.spec.ts`) now apply a distinguishable marker and assert
   `navigateTo` received the MARKED output, not the bare path. Mutation-proven
   by reverting `candidate-session.ts` and `[token].vue` to bare `navigateTo`
   calls: 2/4 and 4/6 tests went red respectively; reverting the mutation
   restored 4/4 and 6/6 green. Also added: 2 new E2E tests
   (`Locale preservation through failure paths`) walking `/en/` through both
   fix sites (middleware gate, entry-route exchange 401) to a real terminal
   URL in a real browser.

**Warnings closed:**
- The source-scan guard's raw-fetch detector missed `$fetch(`/`useFetch(`/`useLazyFetch(`
  (the negative lookbehind excluded any word-prefixed `fetch`, which covers
  `$fetch`/`useFetch`/`useLazyFetch` along with the intentionally-excluded
  `candidateFetch`). Widened (including generic-typed `$fetch<T>(...)`
  syntax), with 7 new unit tests pinning the pattern-matching behavior
  directly, and the guard's own docblock now states its documented ceiling
  (dynamic/concatenated paths, a hypothetical third wrapper, and non-network
  reads are out of scope by design, not by oversight).
- The keepalive flush's acknowledge-on-dispatch behavior (D-C) can silently
  drop proctoring evidence on an undelivered flush, with only a
  `console.warn` from a closing page as the trace. Now stated plainly in
  `candidate-api.ts`, `useIntegrityFlush.ts`, and `useInterviewSession.ts`'s
  resize handler — same practical ceiling `sendBeacon` already had, written
  down because it was not before, and pointed at the same follow-up track as
  5.3 rather than solved here (a durable delivery-confirmation channel is a
  backend-touching change, out of scope for this proposal).

## Verification Commands

- api: `./vendor/bin/pest tests/Feature/CandidateSessionAuth/MintExchangeAuthenticatedCallTest.php` · `./vendor/bin/pint --test` · `./vendor/bin/phpstan analyse --no-progress --memory-limit=1G` · `php artisan test --parallel` · `php artisan test --coverage --min=85`
- frontend: `node node_modules/.bin/vitest run --coverage --coverage.thresholds.lines=85` · `bun run typecheck` · `bun run format:check` · `bun run codegen:check` (expect no diff — no contract change) · `node node_modules/.bin/playwright test --workers=1`
- root: `task test:api` · `task test:frontend` · `task e2e:frontend` (pinned Playwright container, matches CI)
- CI parity: `api/.github/workflows/ci.yml`, `frontend/.github/workflows/ci.yml`; `.github/workflows/wrapper-ci.yml`'s openapi cross-repo gate is not implicated (5.2)
