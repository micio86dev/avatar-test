# Duplicate avatar templates across organizations

## Objective
A SUPERADMIN can copy an avatar template from one organization to one or more other organizations
(so a new client is not empty and templates need not be retyped). Global/shared templates with
propagation are a SEPARATE follow-up (needs SDD: tenancy rule change), see "Out of scope".

## Decision (user, 2026-09-29): "do both, in order" -> duplication first, then global templates via SDD.

## Constraints
- Superadmin only (AvatarTemplatePolicy::create semantics; org roles get 403). Cross-tenant isolation unchanged:
  the copy is a NEW row stamped with the TARGET organization via TenantContextScope::runFor(target); no shared rows.
- Copy: name (see collision rule), description, provider, config, persona, llm_model_id, llm_credential_id
  (credentials are platform rows, RATIFIED 2026-09-14). Do NOT copy: id, organization_id, is_active (copy is inactive),
  heygen_llm_configuration_id, llm_sync_status, llm_synced_at (provider-side resources belong to the source template;
  the copy must sync on its own), timestamps, soft-deleted state.
- Name collisions in the target org: follow the existing uniqueness rules (check migrations/validators); if names must be unique
  auto-suffix " (copy)", " (copy 2)"; never fail half-way: all-or-nothing per request (transaction), report created ids.
- Admin audit log entry per copy (platform audit writer conventions), no secrets in it.
- Repo rules: AuthMatrix catalogue + fixtures for the new route (guard fails otherwise), Pest tests, openapi export + typed client
  regenerated in backoffice, i18n it/en, DESIGN.md updated first for UI rules, Bun only, strict TDD, conventional commits,
  local containers are built images (rebuild before asking the user to test).
- Branches: api stacked on feature/avatar-voice-preview; backoffice stacked on fix/org-logo-same-origin-url.

## Tasks
- [x] D1 API: `POST /api/avatar-templates/{id}/duplicate` body `{target_organization_ids: int[] (1..N, existing orgs)}`,
      service, audit, tests, AuthMatrix, openapi
- [x] D2 Backoffice: "Copy to organizations" action on a template (superadmin), multi-select of orgs incl. "all organizations",
      result summary, refresh, i18n, tests
- [x] D3 Verify (user confirmed copy dialog OK, 2026-10-03): suites, mutations on authz/tenant stamping, rebuild containers, user tries it

## Out of scope (next: SDD proposal)
Global templates shared by all orgs with edit propagation: per-org activation semantics (unique active index per org+provider),
effect on live projects when a global template changes, org-admin read-only visibility, TenantScoped/FK changes.

## Progress / evidence
Reconciled 2026-10-02 against `origin/develop` (read-only mapping, not a test run). Shipped: api PR #81 (6cf1edc, v0.60.0),
backoffice PR #47 (29d1a7d, v0.43.0). Current prod: api v0.65.1, backoffice v0.47.1.
- D1: `POST /api/avatar-templates/{id}/duplicate` (`AvatarTemplateDuplicateController`, `authorize('create')`), body
  `target_organization_ids` (required, distinct, existing orgs), refuses the source org among targets, one `DB::transaction`
  in `DuplicateAvatarTemplate`, each copy under `TenantContextScope::runFor`, copy inactive, provider-side sync fields not
  copied, ` (copy)` / ` (copy N)` suffix, audit after commit without config content. `AvatarTemplateDuplicateTest` (15
  tests: all-or-nothing, suffix, audit, cross-tenant), AuthMatrix entry + fixture, openapi path.
- D2: `CopyTemplateDialog` (multi-select, select all, result summary, inactive note), used on the avatar-templates and
  platform-templates pages, i18n it/en, Vitest 15 tests.
- Follow-up "global templates" is also shipped: api PR #87 (30c922b, v0.61.0), `organization_id NULL` = platform row,
  `POST /admin/avatar-templates/{id}/duplicate`; backoffice 709c8dd (v0.44.0). Edit propagation and per-org activation
  semantics were not checked in this pass.
- D3 PENDING (human): rebuild containers and try the copy dialog against real organizations.

## Next step
D3: manual try-out of the copy dialog (owner).
