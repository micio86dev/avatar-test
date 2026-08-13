# Organization provisioning

## Why

There is no way to create an organization. Production has a healthy API, a
migrated database and a running backoffice, and **nobody can log into it** —
there is no organization, so there is no organization admin, so there is no
account to authenticate.

The two things that come closest both fail to close the gap:

| Existing surface | Why it does not solve this |
|---|---|
| `app:create-superadmin` | Creates a *platform* superadmin with `organization_id = NULL`. It never creates an organization. It is also fully interactive (`ask()`), so it cannot run in a container without a TTY — and `--no-interaction` makes every answer `null`, which the command then rejects. |
| `RolesAndPermissionsSeeder` | Creates a hardcoded `dev-org` and its three roles. Its own docblock says "for development/staging". It seeds no user, so still nobody can log in. |
| `DemoSeeder` | Refuses to run in production, by design. |

So the first real tenant has to be created by hand, directly against the
database, in exactly the place where hand-written SQL is least welcome — and
where getting the Spatie team scoping subtly wrong produces an admin whose role
is silently inert (see D2 below).

## What changes

A single non-interactive artisan command that provisions one organization and
its first admin atomically:

```
php artisan beai:provision-organization \
  --name="Acme Corp" \
  --admin-email=admin@acme.com \
  --admin-name="Acme Admin"
```

It creates the organization, the three org-scoped authorization roles
(`admin`, `operator`, `viewer`), and one user holding `admin` — in one
transaction, so a failure leaves nothing behind.

## What does not change

- No HTTP surface. Provisioning a tenant is an operator action, not an API one;
  exposing it over HTTP would mean designing who is allowed to call it, and the
  answer today is "the person with shell access".
- `app:create-superadmin` stays as it is. Platform superadmin and organization
  admin are different identities (`is_superadmin` vs. an org-scoped Spatie
  role) and conflating them is precisely what C2 forbids.

## Impact

- New: `app/Console/Commands/ProvisionOrganizationCommand.php`
- New: `tests/Feature/Provisioning/ProvisionOrganizationCommandTest.php`
- Touched: `tests/Pest.php` (wire `Feature/Provisioning` to `RefreshDatabase`)
- Touched: `docs/dev-setup.md`, `GUIDE.md` (document the bootstrap step)
