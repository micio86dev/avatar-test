# Tasks: NFR Hardening (C13)

> Strict TDD. Five independent areas; each ships as its own chained PR so a
> blocked one never holds the others.
>
> **Slice 2 (queue worker + scheduler) is already delivered** — extracted to its
> own change and archived 2026-07-31. **Slice 4 (white-label, FR-006) stays
> parked** per ratified decision #9.

## Delivery order and why

| # | Area | Why here |
|---|---|---|
| 1 | `ai_requests` conformance | A **confirmed defect that loses money**. Billed calls go unrecorded on the failure path, and recorded ones are rolled back with the results transaction. Everything else in C13 is additive; this one is losing data today. |
| 2 | Audit log | Binding NFR with no implementation at all. DESIGN.md:580 already promises a consumer. |
| 3 | Accessibility gaps | Narrow and cheap: two E2E wirings plus a lint layer. |
| 4 | GDPR purge mechanism | Buildable in full, ships **disabled**; only the durations are gated on decision #2. |
| 5 | Observability stack | Sentry / Pulse / Clarity / GA4. Largest surface, no defect behind it. |

---

## PR1 — `ai_requests` conformance

- [x] 1.1 RED: a provider call whose response fails JSON parsing still produces one `ai_requests` row with `success = false` and a `failure_reason`. Fails today — the parse-error path returns before any row is written.
- [x] 1.2 RED: the same for an indicator-count mismatch, an invalid indicator score, and a non-verbatim excerpt. Four distinct failure classes, four billed calls, currently four silent losses.
- [x] 1.3 RED: when the transaction persisting competency results rolls back, the `ai_requests` row **survives**. This is the sharpest test in the change: it fails today because the row is written inside that transaction.
- [x] 1.4 RED: `failure_reason` contains no fragment of the provider payload. An error string can echo prompt content, and this table feeds an org-scoped dashboard.
- [x] 1.5 RED: `provider`, `estimated_cost_usd`, `success` are non-null on every row.
- [x] 1.6 GREEN: additive migration — `provider`, `estimated_cost_usd`, `success`, `failure_reason`. No `updated_at`; the table stays append-only.
- [x] 1.7 GREEN: move `AiRequest::create()` **out** of the results `DB::transaction()` in `ScoreEvaluationJob`. A provider call is external, irreversible and billed; the results are local and revocable. Nesting the first inside the second means a later failure erases the record of money already spent.
- [x] 1.8 GREEN: write a row on every failure path that follows a completed provider call — parse error, indicator mismatch, invalid score, non-verbatim excerpt.
- [x] 1.9 GREEN: derive `estimated_cost_usd` at write time from a config-driven rate table. Stored rather than computed on read, so a later rate change cannot silently rewrite history.
- [x] 1.10 Arch test: no `AiRequest::...->update(` or `->save()` on an existing row anywhere in `app/`. A cost record that can be edited is not a cost record.
- [x] 1.11 Gates: `artisan test --parallel`, `pint --test`, `phpstan analyse`.
- [x] 1.12 Open PR1. **DONE** — micio86dev/backend#39, CI green, merged.

## PR2 — Audit log

- [x] 2.1 RED: an admin mutation writes one append-only `audit_logs` row carrying actor, action, subject type/id, before/after, timestamp and `organization_id`.
- [x] 2.2 RED: the row is tenant-scoped — org B never reads org A's trail.
- [x] 2.3 RED: an attempt to update or delete an audit row fails.
- [x] 2.4 RED: before/after payloads exclude secrets (`password`, `key_hash`, `webhook_secret`, tokens). An audit trail that captures credentials is a breach waiting to be read.
- [x] 2.5 GREEN: migration, `AuditLog extends TenantModel`, recorder service, arch guard mirroring the `ai_requests` append-only pattern.
- [x] 2.6 **REDIRECTED, with reason.** `DESIGN.md:595`'s "Request deletion" consumer needs an endpoint that does not exist — wiring an audit consumer to a button nobody built would be a test with no subject. It belongs to PR4 (GDPR purge), where the endpoint itself is in scope. The first consumer is instead M2M client creation and revocation: the most security-relevant admin mutation that exists today.
- [x] 2.7 Gates + PR2. **DONE** — micio86dev/backend#41, merged.

## PR3 — Accessibility gaps

- [x] 3.1 Wire `checkA11y()` into `frontend/tests/e2e/interview-flow.spec.ts` and `browser-gate-middleware.spec.ts` — today it runs only on `health` and `unsupported`, so the two most complex screens are unchecked.
- [x] 3.2 Same audit for `backoffice` E2E specs.
- [x] 3.3 Add `eslint-plugin-vuejs-accessibility` to both Nuxt apps and fix what it reports.
- [x] 3.4 RED first — and it PAID OFF: wiring axe into the interview flow immediately surfaced a real WCAG 2.4.2 (Page Titled, Level A) violation. The interview page, where a candidate spends the whole session, had NO document title at all. Fixed with a localized one.
- [x] 3.5 Gates + PR3. **DONE** — frontend#14, backoffice#6, merged.

## PR4 — GDPR purge mechanism (ships disabled)

- [x] 4.1 RED: the purge command deletes artifacts older than the configured retention and leaves newer ones untouched — driven by **fixture** durations, never the real ones.
- [x] 4.2 RED: it is a no-op when disabled, which is the default. A purge that runs before its durations are ratified deletes data nobody agreed to delete.
- [x] 4.3 RED: every deletion writes an audit row (depends on PR2).
- [x] 4.4 RED: the artifact inventory is complete — `interview_snapshots.s3_key`, the `s3` disk objects, transcripts, `webhook_deliveries.payload`, `participants.display_name`.
- [x] 4.5 GREEN: artisan command + retention-policy resolver + config, **disabled by default**.
- [x] 4.6 Gates + PR4. **DONE** — micio86dev/backend#42, merged.
- [ ] 4.7 **BLOCKED, and stays blocked**: real durations. Open decision #2 needs legal sign-off, and the sign-off must cover `webhook_deliveries.payload` and `participants.display_name`, which postdate the original framing. The mechanism is built so that ratification is a config change, not a code change.

## PR5 — Observability stack

- [x] 5.1 Sentry — **api DONE** (micio86dev/backend#43, merged). **Nuxt halves DONE too**: `@sentry/nuxt` in both apps, off by default (`enabled: dsn !== ''`), `sendDefaultPii: false`, and a scrubber whose denylist mirrors the api's `SentryScrubber` key-for-key. Nine leak-class tests per app, each proved non-vacuous by neutering the mechanism it covers and confirming exactly that test goes red. The frontend's standout risk is the entry-link token, which sits in the URL at `/interview/{token}` — a URL being the single most commonly leaked field in an error report — so it is stripped from `event.request.url` AND from fetch/XHR breadcrumb query strings; the backoffice equivalent is `entry_url` from `POST /entry-links`, which IS a bearer credential and is denylisted as a token rather than treated as a URL shape. Session Replay deliberately NOT enabled: `spec.md` makes Clarity the sole session recorder, and Replay would capture the exact interview screens Clarity is forbidden to touch. **Sentry is deliberately NOT gated on analytics consent** — crash reporting is not behavioural analytics, gating it would blind the team to failures on the interview path for every candidate who declines a marketing banner, and the privacy risk consent exists to manage is already removed by the scrubber regardless of consent.
  - Two inherited limits, named rather than implied: `SENTRY_RELEASE` tagging is left to the SDK's own release injection and is unverifiable until a deploy pipeline sets the env vars; and exception MESSAGES are not scrubbed — a literal `throw new Error(candidateAnswer)` would bypass the denylist. Both match the api half exactly; neither was introduced here.
- [x] 5.2 Laravel Pulse — **DONE** (micio86dev/backend#44). Gated on the `admin` role AND a platform-operator allowlist, empty by default. A considered DEVIATION from `spec.md:242`: `admin` is org-scoped, Pulse is cross-tenant, so the spec read literally shows every customer's data to every customer's admin.
- [x] 5.3 Clarity + GA4 — **DONE** (micio86dev/frontend#15, micio86dev/backoffice#7). Both tools default OFF twice over: unset ID and denied consent. **No consent UI exists yet, so nothing loads** — see 5.6.
- [x] 5.4 RED — **DONE for the api sink**, which is the one that sees confidential data: nine tests, each asserting a specific class of leak does not happen. `send_default_pii=false` proved insufficient on its own — it stops Sentry ATTACHING context but does nothing about what this app's own exceptions carry, and scoring exceptions carry prompt text. The whole point of this product is that a candidate's answers are confidential; an analytics tag that ships a `candidate_ref` breaks that in a way nobody will notice.
- [x] 5.5 Gates + PR5 — **DONE**. api 1320 tests / phpstan 0 / pint clean; frontend 449 tests; backoffice 230 tests; typecheck + eslint clean on both.
- [x] 5.6 Analytics consent UI — **DONE** (micio86dev/frontend#16, micio86dev/backoffice#8). ONE banner, the same component in both apps, standing down on every route where analytics never runs — so nobody is ever shown a cookie dialog stacked on the interview's own recording consent. The two consents stay separate deliberately: recording is a precondition of the service, analytics must be refusable at no cost, and bundling them is what makes a consent invalid. Replaces the dead C1 `ConsentBanner` scaffold, which was mounted nowhere. Earlier framing kept below for the record:

  > **OPEN, product**: an analytics consent UI. The mechanism reads `beai.consent.analytics` and defaults to denied, so analytics is built and inert — the same posture as the retention purge. Granting consent needs a banner nobody has specified, and conflating it with the interview-recording `ConsentBanner` would mean agreeing to be assessed also agreed to be tracked by Google.

## Documented, Not Scoped

- **Cloudflare** — DNS/infra configuration, not a codebase artifact. Verified at deploy.
- **Billing / MRR / trial-conversion metrics** — no billing schema exists among the migrations. C11 deferred these; C13 keeps the narrowing rather than reopening it. A billing slice owns them.
- **Inbound webhooks / provider callbacks / rate limiting** — C10 forward-referenced these to C13, but `ROADMAP.md` does not name them and they are a new *integration* capability, not NFR hardening. Declined; route to a C10 follow-on.
- **White-label and multi-test portal (FR-006)** — parked, ratified decision #9.
- **C1 leftovers** — Trivy container scanning, pinning GitHub Actions to full SHAs, Dependabot, `v0.1.0` release tags, `railway.json`. Real, deferred, and belonging to C1 rather than here. Named so they stay visible.
