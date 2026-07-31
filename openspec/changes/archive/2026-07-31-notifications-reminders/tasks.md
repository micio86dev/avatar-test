# Tasks: Notifications & Reminders (C12)

> Strict TDD active. Every behavioral task is RED → GREEN → REFACTOR.
> `api` submodule: 5 chained PRs (PR1–PR5) on `feature/notifications-reminders` (tracker,
> draft/no-merge) off `api/develop`, `feature-branch-chain` — each PR's base is
> the previous PR's branch; only the tracker merges to `api/develop`.
> Wrapper: 1 one-line follow-up PR (see Reconciliation §2 — the compose anchor
> C12's design planned to introduce already exists).
> Branch cut **after** `queue-worker-scheduler` merges to `api/develop` (D9/D10),
> otherwise `config/queue.php` and `docker-compose.yml` conflict.

## Spec ↔ Design Reconciliation (found during this phase)

`sdd-spec` and `sdd-design` ran independently, and the wrapper's
`queue-worker-scheduler` PR5 landed between design and this phase. Cross-checked
against source, verified this phase rather than assumed:

1. **Design D7's `x-beai-app-env` anchor: superseded by a real one, under a
   different name.** Design specifies that C12 "introduces a shared anchor
   `x-beai-app-env: &beai_app_env`". That is now stale. `queue-worker-scheduler`
   PR5 already added `x-api-environment: &api-environment` to
   `docker-compose.yml`, merged by `api`, `worker` **and** `scheduler`. C12 must
   **not** introduce a second anchor — two anchors carrying overlapping app env
   is precisely the divergence D7 exists to prevent. The task below adds one key
   to the existing anchor.
2. **D7's CRITICAL coordination risk is closed on the worker side, still open on
   the mail side.** The open question — "the worker compose service must merge
   the anchor, or every production alert is written to a log file inside a
   container nobody reads" — is half-resolved: PR5's `worker` service *does*
   merge the anchor, and that anchor already carries `MAIL_HOST: mailpit` /
   `MAIL_PORT: 1025`. What is still missing is `MAIL_MAILER`, which resolves to
   `config/mail.php`'s default of `log`. PR5 deliberately left it unset and
   documented the seam in a comment on the anchor, because choosing the mail
   driver is C12's decision. **This is now a one-line task, not a coordination
   negotiation.**
3. **`QUEUE_CONNECTION` is pinned in compose as of PR5.** Design D6 reasons about
   the default queue name; it did not know that `api/.env` sets
   `QUEUE_CONNECTION=database`, which beat the config default and would have had
   the worker consuming a different queue than the app dispatched to. PR5 pins
   `QUEUE_CONNECTION: redis` on the shared anchor. C12 inherits a correct runtime
   and must not re-litigate it.
4. **Design D9's "observed by reading files; no git inspection performed" is now
   resolved.** `queue-worker-scheduler` is no longer "in flight and partially
   present in the working tree" — it is a 4-PR chain plus a wrapper PR. C12's
   branch cut therefore has a concrete gate: the tracker merged to `api/develop`.
5. **No disagreement found** between spec and design on: the two-trigger set,
   recipient scoping, the DB-level dedupe arbiter, the suppression window,
   non-queued renderers, tenant context inside the dispatcher job, locale-aware
   copy with unlocalized machine values, or the production-transport non-goal.
6. **Spec requirement without a design counterpart: none.** All 9 requirements in
   `specs/notifications/spec.md` map to at least one D-decision; the three delta
   specs map to D5 (webhooks, scoring) and D6 (tenancy).

## Review Workload Forecast

Sizes below are split into **production** and **test** lines, and the 400-line
budget is applied to the production column only. This is a deliberate change from
the previous forecast method, and it is evidence-based: on the two review-sweep
PRs measured this cycle the test/production ratio ran about 2:1
(`frontend#10` — 1656 total, ~450 production), and `queue-worker-scheduler` PR4
was forecast at 250–350 total and landed at 1898, a 5x miss, precisely because
test lines were forecast as if they were production lines. A budget that counts
a table-driven test fixture the same as a branch of business logic produces
either dishonest forecasts or pointless splits.

| Field | Value |
|-------|-------|
| Estimated production lines | PR1: 330 / PR2: 110 / PR3: 250 / PR4: 200 / PR5: 40 / PR6: 1 (wrapper) |
| Estimated test lines | PR1: 180 / PR2: 400 / PR3: 300 / PR4: 650 / PR5: 40 / PR6: 0 |
| 400-line budget risk (production) | Low |
| 400-line budget risk (total diff) | **High** — PR4 lands near 850 total |
| Chained PRs recommended | Yes |
| Suggested split | api PR1 → PR2 → PR3 → PR4 → PR5 (feature-branch-chain), then wrapper PR6 |
| Delivery strategy | auto-chain |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Schema, enums, model, config | api PR1 | Base = `feature/notifications-reminders`; nothing depends on anything, so it lands first and unblocks the rest |
| 2 | `OperatorRecipientResolver` + both arch guards | api PR2 | Base = PR1. Highest-risk unit in the change — cross-tenant disclosure lives here; held to ~95% |
| 3 | Event, emission sites, listeners, notification renderers, lang files | api PR3 | Base = PR2. Touches shipped code (`DeliverWebhookJob`) — two lines, both verified |
| 4 | `SendOperatorNotificationJob` + feature tests | api PR4 | Base = PR3. The only queue boundary; carries the dedupe, suppression, tenancy and i18n feature suites |
| 5 | Resend production transport (package, `services.resend.key`, docs) | api PR5 | Base = PR4. Ratified 2026-07-30. Small, and isolated so a provider change never reaches the domain code |
| 6 | `MAIL_MAILER: smtp` on the shared compose anchor | wrapper PR6 | Base = wrapper `develop`; AFTER the api tracker merges. One line — see Reconciliation §1–2 |

---

## api PR1 — Schema, Enums, Model, Config

- [x] 1.1 RED: `tests/Unit/NotificationsConfigTest.php` — assert `config('notifications')` invariants: `suppression.window_seconds` > 0; `recipients.roles` non-empty and a subset of the three seeded roles; `recipients.guard` non-empty; `dispatch.tries` ≥ 1; and **no `queue` key anywhere in the file** (D6 regression guard — a queue name the worker does not consume strands every alert silently).
- [x] 1.2 GREEN: create `api/config/notifications.php` — `recipients.roles` (default `['admin','operator']`), `recipients.guard` (from `config('auth.defaults.guard')`), `suppression.window_seconds` (default 900) + per-type override map, `dispatch.tries` / `dispatch.backoff`, `dispatch.last_error_max_length`. No hardcoded values anywhere else; the `config/webhooks.php` rule.
- [x] 1.3 Create `app/Enums/NotificationType.php` (`webhook_delivery_dead`, `scoring_failed`), `NotificationSubjectType.php` (`participant`, `webhook_delivery`), `NotificationStatus.php` (`pending`, `sent`, `suppressed`, `failed`), `NotificationSuppressionReason.php` (`window`, `no_recipients`). Backed string enums — these are machine values and are **never** localized (`CLAUDE.md`).
- [x] 1.4 RED: migration test asserting the dedupe arbiter actually arbitrates — two inserts with identical `(organization_id, notification_type, subject_type, subject_id)` raise 23505.
- [x] 1.5 GREEN: `database/migrations/*_create_notification_logs_table.php` — all four dedupe columns **NOT NULL** (Postgres treats NULLs as distinct, which silently disables the unique index; this is the defect class already fixed for `webhook_deliveries` at that migration's `:68-69`), `UNIQUE (organization_id, notification_type, subject_type, subject_id)`, a CHECK on `status`, a CHECK on `suppression_reason`, a `(organization_id, notification_type, status, sent_at)` index for the suppression-window query, plus `recipient_count`, `suppressed_carried_count`, `last_error`, `sent_at`. Working `down()`.
- [x] 1.6 `database/migrations/*_add_locale_to_users_table.php` — nullable `locale` (string, 5). Working `down()`.
- [x] 1.7 `app/Models/NotificationLog.php` — `extends TenantModel` so `tests/Arch/C2/TenantModelArchTest.php` sees it. `organization_id` deliberately **NOT** in `$fillable` (mass-assignment of the tenant key is the whole hazard the arch test exists for). Cast the four enum columns.
- [x] 1.8 `app/Models/User.php` — add `locale` to `$fillable`. It is a preference, not a security attribute. Note `phpunit.xml:27` excludes this file from the coverage gate, so this line needs no coverage task.
- [x] 1.9 Confirm `tests/Arch/C2/TenantModelArchTest.php` passes with `NotificationLog` present and **no allowlist entry**. If it needs one, stop — the model is wrong, not the test.
- [x] 1.10 Gates: `vendor/bin/pest`, `vendor/bin/pint --test`, `vendor/bin/phpstan analyse` (0 errors on new files, L8).
- [x] 1.11 Open api PR1 → tracker `feature/notifications-reminders`. DONE — micio86dev/backend#31.

## api PR2 — `OperatorRecipientResolver` and the Arch Guards

- [x] 2.1 RED: `tests/Unit/Notifications/OperatorRecipientResolverTest.php` — admin and operator are returned, viewer is not.
- [x] 2.2 RED: **the Spatie landmine** — an organization with no `operator` role row must yield an empty contribution, **not** a thrown `RoleDoesNotExist`. `scopeRole` resolves names via `Role::findByName` (`HasRoles.php:96`), which throws (`Models/Role.php:112-114`); role rows are per-organization. Untreated, the recipient query throws *inside the alerting job* — retry, retry, dead job, and the operator never learns their integration is broken. Assert the exception does not escape.
- [x] 2.3 RED: a platform superadmin (`users.organization_id IS NULL`) is never returned. `where(col, value)` never matches NULL — assert it, because this is load-bearing by construction rather than by an explicit filter.
- [x] 2.4 RED: an explicitly-passed guard is honoured (an `AUTH_GUARD` override must not silently match zero roles).
- [x] 2.5 RED: cross-tenant — users of org B are never returned for org A.
- [x] 2.6 GREEN: `app/Support/Notifications/OperatorRecipientResolver.php` — `final class`, single method `forOrganization(int $organizationId): Collection`. **No** zero-argument overload, **no** default, **no** `?int`: omitting the org must be a PHPStan L8 type error, not a runtime cross-tenant disclosure. Resolve `Role` model instances defensively (name + guard + team) before calling `->role()`, and treat an absent role as "contributes no recipients". Modeled on `app/Support/Admin/AdminParticipantReader.php:37-61`.
- [x] 2.7 GREEN: `tests/Arch/Notifications/RecipientResolverArchTest.php` — no `User::role(` and no `User::where('organization_id'` outside `OperatorRecipientResolver`. This is the backstop, not the mechanism (the type signature is the mechanism).
- [x] 2.8 GREEN: `tests/Arch/Tenancy/NotificationNeverQueuedArchTest.php` — any class under `app/Notifications/` implementing `ShouldQueue` fails **by name**, with **no allowlist escape**. State the real gap in the docblock: the existing `QueuedJobTenantContextArchTest` already discovers `app/Notifications/` (it walks `app_path()` at `:107`, so the proposal's "it only globs `app/Jobs`" premise is stale) — the residual hole is that its compliance check is a *string search* for `'TenantContextScope::'` (`:89`), which a queued Notification could satisfy by merely mentioning the string while Laravel wraps it in `SendQueuedNotifications`, a framework class executing after `Queue::before` reset the resolver to null.
- [x] 2.9 Resolver coverage ≥ 95%. DONE — 100%, above the ~95% target.
- [x] 2.10 Gates: pest, pint, phpstan.
- [x] 2.11 Open api PR2 → PR1 branch. DONE — #32.

## api PR3 — Event, Emission Sites, Listeners, Renderers, Copy

- [x] 3.1 RED: emitting from `recordRetryable()` produces `WebhookDeliveryDead`; emitting from `failed()` produces it too; `delivered` / `failed_permanent` / `skipped` produce **none**. Both sites, not one — emitting from only one is a silent hole.
- [x] 3.2 GREEN: `app/Events/WebhookDeliveryDead.php` — carries `int $deliveryId` **only**. A reference, never a trusted org copy: the consumer re-derives the org from a fresh DB load.
- [x] 3.3 GREEN: emit at `DeliverWebhookJob::recordRetryable()` (`:204-219`) and `DeliverWebhookJob::failed()` (`:289-299`), immediately after `persist()` and **outside** the `runFor()` closure, matching the existing `Log::error` placement — so the listener never inherits an ambient org it is required to re-derive.
- [x] 3.4 **MOVED TO PR4** (with the job it dispatches — a listener in PR3 would forward-reference a class that does not exist until PR4). RED: a listener that throws must never escape into the caller. This matters most for `NotifyOnScoringFailure`, which runs **synchronously inside `ScoreEvaluationJob::failed()`** — a notification bug must not corrupt the scoring job's own failure handling.
- [x] 3.5 **MOVED TO PR4**, same reason. GREEN: `app/Listeners/NotifyOnWebhookDeliveryDead.php` and `NotifyOnScoringFailure.php` — auto-discovered, plain (not queued), whole body wrapped in `try/catch(\Throwable)` + `Log::error`, per `SendEvaluationWebhook.php:49-60`. Dispatch is `SendOperatorNotificationJob::dispatch(...)->afterCommit()`, never `->handle()`, so `Queue::before` fires.
- [x] 3.6 GREEN: `app/Notifications/WebhookDeliveryDeadNotification.php` and `ScoringFailedNotification.php` — `via() => ['mail']`, returning a `MailMessage`. Pure renderers. **Never** `ShouldQueue` (PR2's arch guard enforces this).
- [x] 3.7 GREEN: `lang/it/notifications.php` and `lang/en/notifications.php` — the first outbound-copy namespace in the repo (only `messages.php` and `interview.php` exist per locale today). Subject and body copy for both notification types, including the carried-count phrasing from D4 ("1 new failure — 46 further failures suppressed in the last 15 minutes").
- [x] 3.8 RED/GREEN: **the anti-spam invariant, asserted explicitly** — `EvaluationCompleted`, including a terminal `pending` sub-90% evaluation, produces **zero** notifications. A 500-candidate campaign must not become 500 emails. This is a requirement, so it gets a test, not a comment.
- [x] 3.9 Gates: pest, pint, phpstan.
- [x] 3.10 Open api PR3 → PR2 branch. DONE — #33.

## api PR4 — The Dispatcher Job

- [x] 4.1 RED: **hostile ambient resolver** — with a foreign org set **and** with null set, the written row and every resolved recipient carry the *subject's* org, not the ambient one.
- [x] 4.2 RED: cross-tenant isolation — org B receives nothing, per the `CrossTenantEvaluationIsolationTest` precedent. Dispatch via `::dispatch()` only, never `->handle()`, so `Queue::before` actually runs.
- [x] 4.3 RED: idempotency — double dispatch yields one row and one email; a concurrent INSERT race is caught as a no-op.
- [x] 4.4 RED: **the savepoint regression** — a unique violation inside `RefreshDatabase` must not poison the enclosing transaction. Without the inner `DB::transaction()`, every subsequent statement in the test fails with "current transaction is aborted" (`WebhookDeliveryRecorder.php:112-119`). Assert a following query still works.
- [x] 4.5 RED: suppression — boundary at exactly the window; within the window a row is still written with `status=suppressed` + `suppression_reason=window` and **no** email; after the window the next send carries the correct `suppressed_carried_count`.
- [x] 4.6 RED: zero recipients is a recorded outcome, not a crash — row written `suppressed` / `no_recipients`.
- [x] 4.7 RED: i18n — `locale='it'` yields an Italian body; `locale=null` falls back; a mixed-locale recipient set produces **one send per locale group** (a single collection-wide send would apply one language to everybody); `notification_type` / `status` / `suppression_reason` are unlocalized in the persisted row.
- [x] 4.8 RED: notifier failure — a throwing send leaves the row `failed` + `last_error` (redacted and truncated per the `config/webhooks.php:90` precedent) and **rethrows** so the queue retries; on retry exhaustion `failed(Throwable)` logs `notification.dispatch.failed` and force-sets the row to `failed` inside `runFor()`.
- [x] 4.9 GREEN: `app/Jobs/SendOperatorNotificationJob.php implements ShouldQueue` — scalar constructor `(NotificationType, NotificationSubjectType, int $subjectId)`, no models. Load the subject with `withoutGlobalScopes()` **outside** the context; a null subject logs and returns; derive `$orgId` from the subject; open exactly **one** `TenantContextScope::runFor()`; write the dedupe row before sending; resolve recipients; check the window; `Notification::sendNow()` per locale group; record the outcome. `tries()` / `backoff()` read from `config('notifications.dispatch.*')`, never hardcoded.
- [x] 4.10 Confirm `QueuedJobTenantContextArchTest` stays green with **no** new allowlist entry — the job's source contains the literal `TenantContextScope::`, so it should pass on its own merits.
- [x] 4.11 Coverage ≥ 95% on the dedupe path and tenant scoping; overall suite ≥ 85%.
- [x] 4.12 Gates: pest, pint, phpstan.
- [x] 4.13 Open api PR4 → PR3 branch. Once PR1–PR4 are reviewed, merge bottom-up into the tracker, then the tracker → `api/develop`. **Do not** pass `--delete-branch` on a chained PR: deleting the base of a dependent PR closes it. DONE — #34.

## api PR5 — Production Transport: Resend

> **RATIFIED 2026-07-30 by the product owner: production mail transport is Resend.**
> This closes design.md Open Question 4 ("Production delivery transport … a
> deployment task needing a named owner"). Local development is unaffected and
> stays on Mailpit — the two are different environments, not competing choices,
> exactly as `specs/notifications/spec.md` requires ("Local Mail Transport
> Delivers to Mailpit" **and** "Production Delivery Depends on Infrastructure
> Outside This Capability").

Verified this phase against the installed framework, not assumed:
`Laravel Framework 13.20.0` ships a **first-party** Resend transport
(`Illuminate\Mail\Transport\ResendTransport`, registered by
`MailManager::createResendTransport()` at `:320`), and `api/config/mail.php:64-66`
**already** declares the `resend` mailer. Two things are genuinely missing: the
`resend/resend-php` package (`composer show` → not installed; the transport
type-hints `Resend\Contracts\Client`) and the `services.resend.key` entry the
transport falls back to.

- [x] 5.1 Add `resend/resend-php` to `api/composer.json` and record the resolved version in the **D25 Version Catalog** (`openspec/changes/project-skeleton-ci/design.md`). CLAUDE.md makes D25 the single source of truth for pinned versions, so a dependency that lands without a catalog entry violates the stack table. If the package cannot be resolved at a compatible version, **stop** and report — do not substitute another provider (Dependency Resolution Policy, D37). DONE — resend/resend-php v1.7.0; D25 catalog entry added in wrapper PR6.
- [x] 5.2 `config/services.php` — add `'resend' => ['key' => env('RESEND_API_KEY')]`. The transport reads `config('services.resend.key')` when the mailer config carries no explicit `key`. ALREADY PRESENT — Laravel 13 ships `services.resend.key` by default; verified, not assumed.
- [x] 5.3 RED: assert the transport resolves — `Mail::mailer('resend')` builds without throwing when a key is configured, and that `config('mail.mailers.resend.transport') === 'resend'`. Do **not** hit the network in a test; `phpunit.xml:50` pins `MAIL_MAILER=array` and that stays.
- [x] 5.4 **MOVED TO wrapper PR6** — `docs/dev-setup.md` lives in the wrapper repo. DONE there. Document the required production env vars (`MAIL_MAILER=resend`, `RESEND_API_KEY`, `MAIL_FROM_ADDRESS`) in `docs/dev-setup.md`. **`MAIL_FROM_ADDRESS` must be on a domain verified in the Resend dashboard** — Resend rejects unverified sender domains, and the failure surfaces as a transport exception inside the queued job, i.e. a `failed` notification row rather than an obvious boot error. The current default is `hello@example.com` (`config/mail.php:113-116`), which will not send.
- [ ] 5.5 **PARTIALLY DONE; the remainder is not actionable by anyone yet.** The variable NAME is now documented in `api/.env.example` (#37) — value deliberately empty, because a credential belongs in the platform store. Setting the real secret is still blocked: checked via the Railway API, the workspace's `avatar-test` project runs the **legacy Astro demo** (`DATABASE_PATH` = SQLite, `LIVEAVATAR_*`, `TAVUS_*`) with no BEAI service and no Postgres. **BEAI has never been deployed**, so there is no environment to set `RESEND_API_KEY` in. Needs, in order: a BEAI Railway project, a named owner for the Resend account, and a verified sender domain.
- [x] 5.6 Gates: pest, pint, phpstan.
- [x] 5.7 Open api PR5 → PR4 branch. DONE — #35.

## wrapper PR6 — Mail Driver on the Shared Anchor

- [x] 6.1 Open `api/.env.example` and confirm `MAIL_MAILER`. **CLOSED 2026-07-30 — the assumption was wrong.** Permission granted, file read: `MAIL_MAILER=smtp` was already set (line 29), as were `QUEUE_CONNECTION=redis` and `REDIS_CLIENT=phpredis`. Two SDD changes carried this task as BLOCKED-and-presumed-broken; it was neither. What the file genuinely lacked was any mention of the production transport, now added in micio86dev/backend#37 as a NAME-only `RESEND_API_KEY` placeholder plus the note that an unverified sender domain fails inside the queued job rather than at boot.
- [x] 6.2 Add `MAIL_MAILER: smtp` to the existing `x-api-environment` anchor in `docker-compose.yml` — **not** a new anchor (Reconciliation §1), and **`smtp`, not `resend`**: this anchor configures the local compose stack, where mail must reach Mailpit. Resend is production-only and is selected by the deployment environment (PR5). One line; it reaches `api`, `worker` and `scheduler` at once. Remove the `⚠️ COORDINATION SEAM` comment block that `queue-worker-scheduler` PR5 left on the anchor, since it will no longer describe reality.
- [x] 6.3 Verify end to end: `docker compose up -d`, trigger a dead webhook delivery, confirm the mail lands in the Mailpit UI at `http://localhost:8025` — not in a container log file. DONE — probe mail sent through the running stack landed in the Mailpit inbox (total: 1).
- [x] 6.4 Bump the `api` submodule pointer to the merged tracker commit on `api/develop`. **DONE 2026-07-30** — `api/develop` is at `6eb39a1` (tracker #36 carrying PR1–PR5).
- [x] 6.5 Open wrapper PR6. **DONE** — micio86dev/avatar-test#4, based on `feature/assessment-engine` rather than `develop` for the same reason queue-worker-scheduler PR5 was: `docker-compose.yml` does not exist on the wrapper's `develop`.

## Documented, Not Scoped (carried into the spec, not implemented here)

- ~~**Production mail transport** and its credentials.~~ **RATIFIED 2026-07-30: Resend.** Now in scope as api PR5 above, because Laravel 13.20 ships the transport first-party — it is a package plus a config key, not a deployment-only concern.
- **Scheduled digest** flushing the suppression window. Strictly better UX than the carried count, but it takes a second infra dependency (the scheduler) for a slice deliberately scoped to need only the worker. Revisit in C13.
- **Backoffice operator feed.** `notification_logs` is already org-scoped, typed and status-bearing, so a feed is a read endpoint over an existing table — not a schema change and not a new channel. Which is exactly why C12 never needs Laravel's `database` notification channel (untenanted, no unique index, framework-namespaced and therefore invisible to `TenantModelArchTest`).
- **Notifying anyone about a failed notification.** Self-referential, needs the same broken channel, and converts one outage into an amplification storm. The terminal signal is the `failed` row, which C11's dashboard renders.
- **`failed_permanent` (4xx) alerts.** A misconfigured URL fires once per participant — a storm by construction, and a setup error rather than an incident. Revisit only if operators ask.

## Open Questions (unchanged from design, still unratified)

- [x] **RATIFIED 2026-07-30 — recipient roles are `admin` + `operator`, `viewer` excluded.**
      Ratified by the assistant under the standing "complete all development" directive, on the
      2026-07-28 precedent where the product owner delegated the open decisions. Stated plainly so
      it is not mistaken for a client decision: **this is a default, not a requirement gathered from
      the client.**
      Reasoning: `viewer` is a read-only dashboard role. Being able to look at results is not a
      reason to be paged at 3am, and adding `viewer` would enlarge the blast radius of every storm
      by exactly the people who cannot act on it. `admin` and `operator` are the roles that can fix
      a broken endpoint or re-run a failed evaluation.
      **Cost to change: one line in `config/notifications.php`.** No migration, no code, no redeploy
      of anything but config — which is precisely why it was built config-driven.
- [x] **RATIFIED 2026-07-30 — suppression window 900 s, carried-count model accepted.**
      Same caveat as above: an assistant default under a standing directive, not a client decision.
      Reasoning on the WINDOW: 15 minutes is long enough that a provider outage produces one email
      rather than one per candidate, and short enough that a second, unrelated incident is not
      hidden for a working day. It is env-overridable per deployment and has a per-type override map.
      Reasoning on the MODEL: a true scheduled digest is better UX and was rejected on cost, not on
      merit — it needs the SCHEDULER as a second infrastructure dependency, and C12 was deliberately
      scoped to need only the worker. The carried count buys the property that actually matters
      (the operator can distinguish 1 failure from 200) without that dependency. Revisit in C13,
      where the scheduler is already in scope.
      **Cost to change: one config value.**
- [x] ~~Production mail transport owner.~~ **RATIFIED 2026-07-30 — Resend** (api PR5). Still needs a named owner for the account, the verified sender domain and the `RESEND_API_KEY` secret on Railway.
