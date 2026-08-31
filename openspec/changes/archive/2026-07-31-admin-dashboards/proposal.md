# Proposal: Admin Dashboards (C11)

## Intent

`ROADMAP.md:44` frames C11 as "build in the backoffice (SPA) Nuxt app". That framing is
wrong in two structural ways, both verified against code:

**1. The admin read API does not exist.** `api/app/Http/Controllers/Api/` contains exactly
two controllers — `FrameworkController.php` and `ProjectController.php` (enumerated via
`Glob("api/app/Http/Controllers/**/*.php")`). `api/routes/api.php` registers no admin
participant, evaluation, transcript, or download route. C10 already documented this gap
first-hand: `openspec/changes/webhooks-integration/design.md:302` ("no evaluation or
transcript read endpoint exists … without inventing an endpoint C11 owns") and
`api/app/Services/Webhooks/EvaluationPayloadAssembler.php:161-166`, whose `files` block
ships `{type, ref}` pairs with no resolvable URL for exactly this reason.
**C11 is a full-stack slice.** The data model is ready; the HTTP read layer is absent.

**2. The binding lifecycle read-gate has zero enforcement.** `CLAUDE.md` binds transcript
reads to lifecycle ≥ `in_valutazione` and structured-evaluation reads to `completato`. The
only status guard in the codebase, `api/app/Http/Middleware/ParticipantStatusGuard.php:37-68`,
is candidate-side **write** gating on `/api/candidate/interview/*`; its own docblock (`:21-27`)
states it deliberately does not apply to reads. There is no precedent to copy.

Success: an operator can log into the backoffice, find a candidate, watch their lifecycle
state, and read/download the BARS report and transcript — never earlier than the lifecycle
permits, and never across a tenant boundary.

## Verified current state

| Claim | Evidence |
|---|---|
| Backoffice is the bare C1 skeleton | `Glob("backoffice/app/**/*")` → exactly 4 files: `app.vue`, `assets/css/main.css`, `pages/health.vue`, `pages/unsupported.vue`. No `middleware/`, `layouts/`, `components/`, `composables/`. |
| No auth, no UI kit | `backoffice/package.json:22-27` — 4 runtime deps (`@nuxtjs/i18n`, `nuxt`, `vue`, `vue-router`). No `reka-ui`, `shadcn-vue`, `@heroicons/vue`, no state library. |
| Generated client is stale | `backoffice/openapi.json:13` — one path, `/health`. Regen script `package.json:19`, drift check `:20`. |
| `Participant` is **not** tenant-scoped | `api/app/Models/Participant.php:55` `extends Model`; docblock `:23-25` "Does NOT extend TenantModel". |
| `Evaluation`/`CompetencyResult`/`IndicatorScore`/`Utterance`/`InterviewSession` **are** | `Evaluation.php:42`, `CompetencyResult.php:43`, `IndicatorScore.php:43`, `Utterance.php:32`, `InterviewSession.php:60` — all `extends TenantModel`. |
| `frontend` already runs shadcn-vue | `frontend/package.json:31-36` (`shadcn-vue`, `reka-ui`, `class-variance-authority`, `clsx`, `tailwind-merge`) + `@theme inline` bridge at `frontend/app/assets/css/main.css:73-109`. |
| Backoffice design tokens are **stale vs DESIGN.md** | `backoffice/app/assets/css/main.css:8` `--color-primary: #1e3a5f`, `:11` `--color-accent: #0d9488`, `:36` `--font-sans: 'Inter'` — vs `DESIGN.md:56,59,111` (`#771aaf`, `#e45526`, Open Sans). `frontend/app/assets/css/main.css:14,17,49` already matches. Backoffice-only drift. |
| Reusable server-side pieces exist | `api/app/Services/Scoring/TranscriptAssembler.php:34-47`, `ReliabilityRenderer.php:29-33` (round-before-cast, D4 FIX-1). |

## Scope

### In Scope

**API (`api` submodule)** — new admin route group under `auth:api` + `TenantContext`,
mirroring `api/routes/api.php:66-68`:

| Endpoint | Gate |
|---|---|
| `GET /api/participants` (paginated; filters `project_id`, `status`, search) | RBAC only |
| `GET /api/participants/{id}` (detail + lifecycle timeline) | RBAC only |
| `GET /api/participants/{id}/transcript` | lifecycle ≥ `in_valutazione` |
| `GET /api/participants/{id}/evaluation` (BARS report) | lifecycle `completato` |
| `GET /api/participants/{id}/transcript/download` (`text/plain`) | same as read |
| `GET /api/participants/{id}/evaluation/download` (`application/json`) | same as read |
| `GET /api/dashboard/metrics` (org KPI summary) | RBAC only |

Plus: `ParticipantPolicy`, `EvaluationPolicy`, a shared lifecycle read-gate, an admin
evaluation serializer reproducing `docs/app_description/03-ux-reference/evaluation-report-example.json`,
Pest feature tests, Scramble annotations. Final task (gated on C10 merging): add the
additive `url` key to `EvaluationPayloadAssembler::renderFiles()` per the C10 contract at
`openspec/changes/webhooks-integration/design.md:309,460`.

**Backoffice (`backoffice` submodule)**
- Design-token reconciliation of `backoffice/app/assets/css/main.css` to `DESIGN.md` §3.
- shadcn-vue init + Reka UI + Heroicons v2, organized per `DESIGN.md:279-316` Atomic Design.
- Auth: login page, token storage, refresh handling, `$fetch` Bearer interceptor, route guard.
- SA-11 viewport gate middleware wiring `/unsupported` (`DESIGN.md:319-334`).
- App shell (sidebar + top nav, `DESIGN.md:421-437`), dashboard, participant list, participant
  detail, BARS report viewer, downloads.
- Full `it`/`en` i18n key set; `Intl.*` formatting (`DESIGN.md:547-548`).
- Client regeneration (`bun run codegen`), drift check green.
- Vitest per component, Playwright E2E (chromium + webkit + mobile SA-11 project).

**DESIGN.md** — update §8.3 before implementing the report viewer (see Risk R1).

### Out of Scope (explicit)

- **Webhook config / replay UI** — C10 read model plus later work; C10 is in flight.
- **Notifications / reminders** — C12.
- **GDPR retention, purge, deletion-request UI, data-management view** (`DESIGN.md:450,563`) — C13, gated by open product decision #2.
- **PDF export** (`DESIGN.md:565` says "JSON/PDF … C11/C12") — a PDF renderer is not in the D25 version catalog. C11 ships **JSON only**; PDF deferred.
- **Per-question audio download** — the storage does not exist and is gated by decision #2. Snapshots exist (`api/app/Models/InterviewSnapshot.php:34`) but are proctoring artifacts under the same GDPR gate → not exposed.
- **Subscription / MRR / trial-conversion metrics** demanded by `openspec/specs/observability/spec.md:325-331` — no billing schema exists (`rg -i "subscription|billing|mrr|trial|plan"` over `api/database/migrations` → only an unrelated hit in `2026_07_22_000003_create_indicator_scores_table.php`). C11 ships only DB-backed usage + AI-cost metrics (`ai_requests` table exists: `2026_07_22_000004_create_ai_requests_table.php`).
- **Settings / user-management / API-key UI** (`DESIGN.md:448`) — deferred; C11 delivers read-oriented views.
- **`frontend` submodule** — untouched.

## Capabilities

### New Capabilities
- `admin-read-api`: admin-authenticated, org-scoped HTTP read surface for participants, transcripts, evaluations, downloads, and dashboard metrics — including the lifecycle read-gate.
- `admin-backoffice`: backoffice SPA shell, auth session, navigation, participant views, BARS report viewer, SA-11 gate wiring, i18n.

### Modified Capabilities
- `observability`: narrow the C11 obligation at `spec.md:308-331` — subscription/MRR/trial-conversion metrics move to a future billing slice; C11 owns usage + AI-cost metrics only.
- `tenancy`: new requirement — admin HTTP reads of **non-`TenantModel`** entities MUST apply an explicit `organization_id` filter; `withoutGlobalScopes()` is forbidden in HTTP context.

## Approach

**D1 — Two distinct tenant-scoping patterns, not one.** The brief's "always use
`findOrFail()` after `TenantContext`" holds only for `TenantModel` subclasses. `Participant`
is a plain `Model` (`Participant.php:55`), so `Participant::findOrFail($id)` applies **no
scope at all** and would return another org's row with 200. Admin participant reads MUST use
the explicit-filter pattern already proven at `api/app/Http/Controllers/M2m/ParticipantController.php:90,110`
(`Participant::where('organization_id', $orgId)->findOrFail($id)`). Evaluation, CompetencyResult,
IndicatorScore, Utterance and InterviewSession use the `ProjectController.php:115` pattern.

**Trap to avoid:** `EvaluationPayloadAssembler.php:46,48,69,112` uses `withoutGlobalScopes()`.
That is correct in its queued-job context (no ambient tenant resolver) and **catastrophic** if
copied into an HTTP admin controller. `TranscriptAssembler.php:37` carries the same hazard: it
is safe only because its `InterviewSession` was resolved under scope by the caller. A new admin
serializer must be written against scoped queries, not copy-pasted.

**D2 — The read-gate lives in a policy, not middleware, not the query layer.**

| Option | Verdict |
|---|---|
| **Policy** (`ParticipantPolicy::viewTranscript` / `viewEvaluation`), backed by a shared `LifecycleReadGate` value object stating each threshold once | **Chosen.** Per-resource, per-ability — the two gates differ (`≥ in_valutazione` vs `= completato`). Composes with the existing Spatie RBAC checks (`ProjectPolicy.php:30-65`) so there is exactly one authorization decision point and one 403. Reusable outside HTTP; unit-testable without a request. |
| Route middleware (à la `ParticipantStatusGuard`) | Rejected. That guard reads `auth()->user()` as the Participant itself (`:50`); the admin participant is a route parameter, so middleware would duplicate tenant resolution before the controller. It would also need per-route parameterization for two different thresholds, and it cannot express "operator may, viewer may not" without re-implementing RBAC. |
| Query-layer / global scope | Rejected. Turns "not ready yet" into "does not exist" (404), which is the wrong signal for a same-org record, and would leak into the job and webhook paths that legitimately read pre-terminal data. |

**Fail-closed:** an unrecognized status denies. **Status codes:** cross-org → `404` (never
reveal existence); same-org but not yet readable → `403` with a machine-readable, non-localized
`reason` code, consistent with `ParticipantStatusGuard.php:59-64` and the `CLAUDE.md`
machine-facing-responses rule. (`409 Conflict` is arguably more semantically honest; rejected
for consistency with the existing precedent — reopen at design if desired.)

**D3 — Component strategy: shadcn-vue, arranged into DESIGN.md's Atomic Design tree.**
`DESIGN.md:279-316` specifies file **structure and rules** (atoms take only props, emit only
events; every component gets a Vitest test), not component **provenance**. shadcn-vue copies
source into the repo, which lands naturally in `components/atoms/BaseButton.vue`. This is not a
new call: `frontend` already ships it (`frontend/package.json:31-36`). Reka UI is the a11y
primitive layer; **Heroicons v2** per `DESIGN.md:634` replaces the shadcn default icon set.
CLI via `bunx --bun` — Bun only, never npm/pnpm/yarn/npx.

**Token gotcha (verified):** shadcn's `@theme inline` block redefines `--color-primary` as
`var(--primary)` (`frontend/app/assets/css/main.css:99`), and `--primary` is still the shadcn
default `oklch(0.205 0 0)` (`:119`) — a neutral grey, chroma 0. In `frontend` today, `bg-primary`
is therefore **not** Quint purple despite `:14` defining it. Copying that file wholesale would
render the backoffice sidebar (`DESIGN.md:435`, "`--color-primary` background") grey. C11 must
map the brand palette into shadcn's semantic OKLCH variables, not merely append the bridge.

**D4 — Server-driven list.** `GET /api/participants` paginates and filters server-side
(matching `M2m/ParticipantController.php:92`). Every page is a fresh authorized query, which is
the tenant-safe construction; a fetch-all client-side filter would enlarge the payload and the
blast radius. Purpose-built `CandidateTable.vue` / `EvaluationReport.vue` per `DESIGN.md:304-305`
— no generic DataTable abstraction until a second consumer exists (YAGNI).

**D5 — Report rendering correctness.** Indicator scores are the discrete set `{1,3,5}`;
`-1` means **unassessable** and is **excluded** from the competency mean. Verified in the
reference: `evaluation-report-example.json:362-393` — `SLF` has `5, 3, -1`, `reliability "67%"`,
`score 4.0` = mean(5,3). The viewer MUST render `-1` as a distinct "no evidence" treatment,
never as a numeric chip on a 1–5 colour scale. `reliability` arrives pre-rendered as a percent
string (`EvaluationPayloadAssembler.php:146`).

**Git Flow:** `feature/admin-dashboards` off `develop` in **both** `api` and `backoffice`;
wrapper pins the two submodule commits.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Http/Controllers/Api/ParticipantController.php`, `EvaluationController.php`, `DashboardController.php` (names TBD at design) | New | Admin read surface |
| `api/app/Policies/ParticipantPolicy.php`, `EvaluationPolicy.php` | New | RBAC + lifecycle gate |
| `api/app/Support/` (lifecycle read-gate) | New | Threshold stated once |
| `api/app/Http/Resources/`, `api/app/Services/` | New | Admin serializers (scoped, not copied from the webhook assembler) |
| `api/routes/api.php` | Modified | New `auth:api` + `TenantContext` group after `:68` |
| `api/app/Services/Webhooks/EvaluationPayloadAssembler.php:161-187` | Modified (last, C10-gated) | Additive `url` key |
| `backoffice/app/assets/css/main.css` | Modified | Reconcile to `DESIGN.md` §3 + shadcn OKLCH mapping |
| `backoffice/app/{layouts,pages,components,composables,middleware}/**` | New | Entire admin UI |
| `backoffice/i18n/locales/{it,en}.json` | Modified | Full key set |
| `backoffice/openapi.json`, `backoffice/types/api.ts` | Modified | Regenerated; drift check green |
| `backoffice/package.json` | Modified | shadcn-vue, reka-ui, `@heroicons/vue`, `@fontsource/open-sans` |
| `DESIGN.md` §8.3 | Modified | Fix the BARS example (R1) |
| `openspec/specs/observability/spec.md:308-331` | Modified | Narrow C11's metric obligation |

## Risks

| # | Risk | Likelihood | Mitigation |
|---|---|---|---|
| R1 | **DESIGN.md §8.3 contradicts the binding scoring model.** `DESIGN.md:462-464` shows indicator scores `[4] [3] [4]` and `[2] [3] [2]`; `:472` colours chips `1–2 = error, 3 = warning, 4–5 = success`. Values 2 and 4 **cannot exist** under `{1,3,5}`, and `-1` has no treatment. | **CRITICAL** | `DESIGN.md:3-6` forbids implementing anything that contradicts it, and §17 requires updating it first. Fix §8.3 (3-value chip scale + explicit unassessable state) as the first design task, before any viewer code. |
| R2 | Cross-tenant leak from applying the `TenantModel` pattern to `Participant` | **CRITICAL** | D1. ~95% coverage on tenant scoping; a cross-org 404 test per endpoint; a test asserting no `withoutGlobalScopes()` in `App\Http`. |
| R3 | Premature disclosure of a transcript or evaluation before the lifecycle permits | **CRITICAL** | D2, fail-closed; ~95% coverage; a matrix test over all 5 statuses × both gated endpoints. |
| R4 | Backoffice ships on the wrong brand palette | High | Reconcile `main.css` in the first UI PR; assert brand tokens in a Vitest test; the shadcn `@theme inline` override is a known trap (D3). |
| R5 | Diff blows past the 400-line review budget | High | Chained PRs: (1) API read endpoints + gate + policies; (2) tokens + shadcn init + auth + shell + SA-11 gate; (3) participant list/detail; (4) report viewer + downloads + i18n; (5) C10-gated `url` key. `sdd-tasks` produces the binding forecast. |
| R6 | Client drift — `types/api.ts` stale, CI red | Medium | Regenerate via `bun run codegen` in the same PR as each API change; `codegen:check` in CI. |
| R7 | C10 in flight touches `EvaluationPayloadAssembler` and `webhook_deliveries` | Medium | Sequence the `url` task last and rebase; do not modify `api` files C10 owns until it merges. |
| R8 | Backoffice `README.md` is still the unedited Nuxt starter | Low | Rewrite alongside the app shell. |

## Rollback Plan

Two feature branches, no schema migrations, no data change, no deploy. API changes are purely
additive routes/controllers/policies — reverting the merge commit on `api/develop` removes them
with no residue. Backoffice changes are additive except `main.css` and `package.json`; both
revert cleanly (only `health.vue` and `unsupported.vue` consume tokens today, and neither
references brand colours). Wrapper rollback = reset the two submodule pointers. The `DESIGN.md`
§8.3 and observability spec edits are documentation and revert independently.

## Dependencies

- **C9 `scoring-engine`** (merged) — supplies `Evaluation` / `CompetencyResult` / `IndicatorScore`.
- **C2 `tenancy-identity`** (merged) — `auth:api`, `TenantContext`, Spatie teams-mode RBAC.
- **C4 `project-configuration`**, **C6 `participant-sso`**, **C8 `interview-conversation`** (merged) — projects, participants, utterances.
- **C10 `webhooks-integration`** (in flight) — only the final `url`-key task depends on it. Everything else is independent.
- New deps (Bun): `shadcn-vue`, `reka-ui`, `class-variance-authority`, `clsx`, `tailwind-merge`, `@heroicons/vue`, `@fontsource/open-sans` — all already proven in `frontend`. Pin per D25; a blocked resolution is an open question, not an implementation choice (D37).

## Success Criteria

- [ ] An operator logs into the backoffice with a JWT, lists org participants, opens one, and reads the BARS report and transcript.
- [ ] Cross-org `participant_id` returns **404** on every new endpoint — including the plain-`Model` participant path (D1).
- [ ] Transcript returns 403 for `in_attesa` / `in_corso`, 200 from `in_valutazione` onward.
- [ ] Evaluation returns 403 for every status except `completato`.
- [ ] An unrecognized status denies (fail-closed test).
- [ ] The report viewer renders `-1` as "unassessable", excluded from the competency mean; `SLF`-shaped fixture (`5,3,-1` → `4.0`, `67%`) renders correctly.
- [ ] `DESIGN.md` §8.3 updated before the viewer ships; no chip renders a value outside `{1,3,5,unassessable}`.
- [ ] `backoffice/app/assets/css/main.css` brand tokens equal `DESIGN.md` §3, and `bg-primary` resolves to `#771aaf` through the shadcn bridge.
- [ ] Mobile Playwright project: every admin route redirects to `/unsupported`.
- [ ] `bun run codegen:check` green; `types/api.ts` covers every new endpoint.
- [ ] E2E locators role-based, zero CSS class/id selectors; axe clean.
- [ ] Coverage: 85% overall in both submodules; ~95% on tenant scoping and the read-gate.
- [ ] `nuxi typecheck` clean; PHPStan L8 clean on new files; zero hardcoded user-facing strings.

## Proposal question round

Written here because this executor has no direct user channel. Assumptions taken; correct any
before spec.

1. **PDF export.** Assumed **deferred** — `DESIGN.md:565` hedges "C11/C12" and no PDF renderer is in the D25 catalog. C11 ships JSON only. Confirm the client does not need PDF in this slice.
2. **Dashboard metrics.** Assumed C11 surfaces only usage + AI-cost metrics; MRR, trial conversion and subscription growth (`observability/spec.md:325-331`) are deferred because no billing schema exists. Confirm, or a billing slice becomes a C11 blocker.
3. **Gate status code.** Assumed `403` + machine-readable reason (matching `ParticipantStatusGuard`). `409 Conflict` is more semantically honest for "not ready yet". Confirm the preference.
4. **`DESIGN.md` §8.3 chip scale.** Assumed a 3-value scale (`1 = error, 3 = warning, 5 = success`) plus a neutral "unassessable" state for `-1`. The competency-mean thresholds at `:473` also need restating for a `{1,3,5}` domain. Confirm the intended visual mapping.
5. **Settings / user management.** Assumed out of scope (`DESIGN.md:448` lists it, but it is write-heavy admin CRUD, not a dashboard). Confirm C11 stays read-oriented.
6. **Delivery.** Assumed 5 chained PRs across two submodules to respect the 400-line review budget. Confirm, or accept a `size:exception`.
