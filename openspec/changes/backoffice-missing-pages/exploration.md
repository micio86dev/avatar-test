# Exploration — backoffice-missing-pages

Investigating what it takes to build the three backoffice routes the sidebar
already links to but which have no page file: `/projects`, `/reports`,
`/settings`.

Phase: `sdd-explore`. No implementation, no application code changed.

---

## Current state

`backoffice/app/components/organisms/SidebarNav.vue:55-64` links six routes.
Page files exist only for `/`, `/participants`, `/participants/[id]`,
`/avatar-templates`, `/login`, `/health`, `/unsupported`. The other three are
dead links: nginx's SPA fallback answers 200, then the Vue Router finds no route
and renders the Nuxt 404.

---

## `/projects` — fully spec-backed, backoffice-only

The API is complete and the typed client is already generated. This is the one
page that can be built today with zero new backend contract.

| Layer | State |
|---|---|
| Controller | `api/app/Http/Controllers/Api/ProjectController.php` — full apiResource CRUD, org-scoped via `TenantContext` |
| Create rules | `api/app/Http/Requests/StoreProjectRequest.php` |
| Update rules | `api/app/Http/Requests/UpdateProjectRequest.php` |
| Typed client | `backoffice/types/api.ts:621-674` — `paths['/projects']`, `paths['/projects/{project}']`, operations `projects.index/store/show/update/destroy` **already generated** |
| Composable | **absent** — no `useProjects.ts` |

Route-model binding is deliberately not used: `SubstituteBindings` runs before
`TenantContext`, so the controller resolves with a manual `findOrFail` inside the
tenant scope (reason documented at `ProjectController.php:22-28`).

### Contract highlights the form must honour

- Required on create: `framework_version_id` (org-scoped `Rule::exists`), `slug`
  (org-unique, soft-delete aware), `name`, `assessment_type ∈ {standard, potential}`,
  `role_code`, `language ∈ supported_locales`, `competency_ids[]`.
- Bounded: `pause_every_n_competencies` 1–255, `nudge_min_chars` 0–65535,
  `exit_redirect_url` / `error_redirect_url` url max 2048.
- `webhook_events[] ∈ config('webhooks.events.types')` = `['progress', 'evaluation']`.
- Cross-field: `potential` requires `role_code = null` and competencies ⊆ {MTG, LAT},
  all `type = potential`, with `POTENTIAL_CATALOG_INCOMPLETE` (422) checked first.
  `standard` requires `role_code ∈ {ICO, FLL, MLL, BUL, SRX}` and competencies
  assigned to that role.
- `framework_version_id` is **`prohibited` on every PATCH** — immutable after
  creation, even when resubmitting the same value.
- `assessment_type` and `role_code` are immutable once `status ∈ {active, archived}`.
  Enforced twice: FormRequest cross-field **and** a `Project::booted()` `updating`
  guard (`api/app/Models/Project.php:118-159`) as a backstop for non-HTTP writes.
- Lifecycle transitions: only `draft → active` and `active → archived`.
- `ProjectResource` **excludes `webhook_secret`** (hidden + `encrypted` cast). The
  form must treat it write-only — "set a new secret", never render or prefill it.

Those immutability rules are enforced in three places server-side. The form has to
mirror them in the UI (disable the fields once the project is active or archived)
or operators will hit 422s with no explanation of why the field was rejected.

### House pattern to follow

From `useParticipants.ts` + `participants/index.vue` / `[id].vue`, and
`useAvatarTemplates.ts` + `avatar-templates/index.vue`:

- Composable is a thin `useApi().apiFetch` wrapper typed off `paths[...]`.
- Page holds `ref` state, loads in `onMounted`, and maps failures through
  `resolveResourceErrorState` / `resourceErrorKey` (`utils/error-state.ts`) so
  403/404/409/network render as distinct `Alert` states.
- Create/edit uses an `editing` ref — `null` closed, object without id = create,
  object with id = edit — driving a separate `<XForm>.vue` organism that receives
  data + specs + saving + errors and emits `cancel` / `submit`.

**Do not copy `avatar-templates/index.vue`'s markup.** It uses raw `<button>`
elements; `participants/[id].vue` correctly uses the shadcn `Button`. Follow
participants.

### shadcn-vue components still missing

Installed: card, alert, button, avatar, badge, sidebar, tooltip, input, skeleton,
separator, label, dropdown-menu, field, table, sheet.

A project form additionally needs **select, dialog, textarea, checkbox**, and
probably combobox or toggle-group for the competency multi-select.

---

## `/reports` — no API, and no written requirement

Evaluation rendering already exists and is already wired to real data:
`participants/[id].vue:165-171` renders `EvaluationReport.vue` via
`useEvaluationReport().fetchEvaluation(id)` → `GET /participants/{id}/evaluation`.
That is the only evaluation surface in the product.

What the archive actually says:

- `openspec/changes/archive/2026-07-31-admin-dashboards/specs/admin-backoffice/spec.md:93-131`
  ("BARS Report Viewer Rendering Correctness") is entirely about `EvaluationReport.vue`
  correctness **inside participant detail**. No requirement anywhere describes a
  standalone `/reports` page, a cross-participant index, filters, or export.
- PDF export is an explicit C11 **non-goal** (`spec.md:118-124`).
- `api/routes/api.php` has no `/reports` and no `/evaluations` index route.
- `docs/app_description/03-ux-reference/esempio-report-valutazione.json` is keyed by
  competency code for **one** candidate, confirming the canonical shape is
  per-participant rather than a cross-participant listing.
- DESIGN.md §8.2 lists "Reports" in the nav with a one-line description that
  duplicates what the "Candidate detail" / "Evaluation report" rows already cover.

So `/reports` as a distinct capability is unspecified. Building a cross-participant
aggregation would mean inventing an unratified API contract.

---

## `/settings` — one line in DESIGN.md, one of four sub-scopes actually backed

DESIGN.md §8.2 is the **only** written description in the repo:

> `Settings | Organization profile, API keys, webhook config, user management (RBAC)`

Exhaustive search of `docs/app_description/**`, `docs/BEAI_BRIEF.md`,
`openspec/ROADMAP.md` and `openspec/specs/**` returns no other hit. (The single
match inside `ICO.json` is unrelated BARS anchor prose.) There is no settings
table and no settings model.

Sub-scope by sub-scope:

| Sub-scope | Backing |
|---|---|
| **API keys** | **Real.** `api/app/Http/Controllers/M2m/ApiClientController.php` (C5): `POST/GET /api/m2m/clients`, `DELETE /api/m2m/clients/{id}`, admin-only, returns the raw key exactly once, never returns `key_hash`. Full API, zero UI. |
| Organization profile | No controller (`Controllers/Api/*Organization*` → none) |
| Webhook config | Lives on the Project resource, not an org-level entity. No standalone endpoint |
| User management (RBAC) | No User/Role CRUD controller, despite `spatie/laravel-permission` being the target library |

One of four is shippable. The other three have no API, no model, no spec.

---

## DESIGN.md — what it actually mandates

Section numbers corrected against the file (the task brief guessed some):

- **§5 Component Architecture** (281-327) — atoms/molecules/organisms; every
  clickable element MUST show `cursor: pointer`; every component needs a matching
  Vitest test.
- **§8.1 Layout** (430-448) — sidebar 256px; nav is Projects / Candidates /
  Reports / Settings; content max-width 1200px, centered.
- **§8.2 Key Views** (450-460) — Projects: "Table of evaluation projects;
  create/configure/archive". Project detail: "Candidate list + status breakdown +
  webhook log" (not API-backed today beyond the Project resource itself). A "Data
  management (GDPR)" row is also unbuilt and out of this scope.
- **§9** — never use `--color-success` / `--color-warning` as text or icon colour
  on white; an axe-core contrast failure was already caught this way in C11.
- **§14 Lighthouse** (642-661) — Accessibility 100 and Best Practices 100 are
  non-negotiable on both apps; Performance ≥ 90; LCP < 2.5 s, CLS < 0.1, INP < 200 ms.
  The backoffice is an SPA, so code-splitting and lazy routes matter for new routes.
- **§16 Form Design** (684-697) — **STALE.** It prescribes `@tailwindcss/forms`
  plus "VeeValidate or Zod". The codebase actually uses shadcn-vue
  `Field` / `FieldGroup` / `FieldError`. The *semantics* in §16 remain correct and
  binding — `aria-invalid`, `aria-describedby` pointing at the message element,
  i18n-keyed messages, errors after blur — only the named libraries are wrong.
  DESIGN.md needs updating before this change implements against it.

---

## Testing pattern

- **Vitest** (`tests/unit/avatar-templates-page.spec.ts`): `vi.doMock` the
  composable, `vi.resetModules()`, then dynamic `import()` of the page;
  `vi.stubGlobal` for `definePageMeta` / `useHead` / `useI18n`; `mount()` +
  `flushPromises()`; assert on `data-testid`, never CSS selectors.
- **Playwright** (`tests/e2e/admin-flow.spec.ts`): role-based locators only;
  network-level route interception with fixtures shaped like the real API
  Resource; no live backend. Contract drift is caught separately by
  `bun run codegen:check` plus Pest.
- **3-project matrix**: chromium and webkit run the full suite; the `mobile`
  project (`backoffice/playwright.config.ts:44-49`) runs only
  `unsupported-gate.spec.ts`. New pages therefore need no bespoke mobile spec —
  the SA-11 gate covers every route generically.

---

## Tenancy

All org scoping is server-side (`TenantContext` middleware + the `TenantScoped`
global Eloquent scope). The backoffice does no client-side filtering. Existing
cross-tenant coverage: `api/tests/Feature/C4/ProjectCrudTest.php` and
`api/tests/Feature/C11/AdminCrossTenantIsolationTest.php`. Any new `/reports`
endpoint would need equivalent coverage of its own.

---

## Approaches

1. **Build all three as DESIGN.md literally describes.** Matches the design doc,
   but `/reports` and three of `/settings`'s four sub-scopes have zero API or spec
   backing, so it means inventing an unratified contract inline — which is exactly
   what SDD exists to prevent. Effort: high, and partly out of contract.
2. **Build `/projects` fully; scope `/reports` and `/settings` down to what is
   spec-backed.** `/settings` ships the API-keys tab only; `/reports` is either
   aliased into the existing participant evaluation flow or explicitly descoped.
   Everything shipped maps to a real, tested API. Costs a DESIGN.md update or an
   explicit scope note, since both pages land smaller than DESIGN.md's one-liners
   promise. Effort: medium.
3. **Ship `/projects` only; remove or hide the other two sidebar links.** Cleanest,
   zero speculative work, but leaves two visible gaps and needs a separate nav
   change. Effort: low-medium.

## Recommendation

**Approach 2.** `/projects` is fully spec-backed with the typed client already
generated. `/settings` gets the API-keys tab, with organization profile, org-level
webhook config and user/RBAC management explicitly deferred to a future
API-bearing change. `/reports` should not invent a cross-participant aggregation
feature that no spec covers — it needs an explicit product decision before
`sdd-propose` writes it into scope.

## Risks

- Building the `/projects` UI before installing the missing shadcn-vue components
  (select, dialog, textarea, checkbox) risks replicating the raw-`<button>`
  regression already present in `avatar-templates/index.vue`.
- `/reports` and `/settings` carry real scope-creep risk: DESIGN.md promises
  features with zero API or spec backing. This must be surfaced as an explicit
  scoping decision, not silently implemented and not silently dropped.
- Project immutability and lifecycle rules are enforced in three places
  server-side. A form that does not mirror them produces confusing 422s.

## Process finding

`openspec/changes/archive/2026-07-18-project-config` (C4) and
`.../2026-07-31-admin-dashboards` (C11) are both archived — declared complete and
verified — yet `/projects` and `/reports` were never built. C4 explicitly scopes
"backoffice UI" to C11, so the delivery gap sits in C11. A change that archives
without delivering its UI is a gap in the verify phase, not merely a missing page.
