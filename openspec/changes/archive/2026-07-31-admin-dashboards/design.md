# Design: Admin Dashboards (C11)

## Verification log

Every claim below was opened in this session. Nothing is inherited from the proposal untested.

| Claim | Evidence |
|---|---|
| `Project` is tenant-scoped; `Participant` is NOT | `api/app/Models/Project.php:49` (`extends TenantModel`) vs `api/app/Models/Participant.php:55` (`extends Model`). `api/app/Models/TenantModel.php:22` is the abstract base. |
| The global scope + create stamp live in one trait | `api/app/Models/Concerns/TenantScoped.php:39-49` (scope), `:62-75` (unconditional stamp, throws `MissingTenantContextException` on null org) |
| Scoring entities ARE tenant-scoped | `Evaluation.php:42`, `CompetencyResult.php:43`, `IndicatorScore.php:43`, `InterviewSession.php:60` |
| Safe admin pattern for a plain `Model` | `api/app/Http/Controllers/M2m/ParticipantController.php:90` (index), `:110-111` (show) — explicit `where('organization_id', $orgId)->findOrFail()` |
| Unsafe pattern that must not be copied | `api/app/Services/Webhooks/EvaluationPayloadAssembler.php:46,48,69,112` and `api/app/Services/Scoring/TranscriptAssembler.php:37` — `withoutGlobalScopes()`, correct only in the queued-job context documented at `EvaluationPayloadAssembler.php:25-28` |
| Only 2 `Api/` controllers, no admin read routes | `api/app/Http/Controllers/Api/{FrameworkController,ProjectController}.php`; `api/routes/api.php:52-68,174-179` — no participant/evaluation/transcript/download/metrics route |
| No lifecycle READ gate anywhere | `api/app/Http/Middleware/ParticipantStatusGuard.php:37-68` is candidate-side WRITE gating on `/api/candidate/interview/*` (`routes/api.php:147-149`), blocking only the two TERMINAL statuses (`:45`). `api/app/Support/` holds only `Tenancy/{TenantResolver,TenantContextScope}.php` + `Jwt/CandidateTokenFactory.php` — no gate. |
| Only 2 policies exist | `api/app/Policies/{ProjectPolicy,ApiClientPolicy}.php`. `ProjectPolicy.php:30-65` = Spatie `hasRole` checks, no org filter. |
| Org context is derived server-side only | `api/app/Http/Middleware/TenantContext.php:43-44` reads `$user->organization_id` from the DB, never from the JWT. Registered globally on the `api` group at `api/bootstrap/app.php:30`. |
| Central exception→status convention exists | `api/bootstrap/app.php:51-64` (`ParticipantTransitionException`→422, `CompositionException`→422 with machine-readable `error` code) |
| Participant status is a plain string, no enum | `Participant.php:54` (`@property string $status`), `api/app/Enums/` contains only `EvaluationStatus`, `WebhookEventType`, `WebhookDeliveryStatus`, `WebhookSkipReason` |
| Transcript is per-SESSION, and a participant has MANY sessions | `TranscriptAssembler.php:34` takes one `InterviewSession`; `InterviewSession.php:48-49` carries `question_index` + `competency_code`; `ScoreEvaluationJob.php:335-338` loads one session per competency |
| `competency.score` is nullable by design | `CompetencyResult.php:39` (`@property float|null $score`), `:67` "CC2 — all-indicators-(-1) → NULL score" |
| Reference report shape confirmed, including `-1` | `docs/app_description/03-ux-reference/esempio-report-valutazione.json:2-37` (COL: 5,3,3 → `"score": 3.67`, `"reliability": "100%"`) and `:374-392` (SLF: 5,3,**-1** → `"score": 4.0`, `"reliability": "67%"`) |
| `ai_requests` has NO cost column | `2026_07_22_000004_create_ai_requests_table.php:54-61` — `input_tokens`, `output_tokens`, `latency_ms` only. No price/currency anywhere. |
| Participants indexes are org-lead | `2026_07_20_000001_create_participants_table.php:66-67` — `(organization_id, project_id)`, `(organization_id, status)` |
| JWT TTL + denylist | `api/config/jwt.php:108` `ttl=30` (min), `:127` `refresh_ttl=20160` (14 d), `:227` `blacklist_enabled=true`. Rotation semantics: `AuthController.php:42-48,86-98`. API issues **no cookie** — `AuthController.php:181-186` returns JSON only. |
| Backoffice is the bare C1 skeleton | `backoffice/package.json:22-27` (4 runtime deps: `@nuxtjs/i18n`, `nuxt`, `vue`, `vue-router`); `backoffice/nuxt.config.ts:9` `ssr:false`, `:56-60` `runtimeConfig.public.apiBase` already present but empty |
| Playwright projects already correct | `backoffice/playwright.config.ts:35-50` — `chromium`, `webkit`, `mobile` (Pixel 7, `testMatch: **/unsupported-gate.spec.ts`), `:24-26` screenshot tolerance |
| Drift check regenerates from the COMMITTED snapshot | `backoffice/scripts/check-client-drift.sh:13-15`; the snapshot itself comes from `php artisan scramble:export` (`api/.github/workflows/ci.yml:104-105`). **No task/script copies `api/openapi.json` → `backoffice/openapi.json`** — searched `Taskfile.yml` (no `openapi`/`codegen`/`scramble` match) and both `package.json` files. |
| SA-11 gate already solved in `frontend` | `frontend/app/utils/browser-gate.ts:28-47` (pure predicate) + `frontend/app/middleware/browser-gate.global.ts:23-46` |
| `frontend` deviates from DESIGN.md on icons | `frontend/package.json:27` uses `@lucide/vue`; `DESIGN.md:646` mandates Heroicons v2. Backoffice follows DESIGN.md. |

### R6 — theme correctness, verified first-hand

Both halves of the proposal's claim are **TRUE**, and the second is worse than reported.

1. **`backoffice/app/assets/css/main.css` is stale.** `:8` `--color-primary: #1e3a5f` (navy), `:11` `--color-accent: #0d9488` (teal), `:36` `--font-sans: 'Inter'` — against `DESIGN.md:199,202,234` (`#771aaf`, `#e45526`, Open Sans). It is also **missing** `--color-lavender` and `--color-bg-gradient` (`DESIGN.md:207-210`) and has no `@fontsource/open-sans` import (`DESIGN.md:191`).
2. **The shadcn bridge in `frontend` shadows the brand tokens.** `frontend/app/assets/css/main.css:14` sets `--color-primary: #771aaf` inside `@theme`, then `:99` re-declares `--color-primary: var(--primary)` inside `@theme inline`, and `:119` sets `--primary: oklch(0.205 0 0)` — a chroma-0 near-black. Last declaration wins for utility generation, so **`bg-primary` in `frontend` today is dark grey, not Quint purple.** The same shadowing hits `--color-accent` (`:18` `#e45526` → `:93` `var(--accent)` → `:125` `oklch(0.97 0 0)`, near-white) and all four `--radius-*` keys (`:63-66` → `:106-109` `calc(var(--radius) …)`).

Copying that file into `backoffice` would ship a grey sidebar and a near-white accent. D10 fixes it.

## Technical Approach

C11 is a full-stack slice across two submodules. On the API side it adds one admin read group behind `auth:api` + `TenantContext`, built on **two new invariants that are enforced by types, not by discipline**: (a) every admin participant read goes through a single resolver that *cannot be called without naming a lifecycle read scope*, and (b) that resolver is the only sanctioned way to obtain a `Participant` inside `App\Http\Controllers\Api`. On the backoffice side it turns the C1 skeleton into a real SPA: brand tokens reconciled and correctly bridged into shadcn, Bearer-JWT session with single-flight refresh, SA-11 gate ported from `frontend`, and a BARS report viewer whose chip vocabulary is exactly `{1, 3, 5, unassessable}` per the corrected `DESIGN.md:473-485`.

Conforms to `openspec/specs/tenancy/spec.md` and the proposal's D1–D5, and **reverses the proposal's tentative choice on the gate status code** (D4) — the proposal itself flagged that decision as reopenable.

## Sequence

```
Backoffice SPA (origin A)                       API (origin B)
  useApi() $fetch ──Authorization: Bearer──▶ auth:api  (JWT guard, jti denylist)
       │  401 → single-flight /auth/refresh          │
       │                                     TenantContext (bootstrap/app.php:30)
       │                                       orgId ← DB user.organization_id
       │                                       setPermissionsTeamId(orgId)
       │                                             │
       │                                    Admin\ParticipantController
       │                                             │
       │                        AdminParticipantReader::read($id, ReadScope::Evaluation)
       │                          (1) Participant::where('organization_id', $resolver->getOrgId())
       │                                            ->findOrFail($id)      → cross-org = 404
       │                          (2) $this->authorize('view', $participant) → RBAC = 403
       │                          (3) LifecycleReadGate::assert($p->status, $scope)
       │                                 unknown status → deny (fail-closed)
       │                                 not ready     → LifecycleNotReadyException → 409
       │                                             │
       │                                    Evaluation/CompetencyResult/IndicatorScore
       │                                      (TenantModel — global scope, plain findOrFail)
       ◀───────────── JSON / text/plain download ────┘
```

## Architecture Decisions

### D1 — Tenant safety: a typed reader, not a documented convention

`final class App\Support\Admin\AdminParticipantReader` (new; `App\Support\` currently holds only `Tenancy/` and `Jwt/` — verified by glob) is the **single** entry point for admin participant reads:

```php
public function read(int $participantId, ParticipantReadScope $scope): Participant
```

There is no zero-argument overload and no default for `$scope`. A developer adding a sixth read endpoint physically cannot obtain a `Participant` without naming a read scope, and naming a scope applies the org filter and the lifecycle threshold in the same call. Internally it is exactly the `M2m/ParticipantController.php:110-111` pattern — `Participant::where('organization_id', $resolver->getOrgId())->findOrFail($id)` — with `TenantResolver` injected, so a null/bypass org is visible at one place instead of six.

| Option | Tradeoff | Decision |
|---|---|---|
| Typed reader with a mandatory `ReadScope` parameter | Forgetting it is a **type error at compile/PHPStan-L8 time**, not a runtime leak. One place to test to ~95%. Reusable from the download endpoints and any future console command. | **CHOSEN** |
| Base controller (`AdminReadController`) with a protected helper | Inheritance is opt-in: a new controller that extends `Controller` instead silently opts out of tenancy. No signal at review time. | Rejected |
| Make `Participant` extend `TenantModel` | Would fix reads globally — and break the candidate guard. `Participant.php:23-25` documents why it is a plain `Model`: it is the *authenticatable subject* of `auth:api-candidate`, and a global scope evaluated during guard resolution runs before `TenantContextCandidate` has set the resolver. Out of scope for a read slice; a C13-class refactor with its own risk. | Rejected |
| Arch test only ("no `Participant::` in `App\Http`") | **Honestly the weakest option.** It is a lint that fires after the code is written, is trivially silenced with an ignore entry, gives no guidance at authoring time, and cannot express *which* org filter is correct. It catches the mistake; it does not prevent it. | Rejected as the mechanism — **kept as a backstop** |

Two Pest arch tests remain as defence in depth, not as the design: (1) no `withoutGlobalScopes(` token anywhere under `app/Http/`; (2) no direct `Participant::` static call under `app/Http/Controllers/Api/`. Both are cheap and would have caught the exact hazard at `EvaluationPayloadAssembler.php:46`.

### D2 — Where the lifecycle read-gate lives: a pure value object, invoked from the reader

`App\Support\Admin\LifecycleReadGate` states each threshold **once**:

```php
enum ParticipantReadScope { case Summary; case Transcript; case Evaluation; }
```

| Scope | Minimum lifecycle | Source |
|---|---|---|
| `Summary` | none (RBAC only) | list/detail |
| `Transcript` | `in_valutazione` **or later** | `CLAUDE.md` read gates |
| `Evaluation` | exactly `completato` | `CLAUDE.md` read gates |

Ordering is an explicit ordered list `['in_attesa','in_corso','in_valutazione','completato']` — `errore` is deliberately **absent** from that list, because it is terminal-failed, not "further along". Any status not in the map (including `errore` and any future value) **denies**. There is no `?? true` branch; the method's only success path is an explicit match, mirroring the "explicit terminal keys, never `?? []` fallthrough" discipline already argued at `Participant.php:97-100`.

| Option | Tradeoff | Decision |
|---|---|---|
| Pure gate object called from the mandatory reader (D1) | Two different thresholds expressed as data; unit-testable with zero HTTP; unreachable-to-forget because the reader demands the scope | **CHOSEN** |
| Policy ability (`viewTranscript`/`viewEvaluation`) — the proposal's D2 | A policy conflates *who may* with *when it is readable*. Both collapse into one 403 and the backoffice loses the ability to distinguish "you lack the role" from "not scored yet". It is also forgettable: `$this->authorize()` is a call a new endpoint can simply omit. **Policies are still used — for RBAC only** (D3). | Rejected as the lifecycle mechanism |
| Route middleware, à la `ParticipantStatusGuard` | That guard reads the participant from `Auth::guard('api-candidate')->user()` (`:50`); here the participant is a route parameter, so middleware would have to resolve and tenant-filter it *before* the controller, then hand it over — duplicating D1 or bypassing it. It would also need per-route parameterisation for two thresholds. | Rejected |
| Query layer / global scope | Turns "not ready yet" into "does not exist" (404) for a same-org record, and would leak into `ScoreEvaluationJob` / `EvaluationPayloadAssembler`, which legitimately read pre-terminal data. | Rejected |

### D3 — RBAC stays in a policy, matching C4

New `ParticipantPolicy` (`viewAny`, `view`) and `EvaluationPolicy` (`view`) following `ProjectPolicy.php:30-41` verbatim: all three roles read, no owner filter. Authorization runs **inside** `AdminParticipantReader::read()`, after the org filter and before the lifecycle gate, so the order of failure signals is fixed for every endpoint: `404` (not yours) → `403` (not your role) → `409` (not yet).

### D4 — HTTP status for a gated read: **409 Conflict**, with a machine-readable body

The caller is an authenticated admin of the owning organization; the resource exists; the denial is **temporal and self-resolving** — the same request with the same credentials will succeed once scoring completes, with no change to identity, role, or grant.

| Code | Semantics | Verdict |
|---|---|---|
| `409 Conflict` | "request conflicts with the current state of the target resource" — the state *is* the lifecycle | **CHOSEN** |
| `403 Forbidden` | "the server understood and refuses to authorize" — implies a permission problem and that retrying is pointless. It would be indistinguishable from the D3 RBAC denial, so the backoffice could not tell "you're a viewer without rights" from "come back in 4 minutes". | Rejected |
| `404 Not Found` | Lies to an authorized caller about a record they can already see in the list, and makes an "evaluation in progress" state impossible to render. | Rejected |

The proposal picked 403 "for consistency with `ParticipantStatusGuard.php:59-64`". Examined, that precedent argues the other way: that guard blocks the two **terminal** statuses (`:45`) — a permanent condition where 403 is right. C11's gate blocks **pre-terminal** statuses, the exact inverse. Consistency with a precedent whose semantics are inverted is not consistency.

Body (non-localized per the CLAUDE.md machine-facing rule, mirroring `bootstrap/app.php:59`):

```json
{ "error": "lifecycle_not_ready",
  "resource": "evaluation",
  "current_status": "in_corso",
  "required_status": "completato" }
```

`current_status` is safe to disclose: cross-org requests already 404'd in D1, and the participant list exposes the same field to the same caller. Implementation: `LifecycleNotReadyException` registered in `api/bootstrap/app.php` alongside the three existing renders (`:51-64`) — one registration, every present and future endpoint covered.

### D5 — Admin read API surface

All under `Route::middleware(['auth:api', TenantContext::class])` in a new group appended after `routes/api.php:68`, following the C4 comment-block convention. Controllers in `App\Http\Controllers\Api\`, resolving IDs manually (never route-model binding) for the reason documented at `ProjectController.php:23-28`.

| Method / path | Scope | Success | Notes |
|---|---|---|---|
| `GET /api/participants` | — | 200 paginated | filters `project_id`, `status`, `q`; `per_page` 1–100, default 20 |
| `GET /api/participants/{id}` | `Summary` | 200 | detail + lifecycle timeline (`started_at`, `completed_at`, session count) + `files` map |
| `GET /api/participants/{id}/transcript` | `Transcript` | 200 JSON | ordered utterances grouped by session |
| `GET /api/participants/{id}/evaluation` | `Evaluation` | 200 JSON | BARS report, shape of `esempio-report-valutazione.json` |
| `GET /api/participants/{id}/transcript/download` | `Transcript` | 200 `text/plain` | D9 |
| `GET /api/participants/{id}/evaluation/download` | `Evaluation` | 200 `application/json` | D9 |
| `GET /api/dashboard/metrics` | — | 200 | D7 |

**Pagination and filtering are server-driven** (`paginate()`, matching `M2m/ParticipantController.php:92`).

| Option | Tradeoff | Decision |
|---|---|---|
| Server-side offset pagination + server-side filters | Every page is a fresh authorized query, so tenant scope is re-proved per request; payload bounded; the existing `(organization_id, project_id)` and `(organization_id, status)` composites (`…create_participants_table.php:66-67`) serve the filters directly | **CHOSEN** |
| Fetch-all + client-side filter | One query returns the org's entire participant history to the browser — larger blast radius on any auth mistake, unbounded payload, and it puts a data-volume decision in the client | Rejected |
| Cursor/keyset pagination | Better at scale, but no endpoint today needs deep paging and it complicates the typed client. YAGNI. | Deferred |

Sorting is **fixed** (`created_at desc, id desc`) — not client-specifiable, so there is no column name reaching the query builder. Neither composite index covers that sort; per-org participant volumes make this a non-issue today, so **no migration in C11** — revisit with an additive `(organization_id, created_at)` index if `EXPLAIN` shows a sort spill.

### D6 — Serializers: written against scoped queries, never reused from the webhook assembler

`EvaluationPayloadAssembler` is off-limits as a base class: its `withoutGlobalScopes()` calls are correct *only* under the queued-job contract documented at `:25-28`. New `App\Services\Admin\AdminEvaluationSerializer` + `AdminTranscriptSerializer` read through the ordinary global scope (`Evaluation`, `CompetencyResult`, `IndicatorScore` all extend `TenantModel`), eager-load `competencyResults.indicatorScores` (no N+1), and reuse only the two pure collaborators: `ReliabilityRenderer` (percent string, `EvaluationPayloadAssembler.php:146`) and the `project_competencies.position` ordering (`:119-123`).

Transcript is the one genuinely new assembly: `TranscriptAssembler.assemble()` takes a **single** `InterviewSession` (`:34`) but a participant has one session per competency (`InterviewSession.php:48-49`, `ScoreEvaluationJob.php:335-338`). `AdminTranscriptSerializer` iterates the participant's sessions ordered by `question_index`, then `id`, and within each session applies the same `orderBy('ts')->orderBy('id')` dual sort whose necessity is argued at `TranscriptAssembler.php:11-14`. It does **not** call `withoutGlobalScopes()`.

### D7 — Dashboard metrics: DB-backed usage only, no billing, no currency

`GET /api/dashboard/metrics` returns participants by status, evaluations by status, completion rate, and — from `ai_requests` — summed `input_tokens`/`output_tokens` and p50/p95 `latency_ms`, all org-scoped.

**Correction to the proposal:** it promised "usage + AI-cost metrics". There is **no cost column** — `2026_07_22_000004_create_ai_requests_table.php:54-61` stores tokens and latency only, and no price table exists anywhere in `api/database/migrations`. C11 therefore ships **token usage**, not monetary cost. Subscription/MRR/trial metrics (`openspec/specs/observability/spec.md:308-331`) stay deferred per the orchestrator's ruling 3 — no billing schema exists.

### D8 — Report viewer component architecture

Mapped onto `DESIGN.md:279-316`. shadcn-vue source lands in `components/ui/**` (matching `frontend/app/components/ui/**`); the Atomic Design tree wraps it, so the DESIGN.md file structure and shadcn's copy-in model coexist rather than compete (Engram `sdd/admin-dashboards/scope-and-ui-strategy`, ruling 2).

| Layer | Component | Responsibility |
|---|---|---|
| atom | `ScoreChip.vue` | one indicator score — the `{1,3,5,unassessable}` vocabulary |
| atom | `CompetencyMean.vue` | the nullable mean, or `–` |
| atom | `ReliabilityBadge.vue` | pre-rendered percent string |
| atom | `StatusBadge.vue` | lifecycle status, i18n-labelled |
| molecule | `CompetencyRow.vue` | code + name + mean + reliability + chip strip |
| molecule | `ExcerptList.vue` | verbatim excerpts, `--font-mono` (`DESIGN.md:487`) |
| organism | `EvaluationReport.vue` | the `<table>`, `<caption>`, per-competency rows |
| organism | `CandidateTable.vue` | list + filters + pagination |
| organism | `SidebarNav.vue`, `NavBar.vue` | shell (`DESIGN.md:421-437`) |

**Accessibility of the chip scale — non-color cue is mandatory (WCAG 2.1 AA 1.4.1).** Each chip renders three independent signals: (a) the **numeral itself** as visible text — `1`, `3`, `5`, or `–` for unassessable; (b) a Heroicons v2 glyph, `aria-hidden`, distinct per level; (c) the semantic color. Color is the *third* signal, never the only one. Every chip carries a visually-hidden i18n label — `$t('report.chip.low')` / `.mid` / `.high` / `.unassessable` — so a screen reader hears "3, partially meets" rather than "3". `-1` is **never** printed: it renders `–` (en dash) on the muted/neutral token, outside the error/warning/success scale, per `DESIGN.md:477-479`. A competency whose indicators are all unassessable has `score === null` (`CompetencyResult.php:39,67`) and renders `–`, never `0` (`DESIGN.md:484-485`). The chip strip is a `<ul>` with an `aria-label` naming the competency, so the row is navigable rather than an opaque run of boxes.

A purpose-built `CandidateTable.vue` — no generic DataTable abstraction until a second consumer exists (YAGNI, and `DESIGN.md:304-305` names both components explicitly).

### D9 — Downloads

| Aspect | Decision |
|---|---|
| Content types | transcript `text/plain; charset=utf-8`; evaluation `application/json` |
| Streaming vs buffering | **Buffered.** JSON must be complete to be valid, and a transcript is bounded (≤ ~18 sessions × a few KB). Streaming would add a generator and a partial-failure mode for a payload measured in tens of KB. Revisit above ~1 MB. |
| Filename | `beai-{transcript\|evaluation}-{candidate_ref}-{YYYYMMDD}.{txt\|json}` |
| Header safety | `candidate_ref` is **externally supplied and opaque** (`Participant.php:46`) — it must be `Str::slug()`-ed and emitted with RFC 5987 `filename*=UTF-8''…` alongside an ASCII `filename=` fallback. Interpolating it raw into `Content-Disposition` is a header-injection bug. |
| Gate | Identical scope to the corresponding read endpoint — same `AdminParticipantReader::read()` call, so a 409 body is returned instead of a file. The backoffice must not blind-`window.open` these; it fetches, inspects status, then triggers the blob. |
| `files` extensibility | The detail endpoint returns `files` as an **open map** keyed by type: `{ transcript: {type, ref, url}, evaluation_raw: {…} }`. Adding `audio` later is a new key, never a shape change — matching the receiver contract already documented at `EvaluationPayloadAssembler.php:161-166`. Per-question audio does not exist and stays gated by open product decision #2. |

Last task in the slice, **after C10 merges**: add the additive `url` key to `EvaluationPayloadAssembler::renderFiles()` (`:170-187`), absolute via `config('app.url')`. Until then C11 touches no C10-owned file.

### D10 — Theme wiring so `bg-primary` is genuinely Quint purple

Fix in `backoffice/app/assets/css/main.css`, in three parts:

1. **Reconcile the `@theme` block** to `DESIGN.md:196-256` verbatim — including `--color-lavender`, `--color-bg-gradient`, Open Sans — and add `@import '@fontsource/open-sans';` as the first line (`DESIGN.md:191`).
2. **Do NOT copy the six colliding keys into `@theme inline`.** The bridge block is added for shadcn, but `--color-primary`, `--color-accent`, and `--radius-{sm,md,lg,xl}` are **omitted** from it. Those six are precisely the keys that `frontend/app/assets/css/main.css:93,99,106-109` re-aliases and thereby shadows. Omitting them means `bg-primary` compiles against the `@theme` literal `#771aaf`, full stop.
3. **Set shadcn's `:root` semantic variables to brand values** so the two paths agree and any component using `var(--primary)` directly still lands on brand: `--primary` = Quint purple, `--primary-foreground` white (8.2:1, `DESIGN.md:506`), `--accent` = Quint orange, `--sidebar` = purple with white foreground (`DESIGN.md:435`), `--destructive` = `#b91c1c` not `#ef4444` (`DESIGN.md:514` forbids the latter as text), `--radius` = `0.5rem` so shadcn's `calc()` family stays inside the DESIGN.md scale. Neutrals (`--background`, `--muted`, `--border`) map onto the DESIGN.md slate ramp.

| Option | Tradeoff | Decision |
|---|---|---|
| Omit the colliding keys from `@theme inline` **and** brand-map shadcn's `:root` | Both resolution paths yield the brand color, so there is no "which one wins" question. Survives `shadcn-vue add`. | **CHOSEN** |
| Keep the full bridge, only brand-map `:root` | Works, but leaves two live definitions of `--color-primary` in one file — the exact configuration that produced the `frontend` bug. A future edit to the `@theme` literal would silently do nothing. | Rejected |
| Copy `frontend/app/assets/css/main.css` wholesale | Imports the confirmed bug. | Rejected |

OKLCH conversions must be produced by a converter at apply time, **not** eyeballed. The gate is a test, not a review: a Vitest assertion mounting a `bg-primary` element and asserting the computed background resolves to the brand color, plus a snapshot over the token block. `frontend` carries the same bug — out of C11's scope, filed as a separate follow-up (see Risks).

Per `DESIGN.md:3-6` and §17, the DESIGN.md `@theme` block and both apps' CSS are meant to move together; C11 changes only `backoffice`, so the follow-up is not optional bookkeeping.

Note on the `impeccable` guidance to tint neutrals toward the brand hue: **declined**. `DESIGN.md:74-80` pins a slate neutral ramp and `DESIGN.md:500-514` publishes pre-verified contrast ratios against it. DESIGN.md is binding; re-tinting would invalidate published ratios for a stylistic gain.

### D11 — Backoffice auth wiring

| Aspect | Decision | Rationale |
|---|---|---|
| Transport | `Authorization: Bearer <jwt>` via a `useApi()` `$fetch` wrapper over `runtimeConfig.public.apiBase` (`nuxt.config.ts:56-60`, already present) | `tymon/jwt-auth`, never Sanctum; SPA and API are different origins (`ssr:false`, `:9`) |
| Storage | `sessionStorage` + in-memory mirror | The API issues **no cookie** (`AuthController.php:181-186` returns JSON), so an httpOnly refresh cookie would require new API work + CORS credentials + `SameSite=None` — out of scope. `localStorage` persists across tab close and browser restart for no operational gain; in-memory-only forces a re-login on every F5, which operators will not accept. `sessionStorage` is still XSS-readable — the real mitigations are the existing CSP/security headers (`nuxt.config.ts:42-53`), no `v-html`, and the 30-minute TTL (`config/jwt.php:108`). Recorded as an accepted risk. |
| Refresh | **Single-flight.** One module-scoped in-flight promise; every 401 awaits the same `/api/auth/refresh` call, then retries once. | `AuthController.php:86-98` uses jwt-auth *rotation* and the denylist is on (`config/jwt.php:227`): two concurrent refreshes mean the second presents a jti the first already denylisted → hard 401 and a spurious logout. Concurrency here is not hypothetical — the dashboard fires several parallel requests on mount. |
| Refresh failure | Clear session, redirect to `/login`, surface one toast. Never loop. | |
| Logout | `POST /api/auth/logout` (denylists jti + clears the Spatie cache, `AuthController.php:106-115`), then clear local storage regardless of the response | |
| Org context | **Nothing is sent.** `TenantContext.php:43-44` derives org from the DB user record. `/api/auth/me` (`:123-143`) supplies org name + role names for display and nav visibility only — the server remains the authority. No org switcher in C11 (one `organization_id` per user). | |
| Route guards | `01.browser-gate.global.ts` (port of `frontend/app/utils/browser-gate.ts:28-47`, client branch only — the SPA has no SSR path) then `02.auth.global.ts` | Nuxt orders global middleware by filename; numeric prefixes make it explicit. Belt-and-braces: the auth middleware **also** early-returns on `to.path.endsWith('/unsupported')` and on `/login`, so correctness does not depend on filename ordering. Without this, a mobile visitor would be redirected to `/login` instead of `/unsupported` and SA-11 would fail. |

### D12 — Testing architecture

| Layer | What | How |
|---|---|---|
| Pest — unit | `LifecycleReadGate` | Matrix: 5 statuses (`in_attesa`, `in_corso`, `in_valutazione`, `completato`, `errore`) × 3 scopes, **plus a synthetic unknown status** asserting deny. ~95% coverage. |
| Pest — feature | every new endpoint | Cross-org `participant_id` → 404 on **all seven**, including the plain-`Model` path (D1). Gated reads → 409 + `error: lifecycle_not_ready` before the threshold, 200 after. RBAC: viewer/operator/admin. |
| Pest — arch | tenancy backstop | No `withoutGlobalScopes(` under `app/Http/`; no `Participant::` static call under `app/Http/Controllers/Api/`. |
| Vitest | every component (`DESIGN.md:315`) | `ScoreChip` — one case per value in `{1,3,5,-1}`, asserting the numeral/`–` text and the visually-hidden label, not the color class. `EvaluationReport` — the SLF fixture from `esempio-report-valutazione.json:374-392` (`5,3,-1` → mean `4.0`, reliability `67%`), plus an all-unassessable competency rendering `–` and never `0`. Token test per D10. |
| Playwright — chromium + webkit | login → list → detail → report → download | Role-based locators **only** (`getByRole`, `getByLabel`) — zero CSS class/id selectors. `@axe-core/playwright` (`backoffice/package.json:29`) clean on every view. `toHaveScreenshot` on the report grid; the 2% tolerance is already configured (`playwright.config.ts:24-26`). |
| Playwright — mobile | SA-11 | Existing `mobile` project already restricts to `**/unsupported-gate.spec.ts` (`:46-49`); extend that spec so **every** admin route redirects to `/unsupported`, including while authenticated. |

Coverage: 85% overall in both submodules; ~95% on `AdminParticipantReader` and `LifecycleReadGate`.

### D13 — Client generation

Never hand-maintain types. Every new endpoint gets Scramble annotations and a typed `JsonResource`; the pipeline is `php artisan scramble:export` (`api/.github/workflows/ci.yml:104-105`) → copy `api/openapi.json` → `backoffice/openapi.json` → `bun run codegen` → `bun run codegen:check` green (`backoffice/package.json:19-20`).

**Gap found:** nothing automates the copy step — the wrapper `Taskfile.yml` has no `openapi`/`codegen`/`scramble` task, and `check-client-drift.sh:13` only re-derives `types/api.ts` from the *committed* snapshot. So the drift check can pass while `openapi.json` itself is stale against the API. C11 adds a wrapper task `task openapi:sync` performing export + copy + codegen, so the snapshot has a reproducible provenance. Bun only: `bunx openapi-typescript` (`package.json:19`), never npm/pnpm/npx.

### D14 — Delivery

Five chained PRs across two submodules, per the proposal's R5 and the 400-line review budget. `feature/admin-dashboards` off `develop` in both `api` and `backoffice`; the wrapper pins both. PR order: (1) API gate + reader + policies + endpoints; (2) tokens + shadcn init + auth + shell + SA-11; (3) list/detail; (4) report viewer + downloads + i18n; (5) C10-gated `url` key. `sdd-tasks` owns the binding forecast.

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Support/Admin/AdminParticipantReader.php` | Create | D1 — the only admin participant read path |
| `api/app/Support/Admin/LifecycleReadGate.php` | Create | D2 — thresholds stated once, fail-closed |
| `api/app/Support/Admin/ParticipantReadScope.php` | Create | D2 — the enum that makes the gate unforgettable |
| `api/app/Exceptions/Admin/LifecycleNotReadyException.php` | Create | D4 — 409 + machine-readable body |
| `api/app/Http/Controllers/Api/ParticipantController.php` | Create | list, detail, transcript, evaluation |
| `api/app/Http/Controllers/Api/ParticipantDownloadController.php` | Create | D9 |
| `api/app/Http/Controllers/Api/DashboardController.php` | Create | D7 |
| `api/app/Policies/{ParticipantPolicy,EvaluationPolicy}.php` | Create | D3 |
| `api/app/Services/Admin/{AdminEvaluationSerializer,AdminTranscriptSerializer}.php` | Create | D6 |
| `api/app/Http/Resources/Admin/*.php` | Create | typed responses for Scramble |
| `api/routes/api.php` | Modify | new group after `:68` |
| `api/bootstrap/app.php` | Modify | register the 409 render beside `:51-64` |
| `api/app/Services/Webhooks/EvaluationPayloadAssembler.php` | Modify (last, C10-gated) | additive `url` key at `:170-187` |
| `backoffice/app/assets/css/main.css` | Modify | D10 |
| `backoffice/app/{layouts,pages,components,composables,middleware,utils}/**` | Create | the admin UI |
| `backoffice/i18n/locales/{it,en}.json` | Modify | full key set |
| `backoffice/{openapi.json,types/api.ts}` | Modify | regenerated, drift-check green |
| `backoffice/package.json` | Modify | `shadcn-vue`, `reka-ui`, `class-variance-authority`, `clsx`, `tailwind-merge`, `tw-animate-css`, `@heroicons/vue`, `@fontsource/open-sans`, `@vueuse/core` — versions pinned to the `frontend` resolutions (`frontend/package.json:23-41`); a blocked resolution is an open question, never a downgrade (D37) |
| `backoffice/README.md` | Modify | still the unedited Nuxt starter |
| `Taskfile.yml` | Modify | D13 — `openapi:sync` |
| `openspec/specs/observability/spec.md:308-331` | Modify | narrow C11's metric obligation per D7 |

No migrations. No data change. No deploy.

## Migration / Rollout

No migration required. Reverting the merge commit on `api/develop` removes purely additive routes/controllers/policies with no residue; `backoffice` reverts cleanly (only `health.vue` and `unsupported.vue` consume tokens today, and neither references brand colors). Wrapper rollback = reset the two submodule pointers.

## Open Questions

- [ ] **PDF export** — assumed deferred (`DESIGN.md:577` hedges "C11/C12"; no PDF renderer in the D25 catalog). C11 ships JSON only.
- [ ] **Gate status code** — D4 chooses **409**, reversing the proposal's tentative 403. The proposal explicitly invited this ("reopen at design if desired"). Flagging because it is a public contract shape.
- [ ] **Settings / user management** — assumed out of scope; C11 stays read-oriented.
- [ ] `reliability` thresholds for the High/Medium/Low text badge (`DESIGN.md:462-465` shows the labels; open product decision #1 owns the formula). C11 renders the percent string verbatim as shipped by `ReliabilityRenderer`; the word badge needs a band definition or it is dropped from the viewer.
