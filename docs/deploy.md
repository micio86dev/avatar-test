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

## Release Steps on Deploy — `beai:deploy` (`api`)

The `api` service's Railway **`preDeployCommand` MUST be exactly**:

```
php artisan beai:deploy
```

One command, no `&&`, no shell operators of any kind.

**Why one command.** `preDeployCommand` is **not shell-evaluated**. A previous
`php artisan migrate --force && php artisan beai:sync-llm-registry` handed
everything after the `&&` to `migrate` as inert arguments; `migrate` ignored them
and exited 0, so the deploy went green with the second step never invoked. The
workaround moved the registry sync into `docker/entrypoint.sh` — but a bare
`migrate --force` was never restored to the field, so **nothing migrated on
deploy at all**. The schema stayed current only because a human ran migrations by
hand over SSH; a deploy carrying a new migration would have gone green and then
queried columns that did not exist.

`beai:deploy` runs both steps with the failure semantics each one needs:

| Step | Fatal? | Why |
|---|---|---|
| `migrate --force` | **Yes** — non-zero exit aborts the deploy | Booting code against a schema it does not have is the failure this exists to prevent |
| `beai:sync-llm-registry` | **No** — warns, still exits 0 | Catalogue data, not schema. A transient DB hiccup over `llm_models` must not refuse a release; the worst case is a stale model picker |

Every step prints a `[deploy]`-prefixed line. The defect above survived because
the log was silent — a step that never ran and a step that ran cleanly look
identical when neither prints anything. **After the next deploy, check the log
actually contains `[deploy] migrations OK`.**

Migrations deliberately do **not** live in `docker/entrypoint.sh`:
`preDeployCommand` runs once per deploy in its own container, while an entrypoint
runs once per **replica** and on every restart, so migrations there would race
between replicas. The entrypoint is now a pass-through and no longer runs the
registry sync — `beai:deploy` owns both steps, in the correct order, in the
once-per-deploy slot.

To run the same steps by hand:

```
railway ssh --service api -- php artisan beai:deploy
railway ssh --service api -- php artisan beai:sync-llm-registry   # catalogue only
```

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
| `CORS_ALLOWED_ORIGINS` (api) | `http://localhost:3001,http://localhost:3000` | Both deployed Nuxt origins — see below |

## CORS Allowlist (`api`, backoffice-session-refresh-hardening D1)

`api/config/cors.php` reads its allowlist from `CORS_ALLOWED_ORIGINS` — a
comma-separated list, **no wildcard, no regex pattern**. It MUST contain BOTH
deployed Nuxt origins in every environment:

- the `backoffice` origin (operator login, session refresh)
- the `frontend` origin (candidate SSO exchange, interview) — the candidate
  app also calls `api/*`, so an allowlist covering only `backoffice` silently
  takes the candidate app down.

```
CORS_ALLOWED_ORIGINS=https://backoffice.<env>.beai.app,https://frontend.<env>.beai.app
```

`supports_credentials` is unconditionally `true` (required by the httpOnly
refresh cookie), which is why the allowlist can never contain `*` — the two
are mutually exclusive per the Fetch spec, and every browser refuses the
combination.

## Refresh Tokens Are Database-Backed, Not Redis (backoffice-session-refresh-hardening — corrected)

`App\Support\Auth\RefreshTokenStore` persists refresh-token families in the
`refresh_tokens` PostgreSQL table (migration
`2026_08_20_000001_create_refresh_tokens_table.php`), not Redis.

An earlier version of this change stored refresh-token families in Redis and
required `maxmemory-policy=noeviction` on the instance backing `CACHE_STORE`.
That was rejected: `api/.env.example` sets `CACHE_STORE=redis`,
`QUEUE_CONNECTION=redis` and `SESSION_DRIVER=redis` — the SAME Redis instance
serves cache, queues and sessions. Forcing `noeviction` on it means that once
memory fills, cache writes and queue pushes fail outright and the application
breaks. A cache must stay evictable; durable authentication state belongs in
the database, following the same shape Laravel already uses for
`password_reset_tokens` and Sanctum's `personal_access_tokens`, plus a
scheduled `model:prune` of expired/revoked rows (`bootstrap/app.php`'s
`withSchedule()`, run by `schedule:work`).

There is no Redis eviction-policy deploy gate for refresh tokens anymore —
`beai:check-redis-eviction` has been removed. `GET /api/health/queue`'s
`redis_eviction_policy` field still reports the shared cache Redis's actual
policy for general observability, but nothing requires it to be
`noeviction` — a cache should normally run an eviction policy, not
`noeviction`.

**Deploy-risk note**: this is the change's first migration.
`2026_08_20_000001_create_refresh_tokens_table.php` executes against the live
database on the next deploy **provided `preDeployCommand` is
`php artisan beai:deploy`** — see *Release Steps on Deploy* above. It was NOT
true that Railway ran `migrate --force` when this note was first written; that
was the defect `beai:deploy` fixes. The migration itself is purely additive
(`CREATE TABLE`, one new foreign key to the existing `users` table, no
column/table alterations), so it is safe to run against a live database with no
downtime.

## Recovering a Locked-Out User

Self-service email reset **has shipped** (api v0.36.0, backoffice v0.22.0):
`/forgot-password` in the backoffice. Prefer it — it revokes the user's whole
refresh-token family, which the operator command below also does but which no
other path guarantees.

**It is inert until mail is configured.** `BACKOFFICE_ORIGIN` is set on both
`api` and `worker`, but `RESEND_API_KEY` is empty and `MAIL_MAILER` is unset,
so `config('mail.default')` resolves to `log` — which delivers nothing, without
erroring. Set `RESEND_API_KEY` and `MAIL_MAILER=resend` on **both** services
(the link is minted inside a queued job, so the worker needs them too), verify
the sender domain with the provider, then confirm with:

```
railway ssh --service api -- php artisan beai:mail-selftest --to=you@example.com
```

That command refuses to report success on the `log` and `array` transports, so
a pass from it means real delivery rather than a green light over a no-op.

While mail is unconfigured — or during a provider outage, when the reset email
cannot arrive — an operator with shell access to the `api` service can reset a
password directly:

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
