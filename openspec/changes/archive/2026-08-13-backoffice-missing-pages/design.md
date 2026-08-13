# Design: Backoffice Missing Pages — `/projects`, `/reports`, `/settings`

## Verification log

Every claim below was opened in this session. Nothing is inherited untested from the
proposal or the exploration.

| Claim | Evidence |
|---|---|
| Only 15 shadcn-vue components are vendored; `tabs`, `select`, `dialog`, `alert-dialog`, `textarea`, `checkbox`, `toggle-group` are all absent | glob of `backoffice/app/components/ui/*/index.ts` |
| `FieldSet` / `FieldLegend` / `FieldError` / `FieldDescription` ARE already vendored | `backoffice/app/components/ui/field/index.ts:24-33` |
| §16's `@tailwindcss/forms` claim is only HALF stale — the plugin is really installed and loaded | `backoffice/package.json:44`, `backoffice/app/assets/css/main.css:6` |
| §16's "VeeValidate or Zod" IS stale — neither is a dependency of either app | `backoffice/package.json` (no match), `login.vue:116-132` hand-rolls blur validation |
| Input control height today is `h-8` (32 px) with a `md:text-sm` (14 px) downshift that always applies on a ≥1024 px-only product | `backoffice/app/components/ui/input/Input.vue:28`, `DESIGN.md:332-336` |
| shadcn `--input` (control border) is `#e2e8f0` on a `#f8fafc`/white surface ≈ **1.2:1** | `main.css:155,131`; `DESIGN.md:514` demands **≥ 3:1** for UI components |
| `organizations` has `name`, `slug` only — no settings columns | `2026_07_16_200000_create_organizations_table.php:14-21`, `Organization.php:20` |
| `users` already carries `organization_id` (indexed) + `is_superadmin`; both are non-fillable | `2026_07_16_200001_add_organization_id_to_users_table.php:22-32`, `User.php:41-49` |
| Spatie's `roles` table does **not** collide with the BEAI framework role catalog | `create_roles_table.php:10-18` creates `framework_roles`; `config/permission.php:43` keeps Spatie on `roles` |
| The `team_id = NULL` trap is documented in two live files | `ProvisionOrganizationCommand.php:147-161`, `RolesAndPermissionsSeeder.php:49-59` ("both this and the explicit `team_id` are required") |
| `TenantContext` runs on **every** `/api/*` route (globally appended), after `auth:api`, and already calls `setPermissionsTeamId($orgId)` | `bootstrap/app.php:78`, `TenantContext.php:44-50` |
| The codebase already treats 404-vs-403 as an enumeration oracle | `bootstrap/app.php:84-89` (CheckAbility before SubstituteBindings, for exactly this reason) |
| `evaluations` indexes are `unique(participant_id)` + `(organization_id, participant_id)` — **nothing on `evaluated_at`** | `2026_07_22_000001_create_evaluations_table.php:65-68` |
| `competency_results` has `(organization_id, evaluation_id)` and `unique(evaluation_id, competency_code)`; `score` is nullable, `reliability` is a `[0..1]` decimal | `2026_07_22_000002_create_competency_results_table.php:46-65` |
| There is **no** evaluation-level `reliability` or overall-score column anywhere | `Evaluation.php:54-62` (fillable), `AdminEvaluationSerializer.php:105-118` (per-competency only) |
| `projects.webhook_secret` is `text` + encrypted cast; `webhook_events` is `jsonb` defaulting to both types | `create_projects_table.php:44-45`, `add_webhook_events_to_projects_table.php:31-33` |
| A "field-specs" endpoint exists only because the avatar-template field SET varies per provider | `ProviderFieldSpecs.php:39-50` — projects have a fixed field set, so the precedent does not transfer |
| Reference house pattern for a page + composable + error mapping | `useParticipants.ts:16-30`, `participants/index.vue:60-88`, `utils/error-state.ts:24-35` |
| Ratified two-level form feedback | `login.vue:11-26` (field level) and `:47-63` (form-level `role="alert"` adjacent to the CTA) |

## Resolved product decisions (settled inputs, not re-opened here)

1. Admin sets the initial password directly. No invite token, no C12 coupling.
2. Organization `default_locale` is **dropped**. Profile is name-only.
3. Webhook defaults are **copy-on-create**. `webhooks-integration` (C10) is untouched.
4. Reports aggregate = mean competency score per competency code across the filtered set.
5. CSV export out of scope; PDF export remains a C11 non-goal.
6. User deletion is soft **deactivation**.

## Technical Approach

Three API slices, each additive: one self-resolving `organization` singular resource, one
admin-only `users` surface, one `evaluations` read surface that extends the C11
`admin-read-api` group and inherits its tenancy and lifecycle discipline. Zero new tables —
three additive migrations (two column sets, one index). On the backoffice side, three routes
built strictly on the `participants` house pattern, seven new shadcn-vue components installed
via the CLI, and a DESIGN.md §16 rewrite plus a control-sizing token that lands in both Nuxt
apps in one commit per §17.

The through-line of the API decisions: **make the dangerous thing structurally impossible
rather than procedurally forbidden**, exactly as C11 D1/D2 did. The reports gate is a query
predicate that lives in one builder; the user reader is one method with a mandatory org
filter; the role allow-list is code, not data.

## Sequence — `/reports`

```
Backoffice SPA                                    API
 GET /evaluations?project_id&…  ──Bearer──▶ auth:api → TenantContext
                                              (orgId, setPermissionsTeamId)
                                                    │
                                         EvaluationIndexController
                                                    │
                                    EvaluationIndexQuery::build($filters)   ← ONE place
                                      Evaluation (TenantModel: org scope automatic)
                                      join participants  p.status = 'completato'   ┐ gate
                                      join projects      e.status in (completed,    │ is a
                                                                     pending)       ┘ predicate
                                                    │
                                      Gate::authorize('viewAny', Evaluation)  → 403
                                                    │
                                    page ids ──▶ ONE grouped query over
                                                 competency_results (no N+1)
 ◀──────────────── 200 paginated rows ──────────────┘
```

## Architecture Decisions

### D1 — Data model: three additive migrations, zero new tables

| Migration | Change | Why |
|---|---|---|
| `add_settings_to_organizations_table` | `default_webhook_url` (string 2048, null), `default_webhook_secret` (`text`, null, encrypted cast + `hidden`), `default_webhook_events` (`jsonb`, null) | Mirrors `projects` column types verbatim (`create_projects_table.php:44-45`, `add_webhook_events…:31`) so a copy is a straight assignment, not a conversion. **Nullable with no default** — unlike `projects.webhook_events`, absence here means "no default", which is a real and distinct state |
| `add_deactivated_at_to_users_table` | `deactivated_at` (`timestampTz`, null) | D5 |
| `add_evaluated_at_index_to_evaluations_table` | `index(['organization_id','evaluated_at'])` | D7 — the reports sort and date filter are both on `evaluated_at`, which no existing index covers |

CLAUDE.md requires every **new table** to carry `organization_id` and lead composites with it.
No new table is created, so the rule is satisfied by construction; the one new composite index
leads with `organization_id`. `organizations` itself takes no `organization_id` because its `id`
*is* the tenant key — a self-referential column would be a second source of truth for tenancy.

| Option | Tradeoff | Decision |
|---|---|---|
| Additive nullable columns on `organizations` | One row per tenant, one read, no join, no lifecycle of its own. Reversible by dropping three columns | **CHOSEN** |
| A separate `organization_settings` table | Would need `organization_id` + a unique constraint + a create-on-demand path, and turns every read into a nullable join for data that is 1:1 with the tenant | Rejected |
| A generic key/value settings table | Untyped values, no validation at the schema boundary, and Scramble cannot describe it. The exact "flexible" shape that becomes unqueryable | Rejected |

No new index on `users`: the existing single-column `index('organization_id')` serves a list of
tens of rows ordered by name, and the list deliberately shows deactivated users too (D5), so
there is nothing to filter on. Adding a composite here would be cargo cult.

### D2 — Organization settings: a singular, self-resolving resource

`GET /api/organization`, `PATCH /api/organization`. No id in the path, ever.

The org is read as `Organization::findOrFail($resolver->getOrgId())`. `Organization` is a plain
`Model` (no `TenantScoped`), so this follows the explicit-resolve discipline of
`M2m/ParticipantController.php:110-111` — but with a stronger property: **the route accepts no
identifier at all**, so there is no IDOR surface to test, no cross-org id to 404, and no way for
a future refactor to introduce one.

Authorization: read for any org member, write `admin` only, via a new `OrganizationPolicy`
following `ProjectPolicy.php:30-41` verbatim. `slug` is read-only in the resource and rejected
by the FormRequest — it is a tenancy identifier, not a display field.

| Option | Tradeoff | Decision |
|---|---|---|
| `/api/organization` singular | No IDOR surface exists; the caller can only ever address their own org | **CHOSEN** |
| `/api/organizations/{id}` | Introduces an id that must be compared against the tenant context on every verb, forever, in every future action | Rejected |

### D3 — Webhook defaults: copy-on-create, and "absent" ≠ "explicitly null"

Defaults are applied in `ProjectController::store` through a small `ProjectWebhookDefaults`
applier, before create. It fills a key **only when the request payload does not contain it** —
`$request->exists('webhook_url')`, not `filled()`. An operator who explicitly sends
`"webhook_url": null` means "this project has no webhook" and must not have the org default
silently reinstated; `filled()` cannot tell those two apart and would.

Delivery-time resolution (`webhooks-integration` → "Secret resolution — Eloquent-only, never
exposed") is not read, not called, not modified. C10 behaviour is byte-identical.

| Option | Tradeoff | Decision |
|---|---|---|
| Copy-on-create | New projects inherit; live projects keep whatever they were configured with. Zero C10 spec delta | **CHOSEN** |
| Runtime fallback (`project.webhook_url ?? org.default_webhook_url`) | Changing one org field silently re-points every project's live deliveries, including ones deliberately left blank. Modifies a C10 correctness requirement | Rejected |
| Backfill existing projects on save | Retroactive by another name, and irreversible | Rejected |

`default_webhook_secret` is write-only: `hidden` + `encrypted` cast, never serialized, never
prefilled. The UI offers "set a new secret" and shows whether one is configured (a boolean
`has_default_webhook_secret`), never the value.

### D4 — User management authorization (privilege-escalation surface)

Endpoints, all `admin`-only for **every** verb via a new `UserPolicy` (`operator`/`viewer` → 403):

| Method / path | Notes |
|---|---|
| `GET /api/users` | org-scoped list, includes deactivated (badged) |
| `POST /api/users` | name, email, password, role — admin sets the initial password (decision 1) |
| `PATCH /api/users/{id}` | name, email, role, optional password reset |
| `POST /api/users/{id}/deactivate` | 204, D5 |
| `POST /api/users/{id}/activate` | 200, D5 |

**Deliberate deviation from proposal §C:** no `GET /api/roles`, and no `DELETE`.

- *No roles endpoint.* The allow-list is three constants. Shipping it as a backed enum
  `App\Enums\OrgRole` on the user resource means Scramble emits `role: "admin"|"operator"|"viewer"`
  into `openapi.json`, so the backoffice's generated client already carries the allow-list with
  zero drift and zero extra authorization surface. A `/api/roles` route would also sit one
  segment away from `/api/framework/roles` (ICO/FLL/MLL/BUL/SRX) — the exact confusion the
  proposal's invariant 4 forbids, encoded in the URL.
- *No `DELETE`.* A `DELETE` that does not delete is a lie in the contract: a reviewer reading
  `routes/api.php` reasonably assumes row removal. Explicit `deactivate`/`activate` verbs mirror
  the `POST /avatar-templates/{id}/activate` precedent (`routes/api.php:91`).

**Reader.** `UserAdminReader::read(int $id): User` is the only path to a `User` in this surface:

```php
User::where('organization_id', $this->resolver->getOrgId())
    ->where('is_superadmin', false)
    ->findOrFail($id);
```

Cross-org id → `ModelNotFoundException` → **404, not 403**. A 403 confirms the row exists and
turns the endpoint into a cross-tenant existence oracle; the codebase already reasons this way at
`bootstrap/app.php:84-89`. The `is_superadmin = false` predicate means a platform superadmin who
happens to carry an `organization_id` is invisible here — not demotable, not deactivatable, not
listable — enforcing proposal invariant 2 at the query layer rather than in a serializer.

**Role assignment — two mandatory halves.** `TenantContext.php:50` already calls
`setPermissionsTeamId($orgId)` on every request, and that is *still not enough*.
`ProvisionOrganizationCommand.php:147-161` and `RolesAndPermissionsSeeder.php:49-59` both record
why: the registrar governs Spatie's own `Role::create()`, but a role row written through any
other path lands with `team_id = NULL` and becomes invisible to every teams-mode `hasRole()`
check — a silent, total authorization failure that looks like "the role just doesn't work". So:

```php
$role = Role::where('name', $validated['role'])   // never assignRole('admin') by string
    ->where('guard_name', 'api')
    ->where('team_id', $orgId)                     // explicit, never ambient
    ->firstOrFail();
$user->syncRoles([$role]);
app(PermissionRegistrar::class)->forgetCachedPermissions();
```

Assigning by resolved `Role` model rather than by name string is the fail-closed choice: a string
resolves through the registrar's ambient team, so a future code path that reaches this service
without `TenantContext` (a console command, a job) would attach — or create — a NULL-team role
and pass silently. `firstOrFail()` on an explicit `team_id` throws instead.

**Validation: `Rule::in(OrgRole::values())`, never `Rule::exists('roles','name')`.**

| Option | Tradeoff | Decision |
|---|---|---|
| Hard-coded allow-list in code (`Rule::in`) | Reviewed, diffable, and unaffected by data. `identity-auth`'s locked `admin\|operator\|viewer` vocabulary cannot widen by accident | **CHOSEN** |
| `Rule::exists('roles','name')` | Makes the set of assignable roles **data**. Any seeder, migration, or future feature that inserts a row into `roles` instantly makes it grantable — and `roles` is a table other code writes. It would also accept another tenant's role name | Rejected |
| Policy-only check, no validation rule | A 403 for a typo'd role name is the wrong signal, and the check would run after mass assignment | Rejected |

**Guards (`UserGuards`, throwing `UserGuardException` → 422 with a machine-readable `error` code,
registered once in `bootstrap/app.php` beside the existing four renders):**

| Guard | `error` code | Applies to |
|---|---|---|
| Org must retain ≥ 1 active admin | `last_admin` | role change away from admin, deactivate |
| Cannot change your own role | `self_demotion` | PATCH where `{id} === auth()->id()` |
| Cannot deactivate yourself | `self_deactivation` | deactivate |

The count-then-write is wrapped in a transaction with `lockForUpdate()` on the admin assignment
rows. Two admins demoting each other concurrently would otherwise both observe "2 admins exist"
and commit, leaving the organization with zero admins and no way back in. This is a real race,
not a theoretical one — it is exactly the shape of a two-person team tidying up permissions.

Guards live in a support class rather than in FormRequests because they must hold for the role
path *and* the deactivate path *and* any future console command; a FormRequest rule would be
duplicated twice today and forgotten the third time.

`organization_id` and `is_superadmin` stay out of `$fillable` (`User.php:41-49`); the new user's
org comes from `TenantContext`, and a body-supplied value is ignored, never honoured.

**Naming.** The API field is `role` (auth) and never `role_code` (BEAI organizational role,
`Project.role_code`). i18n keys are `users.role.*` versus the existing `projects.roleCode.*`. UI
copy says "Access level" for the auth role, so the bare word "role" is never ambiguous on screen.

### D5 — Soft deactivation: an explicit column, and a live-token kill switch

`deactivated_at` (nullable `timestampTz`), **not** Laravel `SoftDeletes`.

| Option | Tradeoff | Decision |
|---|---|---|
| Explicit `deactivated_at`, no global scope | The row stays visible to audit joins and to the user list (badged "deactivated"), which is the entire point of choosing deactivation over deletion | **CHOSEN** |
| `SoftDeletes` (`deleted_at`) | Its global scope hides the row from *every* query — including `audit_logs` displays and any join that reports who did what. It also makes the jwt-auth user lookup return null, i.e. deactivation semantics by accident rather than by design | Rejected |
| Hard delete | `users.organization_id` is `restrictOnDelete` (`add_organization_id…:25`) and audit trails would dangle | Rejected |

A deactivated user holds a valid JWT for up to 30 minutes (`config/jwt.php:108`), and there is no
token registry to revoke against. The enforcement point is therefore `TenantContext`, immediately
after the null-user pass-through: it already loads the user from the DB on every `/api/*` request
(`bootstrap/app.php:78`), including `/auth/refresh` and `/auth/me`. One check, every route,
present and future, with no per-controller discipline.

Response: **403** with `{"error": "account_deactivated"}` — matching the adjacent fail-closed
branch at `TenantContext.php:69` and the machine-facing (non-localized) body convention. Not 401:
a 401 would trigger the backoffice's single-flight refresh (C11 D11) and surface as "your session
expired", which is a misleading story for an account somebody deliberately disabled. `useApi`
maps this one code to session-clear + redirect to `/login`. Login itself returns the same generic
invalid-credentials response as always — `login.vue:47-54` is explicit that this form must not
become a user-enumeration oracle, and "this account is disabled" would make it one.

### D6 — Reports: the lifecycle gate is a query predicate, not a serializer nullification

One builder, `EvaluationIndexQuery::build(EvaluationIndexFilters): Builder`, is the sole source of
both endpoints' row set. It applies, unconditionally:

```
Evaluation (TenantModel → org scope automatic)
  join participants p  … and p.organization_id = :org     (belt and braces: plain Model)
  join projects pr     … 
  where p.status = 'completato'
    and e.status in ('completed', 'pending')              -- never 'processing'
```

| Option | Tradeoff | Decision |
|---|---|---|
| Gate as a join predicate in one shared builder | A participant who is not `completato` is structurally absent. Adding a column to the resource later cannot leak, because there is no row to leak from. Both endpoints provably see the same set | **CHOSEN** |
| List everything, null out scores for non-`completato` | The gate becomes serializer discipline: correct until the next field is added. Also produces rows with nothing in them, on a page whose unit of meaning is "a scored result" | Rejected |
| Reuse `LifecycleReadGate::assert()` per row | It is a throw-based gate designed for single-resource reads (409 = "come back later"); a list has no single status to be conflicted about, and 409-ing a whole page because one row is mid-scoring is wrong | Rejected — the gate object stays untouched and keeps owning single-resource reads |

In-flight participants are not lost to operators: `/participants` already lists every lifecycle
state, and `/dashboard/metrics` already counts them. `/reports` is the scored-results surface, and
a row click navigates to the existing `/participants/{id}` — no second report renderer (C11 owns
`EvaluationReport.vue`).

**Row shape:** `participant_id`, `candidate_ref`, `display_name`, `project_id`, `project_name`,
`assessment_type`, `role_code`, `evaluated_at`, `status` (`completed`|`pending`, the ≥90% gate),
`reliability` as a verbatim percent string via the reused `ReliabilityRenderer` — no High/Medium/Low
bands (ratified decision 1). **No overall candidate score**: none exists in the schema or in
`AdminEvaluationSerializer`, and deriving one here would bake an unratified business rule into a
list view. DESIGN.md §8.3's "Score: 3.8 / 5.0" is mock text in an ASCII diagram, not a shipped field.

**Filters** (whitelisted through an `EvaluationIndexRequest` FormRequest, so no raw input reaches
the builder): `project_id` (int), `assessment_type` and `role_code` (`Rule::in` against the domain
enums), `status` (`Rule::in(['completed','pending'])`), `evaluated_from` / `evaluated_to` (ISO-8601
dates). Sort is **fixed** at `evaluated_at desc, id desc` — no client-specified column reaches the
query builder, per C11 D5.

**The `reliability >= threshold` filter from the proposal is dropped.** There is no
evaluation-level reliability column (verified: `Evaluation.php:54-62`); it is an aggregate over
`competency_results`, so filtering on it means `HAVING avg(...)`, which no index can serve and
which makes `COUNT(*)` for pagination a full aggregate scan. The two alternatives are worse: a
denormalized `evaluations.reliability` column would put a migration and a write-path change inside
C9's scoring engine — a ~95%-coverage correctness zone — to serve a list filter. Per-row
reliability is still **displayed** (below); the filter can return later, owned by C9, if operators
ask for it.

**N+1 and index strategy.** Two queries per request, never per row:

1. The paginated page (20 rows) over the join above. Served by the new
   `(organization_id, evaluated_at)` index for the date range and the fixed sort;
   `participants(organization_id, project_id)` and `(organization_id, status)`
   (`create_participants_table.php:66-67`) serve the joins and the gate predicate.
2. One grouped query for the page's ids:
   `select evaluation_id, avg(reliability), count(score) from competency_results
    where organization_id = :org and evaluation_id in (:pageIds) group by evaluation_id`
   — covered by the existing `(organization_id, evaluation_id)` composite.

`projects` is eager-loaded through the join, not lazily per row.

### D7 — Reports summary: one grouped query over the same filtered set

`GET /api/evaluations/summary` takes the identical filter set and calls the **same**
`EvaluationIndexQuery::build()` (minus pagination) as a subquery, so the summary can never
describe a different population than the table above it.

```sql
select cr.competency_code,
       round(avg(cr.score)::numeric, 2) as mean_score,
       count(cr.score)                  as scored_count,
       count(*)                         as result_count
from competency_results cr
where cr.organization_id = :org
  and cr.evaluation_id in ( <EvaluationIndexQuery, ids only> )
group by cr.competency_code
order by cr.competency_code
```

Plus counts by `evaluations.status` from the same subquery. Decisions inside the aggregate:

- **`avg` over non-null `score` only** — SQL `AVG` already ignores NULLs, which is exactly the CC2
  semantic (`CompetencyResult.php:39,67`: all-indicators-unassessable → NULL score, excluded).
  `scored_count` and `result_count` are both returned so a mean built from 3 of 40 evaluations is
  visibly weak rather than quietly authoritative.
- **No `valid = true` filter.** Validity is `reliability ≥ T` with `T` env-overridable (CLAUDE.md
  product decision 1). Filtering on it would make the same historical data report different means
  on two deployments. Aggregate over what was scored; expose the counts; let the operator judge.
- **`round(avg(...)::numeric, 2)`** in Postgres, not PHP float math, matching the 2dp convention of
  `competency_results.score` (`decimal(5,2)`) and avoiding binary-float drift in a number operators
  will compare across pages.

Cost is O(competency results in the filtered set) with no per-row PHP work; the
`(organization_id, evaluation_id)` index serves the IN-subquery. Revisit with a rollup table only
if `EXPLAIN` shows a spill — same posture as C11 D5.

### D8 — Backoffice component structure

Follows `participants/index.vue` + `[id].vue` (page holds `ref` state, loads in `onMounted`, maps
failures through `resolveResourceErrorState`/`resourceErrorKey`, `editing` ref drives a separate
form organism). **`avatar-templates/index.vue` is not the model** — it uses raw `<button>` elements
where the shadcn `Button` belongs, and replicating that would spread a known defect.

| Layer | Component | Responsibility |
|---|---|---|
| atom | `AccessLevelBadge.vue` | `admin`/`operator`/`viewer`, i18n-labelled — deliberately NOT named RoleBadge |
| atom | `UserStateBadge.vue` | active / deactivated |
| atom | `ProjectStatusBadge.vue` | `draft`/`active`/`archived` |
| molecule | `WriteOnlySecretField.vue` | "set a new secret" + "a secret is configured" state; never renders a value |
| molecule | `CompetencyPicker.vue` | `FieldSet` + `FieldLegend` + `Checkbox` grid, filtered by role/assessment type |
| molecule | `ReportFilters.vue` | the whitelisted filter set, emits one filter object |
| molecule | `ConfirmDialog.vue` | `AlertDialog` wrapper for archive / deactivate |
| organism | `ProjectTable.vue`, `ProjectForm.vue` | D9 |
| organism | `OrganizationProfileForm.vue`, `WebhookDefaultsForm.vue` | settings tabs 1–2 |
| organism | `ApiKeysPanel.vue` | tab 3, over the existing C5 `/m2m/clients` API; raw key shown exactly once |
| organism | `UsersPanel.vue` + `UserForm.vue` | tab 4 |
| organism | `EvaluationsTable.vue`, `ReportSummary.vue` | `/reports` |
| composable | `useProjects`, `useOrganization`, `useUsers`, `useApiClients`, `useEvaluations` | thin `useApi().apiFetch` wrappers typed off `paths[...]`, exactly `useParticipants.ts:16-30` |

Every component gets a matching Vitest test (DESIGN.md §5).

### D9 — Project form mirrors server immutability, or it manufactures 422s

The rules are enforced three times server-side (`StoreProjectRequest`, `UpdateProjectRequest`,
`Project::booted()` at `Project.php:118-159`). The form must render them, not discover them:

| Rule | UI |
|---|---|
| `framework_version_id` `prohibited` on every PATCH | Rendered read-only after create, even when unchanged |
| `assessment_type`, `role_code` frozen once `status ∈ {active, archived}` | `disabled` + a `FieldDescription` saying **why** — a silently disabled field reads as a bug |
| Lifecycle: only `draft→active`, `active→archived` | Only the one legal transition is offered as an action |
| `potential` ⇒ `role_code = null`, competencies ⊆ {MTG, LAT} | `CompetencyPicker` options derive from assessment type |
| `standard` ⇒ `role_code ∈ {ICO,FLL,MLL,BUL,SRX}`, competencies of that role | Options come from the existing C3 `GET /framework/roles/{roleCode}/competencies` |
| `webhook_secret` write-only | `WriteOnlySecretField` |

**No new `/projects/field-specs` endpoint.** The C14 precedent exists because the avatar-template
field *set* varies by provider (`ProviderFieldSpecs.php:39-50`); the project field set is fixed and
its only dynamic part — which competencies belong to a role — is already served by C3. Static
bounds (`pause_every_n_competencies` 1–255, `nudge_min_chars` 0–65535, URL max 2048) live in one
`app/utils/project-field-specs.ts` module with its own unit test, and server-side 422s are still
mapped per field, so client/server drift degrades to a normal validation message rather than to a
wrong form.

### D10 — shadcn-vue components: seven installs, CLI only, no hand-rolling

`bunx --bun shadcn-vue@latest add tabs select dialog alert-dialog textarea checkbox toggle-group`
(Bun only — CLAUDE.md forbids npx/pnpm/yarn in the new apps). `tabs` was missing from the
proposal's list and the four-tab settings surface cannot exist without it.

**Competency multi-select uses `FieldSet` + `FieldLegend` + `Checkbox`, not a combobox.** A role
carries 14–18 competencies and operators select most of them; a `ToggleGroup` is the documented
choice for 2–7 options, and a multi-select `Combobox` would pull in `command` + `popover`, hide the
full set behind a popover, and put the hardest accessibility surface in the product directly in
front of a non-negotiable Lighthouse 100. `FieldSet`/`FieldLegend` are already vendored
(`field/index.ts:30,32`) and are natively navigable. `ToggleGroup` is still installed — it is the
right control for `assessment_type` (2 options) and the report status filter.

**Code splitting (DESIGN.md §14, SPA).** Nuxt route chunks are per-page by default; the risk is
pulling form organisms and dialogs into a route's initial chunk. So: every form organism and every
dialog is imported with `defineAsyncComponent`, settings tab panels mount lazily (only the active
tab), and nothing new is registered globally. Accessibility 100 and Best Practices 100 are
non-negotiable; Performance ≥ 90.

### D11 — DESIGN.md §16 rewrite

§16 is replaced (its **semantics stay binding and are preserved verbatim**; only the named
libraries and the state classes change). One correction to the proposal's framing: `@tailwindcss/forms`
is *not* stale — it is installed (`package.json:44`) and loaded (`main.css:6`). What is stale is its
described role and the "VeeValidate or Zod" line (neither is a dependency of either app).

New §16 content:

1. **Structure.** `FieldGroup` > `Field` > `FieldLabel` + control + `FieldError` / `FieldDescription`.
   Never a raw `div` with `space-y-*`. `FieldSet` + `FieldLegend` for grouped checkboxes/radios.
2. **Base styling.** `@tailwindcss/forms` stays as a Preflight-level reset only. Visual state lives
   in the vendored shadcn-vue components; pages must not re-style controls with `class`.
3. **Validation.** No VeeValidate, no Zod. Per-field validate functions run **on blur** and again on
   submit (all fields validated, never short-circuited — `login.vue:137-146`). Server 422s map to
   field-level messages through the typed client.
4. **Accessibility (unchanged, binding).** `data-invalid` on `Field`, `aria-invalid` on the control,
   `aria-describedby` pointing at the message element's id, id convention `{form}-{field}-error`.
5. **Two-level feedback contract (ratified, new).** Field-level messages render directly under their
   own field. The form-level success/error banner renders **adjacent to the submit CTA** with
   `role="alert"` and `aria-live="polite"` — not at the top of the card, because it sits where the
   eye already is after pressing the button, and because outcomes that cannot be attributed to a
   single field must not masquerade as field errors. Reference: `login.vue:47-63`,
   `tests/unit/login.spec.ts`.
6. **i18n.** Every message is a key in `i18n/locales/{en,it}.json`. No literal ever.
7. **Disabled/immutable fields** carry a `FieldDescription` explaining why. Silent disabling is a bug.
8. **Control sizing** — D12.
9. **Testing.** Assertions target `data-testid`, never CSS selectors.

§8.2 also gains a scope note where the shipped page is narrower than its one-liner (project detail,
webhook log, data management remain unbuilt).

### D12 — Control sizing token: `--spacing-control: 2.75rem`, in both apps, one commit

The user asked for noticeably larger inputs. That is a token decision, not per-page styling.

| Token | Value | Use |
|---|---|---|
| `--spacing-control` | `2.75rem` (44 px) | default height of `Input`, `Select` trigger, `Button`; `min-height` of `Textarea` |
| `--spacing-control-sm` | `2.25rem` (36 px) | dense contexts: table filter rows, inline table actions |

44 px is WCAG 2.2 SC **2.5.5 Target Size (Enhanced, AAA)**. The current 32 px already clears SC
**2.5.8 (Minimum, AA — 24 px)**, so this is a deliberate step *above* the compliance floor rather
than a fix; 36 px keeps dense contexts comfortably above the AA floor. Control font-size becomes
`1rem`: `Input.vue:28` currently ships `text-base md:text-sm`, and since the product is ≥1024 px only
(DESIGN.md §6), the `md:` downshift *always* applies — every input today renders 14 px text under a
16 px label. Removing the downshift makes label and value agree.

**Application mechanism: edit the vendored component base classes to `h-(--spacing-control)`.**
A `@layer components` override loses to Tailwind utilities (utilities layer is later), and an
unlayered global rule would win but would make per-instance `h-*` overrides impossible. shadcn's
model is source-in-your-project, so editing the vendored class string is the sanctioned path —
with the standing rule that `shadcn-vue add --overwrite` is never run without a `--diff` review.

**Contrast finding, §9.** While checking this against §9 I found a live violation, unrelated to the
size change but made worse by it: shadcn `--input` is `#e2e8f0` (`main.css:155`) on a `#f8fafc`/white
surface ≈ **1.2:1**, against §9's "UI components and graphical objects: ≥ 3:1". A larger control with
a border nobody can see is a worse control. Fix: add `--color-neutral-500: #64748b` to the §3.1 ramp
(it is the Tailwind slate step the ramp already follows everywhere else) and map `--input` to it —
**≈4.8:1 on white**, comfortably above 3:1 while staying visually light. `#94a3b8` (neutral-400) was
measured and rejected at 2.6:1; `#475569` (neutral-600) passes at 7.5:1 but reads as a heavy outline.
Note for the record: axe-core has no non-text-contrast rule, which is precisely why this survived
C11's automated gates — it is a manual §9 check, and §9 is binding.

Per §17 this lands as ONE commit touching `DESIGN.md` §3.1/§16 + `backoffice/app/assets/css/main.css`
+ `frontend/app/assets/css/main.css`, with both apps' Vitest snapshots and Playwright screenshot
baselines refreshed in the same slice. OKLCH conversions are produced by a converter at apply time,
never eyeballed (C11 D10).

### D13 — Testing architecture

| Layer | What | How |
|---|---|---|
| Pest — feature, tenancy | all 7 new endpoints | Cross-org id → **404** on every id-bearing route (`/users/{id}`, deactivate, activate); `/organization` and `/evaluations` asserted to return only the caller's org's data. Mirrors `AdminCrossTenantIsolationTest` |
| Pest — feature, privilege escalation (**~95%**) | D4 invariants 1–6, one test each | body-supplied `organization_id` ignored; body-supplied `is_superadmin` ignored; superadmin row invisible (404) to a tenant admin; `Rule::in` rejects `ICO`/`superadmin`/a foreign org's role name (422); role written with the resolved `team_id` and `hasRole()` true after assignment (the NULL-team trap, mirroring `ProvisionOrganizationCommandTest.php:72-81`); last-admin, self-demotion, self-deactivation each 422 with their machine code; concurrent-demotion test asserting the lock holds |
| Pest — feature, RBAC | every verb | `operator` and `viewer` → 403 on all `users` and on `PATCH /organization` |
| Pest — feature, deactivation | live-token kill switch | Authenticated request with a valid JWT after deactivation → 403 `account_deactivated`, including on `/auth/refresh` |
| Pest — feature, reports gate (**~95%**) | `/evaluations`, `/evaluations/summary` | A participant in each of `in_attesa`/`in_corso`/`in_valutazione`/`errore` is absent from both responses; an `evaluations.status = processing` row is absent; summary and index provably describe the same set for the same filters; aggregate correctness against a fixture with NULL scores (mean excludes them) |
| Pest — feature, webhook defaults | copy-on-create | Absent key inherits; explicit `null` does **not** inherit; changing the org default leaves an existing project's stored config untouched |
| Vitest | every new component + page | Established pattern: `vi.doMock` the composable → `vi.resetModules()` → dynamic `import()` of the page; `vi.stubGlobal` for `definePageMeta`/`useHead`/`useI18n`; `mount()` + `flushPromises()`; assert on `data-testid`. Form specs assert the two-level contract: `aria-invalid`, `aria-describedby` → the message id, and a `role="alert"` banner next to the CTA. `ProjectForm` asserts disabled immutables for an active project |
| Playwright — chromium + webkit | projects CRUD, settings tabs, reports filter+summary | Role-based locators only (`getByRole`/`getByLabel`), network-level route interception with fixtures shaped like the real Resources, `@axe-core/playwright` clean on all three routes |
| Playwright — mobile | none new | The `mobile` project runs only `unsupported-gate.spec.ts` (`playwright.config.ts:44-49`) and covers every route generically — no bespoke mobile spec |
| Contract | drift | `php artisan scramble:export` → `task openapi:sync` → `bun run codegen:check` green in both Nuxt apps |

Coverage 85% overall; ~95% on `UserGuards` + `UserAdminReader` and on `EvaluationIndexQuery`.

### D14 — Delivery

The proposal's seven slices stand, with slice 1 amended to include `tabs`, `alert-dialog`, the
`--color-neutral-500` / `--input` contrast fix, and both apps' snapshot refresh.
`Chained PRs recommended: Yes` · `400-line budget risk: High` · `Decision needed before apply: Yes`.
Slices 3/4/5 (api) are mutually independent; 6 depends on 3+4, 7 on 5, and slice 1 gates 2a/2b/6/7.
`sdd-tasks` owns the binding forecast.

## File Changes

| File | Action | Description |
|---|---|---|
| `api/database/migrations/*_add_settings_to_organizations_table.php` | Create | D1 — three nullable webhook-default columns |
| `api/database/migrations/*_add_deactivated_at_to_users_table.php` | Create | D5 |
| `api/database/migrations/*_add_evaluated_at_index_to_evaluations_table.php` | Create | D1/D7 — `(organization_id, evaluated_at)` |
| `api/app/Models/Organization.php` | Modify | fillable + `encrypted`/`hidden`/`array` casts |
| `api/app/Models/User.php` | Modify | `deactivated_at` cast + `isDeactivated()` |
| `api/app/Enums/OrgRole.php` | Create | D4 — the allow-list, in code, exported to `openapi.json` |
| `api/app/Http/Controllers/Api/OrganizationController.php` | Create | D2/D3 |
| `api/app/Http/Controllers/Api/UserController.php` | Create | D4/D5 |
| `api/app/Support/Users/{UserAdminReader,UserGuards}.php` | Create | D4 — org filter + the three guards |
| `api/app/Exceptions/Users/UserGuardException.php` | Create | 422 + machine-readable `error` |
| `api/app/Http/Controllers/Api/EvaluationIndexController.php` | Create | D6/D7 — index + summary |
| `api/app/Support/Admin/EvaluationIndexQuery.php` | Create | D6 — the gate, stated once |
| `api/app/Support/Projects/ProjectWebhookDefaults.php` | Create | D3 — copy-on-create |
| `api/app/Http/Requests/{UpdateOrganizationRequest,StoreUserRequest,UpdateUserRequest,EvaluationIndexRequest}.php` | Create | validation, incl. `Rule::in(OrgRole::values())` |
| `api/app/Policies/{OrganizationPolicy,UserPolicy}.php` | Create | D2/D4 |
| `api/app/Http/Resources/*` | Create | typed responses for Scramble |
| `api/app/Http/Controllers/Api/ProjectController.php` | Modify | D3 — apply defaults on `store` |
| `api/app/Http/Middleware/TenantContext.php` | Modify | D5 — deactivation kill switch |
| `api/bootstrap/app.php` | Modify | register `UserGuardException` → 422 |
| `api/routes/api.php` | Modify | two new groups, additive |
| `backoffice/app/pages/{projects,reports,settings}/index.vue` | Create | the three routes |
| `backoffice/app/composables/{useProjects,useOrganization,useUsers,useApiClients,useEvaluations}.ts` | Create | D8 |
| `backoffice/app/components/{atoms,molecules,organisms}/**` | Create | D8 |
| `backoffice/app/components/ui/{tabs,select,dialog,alert-dialog,textarea,checkbox,toggle-group}/**` | Create | D10 — CLI installs |
| `backoffice/app/components/ui/{input,button,textarea,select}/*` | Modify | D12 — consume `--spacing-control` |
| `backoffice/app/composables/useApi.ts` | Modify | D5 — map `account_deactivated` to forced logout |
| `backoffice/app/utils/project-field-specs.ts` | Create | D9 |
| `backoffice/i18n/locales/{en,it}.json` | Modify | every new string, both locales |
| `backoffice/{openapi.json,types/api.ts}` | Modify | regenerated; `codegen:check` green |
| `frontend/app/assets/css/main.css` | Modify | D12 — `@theme` parity, §17 |
| `DESIGN.md` §3.1, §8.2, §16 | Modify | D11/D12 |

## Migration / Rollout

Three additive migrations, all reversible (`down()` drops the columns / the index). No backfill: a
null `default_webhook_*` means "no default" and a null `deactivated_at` means "active", so existing
rows are already correct. No existing endpoint changes shape, so no consumer breaks. Rollback is
per-slice: revert the branch, run `migrate:rollback` for the API slices, regenerate `openapi.json`
and both typed clients, reset the wrapper submodule pointers. Frontend slices are purely additive
route files — reverting returns the sidebar to today's dead-link state, no worse than now. No deploy.

## Open Questions

- [ ] **`GET /api/roles` removed** (D4) and **`DELETE /api/users/{id}` replaced by explicit
      `deactivate`/`activate`** (D5) — both are deliberate deviations from the proposal's §C shapes.
      Flagged because they are public contract changes; `sdd-spec` should encode the design's shapes.
- [ ] **`reliability >= threshold` filter dropped** from `/evaluations` (D6). Returning it requires a
      denormalized column owned by C9, not this change.
- [ ] **`--color-neutral-500` is a new §3.1 ramp entry** (D12). It fixes a real §9 non-text-contrast
      violation that predates this change, so it touches both apps' theme blocks and their snapshots.
- [ ] Product decision 4 (retry semantics) and 6 (non-English BARS anchors) remain open upstream and
      are untouched here.
