# Deploy — BEAI

## Principles (D34)

- Each service (`api`, `frontend`, `backoffice`) is a **separate Railway service**
  monitoring ONLY its own repository's `main` branch.
- Deploying `api` does NOT trigger `frontend` or `backoffice`.
- Deploying `frontend` does NOT trigger `api` or `backoffice`.
- A hotfix to `api` can ship without waiting for the frontend release cycles,
  provided the API backward-compatibility contract (D33) is maintained.
- The wrapper superproject has **no Railway service** of its own.
- **Railway is never triggered by CI automatically in C1.**
  All deploys are explicit, human-initiated actions.

## How to Deploy (C1 is not yet deployable — this is reference for C2+)

1. Ensure the submodule's feature PR is merged to its `develop` branch.
2. Cut a `release/vM.m.p` branch, bump the version SoT, run the full test suite green.
3. Open a PR from `release/vM.m.p` → `main` in that submodule's repository.
4. After merge to `main`, tag the commit `vM.m.p`.
5. Railway's deploy trigger watches `main` and deploys automatically (once wired).
6. Merge `main` back to `develop` to keep Git Flow in sync.

## Railway Config

Each submodule carries a committed `railway.json` selecting the Docker builder.
In C1 these configs are **inert** (no Railway service is wired). They will be
activated in C2+ when the Railway project is created and services are linked
to each repository's `main` branch.

| Service | `railway.json` location | Builder |
|---------|------------------------|---------|
| `api` | `api/railway.json` | DOCKERFILE |
| `frontend` | `frontend/railway.json` | DOCKERFILE |
| `backoffice` | `backoffice/railway.json` | DOCKERFILE |

## Environment Variables on Railway

Each Railway service receives its environment variables via the Railway dashboard
(not committed to the repo). Reference each app's `.env.example` for the required
variables. Key differences from local docker-compose values:

| Variable | Local value | Railway value |
|----------|-------------|---------------|
| `DB_HOST` | `postgres` (compose service name) | Supabase host (managed PostgreSQL 17) |
| `REDIS_HOST` | `redis` (compose service name) | Railway Redis private host |
| `NUXT_PUBLIC_API_BASE` | `http://api:9000/api` | HTTPS API service URL |
| `NUXT_PUBLIC_APP_ENV` | `local` | `staging` or `production` |

## Recovering a Locked-Out User

When an existing user has forgotten their password and no in-app recovery
path applies (self-service email reset is not yet shipped), an operator with
shell access to the `api` service can reset it directly:

```
railway ssh --service api -- php artisan beai:reset-user-password user@example.com --no-interaction
```

- The password is always **generated**, never supplied — there is no
  `--password=` option, so a credential is never typed into shell history.
- The generated password is **printed exactly once**, in the command's own
  output. It is not stored anywhere else and cannot be recovered afterward —
  copy it immediately.
- The reset **revokes every existing session** for that user: any token
  issued before the reset is rejected on its next use, regardless of
  remaining TTL, so every device the user was logged into must sign in again.
- A **deactivated** user is refused, not reactivated — reactivate them first
  (via the backoffice or `POST /api/users/{id}/reactivate`), then re-run the
  command.
- This command only resets an **existing** user. For a deployment with no
  organization and therefore no admin at all, use
  `beai:provision-organization` instead.
