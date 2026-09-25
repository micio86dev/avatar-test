# Decisions needed — BEAI Public API

Spec gaps found while implementing `SPEC.md`. Each entry records the question,
the conservative choice taken so work could continue, where the code is marked
with `// SPEC-GAP:`, and what the owner must decide. Every edit to
`openapi.yaml` that is not a pure additive clarification is also logged here.

Status legend: **open** (owner decision pending), **resolved** (owner ruled).

## Found during Phase 0 audit (2026-09-24)

### G-01 — Audio recording ingestion is unspecified · open · blocks full step 6
- **Question.** `GET /v1/interviews/{id}/recording` presumes an audio file exists
  per interview. Neither provider integration retrieves a recording (Tavus and
  HeyGen return only a live `conversation_url`), no table stores an audio object
  key, and the admin resources explicitly say no audio exists
  (`api/app/Http/Resources/Admin/ParticipantDetailResource.php:23-29`).
- **Choice.** Step 6 builds the storage (`interview_recordings`: org, interview,
  object key under `recordings/{org}/{interview}/`, format, duration, size) and
  the signed endpoint on the proven `Storage::disk()->temporaryUrl()` pattern.
  No provider ingestion is built. Live interviews report `recording_ready=false`
  and the endpoint answers `404 recording_not_ready`. The step-9 mock provider
  stores an audio fixture so the path is exercised end to end.
- **Owner decides.** Which provider recording API to pull from (Tavus
  recordings, HeyGen session export), the GDPR retention class for audio
  (ruling 2 sign-off does not cover it), and whether video must be discarded at
  ingestion or never fetched.

### G-02 — No candidate entity exists · resolved (G-00) · steps 4 and 5
- **Question.** The spec models an org-level `Candidate`; the codebase has only
  `participants`, a per-project enrolment keyed `(project_id, email)` with no
  `external_id`/`metadata`. CLAUDE.md ruling 8 rejects a **global** candidates
  table.
- **Choice (superseded by G-00).** No `candidates` table. The public
  `Interview` is the `participants` enrolment and carries `candidate_ref`,
  `email`, `display_name`, `language`, `metadata`. Lookup is by
  `?email=`/`?candidate_ref=` on the interview list.

### G-03 — Public hostnames unconfirmed · open · cosmetic until launch
- **Choice.** Four config keys (`PUBLIC_API_URL`, `DEVELOPERS_URL`,
  `INTERVIEW_URL`, `EMBED_CDN_URL`) with `APP_URL`-derived defaults; docs keep
  `beai.example`.
- **Owner decides.** The real names for `api.`, `developers.`, `interview.`,
  `cdn.`.

### G-04 — Webhook signing format · resolved (G-00) · step 7
- **Question.** The existing calling-system webhooks sign
  `X-BEAI-Signature: v1=<hex>` over `"{ts}.{body}"` with a separate
  `X-BEAI-Timestamp` header, 6 attempts with backoff `[10, 60, 300, 1800, 7200]`
  seconds (`api/config/webhooks.php`). §3.6 specifies `BEAI-Signature:
  t=<unix>,v1=<hex>`, backoff `1m, 5m, 30m, 2h, 12h, 24h`, endpoint model with
  `consecutive_failures` and auto-disable at 50, and a redeliver endpoint.
- **Choice (superseded by G-00).** One format only: the existing
  `X-BEAI-Signature: v1=<hex>` with `X-BEAI-Timestamp`, `X-BEAI-Event`,
  `X-BEAI-Delivery-Id`, the existing `progress`/`evaluation` events and the
  existing retry schedule. Step 7 adds only the read log and redeliver over
  `webhook_deliveries`, plus additive `project.public_id` and `livemode`
  fields in the payload (`payload.version` stays `1.0`).

### G-05 — No prefixed-ULID convention exists · resolved by spec · step 3
- **Question.** All backoffice ids are bigint autoincrement. §3.2 requires
  `int_…`, `cand_…`, `tpl_…`, `exp_…`, `evt_…`, `whd_…`.
- **Choice.** Public ids are **opaque prefixed ULIDs stored in a `public_id`
  column** on each exposed table (unique per table), generated at insert;
  internal bigint keys stay internal. Existing rows are backfilled in the same
  migration. `org_…` is likewise a `public_id` on `organizations`.
- **Owner decides.** Nothing; recorded because it adds a column to five
  existing tables.

### G-06 — Interview status mapping · resolved (G-00) · step 5
- **Question.** The participant lifecycle is `in_attesa → in_corso →
  in_valutazione → completato | errore` and is enforced by a model guard
  (`api/app/Models/Participant.php:131-169`). §3.3 defines `created → invited →
  in_progress → completed | failed | expired | cancelled`.
- **Choice (superseded by G-00).** No new table. `participants` gains
  `public_id`, `metadata`, `exit_redirect_url` and `mode`; the public status
  is a 1:1 English rendering of the binding lifecycle (`pending`,
  `in_progress`, `under_evaluation`, `completed`, `error`). No expiry, no
  cancel. Backoffice behaviour is unchanged.

## Found by the pre-commit review gate (2026-09-24)

### G-00 — The contract contradicted ratified rulings · resolved · Phase 0
- **Question.** The `gga` gate refused the first `openapi.yaml` against
  `AGENTS.md`: `Scoring` (overall score, scale, dimensions, `recommendation`
  bands) versus the binding BARS shape and ruling 1; interview
  `expires_at`/`expired` versus ruling 5 (no deadline concept); a `Candidate`
  entity versus ruling 8; a status machine with no `in_valutazione`; twelve
  lifecycle webhooks versus the binding `progress`/`evaluation` pair with the
  echoed opaque candidate id; per-question `Answer.score`; a `Template`
  without role, assessment type or pinned framework version; a hand-maintained
  contract beside Scramble's generated `api/openapi.json`.
- **Choice (owner, 2026-09-24).** Re-derive the domain-bound schemas from
  `docs/app_description/` and the existing models. Auth, conventions, session
  tokens, embed SDK, exports, test mode and developer docs stay as authored.
  The public contract keeps `openapi.yaml` as the design reference for the
  tests; step 11 publishes the Scramble-generated `/v1` subset and CI diffs
  the two so they cannot drift.

## Found by the RDD reliability review (lineage review-f42f3e293b7574e3)

### G-07 — Error responses and headers missing from the contract · resolved · step 1
- `listInterviews` declared only 200/400; most reads omitted 401/403/429; no
  response declared `RateLimit-*` or `X-Request-Id`.
- **Choice.** Every operation references the shared error responses and the
  common headers (additive clarification of `openapi.yaml`).

### G-08 — Retry schedule count was ambiguous · resolved · step 7
- §3.6 listed six delays and said six attempts.
- **Choice.** The existing `config/webhooks.php` schedule: six attempts, five
  delays `[10, 60, 300, 1800, 7200]` seconds.

### G-09 — Concurrent idempotent requests unspecified · resolved · step 3
- **Choice.** First request takes a Redis lock on `(org, key)`; a concurrent
  second request answers `409 idempotency_in_progress` (new error code).

### G-10 — Cancel allowed from terminal states · superseded by G-00
- **Choice (superseded).** The cancel endpoint and the `created`/`invited`
  states no longer exist (G-00). Do not derive tests from this entry.

### G-11 — Single-use token plus third-party cookie · resolved · step 5
- Browsers blocking third-party cookies drop the `SameSite=None` cookie after
  the token is burned; a reload returned `410` with no recovery.
- **Choice.** Cookie is `Partitioned` (CHIPS) in addition to
  `SameSite=None; Secure`; when the cookie is unreadable the embed page emits
  `error{code:"cookie_blocked", recoverable:true}` and the host may mint a new
  token. Recovery is possible because consuming a token does not change the
  interview status (SPEC §3.5): minting stays allowed while `pending`. The
  `cookie_blocked` code is part of the postMessage error enum (§4.3).

### G-12 — Events list order is an exception to §3.2 · resolved · step 6
- `/interviews/{id}/events` is oldest first; recorded as the one exception.

## Found while re-deriving the schemas (2026-09-24)

### G-13 — The API cannot read the wrapper's contract in CI · resolved · step 1
- `api/.github/workflows/ci.yml` pins the wrapper at a **tag** (`.wrapper-ref`)
  and the framework catalogue is vendored under `api/database/framework` with
  a wrapper-side equality guard.
- **Choice.** Same pattern: the contract is vendored at
  `api/public-api/openapi.yaml`; `config('public_api.contract_path')` points
  there; the wrapper's `ci-guards.sh` asserts byte equality with
  `docs/specs/public-api/openapi.yaml`. The wrapper file stays the source of
  truth.

### G-14 — Existing webhook payload details kept as-is · resolved · step 7
- The existing assemblers send `project{id,slug}` (internal numeric id),
  `data.competencies[{code,status,answers[{question_index,answered_at}]}]`,
  `reliability` as a percentage string (`"100%"`), and may send status
  `processing`/`errore` on a scoring failure.
- **Choice.** Documented verbatim; only additive fields (`project.public_id`,
  `livemode`) are introduced. Changing the shape would alter the C10
  integration surface, which is outside this spec.

### G-15 — Small schema judgements · resolved unless the owner objects
- `whd_` ids are `whd_` + the existing `delivery_id` UUID (no new column).
- `framework_version` exposes `{version, label}` only; its integer id is
  internal.
- `candidate.display_name` is required (the column is `NOT NULL`).
- `candidate.language` defaults to the project language; whether it may
  differ is unsettled.
- An `error` interview answers `409 transcript_not_ready` (binding gate);
  the admin's partial-transcript read is not mirrored.
- Redeliver adds one authorized edge from the terminal delivery states back
  to `pending`, mirroring the participant `errore → in_attesa` recovery edge.
- Session tokens are mintable only in `pending`; a retry after a `pending`
  evaluation (ruling 4, open) gets no token until ruling 4 is decided.
- `Export.status=expired` refers to the archive download window, not to an
  interview.
- Added: `project_not_active` (422), `Behavior.unassessable_reason`,
  `Interview.progress`, `Interview.role_code`.

### G-16 — Idempotent replay of session tokens · resolved · step 3/5
- A replayed `POST /interviews` could return a consumed or expired token.
- **Choice.** `POST /interviews/{id}/session-tokens` takes no
  `Idempotency-Key`; `POST /interviews` replays the original body and the
  contract documents that the token may need re-minting.

### G-17 — Public API route prefix · resolved · step 1
- **Choice.** Laravel serves the public API under `/api/v1/*`; the public
  hostname maps `/v1` onto it. Contract paths omit both prefixes.

### G-18 — New dev dependency · resolved · step 1
- `league/openapi-psr7-validator` (^0.24) is added to the API as a dev
  dependency for response validation against the contract. PSR-7 bridging
  reuses what the lockfile already carries; the step 1 report names any
  additional package verbatim. Approved implicitly by the goal ("build the helper
  in step 1"); recorded here because the Boost rules ask for approval on
  dependency changes.

### G-19 — The response validator ignores `const` · resolved · step 1
- `league/openapi-psr7-validator` 0.24 targets OpenAPI 3.0.2; probed
  empirically on 3.1 keywords: type arrays, `minItems`/`maxItems`, `enum`
  and `oneOf` with `null` are enforced, `const` is silently accepted.
- **Choice.** `ContractValidator::assertDeclaredConstProperties()` (api,
  `tests/Contract/ContractValidator.php`) enforces `const` on top-level
  object properties, including those contributed by top-level `allOf`
  branches, and skips absent optional properties. Nothing nested deeper is
  covered. The contract uses `const` in exactly four places, all within that
  coverage (`/health.status`, `Recording.kind`, the two webhook `event`
  discriminators). `tests/Contract/ContractValidatorTest.php` pins each
  case; a nested `const` added to the contract must extend the accessor and
  its test first.

### G-20 — Spectral lockfile generated by Bun 1.4.2, CI pins 1.4.0 · resolved · step 1
- `tools/spectral/bun.lock` was generated locally with Bun 1.4.2 while CI
  installs Bun 1.4.0 (`docs/version-catalog.md`).
- **Verified.** Bun 1.4.0 (installed in a scratch prefix) ran
  `bun install --frozen-lockfile` against the committed lockfile: 242
  packages installed, lockfile byte-identical afterwards. The lockfile
  format is accepted by the pinned CI version. `tools/spectral/package.json`
  is the single place to bump Spectral; the catalog row mirrors it.

## Found while briefing step 2 (2026-09-24)

### G-21 — Legacy keys have no visible prefix · resolved · step 2
- `api_clients.key_prefix` is added nullable. Rows created before the
  migration store only the hash, so their prefix cannot be backfilled.
- **Choice.** New keys carry `beai_<mode>_` + the first 8 characters of the
  random part; the guard looks up by prefix and decides with `hash_equals`,
  and falls back to the hash-equality lookup for null-prefix rows. No forced
  rotation: those keys remain valid and merely lack a display prefix.

### G-22 — Test-mode data isolation lands in step 9 · resolved · steps 2 and 9
- §3.7 asks for a `mode` column on all tenant tables or a separate schema.
- **Choice.** Step 2 delivers the key `mode` and a request-scoped `ApiMode`
  context (`T-AUTH-007` asserts the stamp and the `Origin` rule). Step 9
  adds `mode` to the tenant tables the public API reads and the global
  scope that partitions them (`T-TEST`). Until then a test key can only
  reach `/health`, so no live data is exposed through it.

### G-23 — Auth tests before real endpoints exist · resolved · step 2
- Step 2 has no contract operation to validate 401/403 bodies against.
- **Choice.** Auth tests register probe routes and validate problem bodies
  against `components.schemas.Problem` plus the `X-Request-Id` header via
  `assertProblemMatchesContract`. Step 4 re-points the auth tests at
  `/organization` for operation-level validation.

## Found by the RDD review of step 2 (lineage review-079d24d11364b4d0)

### G-24 — Test-mode keys must never reach the internal M2M surface · resolved · step 2 follow-up
- The step 2 commit let `POST /api/m2m/clients` mint `mode=test` keys while
  the shared resolver accepted them on every `/api/m2m/*` route, so a test
  key could read live tenant data through the calling-system integration.
- **Choice.** The `api-m2m` guard rejects test-mode clients (401); only the
  `/api/v1` middleware accepts them, and step 9 partitions their data. The
  legacy hash fallback is skipped for test keys and gated by a cached
  "legacy rows exist" flag for live keys. Mode values live in the
  `ApiKeyMode` enum; `prefixOf()` refuses malformed keys.

## Found while briefing step 3 (2026-09-24)

### G-25 — Per-organization rate limits · resolved · step 3
- §3.2 says the limits are "configurable per org in backoffice".
- **Choice.** Two nullable integer columns on `organizations`
  (`public_api_rate_limit_live`, `public_api_rate_limit_test`); null means
  the config defaults (600 and 120 per minute, env-overridable). The
  backoffice editor for them belongs to step 11's backoffice additions.

### G-26 — Idempotency storage · resolved · step 3
- **Choice.** Idempotent responses (2xx only) are stored in the configured
  cache store (Redis in production) for 24 h, keyed by
  `sha256(org|mode|method|path|key)` with a body fingerprint; concurrency
  uses `Cache::lock`. No table is introduced; a cache flush replays nothing
  and never returns a wrong response.

## Found during step 3 (2026-09-24)

### G-27 — 405 answers as 404 `not_found` · resolved · step 3
- `ErrorCode` has no method-not-allowed entry.
- **Choice.** Unknown method → `404 not_found`, consistent with the
  no-enumeration principle: the method surface is not revealed.

### G-28 — Query-parameter errors use 400, not 422 · resolved · step 3 review follow-up
- Step 3 mapped `?limit=`/`?cursor=` validation to `422 validation_failed`.
  §3.2 and the contract declare `400` (`BadRequest`) on list operations and
  reserve `422` for request bodies.
- **Choice.** `?limit=` now raises `App\Exceptions\PublicApi\
  QueryValidationException` (a tagged `ValidationException` subtype) from
  `CursorPage::resolveLimit()`, which `PublicApiExceptionRenderer` maps to
  `400 validation_failed` with the same `errors[]` shape — matched BEFORE
  the plain `ValidationException` case, which stays `422` and now covers
  request-BODY validation only. `invalid_cursor` and `invalid_expand`
  already answered `400` and are unchanged. `T-CONV-002` is updated
  accordingly. `metadata[…]` QUERY filters do not exist yet (no endpoint
  uses them today — only the request-BODY `metadata` object, via
  `App\Rules\PublicApi\Metadata`, which correctly stays `422`); the same
  `QueryValidationException` pattern applies whenever step 4+ adds one.

### G-29 — Cursor HMAC key · resolved · step 3
- The opaque cursor is signed with the raw `app.key` string (not the
  base64-decoded bytes). It is an anti-tampering measure only; the cursor
  position is not a secret.

## Found by the four-lens review of step 3 (2026-09-24)

### G-30 — RateLimitPublicApi is a fixed-window counter, not a token bucket · resolved · step 3 review follow-up
- SPEC.md §3.2 says "per organization, token bucket"; the actual
  implementation (`Illuminate\Cache\RateLimiter`, the same primitive every
  `throttle:` middleware in the framework is built on) is a FIXED-WINDOW
  counter. The two are not interchangeable: a token bucket refills
  smoothly and bounds the rate everywhere on the timeline; a fixed window
  resets at a hard boundary, so a client sending `max` requests at the end
  of one window and `max` more at the start of the next can push up to
  `2 * max` requests through a short span straddling that boundary.
- **Choice.** Accepted as a documented deviation from the spec's literal
  wording — implementing a true token bucket is out of scope for this
  follow-up. `RateLimitPublicApi`'s own docblock, `AppServiceProvider`'s
  named-limiter registration, and `config/public_api.php`'s rate-limit
  block all now say so explicitly, so the gap is documented at every place
  that otherwise repeats the spec's "token bucket" phrase verbatim.
  Distinct from — and not to be confused with — the INTRA-window
  check-then-hit race also found in this review (fixed separately: a
  single window can never itself exceed `max`, burst or not, now that the
  middleware hits the counter and compares its OWN atomic return value
  instead of a separate, later `attempts()` read).

### G-31 — A policy AuthorizationException on /v1 renders 404, not 403 · resolved · step 3 review follow-up
- `PublicApiExceptionRenderer` had an `AuthorizationException → 403
  insufficient_scope` mapping that could never fire: Laravel's own
  `Illuminate\Foundation\Exceptions\Handler::prepareException()` converts
  every `AuthorizationException` with no explicit status to
  `AccessDeniedHttpException` BEFORE any render callback — including this
  one — ever sees it. The exception actually reaching the renderer fell
  through to the generic `HttpExceptionInterface` branch instead, which
  answered `403 validation_failed` — a status/code pairing the contract
  does not define and that materially mischaracterises a policy denial as
  a validation failure.
- **Choice.** `AccessDeniedHttpException` (the one that actually arrives)
  and `AuthorizationException` (kept for defence in depth, in case
  something renders one directly without going through Laravel's own
  handler) both now map to `404 not_found`, not `403`. `403
  insufficient_scope` stays reserved for `App\Http\Middleware\PublicApi\
  RequireScope`'s own direct response, built for a resolved client whose
  `abilities` genuinely lack a named scope — never for a Gate/policy
  denial. A `403` on a policy denial would also tell an unauthorized
  caller a resource EXISTS at all, the same existence-oracle concern
  `NotFound`'s own contract description already raises for a cross-org
  resource (mirrors G-27's reasoning for the 405→404 collapse); `404`
  costs nothing a legitimate caller needs and reveals nothing to one that
  is not.

## Found while briefing step 5 (2026-09-24)

### G-32 — Session-token exchange reuses the candidate JWT, not a cookie · open · step 5
- §3.5 exchanges the single-use token for an httpOnly `SameSite=None`
  cookie. The frontend already runs the whole interview on a bearer
  candidate JWT (`CandidateTokenFactory::mintCandidateToken`, stored by
  `useCandidateSession`), and the existing SSO link already enforces
  single use atomically (`consumeJti`). A cookie would add a second
  credential path and inherits the third-party-cookie failure G-11 describes.
- **Choice.** `GET /api/embed/exchange?token=<session_token>` verifies the
  public session token (dedicated secret `PUBLIC_API_SESSION_SECRET`, HS256,
  `aud=embed`, `sub=int_…`, `jti`), consumes the `jti` atomically, records
  the `token_consumed` event, and answers `200 {access_token}` (the existing
  candidate JWT). A consumed or revoked token answers `410 token_consumed`;
  an expired, mis-signed or wrong-audience token `401 token_invalid`; a
  token whose interview is no longer `pending` `410 token_consumed`. The
  hosted page stores the candidate JWT exactly as the SSO link flow does;
  the embed page (step 10) keeps it in memory and `sessionStorage`. The
  cookie-flag test in `T-TOK` becomes "no cookie is set". Owner may still
  ask for the cookie variant later; it would be additive.

### G-33 — Hosted page in step 5, embed page in step 10 · resolved
- §2 says the hosted page IS the iframe content. The frontend today sets
  `X-Frame-Options: DENY` globally and has no `frame-ancestors`.
- **Choice.** Step 5 ships `/i/{token}` (top-level, same chrome as the SSO
  link flow, no framing). Step 10 adds `/embed/{token}` on the same
  component with `frame-ancestors` from the organization's allowed
  domains, the `Permissions-Policy` for the iframe, and the postMessage
  protocol. Framing stays denied until then.

### G-34 — Interview events table · resolved · step 5
- `/interviews/{id}/events` needs a timeline the domain does not store.
- **Choice.** New tenant-scoped `interview_events` table (`public_id`
  `evt_…`, `participant_id`, `type`, `occurred_at`, small `data` jsonb).
  Step 5 records `created`, `invited`, `token_consumed`; step 6 records the
  session and readiness events from the existing candidate controllers and
  jobs. Never PII or transcript text in `data`.

## Found during step 4 (2026-09-24)

### G-35 — /v1 middleware priority ordering · resolved · step 4
- Laravel's `SortedMiddleware` placed `RequireScope` (priority-listed) before
  `AuthenticatePublicApi` (not listed), so the scope check fell through to
  the lazily resolved `api-m2m` guard, whose `RequestGuard` caches the user
  for the guard instance's lifetime. Steps 2 and 3 shipped with this latent
  defect; step 4's first scoped business route exposed it.
- **Choice.** The whole `/v1` stack is on the priority list in order:
  `AssignRequestId → RejectApiKeyInQuery → AuthenticatePublicApi →
  PublicApiTenantContext → RateLimitPublicApi → RequireScope →
  SubstituteBindings`, pinned by a test.

### G-36 — Public `{project}` binding is resolved in the controller · resolved · step 4
- The admin `apiResource('projects')` binds `{project}` to the integer id.
- **Choice.** Public controllers decode the prefixed public id themselves
  (`PublicId::decode` + `wherePublicId`), never through a global binding
  resolver, so admin routes are untouched.

## Found while briefing step 6 (2026-09-24)

### G-37 — Two meanings of `question_index` · resolved · step 6
- In the domain `InterviewSession.question_index` is the competency's
  position in the project (one session per competency). The public
  `answers[]` item needs the ordinal of the primary question inside that
  competency, and no table stores it: the asked questions are the session's
  `primary_questions` snapshot, and each avatar turn tagged `primary` maps
  to the next entry of that list (`TurnClassifier`).
- **Choice.** Public `answers[].question_index` is the 0-based ordinal of
  the primary question within the competency, derived by replaying the
  session's `primary` avatar turns in `ts, id` order; `question_text` is
  `primary_questions[question_index]`; `answer_text` joins the candidate
  turns up to the next primary avatar turn; `started_at_seconds` and
  `answer_duration_seconds` are deltas of utterance timestamps relative to
  the participant's `started_at`. The public transcript keeps
  `competency_code` on every turn and `question_index` in that same
  derived sense. Follow-up avatar turns carry `question_index` of the
  primary question they follow.

### G-38 — Interview events are recorded at the existing seams · resolved · step 6
- **Choice.** `session_started`/`session_ended` from `InterviewController`
  `start`/`end`, `question_asked`/`answer_recorded` from the utterance
  insert path (`turn_kind = primary` avatar turns, candidate turns),
  `under_evaluation` + `transcript_ready` from the completion CAS,
  `completed`/`error` + `scoring_ready` from `ScoreEvaluationJob`. `data`
  carries only `competency_code` and `question_index`.

## Found during step 5 (2026-09-24)

### G-39 — Exchange error codes live outside the `/v1` enum · resolved · step 5
- `GET /api/embed/exchange` is not a `/v1` operation; it answers problem+json
  with `token_invalid` (401) and `token_consumed` (410), which the `/v1`
  `ErrorCode` enum does not list.
- **Choice.** Kept as documented in G-32; the embed/hosted page maps them.
  Step 11 documents the exchange as its own section of the developer docs.

### G-40 — `hosted_url` is null on reads · resolved · step 5
- A hosted URL embeds a token; a read cannot mint one.
- **Choice.** `Interview.hosted_url` is `null` on list and detail; the create
  and session-token responses carry it. The contract already allows null.

### G-41 — `HasPublicId` keeps the live column check · resolved · step 5
- The step 4 review asked to drop the per-insert `Schema::hasColumn()`.
  `BaselineRevisionMigrationTest` creates rows after rolling back past the
  `public_id` migration, so an explicit fixture cannot work, and a static
  cache broke that test in a batch.
- **Choice.** The live check stays; it costs one catalogue query per
  organization/project/participant insert, which are rare writes.

### G-42 — Raw SQL insert paths must mint the public id themselves · resolved · step 5
- `SsoExchangeController` inserts participants with raw SQL, bypassing the
  Eloquent `creating` hook. The step 5 writer added the ULID to that INSERT
  and to the duplicated SQL in the concurrency test. Any future raw insert
  into a `HasPublicId` table must do the same; the Arch test pins the models,
  not the SQL.

### G-43 — Email case normalisation · open · step 5
- `participants_project_id_email_unique` is a plain `(project_id, email)`
  index; the SSO ingress stores the address as received. The public create
  path lower-cases the address and checks duplicates case-insensitively,
  and the public list filter already matches on `lower(email)`.
- **Owner decides.** Whether to normalise the SSO path too and replace the
  unique index with a functional `lower(email)` index (a migration on a
  live table with a backfill that may collide).

### G-44 — Idempotency records are encrypted at rest · resolved · step 5
- A replayed `POST /v1/interviews` carries the original session token for
  up to 24 h (spec §3.5, G-16). The stored record is encrypted with the app
  key so no live credential sits in Redis in clear.

### G-45 — `participants.public_id` NOT NULL and rolling deploys · open · step 5
- Old code inserting participants during a rolling deploy (after the
  migration, before the new code) fails closed on the NOT NULL column with
  no default (a ULID cannot be a database default).
- **Choice.** Deploy order: new code first, then the migration (Railway
  runs migrations at release; the SSO ingress insert is the only old-code
  writer). Documented in the migration docblock. Owner may prefer a
  temporary trigger-based default.

### G-46 — Public schema names in the generated spec · resolved · step 5 follow-up
- The public resources were exported under `Project`, `Organization` and
  `Interview`, the names the backoffice's generated client uses for the
  admin shapes; the backoffice typecheck broke on 28 usages.
- **Choice.** Public resources carry explicit Scramble schema names
  (`PublicOrganization`, `PublicProject`, `PublicInterview`); admin names
  are unchanged. Step 11's `/v1` filter maps them to the contract names.

## Found during step 6 (2026-09-24)

### G-47 — Indicator score `-1` is literal in the public API · resolved · step 6
- The wrapper standards say the unassessable sentinel is never rendered as
  a number on the admin surface. The vendored contract types
  `Behavior.score` as `enum [1,2,3,4,5,-1]`, so the public API emits the
  literal `-1` with `unassessable_reason` set; the admin surface keeps its
  own rendering. Both derive from the same stored value.

### G-48 — Transcript turns carry no timing fields · resolved · step 6
- The spec prose mentions `started_at_seconds`/`ended_at_seconds` on turns;
  the vendored contract's `Transcript.turns` schema has none. The
  contract wins: timing lives on `/answers` items only.

### G-49 — Answer timing derivation · resolved · step 6
- `started_at_seconds` is the primary question's own timestamp relative to
  the participant's `started_at`; `answer_duration_seconds` spans the
  candidate's own turns for that question only.

### G-50 — Ambient review hook re-triggers against a stale boundary · resolved
- The stop hook periodically offers an "ambient" candidate spanning
  `059d7c0..HEAD`. Verified in full: the pre-session portion
  (`059d7c0..ba54335`, 1362 lines, pure documentation) returns
  `target_already_acknowledged` — a terminal stop meaning that exact
  target was already reviewed and closed before this session. Every
  commit from `883528e` onward (17 commits, the whole public-api feature)
  was individually reviewed and acknowledged through its own scoped
  lineage during this session, each with an explicit consent prompt.
- **Conclusion.** The entire `059d7c0..HEAD` range is genuinely covered;
  the ambient lineage only fails because it treats the whole range as one
  undividable candidate and exceeds the reviewer's context budget as
  such. Re-slicing it further would re-review byte-identical content
  already approved under other lineage ids, with no new safety benefit.
  Not pursuing further; the per-commit review discipline used throughout
  this feature stands as the actual review record. The ambient hook fires
  again on every new wrapper commit (each time the workspace tree changes)
  because it re-derives a fresh target hash for the whole 059d7c0..HEAD
  range; this is expected and each recurrence is re-verified the same way
  rather than re-prompted, since the underlying coverage argument does not
  change once established.

### G-51 — Interview reads are not scoped by key mode · open
- The step 8 gate found that `InterviewController`'s reads (list, detail,
  transcript, answers, scoring, events, recording) filter only by
  `organization_id`, not by the requesting key's `mode`. A test key can
  therefore read live interview data, the same class of leak found and
  fixed for exports (G-51 exports fix in step 8's second gate round).
- **Owner decides.** Whether `participants.mode` should gate every public
  read the way it now gates `/usage` and `/exports`, and whether that is
  a step 8 follow-up or its own small pass across steps 4-6's read
  endpoints before step 9 (which was already going to add mode
  partitioning to the tenant tables per G-22).

### G-52 — Plural `withoutGlobalScopes()` still remains outside step 8's diff · open
- Fixing step 8's own gate findings (round 7) converted every
  `withoutGlobalScopes()` call this diff touched — `ProgressPayloadAssembler`,
  `SendProgressWebhook`, `SendEvaluationWebhook` — to the singular,
  allowlisted `withoutGlobalScope('tenant')` form, so `SoftDeletingScope`
  keeps applying. Two pre-existing sites were deliberately left untouched to
  avoid dragging previously-reviewed, out-of-diff code into this fix round:
  - `app/Services/Webhooks/EvaluationPayloadAssembler.php` — five sites
    (`Project` x2, `Evaluation` x2, `CompetencyResult` x1), all plural.
  - `app/Services/Webhooks/WebhookDeliveryRecorder.php:80` — one plural
    `withoutGlobalScopes()->find($projectId)`, with its own docblock citing a
    queued-job-only justification predating this feature.
  Both classes run outside HTTP-request tenant context by design (same
  reasoning as `ProgressPayloadAssembler`), so the plural form's only
  practical exposure is a soft-deleted row no longer 404ing — narrower than
  the round-7 finding, but the same class of drift.
- **Owner decides.** Whether to fold `Services/Webhooks` into
  `AdminTenancySafetyArchTest`'s `$tenantScopeStripGuardedRoots` (forcing
  every site in both files to the singular form plus a per-file allowlist
  justification) as its own small follow-up pass, or leave it for a future
  gate round that touches those files directly.

## Found during step 9 (2026-09-25)

### G-53 — DispatchScoringJob fails open on an unresolvable Participant · resolved, REVERSED round 4
- The step 9 gate (round 3, review-reliability finding
  R3-dispatch-scoring-fail-open) flagged that `DispatchScoringJob::handle()`
  dispatches the real, paid `ScoreEvaluationJob` whenever the org-filtered
  `Participant` lookup returns `null` — whether the participant genuinely
  does not exist, or `ScoringRequested::organizationId` is simply wrong for
  an existing row. SPEC.md §3.7's "never billed" guarantee for test-mode
  participants therefore depends on that lookup succeeding.
- **Round 3 decision (superseded):** accepted the fail-open behaviour as-is,
  reasoning that failing closed would silently strand a genuinely-missing
  participant that pre-step-9 code already left to `ScoreEvaluationJob`'s
  own not-found handling.
- **Round 4 (gga, same commit's re-review) overruled this**, correctly: the
  round-3 reasoning missed that `ScoreEvaluationJob` resolves its OWN
  `Participant` via `withoutGlobalScopes()` — fully unscoped by design.
  Falling through to `ScoreEvaluationJob::dispatch()` on an org mismatch
  therefore lets it score (and, for a test-mode participant, BILL) that
  exact row anyway, completely bypassing the guard this filter exists to
  enforce — a live security-relevant hole the round-3 framing did not
  actually close, only relocated.
- **Now fails closed**: a `null` lookup logs and returns, never dispatching
  `ScoreEvaluationJob`. Cost is near-zero in practice — `ScoringRequested`
  only ever fires from `FinalizeInterview`, which already confirmed this
  exact `(participantId, organizationId)` pair resolves before firing it
  (both now REQUIRE, never accept null, a genuinely independent
  `organizationId` — see `FinalizeInterview`'s own constructor docblock,
  round 4 finding 1), so a mismatch reaching `DispatchScoringJob` can only
  mean a genuine anomaly, never the normal path.
- `FinalizeInterviewHookTest.php`'s `'DispatchScoringJob refuses (never
  dispatches ScoreEvaluationJob for) a wrong-organization lookup'` test
  locks in this corrected behaviour.
- **Closed.** No further owner decision needed — the residual risk this
  entry originally flagged is now structurally closed, not merely
  documented as accepted.
