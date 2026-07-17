# Proposal: Framework Catalog (C3)

## Intent

BEAI's binding domain (5 roles, 18 standard competencies, per-role BARS anchors) currently lives only as static JSON in `docs/app_description/02-domain/framework/`. Nothing in `api/` models, persists, or serves it. C4 projects must pin a framework version; C9 evaluations must read competency anchors to score. C3 turns the JSON catalog into a queryable, versioned, translatable, tenant-pinnable data layer — seeding EXACTLY what exists (EN, present BARS roles) and tracking known data gaps as explicit authoring tasks instead of inventing domain content.

Success = the base catalog (Role, Competency, BarsIndicator) is seeded idempotently from the JSON, a per-org `FrameworkVersion` pins which version an org uses, translatable columns carry `{it,en}`, a read-only org-scoped API serves roles/competencies/BARS, and missing data (SRX BARS, MTG/LAT, IT anchors) is flagged — not faked.

## Scope

### In Scope
- **GLOBAL base catalog** (plain Model, NO `organization_id`): `Role`, `Competency`, `BarsIndicator` (anchors `{5,3,1}` reference text per indicator; C3 stores, C9 scores).
- **`FrameworkVersion`** (extends `TenantModel`, org-scoped, `organization_id`-first composite index): pins WHICH catalog version an org uses; C4/C9 reference `framework_version_id`.
- Migrations per D22 (3NF, reversible, indexed).
- Install **`spatie/laravel-translatable`**; translatable JSON columns for role/competency names, definitions, BARS anchor text — adding es/fr/de/pt needs no schema change.
- **`FrameworkCatalogSeeder`**: idempotent, EN seed, reads split-file shape (`competencies.json` + `bars/{ROLE}.json`) AND tolerates a future unified competency object; **gracefully skips/flags missing files** (SRX) rather than failing.
- Read-only framework API (org-scoped via pinned version): list roles, list competencies, a role's BARS indicators/anchors.
- Catalog kept separate from evaluation logic (no scoring).

### Out of Scope (non-goals)
- Scoring engine (C9); project config + project→`framework_version` FK wiring + pin-at-creation (C4); per-org BARS overrides (future additive); MTG/LAT scoring flow.
- **Do NOT invent** expert data: `bars/SRX.json` (missing), MTG/LAT definitions+anchors (absent), IT anchor translations. These are CLIENT/EXPERT authoring tasks — C3 flags them; it does not fabricate binding domain content.

## Capabilities

### New Capabilities
- `framework-catalog`: global versioned Role/Competency/BarsIndicator base catalog + tenant-scoped `FrameworkVersion` pin, translatable `{it,en}` columns, idempotent JSON seeder (graceful on gaps), read-only org-scoped read API.

### Modified Capabilities
None (no existing spec covers the framework catalog; `scoring-model` is consumed, not modified).

## Approach

Hybrid tenancy (exploration recommendation): the binding JSON is a SHARED base, so `Role`/`Competency`/`BarsIndicator` are GLOBAL plain models seeded once — orgs cannot mutate the base. A tenant-scoped `framework_versions` table (uses C2 `TenantScoped`) pins a version snapshot per org; future per-org customization is additive override rows, never full copies. `spatie/laravel-translatable` stores `{it,en}` per translatable column with transparent locale accessors. The seeder is idempotent (upsert by natural key), adapter-tolerant across split/unified shapes, and treats absent files as flagged authoring gaps.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `api/composer.json` | Modified | Add `spatie/laravel-translatable` (verify L13 compat at design — D37) |
| `api/app/Models/{Role,Competency,BarsIndicator}.php` | New | GLOBAL, translatable; NOT `TenantScoped` |
| `api/app/Models/FrameworkVersion.php` | New | Extends `TenantModel`; org version pin |
| `api/database/migrations/` | New | `roles`, `competencies`, `bars_indicators`, `framework_versions` (org_id-first index) |
| `api/database/seeders/FrameworkCatalogSeeder.php` | New | Idempotent EN seed; graceful on missing files |
| `api/app/Http/Controllers/Framework*` | New | Read-only roles/competencies/BARS endpoints |
| `api/routes/api.php` | Modified | Framework read routes (org-scoped) |
| `api/tests/` | New | Seeder exactness/idempotency (~high coverage); read API; tenant pin |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| `bars/SRX.json` missing → incomplete SRX seed | High | Seeder skips + flags; tracked authoring task; not a C3 blocker |
| MTG/LAT absent → no `potential` competency data | High | Explicit non-goal; flagged authoring task; blocks C9 potential flow only |
| BUL.json covers 8/14 competencies | Med | Verify at spec/design; seed present, flag gaps |
| EN-only anchors (no IT) degrade IT scoring | Med | Seed EN base; IT pending (decision #6); translatable columns ready; gates non-EN scoring in C9 |
| `spatie/laravel-translatable` incompatible with Laravel 13 | Med | Verify at design/spec (D37); if unresolvable STOP + report — do NOT substitute |
| Global-vs-tenant architecture wrong → costly retrofit | Low | Locked: global base + `FrameworkVersion` pin; additive overrides later |

## Rollback Plan

Feature branch on the `api` submodule. Migrations reversible (`down()` drops framework tables, restoring C2 schema). No prod data/deploy. Rollback = `git revert` + `migrate:rollback` + remove the translatable dependency.

## Dependencies

- **C2 (`tenancy-identity`)** — implemented; provides `TenantModel`/`TenantScoped`/`organization_id`, consumed by `FrameworkVersion`.
- `scoring-model` spec (archived `scoring-discrete-bars`) — anchors `{5,3,1}`, scores `{1,3,5}`; C3 stores anchor text, C9 scores.
- **Downstream:** C4 wires project→`framework_version` FK + pin-at-creation; C9 reads anchors.

## Success Criteria

- [ ] GLOBAL `Role`/`Competency`/`BarsIndicator` models + migrations; NOT tenant-scoped.
- [ ] `FrameworkVersion` extends `TenantModel`; `organization_id`-first composite index; migrations reversible (D22).
- [ ] `spatie/laravel-translatable` installed (L13 compat verified); name/definition/anchor columns translatable `{it,en}`.
- [ ] `FrameworkCatalogSeeder` idempotent (re-run = no duplicates); seeds EN + present BARS roles; skips+flags missing files (SRX) without failing.
- [ ] Seeder reads split-file shape AND tolerates a future unified competency object.
- [ ] Read-only org-scoped API: list roles, list competencies, a role's BARS indicators/anchors.
- [ ] Seeder exactness + idempotency covered at ~high (correctness-critical) coverage.
- [ ] Data gaps (SRX BARS, MTG/LAT, IT anchors, BUL coverage) recorded as explicit authoring tasks — none fabricated.
