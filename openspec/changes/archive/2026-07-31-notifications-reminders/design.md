# Design: Notifications & Reminders (C12)

## Technical Approach

Operator-facing failure alerting, event-triggered only. Two domain events reach two
auto-discovered listeners; each listener dispatches **one** `ShouldQueue` job that
re-derives the org from a fresh DB load, opens **one** `TenantContextScope::runFor()`
boundary, writes the dedupe row **before** sending, resolves recipients through a typed
reader whose org argument is mandatory, and sends a **non-queued** `Notification` with
`sendNow()`. The `notification_logs` row — never the queue, never application logic — is
the arbiter of "already handled", of "suppressed", and of "we tried and failed".

Every mechanism is transferred from an existing, shipped precedent rather than invented:
the dedupe INSERT idiom from `WebhookDeliveryRecorder.php:111-133`, the scalar-payload
queued job from `DeliverWebhookJob.php:62-64`, the typed mandatory-argument reader from
`AdminParticipantReader.php:37-61` (C11 D1), the never-propagate listener wrapper from
`SendEvaluationWebhook.php:49-60`, and the CHECK-constraint discipline from
`2026_07_27_000001_create_webhook_deliveries_table.php:114-133`.

Conforms to `specs/notifications/spec.md` (all 9 requirements) and the three delta specs.

## Sequence

```
DeliverWebhookJob::recordRetryable():204-219   ScoreEvaluationJob::failed()
  status→dead  (also failed():289-299)            event(EvaluationFailed):23-30
         │  event(WebhookDeliveryDead)                        │
         └──────────────┬───────────────────────────────────-─┘
                        │  auto-discovered listener (plain, try/catch Throwable)
                        │  NotifyOnWebhookDeliveryDead / NotifyOnScoringFailure
                        │
              SendOperatorNotificationJob::dispatch(type, subjectType, subjectId)
                        │
        Queue::before → orgId=null, bypass=false, teamId=null
                        │
  (1) OUTSIDE ctx   subject = Model::withoutGlobalScopes()->find($subjectId)
  (2) OUTSIDE ctx   null → log + return   |   $orgId = subject.organization_id
  (3) ┌── TenantContextScope::runFor($orgId, fn () =>
      │      a. DB::transaction(NotificationLog::create(status=pending))
      │           23505 → reload; sent|suppressed → return; pending|failed → continue
      │      b. OperatorRecipientResolver::forOrganization($orgId)   ← typed, mandatory
      │      c. suppression window? → status=suppressed + reason, no send
      │      d. Notification::sendNow($group, $n->locale($lang))  per locale group
      │      e. status=sent, sent_at=now(), recipient_count, suppressed_carried_count
      │         throw → status=failed + last_error, rethrow (queue retries)
      └── finally: previous (orgId, bypass, teamId) restored
```

## Architecture Decisions

### D1 — Laravel Notifications, `mail` channel only; the audit table IS the future in-app feed

`app/Notifications/{WebhookDeliveryDeadNotification,ScoringFailedNotification}.php`,
`via() => ['mail']`, returning a `MailMessage`. `User` already has `Notifiable`
(`User.php:33`), so no model change is needed for delivery.

| Option | Tradeoff | Decision |
|---|---|---|
| `Notification` + `mail` | Keeps `Notification::fake()`, per-recipient `->locale()`, and a free second channel later; queue boundary lives in the job either way | **CHOSEN** |
| Add the `database` channel | Needs Laravel's `notifications` table — **verified absent** (all 29 migrations enumerated under `api/database/migrations/`, none notification-related). It is polymorphic on `notifiable_*`, carries **no `organization_id`** and **no unique index**, and `Illuminate\Notifications\DatabaseNotification` is framework-namespaced, so `tests/Arch/C2/TenantModelArchTest.php` (globs `app/Models`) can never see it. Two competing sources of truth, one of them untenanted. | Rejected |
| Plain queued `Mailable` | Loses `Notification::fake()` and `->locale()` propagation; gains nothing, since the queue boundary is in the job regardless | Rejected |

**Is the backoffice operator feed worth designing for now?** No — and it costs nothing to
be ready. `notification_logs` is already org-scoped, typed, and status-bearing: a C11/C13
feed is a read endpoint over an existing table, not a schema change and not a channel. So
C12 builds no feed and never needs the `database` channel to add one.

### D2 — Recipient resolution: a typed reader, so the unsafe query cannot be written

`final class App\Support\Notifications\OperatorRecipientResolver` — the **only** sanctioned
path to a notification recipient set. Modeled verbatim on C11 D1
(`app/Support/Admin/AdminParticipantReader.php:37-61`).

```php
/** @return Collection<int, User> */
public function forOrganization(int $organizationId): Collection
```

No zero-argument overload, no default, no `?int`. Omitting the org is a **type error at
PHPStan L8 time**, not a runtime cross-tenant disclosure. Internally, three filters, all
mandatory:

1. `->where('organization_id', $organizationId)` — the load-bearing one.
   `User extends Authenticatable` (`User.php:30`), **not** `TenantModel`, so there is no
   global scope. This also excludes platform superadmins by construction:
   `users.organization_id` is **nullable** (`2026_07_16_200001_add_organization_id_to_users_table.php:22-26`)
   and `where(col, value)` never matches NULL.
2. `->role($roleModels, config('notifications.recipients.guard'))` — scopes the *pivot*
   (`HasRoles.php:101-103` is a `whereHas('roles', …)`, team-filtered at `:64-69`), never
   the `users` table. Independent of (1); both always.
3. Roles are resolved **defensively**, as `Role` model instances, before the scope call.

| Option | Tradeoff | Decision |
|---|---|---|
| Typed reader, mandatory org argument | Forgetting the filter is a compile-time error; one class to test to ~95%; reusable by a future digest/console path | **CHOSEN** |
| Documented `->where('organization_id', …)` convention in the job | Exactly the convention that produced this hazard. Review-time signal only. | Rejected |
| Make `User` extend `TenantModel` | The global scope would be evaluated during guard resolution, before `TenantContext` sets the resolver — the same reason `Participant` stays a plain `Model` (`AdminParticipantReader.php:46-48`). Breaks auth to fix a query. | Rejected |
| Arch test alone ("no `User::role(` outside the resolver") | A lint after the fact, silenceable, and it cannot express *which* filter is correct | Rejected as the mechanism — **kept as a backstop** |

**Two verified Spatie landmines this reader neutralises.**

- **`->role()` throws on a missing role — it does not return empty.** `scopeRole` resolves
  each name via `Role::findByName` (`HasRoles.php:96`), which throws `RoleDoesNotExist`
  (`Models/Role.php:112-114`), and `findByParam` filters by the current team id
  (`Models/Role.php:174-181`). Role rows are **per-organization**
  (`RolesAndPermissionsSeeder.php:44-52` sets the team id first; C11 fixtures create
  `['team_id' => $org->id]`). An organization that never had an `operator` role row would
  make the recipient query **throw inside the alerting job** — retry, retry, dead job, and
  the operator never learns their integration is broken. The resolver therefore looks the
  `Role` rows up itself (name + guard + team), passes the found instances (which
  `scopeRole` accepts and does not re-resolve, `HasRoles.php:86-88`), and treats an absent
  role as "contributes no recipients".
- **Guard pinning is defensive, not a live bug.** `Guard::getDefaultName()` returns
  `config('auth.defaults.guard')` when it is among the model's possible guards
  (`vendor/spatie/laravel-permission/src/Guard.php:101-113`); that is `'api'`
  (`config/auth.php:19`), which matches the seeded `guard_name`
  (`RolesAndPermissionsSeeder.php:50`). Correct today — but both `web` and `api` use the
  `users` provider (`config/auth.php:40-51`), so an `AUTH_GUARD` env override would
  silently match zero roles. The guard is passed explicitly from config.

**Zero recipients is a recorded outcome, not a crash**: the row is written
`suppressed` / `suppression_reason = no_recipients`.

### D3 — Idempotency: the C10 pattern, a new table

Table `notification_logs` (plural — Eloquent convention; the specs' prose noun is
`notification_log`, the same object). Model `App\Models\NotificationLog extends TenantModel`,
satisfying `tests/Arch/C2/TenantModelArchTest.php`.

```
UNIQUE (organization_id, notification_type, subject_type, subject_id)
```

All four columns **NOT NULL** — Postgres treats NULLs as distinct, which silently disables
the arbiter (the defect class already fixed for `webhook_deliveries`, migration `:68-69`).
`subject_type` is a string discriminator cast to `App\Enums\NotificationSubjectType`
(`participant` | `webhook_delivery`) with **no FK**: two nullable typed FK columns plus a
CHECK is the obvious alternative and it is wrong — it puts NULLs in the unique index.
Orphan tolerance is deliberate; an audit trail should survive its subject.

The INSERT is the `WebhookDeliveryRecorder.php:111-133` idiom transferred verbatim,
including the non-obvious part: the inner `DB::transaction()` exists so a caught 23505
rolls back to a **savepoint** rather than poisoning an enclosing transaction — without it,
every subsequent statement in a `RefreshDatabase` test fails with "current transaction is
aborted" (`WebhookDeliveryRecorder.php:112-119`).

Write-before-send, always. A crash between INSERT and send loses one email; the inverse
loses idempotency and double-sends. On the losing branch the **existing row's status
decides**, mirroring `DeliverWebhookJob.php:109-111`: `sent` / `suppressed` are terminal →
no-op; `pending` / `failed` → an unfinished send, continue.

Rejected: reusing `webhook_deliveries` (its `delivery_id`, `target_url`, `payload_version`
and four CHECK constraints at `:114-133` are meaningless for mail); `firstOrCreate`
(TOCTOU — the DB must arbitrate); a Redis lock (not auditable, lost on flush, no C11 read
model).

### D4 — Storm suppression: a window, plus a carried count so silence is never total

One provider outage yields one *distinct* failure per candidate, which D3 cannot collapse.
Before sending, inside the same `runFor()` boundary:

```
NotificationLog::where('notification_type', $t)      // org filter comes from the
    ->where('status', Sent)                          // TenantScoped global scope —
    ->where('sent_at', '>=', now()->subSeconds($w))  // legitimate here, unlike D2:
    ->exists();                                      // NotificationLog IS a TenantModel
```

Within the window: the row is still written, `status = suppressed`,
`suppression_reason = window`, **no email**. When the window has elapsed, the next
occurrence sends — and that email carries
`suppressed_carried_count` = suppressed rows for this `(org, type)` since the last `sent`
row. **What the operator actually sees**: the first failure immediately, then silence for
the window, then *"1 new failure — 46 further failures suppressed in the last 15 minutes"*.

| Option | Tradeoff | Decision |
|---|---|---|
| Window + count carried on the next send | Event-triggered, so it needs **no scheduler**; nothing is silently lost; the operator can tell 1 from 200 | **CHOSEN** |
| Pure silence after the first | The operator cannot distinguish one broken endpoint from a total outage | Rejected |
| Scheduled digest job flushing the window | Strictly better UX, but takes a **second** infra dependency (the Laravel scheduler) for a slice deliberately scoped to need only the worker | Rejected — revisit in C13 |
| Delay the first email to batch it | Trades the only latency that matters (the first alert) for tidiness | Rejected |
| `RateLimiter` / cache | No audit row, no C11 count, lost on cache flush | Rejected |

Window from `config('notifications.suppression.window_seconds')` (default **900**), with a
per-type override map. Nothing hardcoded — the `config/webhooks.php` rule.

### D5 — Exactly two triggers; one needs an event that does not exist yet

| Event | Verdict | Why |
|---|---|---|
| `webhook_deliveries.status → dead` | **NOTIFY** (`webhook_delivery_dead`) | Rare (6 attempts / ~2.7 h); the customer's system never received the evaluation; needs a human to fix an endpoint |
| `EvaluationFailed` (`app/Events/EvaluationFailed.php:23-30`) | **NOTIFY** (`scoring_failed`) | Rare; a candidate interviewed and has no result |
| `EvaluationCompleted` | Dashboard only (C11) | One per candidate — a 500-candidate campaign is 500 emails. Asserted absent by test, per spec. |
| Terminal `pending` evaluation (sub-90%) | Dashboard only | A *quality* signal, meaningful only aggregated |
| `webhook_deliveries.status → failed_permanent` (4xx) | Dashboard only | A misconfigured URL fires **once per participant** — a storm by construction, and a setup error, not an incident. Revisit only if operators ask. |
| `skipped` / `no_webhook_url` | Neither | A project configuration state, visible in C11 |
| `ScoringRequested`, `ParticipantCreated`, `CompetencySessionEnded` | Neither | Internal plumbing, per-candidate volume |
| Scoring stalled in `in_valutazione` | Deferred | Inherently time-triggered — needs the scheduler |

`EvaluationFailed` already fires. **`WebhookDeliveryDead` does not exist** — verified: the
full `app/Events/` set is `EvaluationCompleted`, `EvaluationFailed`, `ScoringRequested`,
`CompetencySessionEnded`, `ParticipantCreated`. C10 is archived, so C12 adds
`App\Events\WebhookDeliveryDead(int $deliveryId)` — a reference, never a trusted org copy
(webhooks delta).

**It must be emitted at two sites, both verified**: `DeliverWebhookJob::recordRetryable()`
`:204-219` (the modeled path) and `DeliverWebhookJob::failed()` `:289-299` (the safety
net). Both already log `webhook.delivery.dead`; emitting from only one is a silent hole.
They are mutually exclusive per row (`failed()` returns early for terminal rows,
`:285-287`), and D3 makes double emission harmless regardless. Emission goes **immediately
after** `persist()` and **outside** the `runFor()` closure — matching the existing
`Log::error` placement — so the listener never inherits an ambient org it is required to
re-derive.

Accepted consequence: one scoring failure can produce `scoring_failed` **and**, later,
`webhook_delivery_dead`. Different failures, different remediation; suppression is
per-`(org, type)` by design.

### D6 — Queue interaction, stated precisely

`App\Jobs\SendOperatorNotificationJob implements ShouldQueue`, scalar constructor
`(NotificationType $type, NotificationSubjectType $subjectType, int $subjectId)` — no
models, per the S1-S7 rationale at `DeliverWebhookJob.php:26-30`. Its source contains the
literal `TenantContextScope::`, so `QueuedJobTenantContextArchTest.php:97-112` passes with
**no allowlist entry**.

Notifications are never `ShouldQueue`; the job calls `Notification::sendNow()`.

**Why that rule needs its own named test, stated against the real gap.** The proposal's
premise (the guard globs `app/Jobs/*.php`) is **stale**: verified at
`tests/Arch/Tenancy/QueuedJobTenantContextArchTest.php:44-95`, discovery is a
`RecursiveDirectoryIterator` walk of `app_path()` (`:107`), so a `ShouldQueue` class under
`app/Notifications/` *is* already discovered. The residual gap is different and real: the
guard's compliance check is a **string search** for `'TenantContextScope::'` (`:89`). A
Notification that implements `ShouldQueue` **and** merely mentions that string passes the
scan — while Laravel wraps it in `Illuminate\Notifications\SendQueuedNotifications`, a
framework class no scan over `app/` can ever inspect, executing after `Queue::before` has
reset the resolver to null. Hence the tenancy delta's dedicated scenario: a rule keyed on
`ShouldQueue` under `app/Notifications/`, **with no allowlist escape**.

**Queue name: the default, and no config key for it.** `config/queue.php:137` defaults
`runtime.worker_queues` to `['default']`. A `notifications` queue name that the worker does
not consume would strand every alert silently — the worst possible failure for this
capability. C10 added a `delivery.queue` key (`config/webhooks.php:68`); C12 deliberately
does not. Adding one later MUST land together with the matching `worker_queues` entry.

Dispatch is `::dispatch(...)->afterCommit()` (the `SendEvaluationWebhook.php:110`
precedent), never `->handle()`, so `Queue::before` fires.

### D7 — Mail transport and i18n

**Verified state.** `config/mail.php:17` → `env('MAIL_MAILER', 'log')`; from-address
defaults to `hello@example.com` (`:113-116`); the `smtp` mailer reads `MAIL_HOST`/`MAIL_PORT`
(`:44-45`). `docker-compose.yml:65-73` defines Mailpit (`axllent/mailpit:v1.22`, 1025/8025);
`docker-compose.yml:110-111` sets `MAIL_HOST: mailpit` and `MAIL_PORT: 1025` on the `api`
service and **not `MAIL_MAILER`**. Net: local mail goes to the log driver. Tests are
unaffected — `phpunit.xml:50` pins `MAIL_MAILER=array`. `api/.env.example` **could not be
read: the `api/.env*` path is denied by this agent's tool permissions** (not a filesystem
error), so its content stays unverified — tasks must have the implementer open it.

**The gotcha the spec did not catch: `MAIL_MAILER` on the `api` service is not enough.**
The process that actually sends is the **queue worker**, a separate compose service being
added by `queue-worker-scheduler`. C12 therefore introduces a shared anchor
`x-beai-app-env: &beai_app_env` carrying `MAIL_MAILER: smtp`, `MAIL_HOST`, `MAIL_PORT`,
`MAIL_FROM_ADDRESS`, merged into `api` — and the worker service (owned by the other change)
merges the same anchor. If the worker lands without it, alerts are written to a log file
inside a container nobody reads. **Coordination point, tracked as a CRITICAL risk.**
Production transport stays unselected: no provider-specific code, required env vars
documented only.

**i18n.** There is no recipient language preference anywhere today — verified across both
migrations that define the table (`0001_01_01_000000_create_users_table.php` and
`2026_07_16_200001_add_organization_id_to_users_table.php:21-33`): `name`, `email`,
`email_verified_at`, `password`, `remember_token`, `timestamps`, `organization_id`,
`is_superadmin`. C12 adds nullable `users.locale` (string, 5) and puts it in `$fillable`
(`User.php:41-45` — a preference, not a security attribute; note `phpunit.xml:27` excludes
this file from the coverage gate).

Resolution is `$user->locale` when it is in `config('app.supported_locales')`
(`config/app.php:97` → `['it','en']`), else `config('app.fallback_locale')`
(`config/app.php:83`). There is **no HTTP request inside a queued job**; the transferable
pattern is reading the locale off the model, as `ScoreEvaluationJob.php:298` does
(`$project->language ?? 'en'`). Recipients are therefore **grouped by resolved locale** and
`sendNow()` is called once per group with `$notification->locale($lang)` — a single
collection-wide send would apply one language to everybody. New namespace
`lang/{it,en}/notifications.php` (verified: only `messages.php` and `interview.php` exist
per locale today). Machine values — `notification_type`, `status`, `suppression_reason` —
are never localized, per `CLAUDE.md`.

### D8 — When the notifier itself fails

Four layers, and deliberately **no fifth**.

1. **The row is the record.** Written `pending` before the send. Success → `sent` +
   `sent_at` + `recipient_count`. A throwing send → caught, `status = failed`,
   `last_error` (redacted, truncated per `config/webhooks.php:90` precedent), **rethrown**
   so the queue retries.
2. **Bounded retry.** `tries()` / `backoff()` from `config('notifications.dispatch.*')`,
   never hardcoded. On exhaustion, `failed(Throwable)` logs the machine key
   `notification.dispatch.failed` and force-sets the row to `failed` inside `runFor()` —
   the `DeliverWebhookJob::failed()` shape (`:264-300`).
3. **The framework's own net.** `failed_jobs` (`config/queue.php:200-204`,
   `database-uuids`) retains the exception for 7 days
   (`queue.maintenance.failed_jobs_retention_hours = 168`, `config/queue.php:167`), pruned
   by the scheduled task at `bootstrap/app.php:38-41`.
4. **The listener never propagates.** Both listeners wrap their whole body in
   `try/catch(\Throwable)` + `Log::error`, exactly as `SendEvaluationWebhook.php:49-60`
   does and for a sharper reason: the `EvaluationFailed` listener runs **synchronously
   inside `ScoreEvaluationJob::failed()`**. A notification bug must never corrupt the
   scoring job's own failure handling.

**Rejected: notifying anyone about a failed notification.** It is self-referential, it
needs the same broken channel, and it converts one outage into an amplification storm. The
terminal signal is the `failed` row, which C11's org-scoped dashboard renders as *"we tried
to alert you and could not"* — no new migration required, which is why `last_error` and
`status` are on the table from day one.

### D9 — Infrastructure dependency: stated, not solved

`queue-worker-scheduler` owns the runner. It is **in flight and already partially present
in the `api` working tree at design time** (observed by reading files; no git inspection
performed): `bootstrap/app.php:34-45` registers `->withSchedule()`; `config/queue.php:24`
flips the default connection to `redis`; `config/queue.php:133-140` adds `runtime.*`;
`app/Support/Queue/QueueRuntimeInvariant.php` and `tests/Helpers/QueueWorkCommandFixtures.php`
(`composer.json:46`) exist. C12 owns **none** of it and configures no worker.

Two constraints C12 inherits from it and must not violate: the **default queue only**
(D6), and the **mail env must reach the worker service** (D7). C12 needs the worker; it
does **not** need the scheduler, because it is event-triggered only (D4, D5).

### D10 — Rollout

Two additive migrations (`create_notification_logs_table`, `add_locale_to_users_table`),
both with working `down()`, no data transformation, no destructive change. Rollback =
`git revert` of the PR merge commit(s) on `api/develop`, `migrate:rollback` of the two
migrations, wrapper submodule pointer reset. The only touch-points on shipped code are two
event-emission lines in `DeliverWebhookJob` and two listeners; reverting restores today's
log-only behaviour exactly. No new Composer package — Notifications and Mail ship with
`laravel/framework` (`composer.json:12`). Branch `feature/notifications-reminders` off
`api/develop`, cut **after** `queue-worker-scheduler` merges to avoid a `config/queue.php`
and `docker-compose.yml` conflict.

## File Changes

| File | Action | Description |
|---|---|---|
| `api/database/migrations/*_create_notification_logs_table.php` | Create | D3 — unique dedupe index + 2 CHECK constraints + `(org, type, status, sent_at)` index |
| `api/database/migrations/*_add_locale_to_users_table.php` | Create | D7 — nullable `locale` |
| `api/app/Models/NotificationLog.php` | Create | `extends TenantModel`; `organization_id` **not** in `$fillable` |
| `api/app/Enums/{NotificationType,NotificationSubjectType,NotificationStatus,NotificationSuppressionReason}.php` | Create | Machine values, never localized |
| `api/app/Events/WebhookDeliveryDead.php` | Create | D5 — `int $deliveryId` only |
| `api/app/Jobs/SendOperatorNotificationJob.php` | Create | D6 — the only queue boundary; one `runFor()` |
| `api/app/Support/Notifications/OperatorRecipientResolver.php` | Create | D2 — mandatory typed org argument |
| `api/app/Notifications/{WebhookDeliveryDeadNotification,ScoringFailedNotification}.php` | Create | D1 — pure renderers, **never** `ShouldQueue` |
| `api/app/Listeners/{NotifyOnWebhookDeliveryDead,NotifyOnScoringFailure}.php` | Create | D8 layer 4 — auto-discovered, try/catch(Throwable) |
| `api/app/Jobs/DeliverWebhookJob.php` | Modify | D5 — emit `WebhookDeliveryDead` at `:219` and `:299`, outside `runFor()` |
| `api/app/Models/User.php` | Modify | D7 — `locale` in `$fillable` |
| `api/config/notifications.php` | Create | D2/D4/D8 — roles, guard, window, retry. No `queue` key (D6) |
| `api/lang/{it,en}/notifications.php` | Create | D7 — first outbound-copy namespace |
| `api/resources/views/mail/...` (if a custom template is needed) | Create | Only if the default `MailMessage` markdown is insufficient |
| `api/tests/Arch/Tenancy/NotificationNeverQueuedArchTest.php` | Create | D6 — named, no allowlist |
| `api/tests/Arch/Notifications/RecipientResolverArchTest.php` | Create | D2 backstop — no `User::role(`/`User::where(` outside the resolver |
| `docker-compose.yml` | Modify | D7 — `x-beai-app-env` anchor with `MAIL_MAILER: smtp` + `MAIL_FROM_ADDRESS` |
| `openspec/specs/notifications/spec.md` | Create | New capability |
| `openspec/specs/{webhooks-integration,scoring-engine,tenancy}/spec.md` | Modify | Delta promotion |

## Testing Strategy

| Layer | What | How |
|---|---|---|
| Unit | `OperatorRecipientResolver` (~95%) | admin+operator in, viewer out; **missing role row → empty, not `RoleDoesNotExist`**; superadmin (`organization_id = null`) never returned; explicit guard honoured |
| Unit | Suppression window + locale resolution | boundary at exactly the window; unsupported `locale` value falls back; `suppressed_carried_count` arithmetic |
| Unit | `config/notifications.php` invariants | window > 0; roles non-empty and a subset of the seeded three; **no `queue` key** (D6 regression) |
| Feature | Dispatcher job (~95%) | hostile ambient resolver — foreign org **and** null — row + every recipient carry the subject's org; cross-tenant test (org B receives nothing) per the `CrossTenantEvaluationIsolationTest` precedent; `::dispatch()` only, never `->handle()` |
| Feature | Idempotency | double dispatch → one row, one email; concurrent-INSERT race caught as a no-op; unique violation inside `RefreshDatabase` does **not** poison the transaction (the savepoint regression) |
| Feature | Both emission sites | `recordRetryable()` dead **and** `failed()` dead each produce the event; `delivered`/`failed_permanent`/`skipped` produce none |
| Feature | Anti-spam invariant | `EvaluationCompleted` (including a `pending` sub-90% evaluation) → **zero** notifications, asserted explicitly |
| Feature | Notifier failure | send throws → row `failed` + `last_error`, job retried; exhaustion → `failed()` marks the row; listener throw never escapes into `ScoreEvaluationJob::failed()` |
| Feature | i18n | `locale='it'` → Italian body; `locale=null` → fallback; mixed-locale recipient set → one send per locale group; `notification_type`/`status` unlocalized in the persisted row |
| Arch | Never-queued notifications | `ShouldQueue` under `app/Notifications/` fails by name, no allowlist |
| Arch | Recipient hygiene | no `User::role(` / `User::where(` outside `OperatorRecipientResolver` |
| Arch | Existing guard | `QueuedJobTenantContextArchTest` stays green with **no** new allowlist entry |

Coverage: ~95% on the resolver, the dedupe path, and tenant scoping; 85% overall. New
files: 0 PHPStan L8 errors.

**Delivery**: 2 chained PRs to respect the 400-line review budget — **PR1** = migrations,
model, enums, config, `OperatorRecipientResolver`, both arch tests, unit tests; **PR2** =
event, job, notifications, listeners, `DeliverWebhookJob` emission, lang files, compose
anchor, feature tests. `sdd-tasks` owns the binding forecast.

## Open Questions

- [ ] Recipient roles default to `admin` + `operator` (`viewer` excluded). A proposal
      assumption, **not** client-ratified — config-driven, so confirmable without a code change.
- [ ] Suppression window default **900 s**. Same treatment. Is "first alert, then a carried
      count on the next send" (D4) acceptable in place of a true scheduled digest?
- [ ] **CRITICAL** — the `queue-worker-scheduler` worker compose service must merge the
      `x-beai-app-env` anchor (D7). Confirm with that change's owner before C12 merges, or
      every production alert is written to a log file inside a container nobody reads.
- [ ] Production mail transport (SES / Postmark / Resend) and its credentials: a deployment
      task needing a named owner. No provider is assumed in code.
- [ ] `api/.env.example` is unreadable from this agent's sandbox (path denied by tool
      permissions). The implementer must open it and confirm whether `MAIL_MAILER` is set
      there before relying solely on the compose override.
