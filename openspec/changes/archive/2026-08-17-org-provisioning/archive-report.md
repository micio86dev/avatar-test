# Archive Report: org-provisioning

**Change**: org-provisioning  
**Archived**: 2026-08-17  
**Status**: Complete  
**Tasks**: 23/23 complete  

## Summary

Non-interactive artisan command for provisioning a complete organization and its first administrator account in a single atomic operation. Closes the gap where production deployments could have a healthy API, migrated database, and running backoffice but nobody could log in (no organization, no admin).

Command: `php artisan beai:provision-organization --name="..." --admin-email=... [--admin-name=...] [--admin-password=...]`

## Artifacts Verified

- **Proposal**: openspec/changes/org-provisioning/proposal.md ✅
- **Specs**: openspec/changes/org-provisioning/specs/organization-provisioning/spec.md (ADDED delta) ✅
- **Design**: openspec/changes/org-provisioning/design.md ✅
- **Tasks**: openspec/changes/org-provisioning/tasks.md (23/23 complete) ✅
- **Verify Report**: Engram #1063 ✅

## Promoted Specs (Created)

1. `/openspec/specs/organization-provisioning/spec.md` — NEW spec
   - ADDED: "Operators SHALL provision an organization and its first admin non-interactively"
   - ADDED: "The provisioned admin SHALL NOT be a platform superadmin"
   - ADDED: "Roles SHALL be scoped to the organization"
   - ADDED: "Provisioning SHALL be atomic"
   - ADDED: "The command SHALL refuse to overwrite existing records"
   - ADDED: "A generated password SHALL be shown exactly once"

## Test Coverage

- Full suite: ProvisionOrganizationCommandTest.php (14 tests, all passing)
- Mutation test A (team_id): removed explicit `team_id` from `Role::firstOrCreate` → 13/14 tests failed (mutation detected)
- Mutation test B (atomicity): removed `DB::transaction()` → rollback test failed (mutation detected)
- Both mutations verified and restored via byte-identical restoration

## Code Quality

- PHPStan: 0 errors
- Pint: clean
- Full Pest suite: 1406 tests passing
- Atomicity proven: explicit `team_id` required on role creation, transaction wrapping required for rollback

## Design Decisions (D1-D7)

All design decisions from design.md are implemented and verified:
- D1: Non-interactive options (not `ask()` prompts)
- D2: Explicit `team_id` to registrar context (prevents silent inert roles)
- D3: Single `DB::transaction()` wrapping organization + roles + user (atomicity proven by mutation)
- D4: Generated password shown once; supplied password never echoed
- D5: Duplicate slug and email both refused with no writes
- D6: `organization_id` via relation, `is_superadmin` explicit (not mass-assignment)
- D7: User has `organization_id` set; is admin within that org's team context only

## Documentation

- GUIDE.md (superproject root): bootstrap step for fresh deployment ✅
- docs/dev-setup.md (superproject root): same command for local database ✅
- Note: Proposal's "Impact" section technically places these files as if inside `api/` when they live at superproject root, but content is correct

## Deliverables

- `api/app/Console/Commands/ProvisionOrganizationCommand.php` — command implementation ✅
- `api/tests/Feature/Provisioning/ProvisionOrganizationCommandTest.php` — 14 tests ✅
- `api/tests/Pest.php` — RefreshDatabase trait wired ✅
- Documentation updates ✅

## SDD Cycle

✅ **Propose** → **Spec** → **Design** → **Tasks** → **Apply** → **Verify** → **Archive**

All 23 tasks delivered. Verification verdict: **CLEANEST OF THE THREE CHANGES** — task claims and code state match perfectly. The two most load-bearing behaviors (team scoping via explicit `team_id`, atomicity via `DB::transaction`) are provably tested via mutation, not just documented as tested.

**Change is ready for archive.**

---

Observation IDs for traceability:
- Verify Report: Engram #1063
