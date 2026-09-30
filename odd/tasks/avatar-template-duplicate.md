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
- [ ] D1 API: `POST /api/avatar-templates/{id}/duplicate` body `{target_organization_ids: int[] (1..N, existing orgs)}`,
      service, audit, tests, AuthMatrix, openapi
- [ ] D2 Backoffice: "Copy to organizations" action on a template (superadmin), multi-select of orgs incl. "all organizations",
      result summary, refresh, i18n, tests
- [ ] D3 Verify: suites, mutations on authz/tenant stamping, rebuild containers, user tries it

## Out of scope (next: SDD proposal)
Global templates shared by all orgs with edit propagation: per-org activation semantics (unique active index per org+provider),
effect on live projects when a global template changes, org-admin read-only visibility, TenantScoped/FK changes.

## Progress / evidence
(empty)

## Next step
D1 (api) and the CSP/photo fix (backoffice) run in parallel (different repos).
