# Design: SuperAdmin Acting-Organization Context

Proposal: `openspec/changes/superadmin-acting-organization-context/proposal.md` (sites #1–#9 authoritative).

## Technical Approach

`TenantContext` already writes the right answer into `TenantResolver` (`:83-95`). One container
support class reads it back, eleven call sites delegate to it, an arch guard makes the delegation the
only legal spelling, and `UserAbilities::for()` answers the no-selection state honestly so the two
backoffice gates that already exist hide the surfaces with no new client logic.

Layering is unchanged: middleware writes context → accessor reads context → controllers /
FormRequests / the abilities map consume it. No new mechanism, no new middleware, no migration.

## Architecture Decisions

### D1 — Accessor shape: one class, one call-site method

**Choice**: `App\Support\Tenancy\EffectiveOrganization`, constructor-injected `TenantResolver`.

```php
final class EffectiveOrganization
{
    public function __construct(private readonly TenantResolver $resolver) {}

    /** Nullable read. RESERVED for UserAbilities::for() — see D3. */
    public function id(): ?int;

    /** The one method every HTTP call site uses. 409 organization_context_required when null. */
    public function requireId(): int;
}
```

`requireId()` is the single call-site shape; `id()` exists because the abilities map must answer a
boolean and cannot throw, and its docblock names `UserAbilities` as its only permitted caller. Two
interchangeable shapes is how the current mess started, so the nullable read is an enumerated
exception, not an option.

**Named `requireId()`, not `require()`** (proposal wording): `require` is a semi-reserved PHP keyword —
legal as a method name but it trips PHP-Parser-based tooling — and `requireId()` matches
`UserController::requireOrgId()`, the precedent it absorbs.

**Rejected**: a trait (FormRequest and Controller are unrelated base classes → duplicated, and
invisible to the arch guard); a `User::effectiveOrganizationId()` method (a model reading
request-scoped state answers differently inside a worker — the silent-wrong-answer shape).

**Load-bearing**: `TenancyServiceProvider:27` registers `TenantResolver` as `scoped` — one instance
per request — and route middleware runs before FormRequest validation. A `bind` would no-op this
whole change.

### D2 — Exact contract

| Context | `id()` | `requireId()` | Why safe |
|---|---|---|---|
| Org-bound user (any role) | resolver's org id | same int | `TenantContext:67-73` stamped it; suppression branch provably unreachable |
| SuperAdmin **with** acting org | acting org id | same int | `TenantContext:85-95`, bypass OFF, from the server-side `ActingOrganization` store — never a header |
| SuperAdmin **with none** | `null` | **409** `organization_context_required` | bypass ON + orgId null = "the whole estate", which is not an organization |
| Unauthenticated | `null` | 409 | no principal; every affected route is `auth:api` so this is unreachable |
| Queue worker | resolver value, else `null` | resolver value, else a loud 409 job failure | `Queue::before` nulls the resolver; jobs re-establish via `TenantContextScope::runFor()`, so a job that scoped itself reads its OWN org. Never silently another tenant's |

Fallback order: `resolver->getOrgId()`; if null and `resolver->isBypass()` → `null`; else the
`api`-guard user's `organization_id`. The guard is named explicitly — `api-candidate` and `api-m2m`
principals have their own middleware and their own org source, and falling through to the default
guard could answer from the wrong principal. A non-`User` principal resolves to `null`.

The fallback is **unreachable at all eleven sites** (each is behind `auth:api` + `TenantContext`).
It is kept anyway: it makes the sweep provably monotone — no site can answer worse than today — and
it protects a future route that forgets the middleware from a spurious 409. Covered by an explicit
unit case (resolver null + org-bound user → that user's org). Under the `sync` driver the same
fallback returns the dispatching user's home org, which for an org-bound user is the same org and
for an acting superadmin is `null` → 409. Wrong-but-loud, never wrong-and-quiet.

### D3 — Suppression lives in `UserAbilities::for()`

`Gate::before` grants a superadmin every ability before any policy runs (`UserAbilities:146-150`), so
a policy structurally cannot answer this question.

| Group | No effective org | Rationale |
|---|---|---|
| `organization`, `apiClients`, `users`, `llmCredentials`, `projects`, `participants` | **all keys `false`** | every one reads one tenant's rows; unanswerable with no client |
| `avatarTemplates` (open question in proposal) | **all keys `false`** — decided | `AvatarTemplate` IS a `TenantModel`; the list would render empty and Create would hit `TenantScoped`'s throw. Rejected: keeping it true because the nav item is tagged `scope: 'platform'` — that tag is the same mislabel as `/settings`, and honouring a wrong label is precisely how the API Keys tab shipped. Independent of the deferred policy-scope follow-up, which narrows *who*, not *whether there is an org* |
| `clients`, `platformSettings` | stay `true` | suppressing `clients.viewAny` removes the page used to select a client — the state would be unescapable |

Discriminator: `$this->effective->id() === null`. **No role string.** An org-bound user always has a
non-null column, `TenantContext` stamps it, and the accessor's fallback reads it — and a
non-superadmin with a null org is 403'd by `TenantContext:110` before any controller. So
`id() === null` ⟺ superadmin with no client selected, for any request that got this far. Asserted
per role (admin / operator / viewer unaffected).

Also changed: `:109` `Organization::find($user->organization_id)` → `find($this->effective->id())`.
One line, and it removes an allowlist entry that would otherwise need a subtle "harmless because
`Gate::before`" proof. `:134-157` (policy **subjects**) stays — settled, and allowlisted.

### D4 — Arch guard: `app/Http` + `app/Support`, occurrence-budget allowlist

Follows `tests/Arch/C2/TenantModelArchTest.php` (a `test()` in `group('arch')`, informative failure
message). New: `api/tests/Arch/Tenancy/EffectiveOrganizationArchTest.php`.

Mechanics — three things make it hard to bypass or to rot:
1. **Comments stripped via `token_get_all()`** (skip `T_COMMENT`/`T_DOC_COMMENT`) before matching, so
   the count is stable against prose edits and a docblock quoting the old spelling is not a false hit.
2. **Reads only, not writes**: `/\$\w*[uU]ser\w*\s*\??->organization_id(?!\s*=[^=])/` plus
   `/->user\(\)\s*\??->organization_id(?!\s*=[^=])/`. `=== null` is a read; `= null` is not.
3. **Allowlist is `path => exact occurrence count`**, not `path => ignored`. A new read inside an
   allowlisted file fails on count drift, so the highest-risk files stay guarded.

The matcher is itself unit-tested against known-offending and known-clean snippets — an arch regex
that quietly stops matching is a guard that passes vacuously forever.

| Allowlisted path | Count | Justification |
|---|---|---|
| `app/Support/Tenancy/EffectiveOrganization.php` | 1 | the single legitimate reader; every other site delegates here |
| `app/Http/Middleware/TenantContext.php` | 1 | writes the context the accessor reads — reading the column here IS the rule |
| `app/Http/Controllers/Auth/ResetPasswordController.php` | 2 | unauthenticated route, no actor context: the org is the *subject's* home org for the audit row |
| `app/Support/Authorization/UserAbilities.php` | 1 | `:134` stamps policy **subjects**; `Gate::before` short-circuits for the only identity where the column is null |

`app/Support` is **in scope** — the occurrence budget is what makes that affordable without
whole-file amnesty. `PlatformUserController:107` needs no entry: it is a write.
Known limitation, accepted: `$u = $request->user(); $u->organization_id` evades the pattern. It is a
ratchet against the shape that actually recurred here (all 13 sites spelled one of the two forms),
backed by the real-identity feature tests, which catch a renamed variable at the endpoint.

### D5 — Backoffice: abilities only, no second mechanism

`/settings` route (`03.abilities.global.ts:40`) and its rail item (`SidebarNav.vue:152`) both require
`users.viewAny`; the four tabs require `organization.view`, `apiClients.viewAny`, `users.viewAny`,
`llmCredentials.viewAny` (`pages/settings/index.vue:160,181,199,210`). Suppressing those groups fixes
route + rail + tab in one move, with **zero** backoffice source changes.

**Rejected: tab-level `scope`.** It would put a second, client-side copy of "does this viewer have an
org" beside the server's answer, and `UserAbilities:50-56` records that re-deriving authorization in
the client already shipped as a defect — silently, in the permissive direction. The existing
`scope`/`visibleNavItemsFor` filter stays as-is (it answers a different question: does the page mean
anything). `/settings`'s wrong `scope: 'platform'` label is left alone deliberately — it is now inert,
and changing it would be a second fix for a problem the first one already closed.

Backoffice work is therefore **tests only**: Vitest specs pinning that the suppressed payload yields
no `/settings` rail item, no tabs, and a route redirect.

### D6 — ApiClient is a tenancy boundary, not a list query

`ApiClient` is excluded **by name** from `TenantModelArchTest.php:59-65` (the m2m guard queries it
unscoped), so the explicit `where('organization_id', …)` IS the only boundary.

Made safe by: (a) `requireId()` returns a non-null int **or aborts** — the filter can never again
compile against `NULL`; (b) the int comes from `TenantResolver`, stamped from the server-side
`ActingOrganization` store, never from a client-supplied header; (c) the filter stays **explicit and
inline** — the edit must not introduce a global scope, `withoutGlobalScopes()`, or a `TenantModel`
parent. Site #2's `forceFill(['organization_id' => …])` likewise becomes `requireId()`, so the NOT
NULL column can no longer take a null (500) *or* an orphan row.

Proving test — `tests/Feature/C5/ApiClientActingOrganizationTest.php`, one acting superadmin, three
phases: acting **A** → exactly A's clients, B's ids asserted **absent**; `ActingOrganization::set(B)`
→ exactly B's, A's absent; set `null` → **409** and no row disclosed. Plus `store()` acting A writes
`organization_id = A` (asserted in the DB), and with no selection 409s with `assertDatabaseCount`
unchanged.

**Discovered, classified OUT**: `destroy(ApiClient $apiClient)` uses implicit route binding on a
model with no global scope, and `Gate::before` grants a superadmin `delete` — so an acting superadmin
can revoke another tenant's client by id. Pre-existing bypass property, direction is fail-safe
(revocation, not disclosure), and scoping route binding is its own tenancy decision (does a
*non*-acting superadmin keep estate-wide revocation?). Named immediate follow-up alongside
`AvatarTemplatePolicy`. Deliberately **not** pinned by a test here — we do not lock in a behaviour we
intend to revisit.

### D7 — Refusal code and its layer

Reuse `abort_if($orgId === null, 409, 'organization_context_required')` (`UserController:278-285`),
which moves onto the accessor; `requireOrgId()` becomes a delegation (today it 409s even when a
client IS selected — site #9).

`UpdateOrganizationRequest::authorize()` calls `requireId()` **before** returning an authorization
verdict, so no-selection answers 409 rather than 403. Rationale: 403 tells an operator they lack a
permission they actually hold, instead of that they have not chosen a client. General rule:
`requireId()` runs before any authorization decision needing an org subject, so 409 always precedes
403/404 for this state — one state, one code, one layer.

### D8 — What this closes for free: the "candidate app is always Quint purple" report

Sites #5 and #6 together mean a SuperAdmin can neither **read** (`GET /api/organization` → 404) nor
**save** (`PATCH /api/organization` → 403) `organizations.primary_color` / `logo_path`. Every
organization created or configured by the platform owner therefore still has both columns `NULL`, and
the candidate frontend renders the default Quint palette — which is exactly what the user reported.

**The frontend chain is CORRECT and must not be touched.** `ParticipantResource:92` already sends
`branding.primary_color`; `useCandidateBranding` calls `applyBrandColor()`, which **removes** the
custom property when the value is null rather than writing a default. Null in, product palette out —
per the ratified "both fields nullable permanently" rule. The bug was never in the renderer; it was
that the column could not be written. Fixing #5/#6 is the whole fix, and a "fix" in the frontend
would break the deliberate no-logo-configured behaviour.

Separate and still out of scope: the logo **not rendering** once set (private disk + unsigned
`Storage::url()`, Engram `api/organization-logo-storage` id 1916).

## Data Flow

    TenantContext ──writes──> TenantResolver (scoped, 1/request)
      │  org-bound → orgId                        ▲
      │  superadmin + acting → orgId (bypass off) │ reads
      │  superadmin, none    → bypass, orgId=null │
      v                                    EffectiveOrganization
    next()                                  │            │
      ├─ Controller ─────── requireId() ────┘            │
      ├─ FormRequest rules()/authorize() ── requireId() ─┤
      └─ UserAbilities::for() ───────────────── id() ────┘
                │ null → org-scoped groups false
                v
         /auth/me abilities ──> 03.abilities.global.ts (route)
                             ──> SidebarNav (rail)
                             ──> settings/index.vue (tabs)

## File Changes

| File | Action | Description |
|---|---|---|
| `api/app/Support/Tenancy/EffectiveOrganization.php` | Create | the accessor (D1/D2) |
| `api/app/Http/Controllers/M2m/ApiClientController.php` | Modify | #1 `:131`, #2 `:80` — tenancy boundary (D6) |
| `api/app/Http/Requests/Concerns/ValidatesProjectComposition.php` | Modify | `avatarTemplateRule()` `:68-77`; docblock `:62-67` rewrite |
| `api/app/Http/Requests/StoreProjectRequest.php` | Modify | `:44` — avatar template, `framework_version_id`, **slug uniqueness** |
| `api/app/Http/Requests/UpdateProjectRequest.php` | Modify | `:87`, `:101` — same three rules |
| `api/app/Http/Controllers/Api/ProjectController.php` | Modify | #7 `:80` |
| `api/app/Http/Controllers/Api/OrganizationController.php` | Modify | #5 `:32`, `:50`; docblock `:19` rewrite |
| `api/app/Http/Requests/UpdateOrganizationRequest.php` | Modify | #6 `:27` → 409 before verdict (D7) |
| `api/app/Http/Controllers/Api/OrganizationLogoController.php` | Modify | #8 `:52`, `:153` |
| `api/app/Http/Controllers/Api/UserController.php` | Modify | #9 `:278-285` delegates to `requireId()` |
| `api/app/Support/Authorization/UserAbilities.php` | Modify | suppression + `:109`; `:134-157` untouched (D3) |
| `api/tests/Arch/Tenancy/EffectiveOrganizationArchTest.php` | Create | guard + matcher self-test (D4) |
| `api/tests/Unit/Support/Tenancy/EffectiveOrganizationTest.php` | Create | the five D2 rows |
| `api/tests/Feature/**` (5 files) | Create | acting-superadmin fixture, per-endpoint repairs, duplicate-slug regression, cross-tenant ApiClient, abilities per role |
| `backoffice/app/**` | **No change** | abilities-only fix (D5) |
| `backoffice/test/**` (2 specs) | Create | rail + settings-tab suppression |
| `api/openapi.json` | Regenerate | 409 surfaces; export against **Postgres** per `api/CLAUDE.md` |

## Testing Strategy

Strict TDD: RED first in every slice. Tenancy is a ~95% zone (CLAUDE.md).

| Layer | What | Approach |
|---|---|---|
| Unit (Pest) | Accessor: 5 D2 contexts + the unreachable-fallback case | `TenantResolver` driven directly; no HTTP |
| Unit (Pest) | Arch matcher regex vs. offending/clean snippets | string fixtures — stops a vacuous guard |
| Arch (Pest) | No new `$user->organization_id` read in `app/Http`/`app/Support` | occurrence-budget allowlist, `group('arch')` |
| Feature (Pest) | Every repaired endpoint under the **real** identity (`organization_id = null` + `is_superadmin` + `ActingOrganization::set`) | shared fixture — the thing whose absence let six endpoints ship broken |
| Feature (Pest) | Duplicate slug inside the acting org is **refused** (`slug_taken`) | the silent hole; standalone regression test |
| Feature (Pest) | Cross-tenant ApiClient list/create per acting org, A↔B, absence assertions | D6 |
| Feature (Pest) | Abilities per role: admin/operator/viewer unaffected; acting superadmin true; no-selection false | asserts the discriminator, not a role string |
| Feature (Pest) | No-selection → 409 `organization_context_required` on every site; never 404/500/empty list | |
| Unit (Vitest) | Rail item + settings tabs absent for the suppressed payload; route redirect | mocked `/auth/me` |
| E2E | **No new spec.** The abilities payload is the seam and both sides of it are asserted above; a superadmin acting-org Playwright journey is a named optional follow-up | |

## Threat Matrix

`N/A` — no shell command, subprocess, VCS/PR automation, executable-file classification, or
process-integration boundary. No API route is added, removed, or re-pathed; only the organization a
handler resolves changes. The relevant risk surface is tenant isolation, covered by D6 and the
cross-tenant feature tests.

## Migration / Rollout

**No migration.** Code + tests only; no schema, no data, no contract removal (409 replaces
500/404/403 on paths that were already failing). `ActingOrganization` untouched. Rollback = single
revert of the feature-branch merge.

**Git Flow**: `feature/superadmin-acting-organization-context` off `develop`, released via `release/*`
with a **MINOR** bump — part B is new behaviour (new ability semantics + a new 409 surface), and a
`hotfix/*` off `main` must carry only a minimal defect fix. If the 500/422 must ship sooner, a
carve-out hotfix may contain **PR 1–3 only** (accessor + sweep + 409) and never PR 4/5. Release order
stays api-first (`openapi.json` `info.version` derives from `VERSION`); consumers follow in a patch,
and `VERSION` must agree with the manifest.

## Delivery Slices (feature-branch-chain)

PR #1 targets the feature branch; each later PR targets the previous PR's branch. Arch guard lands
**last** — it would fail against the un-swept sites otherwise, and a temporarily-inflated allowlist is
a guard nobody trusts.

| PR | Scope | Forecast | Risk tier |
|---|---|---|---|
| 1 | Accessor + unit tests + shared acting-superadmin fixture + m2m sites #1/#2 + cross-tenant test | ~380 | **High** (tenancy boundary → 4R) |
| 2 | Project composition: #3 avatar template, framework version, **#4 slug uniqueness**, #7; duplicate-slug regression | ~300 | Medium |
| 3 | Organization #5/#6/#8 + `requireOrgId` #9 + feature tests | ~280 | Medium |
| 4 | Ability suppression (part B) + Pest per-role tests + Vitest rail/tab specs | ~300 | Medium |
| 5 | Arch guard + matcher self-test + both docblock rewrites + `openapi.json` re-export | ~180 authored | Low |

`Decision needed before apply: No` (auto-chain resolved). `Chained PRs recommended: Yes`.
`400-line budget risk: High` overall (~1,440 authored lines), Low/Medium per slice.

Proposal item 4 (suppression) and item 6 (real-identity coverage) are **not split**: PR 4 carries the
suppression with its own tests, and every earlier slice carries its own real-identity tests.

## Open Questions

- [ ] Scoping `ApiClientController::destroy`'s route binding for an acting superadmin (D6) — follow-up change, needs its own decision on estate-wide revocation.
- [ ] `AvatarTemplatePolicy::viewAny`/`view` restricted to superadmin — deferred by the proposal; independent of D3's suppression decision.
- [ ] For a no-selection superadmin, `03.abilities.global.ts` redirects `/settings` to `/`, whose dashboard is `scope: 'client'`. Existing `superadmin-clients-console` behaviour, unchanged here; confirm `/` renders the client picker rather than an empty dashboard.
