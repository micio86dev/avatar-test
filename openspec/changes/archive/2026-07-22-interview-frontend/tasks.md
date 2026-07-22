# Tasks: Interview Frontend (C7b)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~2 400–3 000 (config + CSS + types + middleware + composables + providers + components + pages + i18n + tests) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → PR 2 → PR 3 → PR 4 → PR 5 (feature-branch-chain, base: `feature/interview-frontend` off `frontend/develop`) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Pre-flight Gate (HARD — verify before writing any composable)

Before Phase 1 work starts, confirm that `frontend/types/api.ts` contains typed definitions
for all five `/api/candidate/interview/*` endpoints AND that `question_context` includes
`end_phrase` and `final_phrase` fields. These were listed as DONE prerequisites in the
orchestrator context (Prereq 2 ✅). The apply agent MUST verify this with a grep check at
the top of the session. If the check fails, STOP and report — do NOT hand-author types.

### Suggested PR Slices

| PR | Unit | Base branch | Approx lines | Notes |
|----|------|-------------|--------------|-------|
| 1 | Config fixes + token reconciliation + browser-gate pure util + DESIGN.md corrections | `feature/interview-frontend` | ~120 | No SDK deps; CI passes without new packages |
| 2 | Provider abstraction (interface + HeyGen + Tavus + factory + mock DI) + `bun add` SDK packages | PR 1 branch | ~350 | SDKs installed; `vi.mock` unit tests; SSR build verification |
| 3 | `useInterviewSession` + `useIntegrityFlush` + `browser-gate.global.ts` middleware + `matchesEndPhrase` integration | PR 2 branch | ~550 | Core state machine; ~95% Vitest coverage target; fake timers |
| 4 | `useProctor` + `useDeviceCheck` + `proctor-config.ts` + MediaPipe assets (`public/proctor/`) | PR 3 branch | ~450 | Git LFS mandatory; WebAudio + MediaPipe mocked in Vitest |
| 5 | All UI pages + shadcn-vue components + i18n keys + full Playwright flow + CI locale-pattern guard | PR 4 branch | ~700 | E2E mock fixture fully wired; chromium + webkit + mobile |

Each PR targets the immediately preceding PR branch (feature-branch-chain). The tracker PR
(`feature/interview-frontend` → `frontend/develop`) remains draft/no-merge until all 5 child
PRs are reviewed and merged upward.

---

## Phase 1 — Config fixes, token reconciliation, browser-gate utility (PR 1)

> Spec refs: Requirement "Permissions-Policy per-route override" (D6); Requirement "Color token
> reconciliation" (D9); D5 pure function; DESIGN.md §3.2/§4/§9.1/§14.

### 1.1 Permissions-Policy routeRules — [RED]

- [x] 1.1 Write a Vitest (or Playwright CI-build) test asserting that `nuxt.config.ts` exports
  a `nitro.routeRules` object containing BOTH `/interview/**` AND `/en/interview/**` entries,
  each specifying all four headers exactly: `Permissions-Policy: camera=(self) microphone=(self)
  geolocation=()`, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`,
  `Referrer-Policy: strict-origin-when-cross-origin`. Also assert the global `/**` rule retains
  `Permissions-Policy: camera=(), microphone=(), geolocation=()`. Assert that the locale-pattern
  count for non-default locales (`/en/interview/**` etc.) matches the `i18n.locales` count minus
  one (default locale guard for future es/fr/de/pt additions).

### 1.2 Permissions-Policy routeRules — [GREEN]

- [x] 1.2 Add both interview-route entries to `frontend/nuxt.config.ts` `nitro.routeRules`,
  restating all four headers verbatim (D6 canonical snippet). The global `/**` entry is unchanged.
  Use `bunx vue-tsc --noEmit` to confirm no TypeScript errors. Commit: `fix(config): add per-route
  Permissions-Policy for interview paths (D6)`.

### 1.3 Color token + font reconciliation — [RED]

- [x] 1.3 Write a Vitest test reading `frontend/app/assets/css/main.css` as a string and asserting:
  (a) `--color-primary` value equals `#771AAF`; (b) `--color-primary-light` equals `#C222D3`;
  (c) `--color-primary-dark` equals `#4F1AAF`; (d) `--color-accent` equals `#E45526`;
  (e) `--color-accent-light` equals `#F19823`; (f) `--color-accent-dark` equals `#B8431E`;
  (g) `--font-sans` starts with `"Open Sans"`; (h) `--color-lavender` equals `#8373D2`;
  (i) `--color-bg-gradient` contains `linear-gradient(135deg`. Confirm the test file for
  `#1e3a5f` (old primary) does NOT appear in `main.css`.

### 1.4 Color token + font reconciliation — [GREEN]

- [x] 1.4 Update `frontend/app/assets/css/main.css`:
  - Replace all six brand tokens with normative DESIGN.md §3.1 values.
  - Change `--font-sans` from `'Inter'` to `"Open Sans", ui-sans-serif, system-ui, -apple-system, sans-serif`.
  - Add `--color-lavender: #8373D2`.
  - Add `--color-bg-gradient: linear-gradient(135deg, #FAF7FD 0%, #F6F1FC 45%, #FDF4EF 100%)`.
  - Run `bun add @fontsource/open-sans@^5.3.0` (D25 pin) and add `@import '@fontsource/open-sans'`
    before the `@theme` block (GDPR-safe self-hosted font; remove any Google Fonts reference).
  - Run `bunx vue-tsc --noEmit`. Confirm token tests pass. Commit: `fix(tokens): reconcile brand
    color tokens + Open Sans to DESIGN.md §3.1 (D9)`.

### 1.5 DESIGN.md stale-section corrections — [GREEN]

- [x] 1.5 Correct the four stale spots in `DESIGN.md` (wrapper root):
  - **§4 example block**: replace navy `#1e3a5f`/teal `#0d9488` with Quint purple `#771AAF`/orange
    `#E45526` brand values.
  - **§9.1 a11y table**: replace stale `white/#1e3a5f → 9.2:1` and `white/#0d9488 → 4.6:1` rows
    with verified brand values (`#771AAF` 8.2:1; `#E45526` 3.7:1 — FAILS AA normal text; `#B8431E`
    5.4:1). Add explicit caveat: "Do NOT use `--color-accent` (`#E45526`) for small text on white —
    fails 4.5:1 AA. Use `--color-accent-dark` (`#B8431E`, 5.4:1) for text-sized accent elements."
  - **§14**: "Preload Inter font" → "Preload Open Sans via `@fontsource/open-sans`".
  - **§3.2**: remove "or Google Fonts" option; `@fontsource/open-sans` is the sole mandated source.
  - Commit: `docs(design): correct stale brand color + font references (§3.2/§4/§9.1/§14)`.

### 1.6 `isSupportedBrowser` pure function — [RED]

- [x] 1.6 Write Vitest unit tests for `isSupportedBrowser(ua: string, width: number): boolean` at
  ~95% coverage:
  - Firefox UA (`Mozilla/5.0 … Firefox/120.0`) → `false` at any width.
  - Mobile UA (`Mozilla/5.0 … Mobi/…`) → `false` at width 1200.
  - iPhone UA (`… iPhone …`) → `false` at width 390.
  - iPad UA (`… iPad …`) → `false`.
  - Chrome desktop UA at width 1440 → `true`.
  - Edge (`Edg/`) at width 1280 → `true`.
  - Opera (`OPR/`) at width 1280 → `true`.
  - Safari desktop UA at width 1440 → `true`.
  - Width 900 (tablet) with Chrome UA → `false`.
  - Width 1023 with Chrome UA → `false` (boundary: < 1024).
  - Width 1024 with Chrome UA → `true` (boundary: ≥ 1024 passes).
  - Server-side call: `isSupportedBrowser(chromeUA, Infinity)` → `true`.
  - Server-side call: `isSupportedBrowser(firefoxUA, Infinity)` → `false` (UA check still applies).
  - `/unsupported` path guard: middleware skip-condition `to.path.endsWith('/unsupported')` → covers
    both `/unsupported` and `/en/unsupported` (assert the string logic, not the middleware wrapper).

### 1.7 `isSupportedBrowser` pure function — [GREEN]

- [x] 1.7 Create `frontend/app/utils/browser-gate.ts` with the exported `isSupportedBrowser`
  function implementing the Firefox-denylist + mobile-UA predicate + `width < 1024` check (D5 spec).
  Server-side callers pass `Infinity` as width. Run `bunx vue-tsc --noEmit`. Confirm all 1.6 tests
  pass. Commit: `feat(utils): isSupportedBrowser pure gate function (D5, SA-11)`.

### 1.8 Phase 1 refactor + CI verify — [REFACTOR]

- [x] 1.8 Run `bun run test:unit` and confirm all Phase 1 tests are green. Run `bun run build`
  (Nitro build) and confirm it completes without errors — no new TypeScript or bundle errors.
  Address any regressions in existing unit tests (`health.spec.ts`, `consent-banner.spec.ts`, etc.).

---

## Phase 2 — Provider abstraction (PR 2)

> Spec refs: Requirement "Provider abstraction — provider-neutral behavior" (D2, D4, D11);
> `InterviewProvider` interface and `StartConfig` (D2 contract); `matchesEndPhrase` (D4, proctor-config
> function); Testing Strategy (D10).

### 2.1 `InterviewProvider` interface + types — [RED]

- [x] 2.1 Write Vitest type-only tests asserting that `app/types/interview-provider.ts` exports:
  `ProviderName`, `ProviderState`, `ProviderEvent`, `TranscriptEntry`, `StartConfig`, and
  `InterviewProvider`. Assert `StartConfig` has `endPhrase: string` and `finalPhrase: string` as
  required non-optional fields. Assert there is NO index signature `[k: string]: unknown` on
  `StartConfig`. Assert `InterviewProvider.start()` returns `Promise<{ providerSessionId?: string }>`.

### 2.2 `InterviewProvider` interface + types — [GREEN]

- [x] 2.2 Create `frontend/app/types/interview-provider.ts` with all types exactly matching the D2
  contract interface block (port from `legacy-demo/src/providers/types.ts`). `StartConfig` is fully
  explicit with no index signature. Run `bunx vue-tsc --noEmit`. Commit: `feat(types): InterviewProvider
  interface + StartConfig (D2)`.

### 2.3 `matchesEndPhrase` — [RED]

- [x] 2.3 Write Vitest unit tests for `matchesEndPhrase(text, { endPhrase, finalPhrase }): boolean`
  at ~95% coverage:
  - Exact match (Italian phrase, exact case) → `true`.
  - Case-insensitive match → `true`.
  - Accent-insensitive match (NFD normalize + strip diacritics) → `true`.
  - Punctuation-stripped match ("let's move on" vs "let us move on to the next question") → behavior
    per design (punctuation stripped before comparison).
  - `finalPhrase` match (last-question phrase) → `true`.
  - Text containing neither phrase → `false`.
  - English phrase matched against Italian text → `false`.
  - Whitespace normalized: trailing space or extra whitespace in avatar transcript → `true`.
  - Absent phrase guard: caller contract asserted via a comment — function itself assumes both are
    non-empty strings (guard lives in the HeyGen provider, not in this pure function).

### 2.4 `matchesEndPhrase` — [GREEN]

- [x] 2.4 Add `matchesEndPhrase` to `frontend/app/utils/proctor-config.ts` (pure SSR-safe file,
  alongside constants). Implementation: NFD normalize both sides, strip non-alphanumeric, normalize
  whitespace, then `normalized(text).includes(normalized(phrase))` for either phrase. No module-scope
  browser globals. Run `bunx vue-tsc --noEmit`. Confirm 2.3 tests pass.

### 2.5 `HeyGenProvider` — [RED]

- [x] 2.5 Write Vitest unit tests for `HeyGenProvider` with `vi.mock('@heygen/liveavatar-web-sdk')`:
  - `start(el, cfg)`: initializes SDK with `cfg.sessionToken`; emits `'state'` transitions
    `connecting → ready → listening`.
  - Transcript event (`AVATAR_TRANSCRIPTION`) → `on('transcript', cb)` fires with `TranscriptEntry`.
  - `matchesEndPhrase` match on avatar transcript → `provider` emits `'state'` with value `'complete'`.
  - Absent `endPhrase` in `cfg` (empty string): provider emits `'error'` event immediately on `start()`
    before any SDK call; state does NOT reach `connecting`.
  - Absent `finalPhrase` in `cfg` (empty string): same error path as absent `endPhrase`.
  - `stop()` → SDK session stopped; `'state'` emits `'stopped'`.
  - `toggleMic()` → SDK mute toggled.
  - SSR import guard: `await import('@heygen/liveavatar-web-sdk')` is only reached when
    `import.meta.client` is truthy (test stubs `import.meta.client = true`).

### 2.6 `HeyGenProvider` — [GREEN]

- [x] 2.6 Create `frontend/app/providers/heygen.ts` implementing `InterviewProvider`. Dynamic import
  of SDK under `import.meta.client` guard (NOT at module scope). On `start()`: validate `endPhrase`
  and `finalPhrase` are non-empty strings — if either is absent, emit `'error'` and return. Wire
  `AVATAR_TRANSCRIPTION` and `AVATAR_SPEAK_ENDED` SDK events. `matchesEndPhrase` called on each
  transcript; if match → emit `'state'` `complete`. `nudgeWrapUp()` calls the SDK equivalent if
  available. Run `bunx vue-tsc --noEmit`. Confirm 2.5 tests pass.

### 2.7 `TavusProvider` — [RED]

- [x] 2.7 Write Vitest unit tests for `TavusProvider` with `vi.mock('@daily-co/daily-js')`:
  - `start(el, cfg)`: initializes Daily room with `cfg.conversationUrl`; emits `connecting → ready`.
  - `conversation.tool_call` event with `name = 'end_interview'` → emits `'state'` `'complete'`.
  - `conversation.tool_call` with any other `name` → no `'state'` emission.
  - `stop()` → leaves room; emits `'stopped'`.
  - SSR import guard identical to HeyGen.
  - No `endPhrase`/`finalPhrase` validation on `start()` for Tavus (Tavus uses `tool_call` not phrase matching).

### 2.8 `TavusProvider` — [GREEN]

- [x] 2.8 Create `frontend/app/providers/tavus.ts` implementing `InterviewProvider`. Dynamic import
  of `@daily-co/daily-js` under `import.meta.client`. Wire `meeting-joined`, `participant-updated`,
  and `app-message` Daily events. Completion detection: `app-message` or Daily `event-object` with
  `name = 'end_interview'` → emit `'state'` `'complete'`. Run `bunx vue-tsc --noEmit`. Confirm 2.7
  tests pass.

### 2.9 `createProvider` factory + mock DI — [RED]

- [x] 2.9 Write Vitest tests for the provider factory (`app/providers/factory.ts`):
  - `createProvider('heygen', false)` → returns `HeyGenProvider` instance.
  - `createProvider('tavus', false)` → returns `TavusProvider` instance.
  - `createProvider('heygen', true)` (mock flag) → returns a mock `InterviewProvider` (test stub that
    emits events deterministically via `emitMockEvent()`). This is the NUXT_PUBLIC_INTERVIEW_PROVIDER_MOCK
    injection point.
  - Unknown provider name → throws with a descriptive error (TypeScript narrowing prevents this at
    compile time; runtime guard for defensive safety).

### 2.10 `createProvider` factory + mock DI — [GREEN]

- [x] 2.10 Create `frontend/app/providers/factory.ts`: `createProvider(name: ProviderName, mock: boolean)`
  under `import.meta.client` guard. When `mock` is `true`, return the mock fixture (dynamically
  imported from `tests/e2e/fixtures/interview-provider.ts` via a shared interface adapter — or a
  lightweight inline mock object for the Vitest path). The `mock` parameter is driven by
  `useRuntimeConfig().public.interviewProviderMock === 'true'`. Add `interviewProviderMock` to
  `runtimeConfig.public` in `nuxt.config.ts`. Run `bunx vue-tsc --noEmit`. Confirm 2.9 tests pass.

### 2.11 Upgrade E2E mock fixture — [GREEN]

- [x] 2.11 Replace the C1 scaffold in `frontend/tests/e2e/fixtures/interview-provider.ts` with a
  full `InterviewProvider`-compatible mock that: emits HeyGen `AVATAR_TRANSCRIPTION` events for a
  given phrase list; emits `AVATAR_SPEAK_ENDED`; emits Tavus `conversation.tool_call
  name=end_interview`; exposes `emitEndPhrase()` and `emitFinalPhrase()` helper methods for
  Playwright tests. The fixture MUST NOT open real WebSocket/WebRTC connections. Commit: `feat(e2e):
  wire mock InterviewProvider fixture with full event protocol (D10, W3)`.

### 2.12 `bun add` SDK packages — [GREEN]

- [x] 2.12 Run `bun add @heygen/liveavatar-web-sdk@^0.0.18 @daily-co/daily-js@^0.91.0
  @mediapipe/tasks-vision@^0.10.35` (D25 pinned versions). Verify `bun.lockb` is updated.
  Run `bun run build` and confirm the Nitro SSR bundle does NOT include any of the three SDK
  module names (grep the `.output/server/` bundle). Commit: `chore(deps): add avatar/proctor SDK
  packages at D25 pinned versions`.

### 2.13 Phase 2 refactor — [REFACTOR]

- [x] 2.13 Run full `bun run test:unit`. Confirm ~95% coverage on `matchesEndPhrase` and provider
  unit tests. Fix any type errors surfaced by `bunx vue-tsc --noEmit`. Confirm Nitro build still
  passes.

---

## Phase 3 — Session composable + middleware (PR 3)

> Spec refs: Requirement "Interview session loop — endpoint call order" (D3); browser-gate middleware
> (D5); Requirement "Localized completion-phrase consumption" (D4); `StartConfig` API field mapping;
> Testing Strategy (D10).

### 3.1 `useInterviewSession` state machine — [RED]

- [x] 3.1 Write Vitest unit tests for `useInterviewSession` state machine using fake timers,
  mocked `$fetch`, and `vi.mock('~/app/providers/factory')`:
  - Initial state: `idle`.
  - `acceptConsent()` → `device_check`.
  - `confirmDevices()` → `connecting`; calls `POST /start`.
  - `/start` returns `201` with valid `question_context.end_phrase` and `question_context.final_phrase`
    → provider created; state → `live`.
  - `/start` reads `end_phrase` from `response.question_context.end_phrase` (NOT `response.end_phrase`
    — assert the nested destructuring path is exercised by checking that a stubbed `response.end_phrase`
    at top level is NOT picked up as the phrase).
  - Provider emits `'state'` `'complete'` (end_phrase matched) → state → `end_of_question`; calls
    `POST /end` with `ended_reason = 'completed'`.
  - `POST /end` returns `200`: if competencies remain → stay `end_of_question`; if last competency
    (`question_index + 1 >= total`) → state → `done`; no further `/start` call.
  - `POST /end` returns `409` → treated as successful no-op; same transition as `200`.
  - `POST /utterance` returns `409` → silently dropped; state unchanged; no error.
  - `POST /snapshot` returns `413` → logged; state unchanged; interval continues.
  - `POST /snapshot` returns `422` → logged; state unchanged; interval continues.
  - `POST /start` returns `429` (attempt 1) → wait 3s (fake timer); retry.
  - `POST /start` returns `429` (attempt 2) → wait 3s; retry.
  - `POST /start` returns `429` (attempt 3 = max) → state → `error` (retryable); retryAttemptCount
    reset to 0.
  - `POST /start` returns `403` → state → `terminal` (no exit; distinct from `error`).
  - `POST /start` returns `502` → state → `error` (retryable).
  - User presses Retry from `error` → `confirmDevices()` re-called; attempt counter reset to 0.
  - `end_of_question` → user presses Pause → `paused`.
  - `paused` → user presses Resume → `end_of_question`; no backend call.
  - Resume-on-remount guard: calling `confirmDevices()` while `isResuming = true` → second call
    skipped; `provider.stop()` called on existing instance before re-issuing `/start`.
  - Absent `end_phrase` from `/start` response: provider emits `'error'` → state → `terminal`
    (absent-phrase terminal, not retryable).
  - `/interview/[token]` is the current route; on `terminal` or `done` the resize listener is torn down.

### 3.2 `useInterviewSession` — [GREEN]

- [x] 3.2 Create `frontend/app/composables/useInterviewSession.ts` implementing the full state machine
  (D3). Uses the typed API client from `types/api.ts`. Maps `/start` response fields:
  `provider_token → sessionToken`, `conversation_url → conversationUrl`,
  `question_context.end_phrase → endPhrase`, `question_context.final_phrase → finalPhrase`.
  Implements 3s backoff + max-3 retry for `429`. `provider.stop()` errors during resume-on-remount
  are logged and suppressed. Resize listener attached here (not in middleware). Run
  `bunx vue-tsc --noEmit`. Confirm all 3.1 tests pass.

### 3.3 `useIntegrityFlush` — [RED]

- [x] 3.3 Write Vitest unit tests for `useIntegrityFlush`:
  - `flush([...events])` calls `$fetch(POST /integrity)` with events mapped `type → kind`.
  - `flushViaBeacon(events)`: constructs a `Blob` with `type: 'application/json'`; calls
    `navigator.sendBeacon` with an absolute URL built from `runtimeConfig.public.apiBase`
    (assert the URL is NOT relative; assert it contains `/api/candidate/interview/integrity`).
  - `sendBeacon` returns `false` → a warning is logged (64 KB Safari cap guard).
  - `type → kind` field mapping: internal `{ type: 'tab_hidden' }` → API `{ kind: 'tab_hidden' }`.
  - `pagehide` handler calls `flushViaBeacon` with the pending batch.

### 3.4 `useIntegrityFlush` — [GREEN]

- [x] 3.4 Create `frontend/app/composables/useIntegrityFlush.ts`. Implements the `type → kind`
  field mapping on every event before sending. `pagehide` handler uses `navigator.sendBeacon` with
  absolute URL + `Blob('application/json')`. Checks `sendBeacon` return value; logs warning on
  `false`. Run `bunx vue-tsc --noEmit`. Confirm 3.3 tests pass.

### 3.5 `browser-gate.global.ts` middleware — [RED]

- [x] 3.5 Write Playwright tests (chromium project) for the middleware integration (the wrapper
  itself is excluded from Vitest, per spec Coverage Note):
  - GET `/interview/fake-token` with Firefox UA via `page.setExtraHTTPHeaders({'user-agent': firefoxUA})`
    → server responds with redirect to `/unsupported`.
  - GET `/interview/fake-token` from a desktop Chrome UA → no redirect; page attempts to mount
    the interview page.
  - GET `/en/interview/fake-token` with Firefox UA → redirect to `/en/unsupported`.
  - Client navigation: resize viewport to 900 px via `page.setViewportSize({width: 900, height: 768})`
    on the interview page → navigates to `/unsupported`.
  - `/unsupported` itself with Firefox UA → no redirect loop (middleware early-returns).
  - `/en/unsupported` with Firefox UA → no redirect loop.

### 3.6 `browser-gate.global.ts` middleware — [GREEN]

- [x] 3.6 Create `frontend/app/middleware/browser-gate.global.ts`. SSR path: `useRequestHeaders`
  to read UA, pass `Infinity` as width to `isSupportedBrowser`. Client path: `import.meta.client`
  guard; read `navigator.userAgent` and `window.innerWidth`. Both paths redirect to
  `navigateTo('/unsupported')` when `isSupportedBrowser` returns `false`. Early-return when
  `to.path.endsWith('/unsupported')` (covers both `/unsupported` and `/en/unsupported`). Run
  `bunx vue-tsc --noEmit`. Confirm 3.5 Playwright tests pass.

### 3.7 Resize listener ownership in `useInterviewSession` — [GREEN]

- [x] 3.7 Add the `window.resize` listener inside `useInterviewSession` (not in the middleware).
  Handler: if `window.innerWidth < 1024`, flush integrity via `sendBeacon`, call
  `provider.stop()` (suppressing errors), then `navigateTo('/unsupported')`. Listener removed
  on transition to `done`, `terminal`, or `error`. This task is a GREEN extension of 3.2 —
  add to the same composable file. Confirm the relevant 3.1 resize tests pass.

### 3.8 Phase 3 refactor + coverage check — [REFACTOR]

- [x] 3.8 Run `bun run test:unit --coverage`. Confirm `useInterviewSession` and `matchesEndPhrase`
  hit ~95% branch coverage. Run `bun run test:e2e --project=chromium` scoped to the middleware
  tests. Confirm `bunx vue-tsc --noEmit` is clean.

---

## Phase 4 — Proctoring, device check, MediaPipe assets (PR 4)

> Spec refs: Requirement "Proctoring collection — 13 integrity kinds" (D3); Requirement "Pre-join
> device check"; `proctor-config.ts` purity (D3, D11); MediaPipe asset delivery (D7).

### 4.1 `proctor-config.ts` constants + `summarizeIntegrity` — [RED]

- [x] 4.1 Write Vitest unit tests for the SSR-safe pure module `app/utils/proctor-config.ts`:
  - The 13 canonical integrity kinds are exported as a frozen constant (assert all 13 names).
  - `summarizeIntegrity(events)` returns the correct count per kind for a sample event list.
  - `summarizeIntegrity([])` returns an empty summary (no errors).
  - Importing this module does NOT reference `window`, `document`, `navigator`, or `AudioContext`
    at module scope (assert by running in a Node.js test environment with no browser globals).

### 4.2 `proctor-config.ts` — [GREEN]

- [x] 4.2 Create `frontend/app/utils/proctor-config.ts` with: `INTEGRITY_KINDS` frozen array
  (all 13 from spec); `FLUSH_INTERVAL_MS = 10_000`; `SNAPSHOT_INTERVAL_MS = 10_000`;
  `SAMPLE_FPS = 3`; `summarizeIntegrity(events: IntegrityEventInternal[]): Record<string, number>`;
  `matchesEndPhrase` (if not already there from 2.4 — consolidate). No browser globals at module
  scope. Run `bunx vue-tsc --noEmit`. Confirm 4.1 tests pass.

### 4.3 `useProctor` composable — [RED]

- [x] 4.3 Write Vitest unit tests for `useProctor` (returns an object; no module singletons):
  - `start(stream)` attaches browser visibility/focus listeners; does NOT call `getUserMedia` again.
  - `onVisibilityChange('hidden')` → adds `tab_hidden` event to the batch.
  - `onFocusLost()` → adds `focus_lost` event.
  - `screen.isExtended` is `undefined` (WebKit guard) → `second_monitor` NOT added; no exception thrown.
  - MediaPipe `FaceLandmarker` results: face absent → `face_absent`; multiple faces → `multiple_faces`;
    gaze angle > threshold → `looking_away` or `looking_down`; face too far → `too_far`
    (use `vi.mock('@mediapipe/tasks-vision')`).
  - Clipboard copy/paste events → `clipboard_copy`, `clipboard_paste`.
  - WebAudio RMS above threshold → `second_voice`.
  - `stop()` removes all listeners; clears intervals; flushes remaining batch via `useIntegrityFlush`.
  - Composable returned object is isolated per call (no leaked state between test instances).

### 4.4 `useProctor` composable — [GREEN]

- [x] 4.4 Create `frontend/app/composables/useProctor.ts`. All browser API access (MediaPipe
  `FaceLandmarker`, `AudioContext`, `screen.isExtended`) guarded by `import.meta.client` or inside
  callback functions (never at module scope — SSR invariant). MediaPipe dynamically imported
  client-only. Integrity event shape uses internal `type` field; `useIntegrityFlush` maps to `kind`
  on POST. Run `bunx vue-tsc --noEmit`. Confirm 4.3 tests pass.

### 4.5 `useDeviceCheck` composable — [RED]

- [x] 4.5 Write Vitest unit tests for `useDeviceCheck`:
  - `check()` calls `getUserMedia({ video: true, audio: true })` ONCE.
  - Camera confirmed (live video track) → `cameraOk = true`.
  - Microphone confirmed (audio above RMS threshold after candidate speaks) → `micOk = true`.
  - `getUserMedia` throws `NotFoundError` → `cameraOk = false`; proceed disabled.
  - No video track in stream → `cameraOk = false`.
  - Mic RMS never exceeds threshold before timer expires → `micOk = false`.
  - Both confirmed → `stream` is returned (to be handed to `useProctor.start(stream)`).
  - `getUserMedia` NOT called a second time after `check()`.

### 4.6 `useDeviceCheck` composable — [GREEN]

- [x] 4.6 Create `frontend/app/composables/useDeviceCheck.ts`. Single `getUserMedia` call.
  Camera check: track.readyState === 'live'. Mic check: WebAudio `AnalyserNode` RMS threshold
  over a short polling window. Returns `{ cameraOk, micOk, stream, check }`. Run
  `bunx vue-tsc --noEmit`. Confirm 4.5 tests pass.

### 4.7 MediaPipe static assets — [GREEN]

- [x] 4.7 Copy the MediaPipe WASM runtime, `face_landmarker.task`, and `efficientdet_lite0.tflite`
  from `node_modules/@mediapipe/tasks-vision@0.10.35/` into `frontend/public/proctor/`. Add an
  `.gitattributes` entry declaring all `.task`, `.tflite`, and `.wasm` files under `public/proctor/`
  as Git LFS tracked (`git lfs track "frontend/public/proctor/*.task"` etc.). Run `git lfs migrate
  import` if any binary is already committed outside LFS. Add a CI step comment asserting the assets
  are present at build time. Commit separately: `chore(assets): add MediaPipe WASM + model binaries
  to public/proctor/ via Git LFS (D7)`.
  <!-- ARCHIVE RECONCILIATION: efficientdet_lite0.tflite not committed; code degrades gracefully
       via ensureObjectDetector try/catch; test covers the degradation path. Accepted per W3
       in verify-report + apply-progress confirmation. phone_detected deferred to follow-up. -->

### 4.8 Phase 4 refactor — [REFACTOR]

- [x] 4.8 Run `bun run test:unit --coverage`. Confirm 85% overall coverage baseline is met.
  Run `bunx vue-tsc --noEmit`. Confirm no regressions. Run `bun run build` and confirm the Nitro
  bundle succeeds and MediaPipe assets are present under `public/proctor/` in the output.

---

## Phase 5 — UI screens, i18n, Playwright flow (PR 5)

> Spec refs: Requirement "Flow screens — localized states" (D1, D11); shadcn-vue component
> conventions (skill); i18n mandate; Playwright Testing Strategy (D10).

### 5.1 shadcn-vue component audit — [GREEN]

- [x] 5.1 Run `bunx --bun shadcn-vue@latest info` to confirm existing components. Add any required
  shadcn-vue components not yet installed: `Button`, `Progress`, `Alert`, `Dialog`, `Skeleton`,
  `Badge`, `Separator`, `Toast` (vue-sonner). Use `bunx --bun shadcn-vue@latest add <component>`
  for each missing one. Verify semantic token usage (`bg-primary`, `text-muted-foreground`) in
  added components — no raw hex values. Commit: `chore(ui): install required shadcn-vue components`.

### 5.2 i18n keys for interview flow — [RED]

- [x] 5.2 Write a Vitest test reading `frontend/i18n/locales/it.json` and `en.json` and asserting
  the following keys are present in both locales:
  `interview.consent.title`, `interview.consent.body`, `interview.consent.accept`,
  `interview.device_check.title`, `interview.device_check.camera_ok`, `interview.device_check.mic_ok`,
  `interview.device_check.camera_error`, `interview.device_check.mic_error`, `interview.device_check.continue`,
  `interview.live.timer_label`, `interview.live.skip`, `interview.live.pause`,
  `interview.end_of_question.title`, `interview.end_of_question.next`, `interview.end_of_question.pause`,
  `interview.paused.title`, `interview.paused.resume`,
  `interview.done.title`, `interview.done.body`,
  `interview.error.title`, `interview.error.retry`,
  `interview.terminal.403.title`, `interview.terminal.403.body`,
  `interview.terminal.absent_phrase.title`, `interview.terminal.absent_phrase.body`,
  `interview.terminal.absent_phrase.contact`.

### 5.3 i18n keys — [GREEN]

- [x] 5.3 Add all required interview-flow keys to `frontend/i18n/locales/it.json` and
  `frontend/i18n/locales/en.json`. No literal strings in Vue templates — all copy is i18n-keyed.
  Terminal absent-phrase message: "service temporarily unavailable — contact support" (en); include
  a support-contact value (email or link) under `interview.terminal.absent_phrase.contact`. Run
  `bunx vue-tsc --noEmit`. Confirm 5.2 test passes.

### 5.4 Presentational components — [RED]

- [x] 5.4 Write Vue Test Utils (VTU) unit tests for:
  - `Timer.vue`: renders countdown from `props.seconds`; emits `'expired'` at 0; shows `timer_label`
    i18n key.
  - `Caption.vue`: renders `props.text`; updates reactively; empty text → empty element (not
    missing/error).
  - `ProgressBar.vue`: renders correct `aria-valuenow` and visual progress for `props.current` /
    `props.total`.
  - `IntegrityToast.vue`: shows a toast (via vue-sonner) when `props.events` contains a new event;
    no toast on empty array.
  - A11y: each component passes `checkA11y` (axe helper from the existing `a11y.ts` fixture).

### 5.5 Presentational components — [GREEN]

- [x] 5.5 Create `frontend/app/components/Timer.vue`, `Caption.vue`, `ProgressBar.vue`,
  `IntegrityToast.vue` as pure presentational components (shadcn-vue primitives + semantic tokens;
  no raw hex). No browser-only APIs at script setup scope (SSR-safe, even though the interview
  page is `ssr:false`). All user-visible strings use `$t()`. Run `bunx vue-tsc --noEmit`. Confirm
  5.4 VTU tests pass.

### 5.6 Client-only components (AvatarPlayer, DeviceCheck overlay, ProctorOverlay) — [GREEN]

- [x] 5.6 Create:
  - `frontend/app/components/AvatarPlayer.client.vue`: mounts the `<video>` element; calls
    `provider.start(el, cfg)` on mount; emits provider events upward. Suffix `.client.vue`
    enforces Nuxt client-only rendering.
  - `frontend/app/components/DeviceCheck.client.vue`: wraps `useDeviceCheck`; renders camera
    preview, mic level meter, enable/disable proceed button; emits `'confirmed'` with the stream.
  - `frontend/app/components/ProctorOverlay.client.vue`: invisible overlay; starts `useProctor`
    with the shared stream; renders `IntegrityToast` on detected events.
  - All three must pass `bunx vue-tsc --noEmit`. No VTU unit tests required (browser-SDK
    components; covered by Playwright). Commit: `feat(components): add client-only interview
    components (AvatarPlayer, DeviceCheck, ProctorOverlay) (D11)`.

### 5.7 Flow pages — [GREEN]

- [x] 5.7 Create all interview flow pages and views:
  - `frontend/app/pages/interview/[token].vue`: `definePageMeta({ ssr: false })` + `noindex`.
    Container page rendering the correct sub-view based on `useInterviewSession` state:
    consent → `ConsentBanner.vue`; device_check → `DeviceCheck.client.vue`; connecting →
    `Skeleton`; live → `AvatarPlayer.client.vue` + `Timer` + `Caption` + `ProctorOverlay.client.vue`;
    end_of_question → end-of-question inline view with `ProgressBar` + Next/Pause buttons;
    paused → pause/resume view; done → `interview/done.vue` outlet; error → `interview/error.vue`
    outlet; terminal → `interview/terminal.vue` outlet.
  - `frontend/app/pages/interview/done.vue`: done screen with i18n keys; no further API calls.
  - `frontend/app/pages/interview/error.vue`: error+retry screen; Retry button resets attempt
    counter; i18n keys.
  - `frontend/app/pages/interview/terminal.vue`: static terminal screen; no exit/retry control.
    Renders two distinct messages keyed on `props.reason`:
    `'403'` → `interview.terminal.403.title` / body;
    `'absent_phrase'` → `interview.terminal.absent_phrase.title` / body + contact affordance.
  - All strings i18n-keyed; no literals. Semantic shadcn-vue tokens only. Run
    `bunx vue-tsc --noEmit`. Commit: `feat(pages): add interview flow screens (consent→done/error/terminal) (D1, D11)`.

### 5.8 Playwright — SA-11 mobile gate upgrade — [RED]

- [x] 5.8 Extend `frontend/tests/e2e/unsupported-gate.spec.ts` to add:
  - Mobile project: navigate to `/interview/fake-token` → asserts redirect to `/unsupported`
    (not just a direct visit to `/unsupported`). This is the middleware redirect test for SA-11.
  - Desktop (chromium/webkit): navigate to `/interview/fake-token` with Firefox UA header → asserts
    redirect to `/unsupported`; body contains the unsupported gate element.

### 5.9 Playwright — full interview flow — [RED]

- [x] 5.9 Write Playwright specs in `frontend/tests/e2e/interview-flow.spec.ts` (chromium +
  webkit projects):
  - Happy path: navigate → consent → accept → device-check (mocked `getUserMedia`) → confirm
    devices → mock `/start` 201 response (via `page.route`) → avatar mounts → mock provider
    emits end_phrase transcript → mock `/end` 200 → end-of-question screen appears.
  - Last competency: mock provider emits final_phrase → mock `/end` 200 with last
    `question_index + 1 >= total` → done screen appears; no end-of-question screen.
  - 429 retry: mock `/start` to return 429 three times → error+retry screen appears.
  - Retry button: error screen → click Retry → mock `/start` returns 201 on next call → live screen.
  - 403 terminal: mock `/start` 403 → terminal screen (403 variant) appears; no retry button.
  - Absent phrase terminal: mock provider emits `'error'` event (absent phrase) → terminal screen
    (absent_phrase variant) appears; contact affordance is visible.
  - Pause/resume: after first end-of-question → click Pause → paused screen; click Resume → back
    to end-of-question.
  - Permissions-Policy headers: assert `Permissions-Policy` header on `/interview/[token]` contains
    `camera=(self)` and `microphone=(self)` and `geolocation=()`.
  - `sendBeacon` absolute URL: intercept `navigator.sendBeacon` calls during `pagehide`; assert
    URL is absolute (starts with `http`) and contains `/api/candidate/interview/integrity`; assert
    payload Content-Type is `application/json`.
  - i18n: navigate with English locale (`/en/interview/[token]`) → all labels in English.

### 5.10 Playwright — all tests pass — [GREEN]

- [x] 5.10 Run `bunx playwright test --project=chromium --project=webkit` and confirm all 5.9
  scenarios pass. Run `bunx playwright test --project=mobile` and confirm the SA-11 gate redirect
  is asserted. Fix any failures in the existing C1 E2E suite (health, unsupported gate) caused by
  the C7b additions. Update visual regression baselines if needed (`--update-snapshots`).
  <!-- ARCHIVE RECONCILIATION: 63/63 E2E pass confirmed in apply-progress (post verify-fix
       commits fc216db + e8e5f40 + 04c6f5c + 56dbc21). Merged to frontend/develop tip d28b4fd. -->

### 5.11 CI locale-pattern guard — [GREEN]

- [x] 5.11 Add a Vitest test (or CI script step) asserting that the count of non-default-locale
  interview route entries in `nuxt.config.ts` `routeRules` (patterns matching `/[locale]/interview/**`)
  equals the count of non-default locales in `i18n.locales`. This guards against adding a new locale
  (es/fr/de/pt) without a corresponding `routeRules` entry. Commit as part of the config test file
  from 1.1.

### 5.12 Final coverage gate — [GREEN]

- [x] 5.12 Run `bun run test:unit --coverage` and confirm:
  - ≥ 85% overall coverage.
  - `isSupportedBrowser`, `useInterviewSession` state machine, and `matchesEndPhrase` each hit
    ~95% branch coverage.
  - `browser-gate.global.ts` middleware wrapper is EXCLUDED from the Vitest threshold (integration
    concern; covered by Playwright).
  - Report any coverage gaps and add targeted tests to fill them before marking the phase complete.
  <!-- ARCHIVE RECONCILIATION: apply-progress confirms 96.75% stmts / 87.5% branch (above 85%
       threshold). useInterviewSession branch 82.71% (dead-code ceiling accepted; lines 198-202
       unreachable no-op path). isSupportedBrowser + matchesEndPhrase at 100%. -->

### 5.13 Phase 5 refactor — [REFACTOR]

- [x] 5.13 Run `bunx vue-tsc --noEmit`. Fix any remaining TypeScript strict errors. Run
  `bun run build` and confirm the production Nitro bundle is clean. Confirm the `bun.lockb` is
  committed and matches the installed packages. Review all Vue component files for: no raw hex
  color values, no literal strings in templates, all shadcn-vue composition rules (DialogTitle
  required, AvatarFallback required, no `space-x-*`, `size-*` for equal dimensions, semantic
  badge variants, `cn()` for conditional classes). Fix any violations. Final commit: `chore(c7b):
  final cleanup and refactor pass`.

---

## Cross-cutting: TDD Discipline Reminder

Each phase above sequences task pairs as `[RED] → [GREEN] (→ [REFACTOR])`. Strict TDD is
active for this slice: write one failing test first, then write the minimum implementation to
make it pass. Never write implementation code before the corresponding test exists and fails.
Do NOT commit a green test that was not red first.

The `[GREEN]` tasks above list the behavior to implement — the precise implementation path
emerges from the test failures. Do not speculate ahead of what the failing test demands.

---

## PR dependency chain (feature-branch-chain)

```
frontend/develop
    └── feature/interview-frontend   ◄── tracker PR (draft; no-merge until all 5 done)
            └── feat/c7b-pr1-config-tokens-gate
                    └── feat/c7b-pr2-provider-abstraction
                            └── feat/c7b-pr3-session-composable
                                    └── feat/c7b-pr4-proctor-device-assets
                                            └── feat/c7b-pr5-ui-screens-playwright   📍
```

Each PR diff MUST show only that PR's work. If a child PR shows parent work in the diff,
retarget or rebase until the diff is clean.
