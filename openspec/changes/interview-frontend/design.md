# Design: Interview Frontend (C7b)

## Technical Approach

Deliver the candidate-facing interview experience as an additive slice inside the
`frontend/` Nuxt 4 submodule (C1 scaffold). The strategy is **composable-first,
page-shell** (proposal Approach A): the interview route is a thin `ssr:false`
page that mounts browser-only work through composables (`useInterviewSession`,
`useProctor`, `useDeviceCheck`, `useIntegrityFlush`), a pure-TS `InterviewProvider`
abstraction with client-only dynamic SDK imports, and shadcn-vue presentational
components over the reconciled DESIGN.md token set. The five C7a endpoints
(`openspec/specs/interview-session/spec.md`) are consumed through a regenerated
typed client. Two C1 defects (Permissions-Policy, color tokens) are fixed here
because they block every downstream component.

Grounding: legacy port sources `legacy-demo/src/providers/types.ts`,
`legacy-demo/src/lib/proctor-config.ts`, and the legacy `scripts/{proctor,device-check}.ts`
(read-only). Current scaffold: `frontend/nuxt.config.ts`, `frontend/app/assets/css/main.css`,
`frontend/types/api.ts`, `frontend/tests/e2e/fixtures/interview-provider.ts`.

## Architecture Decisions

| # | Decision | Choice | Alternatives rejected | Rationale |
|---|---|---|---|---|
| **D1** | Interview-page rendering | `pages/interview/[token].vue` with `definePageMeta({ ssr:false })` + `noindex`. SSR shell renders nothing meaningful; all logic client-only. | Full SSR + `<ClientOnly>` wrapping every media widget; Nuxt Island | Route is session-gated and `noindex` → SSR yields zero SEO/TTFB value. Every API used (WebRTC, WebAudio, MediaPipe, `getUserMedia`) is browser-only. `ssr:false` removes an entire class of hydration-mismatch and accidental-SSR-import bugs. Router + i18n still work. |
| **D2** | Provider abstraction boundary | Pure-TS `InterviewProvider` iface in `app/types/interview-provider.ts`. Concrete `HeyGenProvider`/`TavusProvider` in `app/providers/{heygen,tavus}.ts`, loaded via **`await import()` guarded by `import.meta.client`** inside a `createProvider(name)` factory. Factory selects on the `provider` field from `/start`. SDK modules are NEVER imported at module scope. | Static top-level SDK imports; register providers via a Nuxt plugin at boot; one fat provider `if/else` | `@heygen/liveavatar-web-sdk` and `@daily-co/daily-js` reference `window`/`navigator` at import evaluation → any SSR-reachable static import crashes the Nitro `node-server` build. Dynamic client-only import is the only SSR-safe boundary. Factory keeps selection server-driven (not hardcoded) and preserves the legacy interchangeable-provider contract. |
| **D3** | Composables & state | `useInterviewSession` owns the state machine (`idle→device_check→connecting→live→end_of_question→paused→done/error/terminal`), the 5-endpoint loop, `429 provider_busy` (3s backoff, max 3), `409` silent-drop, `403` terminal redirect, resume-on-remount (calls `provider.stop()` on the existing instance before issuing the new `/start`; `provider.stop()` errors here are logged and suppressed — non-fatal). `useProctor` owns integrity capture + batching + snapshot + flush cadence, **returns an object (no module singletons)**. Pure constants + `summarizeIntegrity()` in `app/utils/proctor-config.ts` (SSR-safe, pure). **SSR invariant:** no composable module-evaluation scope may reference browser-only globals (`window`/`document`/`navigator`/`AudioContext`). All browser API access MUST be inside functions guarded by `import.meta.client` or a client-only dynamic import. Violation is a build-time error on the Nitro `node-server` bundle. **State: `terminal`** (no exit — reached from `403` on any endpoint, or from absent-phrase detection; distinct from `error` which is retryable). **`POST /end` 409 handling:** a `409` response from `POST /end` MUST be treated as a successful no-op — the session was already ended by a concurrent path (e.g. avatar-completion and timer-expiry race). The state machine proceeds exactly as if `/end` returned `200`; the `409` is NOT an error and MUST NOT trigger a retry or error screen. This rule is DISTINCT from the `/utterance` 409 silent-drop (different endpoint, same treatment but different semantic reason). **Last-competency detection:** the frontend tracks the ordered competency list from the C6 candidate-session bootstrap (project competencies from C4 `project_competencies.position` order). After `/end` returns `200`, the composable compares the `question_index` from `/start`'s `question_context` against the total competency count; when no competencies remain (all positions consumed), the state transitions directly to `done` instead of `end_of_question`. No `203` variant exists — `/end` always returns `200`. | Pinia store; legacy module-scope singleton (`proctor.ts`) | Composables returning objects are unit-testable with mocked providers/timers; module singletons leak state across tests and Nuxt requests. `proctor-config.ts` touches no browser globals → safe to import anywhere, matching the legacy "shared by client + server" property. |
| **D4** | Completion-phrase contract (**C7a ADDENDUM — cross-slice**) | Frontend consumes `question_context.end_phrase` and `question_context.final_phrase` (project-language strings) from `/start`. It keeps ONLY the matcher (`matchesEndPhrase`, ported accent/case/punctuation-insensitive), never the phrase literals. **Requires C7a to add these two fields** — see Interfaces. | Hardcode legacy IT phrases; frontend translates phrases; separate `/phrases` endpoint | Legacy hardcoded `'Grazie per il tuo tempo.'` never matches an `en` avatar → HeyGen hangs on the last question. The avatar is *told* the phrase server-side (via provider context), so the same source must feed the listener. Single-sourcing at `/start` is the only consistent option. |
| **D5** | Browser gate (SA-11) | `app/middleware/browser-gate.global.ts`. **Detection split — server vs client:** (a) Server side (`useRequestHeaders(['user-agent'])`): detects Firefox UA (predicate: `/Firefox\//i` case-insensitive) and known-mobile UA strings (predicate: `/Mobi|Android|iPhone|iPad/i`). On the server, viewport width is NOT detectable from HTTP headers — pass `Infinity` to `isSupportedBrowser` as the width argument so only the UA check applies server-side. (b) Client side (`import.meta.client`): reads `navigator.userAgent` for Firefox + viewport width `window.innerWidth < 1024` (DESIGN.md §6: 768–1023 px = tablet = unsupported; ≥1024 px = desktop). A reactive `window.resize` listener MUST be attached — **this listener lives INSIDE `useInterviewSession`** (which owns the `provider` instance), NOT in `browser-gate.global.ts` (a router guard with no provider access). The composable attaches its own resize listener that flushes integrity (sendBeacon) + calls `provider.stop()` then triggers navigation to `/unsupported`. The middleware only handles route-entry gating. The resize listener MUST be removed on transition to `done`/`terminal`/`error` to prevent calling `provider.stop()` on an already-stopped provider (which is non-fatal but noisy). `provider.stop()` errors during resize-triggered teardown are logged and suppressed (non-fatal). On resize, the handler MUST flush the pending integrity batch via `sendBeacon` and call `provider.stop()` BEFORE navigating to `/unsupported`. Both detection paths redirect to `/unsupported`. Early-return (skip) when `to.path.endsWith('/unsupported')` (covers both `/unsupported` and `/en/unsupported`, preventing a redirect loop on the non-default locale path). The Firefox-denylist approach is used (not an allowed-list): the gate explicitly rejects Firefox UA; all other UAs (Chrome/Edge/Opera/Safari) pass. IE11/legacy: these also pass the Firefox denylist by design — no real candidate uses IE11 and the WebRTC/MediaPipe requirements block them at the functionality layer. The gate logic is extracted into a pure testable function `isSupportedBrowser(ua: string, width: number): boolean` so Vitest can cover the UA/viewport combinations without a browser context. SSR-path coverage (request-headers path) comes from Playwright. The `browser-gate.global.ts` middleware wrapper itself is excluded from the Vitest coverage threshold (it is an integration concern). **Font loading:** Open Sans MUST be loaded via self-hosted `@fontsource/open-sans` (GDPR-safe; no Google Fonts runtime call). The exact version MUST be added to the D25 catalog — flagged as a D25 gap below. | Per-page guard; plugin-based; client-only detection; `< 768` cutoff (mismatches DESIGN.md §6 which counts 768–1023 as tablet = unsupported) | Global middleware runs on every navigation on BOTH sides, so SSR blocks Firefox before hydration (no flash). Skip-on-`to.path.endsWith('/unsupported')` prevents a redirect loop for all locale-prefixed variants. Reuses the existing C1 `/unsupported` page + Playwright mobile project. Resize teardown (sendBeacon + provider.stop before navigate) prevents integrity data loss and dangling provider connections. |
| **D6** | Permissions-Policy (**CRITICAL C1 fix**) | Nitro `routeRules`: interview route gets `camera=(self) microphone=(self) geolocation=()`; everything else keeps the locked-down header. BOTH of the following route patterns MUST be covered (i18n `strategy: prefix_except_default`, `defaultLocale: 'it'`): `/interview/**` (default locale, no prefix) and `/en/interview/**` (non-default locale prefix). If additional locale prefixes are added to `nuxt.config.ts`, their `/[locale]/interview/**` patterns MUST be added here too. **Nitro header override semantics: a more-specific route entry REPLACES (not merges) the headers from less-specific entries.** Therefore the per-interview-route entry MUST repeat ALL headers that `/**` sets — omitting any header causes Nitro to drop it on matched routes. Required `nuxt.config.ts` snippet (full header set for interview routes): `'/interview/**': { headers: { 'Permissions-Policy': 'camera=(self) microphone=(self) geolocation=()', 'X-Frame-Options': 'DENY', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'strict-origin-when-cross-origin' } }, '/en/interview/**': { headers: { 'Permissions-Policy': 'camera=(self) microphone=(self) geolocation=()', 'X-Frame-Options': 'DENY', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'strict-origin-when-cross-origin' } }`. **`geolocation=()` MUST be explicitly listed on each interview-route entry.** Because Nitro replaces headers (does not merge), omitting `geolocation=()` from the interview-route entry removes the directive entirely — causing the browser to apply its permissive same-origin default (geolocation allowed same-origin) on those routes. The directive must be present and set to `()` (deny all) to keep parity with the global rule. The global `/**` rule keeps `camera=(), microphone=(), geolocation=()` unchanged. The values above match exactly those in the current `frontend/nuxt.config.ts`. | Global relaxation; meta-tag override; drop the header; per-interview entry sets only `Permissions-Policy` (forgets the other three headers) | Current global `camera=(), microphone=(), geolocation=()` blocks `getUserMedia` app-wide → the device check and proctor camera cannot start. Per-route override grants the capability on the single route that needs it and nowhere else (least privilege). Nitro replace-not-merge semantics mean partial header entries silently drop security headers — all four must be restated. `geolocation=()` must appear explicitly; an omitted directive is dropped entirely by Nitro, which would let the browser apply its permissive same-origin default for geolocation on the interview routes. |
| **D7** | MediaPipe assets (~12MB) | **Commit** `@mediapipe/tasks-vision` WASM + `face_landmarker.task` + `efficientdet_lite0.tflite` under `frontend/public/proctor/` (served same-origin). **Git LFS is MANDATORY** for all binary model assets (`.task`, `.tflite`, WASM blobs). The `@mediapipe/tasks-vision` version and the exact package-relative asset paths to copy into `public/proctor/` MUST be pinned in D25 before committing — **do NOT choose a version without updating D25** (Dependency Resolution Policy hard-stop applies). | Build-time fetch from CDN; runtime CDN load | Same-origin static serving works offline/air-gapped, is deterministic in CI, and avoids a third-party runtime dependency during a live GDPR-sensitive interview. Tradeoff: ~12MB repo weight in `frontend/` (accepted; flagged in risks). Git LFS mandatory for binary blobs. |
| **D8** | API client codegen (**HARD prerequisite + ordering gate**) | Regenerate `frontend/openapi.json` from C7a-merged `api/develop`, then `bunx openapi-typescript openapi.json -o types/api.ts` (per the C1 `codegen` script, `openapi-typescript ^7.0` pinned in D25). Typed client stays in `frontend/types/api.ts` + the existing C1 client wrapper. **Ordering constraint (HARD GATE):** (1) The C7a delta addendum (`end_phrase`/`final_phrase`) MUST be merged into `api/develop` first. (2) `frontend` regenerates `openapi.json` and `types/api.ts` from that merged `api/develop`. (3) ONLY THEN may C7b apply begin. No C7b file that calls an interview endpoint may be written before this gate is cleared — hand-authored request/response types are prohibited by CLAUDE.md contract rule. | Hand-author the 5 endpoint types; point codegen at a local api checkout | Hand-authored types drift from the contract on day one. D4 spec change means `openapi.json` must include `end_phrase`/`final_phrase` before C7b apply — this gates the slice. No request/response types hand-maintained (CLAUDE.md contract rule). |
| **D9** | Color token reconciliation | `main.css` diverges from DESIGN.md on ALL six brand tokens and the font. **Normative values (DESIGN.md §3.1 token table):** `--color-primary: #771AAF` (Quint purple), `--color-primary-light: #C222D3`, `--color-primary-dark: #4F1AAF`, `--color-accent: #E45526` (Quint institutional orange), `--color-accent-light: #F19823`, `--color-accent-dark: #B8431E`. Current `main.css` (navy/teal, WRONG): `--color-primary: #1e3a5f`, `--color-primary-light: #2d5282`, `--color-primary-dark: #132740`, `--color-accent: #0d9488`, `--color-accent-light: #14b8a6`, `--color-accent-dark: #0f766e`. **Font divergence:** `main.css` declares `--font-sans: 'Inter'`; DESIGN.md §3.2 specifies `"Open Sans"` (Quint institutional font). C7b MUST reconcile `--font-sans` to `"Open Sans", ui-sans-serif, system-ui, -apple-system, sans-serif`. **Additional brand tokens in scope for reconciliation (DESIGN.md §3.1):** `--color-lavender: #8373D2` (supporting secondary — subtle highlights, badges) and `--color-bg-gradient: linear-gradient(135deg, #FAF7FD 0%, #F6F1FC 45%, #FDF4EF 100%)` (page background gradient; supersedes flat `--color-neutral-50` for page backgrounds). Both MUST be present in the reconciled `main.css`. **DESIGN.md itself has a defect:** its §4 example block (~line 197-199) and a11y table (~line 485) still show the stale navy/teal values — these are documentation defects. Correcting the DESIGN.md example block and a11y table to reflect the `#771AAF`/`#E45526` brand is a C7b documentation deliverable. **Authoritative source = DESIGN.md §3.1 token table**, NOT the example block. **DESIGN.md §9.1 a11y correction — AUTHORITATIVE contrast ratios for new brand colors on white (implementer MUST re-verify with a contrast tool when writing the DESIGN.md §9.1 correction):**
- `#771AAF` (primary) = **8.2:1** — PASSES WCAG 2.1 AA for normal text.
- `#E45526` (accent) = **3.7:1** — FAILS WCAG 2.1 AA 4.5:1 for normal text; passes only the 3:1 large-text / UI-component bar. Do NOT use for small text on white.
- `#B8431E` (accent-dark) = **5.4:1** — PASSES WCAG 2.1 AA 4.5:1 for normal text; this IS the valid text-sized accent alternative.
- `#C222D3` (primary-light) ≈ **4.7:1** (marginal AA for normal text — verify per use-case before applying to body text).

The corrected §9.1 table MUST carry an explicit caveat: "Do NOT use `--color-accent` (`#E45526`) for small text on white — it fails the 4.5:1 AA threshold for normal text (3.7:1). Use `--color-accent-dark` (`#B8431E`, 5.4:1) for text-sized accent elements." This mirrors the existing error-red note in §9.1. The stale entries (`white / #1e3a5f → 9.2:1` and `white / #0d9488 → 4.6:1`) must be replaced with the verified Quint purple values above. | Follow the navy example block; keep `main.css` navy | The token table is the normative contrast-validated spec; the example/a11y blocks were not updated when the brand switched to Quint purple. Components use semantic tokens (`bg-primary`), so reconciling once fixes every screen. Blindly copying hex values into the a11y table without re-verifying contrast would re-introduce a WCAG AA violation. |
| **D10** | Testing strategy | Vitest: composables (session state machine, retry/backoff, resume), `matchesEndPhrase`, `isSupportedBrowser` (pure function — Firefox UA rejected, Edge/Opera/Chrome/Safari accepted; width < 1024 rejected; width = Infinity passes server-side UA-only check), `proctor-config` purity + `summarizeIntegrity`, provider state machines with **mocked SDK modules** (`vi.mock` the dynamic import). The pure `isSupportedBrowser()` function is held to ~95% Vitest coverage. The `browser-gate.global.ts` middleware wrapper is EXCLUDED from the Vitest threshold — SSR-path coverage is Playwright's. Playwright: chromium + webkit real flow with **network-mocked provider events**; mobile project asserts SA-11 gate (viewport < 1024 px → redirect to `/unsupported`). | Only E2E; only unit; real provider sessions in CI | Coverage per CLAUDE.md: 85% overall, ~95% on the candidate state machine + matcher + `isSupportedBrowser`. Provider SDKs can't run real WebSocket/WebRTC in CI → mock at two layers: `vi.mock` for unit, and a **local mock provider fixture** (`tests/e2e/fixtures/interview-provider.ts`) that emits the HeyGen `AVATAR_TRANSCRIPTION`/`AVATAR_SPEAK_ENDED` and Tavus `tool_call` event sequences deterministically. See Testing Strategy. |
| **D11** | Component architecture | Container/presentational + atomic. Containers = composables + the `[token].vue` page. Presentational = shadcn-vue primitives (`Button`, `Progress`, `Alert`, `Sonner`, `Dialog`, `Empty`, `Skeleton`) with semantic tokens, no literals. **`.client.vue`** only for components that mount browser SDKs/media: `AvatarPlayer.client.vue`, `DeviceCheck.client.vue`, `ProctorOverlay.client.vue`. `Timer`, `Caption`, `ProgressBar`, `IntegrityToast` are pure presentational (SSR-safe, though the page is `ssr:false`). | Everything `.client.vue`; God-page (legacy monolith) | God-page violates the SoC hard-requirement (engineering-excellence / typescript-expert skills). Scoping `.client.vue` to true browser-API components keeps the rest unit-testable with plain Vue Test Utils and reusable in other contexts. shadcn-vue is the project UI convention (memory: nuxt-ui-shadcn-vue). |

## Data Flow

```
   /unsupported ◄── browser-gate.global.ts (SSR UA + client viewport)
        ▲
  navigate /interview/[token]  (ssr:false, Permissions-Policy: camera/mic self)
        │
  ConsentBanner ─► DeviceCheck.client (getUserMedia; camera+mic confirm)
        │  hand off MediaStream (no 2nd getUserMedia)
        ▼
  useInterviewSession ──POST /start─► { session_id, provider, token|url, question_context{end_phrase,final_phrase} }
        │                                   │
        │ createProvider(provider)  ◄───────┘  (dynamic import.meta.client)
        ▼
  HeyGen/TavusProvider ──► AvatarPlayer.client (<video>)
        │  on 'transcript' ──► POST /utterance (202 | 409 drop)
        │  matchesEndPhrase(end|final) ──► state=end_of_question ──► POST /end {completed}
        │                                        │ last competency → backend CAS → in_valutazione
        ▼                                        ▼
  useProctor (visibility/focus + MediaPipe 3FPS + WebAudio RMS)
        ├─ every 10s ──► POST /integrity {events[]}   (batched)
        ├─ every 10s ──► POST /snapshot {image_base64}
        └─ pagehide ──► navigator.sendBeacon(/integrity)
        │
        ▼  all competencies done → /done ; 403 → terminal redirect ; provider 5xx → /error
```

## File Changes

| File | Action | Description |
|---|---|---|
| `frontend/nuxt.config.ts` | Modify | Per-route `routeRules` Permissions-Policy override for `/interview/**` (D6) |
| `frontend/app/assets/css/main.css` | Modify | Reconcile primary/accent tokens to DESIGN.md `#771AAF`/`#E45526` (D9) |
| `frontend/openapi.json` + `frontend/types/api.ts` | Modify | Regenerate from C7a-merged `api/develop` incl. D4 addendum (D8) |
| `frontend/app/pages/interview/[token].vue` | Create | Primary page, `ssr:false`, container |
| `frontend/app/pages/interview/{done,error}.vue` | Create | Done / retryable-error screens |
| `frontend/app/pages/interview/terminal.vue` (or conditional view within `[token].vue`) | Create | Terminal screen (no exit — for `403` + absent-phrase cases). Shows distinct i18n messages: `403` → "session closed" completion message; absent-phrase → "service temporarily unavailable — contact support" with a support-contact affordance (link/email). |
| `frontend/app/types/interview-provider.ts` | Create | Pure-TS `InterviewProvider` iface + event/state types (ported) |
| `frontend/app/providers/{heygen,tavus}.ts` | Create | Client-only dynamic-import SDK implementations |
| `frontend/app/providers/factory.ts` | Create | `createProvider(name)` selection by `/start` `provider` |
| `frontend/app/composables/{useInterviewSession,useProctor,useDeviceCheck,useIntegrityFlush}.ts` | Create | State machine + proctor + device gate + flush |
| `frontend/app/utils/proctor-config.ts` | Create | SSR-safe pure constants + `summarizeIntegrity()` + `matchesEndPhrase` |
| `frontend/app/components/{AvatarPlayer,DeviceCheck,ProctorOverlay}.client.vue` | Create | Browser-SDK/media components |
| `frontend/app/components/{Timer,Caption,ProgressBar,IntegrityToast}.vue` | Create | Presentational (shadcn-vue composition) |
| `frontend/app/middleware/browser-gate.global.ts` | Create | SA-11 Firefox + mobile redirect (D5) |
| `frontend/public/proctor/**` | Create (asset) | MediaPipe WASM + `.task` + `.tflite` (D7) |
| `frontend/i18n/locales/{it,en}.json` | Modify | Interview-flow UI keys |
| `frontend/tests/e2e/fixtures/interview-provider.ts` | Create | Mock provider fixture emitting HeyGen/Tavus event sequences (new file — does not exist in C1 scaffold) |
| `DESIGN.md` | Modify | Correct four stale sections (C7b documentation deliverable): **§4** example block — replace navy `#1e3a5f`/teal `#0d9488` with Quint purple `#771AAF`/orange `#E45526`; **§9.1** a11y table — replace stale contrast rows with verified brand values (see D9 above); **§14** "Preload Inter font" → "Preload Open Sans via `@fontsource/open-sans`"; **§3.2** "sourced via @fontsource/open-sans **or Google Fonts**" → remove "or Google Fonts" option (GDPR: self-hosted `@fontsource/open-sans` is the sole mandated source). These four spots (§4, §9.1, §14, §3.2) are the complete set to correct. |

## Interfaces / Contracts

**Ported provider interface (frontend, pure TS):**

```ts
export type ProviderName = 'heygen' | 'tavus'
export type ProviderState = 'connecting'|'ready'|'listening'|'speaking'|'stopped'|'complete'
export type ProviderEvent = 'transcript' | 'state' | 'error'
export interface TranscriptEntry { role: 'user'|'avatar'; text: string; ts: number; seq?: number }

/**
 * Typed, closed config passed from useInterviewSession → createProvider → provider.start().
 * NO index signature ([k:string]:unknown) — banned under strict + exactOptionalPropertyTypes.
 *
 * API → StartConfig field mapping (from /start 201 response):
 *   provider_token                   → sessionToken    (HeyGen)
 *   conversation_url                 → conversationUrl (Tavus)
 *   question_context.end_phrase      → endPhrase       (both; completion signal for intermediate questions)
 *   question_context.final_phrase    → finalPhrase     (both; completion signal for the last question)
 *
 * IMPORTANT: end_phrase and final_phrase are NESTED inside question_context — they are NOT
 * top-level fields on the /start response. Reading them from the top level yields `undefined`,
 * which triggers the absent-phrase guard and transitions to `terminal`. Always destructure as:
 *   const { end_phrase, final_phrase } = response.question_context
 */
export interface StartConfig {
  dbSessionId: number
  providerSessionId?: string
  sessionToken?: string       // HeyGen — from /start response field `provider_token`
  conversationUrl?: string    // Tavus  — from /start response field `conversation_url`
  endPhrase: string           // inter-question completion phrase (project-language, from /start)
  finalPhrase: string         // final-question completion phrase (project-language, from /start)
}

export interface InterviewProvider {
  start(mountEl: HTMLElement, cfg: StartConfig): Promise<{ providerSessionId?: string }>
  toggleMic(): Promise<void>
  stop(): Promise<void>
  on(evt: ProviderEvent, cb: (payload: unknown) => void): void
  nudgeWrapUp?(): void
}
```

**Completion-phrase matcher signature (lives in `app/utils/proctor-config.ts`):**

```ts
// Takes backend-injected phrases as a parameter — does NOT close over module-level constants.
// phrases are project-language strings from question_context (POST /start response).
// PRECONDITION: both endPhrase and finalPhrase MUST be non-empty strings.
//   If either is absent, the caller (HeyGen provider) MUST NOT call this function —
//   it must instead emit an error event and transition to the terminal state.
export function matchesEndPhrase(
  text: string,
  phrases: { endPhrase: string; finalPhrase: string }
): boolean
```

The function applies accent/case/punctuation-insensitive containment matching (NFD normalize → strip non-alphanumeric → normalize whitespace → `.includes()`). It returns `true` if `text` matches EITHER `endPhrase` OR `finalPhrase`. Both phrases must be present and non-empty before this function is called; the guard lives in the provider, not inside this pure function.

**Browser gate pure testable function (lives in `app/utils/browser-gate.ts` or inline in middleware):**

```ts
// Pure function — no browser globals. Accepts the UA string and viewport width.
// Returns false if:
//   - UA matches the Firefox predicate (/Firefox\//i), OR
//   - UA matches the mobile-device predicate (/Mobi|Android|iPhone|iPad/i), OR
//   - width < 1024 (tablet 768–1023 and mobile < 768 are both unsupported per DESIGN.md §6)
// Server-side callers (SSR path): pass Infinity as width to skip the viewport check
//   (viewport is not available in HTTP headers; UA check still applies).
export function isSupportedBrowser(ua: string, width: number): boolean
```

Firefox predicate: `/Firefox\//i` (case-insensitive; matches `Firefox/` version separator). This is a **Firefox-denylist** gate: Firefox is explicitly rejected; all other desktop UA strings (Chrome/Edge/Opera/Safari) pass. IE11/legacy UAs also pass the Firefox denylist by design — no real candidate uses IE11, and WebRTC/MediaPipe requirements functionally exclude them without a UA check.

**Integrity event field mapping (B9 — frontend internal `type` → API `kind`):**

The legacy `proctor-config.ts` `IntegrityEventInput` uses the field name `type`. The C7a `/integrity` API contract (`openspec/specs/interview-session/spec.md`) uses the field name `kind`. These differ. When building the `POST /integrity` payload, the frontend MUST map its internal event field `type` → `kind`:

```ts
// Internal collector event shape (ported from legacy proctor-config.ts)
interface IntegrityEventInternal { type: IntegrityType; ts: string; meta?: Record<string, unknown> | null }

// API payload shape (C7a contract — POST /integrity body)
interface IntegrityEventPayload { kind: IntegrityType; payload?: Record<string, unknown> | null; ts: string }

// Mapping required before sending:
const payload: IntegrityEventPayload = { kind: event.type, ts: event.ts, payload: event.meta ?? null }
```

Failure to map results in a backend 422 (unknown `kind` field). The generated `types/api.ts` is the authoritative source for the API payload shape after D8 codegen.

**C7a CONTRACT ADDENDUM (cross-slice — must land on `api/develop` before C7b apply):**
`/start` `question_context` MUST additionally return two project-language strings:

```jsonc
"question_context": {
  /* ...existing C7a fields... */
  "end_phrase":   "<project-language string>",  // between-questions completion signal (ILLUSTRATIVE: e.g. IT → "Passiamo alla prossima domanda.", EN → "Let us move on to the next question.")
  "final_phrase": "<project-language string>"   // last-question completion signal      (ILLUSTRATIVE: e.g. IT → "Grazie per il tuo tempo.", EN → "Thank you for your time.")
}
```

> **IMPORTANT — do NOT treat the Italian examples above as literals.** The backend returns
> per-project-language strings at runtime. Hardcoding `"Passiamo alla prossima domanda."` or
> `"Grazie per il tuo tempo."` in the frontend would reintroduce the original IT-only hang bug
> (HeyGen never speaks Italian phrases in an `en`-language session). The frontend MUST NOT store
> any phrase literal; it MUST consume only what `/start` returns.
>
> **Absent-phrase guard:** `matchesEndPhrase` requires BOTH `endPhrase` and `finalPhrase` to be
> present and non-empty before matching. If either field is absent, the HeyGen provider MUST
> immediately emit an `error` event and the state machine transitions to `terminal` (service
> unavailable — contact support), NOT to `error` (retryable). Retrying the same `/start` would
> return the same absent field.

Both localized to the project language (from the candidate JWT lang claim / project config).
The frontend keeps only `matchesEndPhrase(text, { endPhrase, finalPhrase })`. This is additive
on the archived `interview-session` contract; it needs a small coordinated C7a follow-up + a
regenerated `openapi.json`. Until it lands, C7b cannot correctly complete an `en` HeyGen session.

## Testing Strategy

| Layer | What to Test | Approach |
|---|---|---|
| Unit (Vitest) | `useInterviewSession` state machine (all transitions, `429` retry up to 3 total attempts = 1 initial + 2 retries, `409` drop, `403` redirect, resume-on-remount); `matchesEndPhrase` (accent/case/punct, IT+EN; absent phrase → guard fires before fn call); `isSupportedBrowser` (Firefox UA rejected, Edge/Opera/Chrome/Safari accepted; width < 1024 rejected; Infinity passes server-side UA-only path; mobile UA rejected); `proctor-config` purity + `summarizeIntegrity`; provider classes with `vi.mock`ed SDK modules (event → state/transcript mapping, end-phrase → `complete`). The `browser-gate.global.ts` middleware wrapper is EXCLUDED from the Vitest coverage threshold — SSR-path coverage is Playwright's responsibility. | Fake timers, mocked `$fetch`, `vi.mock('@heygen/...')` / `vi.mock('@daily-co/daily-js')` |
| Component (VTU) | `Timer`, `Caption`, `ProgressBar`, `IntegrityToast` rendering + i18n keys; a11y (axe helper) | Vue Test Utils, no browser SDK |
| E2E (Playwright) | Full flow gate→consent→device-check→per-competency→done on **chromium + webkit**; provider events network-mocked via the fixture; mobile project asserts SA-11 `/unsupported` redirect; Permissions-Policy allows camera/mic on `/interview/**` AND `/en/interview/**`; `sendBeacon` flush uses absolute URL built from `runtimeConfig.public.apiBase` and sends `Blob` with `type: 'application/json'` (assert Content-Type). The E2E fixture (`tests/e2e/fixtures/interview-provider.ts`) is **injected** into `createProvider()` via a test-only env flag (`NUXT_PUBLIC_INTERVIEW_PROVIDER_MOCK=true`) that switches the factory to return the mock provider instead of dynamically importing the real SDK. The mock fixture is a `Create` (new file — not present in C1). | Local mock provider fixture emits deterministic HeyGen (`AVATAR_TRANSCRIPTION`,`AVATAR_SPEAK_ENDED`) / Tavus (`conversation.tool_call name=end_interview`) sequences; `page.route` intercepts the 5 endpoints |

Coverage: ≥85% overall; ~95% Vitest threshold scoped to the correctness-critical PURE units only: `isSupportedBrowser`, the `useInterviewSession` state machine, and `matchesEndPhrase`. `sendBeacon` flush, SSR build-isolation, and device-check happy/fail paths are covered by the Playwright/E2E + CI-build tier (not counted in the Vitest ~95% threshold). The `browser-gate.global.ts` middleware wrapper remains excluded from the Vitest threshold.
E2E provider mocking never opens a real WebSocket/WebRTC connection.

## Migration / Rollout

No data migration. Additive within `frontend/`. Rollback = revert the C7b commit range and
restore prior `nuxt.config.ts` / `main.css` / `openapi.json`. Backend rollback only if the D4
C7a addendum was merged and no other slice depends on it.

## Version-Catalog Gaps (Dependency Resolution Policy — D25)

D25 pins `openapi-typescript ^7.0` (present) but has **NO entry** for:
`@heygen/liveavatar-web-sdk`, `@daily-co/daily-js`, `@mediapipe/tasks-vision`, `@fontsource/open-sans`.
Per CLAUDE.md Dependency Resolution Policy these MUST be added to the D25 catalog before
install — do NOT pick versions silently. If a required version cannot be resolved: STOP and
report. This is a hard prerequisite alongside D8 codegen and the D4 addendum.

> **Note on `@fontsource/open-sans`:** This package is required to self-host Open Sans
> (GDPR-safe; eliminates the Google Fonts runtime call). Version MUST be pinned in D25 before
> `bun add`. Do NOT use Google Fonts CDN in the frontend — it constitutes a cross-origin data
> transfer subject to GDPR consent (IP address sent to Google on page load).

## Open Questions

- [ ] **D4 C7a addendum** — confirm and merge `end_phrase`/`final_phrase` on `api/develop`; regenerate `openapi.json` (BLOCKS `en` completion; BLOCKS D8 gate).
- [ ] **Provider SDK + MediaPipe + @fontsource/open-sans versions** — add to D25 catalog (BLOCKS install per Dependency Resolution Policy).
- [ ] **MediaPipe delivery** — Git LFS is MANDATORY (D7); confirm asset paths once D25 version is pinned.
- [x] **Interview route pattern + i18n prefix** — DECIDED (D6): `/interview/**` + `/en/interview/**` (and any future locale prefix) in `routeRules`. Nitro replace-semantics confirmed; all 4 security headers must be restated per route entry.
- [ ] **Proctor cadence** — confirm legacy `SAMPLE_FPS=3` / 10s flush / 10s snapshot is production intent or per-project tunable.
- [ ] **GDPR media retention** (CLAUDE.md open #2) — non-blocking for C7b capture; confirm frontend has no retention obligation beyond shipping snapshots.
- [x] **sendBeacon URL + Content-Type** — DECIDED (W2): `pagehide` flush MUST use an absolute URL built from `runtimeConfig.public.apiBase` (cross-origin production); MUST send a `Blob` with `type: 'application/json'`. Test asserts Content-Type. **Note:** `sendBeacon` has a 64 KB payload cap on Safari; implementation SHOULD check the boolean return value of `navigator.sendBeacon()` and log a warning (with a degradation note) if it returns `false`.
- [x] **E2E mock provider DI** — DECIDED (W3): `NUXT_PUBLIC_INTERVIEW_PROVIDER_MOCK=true` env flag switches the `createProvider()` factory to the test fixture. `tests/e2e/fixtures/interview-provider.ts` is a new Create (not Modify).

## Implementation Notes

- **Tasks-phase gate — codegen pre-flight:** Before any composable file calling an interview
  endpoint is written, the tasks description MUST include a pre-flight check confirming that
  `frontend/types/api.ts` contains the five `/api/candidate/interview/*` endpoint types
  (including `end_phrase`/`final_phrase` in `question_context`). This check is deferred to the
  tasks phase, not enforced here.

- **`sendBeacon` 64 KB Safari cap:** Safari's implementation of `navigator.sendBeacon` caps the
  payload at 64 KB. If the pending integrity batch exceeds that limit (very unlikely in normal
  use but possible if flush cadence was interrupted), the beacon MAY silently fail. The
  implementation SHOULD check the boolean return value and log a warning if `false`, allowing
  ops to diagnose integrity data gaps post-session.

- **IE11/legacy UA pass-through by design:** IE11 and other legacy browsers pass the Firefox
  denylist because `/Firefox\//i` does not match their UA strings. This is intentional — no real
  candidate uses IE11, and the WebRTC/MediaPipe/ES2020 requirements block them at the
  functionality layer. Documenting this assumption prevents the gate from being re-flagged at
  code review as a missing case.

- **iPadOS 13+ Safari desktop UA:** iPadOS 13+ requests the desktop version of sites by default
  and sends a Mac-like UA string (`Macintosh; Intel Mac OS X`), not `iPad`. This means
  server-side UA mobile-detection misses iPadOS devices. The client-side `window.innerWidth < 1024`
  viewport check catches them at the client gate. Do not rely on server-side UA inspection alone
  to block tablet traffic; the client-layer viewport check is the authoritative tablet gate.

- **CI locale-pattern guard:** CI SHOULD assert that the number of `routeRules` interview-route
  entries (patterns like `/[locale]/interview/**`) matches the count of non-default locales in
  `i18n.locales`. This guards against locale additions (es/fr/de/pt) that land without a
  corresponding `routeRules` Permissions-Policy entry, which would silently leave those routes
  with the locked-down `camera=()` header.
