# Proposal: SuperAdmin Acting-Organization Context

## Intent

`TenantContext` (`api/app/Http/Middleware/TenantContext.php:83-95`) resolves a SuperAdmin's
selected client from `ActingOrganization` and stamps `TenantResolver` correctly. Almost nothing
downstream reads it: 13 authenticated call sites read `$user->organization_id`, which for the real
production identity (`organization_id = null` + `is_superadmin = true`) is NULL. Six operator
surfaces are broken in production, one of them silently.

| # | Site (verified) | Symptom |
|---|---|---|
| 1 | `M2m/ApiClientController.php:131` | Settings > API Keys renders always, always empty |
| 2 | `M2m/ApiClientController.php:80` | `api_clients.organization_id` is NOT NULL (migration `2026_07_18_000001:29`, no `nullable()`) → **500**, not an orphan row |
| 3 | `StoreProjectRequest.php:44`, `UpdateProjectRequest.php:87` → `ValidatesProjectComposition::avatarTemplateRule()` | 422 `avatar_template_invalid` on a valid template; same `$orgId` breaks the `framework_version_id` exists rule |
| 4 | same `$orgId` → `Rule::unique('projects','slug')->where('organization_id', $orgId)` | **SILENT: duplicate slugs accepted.** Uniqueness is checked against `organization_id IS NULL`. Nothing surfaces. Fixing only #3 leaves this open |
| 5 | `Api/OrganizationController.php:32,50` (+ wrong docblock `:19`) | Settings > Organization 404 |
| 6 | `Api/ProjectController.php:80` | cannot create a project |
| 7 | `Api/OrganizationLogoController.php:52,153` | logo upload/delete 404 |
| 8 | `UpdateOrganizationRequest.php:27` (not previously listed) | `authorize()` returns false → PATCH /organization **403** |
| 9 | `Api/UserController.php:280` `requireOrgId()` | 409 even when a client IS selected |

**Aggravating factor — tenancy boundary.** `ApiClient` is deliberately not a `TenantModel`
(`tests/Arch/C2/TenantModelArchTest.php:59-65`; the api-m2m guard must query it unscoped). The
explicit `where('organization_id', …)` in #1 **is** the tenant boundary — no global scope
underneath. `UserAbilities.php:62-70` states this: "If that filter ever goes, this answer goes with
it." Sites #1/#2 must be reviewed as a tenancy change, not a list-query tweak.

**Why it shipped.** No test uses the production identity. Every fixture is
`User::factory()->create(['organization_id' => $org->id])`, including the one named superadmin test
(`tests/Feature/C4/ProjectCrudTest.php:297` — superadmin *with* an org). Six endpoints broke
unnoticed for want of one shared fixture.

**Load-bearing assumption (confirmed).** `TenancyServiceProvider.php:27` binds the resolver with
`$this->app->scoped(...)` — one instance per request, so a controller or FormRequest reading it sees
what the middleware wrote. Route middleware runs before FormRequest validation. Had this been
`bind`, the fix would silently no-op.

## Scope

### In Scope

1. **One accessor** — `App\Support\Tenancy\EffectiveOrganization`: `id(): ?int` (TenantResolver
   first, `$user->organization_id` fallback) and `require(): int` (refuses when null). A container
   support class, not a trait (FormRequest and Controller are unrelated base classes; a trait would
   be duplicated and invisible to the arch guard) and not a `User` method (a model reading
   request-scoped state answers differently in a queue worker, which is the silent-wrong-answer
   shape). Consistent with existing `TenantResolver`-injecting readers
   (`EvaluationIndexController`, `SessionReviewController`, `AdminParticipantReader`).
2. **Sweep sites #1–#9**, including both project FormRequests (fixes the 422 **and** the silent slug
   hole in one accessor change).
3. **Explicit refusal** where an operation needs an organization: reuse the existing
   **409 `organization_context_required`** (`UserController.php:278-285`), not a new
   `no_acting_organization` code — one state, one code. Never `findOrFail(null)` 404 and never an
   empty list that reads as "this client has none".
4. **Ability-driven hiding (part B).** `UserAbilities::for()` must answer `false` for org-scoped
   groups (`organization`, `apiClients`, `users`, `llmCredentials`, `projects`, `participants`) when
   the actor has no effective organization, and keep `clients`/`platformSettings` true.
   Suppression must live here: `Gate::before` grants a superadmin every policy, so policies cannot
   answer this. Both backoffice layers then work unchanged —
   `03.abilities.global.ts:39-43` gates the route, `SidebarNav.vue:182-196` gates the rail, and the
   Settings tabs gate on the same map. No new client-side role checks
   (`UserAbilities.php:50-56` records that re-deriving roles in the client already shipped as a
   defect). Note: `SidebarNav`'s existing `scope`/`visibleNavItemsFor` already hides Dashboard,
   Projects, Candidates and Reports; `/settings` is mislabelled `scope: 'platform'` while its tabs
   are org-scoped — abilities are the fix, not a new scope.
5. **Arch test** forbidding new `$user->organization_id` reads in `app/Http`, with a documented
   allowlist (`TenantContext` itself; `PlatformUserController:107` write;
   `ResetPasswordController:150`), following `tests/Arch/C2/TenantModelArchTest.php`. This is what
   makes the fix permanent instead of a sweep that rots.
6. **Pest coverage for the real identity** — shared fixture (`organization_id = null` +
   `is_superadmin = true` + `ActingOrganization::set`), across every repaired endpoint, plus a
   dedicated regression test proving the duplicate-slug hole is closed, and no-acting-org tests
   asserting 409 + suppressed abilities. Tenancy is a ~95% zone (CLAUDE.md).
7. **Docblock rewrites** — `OrganizationController.php:19` ("org resolves EXCLUSIVELY from
   `$request->user()->organization_id`") and `ValidatesProjectComposition.php:64-67` ("$orgId is
   nullable because `User::$organization_id` is"). Both now document the wrong rule; leaving them is
   the two-documents-one-truth drift CLAUDE.md records three times.

### Out of Scope

- **Organization logo not rendering.** Separate root cause (private snapshot disk + unsigned
  `Storage::url()`); fix already decided (unauthenticated streaming route). Engram
  `api/organization-logo-storage` (id 1916). This change only repairs the logo endpoints' org
  resolution.
- **Restricting `AvatarTemplatePolicy::viewAny`/`view` to superadmin.** A permission-scope decision,
  not a tenancy bug; mixing it would muddy a tenancy-boundary review. **Immediate follow-up.**
- `db-driven-conversation-prompts` (`app/Services/Conversation/**`) — untouched.
- Correct as-is, no change: `ResetPasswordController:150` (unauthenticated route; the org is the
  *subject's* home org, not an actor context), `PlatformUserController:107` (a write that nulls the
  column by design), `UserAbilities.php:134-157` policy *subjects* (`Gate::before` short-circuits, so
  nothing reads the column on them — the map's return values change, the subjects do not).
  `UserAbilities.php:109` becomes effective-org-aware only as a consequence of item 4.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `tenancy`: effective-organization resolution for the acting-superadmin identity; arch guard against
  `$user->organization_id` in `app/Http`.
- `superadmin-clients-console`: org-scoped surfaces are hidden (abilities) and refused (409) when no
  client is selected.
- `m2m-auth`: API-client list/create scope by effective organization (tenancy boundary).
- `project-config`: project create/update validation — avatar template, framework version, and slug
  uniqueness scope by effective organization.
- `organization-settings`: organization read/update/logo scope by effective organization.
- `admin-backoffice`: ability-driven nav/route/tab hiding for the no-acting-organization state.
- `user-management`: `requireOrgId` reads the effective organization.

## Approach

Introduce the accessor, sweep the call sites, add the arch guard, then make `UserAbilities` answer
the no-selection state honestly so the two existing backoffice gates hide the surfaces without new
client logic. Enforcement stays server-side (409 + policies); abilities remain affordances only.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/app/Support/Tenancy/EffectiveOrganization.php` | New | the single accessor |
| `api/app/Http/Controllers/{Api,M2m}/**` | Modified | sites #1,2,5,6,7,9 |
| `api/app/Http/Requests/{Store,Update}ProjectRequest.php`, `UpdateOrganizationRequest.php` | Modified | sites #3,4,8 |
| `api/app/Support/Authorization/UserAbilities.php` | Modified | suppress org-scoped groups |
| `api/tests/Arch/**`, `api/tests/Feature/**` | New | arch guard + real-identity fixture |
| `backoffice/app/**` (Settings tabs, nav) | Modified | consume abilities; no new role checks |
| `openapi.json` | Regenerated | 409 responses (Postgres export per `api/CLAUDE.md`) |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| **Silent slug hole stays open** if only the 422 is fixed | Med | one accessor covers both rules; dedicated regression test is a gate |
| **ApiClient filter is the only tenant boundary** — a wrong edit leaks credentials cross-tenant | Low/**Severe** | review as a tenancy change; cross-tenant Pest test per acting org; `TenantModelArchTest` exclusion note referenced in the diff |
| Ability suppression hides a page from an org admin (over-broad) | Med | suppress only when there is no effective org; org-bound admins always have one; assert per role |
| A missed call site | Med | arch test with explicit allowlist |
| Abilities mistaken for enforcement | Low | 409 + policies enforce independently (`03.abilities.global.ts:9-15`) |

## Rollback Plan

Single revert of the feature branch merge. The accessor is additive, no migration, no data change,
no contract removal (409 is a new response on paths that previously 500/404/403'd). The
`ActingOrganization` cache is untouched. Reverting restores the current (broken) behaviour with no
cleanup.

## Dependencies

- None. Concurrent `db-driven-conversation-prompts` does not overlap.
- Open decision: whether `avatarTemplates.viewAny` belongs in the suppression set (org-scoped data
  says yes; it interacts with the deferred policy-scope follow-up). Default: suppress. Settle in spec.

## Delivery

**`feature/superadmin-acting-organization-context` off `develop`**, released through a normal
`release/*` **minor** bump. Part B is new behaviour, not a repair, and a `hotfix/*` off `main` must
carry only the minimal defect fix — shipping new ability semantics and a new 409 straight to
production without passing `develop` is the larger risk. If the 500/422 must land sooner, carve a
hotfix containing **only** items 1–3 (accessor + sweep + 409) and let part B follow; do not split
item 4 from item 6.

## Success Criteria

- [ ] With a client selected, a SuperAdmin sees and manages exactly what an admin of that org does:
      API keys list/create, project create/update, organization read/update, logo upload/delete.
- [ ] A duplicate project slug within the acting organization is **refused** (regression test).
- [ ] `POST /api/m2m/clients` no longer 500s; `POST /api/projects` no longer 422s on a valid template.
- [ ] With no client selected: org-scoped abilities are `false`, the nav entries and Settings tabs are
      absent, routes redirect, and the API answers **409 `organization_context_required`** — never a
      404, a 500, or an empty list.
- [ ] The arch test fails on a newly introduced `$user->organization_id` read in `app/Http`.
- [ ] Both stale docblocks describe the effective-organization rule.
- [ ] Tenancy-touching code ≥95% covered; suite green (`php artisan test --parallel`, `bun run test:unit`).
