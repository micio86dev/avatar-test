# BEAI — Local trial guide

How to run BEAI on your machine, and what you can actually see once it is up.

> **Every command below was really executed**, on this machine, on 2026-08-01.
> Where something does not work, it is stated plainly rather than glossed over.

---

## 1. Prerequisites

Only **Docker Desktop** is required (tested with 29.4.3). Everything else runs
inside the containers: no PHP, Node or Bun on the host to bring the stack up.

```bash
docker info      # must respond without errors
```

---

## 2. Startup

From the wrapper root:

```bash
./scripts/dev.sh
```

It is idempotent: re-running it breaks nothing. It always rebuilds the app
images: the backoffice is a static SPA, its bundle is produced at build time, and
a stale image serves stale code no matter what the working tree says. Useful
options:

| Command | What it does |
|---|---|
| `./scripts/dev.sh --no-build` | start without rebuilding (reuse the current images) |
| `./scripts/dev.sh --status` | service status and health |
| `./scripts/dev.sh --logs` | follow the logs of all services |
| `./scripts/dev.sh --down` | stop the containers (data is kept) |
| `./scripts/dev.sh --fresh` | **DESTRUCTIVE**: drop the volumes and start from scratch |

When it finishes you see:

```
Candidate app   http://localhost:3000
Backoffice      http://localhost:3001
API             http://localhost:8000/api/health
Mailpit         http://localhost:8025
Postgres        localhost:5432   ·   Redis  localhost:6379
```

Quick check:

```bash
curl -s http://localhost:8000/api/health
# {"status":"ok", ...}
```

---

## 3. Populating the database

A freshly migrated database is **empty and unusable**: without the framework
catalog (competencies, roles, BARS anchors) no project can be created.

### 3.1 Catalog + roles

The catalog lives in the **wrapper** (`docs/app_description/`), not inside the
`api` submodule — so the container cannot see it. It has to be copied in once:

```bash
docker cp docs/app_description/02-domain/framework beai_api:/tmp/framework

docker compose exec -e FRAMEWORK_CATALOG_PATH=/tmp/framework api \
  php artisan db:seed
```

> **Why the manual step.** The seeder looks for the catalog in
> `dirname(base_path())/docs/...`, which works in a checkout but resolves to
> `/var/docs` inside the image, where there is nothing. The
> `FRAMEWORK_CATALOG_PATH` variable exists precisely to override that default.
>
> A direct mount (`./docs:/var/docs:ro` in the compose file) would be cleaner,
> but **it does not work on this machine**: the project sits on
> `/Volumes/Scheda SSD` and Docker Desktop does not list that path among its
> shared folders. If you add it under *Settings → Resources → File Sharing*, the
> mount becomes the better route.

Expected output:

```
Database\Seeders\RolesAndPermissionsSeeder ...... DONE
Database\Seeders\FrameworkCatalogSeeder ......... DONE
```

### 3.2 A real organization and admin

There is no API and no screen to create an organization: projects and
participants have endpoints, organizations do not, and the platform superadmin is
born with `organization_id = null`. From a migrated database there is therefore
no way *over HTTP* to reach anything you can log into. A command is required, and
it works everywhere (production included: no known password, no fake data),
because it **asks for nothing interactively** — it runs in a container with no
terminal, where `app:create-superadmin` cannot go.

```bash
php artisan beai:provision-organization \
  --name="Acme Corp" \
  --admin-email=admin@acme.com \
  --admin-name="Acme Admin"
```

```
Organization provisioned: Acme Corp (id=1, slug=acme-corp)
Roles created: admin, operator, viewer (scoped to this organization)
Administrator: admin@acme.com
Password: <generated, 20 characters>
This password is shown once and cannot be recovered. Store it now.
```

In a single transaction it creates the organization, the three authorization
roles (`admin`, `operator`, `viewer`) scoped to that organization, and the
administrator user. Those credentials get you into the backoffice.

Useful options:

| Option | Effect |
|---|---|
| `--slug=` | explicit slug instead of deriving it from the name |
| `--admin-password=` | a password of your choosing — in that case it is **not** printed |
| `--locale=` | language of the admin's notifications (default `it`) |

> It refuses to overwrite: if the slug or the email already exists it exits with
> an error and writes nothing. The admin it creates is an administrator **of its
> own organization**, not a platform superadmin — that one remains
> `app:create-superadmin`.

#### In production on Railway: `ssh`, not `run`

```bash
railway ssh --service api \
  "php artisan beai:provision-organization --name=Quint --admin-email=admin@quint.com"
```

**`railway run` does not work for this.** It injects the environment variables
but executes the command *on your machine*, and `DB_HOST` points at
`pgvector.railway.internal` — a name on Railway's private network, which does not
resolve from a laptop:

```
SQLSTATE[08006] could not translate host name "pgvector.railway.internal" to address
```

`railway ssh` runs **inside** the container, where that name exists. On top of
that, the database credentials never transit through your machine.

A read-only check before writing, if you want one:

```bash
railway ssh --service api "php artisan tinker --execute=\"echo App\\\\Models\\\\Organization::count();\""
```

### 3.3 Demo data

`beai:demo-seed` **never creates a user**, in any environment: the login stays
the one created in §3.2. What it brings is a rich, BARS-valid dataset inside the
organization you have just provisioned — projects, participants in every
lifecycle status, evaluations with scores computed by the real engines,
proctoring events. Every row carries the `beai-demo-` prefix, so it never gets
confused with real data and stays selectable for teardown.

```bash
docker compose exec api php artisan beai:demo-seed --org=acme-corp
```

```
Demo dataset provisioned.
  | FrameworkVersion | beai-demo-1.0.0 (locked=false)                            |
  | Avatar templates | 2 (1 active)                                              |
  | Projects         | 4                                                        |
  | Participants     | 9 across every lifecycle status                          |
  | Evaluations      | 5 with computed competency results and indicator scores  |
  | Snapshots        | 34 objects written to the configured disk                |
```

> It is idempotent: re-running it duplicates nothing. If the dataset is left
> half-built (a row deleted by hand, say) the command **refuses** to proceed
> rather than guess — use `beai:demo-teardown --org=acme-corp` to clean up, then
> re-run the seed.
>
> In production `--force-production` is required: creating a demo project locks
> (`is_locked=true`) a `FrameworkVersion`, a cross-tenant and permanent effect —
> the command prints this before writing any row.

To remove everything this command created, including the placeholder images on
object storage, without touching the real data of the same organization:

```bash
docker compose exec api php artisan beai:demo-teardown --org=acme-corp
```

---

## 4. What you can try right now

### 4.1 Backoffice — http://localhost:3001

Works **completely**. Log in with the credentials printed in §3.2
(`admin@acme.com` / the one-time generated password).

- **Dashboard** — aggregate metrics for the organization
- **Participants** — list with filters, plus the individual candidate detail
- **Avatar templates** — face, voice and interview tuning (see §4.5)
- **Analytics consent banner** — appears after login (see §6)

The lifecycle gates are real: the transcript opens from `in_valutazione` onwards,
the evaluation only on `completato`. The demo dataset covers all five statuses at
once — `beai-demo-c-006` is `in_attesa`, so transcript and evaluation both answer
**409** for that candidate; `beai-demo-c-001` is `completato` and exposes both.
Neither is a bug: that is the gate doing its job.

### 4.5 Avatar templates

They define the face and the voice every candidate of the organization meets.
**Only one template is active at a time**, guaranteed by a partial unique index
in the database: this is not an application-level rule, so two concurrent
activations cannot both win.

The form is built from the *field specs* served by the API — 12 knobs for HeyGen,
17 for Tavus — so a knob added server-side shows up here without touching the
frontend, and one the server does not know about cannot show up at all.

Things worth knowing while trying it:

- **The provider is named only here.** You need it to know which dashboard to
  copy the identifiers from. The candidate never sees it: no string, no error, no
  frontend translation names the vendor.
- **Clearing a field removes it**, it does not zero it: absent means "use the
  provider default", an empty string is a value.
- **The provider cannot be changed** after creation — the settings belong to a
  single vendor and none of them overlap.
- **The active template cannot be deleted**: activate another one first.
- Without a provider key you can create and activate templates, but the interview
  does not start (see §5).

An organization **without** an active template is not an error: interviews fall
back to the environment defaults, exactly as before this feature existed.

### 4.2 API — http://localhost:8000

```bash
# Use the email and password printed in §3.2 (beai:provision-organization).
TOKEN=$(curl -s -X POST http://localhost:8000/api/auth/login \
  -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d '{"email":"admin@acme.com","password":"<the password generated in §3.2>"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

curl -s http://localhost:8000/api/auth/me -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json'
curl -s http://localhost:8000/api/participants -H "Authorization: Bearer $TOKEN" -H 'Accept: application/json'
```

Verified: the login returns a JWT, `/me` reports user + organization + roles, and
`/participants` returns only the candidates of your tenant.

OpenAPI documentation generated by Scramble: `http://localhost:8000/docs/api`.

### 4.3 Candidate app — http://localhost:3000

The root is an **informational page**, not a home: no login, no form. That is
intentional — a candidate never types this address, they arrive from a magic
link.

### 4.4 Mailpit — http://localhost:8025

Captures all outgoing mail. Locally nothing is sent until you trigger a
notification.

---

## 5. What you cannot try (and why)

This is the honest answer to "is everything ready?".

### The real interview does not start

It needs credentials that do not exist in this repo, and rightly so:

| Needed | For what | Where it lives |
|---|---|---|
| `ANTHROPIC_API_KEY` | asynchronous BARS scoring | goes in the variable store, never committed |
| avatar provider key (HeyGen / Tavus) | video + synthetic voice | same |

Without an avatar key the consent screen and the device check are visible, but
the avatar does not connect. Without an Anthropic key a completed interview stays
in `in_valutazione` and never reaches `completato`.

### The magic link has to be built by hand

The real flow is: the calling system calls `POST /api/m2m/sso-link` with an M2M
key, gets a token, and sends the candidate to `/api/sso/exchange?token=…`. To do
that locally you first have to create an M2M client (`POST /api/m2m/clients` with
the admin JWT). `beai:demo-seed` **does not** do it: minting ingress tokens is
the kind of thing that deserves an explicit step.

### The GDPR purge is disabled

`beai:purge-expired-data` exists and is tested, but it ships **switched off** and
all durations are `null`: they are waiting on legal sign-off (open decision #2).
Running it now prints `Retention is DISABLED` and touches nothing. It is the only
thing still open in C13.

### Pulse does not open in the browser

`/pulse` records everything correctly in the `pulse_*` tables, but the HTML
dashboard is not navigable: the API is stateless JWT, with no session login, and
Livewire's XHR calls do not carry the `Authorization` header. It needs an
authenticator in front of it, or you read the tables directly. Details in
`docs/observability.md`.

---

## 6. Analytics and consent

GA4 and Microsoft Clarity are wired into both Nuxt apps, but **switched off
twice**: no ID configured, and consent denied by default. Locally nothing is sent
to third parties.

If you want to see the banner, start with a fake ID:

```bash
NUXT_PUBLIC_GA_MEASUREMENT_ID=G-TEST ./scripts/dev.sh --build
```

The banner **does not appear** on the interview routes, nor on
participants/login in the backoffice: analytics simply do not run there, and a
cookie dialog on top of a person's evaluation would be the wrong thing in the
wrong place.

---

## 7. Tests

They run outside Docker and need the local toolchain (PHP 8.5, Bun, Node 24).

```bash
# API — 1320 tests
cd api && php -d memory_limit=4G vendor/bin/pest
cd api && ./vendor/bin/phpstan analyse --memory-limit=1G

# Frontend — 464 unit + 105 E2E
cd frontend && bunx vitest run
cd frontend && bunx playwright test

# Backoffice — 250 unit + 69 E2E
cd backoffice && bunx vitest run
cd backoffice && bunx playwright test
```

> **A real trap**: Playwright reuses a server already listening on 3000/3001. If
> you started one by hand — or if the container is running — the tests run
> against *that one*, without the environment variables Playwright injects, and
> would fail for reasons that have nothing to do with the code. Stop everything
> first.

> If a Nuxt build fails with `Invalid or unexpected token`, it is not the code:
> `node_modules` is corrupted. `rm -rf node_modules && bun install` fixes it.
> `bun install` alone is not enough.

---

## 8. Common problems

| Symptom | Cause | Remedy |
|---|---|---|
| `db:seed` → `Call to undefined function fake()` | stale image | `docker compose build api` |
| `db:seed` → catalog not found | `docs/` not visible in the container | redo the `docker cp` from §3.1 |
| `api` does not start, mount error | Docker file sharing | remove the mount, or enable the path |
| Backoffice shows 401 | expired JWT | log in again |
| Docker hangs | backend stuck | `pkill -f 'Docker Desktop'; pkill -f com.docker.backend; open -a Docker` |

---

## 8.1 Vercel: disabled on purpose

The deploy target is **Railway**. A Vercel GitHub App was connected to this
wrapper and created a Production deployment on every merge to `main` — harmless
in practice, since there is no application to serve here, but still a violation
of a binding rule.

`vercel.json` with `git.deploymentEnabled: false` switches it off from the
repository. The file is there to **prevent** Vercel deploys, not to configure
them.

Removing it entirely requires disconnecting the integration from the Vercel
dashboard: this file neutralizes it, it does not uninstall it.

## 9. Product status

14 vertical slices (C1→C14). **All delivered.**

C14 also closed two defects that were already in production: the candidate saw a
provider iframe inside the interview page, and Tavus sessions never reached
completion — so they were never evaluated.

A single blocking task remains across the whole project: the **GDPR retention
durations**. That needs a lawyer, not more code — the mechanism is built so that
ratifying them is a configuration change, not a code change.

Two things deferred by choice, written up in
`openspec/changes/avatar-provider-templates/tasks.md`: no per-project template
override (projects already have a `language`, so a single avatar per organization
may be tight for anyone interviewing in two languages), and avatar/voice ids are
not validated against the provider's real inventory.

The three gaps that surfaced while writing this guide, all real and none of them
blocking for trying the product:

1. **No surface to create an organization** — neither API nor UI. Today
   `beai:provision-organization` covers it (§3.2).
2. **The framework catalog is not reachable from the container** — the path is
   relative to the wrapper, now overridable with `FRAMEWORK_CATALOG_PATH`.
3. **The end-to-end interview requires provider credentials** that nobody has put
   into an environment yet.
