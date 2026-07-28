# Tasks: Admin Dashboards (C11)

> Strict TDD active. Correctness-critical zones (~95% coverage): `AdminParticipantReader`,
> `LifecycleReadGate`, tenant-scoping tests. 85% overall in both submodules.
> **Two submodules, two trackers.** `feature/admin-dashboards` (draft/no-merge) off
> `develop` in **both** `api` and `backoffice`. C11 stacks on C10 (`api`, tracker
> `feature/webhooks-integration`, currently unmerged — checked out at `feat/c10-pr4-recorder`)
> ONLY for the deferred last API task (PR A4); everything else is independent and must
> NOT touch any C10-owned file or branch.

## Spec ↔ Design Reconciliation (found during this phase)

`sdd-spec` and `sdd-design` ran concurrently and disagree on **one point**, already
settled by orchestrator ruling #1:

- **Delta spec** `specs/admin-read-api/spec.md` (Requirement: Lifecycle Read-Gate,
  the status table, and 3 scenarios) says the gated-read denial is **`403`** with a
  machine-readable `reason` code.
- **Design** D4 says **`409 Conflict`** with body `{error: lifecycle_not_ready,
  resource, current_status, required_status}`, and explicitly argues the `403`
  precedent (`ParticipantStatusGuard`) is inverted (it blocks *terminal* statuses;
  C11 blocks *pre-terminal* ones).
- **Resolution**: design wins (ruling #1). Task 0.2 below rewrites the spec's status
  table and all 3 affected scenarios to `409` + the machine-readable body, so the
  promoted artifact is accurate.

**Second disagreement found independently** (not in either artifact's own diff, found
by re-reading `DESIGN.md` against D8): `DESIGN.md:462-465` still renders `High` /
`Medium` / `Low` reliability words in the §8.3 mockup, and `:486` says "Reliability:
text badge" — contradicting design D8 (`ReliabilityBadge.vue`: pre-rendered percent
string only) and orchestrator ruling #6 (no band formula exists; open product
decision #1). Task 0.1 fixes this alongside the already-corrected chip-scale text.

No other disagreement found: the backoffice spec's competency-**mean** color
thresholds (`<2.5/2.5–3.5/>3.5`, continuous) are additive to, not contradicting, the
indicator-**chip** discrete `{1,3,5}` scale — design D8 is silent on mean thresholds,
spec owns them, no conflict. The `observability` and `tenancy` delta specs already
match design D7/D1 verbatim.

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | API: A1 380–480 / A2 320–420 / A3 480–620 / A4 40–70. Backoffice: B0 (vendor) 400–700 / B1 350–480 / B2 350–480 / B3 450–600. Wrapper docs: 20–40. |
| 400-line budget risk | High (every unit above except A4 and wrapper docs is at or near budget) |
| Chained PRs recommended | Yes |
| Suggested split | Wrapper docs → API A1→A2→A3→(A4 deferred) → Backoffice B0→B1→B2→B3 |
| Delivery strategy | auto-chain |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

**Deviation from design D14, flagged honestly**: D14 assumed the whole admin read API
lands in **one** API PR. Estimating file-by-file (2 support classes + 1 exception +
1 reader + 2 policies + 2 serializers + 4 resources + 3 controllers + route wiring +
the RBAC/cross-org/gate-matrix/arch feature-test surface the spec demands) puts that
alone at ~1200–1700 lines — the excess is **logic**, not test padding (serializers +
controllers + resources are ~350–500 lines of new production code by themselves), so
per the C10-chain standing ruling ("don't split on line count alone when the excess
is tests — but do flag it") this **is** a logic-driven split, not a defensive one:
API is split into A1 (mechanism) → A2 (serializers/resources) → A3 (HTTP surface +
feature tests). Backoffice B0 is split out from B1 because `shadcn-vue add` vendors
component source into `components/ui/**` — large diff, near-zero hand-authored logic,
a `size:exception` candidate per the chained-pr skill's "generated/vendor diff"
decision gate; keeping it separate from the hand-written theme/auth/shell logic in
B1 keeps B1 reviewable.

### Suggested Work Units

| Unit | Goal | Repo / Branch | Notes |
|------|------|-----|-------|
| 0 | `DESIGN.md` §8.3 + `specs/admin-read-api/spec.md` reconciliation | wrapper, current branch | Docs-only, no submodule touch; lands before any viewer/gate code (R1) |
| A1 | Reader + gate + policies (mechanism) | `api`, base = `feature/admin-dashboards` tracker | ~95%-coverage zone |
| A2 | Scoped serializers + Scramble resources | `api`, base = A1 branch | No `withoutGlobalScopes()` |
| A3 | Controllers + routes + full feature-test matrix | `api`, base = A2 branch | Cross-org ×7, gate matrix, RBAC, download headers |
| A4 | Additive `url` key in `EvaluationPayloadAssembler` | `api`, base = tracker, **after C10 merges** | Deferred; touches C10-owned file |
| B0 | shadcn-vue init + component vendoring | `backoffice`, base = `feature/admin-dashboards` tracker | `size:exception` candidate, near-zero hand logic |
| B1 | Brand theme + auth (single-flight refresh) + shell + SA-11 | `backoffice`, base = B0 branch | R4/R7-critical |
| B2 | Participant list/detail + dashboard KPIs + codegen | `backoffice`, base = B1 branch | Requires A3 merged (real endpoints) |
| B3 | BARS report viewer + downloads + i18n + E2E | `backoffice`, base = B2 branch | Requires the DESIGN.md fix (unit 0) |

---

## Phase 0: Wrapper Docs (Unit 0 — no submodule touch)

- [ ] 0.1 Edit `DESIGN.md:462-465,486`: replace the `High`/`Medium`/`Low` mockup column
      and "Reliability: text badge" line with "Reliability: pre-rendered percent string
      (e.g. `67%`); no High/Medium/Low band — the threshold formula is open product
      decision #1 and MUST NOT be invented."
- [ ] 0.2 Edit `openspec/changes/admin-dashboards/specs/admin-read-api/spec.md`:
      replace every `403` gate-denial reference (status table + 3 scenarios) with
      `409` and the machine-readable body `{error: lifecycle_not_ready, resource,
      current_status, required_status}`, per design D4 / ruling #1.

---

## API — `feature/admin-dashboards` tracker off `api/develop`

### Task: Branching prerequisite

- [ ] A0.1 Confirm `api` working tree is clean; create `feature/admin-dashboards` off
      `develop` (NOT off `feat/c10-pr4-recorder` or `feature/webhooks-integration` —
      C10 is unrelated to A1–A3). Do not check out or modify any C10 branch/file.

## PR A1 — Tenant-Safe Reader + Lifecycle Gate (Mechanism)

### Phase 1: Foundation (PR A1)

- [ ] 1.1 Create `api/app/Support/Admin/ParticipantReadScope.php`: `enum
      ParticipantReadScope { case Summary; case Transcript; case Evaluation; }`.
- [ ] 1.2 Create `api/app/Support/Admin/LifecycleReadGate.php`: `final class`; ordered
      list `['in_attesa','in_corso','in_valutazione','completato']` (`errore`
      deliberately absent); per-scope threshold map; `assert(string $status,
      ParticipantReadScope $scope): void` throws on anything not an explicit match
      (fail-closed, no `?? true`).
- [ ] 1.3 Create `api/app/Exceptions/Admin/LifecycleNotReadyException.php`: carries
      `resource`, `current_status`, `required_status`; register a `409` render in
      `api/bootstrap/app.php` beside the existing `:51-64` block.

### Phase 2: RED (PR A1, TDD)

- [ ] 2.1 RED `api/tests/Unit/Support/Admin/LifecycleReadGateTest.php`: matrix of the
      5 lifecycle statuses × `{Summary,Transcript,Evaluation}` (Summary always passes)
      **plus** a synthetic unknown status asserting deny for every scope.
- [ ] 2.2 RED `api/tests/Unit/Support/Admin/AdminParticipantReaderTest.php`: (a)
      cross-org id → `ModelNotFoundException`; (b) same-org, RBAC-denying user → policy
      denial; (c) same-org, authorized, gate-blocked status →
      `LifecycleNotReadyException`; (d) same-org, authorized, ready status → returns
      the `Participant`.
- [ ] 2.3 RED `api/tests/Arch/C11/AdminTenancySafetyArchTest.php`: (a) no
      `withoutGlobalScopes(` under `app/Http/`; (b) no bare `Participant::` static
      call under `app/Http/Controllers/Api` (mirrors `api/tests/Arch/C2/TenantModelArchTest.php`).

### Phase 3: GREEN (PR A1)

- [ ] 3.1 Implement `LifecycleReadGate::assert()` per Phase 1. Run 2.1 to GREEN.
- [ ] 3.2 Create `api/app/Support/Admin/AdminParticipantReader.php`: `final class`;
      `public function read(int $id, ParticipantReadScope $scope): Participant` — no
      zero-arg overload; injects `TenantResolver` (`api/app/Support/Tenancy/TenantResolver.php`,
      already exists); `Participant::where('organization_id', $resolver->getOrgId())
      ->findOrFail($id)` (the `M2m/ParticipantController.php:90,110` pattern), then
      `Gate::authorize('view', $participant)`, then `LifecycleReadGate::assert()`.
      Run 2.2 to GREEN.
- [ ] 3.3 Create `api/app/Policies/ParticipantPolicy.php` (`viewAny`, `view`) mirroring
      `ProjectPolicy.php:30-41` — all 3 roles read, no owner filter.
- [ ] 3.4 Create `api/app/Policies/EvaluationPolicy.php` (`view`), same pattern.
      Run 2.3 to GREEN.

### Phase 4: Full-Suite Gate + REFACTOR (PR A1)

- [ ] 4.1 Run `./vendor/bin/pest` — full suite, zero regressions.
- [ ] 4.2 Run `php -d memory_limit=2G ./vendor/bin/phpstan analyse --memory-limit=2G`
      — 0 errors on new files; do not attribute pre-existing errors to this change.
- [ ] 4.3 Run `./vendor/bin/pint` scoped to the 6 new files + `bootstrap/app.php`.
- [ ] 4.4 Confirm ~95% coverage on `AdminParticipantReader` + `LifecycleReadGate`.
- [ ] 4.5 Open PR A1 → tracker `feature/admin-dashboards` (human authorizes push/PR).

---

## PR A2 — Scoped Serializers + Scramble Resources

> Base: PR A1 branch.

### Phase 5: RED — Serializer Fixtures (PR A2, TDD)

- [ ] 5.1 RED `api/tests/Unit/Services/Admin/AdminEvaluationSerializerTest.php`: the
      `SLF` fixture from `esempio-report-valutazione.json:374-392` (`5,3,-1` → mean
      `4.0`, `reliability "67%"`) plus an all-`-1` competency → `score: null`
      (`CompetencyResult.php:39,67`), never `0`.
- [ ] 5.2 RED `api/tests/Unit/Services/Admin/AdminTranscriptSerializerTest.php`: a
      participant with 2+ `InterviewSession`s (one per competency,
      `InterviewSession.php:48-49`) → utterances grouped and ordered by
      `question_index` then session `id`, each session's utterances by `ts` then `id`.
- [ ] 5.3 RED — extend the Phase 2 arch test (2.3) to also assert
      `AdminEvaluationSerializer`/`AdminTranscriptSerializer` contain no
      `withoutGlobalScopes()` call (spec scenario "Serializer never bypasses the
      tenant scope").

### Phase 6: GREEN (PR A2)

- [ ] 6.1 Create `api/app/Services/Admin/AdminEvaluationSerializer.php`: scoped
      queries only (`Evaluation`/`CompetencyResult`/`IndicatorScore` all extend
      `TenantModel`); eager-load `competencyResults.indicatorScores` (no N+1); reuse
      `ReliabilityRenderer` (`EvaluationPayloadAssembler.php:146`) and the
      `project_competencies.position` ordering (`:119-123`) as pure collaborators
      only — do not extend or copy `EvaluationPayloadAssembler` itself. Run 5.1 GREEN.
- [ ] 6.2 Create `api/app/Services/Admin/AdminTranscriptSerializer.php`: iterate the
      participant's sessions (never `TranscriptAssembler::assemble()`'s single-session
      signature, `TranscriptAssembler.php:34` — this is new assembly logic, not
      reuse); dual `orderBy` per session per `TranscriptAssembler.php:11-14`'s
      discipline. Run 5.2 GREEN.
- [ ] 6.3 Create `api/app/Http/Resources/Admin/{ParticipantResource,
      ParticipantDetailResource,TranscriptResource,EvaluationResource}.php` with
      Scramble annotations sufficient for a resolvable `openapi.json` schema.

### Phase 7: Full-Suite Gate (PR A2)

- [ ] 7.1 `./vendor/bin/pest` full suite; `phpstan` 0 new errors; `pint` scoped to the
      6 new files.
- [ ] 7.2 Open PR A2 → PR A1 branch.

---

## PR A3 — Controllers + Routes + Feature-Test Matrix

> Base: PR A2 branch.

### Phase 8: Build (PR A3)

- [ ] 8.1 Create `api/app/Http/Controllers/Api/ParticipantController.php`:
      `index`/`show`/`transcript`/`evaluation`, all via `AdminParticipantReader::read()`
      — never a direct `Participant::` call (defense in depth, arch-tested). List
      endpoint: `paginate()`, filters `project_id`/`status`/`q`, `per_page` 1–100
      default 20, sort fixed `created_at desc, id desc` (D5 — no client-specified sort).
- [ ] 8.2 Create `api/app/Http/Controllers/Api/ParticipantDownloadController.php`
      (D9): transcript `text/plain; charset=utf-8`, evaluation `application/json`,
      buffered; filename `beai-{type}-{candidate_ref}-{YYYYMMDD}.{ext}` — `candidate_ref`
      is externally supplied (`Participant.php:46`), MUST be `Str::slug()`-ed with
      RFC 5987 `filename*=UTF-8''…` + an ASCII `filename=` fallback (header-injection
      guard — never interpolate raw).
- [ ] 8.3 Create `api/app/Http/Controllers/Api/DashboardController.php` (D7): org-scoped
      participants-by-status, evaluations-by-status, completion rate; from
      `ai_requests` (`2026_07_22_000004_create_ai_requests_table.php:54-61` —
      `input_tokens`/`output_tokens`/`latency_ms` only, **no cost/currency column,
      none added**): summed token usage + p50/p95 latency. No MRR/trial/subscription
      widget (observability delta, ruling #5).
- [ ] 8.4 Append the new admin route group to `api/routes/api.php` after `:68`, under
      `['auth:api', TenantContext::class]`, resolving IDs manually (never route-model
      binding, per `ProjectController.php:23-28`'s documented reason).

### Phase 9: RED — Feature Tests (PR A3, TDD)

- [ ] 9.1 RED cross-org 404 across **all 7 endpoints** (spec scenario): participant
      P in org B, requester org A → every endpoint 404, zero fields from P leaked.
- [ ] 9.2 RED lifecycle gate matrix (spec table, corrected to `409` per task 0.2):
      5 statuses × {transcript read+download, evaluation read+download} → `403` never
      appears; `409` with `error: lifecycle_not_ready` before threshold, `200` after.
- [ ] 9.3 RED fail-closed: participant with an unrecognized status string → `409`,
      never `200`, on both gated scopes.
- [ ] 9.4 RED RBAC: viewer/operator/admin all read successfully (spec "List and
      detail return only RBAC-gated data").
- [ ] 9.5 RED download header safety: a `candidate_ref` containing
      `"` / CRLF / non-ASCII → response `Content-Disposition` is safe (slugged +
      RFC 5987), never raw-interpolated.
- [ ] 9.6 RED negative test: no route serves per-question audio or snapshot binary
      content (spec "No audio download endpoint exists") — assert via
      `Route::getRoutes()` enumeration.

### Phase 10: GREEN + Full-Suite Gate (PR A3)

- [ ] 10.1 Make Phase 9 GREEN against the Phase 8 controllers/routes.
- [ ] 10.2 Run `php artisan scramble:export`; confirm all 7 admin endpoints present
      with typed request/response schemas.
- [ ] 10.3 `./vendor/bin/pest` full suite; `phpstan` 0 new errors; `pint` scoped to
      touched files.
- [ ] 10.4 Confirm 85% overall on the API slice; ~95% maintained on the tenancy/gate
      paths reachable through the new controllers.
- [ ] 10.5 Open PR A3 → PR A2 branch.

---

## PR A4 — C10-Gated Webhook `url` Key (deferred)

> Base: tracker `feature/admin-dashboards`, **only after** A1–A3 are merged into the
> tracker **and** C10's tracker (`feature/webhooks-integration`) has merged to
> `api/develop`. Rebase before starting; do not touch this file earlier.

### Phase 11: Build + Gate (PR A4)

- [ ] 11.1 Add the additive `url` key to
      `EvaluationPayloadAssembler::renderFiles()` (`:170-187`), absolute via
      `config('app.url')`, per `openspec/changes/webhooks-integration/design.md:309,460`.
- [ ] 11.2 Update/extend the existing `EvaluationPayloadAssembler` tests to assert the
      new key without weakening any existing assertion.
- [ ] 11.3 `./vendor/bin/pest` full suite; `phpstan`; `pint` scoped. Open PR A4 → tracker.

---

## Backoffice — `feature/admin-dashboards` tracker off `backoffice/develop`

### Task: Branching prerequisite

- [ ] B0.0 Confirm `backoffice` working tree is clean; create `feature/admin-dashboards`
      off `develop`. Independent of the API tracker except B2/B3 need A3 merged
      (real endpoints) before their feature work starts.

## PR B0 — shadcn-vue Vendor Init (`size:exception` candidate)

### Phase 12: Vendor (PR B0)

- [ ] 12.1 Add deps to `backoffice/package.json`: `shadcn-vue`, `reka-ui`,
      `class-variance-authority`, `clsx`, `tailwind-merge`, `tw-animate-css`,
      `@heroicons/vue`, `@fontsource/open-sans`, `@vueuse/core` — pinned to the exact
      resolutions already proven in `frontend/package.json:23-41`. A blocked
      resolution is an open question (D37) — stop, report, do not downgrade/substitute.
- [ ] 12.2 Run `bunx --bun shadcn-vue@latest init` then `add` for the components
      listed in design D8 (`Button`, `Table`, `Card`, `Badge`, `Sidebar`, `Avatar`,
      etc. per usage) — Bun only, never npm/pnpm/yarn/npx. Icon set: swap any
      registry default icon imports to `@heroicons/vue` (design D3 — replaces
      shadcn's default set).
- [ ] 12.3 Flag to reviewer: this PR is >90% vendored source; request `size:exception`
      per the chained-pr skill's generated/vendor-diff gate rather than splitting
      component-by-component.
- [ ] 12.4 Open PR B0 → tracker `feature/admin-dashboards`.

---

## PR B1 — Brand Theme + Auth + Shell + SA-11 Gate

> Base: PR B0 branch.

### Phase 13: Theme Reconciliation (PR B1, D10)

- [ ] 13.1 RED `backoffice/tests/unit/theme.spec.ts`: mount a `bg-primary` element,
      assert computed background `#771AAF` (not shadcn's default grey/`oklch(0.205 0
      0)` — the confirmed `frontend` bug, ruling #7, out of scope to fix there).
- [ ] 13.2 GREEN — edit `backoffice/app/assets/css/main.css`: reconcile `@theme` to
      `DESIGN.md` §3 verbatim (`--color-primary:#771AAF`, `--color-accent:#E45526`,
      `--color-lavender`, `--color-bg-gradient`, `@import '@fontsource/open-sans';`
      first line, `--font-sans:"Open Sans"`); **omit** `--color-primary`,
      `--color-accent`, and the 4 `--radius-*` keys from the `@theme inline` bridge
      (do NOT copy `frontend`'s colliding bridge); set shadcn `:root` semantics
      (`--primary`, `--primary-foreground`, `--accent`, `--sidebar`, `--destructive:
      #b91c1c` not `#ef4444`, `--radius:0.5rem`) to brand values so both resolution
      paths agree. Run 13.1 GREEN.
- [ ] 13.3 Snapshot test over the full token block (regression guard for future edits).

### Phase 14: Auth Session (PR B1, D11)

- [ ] 14.1 RED `backoffice/tests/unit/composables/useApi.spec.ts`: unauthenticated
      request → redirect target `/login`; expired-token request → single silent
      refresh + retry, no redirect.
- [ ] 14.2 RED `backoffice/tests/unit/composables/useAuth.spec.ts`: **fire 2+
      concurrent 401s** → exactly ONE `/api/auth/refresh` call issued (single-flight),
      both original requests retried with the new token — regression guard for the
      `AuthController.php:86-98` rotation + denylist (`config/jwt.php:227`) hazard.
- [ ] 14.3 GREEN — `useApi()` `$fetch` wrapper over `runtimeConfig.public.apiBase`
      (`nuxt.config.ts:56-60`) attaching `Authorization: Bearer`; `sessionStorage` +
      in-memory mirror (API issues no cookie, `AuthController.php:181-186`); a
      module-scoped in-flight refresh promise shared by all concurrent 401s.
- [ ] 14.4 Create login page (`pages/login.vue`) + logout action (denylist via
      `POST /api/auth/logout`, then clear storage regardless of response).
- [ ] 14.5 Create `backoffice/app/middleware/01.browser-gate.global.ts` (port of
      `frontend/app/utils/browser-gate.ts:28-47`, client-only branch — SPA has no
      SSR path) and `02.auth.global.ts` (redirects unauthenticated → `/login`;
      early-returns on `/unsupported` and `/login` regardless of filename order —
      belt-and-braces per D11).

### Phase 15: SA-11 Gate + Shell (PR B1)

- [ ] 15.1 RED `backoffice/tests/e2e/unsupported-gate.spec.ts` extension: every admin
      route at a 375px viewport renders `/unsupported`, including while authenticated.
- [ ] 15.2 GREEN — wire `browser-gate.global.ts` against `backoffice/app/pages/unsupported.vue`
      (exists, unwired today).
- [ ] 15.3 Create `SidebarNav.vue` / `NavBar.vue` shell organisms (`DESIGN.md:421-437`)
      + `app.vue`/`layouts/default.vue` wiring, each with a Vitest test.

### Phase 16: Gate (PR B1)

- [ ] 16.1 `bunx nuxi prepare` then `bun run typecheck` (nuxi typecheck) clean.
- [ ] 16.2 `bun run test:unit` full suite; `bun run test:e2e` (chromium+webkit+mobile
      unsupported-gate) green.
- [ ] 16.3 Open PR B1 → PR B0 branch.

---

## PR B2 — Participant List/Detail + Dashboard KPIs

> Base: PR B1 branch. **Requires API PR A3 merged into the api tracker** — real
> endpoints must exist before consumption.

### Phase 17: Client Sync + Build (PR B2)

- [ ] 17.1 Add `openapi:sync` task to wrapper `Taskfile.yml` (D13): `php artisan
      scramble:export` in `api` → copy `api/openapi.json` → `backoffice/openapi.json`
      → `bun run codegen`. Closes the gap where `check-client-drift.sh:13` only
      re-derives from the committed snapshot and nothing syncs it from the API.
- [ ] 17.2 Run `task openapi:sync`; run `bun run codegen:check` — green.
- [ ] 17.3 Create `CandidateTable.vue` organism (D4/D5): server-paginated, filters
      `project_id`/`status`/`q`, a **fresh authorized query per page** — no
      client-side fetch-all filtering.
- [ ] 17.4 Create participant list page (`pages/participants/index.vue`) + detail
      page (`pages/participants/[id].vue`) with lifecycle timeline.
- [ ] 17.5 Create dashboard page (`pages/index.vue` or `pages/dashboard.vue`): usage
      + AI-cost KPI cards only (`GET /api/dashboard/metrics`) — no MRR/trial/billing
      widget, not even disabled/placeholder (observability delta scenario).

### Phase 18: Tests + Gate (PR B2)

- [ ] 18.1 Vitest per new component (`CandidateTable`, list/detail pages as
      composable-backed components, dashboard KPI cards).
- [ ] 18.2 `backoffice/tests/e2e/admin-flow.spec.ts` (chromium+webkit): login → list
      → open detail; role-based locators only (`getByRole`/`getByLabel`), zero
      CSS class/id selectors; `@axe-core/playwright` clean.
- [ ] 18.3 `bun run typecheck` clean; `bun run test:unit` + `test:e2e` green; open
      PR B2 → PR B1 branch.

---

## PR B3 — BARS Report Viewer + Downloads + i18n + E2E

> Base: PR B2 branch. **Requires task 0.1** (`DESIGN.md` §8.3 reliability fix) merged
> before starting.

### Phase 19: Report Viewer Atoms/Molecules (PR B3, D8)

- [ ] 19.1 RED `backoffice/app/components/atoms/ScoreChip.spec.ts`: one case per
      `{1,3,5,-1}` — assert the visible numeral/`–` text and the visually-hidden i18n
      label (`report.chip.low/mid/high/unassessable`), never assert on color class.
- [ ] 19.2 GREEN — `ScoreChip.vue`: numeral/`–` + `aria-hidden` Heroicons glyph +
      semantic color (color is the 3rd signal, never the only one, WCAG 2.1 AA 1.4.1);
      `-1` renders `–`, never printed as `-1`, never on the error/warning/success scale.
- [ ] 19.3 Create `CompetencyMean.vue` (nullable mean or `–`, never `0`),
      `ReliabilityBadge.vue` (pre-rendered percent string **only** — no High/Medium/Low
      band, per task 0.1/ruling #6), `StatusBadge.vue` (i18n-labelled lifecycle status)
      — each with a Vitest test.
- [ ] 19.4 Create `CompetencyRow.vue` (code+name+mean+reliability+chip strip as a
      `<ul>` with `aria-label` naming the competency) and `ExcerptList.vue`
      (`--font-mono`, verbatim excerpts) molecules, each with a Vitest test.

### Phase 20: Report Organism + Downloads (PR B3)

- [ ] 20.1 RED `EvaluationReport.spec.ts`: the `SLF` fixture (`5,3,-1` → mean `4.0`,
      reliability `67%`) renders correctly; an all-`-1` competency renders `–` never `0`.
- [ ] 20.2 GREEN — `EvaluationReport.vue` (`<table>` + `<caption>` + per-competency
      `CompetencyRow`s + `ExcerptList`).
- [ ] 20.3 Download buttons (transcript `text/plain`, evaluation JSON): fetch +
      inspect status + trigger blob — never blind `window.open` (D9); disabled/absent
      when the corresponding read scope is gated (409).

### Phase 21: i18n + E2E + Gate (PR B3)

- [ ] 21.1 Full `it`/`en` key set in `backoffice/i18n/locales/{it,en}.json` for every
      new string; `Intl.DateTimeFormat`/`Intl.NumberFormat` for dates/scores/percentages
      — never manual formatting.
- [ ] 21.2 `backoffice/tests/e2e/admin-flow.spec.ts` extension: full login → list →
      detail → report → download flow, chromium+webkit; `toHaveScreenshot` on the
      report grid (2% tolerance already configured); axe clean.
- [ ] 21.3 Run `task openapi:sync` + `bun run codegen:check` green (final endpoint
      consumption pass).
- [ ] 21.4 `bun run typecheck` clean; `bun run test:unit` + `test:e2e` (all 3
      projects) green; confirm 85% overall backoffice coverage.
- [ ] 21.5 Open PR B3 → PR B2 branch.
