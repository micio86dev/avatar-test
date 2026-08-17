# Tasks — organization provisioning

## 1. Command

- [x] 1.1 `ProvisionOrganizationCommand` with `beai:provision-organization` signature, every input an option (D1)
- [x] 1.2 Input validation: name and admin email required, email shape checked, slug derivable
- [x] 1.3 Duplicate-slug and duplicate-email refusal with an operator-readable message (D5)
- [x] 1.4 Organization + three org-scoped roles + admin user written in one `DB::transaction` (D3)
- [x] 1.5 `team_id` passed explicitly to `Role::firstOrCreate`, registrar context set for `assignRole` (D2)
- [x] 1.6 `organization_id` via the relation, `is_superadmin` written explicitly — neither through mass assignment (D6)
- [x] 1.7 Password generated when omitted and printed once; a supplied password never echoed (D4)

## 2. Tests

- [x] 2.1 Provisions organization, roles and admin
- [x] 2.2 Admin is org-scoped, never a platform superadmin
- [x] 2.3 All three roles carry the organization's `team_id`
- [x] 2.4 Admin resolves `hasRole('admin')` inside the organization's team context
- [x] 2.5 Slug derived from name, overridable with `--slug`
- [x] 2.6 Generated password is printed and authenticates
- [x] 2.7 Supplied password is used and not echoed
- [x] 2.8 Duplicate slug and duplicate email both refused with no writes
- [x] 2.9 Missing name / missing email / malformed email all refused
- [x] 2.10 Runs under `--no-interaction`
- [x] 2.11 **Rollback genuinely exercised** — a DB-level insert failure past validation leaves no organization behind

## 3. Verification

- [x] 3.1 Mutation check: dropping the explicit `team_id` turns the suite red (11/12)
- [x] 3.2 Mutation check: removing `DB::transaction` turns the suite red — it did NOT before task 2.11 was added, which is why 2.11 exists
- [x] 3.3 Pint, PHPStan level 8, full Pest suite green (1406 tests)

## 4. Documentation

- [x] 4.1 `GUIDE.md` — bootstrap step for a fresh deployment
- [x] 4.2 `docs/dev-setup.md` — same command for a local database

## Notes

Task 3.2 is the one worth remembering. The first version of the atomicity test
passed with the transaction *removed*, because `validateInput()` short-circuits
every failure path it covered before a single row is written. It asserted
nothing. Task 2.11 drives a failure past validation into the INSERT, and turns
red without the transaction.
