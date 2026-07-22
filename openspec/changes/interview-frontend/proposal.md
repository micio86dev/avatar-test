# Proposal: Interview Frontend (C7b)

## Intent

C7a shipped the backend session mechanics (5 candidate endpoints behind `ParticipantStatusGuard`,
server-side provider tokens, lifecycle `in_attesa→in_corso→in_valutazione`) but a candidate still
**cannot take an interview** — there is no UI to join the avatar, speak, be proctored, or advance
through competencies. C7b delivers the candidate-facing **Nuxt 4 (Vue 3) SSR** app that makes the
C7a mechanics usable: it ports the legacy Astro avatar/proctoring kernel to Vue composables, gates
the experience to supported desktop browsers (SA-11), runs the pre-join device check, drives the
live interview loop (avatar player, timer, captions, proctoring collection, snapshot + integrity
flush), and consumes the C7a contract in the project language.

One session = one competency question, played in the fixed C4 order. Adaptivity is C8, BARS scoring
is C9, webhook delivery is C10, admin review is C11 — none of them belong here.

## Scope

### In Scope

- **Provider abstraction port** — `InterviewProvider` interface (pure TS) with two concrete
  implementations behind dynamic client-only SDK imports: HeyGen (`@heygen/liveavatar-web-sdk`,
  conversational mode, barge-in) and Tavus (`@daily-co/daily-js`, audio-only room). Provider chosen
  by the C7a `/start` response, not hardcoded.
- **Browser-support gate (SA-11)** — global route middleware redirecting Firefox and mobile
  viewports to the existing `/unsupported` page (SSR user-agent + client `navigator` detection);
  the page and E2E scaffold already exist, the middleware does not.
- **Pre-join device check** — camera (live video track) + mic (spoken-above-threshold) confirmation
  gate before fullscreen entry, handing the camera stream off to proctoring without a second
  `getUserMedia`.
- **Live interview UI** — avatar player (`.client.vue`), per-question countdown timer, live caption,
  proctoring collector, periodic snapshot + integrity flush, plus the flow screens:
  end-of-question / pause-resume (client-driven) / done / error.
- **Proctoring collector** — port of the 3-layer legacy proctor (browser visibility/focus, MediaPipe
  FaceLandmarker at 3 FPS + head pose, Web Audio RMS second-voice) as `useProctor`, with the pure
  constants + `summarizeIntegrity()` as an SSR-safe shared util. Cadence identical to legacy
  (`FLUSH_INTERVAL_MS=10_000`, `SNAPSHOT_INTERVAL_MS=10_000`, `SAMPLE_FPS=3`).
- **i18n (it/en)** of all UI chrome (device-check instructions, timer, integrity warnings, competency
  transitions, error states), locale selected from the C6 candidate JWT language claim.
- **Localized completion-signal consumption** — the frontend consumes localized `end_phrase` /
  `final_phrase` from the backend and matches them accent/case/punctuation-insensitively (see the
  resolved decision below).
- **Two critical C1 fixes** — Permissions-Policy per-route override for the interview path, and
  reconciliation of `main.css` color tokens to the authoritative DESIGN.md palette.

### Out of Scope

- **C8 (conversation / adaptive)** — adaptive question selection, AI follow-ups within a competency,
  mid-session question injection.
- **C9 (scoring)** — `summarizeIntegrity()` *computation trigger*, BARS score display, competency
  scores. (The pure `summarizeIntegrity()` util may be ported for reuse, but the frontend never
  computes or renders scores.)
- **C10 (webhooks)** — not a frontend concern.
- **C11 (admin review / dashboards)** — backoffice.
- **GDPR media retention policy** (open decision #2) — storage TTL is a backend/ops concern, unchanged
  by C7b; the frontend only captures and ships snapshots.
- **Server-enforced `pause_every_n_competencies`** — no backend column exists; C7b implements the
  pause/resume *code path* with client-side state only.

## Capabilities

### New Capabilities

- `interview-frontend`: candidate SSR app delivering the browser gate, device check, live avatar
  interview loop, proctoring collection, integrity/snapshot flush, localized flow screens, and the
  provider abstraction consuming the C7a contract.

### Modified Capabilities

- **`interview-session` (C7a) — contract addendum (cross-slice prerequisite).** The `/start`
  `question_context` payload must additionally carry the localized `end_phrase` and `final_phrase`
  in the project language (see Resolved Decision). This is an additive field on an existing,
  already-archived contract — it requires a coordinated small C7a follow-up change / `api/develop`
  tweak, tracked as a hard prerequisite below. No other C7a behavior changes.

## Resolved Decision — Completion-signal phrases injected by backend

The HeyGen completion-signal phrases (the inter-question **end phrase** and the final **thank-you
phrase**) will be **injected by the backend in the project language**, NOT hardcoded Italian in the
frontend as the legacy demo did (`HEYGEN_END_PHRASE = 'Passiamo alla prossima domanda.'`,
`HEYGEN_FINAL_PHRASE = 'Grazie per il tuo tempo.'`).

- **Why**: with an `en` project, the avatar speaks English and the hardcoded Italian phrase would
  never match `matchesEndPhrase()`, so the HeyGen interview would hang on the last question. The
  completion signal is a coupling between what the avatar is told to say and what the frontend
  listens for; it must be language-consistent and single-sourced.
- **Contract implication**: `/start`'s `question_context` must include localized `end_phrase` and
  `final_phrase`. The frontend keeps only the *matching logic* (accent/case/punctuation-insensitive
  containment), never the phrase strings.
- **Cross-slice tracking**: this is a C7a follow-up (additive field). C7b's spec and implementation
  depend on it landing on `api/develop` and being reflected in the regenerated `openapi.json`.

## Approach

**Composable-first, page-shell pattern** (exploration Approach A — chosen over the legacy God-page
monolith, which violates the SoC hard-requirements in the engineering-excellence / typescript-expert
skills):

- **Interview page** `pages/interview/[token].vue` with `definePageMeta({ ssr: false })`. The route
  is session-gated and `noindex`, so SSR provides no value; all its APIs (WebRTC, WebAudio,
  MediaPipe) are browser-only. The token derives from the C6 magic-link JWT claim.
- **`useInterviewSession`** composable owns the session state machine
  (`idle → device_check → connecting → live → end_of_question → paused → done | error | terminal`),
  calls the 5 C7a endpoints in order, and handles resume, `429 provider_busy` retry (3s backoff,
  max 3), `409` silent-drop (both `/utterance` and `/end`), and the `403` terminal redirect.
- **`useProctor`** composable owns all browser-side integrity collection and returns an object (not
  module-scope singletons) for testability; MediaPipe is dynamically imported client-only.
- **`InterviewProvider`** interface is pure TS; concrete `heygen.ts` / `tavus.ts` live under
  `app/providers/` and are dynamically imported under `import.meta.client`. `AvatarPlayer.client.vue`
  wraps the `<video>` mount. Any accidental SSR import of a provider SDK crashes the Nitro build, so
  the client-only boundary is a hard invariant.
- **UI** composed from **shadcn-vue** primitives with **semantic tokens** (`bg-primary`,
  `text-muted-foreground`) — no raw color values — over the reconciled DESIGN.md palette. All copy is
  i18n-keyed; no literals in components.
- **Permissions-Policy fix** via Nitro `routeRules`: `camera=(self) microphone=(self)` on the
  interview route only, `camera=(), microphone=(), geolocation=()` elsewhere.

Detailed component/composable APIs, the exact route pattern, the MediaPipe asset layout, and the
provider event maps are deferred to design.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `frontend/nuxt.config.ts` | Modified (CRITICAL) | Per-route Permissions-Policy override (Nitro `routeRules`); global `camera=(), microphone=()` currently blocks getUserMedia everywhere |
| `frontend/app/assets/css/main.css` | Modified (CRITICAL) | Reconcile `--color-primary` etc. to authoritative DESIGN.md palette (`#771AAF` Quint purple), replacing diverged `#1e3a5f` navy |
| `frontend/openapi.json` + `frontend/types/api.ts` | Modified (PREREQUISITE) | Regenerate from C7a-merged `api/develop` so the 5 interview endpoints are typed (currently health-only) |
| `frontend/app/pages/interview/[token].vue` | New | Primary deliverable, `ssr:false` |
| `frontend/app/pages/` (done / error / device-check) | New | Terminal + pre-join flow pages |
| `frontend/app/components/` | New | `AvatarPlayer.client.vue`, `DeviceCheck`, `Timer`, `Caption`, `ProctorOverlay`, `IntegrityToast`, `ProgressBar` (shadcn-vue composition) |
| `frontend/app/composables/` | New | `useInterviewSession`, `useProctor`, `useDeviceCheck`, `useIntegrityFlush` |
| `frontend/app/middleware/browser-gate.global.ts` | New | SA-11 Firefox + mobile redirect to `/unsupported` |
| `frontend/app/providers/{heygen,tavus}.ts` + `app/types/interview-provider.ts` | New | Provider abstraction port (client-only dynamic import) |
| `frontend/app/utils/proctor-config.ts` | New | SSR-safe pure constants + `summarizeIntegrity()` |
| `frontend/public/proctor/**` | New (asset) | MediaPipe WASM + model binaries (`face_landmarker.task`, `efficientdet_lite0.tflite`) as static assets |
| `frontend/i18n/locales/{it,en}.json` | Modified | Interview-flow UI keys |
| `frontend/tests/e2e/**` + Playwright projects | Modified | Real interview-provider mock fixture; chromium/webkit full flow + mobile-gate assertion |
| `legacy-demo/src/providers/`, `src/lib/proctor-config.ts`, `scripts/` | Read-only | Port source of truth |

**Constraints in force**: desktop-only (Chrome/Edge/Opera/Safari; Firefox + mobile excluded → gate),
HTTPS required for getUserMedia, GDPR consent (existing `ConsentBanner.vue`), voice latency < 2–3s,
`noindex` on the interview surface, tenant isolation inherited from the candidate JWT.

## Cross-slice Dependencies / Prerequisites

1. **openapi codegen (HARD)** — `frontend/openapi.json` + `types/api.ts` must be regenerated from
   C7a-merged `api/develop` before spec/apply, or the 5 endpoints stay untyped and the client drifts
   from day one.
2. **C7a `question_context` localized-phrase addendum (HARD)** — the Resolved Decision requires
   `end_phrase` / `final_phrase` in `/start`. Coordinated small C7a follow-up on `api/develop`,
   reflected in the regenerated spec.
3. **MediaPipe static assets** — WASM + `.task` + `.tflite` binaries (~12MB total) served from
   `public/proctor/`; committed or fetched at build time (strategy decided at design).
4. **Two critical C1 fixes** — Permissions-Policy per-route override and color-token reconciliation
   (both in scope, listed here because they unblock everything else).

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Permissions-Policy blocks getUserMedia app-wide | High (present) | Per-route Nitro override for the interview path; verify before any media request |
| Provider SDK accidentally imported in SSR → Nitro crash | Med | 100% client-only boundary: `.client.vue` + `import.meta.client` dynamic imports; SSR renders a skeleton |
| Stale `openapi.json` (health-only) → type drift | High (present) | Codegen from C7a-merged `api/develop` as a gating prerequisite |
| Completion-phrase language mismatch hangs last question | High (if unaddressed) | Resolved: backend injects localized `end_phrase`/`final_phrase`; frontend keeps only matcher |
| MediaPipe asset delivery (~12MB binaries) | Med | Static `public/proctor/`; commit-vs-build-fetch decided at design |
| E2E interview mock infra (WebSocket/WebRTC events) | Med | Real stub fixture simulating HeyGen/Tavus protocol events at the Playwright layer |
| WebKit gaps: `screen.isExtended` undefined, fullscreen decline | Med | Graceful guards (legacy already guards `isExtended === true`); fullscreen degrades without breaking the flow |
| Color-token divergence visible in every component | Med | Reconcile `main.css` to DESIGN.md `#771AAF` before building components |

## Rollback Plan

Additive within the `frontend/` submodule: new pages, components, composables, middleware,
providers, utils, and static assets. Rollback = revert the C7b commit range on the `frontend`
feature branch (drops the new files) and restore the prior `nuxt.config.ts` / `main.css` /
`openapi.json`. No backend rollback beyond reverting the C7a `question_context` addendum if it was
merged and no other slice depends on it. No data migration.

## Dependencies

- **C7a** `interview-session` — the 5 candidate endpoints, `ParticipantStatusGuard`, lifecycle
  transitions, provider token issuance (DELIVERED + archived + merged to `api/develop`).
- **C6** `participant-sso` — candidate JWT (language claim), `GET /api/candidate/session` bootstrap,
  magic-link token.
- **C4** `project-config` — competency order the interview walks.
- **C1** `project-skeleton-ci` — Nuxt 4 SSR scaffold, i18n, Tailwind v4, Playwright projects,
  `ConsentBanner.vue`, `/unsupported` page.
- Sources: `docs/app_description/` (binding), `DESIGN.md` (authoritative UX/UI), legacy-demo
  `src/providers/`, `src/lib/proctor-config.ts`, `scripts/{proctor,device-check}.ts` (port source of
  truth, read-only).

## Open Questions (close before / at spec)

1. **MediaPipe asset strategy** — commit the ~12MB binaries to `frontend/public/proctor/` vs
   build-time fetch? (Repo weight vs build-network dependency.)
2. **GDPR media retention** (CLAUDE.md open decision #2) — not blocking C7b capture, but confirm the
   frontend has no retention obligation beyond shipping snapshots.
3. **Proctoring capture cadence** — confirm the legacy `SAMPLE_FPS=3` / 10s flush / 10s snapshot
   cadence is the intended production cadence, or whether it should be tunable per project.
4. **Exact provider SDK versions** — pin `@heygen/liveavatar-web-sdk` and `@daily-co/daily-js`
   versions against the D25 catalog (Dependency Resolution Policy: STOP on conflict, do not
   downgrade/substitute).
5. **Interview route URL pattern** — final route shape (`/interview/[token]` vs query token) drives
   the exact Nitro `routeRules` Permissions-Policy pattern.

## Success Criteria

- [ ] A supported-desktop candidate can complete the full flow: gate → consent → device check →
      fullscreen → per-competency avatar sessions → done screen, calling the 5 C7a endpoints in order.
- [ ] Firefox and mobile viewports are redirected to `/unsupported` by global middleware (SSR + client),
      never reaching the interview page; mobile Playwright project asserts the gate.
- [ ] Permissions-Policy allows camera/mic on the interview route only; getUserMedia succeeds there and
      the pre-join device check confirms both devices before fullscreen.
- [ ] Provider selection is driven by the `/start` response; both HeyGen and Tavus paths work; provider
      SDKs are client-only and the SSR build succeeds without them.
- [ ] Completion is detected via the backend-injected localized `end_phrase` / `final_phrase` (matched
      accent/case/punctuation-insensitively); an `en` project's last question completes correctly.
- [ ] Proctoring collects the 13 integrity kinds and flushes every 10s; snapshots every 10s; `pagehide`
      flush via `sendBeacon`; `409`/`202` handled per contract.
- [ ] `openapi.json` + `types/api.ts` regenerated from C7a-merged `api/develop`; the 5 endpoints are
      typed and consumed through the generated client (no hand-authored request/response types).
- [ ] `main.css` tokens reconciled to DESIGN.md (`#771AAF` primary); UI uses shadcn-vue semantic tokens.
- [ ] All UI copy i18n-keyed (it/en), locale from the candidate JWT language claim; no literals in
      components.
- [ ] Terminal participants (`403 ParticipantStatusGuard`) redirect to the done/terminal screen.
- [ ] Coverage ≥ 85% overall; candidate state-machine paths held to ~95%; Pest/Vitest/Playwright all
      run in CI for chromium + webkit + mobile-gate.
