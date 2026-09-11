# Tasks: SuperAdmin Acting-Organization Context

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | ~1,440 authored |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → PR 2 → PR 3 → PR 4 → PR 5 |
| Delivery strategy | auto-chain |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

**Full 4R review required on PR 1** (tenancy boundary — cross-tenant credential exposure risk).

### Suggested Work Units

| PR | Goal | Branch | Target base | Est. lines | Focused test command | Rollback boundary |
|---|---|---|---|---|---|---|
| 1 | Accessor + shared acting-superadmin fixture + m2m sites #1/#2 | `feature/superadmin-acting-organization-context/pr1-accessor` | `feature/superadmin-acting-organization-context` | ~380 | `php artisan test --parallel --filter=EffectiveOrganization\|ApiClientActingOrganization` | revert accessor + m2m diff; no callers yet |
| 2 | Project composition: avatar template, framework version, slug uniqueness, #7 | `.../pr2-project-composition` | PR 1 branch | ~300 | `php artisan test --parallel --filter=ProjectComposition\|ProjectSlugUniqueness` | revert project FormRequest/controller diff |
| 3 | Organization read/write/logo + `requireOrgId` | `.../pr3-organization-settings` | PR 2 branch | ~280 | `php artisan test --parallel --filter=OrganizationActingOrg` | revert org controller/request diff |
| 4 | Ability suppression (7 groups) + per-role coverage | `.../pr4-ability-suppression` | PR 3 branch | ~300 | `php artisan test --parallel --filter=UserAbilities` && `bun run test:unit` (backoffice) | revert `UserAbilities::for()` diff |
| 5 | Arch guard + matcher self-test + docblocks + openapi re-export | `.../pr5-arch-guard` | PR 4 branch | ~180 | `php artisan test --parallel --filter=EffectiveOrganizationArch` | revert arch test + allowlist; guard lands last on purpose |

## PR 1 — Accessor + M2M tenancy boundary (High risk, full 4R)

- [x] 1.1 RED: `api/tests/Unit/Support/Tenancy/EffectiveOrganizationTest.php` — the 5 D2 rows (org-bound, acting, no-acting→409, unauthenticated→409, worker unreachable-fallback).
- [x] 1.2 GREEN: create `api/app/Support/Tenancy/EffectiveOrganization.php` — `id(): ?int`, `requireId(): int` (409 `organization_context_required`), constructor-injects `TenantResolver`.
- [x] 1.3 RED: `api/tests/Feature/C5/ApiClientActingOrganizationTest.php` — shared acting-superadmin fixture (`organization_id=null`, `is_superadmin=true`, `ActingOrganization::set()`); acting A → only A's clients (B absent); switch to B → only B's (A absent); `store()` writes `organization_id=A`; no selection → 409, `assertDatabaseCount` unchanged.
- [x] 1.4 GREEN: `M2m/ApiClientController::index` (`:131`) → `EffectiveOrganization::requireId()`.
- [x] 1.5 GREEN: `M2m/ApiClientController::store` (`:80`) → `requireId()` before `forceFill`, refuse pre-insert on null (no more NOT-NULL 500).
- [x] 1.6 Record follow-up (no code, no test): `ApiClientController::destroy` uses implicit route binding on an unscoped model — pre-existing cross-tenant revocation gap, deliberately left unpinned pending its own tenancy decision.
- [x] 1.7 Verify: `php artisan test --parallel --filter=EffectiveOrganization\|ApiClientActingOrganization` green.

## PR 2 — Project composition

- [ ] 2.1 RED: feature test — acting org A + valid avatar template/framework_version → 201, not 422 `avatar_template_invalid`.
- [ ] 2.2 RED: `api/tests/Feature/C4/ProjectSlugUniquenessActingOrgTest.php` — standalone regression: duplicate slug inside acting org A is rejected 422 `slug_taken` (previously checked against `organization_id IS NULL`, silently accepted).
- [ ] 2.3 GREEN: `ValidatesProjectComposition::avatarTemplateRule()` (`:68-77`) → `EffectiveOrganization`.
- [ ] 2.4 GREEN: `StoreProjectRequest` (`:44`) — avatar template, `framework_version_id`, slug-uniqueness rules → `EffectiveOrganization`.
- [ ] 2.5 GREEN: `UpdateProjectRequest` (`:87`, `:101`) — same three rules.
- [ ] 2.6 GREEN: `ProjectController::store` (`:80`) → `requireId()`.
- [ ] 2.7 Verify: `php artisan test --parallel --filter=ProjectComposition\|ProjectSlugUniqueness` green.

## PR 3 — Organization settings

- [ ] 3.1 RED: prove `UpdateOrganizationRequest` receives `EffectiveOrganization` via container method-injection (`Container::call`) — assert resolution before any production code depends on it.
- [ ] 3.2 RED: feature test — acting org A: `GET`/`PATCH /api/organization` → 200, never 404/403.
- [ ] 3.3 RED: feature test — SuperAdmin saves `primary_color`/`logo` for acting org A; assert `ParticipantResource.branding.primary_color` reflects it (closes the Quint-purple bug; frontend chain untouched).
- [ ] 3.4 RED: feature test — logo upload/delete for acting org A, never 404.
- [ ] 3.5 RED: feature test — no acting org → 409 on all four org endpoints, never 404/403.
- [ ] 3.6 GREEN: `OrganizationController` (`:32`, `:50`) → `EffectiveOrganization`; rewrite stale docblock `:19`.
- [ ] 3.7 GREEN: `UpdateOrganizationRequest::authorize()` (`:27`) → `requireId()` before verdict (409 precedes 403).
- [ ] 3.8 GREEN: `OrganizationLogoController` (`:52`, `:153`) → `EffectiveOrganization`.
- [ ] 3.9 Verify: `php artisan test --parallel --filter=OrganizationActingOrg` green.

## PR 4 — Ability suppression

- [ ] 4.1 RED: Pest per role — admin/operator/viewer (org-bound, always non-null effective org) UNAFFECTED by suppression.
- [ ] 4.2 RED: Pest — no-selection superadmin: `organization`, `apiClients`, `users`, `llmCredentials`, `projects`, `participants`, `avatarTemplates` all `false`; `clients`/`platformSettings` stay `true`.
- [ ] 4.3 RED: Pest — selecting acting org A restores abilities identical to an org A admin.
- [ ] 4.4 RED: Vitest — suppressed payload → no `/settings` rail item, no tabs, route redirect.
- [ ] 4.5 GREEN: `UserAbilities::for()` — suppress the 7 groups on `effective->id() === null`; `:109` → `find($effective->id())`.
- [ ] 4.6 Verify: `php artisan test --parallel --filter=UserAbilities` and `bun run test:unit` (backoffice) green.

## PR 5 — Arch guard + cleanup (lands last)

- [ ] 5.1 RED: matcher self-test — regex vs known-offending/known-clean snippets (comment-stripped via `token_get_all`).
- [ ] 5.2 RED: `api/tests/Arch/Tenancy/EffectiveOrganizationArchTest.php` — no new `$user->organization_id` read in `app/Http`/`app/Support`, occurrence-budget allowlist (`EffectiveOrganization.php`=1, `TenantContext.php`=1, `ResetPasswordController.php`=2, `UserAbilities.php`=1) so a new read in an allowlisted file also fails.
- [ ] 5.3 GREEN: implement the arch test + allowlist.
- [ ] 5.4 Rewrite stale docblock `ValidatesProjectComposition.php:64-67`.
- [ ] 5.5 GREEN: `UserController::requireOrgId()` (`:278-285`) delegates to `EffectiveOrganization::requireId()`.
- [ ] 5.6 Regenerate `api/openapi.json` against Postgres (per `api/CLAUDE.md`) — 409 surfaces reflected.
- [ ] 5.7 Verify full suite: `php artisan test --parallel`, `./vendor/bin/pint --test`, `./vendor/bin/phpstan analyse`, `bun run test:unit` all green.

## Git Flow

`feature/superadmin-acting-organization-context` off `develop`, released via `release/*` with a **MINOR** bump (part B / PR 4 is new ability semantics, not a repair) — NOT `hotfix/*` off `main`. If the 500/422 must ship sooner, a carve-out hotfix may contain **PR 1–3 only**; never PR 4 or PR 5.

## Open Follow-ups (not this change)

- Scope `ApiClientController::destroy` route binding for acting superadmins (D6).
- Restrict `AvatarTemplatePolicy::viewAny`/`view` to superadmin (deferred, independent of PR 4).

## Follow-ups from the PR 1 bounded review (lineage review-37fe736c9bba7bb4, state: approved)

Both are `info` severity, neither blocks. The PR 1 receipt is content-bound and already
approved, so these are NOT corrections to PR 1 — editing those files now would invalidate
the receipt as scope-changed. Each folds into the later slice that already touches it.

- [ ] PR 4 — `app/Support/Authorization/UserAbilities.php:66-70`: the docblock still cites
      `ApiClient::where('organization_id', $user->organization_id)` as the load-bearing
      tenant filter. PR 1 replaced that expression with
      `$effectiveOrganization->requireId()` (`ApiClientController.php:131`). That docblock is
      the recorded justification for answering `apiClients.delete` at class level rather than
      per row, so a stale citation there is the two-documents-one-truth drift CLAUDE.md
      records three times. Update the citation. (risk lens, SUGGESTION, causal: introduced)

- [ ] PR 3 or PR 5 — `app/Support/Tenancy/EffectiveOrganization.php:89-96`: the 409
      `organization_context_required` refusal is raised via `abort_if()`, which produces a
      Symfony `HttpException`. Verified: `HttpException::class` is in Laravel's default
      `Handler::$internalDontReport` (vendor Handler.php:174) and `bootstrap/app.php`
      registers no override, so the refusal is never reported server-side. For `store()` this
      is a REGRESSION in observability: it replaces an auto-reported NOT-NULL 500 with a
      log-invisible 409. A systemic cause (e.g. a Redis eviction clearing many superadmins'
      acting-org selections at once) would produce a spike of refusals with zero aggregate
      signal. Add a structured log line at the refusal, distinguishable from a genuine
      "this tenant has none". (resilience lens, WARNING, causal: worsened)
