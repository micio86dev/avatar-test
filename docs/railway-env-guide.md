# Railway environment variables — Public API, Embed and Developer Area

Project `beai`, environment `production`. Services: `api`, `worker`, `scheduler`
(same Laravel codebase), `frontend`, `backoffice`, `Redis`, `pgvector`.
Set a variable with the Railway dashboard (service > Variables) or the CLI:

```sh
railway link --project dad8b4f9-ed1a-4417-94be-2018378ff852 --environment production
railway variable set "KEY=value" --service api --skip-deploys   # then redeploy the service
```

An empty value is safe for every variable below marked "empty = default":
`config/public_api.php` applies its defaults with `?:`, so `KEY=` behaves like an unset key.

## Set with a real value (already done on 2026-09-25)

| Variable | Services | Value | Notes |
|---|---|---|---|
| `PUBLIC_API_SESSION_SECRET` | api, worker, scheduler | random 64-hex string | Dedicated signing secret for session tokens, never reuse `JWT_SECRET`. Generated with `openssl rand -hex 32`; nobody has the value except Railway. Rotating it invalidates outstanding session tokens (15 min lifetime). Read it back with `railway variable list --service api` (values visible to a logged-in CLI). |
| `PUBLIC_API_URL` | api, worker, scheduler | `https://api-production-640e.up.railway.app/api/v1` | Public base of `/v1`. Change when the API gets a custom domain. |
| `INTERVIEW_URL` | api, worker, scheduler | `https://frontend-production-5cb6.up.railway.app` | Origin of the hosted page `/i/{token}`. Falls back to `CANDIDATE_APP_URL` if empty. |
| `DEVELOPERS_URL` | api, worker, scheduler | `https://backoffice-production-ec05.up.railway.app/developers` | Where the Scalar docs are served. |

Already correct and untouched: `frontend` `NUXT_API_ORIGIN` (the embed page's CSP lookup and the `/api` proxy
both use it; verified the proxy answers), `backoffice` `BEAI_API_ORIGIN`.

## Set empty (you must decide a value, or leave empty)

| Variable | Service | Empty means | Where to get / what to choose |
|---|---|---|---|
| `EMBED_CDN_URL` | api, worker, scheduler | none (docs show no CDN snippet) | The public URL of the published `@beai/embed` IIFE bundle. Publish the package first (npm, or upload `embed/dist/embed.iife.js` to a CDN/bucket) and use that URL. |
| `PUBLIC_API_CONTRACT_PATH` | api, worker, scheduler | `base_path('public-api/openapi.yaml')` | Only for contract validation against a vendored spec. Leave empty in production. |
| `PUBLIC_API_SPEC_SERVER_URL` | api | `https://api.beai.example/v1` placeholder in the exported spec | Decision G-03: the real public API host (custom domain). Only matters when re-exporting `openapi.v1.json`. |
| `PUBLIC_API_RATE_LIMIT_LIVE` / `_TEST` | api | 600 / 120 requests per minute per org | Tune under real load (decision 7). Per-org overrides live in the database. |
| `PUBLIC_API_IDEMPOTENCY_RECORD_TTL_SECONDS` | api | 86400 | Idempotency record lifetime. |
| `PUBLIC_API_IDEMPOTENCY_LOCK_TTL_SECONDS` | api | 30 | Concurrent-request lock TTL. |
| `PUBLIC_API_IDEMPOTENCY_LOCK_WAIT_SECONDS` | api | 5 | How long a duplicate request waits for the lock. |
| `PUBLIC_API_SESSION_TOKEN_TTL_MINUTES` | api | 15 | Session-token lifetime. |

## Deliberately NOT touched

`api/.env.example` lists other keys that Railway does not define (`ANTHROPIC_TIMEOUT`, `CONVERSATION_*`,
`HEYGEN_AVATAR_ID`, `TAVUS_REPLICA_ID`, `SCORING_AUDIT_*`, `REFRESH_*`, `SESSION_LIFETIME`, ...). They predate the
Public API and have code defaults; several are read with plain `env()`, so an empty value could override a default
with `0` or `''`. Set them only with a real value.

## Where to find things you may still need

| Secret / value | Where |
|---|---|
| Anthropic key (`ANTHROPIC_API_KEY`) | console.anthropic.com > API keys. GitHub `ANTHROPIC_API_KEY` secret (for `ai-integration.yml`) is separate: `gh secret set ANTHROPIC_API_KEY -R micio86dev/backend`. |
| HeyGen / Tavus keys and ids | HeyGen: app.heygen.com > Settings > API. Tavus: platform.tavus.io > API keys, replicas and personas. |
| Resend (`RESEND_API_KEY`) | resend.com > API Keys. Production mail also needs a verified sending domain (quint.org) in Resend. |
| Sentry DSN / auth token | sentry.io > Project Settings > Client Keys (DSN); Organization Settings > Auth Tokens (`SENTRY_AUTH_TOKEN`). |
| Clarity / GA4 ids (`NUXT_PUBLIC_CLARITY_PROJECT_ID`, `NUXT_PUBLIC_GA_MEASUREMENT_ID`) | clarity.microsoft.com > Settings > Overview; analytics.google.com > Admin > Data streams. |
| Railway service URLs | Railway > service > Settings > Networking, or `railway domain --service <name>`. |
| Database / Redis credentials | Railway > `pgvector` / `Redis` > Variables (referenced by the services; do not copy by hand). |
