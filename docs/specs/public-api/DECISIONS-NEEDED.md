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
