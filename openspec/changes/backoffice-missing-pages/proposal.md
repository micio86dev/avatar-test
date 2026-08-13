# Proposal: Backoffice Missing Pages — `/projects`, `/reports`, `/settings`

## Intent

`SidebarNav.vue:55-64` links six routes; three have no page file. `/projects`,
`/reports` and `/settings` return the SPA fallback and then a Nuxt 404. Operators
see navigation that promises capability the product does not deliver.

C4 (project config) and C11 (admin dashboards) are both archived, yet the project
CRUD UI they imply was never built: C4 deferred "backoffice UI" to C11, and C11
shipped without it. This change closes that delivery gap and builds the three
routes as DESIGN.md §8.2 describes — including the surfaces that have no API
contract today.

Scope decision is settled: build all three. The job of this proposal is to make
that scope safe by specifying the four missing API contracts up front instead of
inventing them inline during implementation.

## Scope

### In Scope

| # | Deliverable | Backing today |
|---|---|---|
| 1 | `/projects` full CRUD page + `useProjects` composable + `ProjectForm` organism | API complete; typed client already at `backoffice/types/api.ts:621-674` |
| 2 | `/settings` → API keys tab | API complete (`M2m/ApiClientController.php`, C5) |
| 3 | `/settings` → Organization profile tab + **new API** | none |
| 4 | `/settings` → Organization webhook defaults tab + **new API** | webhook config is per-Project only |
| 5 | `/settings` → Users & roles tab + **new API** | no User/Role CRUD controller |
| 6 | `/reports` cross-participant index + **new API** | no `/reports`, no `/evaluations` index route |
| 7 | DESIGN.md §16 rewrite + form/input sizing tokens | §16 is stale |
| 8 | Missing shadcn-vue components via CLI: `select`, `dialog`, `textarea`, `checkbox`, `toggle-group` (competency multi-select) | not installed |

### Out of Scope / Non-Goals

- **PDF export** — explicit C11 non-goal (`archive/2026-07-31-admin-dashboards/.../spec.md:118-124`). Stays a non-goal.
- **CSV export of the reports index** — `admin-read-api` requirement "Downloadable Artifacts Are Limited to Transcript and Evaluation" would have to change. Deferred to a dedicated change.
- **White-label / branding** (logo upload, theme colours, custom domain, FR-006 multi-test portal) — CLAUDE.md product decision 9 is **PARKED**. Boundary below.
- **GDPR retention configuration** — product decision 2 is pending legal sign-off. No retention controls in `/settings`.
- **Project detail page** and the §8.2 "webhook log" / "Data management (GDPR)" rows — separate change.
- **Webhook delivery log UI** — `webhook_deliveries.payload` is inside the pending GDPR sign-off.
- **Multi-org membership** — locked non-goal in `identity-auth` (C2). One user, one organization.
- **Password reset / invite emails** for new users — first slice sets an initial password directly.

## New API Contracts

Proposal-level shapes. `sdd-spec` formalises them. All under
`auth:api` + `TenantContext`; org scoping is server-side only (the backoffice never
filters by org client-side).

### A. Organization profile — extends new capability `organization-settings`

| Item | Decision |
|---|---|
| Entity | existing `Organization` (`name`, `slug`) |
| Endpoints | `GET /api/organization`, `PATCH /api/organization` — **singular, no id in path** (resolved from `TenantContext`), which removes the IDOR surface entirely |
| New table | No. Additive nullable columns only (`default_locale`) |
| Org scoping | Implicit: the route can only ever address the caller's own org |
| Authorization | read: any org member; write: `admin` only |
| Editable | `name`, `default_locale` (∈ `supported_locales`) |
| Read-only | `slug` — it is a tenancy identifier, not a display field |

**PARKED-scope boundary.** Organization profile here means *administrative identity*
only. It explicitly does NOT include logo, colour tokens, custom domain, sender
branding, or portal composition — those are white-label (decision 9, PARKED) and
must not be silently absorbed. If a future written white-label requirement lands, it
extends this capability rather than reopening it.

### B. Organization webhook defaults — same capability `organization-settings`

Today `webhook_url` / `webhook_secret` / `webhook_events` live on `Project`.

| Item | Decision |
|---|---|
| Endpoints | folded into `GET/PATCH /api/organization` |
| New table | No. Additive nullable columns on `organizations`: `default_webhook_url`, `default_webhook_secret` (`encrypted` cast, `hidden`), `default_webhook_events` (jsonb) |
| Semantics | **copy-on-create**, not runtime fallback. Defaults prefill a new Project at creation; delivery resolution is untouched |
| Why | runtime fallback would modify `webhooks-integration` → "Secret resolution — Eloquent-only, never exposed", a C10 correctness requirement. Copy-on-create leaves C10 delivery behaviour byte-identical |
| Secret handling | write-only. Never serialized, never prefilled. UI offers "set a new secret", mirroring `ProjectResource` |

### C. User management / RBAC — new capability `user-management` (**security-sensitive**)

| Item | Decision |
|---|---|
| Endpoints | `GET/POST /api/users`, `PATCH/DELETE /api/users/{id}`, `GET /api/roles` |
| New table | No. `users` + Spatie `model_has_roles` (teams mode) |
| Org scoping | `User::where('organization_id', $orgId)` — `users` is a plain model, so it follows the `admin-read-api` explicit-where pattern, never bare `findOrFail`. Cross-org id → `404` |
| Authorization | `admin` only for every verb. `operator`/`viewer` → `403` |

This endpoint can grant the `admin` role, so it is a privilege-escalation surface.
Binding invariants:

1. `organization_id` is NOT fillable (`User.php:20`). The new user's org comes from
   `TenantContext`, never from the request body. A body-supplied `organization_id`
   is ignored, not honoured.
2. `is_superadmin` is NOT fillable (`User.php:21`) and is not assignable, readable,
   or filterable through this surface. Superadmin users are not manageable here.
3. Role assignment uses `setPermissionsTeamId($organizationId)` with
   `team_id = organization_id`, and validates against a hard allow-list
   `Rule::in(['admin','operator','viewer'])` — never a free-form role name.
4. **BEAI organizational roles (ICO/FLL/MLL/BUL/SRX) MUST NOT appear anywhere in this
   surface.** They are a domain concept on `Project.role_code`, not an auth concept.
   `identity-auth` already locks the `roles` table to `admin|operator|viewer`; this
   change must not widen it. UI copy must not use the bare word "role" ambiguously.
5. **Last-admin guard**: an org must always retain ≥1 admin. Self-demotion and
   self-deletion are rejected (`422`).
6. Passwords are never returned. Role cache is cleared on every role write.

### D. Reports index — **modifies** existing capability `admin-read-api`

Participant detail already renders the per-candidate BARS report via
`GET /participants/{id}/evaluation`. `/reports` is not a second renderer of that.
What it adds:

| Endpoint | Purpose |
|---|---|
| `GET /api/evaluations` | cross-participant, org-scoped, paginated index |
| `GET /api/evaluations/summary` | aggregates over the same filter set |

- Filters: `project_id`, `assessment_type`, `role_code`, `status`, completion date
  range, `reliability` ≥ threshold.
- Row shape: participant ref, project, assessment type, role code, `completed_at`,
  completion status (`completed` / `pending` per the ≥90% gate), `reliability`
  rendered verbatim as a percentage (product decision 1 — **no High/Medium/Low bands**).
- Summary: counts by completion status, and mean competency score per competency
  code across the filtered set.
- **Lifecycle read-gate still applies.** Structured evaluation data appears only for
  participants in `completato`. Others are either excluded or listed with status only
  — never with scores. This extends "Admin Read Endpoint Surface" and inherits
  "Cross-Tenant Isolation on Every Admin Read Endpoint" verbatim.
- Clicking a row navigates to the existing `/participants/{id}` detail. No duplicated
  report renderer.

## Capabilities

### New Capabilities

- `organization-settings`: org profile read/update and org-level webhook defaults (copy-on-create), admin-gated, singular self-resolving route.
- `user-management`: admin-only, org-scoped user CRUD and Spatie role assignment, with privilege-escalation and last-admin invariants.

### Modified Capabilities

- `admin-read-api`: adds `GET /api/evaluations` and `GET /api/evaluations/summary` to the admin read surface, under the same lifecycle read-gate and cross-tenant rules.
- `admin-backoffice`: adds the `/projects`, `/reports`, `/settings` routes; codifies the ratified form contract; reconciles DESIGN.md §16.
- `identity-auth`: role assignment becomes a runtime admin operation. The `admin|operator|viewer` allow-list itself is unchanged and must stay unchanged.

## Approach

**Frontend.** Follow the house pattern proven by `useParticipants.ts` +
`participants/index.vue` / `[id].vue`: thin `useApi().apiFetch` composable typed off
`paths[...]`, page-level `ref` state loaded in `onMounted`, failures mapped through
`resolveResourceErrorState` / `resourceErrorKey` so 403/404/409/network render as
distinct `Alert` states, and an `editing` ref (`null` = closed, no id = create, id =
edit) driving a separate form organism. Do **not** copy `avatar-templates/index.vue`
markup — it uses raw `<button>` elements.

**Form contract** (ratified on `backoffice/app/pages/login.vue`, covered by
`backoffice/tests/unit/login.spec.ts`) applies to every form in this change:

- field-level messages render directly under their own field, with `aria-invalid` on
  the control and `aria-describedby` pointing at the message element id;
- the form-level success/error banner renders adjacent to the submit CTA with
  `role="alert"`;
- all messages are i18n-keyed (`backoffice/i18n/locales/{en,it}.json`), errors after blur;
- layout uses shadcn-vue `FieldGroup` / `Field` / `FieldError`, never raw `div` +
  `space-y-*`.

**Project form must mirror server-side immutability**, or operators hit unexplained
422s. The rules are enforced in three places server-side
(`StoreProjectRequest`, `UpdateProjectRequest`, `Project::booted()` at
`Project.php:118-159`):

- `framework_version_id` is `prohibited` on **every** PATCH — render it read-only
  after create, even when the value is unchanged;
- `assessment_type` and `role_code` freeze once `status ∈ {active, archived}`;
- lifecycle offers only `draft → active` and `active → archived`;
- `potential` ⇒ `role_code = null` and competencies ⊆ {MTG, LAT}; `standard` ⇒
  `role_code ∈ {ICO,FLL,MLL,BUL,SRX}` and competencies assigned to that role;
- `webhook_secret` is write-only — "set a new secret", never rendered or prefilled.

**DESIGN.md.** CLAUDE.md forbids implementing a UI decision that contradicts
DESIGN.md without updating it first. §16 currently prescribes `@tailwindcss/forms`
and "VeeValidate or Zod"; the codebase uses shadcn-vue `Field`/`FieldGroup`/
`FieldError`. Its *semantics* (`aria-invalid`, `aria-describedby` → message id,
i18n-keyed messages, errors after blur) remain binding and are preserved verbatim.
The rewrite replaces the named libraries, records the ratified login form contract,
and adds a **control-height / input sizing token** (the user asked for larger inputs
— this is a token decision, not per-page CSS). Per DESIGN.md §17 the `@theme` block
must be updated in **both** Nuxt repos' `assets/css/main.css` in the same commit, so
this touches the `frontend/` submodule too. §8.2 also gets a scope note where the
built page is narrower than its one-liner.

**shadcn-vue components** are installed via the CLI (`bunx --bun shadcn-vue@latest
add ...`), never hand-rolled.

**API.** Additive routes and additive nullable columns only. No existing endpoint
changes shape. Scramble regenerates `openapi.json`; both Nuxt apps regenerate their
typed client and `bun run codegen:check` gates drift.

## Size and Delivery

This change is large and spans all three submodules. It **must** be chained.

- `Chained PRs recommended: Yes`
- `400-line budget risk: High`
- `Decision needed before apply: Yes` (delivery strategy is `ask-on-risk`)

Proposed slice boundaries, each with an autonomous scope and its own verification:

| Slice | Repo | Content |
|---|---|---|
| 1 | wrapper + `frontend` + `backoffice` | DESIGN.md §16 rewrite, §8.2 scope note, input sizing token in both `@theme` blocks, shadcn-vue component installs |
| 2a | `backoffice` | `/projects` list: `useProjects`, table, empty/error states, Vitest |
| 2b | `backoffice` | `/projects` create/edit `ProjectForm` incl. immutability mirroring, Vitest + Playwright |
| 3 | `api` | `organization-settings`: profile + webhook defaults, migration, Pest, cross-tenant |
| 4 | `api` | `user-management`: users + roles, Pest incl. privilege-escalation and last-admin |
| 5 | `api` | `admin-read-api` delta: evaluations index + summary, Pest |
| 6 | `backoffice` | `/settings` tabs wired to slices 3, 4 and the existing m2m clients API |
| 7 | `backoffice` | `/reports` wired to slice 5 |

Slices 3, 4 and 5 are independent of each other and may run in parallel; 6 depends on
3+4, and 7 on 5. Slice 1 gates 2a/2b/6/7.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `backoffice/app/pages/projects/index.vue` | New | Project CRUD page |
| `backoffice/app/pages/reports/index.vue` | New | Cross-participant evaluations index |
| `backoffice/app/pages/settings/index.vue` | New | Four-tab settings surface |
| `backoffice/app/composables/useProjects.ts` + 4 more | New | Typed `apiFetch` wrappers |
| `backoffice/app/components/organisms/ProjectForm.vue` + settings forms | New | Form organisms |
| `backoffice/app/components/ui/{select,dialog,textarea,checkbox,toggle-group}` | New | shadcn-vue CLI installs |
| `backoffice/i18n/locales/{en,it}.json` | Modified | All new user-facing strings |
| `backoffice/types/api.ts` | Modified | Regenerated from `openapi.json` |
| `api/app/Http/Controllers/Api/OrganizationController.php` | New | Profile + webhook defaults |
| `api/app/Http/Controllers/Api/UserController.php`, `RoleController.php` | New | RBAC admin surface |
| `api/app/Http/Controllers/Api/EvaluationIndexController.php` | New | Reports index + summary |
| `api/app/Policies/{OrganizationPolicy,UserPolicy}.php` | New | Admin-only gates |
| `api/database/migrations/*_add_settings_to_organizations_table.php` | New | Additive nullable columns |
| `api/routes/api.php` | Modified | Additive route registrations |
| `DESIGN.md` §16, §8.2 | Modified | Stale form section; scope notes |
| `frontend/assets/css/main.css` | Modified | `@theme` parity per §17 |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Organization profile silently absorbs PARKED white-label scope | Med | Explicit boundary above: administrative identity only. No logo/colour/domain fields. Reject any such field in spec review |
| Org webhook defaults break C10 delivery resolution | Med | Copy-on-create, not runtime fallback. `webhooks-integration` "Secret resolution" requirement stays untouched |
| Privilege escalation via user-management | **High** | Admin-only policy; `organization_id`/`is_superadmin` non-fillable; role allow-list `Rule::in`; last-admin + self-demotion guards; dedicated Pest tests per invariant |
| ICO/FLL/MLL/BUL/SRX confused with admin/operator/viewer | Med | Distinct i18n keys and distinct API field names (`role` vs `role_code`); `identity-auth` allow-list test stays green |
| `/reports` leaks scores for non-`completato` participants | Med | Lifecycle read-gate inherited from `admin-read-api`, asserted in Pest |
| Cross-tenant leak on any of the 5 new endpoints | Med | Explicit-where pattern; dedicated cross-tenant Pest per endpoint (mirrors `AdminCrossTenantIsolationTest`) |
| Project form diverges from server immutability → unexplained 422s | High | Mirror all three server rules in the form; Playwright asserts fields are disabled on an active project |
| Input sizing token regresses the candidate `frontend` visually | Med | §17 mandates both `@theme` blocks in one commit; frontend Vitest snapshots updated in slice 1; Lighthouse rerun |
| Lighthouse A11y/Best-Practices 100 regression on three new routes | Med | Lazy routes + code splitting; axe-core in Playwright; never `--color-success`/`--color-warning` as text on white (§9) |
| Scope sprawl across 7 slices in 3 submodules | High | Chained PRs with explicit dependency order; each slice independently revertable |

## Rollback Plan

Per-slice, feature branch only, no deploy.

- **Frontend slices (1, 2a, 2b, 6, 7):** purely additive route/page files. Revert the
  branch; the sidebar links return to their current dead state — no worse than today.
  DESIGN.md and the `@theme` blocks revert together as one commit per §17.
- **API slices (3, 4, 5):** additive routes plus additive nullable columns. Revert the
  branch and run the down migration (drops `default_*` columns on `organizations`).
  No existing endpoint changes shape, so no consumer breaks. Regenerate
  `openapi.json` and both typed clients; `bun run codegen:check` proves parity.
- Wrapper submodule pointers are reverted to the previous pinned commits.

## Dependencies

- Slice 1 (tokens + shadcn-vue components) gates every UI slice.
- Slices 6 and 7 depend on API slices 3/4 and 5 respectively, including regenerated
  `openapi.json` and typed clients.
- `spatie/laravel-permission` teams mode (already installed, C2) for slice 4.
- Legal sign-off on product decision 2 is **not** a dependency — retention
  configuration is out of scope by design.
- No dependency on product decision 9 (white-label, PARKED) — the boundary above
  keeps this change clear of it.

## Success Criteria

- [ ] All six sidebar links resolve to a real page; no Nuxt 404 on any nav item.
- [ ] `/projects` supports create, edit, archive, with immutable fields visibly disabled on active/archived projects and zero unexplained 422s.
- [ ] `/settings` exposes four working tabs: organization profile, API keys (raw key shown exactly once), webhook defaults (secret write-only), users and roles.
- [ ] `/reports` lists evaluations across participants with filters and aggregate stats, and never exposes scores for non-`completato` participants.
- [ ] Every new endpoint has a passing cross-tenant isolation Pest test returning `404` for a foreign id.
- [ ] User-management privilege-escalation invariants (1–6 above) each have a dedicated failing-then-passing Pest test.
- [ ] DESIGN.md §16 matches the implementation; `@theme` blocks in both Nuxt repos agree.
- [ ] Every user-facing string resolves from `en` and `it` locale files; no hardcoded copy.
- [ ] Coverage ≥ 85% overall; Vitest, Pest and Playwright (chromium + webkit) green in CI; mobile project still passes the SA-11 gate.
- [ ] Lighthouse Accessibility 100 and Best Practices 100 on all three new routes.
- [ ] `bun run codegen:check` green in both Nuxt apps.

## Proposal Question Round

Execution mode is `automatic`, so these could not be asked interactively. Each is a
product decision, not a harness detail. `sdd-spec` must not silently invent answers.

1. **New user onboarding** — does an admin set an initial password directly (assumed,
   no email dependency), or does the system send an invite? An invite couples this to
   C12 notifications and adds a token lifecycle.
2. **Organization `default_locale`** — genuinely wanted as a project-creation prefill,
   or is it speculative? If speculative, drop the column and ship name-only.
3. **Webhook defaults semantics** — is copy-on-create the intended behaviour, or do
   operators expect changing the org default to retroactively affect live projects?
   Retroactive resolution is a C10 spec change and is assumed rejected.
4. **Reports aggregates** — is "mean competency score per competency code across the
   filtered set" the metric operators actually want, or something closer to a
   per-project readiness rollup?
5. **Reports export** — CSV export is assumed out of scope because it would modify
   `admin-read-api` → "Downloadable Artifacts Are Limited to Transcript and
   Evaluation". Confirm, or reopen as its own change.
6. **User deactivation vs deletion** — is `DELETE /api/users/{id}` a hard delete or a
   soft deactivation? Hard delete of a user who authored audit-relevant actions may
   be undesirable; soft deactivation is assumed safer but adds a column.
