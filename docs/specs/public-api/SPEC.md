# SPEC — BEAI Public API, Embed SDK & Developer Area

**Status:** Draft v1 · **Owner:** Alessandro Micelli · **Method:** SDD + TDD
**Contract:** `openapi.yaml` (design reference for all request/response shapes; see "Contract governance" in §0)

---

## 0. Decisions already taken (do not re-open)

| Decision | Value |
|---|---|
| API keys | **Backend-only.** Never accepted from browsers. No "publishable key" flow. |
| Configuration (projects, avatars, LLM, webhooks endpoints, key scopes) | **Backoffice only**, admin role, as today. The public API is **read-only** for configuration. |
| Data exposed | Everything an org admin can see in the backoffice, **except** API keys/secrets and **video recordings**, expressed in the binding domain model: projects, participant enrolments (`candidate_ref`, `email`, `display_name`, binding lifecycle), BARS scoring with its version triplet, the `progress`/`evaluation` webhooks. No candidate entity, no interview deadline, no overall score. |
| Media exposed | **Audio recording** (signed, expiring URL) and **transcripts**: yes. **Video**: no, backoffice only. |
| Browser surface | Only a short-lived, single-interview **session token** consumed by the embed SDK. |
| Testing | TDD. Every requirement below has a test ID (`T-xxx`). Write the failing test first. Target ≥ 85 % coverage on new code. |
| Versioning | Path prefix `/v1`. Breaking changes → `/v2`. Additive changes are not breaking. |
| Spec language | English (agent-facing). |
| Contract governance | `openapi.yaml` is the design reference the tests validate against. Step 11 exports the Scramble-generated spec filtered to `/v1`, and CI asserts the two are equivalent (`T-CONTRACT-001`). Neither may change without the other (G-00). |

---

## 1. Problem & goals

**Problem.** Clients (HR departments, ATS vendors, staffing agencies) want to run BEAI interviews from inside their own sites/apps and pull results back into their systems, without logging into the BEAI backoffice.

**Goals**
- G1 — A client backend can create an interview and hand the candidate a working interview in ≤ 3 API calls.
- G2 — A client can retrieve **100 % of its own data** (per decision table) via API, including a bulk export.
- G3 — Zero secret leakage to browsers: an audit of the embed page and SDK bundle shows no API key, no provider (Tavus/HeyGen) key.
- G4 — Docs good enough that an external dev reaches a completed test-mode interview in < 30 minutes without support.

**Non-goals (v1)**
- Project / avatar / LLM configuration via API (stays in backoffice).
- Native iOS/Android SDKs (WebView + embed SDK covers mobile; native only if a client funds it).
- Video recording access via API.
- GraphQL. REST + OpenAPI only.
- Per-user (member) API keys. Keys belong to the **organization** (existing system).

---

## 2. Architecture

```
Client backend ──(API key, HTTPS)──► BEAI Public API  /v1/*
       │                                    │
       │ session_token (JWT, 15 min)        │ webhooks (HMAC-signed) ──► client endpoint
       ▼                                    │
Client frontend ──@beai/embed──► <iframe src=BEAI /embed/{token}> ──► Tavus / HeyGen (keys stay server-side)
```

Three deliverables, three phases (ship in order, each independently releasable):

| Phase | Deliverable | Depends on |
|---|---|---|
| **P1** | Public REST API (`/v1`) + webhooks + **hosted interview URL** | existing org API-key system |
| **P2** | Embed SDK `@beai/embed` (iframe + postMessage) + session tokens | P1 |
| **P3** | Developer area: OpenAPI-generated docs, generated SDKs (TS/Node, PHP, Python), test mode UX, API logs in backoffice | P1, P2 |

The hosted page of P1 **is** the iframe content of P2 — do not build two pages.

---

## 3. Public API (`/v1`)

### 3.1 Authentication

- Header: `Authorization: Bearer <api_key>`.
- Key format: `beai_live_<32 random url-safe chars>` / `beai_test_<…>`. Prefix + first 8 chars stored in clear for identification; **full key stored only as SHA-256 hash**. Shown once at creation (existing backoffice flow — adapt if it currently stores plaintext).
- Key → `organization_id` + `mode` (`live`|`test`) + `scopes[]`. **Tenancy is derived from the key, never from the payload or query.**
- Scopes (set by admin in backoffice): `interviews:write`, `interviews:read`, `projects:read`, `recordings:read`, `exports:write`, `exports:read`, `usage:read`, `webhooks:read`, `webhooks:write`. Missing scope → `403 insufficient_scope`.
- Revoked/unknown key → `401 invalid_api_key`. Constant-time comparison. No enumeration hints.
- Keys are **rejected** when sent as a query parameter (`?api_key=`) → `400 api_key_in_query`. Also rejected if the request carries an `Origin` header matching a browser origin **and** the key is `live` → `401 browser_origin_forbidden` (defense in depth, not the primary control).

Tests: `T-AUTH-001..009` — valid key, revoked key, wrong prefix, key in query, missing scope, cross-org access returns 404 (not 403 — do not reveal existence), test key cannot read live data and vice versa, hash-only storage (DB never contains the plaintext), constant-time compare.

### 3.2 Conventions

- JSON only. `Content-Type: application/json; charset=utf-8`.
- IDs: prefixed ULIDs stored in a `public_id` column (G-05) — `org_…` organization, `prj_…` project, `int_…` interview, `exp_…` export, `evt_…` event. Webhook deliveries use `whd_` + the existing `delivery_id` UUID. Path parameters are validated by regex; mismatched prefix → `404`.
- Timestamps: ISO 8601 UTC with `Z`. Durations in **seconds**.
- Pagination: cursor-based. `?limit=` (default 25, max 100), `?cursor=`. Response envelope `{ "data": [...], "next_cursor": "…"|null, "has_more": bool }`. Stable ordering by `created_at desc, id desc`.
- Filtering on list endpoints: `status`, `project_id`, `created_after`, `created_before`, `metadata[key]=value` (exact match, max 3 metadata filters).
- Expansion: `?expand=project` on interview reads to inline the project.
- Errors: **RFC 9457 Problem Details**, `application/problem+json`:
  ```json
  { "type": "https://developers.beai.example/errors/insufficient_scope",
    "title": "Insufficient scope", "status": 403,
    "code": "insufficient_scope", "detail": "Requires interviews:read", "request_id": "req_…" }
  ```
  `code` is a stable machine string (documented enum in `openapi.yaml`). Validation errors add `errors: [{ "field": "candidate.email", "code": "invalid_email" }]`.
- Every response carries `X-Request-Id`. Clients may send their own; it is echoed and logged.
- Rate limiting: per organization, token bucket. Defaults `live` 600 req/min, `test` 120 req/min (configurable per org in backoffice). Headers `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`; on exceed → `429 rate_limited` + `Retry-After`.
- Idempotency: `POST` endpoints accept `Idempotency-Key` (≤ 255 chars). Same key + same org + same body within 24 h → replay original response (status + body + header `Idempotent-Replayed: true`). Same key + different body → `409 idempotency_key_reused`.
- Metadata: free-form `object<string, string>` on interviews, ≤ 20 keys, key ≤ 40 chars, value ≤ 500 chars. This is how clients store their own IDs — no mapping tables on their side.

Tests: `T-CONV-001..012` — pagination stability under inserts, limit bounds, invalid cursor → 400, problem+json shape on every error path, request-id echo, rate limit headers + 429, idempotent replay, idempotency conflict, metadata limits, expand limits.

### 3.3 Resources & endpoints

Full shapes in `openapi.yaml`. The public resources map onto the existing domain model; none introduces a
concept the binding documents (`docs/app_description/`, CLAUDE.md rulings) do not already define.

| Public resource | Backing model | Notes |
|---|---|---|
| `Organization` | `organizations` | The tenant owning the key. |
| `Project` | `projects` | An assessment campaign: role, assessment type, language, pinned framework version, competency set. |
| `Interview` | `participants` | A **participant enrolment** — one candidate in one project. There is no separate candidate entity (ruling 8). |
| `Scoring` | `evaluations` + `competency_results` + `indicator_scores` | The binding BARS output. |
| `WebhookDelivery` | `webhook_deliveries` | The existing C10 delivery log. |

| Method | Path | Scope | Notes |
|---|---|---|---|
| GET | `/v1/organization` | any | `id, name, mode` (of the key), `default_language?`, `allowed_domains`, `created_at`. |
| GET | `/v1/projects` | `projects:read` | Read-only. Filters `status`, `role_code`, `assessment_type`. Public-safe fields only (see 3.4). |
| GET | `/v1/projects/{id}` | `projects:read` | |
| POST | `/v1/interviews` | `interviews:write` | Enrol a candidate. Returns `interview`, `hosted_url`, `session_token`, `expires_at` (of the token). |
| GET | `/v1/interviews` | `interviews:read` | List + filters (`status`, `project_id`, `email`, `candidate_ref`, `created_*`, `metadata[…]`). `email`/`candidate_ref` replace a candidate lookup and match **this organization's** enrolments only. |
| GET | `/v1/interviews/{id}` | `interviews:read` | Status, timings, candidate fields, per-competency `progress`, readiness flags, metadata. |
| POST | `/v1/interviews/{id}/session-tokens` | `interviews:write` | Mint a **new** session token (previous one revoked). Only while status is `pending`, else `409 invalid_state`. |
| GET | `/v1/interviews/{id}/transcript` | `interviews:read` | Full turn-by-turn transcript. Gate: `under_evaluation` or `completed`, else `409 transcript_not_ready`. |
| GET | `/v1/interviews/{id}/answers` | `interviews:read` | Convenience grouping of the transcript per competency/question. No scores. Same gate as the transcript. |
| GET | `/v1/interviews/{id}/scoring` | `interviews:read` | BARS evaluation. Gate: `completed` only, else `409 scoring_not_ready`. |
| GET | `/v1/interviews/{id}/recording` | `recordings:read` | **Audio only.** Returns `{ url, expires_at, format, duration_seconds, size_bytes }`. URL is signed, TTL 10 min, single org. |
| GET | `/v1/interviews/{id}/events` | `interviews:read` | Timeline, **oldest first** (the one exception to §3.2 ordering, G-12). |
| GET | `/v1/usage` | `usage:read` | `?from&to` (default current month). The dashboard figures, see 3.4. |
| POST | `/v1/exports` | `exports:write` | Async. Body: `{ scope: "all"|"interviews", from?, to?, format: "jsonl"|"csv" }`. Returns `202` + export object. |
| GET | `/v1/exports` | `exports:read` | |
| GET | `/v1/exports/{id}` | `exports:read` | `status`, when `ready` → `download_url` (signed, 1 h), `download_expires_at`, `size_bytes`, `checksum_sha256`. |
| GET | `/v1/webhooks/deliveries` | `webhooks:read` | Read-only view of `webhook_deliveries` (endpoint config stays in backoffice). |
| POST | `/v1/webhooks/deliveries/{id}/redeliver` | `webhooks:write` | Re-send one delivery (see 3.6). |

There is no cancel endpoint: the binding lifecycle has no cancellation state, and the only way out of a
non-terminal state other than progression is `error`.

**Interview status — the binding candidate lifecycle, in English.** No public-only state exists.

| Public `status` | Stored value | Meaning |
|---|---|---|
| `pending` | `in_attesa` | Enrolled, interview not started. The only status in which a session token can be minted. |
| `in_progress` | `in_corso` | Interview active. |
| `under_evaluation` | `in_valutazione` | Interview closed, scoring job running. Transcript readable. |
| `completed` | `completato` | Evaluation finished (`scoring.status` is `completed` or `pending`). Scoring readable. |
| `error` | `errore` | Technical or unrecoverable failure. An admin recovery in the backoffice may return it to `pending`. |

Transitions are the model guard's (`Participant::$allowedTransitions`); the API observes them and never
drives them. There is **no interview-level expiry or deadline** (ruling 5): the only expiry in the API is the
session-token TTL (§3.5). Scheduling and reminders belong to the calling system.

Step 5 adds to `participants` the columns the public resource needs: `public_id` (`int_…`, G-05),
`metadata` (jsonb), `exit_redirect_url` (nullable override) and `mode` (`live`/`test`). The earlier plan of a
separate `interviews` table with its own state machine (G-06) is superseded.

**Create interview — request**
```json
{
  "project_id": "prj_01J…",
  "candidate": {
    "candidate_ref": "acme-672-mrossi",
    "email": "mario.rossi@example.com",
    "display_name": "Mario Rossi",
    "language": "it"
  },
  "metadata": { "ats_application_id": "A-4471" },
  "exit_redirect_url": "https://hr.acme.example/assessment/done"
}
```
- `candidate_ref` is the calling system's opaque identifier: stored verbatim and echoed unchanged in every
  response and webhook.
- `email` is mandatory (ruling 8). `display_name` is required (SSO ingress requires it; the column is
  `NOT NULL`). `language` defaults to the project's language.
- The project must be `active`, else `422 project_not_active`. `role_code` is inherited from the project.
- Uniqueness is per project: `(project, email)` and `(project, candidate_ref)`. A second enrolment answers
  `409 duplicate_enrolment`. The same email in another project or another organization is a separate
  enrolment; no endpoint reveals where else an address appears.
- `exit_redirect_url` is an optional per-enrolment override of the project's exit redirect. It must be
  `https` and its host must be in the organization's **allowed domains** (configured in backoffice, same list
  used for `frame-ancestors`), else `422 redirect_url_not_allowed`. When absent, the project's value applies.

**Scoring — response shape (binding BARS)**
```json
{
  "interview_id": "int_01J…",
  "status": "completed",
  "competencies": {
    "COL": {
      "score": 3.67,
      "reliability": 1.0,
      "behaviors": [
        { "indicator": "Work effectively with others", "score": 5,
          "explanation": "…", "excerpts": ["verbatim transcript substring"], "unassessable_reason": null }
      ],
      "unscorable_reason": null
    }
  },
  "framework_version": "…", "model_version": "…", "prompt_version": "…",
  "evaluated_at": "2026-09-24T15:45:00Z"
}
```
- One entry per assessed competency, in project order. Each carries **exactly 3** behaviours.
- Indicator `score` ∈ {1,2,3,4,5,-1}. `4`/`2` are residual levels; `-1` is unassessable and excluded from the
  competency mean.
- Competency `score` is the mean of the assessed indicator scores (`null` when none is assessable);
  `reliability` is `assessed / total` as a number in `[0, 1]`. No bands (ruling 1).
- `excerpts` are verbatim substrings of the transcript.
- No overall score, scale, dimension list or recommendation exists.
- `framework_version`, `model_version`, `prompt_version` and `evaluated_at` are **required** — they are the
  traceability triplet of the evaluation.

**Answers — response item.** `{ competency_code, question_index, question_text, answer_text,
started_at_seconds, answer_duration_seconds }`, derived from the transcript. No per-question score exists.

Tests: `T-INT-001..030` (create happy path; every 422 branch; `duplicate_enrolment` on email and on
`candidate_ref`; `project_not_active`; lifecycle mapping for all five statuses; session-token minting only in
`pending`; cross-org 404; `email` filter never returns another organization's rows; transcript/answers gate
`409 transcript_not_ready` below `under_evaluation`; scoring gate `409 scoring_not_ready` below `completed`;
scoring shape: exactly 3 behaviours, score enum, mean excludes `-1`, excerpts are transcript substrings, version
triplet present; recording never returns video; signed URL expiry and org binding; events ordering),
`T-PRJ-001..005` (no private fields leak — see 3.4), `T-USAGE-001..004`, `T-EXP-001..010` (async job,
status polling, download URL expiry, checksum, contains everything admin sees minus exclusions — snapshot test
against backoffice serializer), `T-WHD-001..005` (delivery list, filters, redeliver from each status).

### 3.4 Data exposure rules (the "everything the admin sees" contract)

Implement **one serializer per resource** shared by the public API and the export. Add a test that diffs the set of fields exposed in the backoffice API against the public serializer and asserts the difference equals **exactly** the exclusion list below. This turns "all the data" from a promise into a test.

Exclusion list (never in public API or export):
- API keys, key hashes, key prefixes, scopes of other keys
- Provider credentials (Tavus/HeyGen/LLM keys), provider names, provider persona/avatar internal IDs, provider session references
- Video recording URLs/paths, proctoring snapshots
- Per-provider cost breakdowns (only the total the dashboard shows is exposed)
- Internal user (member) passwords/2FA/sessions
- Internal numeric ids (public ids only, G-05)
- Webhook secrets and webhook endpoint configuration
- Soft-deleted rows

Always exposed where the admin sees them: `candidate_ref`, the candidate `email` and `display_name` on the
owning organization's own enrolments, and the scoring traceability triplet (`framework_version`,
`model_version`, `prompt_version`).

Projects specifically: expose `id, name, slug, role_code, assessment_type, language, status,
framework_version {version, label}, competencies[] {code, name, type}, pause_every_n_competencies,
nudge_min_chars, exit_redirect_url, avatar_display_name, created_at, updated_at`. `avatar_display_name` is
the avatar template name only. Hide provider, model, prompts, keys, `error_redirect_url`, webhook
configuration, `deadline_at`, `goes_live_at`, `pin_context`, `can`.

Usage specifically: the backoffice dashboard figures — `interviews {pending, in_progress, under_evaluation,
completed, error}`, `evaluations {completed, pending}`, `completion_rate`, `llm_tokens {input, output}`,
`cost_usd` (total only), `currency`. Latency percentiles and the per-provider cost split are not exposed.

Tests: `T-EXPOSE-001` (field-diff test, fails on any new backoffice field not classified), `T-EXPOSE-002` (grep-style assertion: no value matching `beai_live_|beai_test_|tavus|heygen` in any public response).

### 3.5 Session tokens (browser surface)

- JWT, `HS256` (or `EdDSA` if already used in the project), signed with a **dedicated** secret (not the app key). Claims: `iss=beai`, `sub=int_…`, `org=org_…`, `mode`, `jti`, `iat`, `exp = iat + 15 min`, `aud=embed`.
- **Single-use**: on first successful `/embed/{token}` load the `jti` is marked consumed and exchanged for an httpOnly, SameSite=None, Secure cookie bound to the interview (the WebRTC session then runs on the cookie). A second load with the same token → `410 token_consumed`. Minting a new token revokes previous unconsumed ones. Consuming a token records the `token_consumed` event and does **not** change the interview status: `in_progress` begins only when the first interview session starts. While the interview is still `pending`, the client backend may therefore mint a replacement token (recovery for a blocked cookie, see G-11). The cookie is `Partitioned` (CHIPS); when it is unreadable on the next request the embed page emits `error{code:"cookie_blocked", recoverable:true}` and consumes nothing further.
- **Session-token endpoints are not idempotent-replayable**: `POST /interviews/{id}/session-tokens` does not accept `Idempotency-Key` (a duplicate mint only revokes the previous token). `POST /interviews` does accept it, and a replayed `201` carries the ORIGINAL `session_token`, which may by then be expired or consumed; the client must mint a new one in that case. Documented on both operations.
- A session token grants **only**: load embed page for `sub`, start/end that interview's avatar session. It cannot call `/v1/*`. Tests must assert `/v1/*` rejects a session token with `401 invalid_api_key`.
- Hosted URL: `https://interview.beai.example/i/{token}` — same token, same rules. Hosted page shows BEAI branding unless org has white-label (existing backoffice setting).

Tests: `T-TOK-001..010` — expiry, single-use, revocation on re-mint, wrong `aud`, wrong signature, token for an interview no longer `pending` → `410`, token cannot hit `/v1`, cookie flags, org white-label flag applied.

### 3.6 Webhooks

The public API does **not** introduce a second webhook system. It reuses the C10 calling-system webhooks
verbatim — events, payloads, signing, retry — and adds a read/redeliver surface over their log.

- **Configuration** stays in the backoffice: per project (`webhook_url`, secret, enabled events) with the
  organization default as fallback. Secrets are encrypted at rest.
- **Events** — exactly the binding two, named as `App\Enums\WebhookEventType` names them:

  | `event` | When | Binding name |
  |---|---|---|
  | `progress` | On enrolment, and after every recorded answer | Candidate progress |
  | `evaluation` | When the asynchronous scoring job ends | Evaluation completed |

- **Envelope** (both events, existing `*PayloadAssembler` shape):
  `{ version, event, delivery_id, occurred_at, candidate_ref, project: { id, slug }, data }`.
  `candidate_ref` is the opaque identifier received at enrolment or SSO ingress, unchanged.
  Step 7 adds `project.public_id` (`prj_…`) and step 9 adds `livemode`; both are additive and keep
  `payload.version` at `1.0`.
- **`progress` data:** `competencies: [ { code, status, answers: [ { question_index, answered_at } ] } ]` —
  every project competency in project order, with empty `answers` before the first recorded answer.
- **`evaluation` data:** `{ status, text, files }`. `status` is `completed` or `pending`; `text` is the
  binding evaluation block keyed by competency code (`score`, `reliability` as the rendered percentage
  string, `behaviors[] { indicator, score, explanation, excerpts }`, reason keys only when set); `files` is
  `{ transcript: { type, ref, url }, evaluation_raw: { type, ref, url } }`, an open, extensible map.
  A `pending` evaluation is still sent with the data available. On a catastrophic scoring failure the event
  is sent with an empty `text` and a non-`completed`/`pending` status (see `openapi.yaml`).
- **Signature** (existing format, `WebhookSigner`): headers
  `X-BEAI-Signature: v1=<lowercase hex HMAC-SHA256(secret, "<ts>.<raw_body>")>`, `X-BEAI-Timestamp: <ts>`,
  `X-BEAI-Event: <event>`, `X-BEAI-Delivery-Id: <uuid>`. Receivers reject `|now - ts| > 300 s`. Docs ship
  verification snippets in Node/PHP/Python.
- **Delivery** (existing `config/webhooks.php`): POST, 10 s timeout, 5 s connect timeout, success = 2xx.
  **6 attempts**, retry delays `[10, 60, 300, 1800, 7200]` seconds (one per retry). Status values are
  `App\Enums\WebhookDeliveryStatus` verbatim: `pending`, then one of the terminal `delivered`,
  `failed_permanent`, `dead`; `skipped` is set at insert when there is nothing to deliver to.
- **Exactly-once emission** per trigger is arbitrated by the existing `(event_type, dedupe_key)` uniqueness.
  Ordering is not guaranteed; receivers deduplicate on `delivery_id`. Documented.
- **Delivery log** — `GET /v1/webhooks/deliveries` exposes `webhook_deliveries` rows. Id =
  `whd_` + the existing `delivery_id` UUID (the value receivers already see in `X-BEAI-Delivery-Id`), so no
  new column is added. Exposed: `event_type, status, interview_id, project_id, candidate_ref, target_url,
  attempt_count, max_attempts, payload_version, last_response_status, last_attempt_at, next_attempt_at,
  delivered_at, created_at`. Not exposed: `payload`, `dedupe_key`, `skip_reason`, `last_error`.
- **Redeliver** — `POST /v1/webhooks/deliveries/{id}/redeliver` re-sends the frozen payload bytes with the
  same `delivery_id` and a fresh timestamp/signature. Allowed from `delivered`, `failed_permanent`, `dead`;
  `pending` and `skipped` answer `409 invalid_state`. This adds one authorized re-open edge
  (terminal → `pending`, attempt counter reset) to the C10 delivery state machine, written only by the
  redeliver action — the same pattern as the participant `errore → in_attesa` recovery edge.

Tests: `T-WH-001..012` — signature correctness against reference vectors (existing `v1=` format), timestamp
tolerance, retry schedule `[10, 60, 300, 1800, 7200]` with a time-travel clock, only `progress`/`evaluation`
ever emitted, `candidate_ref` echoed unchanged in both, progress payload lists every project competency,
evaluation payload `text` matches the Scoring content, additive `project.public_id`/`livemode` do not change
`payload.version`, redeliver keeps `delivery_id` and the payload bytes, delivery log hides `payload` and
`last_error`, emitted exactly once per trigger.

### 3.7 Test mode

- `beai_test_…` keys operate on an isolated data partition (`mode` column on all tenant tables, or separate schema — pick what the current stack does for staging).
- Interviews created in test mode use a **mock avatar provider**: no Tavus/HeyGen call, scripted turns, and the enrolment walks the real lifecycle `pending → in_progress → under_evaluation → completed` in ≤ 30 s once the embed calls `start()`. It generates a realistic transcript, answers, a BARS scoring that satisfies the §3.3 shape (3 behaviours per competency, verbatim excerpts, version triplet), and a short audio fixture so every read endpoint returns real data.
- Webhooks (`progress`, `evaluation`) fire in test mode identically, with `"livemode": false` in the payload.
- Test-mode data is never counted in `/v1/usage` live numbers and never billed.

Tests: `T-TEST-001..006`.

---

## 4. Embed SDK — `@beai/embed`

### 4.1 Packaging
- TypeScript, zero runtime deps, **≤ 12 KB gz**. Builds: ESM (`import { BEAI } from "@beai/embed"`), UMD/IIFE for `<script src="https://cdn.beai.example/embed/v1.js">` exposing `window.BEAI`. Semver, `v1` CDN alias always points to latest 1.x.
- Framework wrappers `@beai/react` (hook + component) and `@beai/vue` are thin layers over the core — no logic duplication. Ship after core is stable.

### 4.2 API
```ts
const interview = BEAI.mount({
  container: HTMLElement | string,     // selector or element
  token: string,                       // session token from client backend
  locale?: string,                     // UI locale, defaults to interview locale
  theme?: { primaryColor?: string; borderRadius?: string; logoUrl?: string }, // only applied if org white-label allows
  onReady?, onStarted?, onQuestionChanged?, onCompleted?, onError?, onDestroyed?
});
interview.on("completed", (e) => …);   // same events as callbacks
interview.start();                     // optional: auto-start after consent screen is default
interview.end();                       // ends gracefully, triggers completed/failed
interview.destroy();                   // removes iframe, cleans listeners
```

### 4.3 Events (postMessage protocol)
All messages: `{ source: "beai-embed", version: 1, type, payload }`. Host → iframe: `start`, `end`, `set-theme`. Iframe → host: `ready`, `consent:granted`, `permissions:denied`, `started`, `question:changed { index, total }`, `completed { interviewId }`, `error { code, message, recoverable }`, `resize { height }`.
- SDK **validates `event.origin`** against the BEAI embed origin and ignores everything else.
- iframe **validates `event.origin`** against the org's allowed domains (from the token's org); mismatched → message ignored and `error {code:"origin_not_allowed"}` emitted once. Error codes emitted by the iframe: `origin_not_allowed`, `cookie_blocked`, `permissions_denied`, `provider_unavailable`, `network_lost`, `token_invalid`.
- No candidate PII, transcript, or scores cross postMessage. Only IDs and progress.

### 4.4 Iframe / embed page (`/embed/{token}`)
- Response headers: `Content-Security-Policy: frame-ancestors <org allowed domains>`; `Permissions-Policy: camera=(self), microphone=(self)`. Iframe attribute `allow="camera; microphone; autoplay"`.
- Consent screen (camera/mic + recording notice, GDPR text in the project language) **before** any provider connection. `start()` before consent is queued, not executed.
- Handles: permissions denied, provider connection failure (retry ×3 then `error{recoverable:false}`), tab hidden > 60 s (pause & warn), network drop (reconnect attempt, then fail with events persisted server-side).
- Reuses the hosted page component. Hosted mode differs only in chrome (branding header, full-page layout).

Tests: `T-SDK-001..020` — unit (TS, Vitest): mount/destroy idempotency, origin validation both directions, event ordering, queued start before ready, theme application gated by white-label flag; E2E (Playwright): full flow in test mode from `mount` to `completed` in ≤ 60 s, CSP header blocks iframe on a non-allowed host, bundle size budget test in CI.

---

## 5. Cross-cutting

### 5.1 Security checklist (each is a test or a CI gate)
- [ ] No plaintext keys in DB (`T-AUTH-008`)
- [ ] Tenancy via key only; every query scoped by `organization_id` at the repository/scope layer, not per-controller (add a test that creates two orgs and asserts every list endpoint returns 0 rows for the other)
- [ ] Signed media URLs bound to org + interview + expiry (`T-INT-0xx`)
- [ ] Session tokens: short TTL, single-use, dedicated secret, no `/v1` access
- [ ] CSP `frame-ancestors` + origin checks both sides
- [ ] Webhook secrets are the existing `projects.webhook_secret` / `organizations.default_webhook_secret` columns: Eloquent `encrypted` cast, `$hidden`, never returned by any endpoint. Test that a DB dump does not contain the plaintext secret.
- [ ] Audit log: every `/v1` call logged (org, key prefix, method, path, status, latency, request_id, IP) — visible in backoffice, retained 90 days. **Never** log bodies or `Authorization`.
- [ ] Dependency/SAST scan in CI; OpenAPI lint (Spectral) in CI.

### 5.2 Reliability
- Webhook deliveries reuse the existing C10 path: `WebhookDeliveryRecorder` inserts one `webhook_deliveries` row per `(organization_id, project_id, event_type, dedupe_key)` in the same transaction as the state change, and `DeliverWebhookJob` sends it. That unique key is the exactly-once guarantee; no separate outbox table is introduced. Exports and interview events (`/events`) are recorded through the same transactional pattern.
- Exports run as background jobs, streamed to object storage; max 1 concurrent export per org; `429 export_in_progress` otherwise.
- Health: `/v1/health` (unauthenticated, no data) for client monitors.

### 5.3 Observability
- Metrics per endpoint (p50/p95/p99, error rate), per org request counts, webhook success rate, export duration. Alerts: p95 > 500 ms on reads, webhook success < 95 %.

---

## 6. Developer area (P3)

- `developers.beai.example`: docs generated from `openapi.yaml` (Scalar or Mintlify — choose the one already free for the current hosting). Sections: Quickstart (backend create → hosted URL, then embed), Authentication & keys, Interviews lifecycle, Data & exports, Webhooks (with verification code), Embed SDK, Test mode, Errors reference (auto from `code` enum), Rate limits, Changelog, Versioning & deprecation policy (≥ 6 months notice, `Sunset` header).
- SDKs generated from `openapi.yaml` with Speakeasy or Stainless (or `openapi-generator` if cost matters more than polish): `@beai/sdk` (TS/Node), `beai/beai-php` (Composer), `beai` (PyPI). CI regenerates on spec change; hand-written code lives only in `@beai/embed`.
- Backoffice additions: API logs viewer, webhook deliveries viewer with redeliver, key scopes editor (if missing), allowed-domains editor, test-mode toggle/keys.
- Quickstart is itself a test: a CI job runs the quickstart snippets against a test-mode org and must reach `completed`.

---

## 7. TDD plan & definition of done

**Order of work (each step = red → green → refactor, PR per step):**
1. Contract: `openapi.yaml` finalized + Spectral lint + contract tests scaffold (responses validated against schema in every integration test).
2. Auth middleware + scopes + tenancy guard (`T-AUTH`, tenancy isolation test).
3. Conventions layer: problem+json, pagination, rate limit, idempotency, request-id (`T-CONV`).
4. Read endpoints: organization, projects (`T-PRJ`, `T-EXPOSE`).
5. Interview enrolment + binding lifecycle mapping + session tokens + hosted page; no cancel (`T-INT`, `T-TOK`).
6. Transcript / answers / scoring / audio recording / events (`T-INT` remainder).
7. Webhook delivery log + redeliver over the existing C10 webhooks (`T-WH`, `T-WHD`).
8. Exports (`T-EXP`), usage (`T-USAGE`).
9. Test mode + mock provider (`T-TEST`).
10. `@beai/embed` (`T-SDK`), then E2E.
11. Docs + generated SDKs + quickstart CI job + Scramble `/v1` export and contract-equivalence check (`T-CONTRACT-001`).

**Definition of done (per PR):** failing test written first and referenced by ID in the PR; all `T-*` for the step green; coverage ≥ 85 % on new files; Spectral clean; no new field in a public response without an entry in the exposure test; docs page updated in the same PR.

---

## 8. Decisions on the former open questions (codebase audit, 2026-09-24)

Each row replaces the original question. Evidence is `file:line` in the `api`
submodule at `v0.57.1` unless stated otherwise. Anything the audit found that the
spec does not cover is tracked in `DECISIONS-NEEDED.md`.

| # | Decision | Evidence |
|---|---|---|
| Q1 | **Keys are already hashed. No 1b migration, no forced rotation.** The existing org API-key system (`api_clients`) stores only the SHA-256 hex of the raw key in a `UNIQUE` `key_hash` column; the raw key is returned once in the `201` body as top-level `api_key`, hidden from the model (`$hidden`), excluded from the resource, redacted by name in both the audit recorder and the Sentry scrubber, and never logged. The guard hashes the bearer and does an indexed equality lookup on the digest; there is no `hash_equals`, and none is required because the comparison is over the digest, not the secret. **P1 reuses this table and guard.** Step 2 extends it additively: `key_prefix` (clear, `beai_live_`/`beai_test_` + first 8 chars, for identification only), `mode` (`live`/`test`), and `scopes` (the existing `abilities` jsonb is reused as the scope store; the public scope names are added to `config/m2m_abilities.php`). Entropy stays at the current 48 random bytes (384 bit), which exceeds the 32-char minimum in §3.1; the format line in §3.1 is read as a minimum. `T-AUTH-008` asserts the DB never contains a plaintext key; `T-AUTH-009` asserts the lookup is digest-based and the raw key is never compared. | Generator `app/Services/ApiKeyGenerator.php:23-43`; migration `database/migrations/2026_07_18_000001_create_api_clients_table.php:37`; guard `app/Providers/AppServiceProvider.php:226-275`; model `app/Models/ApiClient.php:56-72`; controller `app/Http/Controllers/M2m/ApiClientController.php:84-117`; resource `app/Http/Resources/ApiClientResource.php:52-73`; redactors `app/Support/Audit/AuditRedactor.php:34-35`, `app/Support/Observability/SentryScrubber.php:84,165-170`; backoffice one-time reveal `backoffice/app/components/organisms/ApiKeysPanel.vue:198-216,327,384`. |
| Q2 | **Object storage is the Laravel default disk and presigning is proven, but no audio recording exists today.** `FILESYSTEM_DISK` selects `local` (dev/CI, a shared `api_storage` volume) or `s3` (Railway, Cloudflare R2 through the generic `AWS_*` vars; `AWS_URL` must stay empty or presigned URLs break). TTL-bound URLs are produced with `Storage::disk()->temporaryUrl($key, $expiry)` at four call sites, always behind an org filter on the parent row plus a structural key-prefix guard. **Step 6 reuses exactly that pattern** for `/interviews/{id}/recording` (10-minute TTL, key prefix `recordings/{org}/{interview}/`). What does not exist: any table/column holding an audio object key, and any ingestion path (both providers return only a live `conversation_url`; the avatar-template `enable_recording` flag only toggles the provider's own recording). Step 6 therefore adds the storage and the signed endpoint; **until an ingestion path is specified, `recording_ready` is `false` and the endpoint answers `404 recording_not_ready`**. The step-9 mock provider writes a short audio fixture so the whole path is exercised in test mode. Tracked as gap G-01 in `DECISIONS-NEEDED.md`. | Disks `config/filesystems.php:16,50-61`; env `.env.example:203-224`; signers `app/Support/ProfilePhotoUrlSigner.php:43-64`, `app/Http/Controllers/Api/OrganizationLogoController.php:103-129`, `app/Http/Controllers/Api/SessionReviewController.php:140-147`; only media column `database/migrations/2026_07_20_100005_create_interview_snapshots_table.php:39`; explicit "no audio" `app/Http/Resources/Admin/ParticipantDetailResource.php:23-29`; no MinIO in `docker-compose.yml`. |
| Q3 | **Superseded (pre-commit gate, 2026-09-24): the `Candidate` resource is dropped and no `candidates` table is created.** Ruling 8 makes the email the identity key precisely so that no candidate row exists for a careless read to span; an org-scoped table would still add an entity the binding documents do not define. The public resource is the **participant enrolment** (`Interview`), carrying `candidate_ref` (the calling system's opaque id, echoed unchanged), the mandatory `email`, `display_name`, `language` and `metadata`. Uniqueness stays per project, `(project_id, email)` and `(project_id, candidate_ref)`, and a duplicate answers `409 duplicate_enrolment`. Candidate lookup is `GET /v1/interviews?email=` (or `?candidate_ref=`), scoped to the key's organization. G-02 is closed by this row. | `database/migrations/2026_07_20_000001_create_participants_table.php:29-68`; `database/migrations/2026_09_01_180000_add_email_to_participants.php:58-69`; `app/Models/Participant.php:79-107`; wrapper `CLAUDE.md` ruling 8. |
| Q4 | **No.** `/v1/organization` does not expose members. The backoffice user list carries names, emails, roles and deactivation state of BEAI operators, which is internal identity data with no integration use case in v1. Adding it later is additive. | `app/Http/Resources/UserResource.php:42-50`; §3.4 exclusion list. |
| Q5 | **Scalar, self-hosted**, generated from `openapi.yaml` in step 11 and served as static assets by the existing nginx stage of the `backoffice` image (or a sibling static service on Railway). Free, no vendor account, and the same artifact is reviewable in CI. Mintlify is not chosen. | Goal statement; `backoffice/Dockerfile` nginx stage; `docs/version-catalog.md`. |
| Q6 | **Unconfirmed; P1 ships host-agnostic.** Nothing in code depends on a hostname: the four surfaces are configured by `PUBLIC_API_URL`, `DEVELOPERS_URL`, `INTERVIEW_URL` and `EMBED_CDN_URL` (added in step 1 to `config/public_api.php`, defaulting to the existing `APP_URL`/frontend URL). Documentation and `openapi.yaml` keep the `beai.example` placeholders until the names `api.`, `developers.`, `interview.`, `cdn.` are confirmed by the owner. Tracked as G-03. | `openapi.yaml:11-13`; Railway topology in wrapper memory `railway-deploy-topology`. |

### 8.1 Backoffice serializer reference for §3.4 (audit, 2026-09-24)

`T-EXPOSE-001` diffs the public serializers against these admin resources. The
right-hand column is the exclusion set the test must assert, per resource.

| Public resource | Backoffice source | Admin fields | Must be excluded (why) |
|---|---|---|---|
| `Organization` | `app/Http/Resources/Admin/OrganizationResource.php:42-78` | `id, name, slug, primary_color, logo_url, default_webhook_url, default_webhook_events, has_default_webhook_secret, created_at, updated_at` | `default_webhook_*` (webhook config stays backoffice), `slug` (internal). Public adds `mode`, `allowed_domains` (new column, step 4). |
| `Project` | `ProjectResource.php:47-162` + `AvatarTemplateResource.php:63-79` | Project: `id, organization_id, framework_version_id, slug, name, assessment_type, role_code, language, status, pause_every_n_competencies, nudge_min_chars, exit_redirect_url, error_redirect_url, avatar_template_id, avatar_template{id,name,provider,llm_model}, webhook_url, webhook_events, has_webhook_secret, deadline_at, goes_live_at, pin_context, competencies[], can{}` | `avatar_template.provider`, `avatar_template.llm_model`, `webhook_*`, `framework_version_id` (replaced by `framework_version{version,label}`), `error_redirect_url`, `deadline_at`, `goes_live_at`, `pin_context`, `can`, `organization_id`, every AvatarTemplate field except `name` (exposed as `avatar_display_name`): `provider`, `config`, `persona`, `llm_model_id`, `llm_credential_id`, `llm_sync_status`, `llm{estimated_cost…}`, `heygen_llm_configuration_id`. |
| `Interview` | `Admin/ParticipantResource.php:55-74`, `Admin/ParticipantDetailResource.php:78-121`, `Admin/SessionSummaryResource.php:32-51`, `Admin/SessionReviewResource.php:62-114` | participant: `id, candidate_ref, display_name, email, role_code, language, status, project_id, project_name, started_at, completed_at, timeline, progress, elapsed, cost{}, files{transcript,evaluation_raw}`; session: `provider, provider_session_ref, integrity{}, snapshots[], cost{avatar{provider,minutes,usd},llm{…}}, evaluation{}` | `provider`, `provider_session_ref`, `snapshots` (proctoring images = video-class media), `cost.*` per provider, `integrity` (proctoring detail; not in v1 contract), `files.*.url` (replaced by `/transcript` and `/recording`). `status` is exposed through the English mapping of §3.3; `timeline` through `/events`. |
| `Transcript` | `Admin/TranscriptResource.php:47-50` | `is_partial, sessions[{session_id, competency_code, question_index, utterances[{speaker,text,ts}]}]` | `session_id` (internal). `is_partial` is dropped: the public gate (`under_evaluation`+) is stricter than the admin one, so a public transcript is never partial. Turns are flattened into `turns[]` carrying `competency_code` and `question_index`. |
| `Scoring` | `Admin/EvaluationResource.php:61-93` (+ `meta.scoring`, `meta.audit`) | per competency `{score, reliability, behaviors[{indicator,score,explanation,excerpts,unassessable_reason,audit{}}], unscorable_reason}`; `meta.scoring{prompt_version,model_version,framework_version}`; `meta.audit{…}` | `meta.audit.*`, `behaviors[].audit` (judge internals). `prompt_version`, `model_version`, `framework_version` are **exposed** (required traceability triplet, §3.3). `reliability` is exposed as the `[0,1]` fraction rather than the admin's rendered percentage string; an unassessable indicator is `-1`, not `null`. |
| `Usage` | `Admin/DashboardMetricsResource.php:62-65` | `participants_by_status, evaluations_by_status, completion_rate, ai_usage{input_tokens,output_tokens,latency_ms_p50,latency_ms_p95}, costs{scoring_usd,conversation_usd,total_usd,currency}` | `latency_ms_*`, per-provider split (`scoring_usd`, `conversation_usd`). Exposed as `interviews{…}` (English status keys), `evaluations{completed,pending}`, `completion_rate`, `llm_tokens{input,output}`, `cost_usd` (= `total_usd`), `currency`. |
| `WebhookDelivery` | **no admin resource or route exists** (`app/Models/WebhookDelivery.php`, table `webhook_deliveries`) | model: `delivery_id, event_type, dedupe_key, status, skip_reason, target_url, payload, payload_version, attempt_count, max_attempts, last_attempt_at, next_attempt_at, delivered_at, last_response_status, last_error` | `payload`, `dedupe_key`, `skip_reason`, `last_error` (may echo the receiver's body). Id is `whd_` + `delivery_id`. The existing `X-BEAI-Signature: v1=<hex>` + `X-BEAI-Timestamp` format is the only one; the public API adds none (G-04). |
