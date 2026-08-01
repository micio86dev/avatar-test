# Proposal: NFR Hardening (C13) — sliced by blocker class

## Intent

`ROADMAP.md:46` bundles six workstreams under one slice: audit logs, GDPR retention/purge,
full observability-stack enforcement, white-label, accessibility, multi-test portal. They do
**not** share a blocker. Two are pure greenfield work, one is a spec-conformance defect in
already-merged C9 code, one is hard-gated by a client legal decision, and two are specified by
a single bullet each. Shipping them as one change would let the two vaguest items block the
four that are ready, and would hide a cross-cutting infra dependency inside an NFR slice.

**This proposal restructures C13 into four slices by blocker class.** C13 proper = Slice 1 +
Slice 3's mechanism + Slice 4's questions. Slice 2 is recommended **out** of C13 as its own
prerequisite change.

| Slice | Content | Blocker class | Verdict |
|---|---|---|---|
| **1** | Audit logs · `ai_requests` spec conformance · accessibility gaps | None | **Build now — this is C13** |
| **2** | Queue worker + Laravel scheduler | None (infra debt) | **Extract to its own change — blocks C9/C10/C12/C13 alike** |
| **3** | GDPR purge | Mechanism free; **enforcement** gated by open decision #2 | Build the mechanism, gate the numbers |
| **4** | White-label · multi-test portal (FR-006) | Client (underspecified) | **Propose nothing — ship questions only** |

---

## Verified current state

Every line below was opened during this proposal. Nothing is inherited.

| Claim | Evidence |
|---|---|
| No audit-log package or model | `api/composer.json:9-31` — no `spatie/laravel-activitylog` / `owen-it/laravel-auditing`; no `AuditLog` among the 21 files in `api/app/Models/` |
| Audit logs are binding | `CLAUDE.md:164` + `docs/BEAI_BRIEF.md:142` (unqualified NFR). `docs/app_description/05-business-rules/03-requisiti-non-funzionali.md:56` says *"consigliato"* — CLAUDE.md wins per its own source-of-truth framing |
| No queue worker anywhere | `api/Dockerfile:75` CMD = `php artisan serve` only; `docker-compose.yml:40` mentions Horizon **in a comment**, no worker service; zero `queue:work\|queue:listen\|horizon\|supervisor` hits in `api/.github/workflows/`; `laravel/horizon` absent from `api/composer.json:9-17` |
| No scheduler registered | `api/bootstrap/app.php:16-65` — `withRouting`/`withMiddleware`/`withExceptions`/`create()`; no `->withSchedule()` |
| Sentry / Pulse / Clarity / GA4 absent | `api/composer.json:9-31`; `frontend/package.json:23-62`; `backoffice/package.json:22-58`; and **also absent from both `nuxt.config.ts`** (zero `clarity\|gtag\|analytics\|sentry` hits) — the exploration's "may be script-injected" caveat is now closed |
| a11y foundation exists | `@axe-core/playwright` at `frontend/package.json:43`, `backoffice/package.json:39`; `checkA11y()` at `frontend/tests/e2e/fixtures/a11y.ts:10-24` enforcing `wcag2a/wcag2aa/wcag21aa`; `DESIGN.md:496-546` §9 |
| a11y gap is narrow | `checkA11y` is called only from `health.spec.ts` + `unsupported-gate.spec.ts` in both apps. **`frontend/tests/e2e/interview-flow.spec.ts` and `browser-gate-middleware.spec.ts` have zero a11y assertions** — the candidate's core journey is uncovered. No lint-time a11y plugin in either `package.json` |
| Purge targets | `interview_snapshots.s3_key` (`…100005_create_interview_snapshots_table.php:39`; docblock `:14` "No TTL in C7a (deferred to C13/GDPR)"); `s3` disk (`api/config/filesystems.php:50-61`); `utterances` = DB rows; `evaluations`/`competency_results`/`indicator_scores` (verbatim `excerpts`); `ai_requests`; `participants.display_name`/`candidate_ref` (`…create_participants_table.php:41,44`; docblock `:22` "No deleted_at … GDPR concern deferred to C13") |
| **No per-question audio exists** | Zero audio column or disk path across the 28 files in `api/database/migrations/` and `api/config/` — "audio" in decision #2 is aspirational |
| C10 adds a **new** PII class | `webhook_deliveries.payload` jsonb, frozen at insert (`…2026_07_27_000001_create_webhook_deliveries_table.php:81`, docblock `:16`) |
| White-label spec = 2 bullets | `docs/BEAI_BRIEF.md:83` ("branding"), `:145` ("White-label branding"). Zero hits elsewhere in `docs/`. `projects` table has **no** branding column (`…create_projects_table.php`, zero `branding\|logo\|brand\|theme` hits) despite `ROADMAP.md:37` claiming C4 delivers it |
| FR-006 spec = 1 sentence | `docs/BEAI_BRIEF.md:112-113` — "Optional dashboard hosting multiple assessments." |

### The `ai_requests` defect — worse than reported

`openspec/specs/observability/spec.md:361-377` requires 12 fields. The delivered table
(`…2026_07_22_000004_create_ai_requests_table.php:31-68`) conforms on 5.

| Spec field | Delivered | Status |
|---|---|---|
| `provider` | — | **Missing** |
| `estimated_cost_usd` | — | **Missing** |
| `success` | — | **Missing** |
| `failure_reason` | `finish_reason` (`:58`) — LLM stop reason, not an error channel | **Missing** |
| `total_tokens` | — | Missing (derivable) |
| `prompt_tokens` / `completion_tokens` | `input_tokens` / `output_tokens` (`:54-55`) | Renamed |

Two consequences the exploration did not reach:

1. **`spec.md:344` is currently unsatisfiable.** It promises "total token usage and estimated
   cost per provider and model are computable from those records alone". Without `provider`
   and `estimated_cost_usd`, it is not. This is why C11 narrowed its dashboard — stated
   outright at `openspec/changes/admin-dashboards/design.md:177`: *"There is no cost column …
   C11 therefore ships token usage, not monetary cost."* C11 paid for C9's gap.
2. **Failed AI calls are never logged at all.** `spec.md:382-384` requires a record with
   `success = false` for a failed or timed-out call. There is exactly **one** `AiRequest::create()`
   in the codebase — `api/app/Jobs/ScoreEvaluationJob.php:656`, on the success path, *inside*
   the `DB::transaction` at `:651` that also writes `CompetencyResult`/`IndicatorScore`. So a
   provider error produces no row, **and** a rollback of scoring persistence silently discards
   the cost record of an AI call that was actually billed.

This is **C9 under-delivering against a promoted spec**, not an enhancement. C13 owns closing it.

---

## Scope

### In Scope (C13)

- **Audit log** — append-only, tenant-scoped record of admin/operator mutations: actor, action, subject, before/after, timestamp, org. Reuses the proven `ai_requests` append-only pattern (no `updated_at`, no `update()` in business logic). First consumer already designed: `DESIGN.md:580` — the "Request deletion" button "triggers a traceable server-side event".
- **`ai_requests` spec conformance** — additive migration (`provider`, `estimated_cost_usd`, `success`, `failure_reason`) + move logging **out** of the results transaction + log failures. Restores `spec.md:344` and unblocks C11's cost dashboard.
- **Accessibility — narrow gaps only** — wire `checkA11y()` into `interview-flow.spec.ts` and `browser-gate-middleware.spec.ts`; add a lint-time a11y layer (`eslint-plugin-vuejs-accessibility`) to both apps. **Nothing already delivered is re-proposed.**
- **GDPR purge mechanism (Slice 3)** — artisan command + retention-policy source, fully tested against fixture retention values, shipped **disabled by default**. Real durations injected on ratification of decision #2, with no code change.
- **Observability stack enforcement** — Sentry (`api`, `frontend`, `backoffice`), Laravel Pulse (admin-gated), Clarity + GA4 in both Nuxt apps, per `spec.md:171-298`.

### Out of Scope (explicit)

- **Queue worker + Laravel scheduler (Slice 2)** — see the ruling below. Belongs to its own change.
- **White-label and multi-test portal (Slice 4)** — questions only; no design, no schema, no estimate.
- **Billing / MRR / trial-conversion / subscription-growth metrics** (`spec.md:325-331`, `:346-351`) — no billing schema exists among the 28 migrations. C11 already deferred these (`admin-dashboards/proposal.md:95`); C13 **keeps** the narrowing and does not reopen it. A billing slice owns them.
- **Inbound webhooks / provider callbacks / rate limiting** — C10 forward-references these to C13 (`webhooks-integration/proposal.md:65`), but `ROADMAP.md:46` does not name them and they are a new *integration* capability, not NFR hardening. **Declined** — route to a C10 follow-on.
- **Cloudflare** (`spec.md:266-298`) — DNS/infra configuration, not a codebase artifact; verified at deploy, not by this change.
- **Enforcing real retention durations** — gated by open product decision #2.

## Capabilities

### New Capabilities
- `audit-log`: append-only, tenant-scoped admin action trail; immutability and read access.
- `data-retention`: GDPR purge mechanism, artifact-class inventory, policy resolution, deletion auditability.
- `accessibility`: WCAG 2.1 AA enforcement points (E2E coverage obligation + lint gate), formalizing the D29 mandate that today lives only in `DESIGN.md`.

### Modified Capabilities
- `observability`: (a) `ai_requests` field set corrected to match `spec.md:361-377`, with the `input_tokens`/`output_tokens` naming reconciled; (b) failure-path logging made mandatory and transaction-independent; (c) Sentry/Pulse/Clarity/GA4 marked delivered; (d) the C11 business-metric narrowing made permanent pending a billing slice.

---

## Approach

**D1 — Slice 2 is extracted, not absorbed.** A retention sweep is inherently time-triggered, so
Slice 3 hard-depends on a scheduler. But the same missing infra already blocks C9 (no worker
consumes `ScoreEvaluationJob` — `archive/2026-07-27-queued-job-tenancy/proposal.md:36`), C10
(`webhooks-integration/proposal.md:154-161` defers Horizon as "pre-existing debt … to be closed
by its own infra change"), and C12 (queued reminders). Burying a four-slice dependency inside an
NFR change makes it invisible to the three slices that already need it and were told it was
someone else's job. **Recommendation: a separate change (e.g. `queue-scheduler-infra`) landing
before C13's purge work** — worker service in `docker-compose.yml` + `api/Dockerfile`,
`->withSchedule()` in `api/bootstrap/app.php`, Horizon per `config.yaml:14`. Note
`…create_webhook_deliveries_table.php:107` already indexes for "a future sweeper" — the
consumer is anticipated on both sides.

**D2 — `ai_requests`: additive migration, amend the spec on token naming.** Add the four missing
columns; do **not** rename `input_tokens`/`output_tokens`. Renaming would break C11's in-flight
query (`admin-dashboards/design.md:175`) for zero semantic gain, and input/output is the
provider-native vocabulary. Amend `spec.md:368-370` to the delivered names and declare
`total_tokens` derived, not stored. Pricing resolves from a versioned config map at write time
(`spec.md:372` — "as of log time"), snapshotted into the row; **no price table, no billing
schema** — that stays out of scope.

**D3 — Purge: policy table + scheduled sweep, disabled by default.** Preferred over per-row
`purge_at` columns: a policy change post-ratification is picked up on the next sweep instead of
requiring a backfill `UPDATE` across six tables, and it needs no migration on every artifact
table. Every deletion writes an `audit-log` entry first — which is why **audit logs sequence
before the purge**, though `ROADMAP.md:46` lists them as siblings. Ships behind a config flag
with retention values `null`; a null policy purges nothing, so the mechanism is inert until
decision #2 lands.

**D4 — Slice 4 gets questions, not a design.** Two bullets and one sentence are not a
specification. Any design drafted from them would be invented, and expensive to unwind.

---

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/database/migrations/` | New | `audit_logs`, `retention_policies`; ALTER `ai_requests` (+4 columns) |
| `api/app/Jobs/ScoreEvaluationJob.php:651-665` | Modified | Move `AiRequest::create()` out of the results transaction; log failures with `success=false` |
| `api/app/Console/Commands/` | New | `beai:purge-expired` (idempotent, chunked, audited) |
| `api/bootstrap/app.php` | Modified | `->withSchedule()` — **only if Slice 2 lands inside C13** |
| `api/composer.json` | Modified | `sentry/sentry-laravel`, `laravel/pulse` (D37 policy applies) |
| `frontend/`, `backoffice/` `nuxt.config.ts` + `package.json` | Modified | Sentry, Clarity, GA4; `eslint-plugin-vuejs-accessibility` |
| `frontend/tests/e2e/interview-flow.spec.ts`, `browser-gate-middleware.spec.ts` | Modified | Add `checkA11y()` |
| `openspec/specs/observability/spec.md` | Modified | Delta per Capabilities above — **read post-C11** |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Purge built on a retention model the client later rejects | Med | Mechanism is policy-driven and inert by default; only the values change |
| Purge deletes more than intended | **Low/High impact** | Dry-run mode; audit entry written before deletion; per-artifact-class tests; disabled by default |
| Slice 2 stays unowned and Slice 3 cannot run | High | D1 makes it a named prerequisite change, not a footnote |
| Editing `observability/spec.md` collides with C11's in-flight edit to the same lines | **High** | C13 spec work starts only after C11 merges; C11's narrowing is preserved verbatim |
| C10/C11 shapes shift before C13 starts | Med | C13 depends on `webhook_deliveries.payload` existing, not on its columns |
| Sentry leaks candidate PII | Med | `spec.md:196-197` scrubbing (candidateRef, email, JWT) is an acceptance criterion, not a config note |
| Enabling a11y lint floods both apps with violations | Med | Land the plugin as `warn`, fix, then promote to `error` in a second PR |
| Diff exceeds the 400-line review budget | **High** | Chained PRs: (1) `ai_requests` conformance; (2) audit log; (3) accessibility; (4) observability SDKs; (5) purge mechanism. `sdd-tasks` produces the binding forecast |

## Rollback Plan

Additive only — no destructive migration, no data deletion at deploy. Rollback = `git revert`
per PR + `php artisan migrate:rollback` for the additive migrations + reset the wrapper
submodule pointers. `ai_requests` gains nullable columns, so reverting the job change leaves
existing rows valid. The purge command ships disabled; reverting it deletes nothing because it
deleted nothing. Observability SDKs are removed by dropping the package + env vars — no domain
code depends on them (`spec.md:493`).

## Dependencies

- **C10 `webhooks-integration`** (unmerged) — supplies `webhook_deliveries.payload` as a purge target.
- **C11 `admin-dashboards`** (unmerged) — supplies the post-narrowing `observability/spec.md`, plus the backoffice RBAC shell that the audit-log viewer and GDPR deletion UI (`DESIGN.md:449,580`) reuse.
- **Slice 2 `queue-scheduler-infra`** (proposed, does not exist) — **hard prerequisite for the purge sweep only.** Slice 1 needs nothing from it.
- **Open product decision #2** — blocks enforcement, not construction.
- New Composer/npm packages — D37 Dependency Resolution Policy applies: pin, or STOP and report.

## Success Criteria

- [ ] An `ai_requests` row is written for a **failed** LLM call, with `success=false` and `failure_reason` populated (`spec.md:392-397`).
- [ ] The AI-cost record survives a rollback of the scoring-results transaction.
- [ ] `SELECT provider, model, SUM(estimated_cost_usd)` satisfies `spec.md:344` from `ai_requests` alone.
- [ ] Every admin mutation produces exactly one immutable, org-scoped audit row; an arch test proves no `update()`/`delete()` targets `audit_logs`.
- [ ] Cross-tenant test: org A cannot read org B's audit rows or trigger a purge over org B's data.
- [ ] `checkA11y()` runs on every route in `interview-flow.spec.ts`; a11y lint gate is green in CI for both apps.
- [ ] Purge tests pass against fixture retention values and cover all six artifact classes; with retention unset, a purge run deletes zero rows.
- [ ] Every purge deletion has a preceding audit entry.
- [ ] Sentry reports from all three apps with release tag and PII scrubbed; Pulse returns 401 unauthenticated / 403 for non-admin (`spec.md:246-257`).
- [ ] 0 PHPStan L8 errors on new files; ≥85% coverage, ~95% on tenant-scoping and purge paths.

---

## Proposal question round

This executor cannot query the user directly. Assumptions are marked; correct any before spec.

### Product/legal — must reach the client

1. **Retention durations (decision #2).** Per artifact class: snapshots (S3), utterances, evaluations + verbatim `excerpts`, `ai_requests`, `webhook_deliveries.payload`, `participants` PII. *Implication:* one number per class turns the mechanism live with no code change.
2. **Decision #2's scope predates two artifacts.** Its text (`ROADMAP.md:51`) names only "audio/video/snapshots/transcripts". It does **not** cover `webhook_deliveries.payload` (C10, frozen evaluation data incl. `candidate_ref`) or `participants.display_name`. *Implication:* if ratification is not extended, the purge ships with a legally significant hole.
3. **Deletion semantics: hard delete or anonymize?** `participants` is the FK root of every other artifact and has no `deleted_at` (`…create_participants_table.php:22`). *Implication:* hard delete cascades away completed evaluations the client may need for aggregate reporting; anonymization preserves them but requires a redaction pass over verbatim `excerpts`.
4. **White-label — five answers needed before any design** (`docs/BEAI_BRIEF.md:83,145` is all that exists): (a) logo + colors only, or full removal of "BEAI" from candidate UI, emails, and the magic-link domain? (b) per-organization or per-project? (c) custom domain / CNAME — i.e. TLS automation? (d) email sender branding? (e) candidate frontend, backoffice, or both? *Implication:* (a)+(c) is the difference between two `projects` columns and a domain-provisioning subsystem.
5. **Multi-test portal (FR-006) — is it in scope at all?** `docs/BEAI_BRIEF.md:112-113` marks it **Optional** and it has no data model, UX reference, or acceptance criteria anywhere. If yes: (a) candidate-facing hub or admin-facing? (b) does it span existing `Project` rows or introduce a new aggregate above `Project`? *Implication:* (b) is a schema-level decision touching every tenant-scoped query. **Recommendation: defer explicitly and remove it from C13.**
6. **Audit-log strength.** `CLAUDE.md:164`/`BEAI_BRIEF.md:142` state it flatly; `03-requisiti-non-funzionali.md:56` says *"consigliato"*. Assumed **binding**. *Implication:* if merely recommended, retention and immutability guarantees relax considerably.

### Structural — for the orchestrator

7. **Slice 2 extraction (D1).** Assumed a separate `queue-scheduler-infra` change lands first. Confirm, or C13 absorbs worker + scheduler and grows accordingly.
8. **Token-column naming (D2).** Assumed the spec is amended to `input_tokens`/`output_tokens` rather than renaming the columns and breaking C11's query. Confirm.
9. **Inbound webhooks / rate limiting.** Assumed **declined** — C10 forward-referenced it (`webhooks-integration/proposal.md:65`) but `ROADMAP.md:46` does not, and it is an integration capability. Confirm, or C13 absorbs it.
10. **Sequencing.** Assumed Slice 1 may start before C10/C11 merge (it depends on neither), while spec edits to `observability` wait for C11 to avoid a same-lines collision. Confirm.
