# Proposal: Notifications & Reminders (C12)

## Intent

C12 was chartered as "invitations; deadline reminders; queued email/notification jobs"
(`openspec/ROADMAP.md:45`, FR-002). Investigation found that **half of that charter is not
buildable and the other half is already owed**.

**Not buildable — candidate-facing email.** `participants` has **no contact column of any
kind**. Verified in full at `api/database/migrations/2026_07_20_000001_create_participants_table.php:29-68`:
the columns are `organization_id`, `project_id`, `candidate_ref`, `display_name`, `role_code`,
`language`, `status`, `started_at`, `completed_at`, `timestamps`. No email, no phone, no contact
field. This is not an oversight — it is the opaque-candidate-identifier contract
(`:40-41` "Opaque SSO identifier — stored VERBATIM") and GDPR data minimisation working as
designed. BEAI is **structurally incapable of contacting a candidate**, and the binding
integration docs put that job with the caller: the calling system generates the secure link
(`docs/app_description/04-integration-surface/01-ingresso-sso.md:9`), need not even pre-create
the candidate (`:33`), and BEAI's own "generate SSO link" is offered as an *"alternativa o
complemento"* to portal entry — an M2M capability, not a sending channel
(`docs/app_description/04-integration-surface/02-api-capacita.md:75`).

**Already owed — operator-facing notification.** `users.email` exists and is `unique`
(`api/database/migrations/0001_01_01_000000_create_users_table.php:17`), so organization staff
*are* reachable. C10 explicitly deferred its dead-letter alerting to this slice:
*"Operator/tenant **notification is C12** (`notifications-reminders`) — C10 must not grow a
notification channel"* (`openspec/changes/webhooks-integration/proposal.md:145-147`, ratified
at `:334`). C6 likewise lists *"Notifications (C12)"* as its own non-goal
(`openspec/specs/participant-sso/spec.md:21`). That is a concrete, already-agreed obligation
sitting unfulfilled.

**Why now.** Today, when a webhook delivery dies after ~2.7 h of retries
(`openspec/changes/webhooks-integration/proposal.md:138-144`), or when scoring fails
catastrophically and a candidate lands in `errore`, BEAI writes a log line and an observability
counter and **nobody is told**. The calling system's integration is silently broken and the
customer discovers it from the missing report, not from us. That is the failure C12 closes.

**Success looks like:** a small number of genuinely actionable failures reach the right
organization's staff, exactly once, in their language, with a tenant-scoped audit row proving
it — and a notification volume low enough that nobody builds a mail rule to mute us.

## Scope

### In Scope

- **`notification_log`** table + `TenantModel`-descended model: tenant-scoped audit trail and
  idempotency arbiter, mirroring the C10 `webhook_deliveries` shape.
- **Two notification types only** (see D3): `webhook_delivery_dead` and `scoring_failed`.
- **Recipient resolution** for organization users, explicitly `organization_id`-filtered.
- **One queued dispatcher job** (`app/Jobs/*`) establishing tenant context via
  `TenantContextScope::runFor()`, owning the dedupe write and the send.
- **Notification classes as pure renderers** (`app/Notifications/*`), non-queued, locale-aware.
- **`users.locale`** column (nullable) — verified absent today; required for D7.
- **`lang/{it,en}/notifications.php`** — new server-side outbound copy namespace.
- **Storm suppression** (D6): a config-driven per-`(org, type)` window so a provider outage
  cannot produce one email per affected candidate.
- **Local mail transport wiring** so Mailpit actually catches mail (D8).
- **Arch-test extension** closing the queued-notification bypass identified in D2.
- Spec updates: new `notifications` capability; `webhooks-integration` and `scoring-engine`
  gain their notification emission points.

### Out of Scope (explicit)

| Excluded | Why |
|---|---|
| **Candidate invitation emails** | BLOCKED — see "Blocked non-goal" below. |
| **Deadline reminder emails to candidates** | BLOCKED — same reason, plus needs a scheduler. |
| **Any time-triggered sweep** (stalled-scoring detection, deadline tiers) | Deliberate: C12 ships **event-triggered only**, so it needs the queue worker but **not** the scheduler. Halves the infra dependency. |
| **Queue worker + Laravel scheduler infrastructure** | D9 — pre-existing, repo-wide, affects C9 and C10 equally. Its own change. |
| **`laravel/horizon` install** | Absent from `api/composer.json`; a dependency decision, already deferred by C10 D7 (`webhooks-integration/proposal.md:154-161`) and by the archived `queued-job-tenancy` proposal (`:37`). |
| **Laravel's built-in `database` notification channel / `notifications` table** | D2 — creates a second, un-tenant-scoped source of truth. |
| **Backoffice in-app notification feed UI** | C11/C13 surface; C12 provides the org-scoped table it would read. |
| **Per-project reminder cadence config** | `openspec/specs/project-config/spec.md:489` defers "Deadline / `goes_live_at` scheduled jobs" to C12/C13 — with candidate reminders blocked, the cadence column has nothing to configure. Deferred to C13 or the unblocking change. |
| **SMS / Slack / webhook-to-operator channels** | YAGNI; the Notification abstraction chosen in D2 keeps the door open at near-zero cost. |
| **Production mail transport selection** (SES / Postmark / Resend) | D8 — a deployment decision, not a code one. |

### Blocked non-goal: candidate invitations & reminders

Recorded here rather than silently dropped, because FR-002 (`docs/BEAI_BRIEF.md`) does list
them.

**Why blocked:** sending a candidate anything requires storing candidate PII (at minimum an
email address) in a data model that **deliberately excludes it**
(`create_participants_table.php:29-68`, class doc `:14` "The opaque candidate_ref is echoed
unchanged in every webhook (GDPR/integration contract)"). Adding it is a **product and GDPR
decision, not an architectural one**. It compounds with two still-open decisions in
`openspec/ROADMAP.md:48-56`: **#2** (GDPR retention for candidate data — a new PII class needs a
retention rule before it exists) and **#5** (time limits / deadline behavior — a reminder has no
meaning without a ratified deadline policy).

**The exact question for the client:**

> Should BEAI store candidate contact details (email address, and optionally name) and become
> the sender of record for interview invitations and deadline reminders — or does the calling
> portal remain the only system that ever contacts a candidate, with BEAI limited to signalling
> "this candidate has not started / is near deadline" back over the existing webhook channel?

| Answer | Scope implication |
|---|---|
| **A — Calling portal keeps candidate contact** (recommended; matches `03-ecosistema.md:53-59` and all of `04-integration-surface/`) | No PII added. C12 as proposed is complete. A future slice may add a `participant.stalled` / `participant.deadline_approaching` **webhook event type** reusing C10's delivery machinery end-to-end — days of work, zero new PII, zero new GDPR surface. |
| **B — BEAI stores candidate email and sends** | New migration adding PII to `participants`; retention/purge rule required **before** the column ships (blocks on decision #2); reminder cadence config on `projects` (blocks on decision #5); consent/lawful-basis question with the tenant; a candidate-facing email template set in ≥2 locales; the scheduler infra from D9 becomes mandatory, not optional. This is its own vertical slice, not a C12 sub-task. |

Answer A is recommended. Answer B is legitimate but must be planned as its own change with the
GDPR decision closed first.

## Capabilities

### New Capabilities

- **`notifications`** — operator-facing notification emission: trigger set, recipient
  resolution, idempotency, suppression, locale selection, delivery audit.

### Modified Capabilities

- **`webhooks-integration`** — the terminal `dead` status gains a notification emission point
  (discharging the obligation recorded at `webhooks-integration/proposal.md:145-147`).
- **`scoring-engine`** — `EvaluationFailed` (`api/app/Events/EvaluationFailed.php:23-30`) gains a
  notification emission point.
- **`tenancy`** — the queued-job arch guard extends to cover queued notifications (D2).

## Approach

### D1 — Recipients are organization users; candidates are unreachable by construction

Non-negotiable, and it is a schema fact, not a preference. Every C12 notification targets a
`User` row belonging to the organization that owns the failing entity.

**Which users.** Spatie seeds exactly three org roles — `admin`, `operator`, `viewer`
(`api/database/seeders/RolesAndPermissionsSeeder.php:48`). Proposed default: notify **`admin`
and `operator`**; exclude **`viewer`** (a read-only role should not be paged). Confirm in the
question round.

**The tenancy trap — and it is worse than the one the exploration flagged for `Participant`.**
`User extends Authenticatable` (`api/app/Models/User.php:30`), **not** `TenantModel`. There is
no global scope. A bare `User::role('admin')->get()` inside a queued job would return **every
admin of every tenant** and mail them another customer's failure. Every recipient query MUST
carry an explicit `->where('organization_id', $orgId)`. Spatie's `role()` filter *is*
team-scoped once inside `TenantContextScope::runFor()` (it calls
`setPermissionsTeamId($orgId)` — `api/app/Support/Tenancy/TenantContextScope.php:60`), but that
scopes the **pivot**, not the `users` table. Both filters, always. This gets a dedicated
cross-tenant test, per the `CrossTenantEvaluationIsolationTest` precedent.

### D2 — Laravel Notifications as renderers, plain queued job as the engine

This is the decision the task flagged, and the honest answer is **neither option wholesale**.

| Option | Verdict |
|---|---|
| **Laravel `Notification` + `mail` + `database` channels** | Rejected as a whole. The `database` channel needs Laravel's `notifications` table — **verified absent** (all 28 migrations listed; none is notification-related). It is polymorphic (`notifiable_type`/`notifiable_id`), has **no `organization_id`** and **no unique index**, and because `Illuminate\Notifications\DatabaseNotification` lives in the framework namespace it would slip past `api/tests/Arch/C2/TenantModelArchTest.php` (which globs `app/Models`) — an **un-tenant-scoped table that no guard catches**. Enabling it later, on top of our own log, would create two competing sources of truth. |
| **Plain queued `Mailable` only** | Rejected. Throws away `->locale()`, `Notification::fake()`, and any future channel for no gain over the hybrid. |
| **Hybrid (chosen)** | `Notification` classes are **pure renderers** — subject/body/locale, `via() = ['mail']`, **never `implements ShouldQueue`**. A single `App\Jobs\SendOperatorNotification` (or similar) owns the queue, the tenant context, the dedupe write, and calls `notifyNow()` / `Notification::sendNow()`. |

**Why the "never `ShouldQueue` on a Notification" rule is load-bearing, not style.**
`api/tests/Arch/Tenancy/QueuedJobTenantContextArchTest.php:33` globs `app/Jobs/*.php` only. A
queued Notification is wrapped by Laravel in `Illuminate\Notifications\SendQueuedNotifications`
— a framework class in a framework directory. It would **completely bypass the tenancy arch
guard**, run with the resolver reset to null by `Queue::before`, and any tenant-scoped write
inside it would throw `MissingTenantContextException` at `TenantScoped::creating` in production
while passing CI. Keeping the queue boundary inside `app/Jobs` keeps it inside the guard.

**C12 therefore extends the arch test** to also fail if any `app/Notifications/*.php` class
implements `ShouldQueue` — encoding the rule so a future author cannot silently reintroduce the
bypass. Same philosophy as the archived `queued-job-tenancy` D4.

**Tenancy contract the new job must satisfy** (all three verified):
1. Source literally contains `TenantContextScope::` or it fails
   `QueuedJobTenantContextArchTest.php:56`.
2. `$orgId` re-derived from a freshly-loaded DB aggregate inside `handle()` — never from the
   serialized payload, never from ambient resolver state (archived `queued-job-tenancy`
   proposal D2, `:64`).
3. One `runFor()` wrapper around the whole body, not one per write site
   (`ScoreEvaluationJob` precedent).

`NotificationLog` extends `TenantModel`, satisfying the blanket
`api/tests/Arch/C2/TenantModelArchTest.php` guard.

### D3 — Only two triggers. Selectivity is the feature.

A notification system that cries wolf gets muted, and then the one that mattered is missed.
Every candidate event in `api/app/Events/` was assessed:

| Event | Volume | Actionable by a human? | Verdict |
|---|---|---|---|
| **Webhook delivery reaches `dead`** (C10, `webhook_deliveries.status`, `2026_07_27_000001_create_webhook_deliveries_table.php:71`) | Rare — only after ~2.7 h / 6 attempts | **Yes** — the customer's integration is broken and their system has *not* received the evaluation. Needs someone to fix an endpoint and replay. | **NOTIFY** |
| **`EvaluationFailed`** (`api/app/Events/EvaluationFailed.php:23-30`) — job exhausted all retries, participant → `errore` | Rare | **Yes** — a candidate did the interview and has no result. Needs a human decision. | **NOTIFY** |
| **`EvaluationCompleted`** (`api/app/Events/EvaluationCompleted.php:25-33`) | **One per candidate** — a 500-candidate campaign is 500 emails | No. Nothing to do. | **Dashboard only (C11)** |
| **Evaluation terminal state `pending`** (below the 90 % gate, `CLAUDE.md`) | Potentially every candidate on a weak framework | Marginal — it is a *quality* signal, best seen aggregated | **Dashboard only (C11)** |
| **`ScoringRequested`** (`api/app/Events/ScoringRequested.php`) | One per candidate | No — pure internal plumbing | **Neither** |
| **Scoring stalled** (stuck in `in_valutazione`) | Rare, genuinely useful | Yes | **Deferred** — inherently time-triggered; needs the D9 scheduler. Revisit once infra lands. |

Both chosen triggers are **failures**, both are **rare**, both **require a human**. That is the
bar. Adding a third should require clearing the same bar.

### D4 — Idempotency: reuse the C10 pattern, not the C10 table

Reuse the **pattern**; a new table. `webhook_deliveries` carries webhook-specific columns
(`delivery_id`, `target_url`, `payload_version`, four CHECK constraints —
`2026_07_27_000001_create_webhook_deliveries_table.php:114-133`) that are meaningless for mail.

Transferred verbatim from `:102-105`:

- `UNIQUE(organization_id, notification_type, subject_type, subject_id)` as the **INSERT
  arbiter** — the DB, not application logic, decides whether this is the first time.
- **Write the row BEFORE the send** (`:15-16` "Written BEFORE the outbound HTTP call … the row —
  never the queue — is the single source of truth"), then mark `sent_at` after. A crash between
  insert and send loses one email; the inverse loses idempotency and double-sends. Losing an
  email is recoverable; double-sending erodes trust in the channel permanently.
- Catch `UniqueConstraintViolationException` on the racing INSERT and treat it as "already
  handled — do nothing" (same idiom as the `23505` handling already in `ScoreEvaluationJob`).
- `dedupe` columns **NOT NULL** — Postgres treats NULLs as distinct, which would silently
  disable the whole mechanism (`:23-25`, learned the hard way in C10).
- `attempt`/counter columns assigned from `$this->attempts()`, never incremented (`:26`).

This makes a duplicate send **impossible at the storage layer**, not merely unlikely — which is
the only standard worth holding a notification system to.

### D5 — Emission point: listeners on existing events

`EvaluationFailed` already exists and already fires. C10's dead-letter transition currently
emits "a log line + an observability counter" (`webhooks-integration/proposal.md:145`) — C12 adds
a listener, and if no domain event exists at that transition, C10's owner adds one rather than
C12 reaching into webhook internals. Listener → dispatch job → job establishes context, writes,
sends. No notification logic in C9 or C10 code paths.

### D6 — Storm suppression: config-driven window per `(org, type)`

D4 guarantees each *distinct* failure notifies once. It does **not** stop a provider outage from
producing one distinct failure per candidate — 200 emails, then a mail rule, then permanent
deafness.

Proposed: before sending, if a `notification_log` row for the same `(organization_id,
notification_type)` was sent inside the configured window, still **record** the occurrence
(audit + C11 count) but **suppress the send**, with an explicit `suppressed` status and reason —
directly mirroring C10's `skipped` + `skip_reason` design, which exists precisely so C11 can tell
"never happened" from "happened, not delivered"
(`webhooks-integration/proposal.md:321-324`). Every value in `config/notifications.php`, **none
hardcoded** — the same rule C10 adopted for its retry schedule (`:142-143`).

Default window: **15 minutes**. Flagged in the question round — the number is a product call.

### D7 — i18n: read the locale off the model, and add the column that is missing

The existing locale mechanism is HTTP-request-scoped (`?locale=` → `Accept-Language` →
`fallback_locale`, documented at `api/config/app.php:92-94`; `supported_locales => ['it','en']`
at `:97`). **There is no request inside a queued job.** The transferable pattern is
`ScoreEvaluationJob.php:286` — read the locale straight off the model.

**Gap found:** the `users` table has **no locale/language column**. Verified across both
migrations that define it — `0001_01_01_000000_create_users_table.php:14-22` (`name`, `email`,
`email_verified_at`, `password`, `rememberToken`, `timestamps`) and
`2026_07_16_200001_add_organization_id_to_users_table.php:21-33` (`organization_id`,
`is_superadmin`). Neither has one.

C12 therefore adds nullable `users.locale`, resolved as
`user.locale ?? config('app.fallback_locale')`, validated against `config('app.supported_locales')`,
and passed to the renderer via `Notification::locale()`. New namespace
`api/lang/{it,en}/notifications.php` — **currently only `messages.php` and `interview.php` exist
in each locale**; there is no outbound-copy namespace at all.

Per `CLAUDE.md`, machine-facing values (`notification_type`, status strings, log keys) are
**never** localized — only the human-readable subject and body are.

### D8 — Mail transport: fix local, defer production

Verified:
- `api/config/mail.php:17` — `'default' => env('MAIL_MAILER', 'log')`. Absent an env override,
  **all mail goes to the log file.**
- `docker-compose.yml:64-72` — a Mailpit service **is** defined (`axllent/mailpit:v1.22`,
  SMTP 1025, UI 8025).
- `docker-compose.yml:104-105` — the `api` service sets `MAIL_HOST: mailpit` and
  `MAIL_PORT: 1025` but **not `MAIL_MAILER`**.

Net effect: Mailpit runs, the api container points at it, and still writes to the log driver
unless `api/.env` sets `MAIL_MAILER=smtp`. *(`api/.env.example` could not be read — permission
denied — so whether the example file sets it is **unverified**; the design phase must check.)*
C12 sets `MAIL_MAILER: smtp` in the compose `api` environment block so local dev works out of
the box, and adds a `MAIL_FROM_ADDRESS` default.

**Production transport is a deployment decision, not a code one.** No SES/Postmark/Resend
credentials exist anywhere; the mailers in `config/mail.php:38+` are unfilled Laravel scaffold.
C12 ships transport-agnostic code and documents the required env vars. Someone must pick and
provision a provider before the first real email leaves.

### D9 — Infrastructure: C12 does NOT own it, and says so out loud

Both gaps independently re-verified for this proposal:

1. **No queue worker exists anywhere.** `rg -i 'queue:work|queue:listen|horizon|supervisor|schedule:run|withSchedule'` across the whole repo returns **only** documentation prose and one code comment (`api/app/Jobs/ScoreEvaluationJob.php:52` "Runs on Horizon" — aspirational, not true). `api/Dockerfile:75` is `CMD ["php","artisan","serve",...]` — the HTTP server and nothing else. `docker-compose.yml` defines no worker service. `laravel/horizon` is absent from `api/composer.json`.
2. **No scheduler kernel is registered.** `api/bootstrap/app.php` read in full (65 lines): `withRouting` / `withMiddleware` / `withExceptions` / `create()` — **no `->withSchedule()`**. A `schedule:run` cron would have nothing to run.

**Position: a separate infra change owns both.** They are pre-existing, repo-wide, and already
degrade **C9 and C10** exactly as much as C12 — fixing them inside C12 would mean C12 owning the
runtime characteristics of two other slices' jobs, and would blow the review budget on work
unrelated to notifications. Both C10 (`webhooks-integration/proposal.md:154-161`) and the
archived `queued-job-tenancy` change (`proposal.md:36-37`) reached the same conclusion
independently.

**Stated plainly, not buried: without that infra change, C12 ships code that cannot run in
production.** Queued notifications will sit in the `jobs` table forever. CI and the test suite
will be green — `QUEUE_CONNECTION=sync` executes jobs inline, which is *faithful* for the
`Queue::before` tenancy reset but says **nothing** about whether a worker exists. This is a
deployment blocker for C12, C9 and C10 alike, and the notification feature is the one that makes
it most visible: nobody notices a delayed webhook retry, everybody notices an alert that never
arrives.

**Design mitigation:** by scoping C12 to **event-triggered only** (D3), it needs the worker but
**not** the scheduler — one missing piece instead of two.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/database/migrations/*_create_notification_logs_table.php` | New | Tenant-scoped log; unique dedupe index (D4) |
| `api/database/migrations/*_add_locale_to_users_table.php` | New | Nullable `locale` (D7) |
| `api/app/Models/NotificationLog.php` | New | `extends TenantModel` (satisfies `TenantModelArchTest`) |
| `api/app/Jobs/*` (one dispatcher job) | New | `TenantContextScope::runFor()`; owns dedupe + send |
| `api/app/Notifications/*` (two classes) | New | Pure renderers; **never** `ShouldQueue` (D2) |
| `api/app/Listeners/*` | New | Bridge from `EvaluationFailed` + C10 dead-letter |
| `api/config/notifications.php` | New | Suppression window, recipient roles, from-address (D6) |
| `api/lang/{it,en}/notifications.php` | New | Outbound copy; first such namespace |
| `api/app/Models/User.php` | Modified | `locale` cast/fillable; already has `Notifiable` (`:33`) |
| `api/tests/Arch/Tenancy/QueuedJobTenantContextArchTest.php` | Modified | Extend to `app/Notifications/*` (D2) |
| `docker-compose.yml` | Modified | `MAIL_MAILER: smtp` + `MAIL_FROM_ADDRESS` on `api` (D8) |
| `openspec/specs/notifications/spec.md` | New | New capability |
| `openspec/specs/{webhooks-integration,scoring-engine,tenancy}/spec.md` | Modified | Emission points + arch guard |

**Concurrency note:** C10 is in flight on `api/` and C11 tasks are being written. C12 touches
C10's dead-letter path only through a listener on an event C10 owns — the emission point must be
agreed with C10 rather than assumed, and C12's branch should be cut after C10 merges to
`api/develop`.

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| No queue worker → notifications never send in a real environment | **CRITICAL** | D9. Separate infra change; must land before C12 is deployed. Not a C12 code defect. |
| Cross-tenant leak via unscoped `User` query — `User` is **not** a `TenantModel` (`api/app/Models/User.php:30`) and mailing the wrong tenant is an unrecoverable disclosure | **CRITICAL** | D1: mandatory explicit `->where('organization_id', $orgId)` **plus** Spatie team scope; dedicated cross-tenant test per the `CrossTenantEvaluationIsolationTest` precedent. |
| A queued `Notification` bypasses `QueuedJobTenantContextArchTest` (globs `app/Jobs` only) and fails only in production | **HIGH** | D2: notifications never `ShouldQueue`; arch test extended to enforce it. |
| Duplicate sends from queue retries or duplicate event emission | **HIGH** | D4: DB-level unique dedupe index; write-before-send; catch the racing INSERT. |
| Notification storm during a provider outage → channel gets muted | **HIGH** | D6: config-driven `(org, type)` suppression window with an auditable `suppressed` status. |
| FR-002 "invitations / reminders" not delivered — a visible charter gap | **HIGH** | Blocked non-goal section: exact client question + scope implications of each answer. Must be raised, not silently carried. |
| Production mail transport undecided; no credentials exist anywhere | **MEDIUM** | D8: transport-agnostic code + documented env vars; provisioning is a deployment task with a named owner. |
| `api/.env.example` unreadable (permission denied) — local `MAIL_MAILER` state unverified | **LOW** | Design phase must open it; D8 sets the value in compose regardless. |
| C10 in flight — the dead-letter emission point may move | **MEDIUM** | Agree the event contract with C10's owner; cut the C12 branch after C10 merges. |
| `users.locale` absent → all operator mail defaults to `en` until backfilled | **LOW** | D7 adds the column; backoffice exposure of the preference is a C11/C13 concern. |

## Rollback Plan

Single feature branch on the `api` submodule plus one `docker-compose.yml` line in the wrapper.
Two additive migrations (`notification_logs`, `users.locale`) — both with working `down()`, no
data transformation, no destructive change to any existing table. Rollback = `git revert` of the
PR merge commit(s) on `api/develop`, `migrate:rollback` of the two migrations, and reset of the
wrapper submodule pointer. Listeners are the only touch-point on C9/C10 code paths; reverting
them restores today's log-only behavior exactly.

## Dependencies

- **C6 `participant-sso`** — `ROADMAP.md:45` dependency; supplies the `Participant` model and the
  explicit `Notifications (C12)` non-goal (`specs/participant-sso/spec.md:21`).
- **C9 `scoring-engine`** — supplies `EvaluationFailed` (`api/app/Events/EvaluationFailed.php`).
- **C10 `webhooks-integration`** — supplies the dead-letter transition and the ratified
  obligation (`proposal.md:145-147`, `:334`). **In flight** — coordinate.
- **C2 `tenancy`** — supplies `TenantContextScope`, `TenantModel`, `TenantScoped`, and both arch
  tests.
- **Queue-worker infra change (does not yet exist)** — **deployment blocker**, not a build
  blocker (D9).
- **No new Composer packages** — Notifications and Mail ship with the framework; D37 Dependency
  Resolution Policy untouched.

## Success Criteria

- [ ] A dead-lettered webhook delivery produces exactly one notification to the owning
      organization's `admin` + `operator` users, and a `notification_log` row.
- [ ] `EvaluationFailed` produces exactly one notification, same shape.
- [ ] Re-firing the same event N times produces **one** email and **one** log row — proven by a
      test that dispatches twice and asserts the unique-index arbitration, not by application
      logic alone.
- [ ] A hostile-context test (ambient resolver holding a **foreign** org, and again holding
      **null**) proves recipients and log rows carry the **aggregate's** `organization_id`.
- [ ] A cross-tenant test proves org B's staff receive **nothing** when org A's delivery dies.
- [ ] Notifications are dispatched through the dispatcher (`::dispatch()`), never `->handle()`,
      so `Queue::before` fires — per the archived `queued-job-tenancy` D4.
- [ ] The arch test **fails** if a new `app/Notifications/*` class implements `ShouldQueue`.
- [ ] The arch test **fails** if the new job omits `TenantContextScope::`.
- [ ] Recipient with `locale = 'it'` receives Italian copy; `locale = null` receives
      `fallback_locale`; `notification_type` and status strings are **not** localized.
- [ ] Exceeding the suppression window records a `suppressed` row and sends **no** email,
      distinguishable from "never occurred".
- [ ] `EvaluationCompleted` produces **no** notification (asserted explicitly — the anti-spam
      invariant must be a test, not a comment).
- [ ] New files: 0 PHPStan L8 errors; tenant-scoping coverage ~95 %; overall ≥ 85 %.

## Proposal question round

Written here because this executor cannot query the user directly. These shape the PRD, not the
harness. Assumptions taken as stated — correct any before spec.

1. **Candidate invitations/reminders — the central scope call.** Assumed **answer A**: the
   calling portal remains the only system that contacts candidates; BEAI stores no candidate
   contact details, and FR-002's "invitations/reminders" is satisfied by the caller. Confirm, or
   choose B and accept it as a separate slice gated on GDPR decision #2. *(This single answer
   determines roughly half of C12's scope.)*
2. **Who gets paged.** Assumed `admin` + `operator`, excluding `viewer`
   (`RolesAndPermissionsSeeder.php:48`). Should it instead be `admin` only, or a per-user opt-in
   preference — and if opt-in, does that preference belong in C12 or C11's settings UI?
3. **Trigger set.** Assumed exactly two — dead-lettered webhook and catastrophic scoring failure
   — with `EvaluationCompleted` deliberately excluded as per-candidate noise. Is there an
   operational event we have wrongly classified as dashboard-only? Conversely: is a *successful*
   completion notification actually wanted for low-volume tenants (which would imply a
   per-project toggle, not a global one)?
4. **Storm suppression window.** Assumed 15 minutes per `(org, type)`, config-driven, with
   suppressed occurrences still recorded. Is silence-after-the-first during an outage acceptable,
   or should a digest ("47 further failures in the last hour") be sent when the window closes?
   A digest is more useful and materially more work.
5. **Deployment reality.** Assumed the queue-worker infra change is scheduled **before** C12
   deploys. If it is not, C12 should be built and merged but explicitly marked
   *not-deployable* — confirm that is acceptable rather than deferring C12 entirely.
6. **Scoring-stalled detection.** Assumed **deferred** (time-triggered, needs the scheduler). If
   "a candidate has been stuck in `in_valutazione` for hours and nobody knows" is a real
   operational pain today, that raises the priority of the scheduler infra work above C12 itself.
