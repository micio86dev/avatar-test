# Proposal: Self-Service Password Reset

## Intent

A backoffice user who forgets their password today has **exactly one** recovery path:
`beai:reset-user-password`, run over `railway ssh` by someone with production shell access.
That is a break-glass tool being used as a product feature. Every forgotten password is an
escalation to an engineer, the credential travels back to the user over whatever channel they
happen to share, and a user with no engineer available is simply locked out.

This was a **deliberate, ratified decision** — not an oversight.
`openspec/changes/archive/2026-08-18-admin-password-reset` shipped CLI-only under D2, and
`openspec/specs/password-recovery/spec.md:106-112` records the reason as a **Non-Goal**:
production had no mail configuration on either the `api` or the `worker` service, so
`api/config/mail.php:17` fell back to `log` and a reset email would have been written to a
container filesystem nobody reads. The archived proposal's own Open Question #3 —
*"Is production mail actually deliverable?"* — was the gate.

**What changed.** `beai:mail-selftest` (`api/app/Console/Commands/MailSelfTestCommand.php`)
now exists: a live round-trip probe that **refuses to report success on a `log` or `array`
transport**, proven working locally against Mailpit. Railway `api` and `worker` both carry
`MAIL_FROM_ADDRESS=noreply@quint.org`, `MAIL_FROM_NAME=BEAI` and a `RESEND_API_KEY`
placeholder. The gate is no longer unanswerable — it is **measurable**, and there is now a
command that answers it honestly.

**What has NOT changed.** `quint.org` is **not yet verified in Resend**, `RESEND_API_KEY` is
empty, and `MAIL_MAILER` is still deliberately unset on both services. The spec's gate is
*"proven to deliver on BOTH services"*, and that is **not yet satisfied**. This proposal is
therefore written *against* a gate it does not yet pass — see `## Dependencies`, where it is a
**hard ship gate**, not a footnote.

Success = a locked-out operator recovers alone, in their own language, without an engineer,
and every session they held is dead the moment they do.

---

## AD-1 — The archived CLI-only decision is OVERTURNED; the CLI command STAYS

**Choice.** Add the HTTP self-service flow **and keep `ResetUserPasswordCommand` unchanged in
purpose**. `password-recovery`'s first Non-Goal is deleted and replaced by the requirements
this change introduces; the change must **say plainly** that it reverses D2 of
`archive/2026-08-18-admin-password-reset`, and why: the blocker was *deliverability*, and
deliverability is now provable (`beai:mail-selftest`) even though it is not yet proven.

**Why not option (a), delete the CLI once email ships.** The CLI is the **break-glass path for
the case where mail itself is broken** — an expired Resend key, an unverified domain, a
provider outage. Deleting it would make a mail outage an *unrecoverable* lockout, converting a
degraded dependency into a total one. The email flow is the product path; the CLI is the floor
under it. Two paths is the design, not duplication.

**Why not option (b), silently add the endpoint and leave the Non-Goal text standing.** A spec
whose Non-Goals contradict its own Requirements stops being a source of truth. The archived
decision was correct **on the facts it had**; overturning it is legitimate only if the record
says which fact changed.

## AD-2 — Laravel's `Password` broker, not hand-rolled tokens

**Choice.** Use `Password::broker()` / `sendResetLink()` / `reset()`. The table already exists
(`api/database/migrations/0001_01_01_000000_create_users_table.php:24-28`), the broker is
already configured (`api/config/auth.php:118-125`, `expire => 60` min, `throttle => 60` s),
`User` already uses `Notifiable` and inherits `CanResetPassword`, so
`sendPasswordResetNotification()` already exists. **Not one line of this machinery is
currently used** — there is no `Password::` call anywhere in the repo. This change turns on
infrastructure that has been sitting inert since the framework skeleton landed.

**Why not option (a), a hand-rolled token table.** It would reimplement hashing-at-rest,
single-use consumption, expiry and throttling — four security-critical behaviours the
framework already ships, tested, with the exact semantics D3 of the archived proposal
prescribed (*single-use, short TTL, hashed at rest*). Rewriting them buys nothing and puts a
bespoke credential primitive in the blast radius.

**Why not option (b), reuse the candidate magic-link JWT.** The candidate link is a
**stateless, short-lived JWT** bound to the candidate guard (`identity-auth:496`, Candidate
Guard Isolation). A stateless token **cannot be made single-use** without a denylist, and
crossing the candidate/user guard boundary for a backoffice credential is precisely the
isolation that spec exists to protect.

## AD-3 — One response for every email — and the timing channel is CLOSED, not accepted

**Choice.** `POST /api/auth/forgot-password` returns an **identical** response — same status,
same body, same headers — for an existing user, a non-existent email, and a **deactivated**
user (which `AuthController::login` already refuses indistinguishably,
`api/app/Http/Controllers/Auth/AuthController.php:70-77`). Anti-enumeration is already
established in three layers here: the controller, `AuthControllerTest.php:107,117`, and
`backoffice/app/pages/login.vue:47-54`, which states in a comment that the form must not
become an enumeration oracle. This endpoint joins that contract.

**The timing channel is the load-bearing part.** Login has a known, untested timing side
channel (the unknown-email path skips `Hash::check`). A reset endpoint would be **far worse**:
the existing-user branch performs a token write **plus a live SMTP/Resend round trip** —
hundreds of milliseconds — while the unknown-email branch returns immediately. That is not a
subtle statistical channel; it is a stopwatch. The fix is structural: the controller
**dispatches a queued job and returns**, so token creation, broker throttling and the send all
happen off-request. The response time is then governed by the dispatch, not by whether the
user exists.

**Why not option (a), accept the timing gap as we do on login.** Login's gap is one bcrypt
comparison. This one is a network round trip — two to three orders of magnitude larger, and
observable without statistics.

**Why not option (b), constant-time padding in the request.** Padding to the slowest branch
makes **every** caller wait for a mail round trip, turns provider latency into user-visible
latency, and is still only as good as the chosen pad. Moving the work off-request removes the
signal instead of masking it.

**Consequence, stated up front:** off-request sending makes the **worker** service part of
this feature's critical path. See `## Dependencies`.

## AD-4 — A reset revokes refresh-token families; `password_changed_at` alone is NOT enough

**Choice.** A completed reset MUST (1) stamp `password_changed_at` with
`now()->startOfSecond()` — matching every existing writer, because `RejectStaleCredentials`
compares with a strict `<` against a second-precision `iat` — **and** (2) revoke **every**
refresh-token family the user holds.

**The gap is concrete.** `POST /api/auth/refresh` runs **outside** `auth:api` *and* outside
`RejectStaleCredentials` — deliberately, and load-bearing (`api/routes/api.php:57-76`, D8: an
expired access token is exactly when refresh must still work). So `password_changed_at`, the
mechanism `identity-auth:216-238` relies on, **is never consulted on the refresh path**. A
stolen refresh cookie therefore survives a password reset and mints fresh access tokens.
Revocation closes it: `RefreshTokenStore::rotate()` already refuses a revoked row
(`RefreshTokenStore.php:97`), which is what makes logout work.

**A verified detail for `sdd-design`:** the existing `revokeFamily(string $familyId)` is
**family-scoped and insufficient here**. A reset has no session and therefore no `fam` claim,
and a user holds one family **per login** (`issue()` mints a new `familyId` each time). This
needs a **user-scoped** revocation (`revokeAllForUser(int $userId)`), not a reuse of
`revokeFamily()`.

**Why not option (a), rely on `password_changed_at` alone.** It provably does not cover the
one endpoint that matters. Consistency with the CLI is not a defence — the CLI has the same
hole today.

**Why not option (b), fix it by putting `RejectStaleCredentials` on `/api/auth/refresh`.** That
re-breaks D8's second fix for the operator's *"logged out constantly"* complaint, in a change
that has nothing to do with session refresh. Wrong change, wrong risk.

**Therefore `ResetUserPasswordCommand` gains the same revocation call.** Not scope creep: the
spec requirement is *"an out-of-session reset invalidates prior sessions"*, and two paths that
answer it differently is the divergence this proposal exists to prevent.

## AD-5 — The reset link is built from `services.backoffice_origin`, and it FAILS LOUDLY when unset

**Choice.** Build the link from `config('services.backoffice_origin')`
(`api/config/services.php:19`, env `BACKOFFICE_ORIGIN`). When it is empty, invalid, or a
wildcard, the flow **refuses to send** and logs — it does **not** emit a mail carrying a broken
link.

**`BACKOFFICE_URL` does not exist.** Verified: the only backoffice-origin config in the repo is
`services.backoffice_origin`. Introducing a second variable naming the same thing would create
two sources of truth for one URL, and a deployment where they disagree ships working CSP with
broken emails — or the reverse.

**Why not option (a), a new dedicated `PASSWORD_RESET_URL`.** Same objection; and the value is
already required to be a *"non-empty, non-wildcard explicit HTTPS origin"* for CSP
(`SecurityHeaders.php:102-121`), which is exactly the validation a reset link needs.

**Why not option (b), degrade to a relative or best-guess URL when unset.** A reset mail whose
link goes nowhere is worse than no mail: the user believes recovery is in progress and stops
looking for another route. `SecurityHeaders` already chose *safe default over guess* for this
same value; this follows it.

## AD-6 — Publish and theme Laravel's markdown mail views

**Choice.** `vendor:publish --tag=laravel-mail` into `resources/views/vendor/mail/**` and theme
the published `html/themes/default.css` with the Quint tokens from the authoritative
`DESIGN.md` — `--color-primary #771AAF`, `--color-accent #E45526`. Constraints, all
non-negotiable: **table layout**, **no remote images**, **useful with CSS stripped entirely**,
and the **full URL as plain text below the button**.

Two facts make this a real decision rather than a default: `resources/views/vendor/mail/**` is
**not currently published**, and the repo contains **zero application Blade** — the API is
API-only, no Blade UI. This change introduces the first Blade in the codebase, which is worth
saying out loud rather than discovering at review.

**Why not option (a), a hand-written standalone Blade view.** Email HTML is a compatibility
minefield (Outlook's Word renderer, Gmail's CSS stripping, dark-mode inversion). Laravel's
published theme is battle-tested table markup with an inliner already wired; hand-rolling it
means re-learning those lessons in production, on the one message a locked-out user must be
able to read.

**Why not option (b), an unstyled plain-text-only mail.** Plain text is the **fallback**, and
it MUST be present and complete. As the only format it makes a security-sensitive message
indistinguishable from spam, and the product is brand-facing.

## AD-7 — Both new public routes carry an inline `throttle`, per the existing convention

**Choice.** `/api/auth/*` is currently **entirely unthrottled** — login included. The house
convention is an inline `throttle:N,1` **with a comment naming the abuse primitive**
(`api/routes/api.php:107,110,156,158`; `/profile/password` carries `throttle:6,1` because
without it the endpoint is a current-password oracle). Both new routes adopt it:

| Route | Abuse primitive being priced |
|---|---|
| `POST /api/auth/forgot-password` | Unauthenticated, with a side effect on **another person's inbox** — a mail-bomb and a cost primitive. Must be keyed on **both** IP and the submitted email, per the archived D5. |
| `POST /api/auth/reset-password` | Unauthenticated token submission — a brute-force surface against the token itself. |

Laravel's broker throttle (`config/auth.php:123`, 60 s) is **per-user, not per-caller**, and
under AD-3 it now runs inside the queued job. It cannot price an HTTP endpoint, and it must not
be mistaken for the route throttle.

**Why not option (a), throttle the whole `/api/auth` prefix in this change.** Adding a throttle
to `login` and `refresh` is a behaviour change to the session-hardening work (`refresh` is
called by `00.auth-bootstrap.client.ts` on **every** cold load) and belongs to its own change,
with its own verification. Named as an explicit non-goal, not forgotten.

**Why not option (b), a named RateLimiter in `AppServiceProvider`.** Cleaner in the abstract,
inconsistent with four existing call sites here. `sdd-design` picks the numbers; the *shape*
follows the convention.

## AD-8 — The reset mail is NOT a C12 `notifications` trigger

**Choice.** The reset mail is a **user-initiated transactional message**, delivered through
Laravel's mail abstraction. It does **not** enter the C12 pipeline:
`SendOperatorNotificationJob`, `notification_logs`, org-scoped recipient resolution, dedupe or
storm suppression. `openspec/specs/notifications/spec.md` appears in **no delta**.

That spec's first requirement is literally *"Trigger Set Is Exactly Two Events"*
(`notifications/spec.md:23-31`), and it says a third trigger *"requires the same 'rare,
actionable by a human' justification as the first two — it is not a configuration toggle"*. A
password reset is **neither rare nor operator-facing**: it is a self-service action by the
recipient themselves. Filing it as a third trigger would dissolve a deliberately narrow
invariant to reuse plumbing designed for a different problem — org-scoped alerting for a
**tenant's** operators.

**Two C12 constraints still bind, because they are repo-wide, not capability-scoped:**

1. `NotificationNeverQueuedArchTest` forbids **any** class under `app/Notifications/` from
   implementing `ShouldQueue` — **no allowlist**. The reset notification is therefore a
   non-queued renderer; the queue boundary lives in the dispatching job that calls it (the
   `SendOperatorNotificationJob` **shape**, not its pipeline). AD-3 needs that job anyway.
2. Local mail must reach Mailpit, not the `log` driver (`notifications/spec.md:239-257`).

**Why not option (a), route it through `SendOperatorNotificationJob`.** It resolves recipients
by org and role and dedupes per `(org, type)`. A reset targets **one specific user**, possibly
a platform superadmin with `organization_id IS NULL` — a shape that pipeline cannot express,
and the same `NOT NULL` tenancy wall the CLI already documents at `recordAudit()`.

**Why not option (b), record it in `notification_logs` "for the audit trail".** That table is
tenant-scoped operator alerting. The reset's audit trail belongs where the CLI already puts
it: `audit_logs`, via `AuditRecorder`, action `user.password_reset`.

---

## Scope

### In Scope

| # | Deliverable | Repo |
|---|---|---|
| 1 | `POST /api/auth/forgot-password` — generic response, dispatches the send job (AD-2, AD-3) | `api` |
| 2 | `POST /api/auth/reset-password` — token + new password; sets `password_changed_at`, revokes refresh families, transactional (AD-2, AD-4) | `api` |
| 3 | Queued dispatcher job wrapping `Password::sendResetLink()`; non-queued notification renderer (AD-3, AD-8) | `api` |
| 4 | `RefreshTokenStore::revokeAllForUser()` — user-scoped, not family-scoped (AD-4) | `api` |
| 5 | `ResetUserPasswordCommand` calls the same revocation, inside the existing transaction (AD-4) | `api` |
| 6 | Published + Quint-themed mail views; plain-text part; URL below the button (AD-6) | `api` |
| 7 | Reset-link builder over `services.backoffice_origin`, refusing to send when unset (AD-5) | `api` |
| 8 | Inline `throttle` on both routes, keyed on IP **and** email for forgot-password (AD-7) | `api` |
| 9 | `it`/`en` mail copy, locale from the target user (mandatory i18n) | `api` |
| 10 | Forgot-password affordance on `login.vue`, with copy that does not leak existence | `backoffice` |
| 11 | Public `/reset-password/{token}` page + generic "check your inbox" confirmation | `backoffice` |
| 12 | **`PUBLIC_PATHS` matching fix** in `02.auth.global.ts` (see below) | `backoffice` |
| 13 | `password-recovery` spec: the self-service Non-Goal deleted and replaced (AD-1) | wrapper |
| 14 | Runbook: which path to use when, and what a mail outage means | wrapper |

**Deliverable 12 is a live bug, not a nicety.** `backoffice/app/middleware/02.auth.global.ts:31`
declares `PUBLIC_PATHS = ['/unsupported', '/login', '/health']` and matches with
`to.path.endsWith(path)` (line 34). `/reset-password/{token}` **ends with the token**, so it can
never match — a locked-out user clicking their link is bounced to `/login`. Any fix must
preserve the existing suffix semantics the middleware's own comment relies on.

### Out of Scope — explicit non-goals

- **Throttling `login`, `refresh`, `logout`, `me`** — the rest of `/api/auth` stays as it is
  today (AD-7). Its own change.
- **Closing login's bcrypt timing gap** — pre-existing, untested, unchanged here. AD-3 covers
  only the new endpoint.
- **Putting `RejectStaleCredentials` on `/api/auth/refresh`** — explicitly rejected (AD-4).
- **A third `notifications` trigger, or any `notification_logs` row** — AD-8;
  `openspec/specs/notifications/spec.md` must appear in **no** delta.
- **Candidate-facing reset** — candidates authenticate by magic link and have no password.
  BEAI holds no candidate contact data (ratified decision #8).
- **Deleting or deprecating `ResetUserPasswordCommand`** — AD-1.
- **Email verification, password-strength policy changes, 2FA, "log out my other devices"** —
  adjacent, separately justifiable.
- **Selecting or provisioning the production mail transport** — a deployment decision
  (`notifications/spec.md:309`). This change **consumes** it; see `## Dependencies`.
- **`00.auth-bootstrap.client.ts`'s cold-load refresh** — a public reset page still pays one
  `POST /api/auth/refresh`. Noted as a `## Risks` item, **not** fixed here: touching the
  bootstrap plugin is session-refresh work.

## Capabilities

### New Capabilities

None. `password-recovery` already exists; this change **reverses one of its Non-Goals** rather
than introducing a capability beside it.

### Modified Capabilities

- `password-recovery`: gains the HTTP self-service flow — broker-backed single-use token,
  identical response for every email, off-request send, `backoffice_origin`-derived link that
  fails loudly, both route throttles. The **self-service Non-Goal (`spec.md:106-112`) is
  deleted and its reversal recorded**, and the CLI requirements stay in force (AD-1).
- `identity-auth`: *"Out-of-Session Password Reset Invalidates Prior Sessions"*
  (`spec.md:216-238`) widens from `password_changed_at` alone to **`password_changed_at` +
  user-scoped refresh-family revocation**, with the `/api/auth/refresh` bypass named
  explicitly; two new public routes join the auth surface with stated throttles.
- `admin-backoffice`: a forgot-password affordance on the login page, a public
  `/reset-password/{token}` route, and the corrected `PUBLIC_PATHS` predicate.

## Approach

**Switch on machinery that is already installed, then close the two holes it does not cover.**
Deliverables 1–3 are mostly configuration and wiring: the table, the broker, `Notifiable` and
`CanResetPassword` all exist and are unused. The genuinely new engineering is small and
specific — a user-scoped revocation method (AD-4), a link builder that refuses to guess
(AD-5), and the first Blade in the repo (AD-6).

Ordering: **revocation + `identity-auth` delta → API flow → mail template → backoffice**. The
revocation lands first because the CLI shares it (AD-4) and it is verifiable with no HTTP
surface at all. The backoffice lands last because it consumes the regenerated typed client, and
because deliverable 12's guard fix is worthless before a page exists to reach.

Strict TDD per `openspec/config.yaml` (`strict_tdd: true`): every RED precedes its GREEN.
Anti-enumeration and session revocation are correctness-critical (~95%): the enumeration
assertions must cover **all three** cases — existing, unknown, **deactivated** — and
byte-compare the responses, not merely the status codes.

## Size and Delivery

- `Chained PRs recommended: Yes`
- `400-line budget risk: High`
- `Decision needed before apply: Yes` — the question round below gates the throttle numbers,
  the token TTL, and the deactivated-user semantics; `## Dependencies` gates **shipping** on
  `beai:mail-selftest`.

Natural slices, each independently revertable and verifiable:
**P1** revocation + `identity-auth` delta + CLI parity ·
**P2** the two endpoints + broker wiring + anti-enumeration tests ·
**P3** mail views, theming, i18n copy, link builder ·
**P4** backoffice login affordance + reset page + `PUBLIC_PATHS` fix + typed-client regen.

P4 must land `api` before `backoffice`. **P1 ships alone and is useful alone** — it fixes a
real session-survival hole in the CLI path that exists today, with or without the email flow.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/routes/api.php` (auth block, :68-76) | Modified | Two public routes + inline `throttle` with abuse-primitive comments |
| `api/app/Http/Controllers/Auth/ForgotPasswordController.php` | New | Generic response, dispatch-and-return (AD-3) |
| `api/app/Http/Controllers/Auth/ResetPasswordController.php` | New | Token consumption, password write, revocation (AD-2, AD-4) |
| `api/app/Http/Requests/**` | New | Validation that cannot leak existence via field errors |
| `api/app/Jobs/SendPasswordResetLinkJob.php` | New | Off-request broker call — the queue boundary (AD-3, AD-8) |
| `api/app/Notifications/ResetPasswordNotification.php` | New | Non-queued renderer; must NOT implement `ShouldQueue` |
| `api/resources/views/vendor/mail/**` | New | First Blade in the repo; published + Quint-themed (AD-6) |
| `api/app/Support/Auth/RefreshTokenStore.php` | Modified | `revokeAllForUser()` — user-scoped, new (AD-4) |
| `api/app/Console/Commands/ResetUserPasswordCommand.php` | Modified | Same revocation, inside the existing transaction (AD-4) |
| `api/config/auth.php` | Modified | Broker `expire` / `throttle` reviewed against the ratified TTL |
| `api/lang/{en,it}/**` | Modified | Mail subject + body copy |
| `api/tests/**` | New | Enumeration byte-equality, timing, revocation, throttle, unset-origin refusal |
| `backoffice/app/pages/login.vue` | Modified | Forgot-password affordance; existing enumeration copy preserved |
| `backoffice/app/pages/reset-password/[token].vue` | New | Public reset page |
| `backoffice/app/middleware/02.auth.global.ts` | Modified | `PUBLIC_PATHS` predicate fix (deliverable 12) |
| `backoffice/i18n/locales/{en,it}.json` | Modified | Page + affordance copy |
| `backoffice/tests/**`, `backoffice/e2e/**` | New | Guard-fix unit test; happy-path E2E on Chromium + WebKit |
| `openspec/specs/password-recovery/spec.md` | Modified | Non-Goal deleted; self-service requirements added (AD-1) |
| `openspec/specs/identity-auth/spec.md` | Modified | Revocation requirement widened (AD-4) |
| `openspec/specs/notifications/spec.md` | **Unchanged** | AD-8 — a delta here would be the bug, not the fix |
| `api/app/Jobs/SendOperatorNotificationJob.php`, `notification_logs` | **Unchanged** | AD-8 — different pipeline, different problem |
| `api/app/Http/Middleware/RejectStaleCredentials.php` | **Unchanged** | The strict `<` / second-precision contract is inherited, never tightened |
| `AuthController::login` / `refresh` / `logout` / `me` | **Unchanged** | No throttle, no timing change — explicit non-goal (AD-7) |
| `backoffice/app/plugins/00.auth-bootstrap.client.ts` | **Unchanged** | Session-refresh work; the wasted cold-load refresh is a stated risk |
| `api/app/Policies/UserPolicy.php` | **Unchanged** | No authorization surface here — the actor is unauthenticated by definition |
| `participants` / candidate guard | **Unchanged** | Candidates have no password and no contact column |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Ships before mail actually delivers → a button that silently does nothing (the exact failure the archived D2 predicted) | **High** | `## Dependencies` makes `beai:mail-selftest` green on **both** services a hard ship gate; AD-5 makes a misconfigured origin refuse rather than send |
| The queued job silently fails on the `worker` service while `api` looks healthy | **High** | AD-3 puts the worker on the critical path deliberately; the gate requires the selftest on **both**; job failure must be loud, never swallowed |
| The enumeration oracle reappears via a differing field error, header, or status | **High** | Byte-equality assertions across existing / unknown / **deactivated**; the deactivated case is the one most likely to be forgotten |
| Refresh-family revocation is scoped to one family, leaving other devices alive | **High** | AD-4 names it explicitly: `revokeFamily()` is insufficient; the new method is user-scoped and asserted with a **two-family** fixture |
| `PUBLIC_PATHS` fix widens the guard and exposes an authenticated route | Med | Suffix semantics preserved; a unit test asserts a token-bearing path passes **and** that no authenticated path newly matches |
| First Blade in an API-only repo drifts into a UI layer | Med | Scoped to `resources/views/vendor/mail/**`; no route renders a view; the API stays API-only |
| A reset mail lands in spam and the user assumes recovery is broken | Med | Verified `quint.org` sender (part of the gate); plain-text part; copy sets expectations about the inbox |
| Throttle numbers invented here contradict a future `nfr-hardening` policy | Med | Inline convention + comment, matching four existing call sites; a future policy change relocates them in one place |
| The public reset page pays a pointless `POST /api/auth/refresh` on cold load | Low | Accepted and documented; harmless (no cookie → no session), and fixing it means touching session-refresh work |
| Token TTL (60 min) proves too long or too short in practice | Low | Config-driven; the value is a question-round item, not a hardcode |

## Rollback Plan

Per-slice, feature branch, no deploy.

- **P4:** `git revert` in `backoffice`. The login page loses the affordance; the reset page
  disappears. **Revert P4 before P2** — leaving a live endpoint with no UI is harmless, but a
  UI pointing at a reverted endpoint is a dead end for a locked-out user.
- **P3:** `git revert`. The published `vendor/mail` views are additive; removing them restores
  the framework defaults.
- **P2:** `git revert`. Both routes vanish; `password_reset_tokens` may hold unconsumed rows —
  **leave them**, they expire on their own (`config/auth.php:122`) and are hashed at rest.
- **P1:** `git revert` restores `password_changed_at`-only revocation. **No migration, no
  schema change, no data precondition** — `refresh_tokens` rows already revoked stay revoked
  (correct: those users simply log in again).
- Reverse ship order on rollback: **P4 → P3 → P2 → P1**.
- Wrapper submodule pointers revert to their previous pinned commits.
- **Recovery is never lost at any point in a rollback**: `beai:reset-user-password` is
  untouched by every step except P1's one-line addition. That is AD-1's whole argument.

## Dependencies

**HARD SHIP GATE — this feature MUST NOT reach production until all three hold:**

1. `quint.org` (or the chosen sender domain) is **verified in Resend**.
2. `RESEND_API_KEY` is populated **and** `MAIL_MAILER=resend` is set on **both** the `api`
   **and** `worker` Railway services. Today `MAIL_MAILER` is deliberately unset on both —
   setting it before the key exists converts silent non-delivery into loud queue failures.
3. `php artisan beai:mail-selftest --to=<real inbox>` exits **0 on BOTH services**, and the
   message is confirmed in a real inbox — *"accepted by the API is not the same as landed in an
   inbox"*, per the command's own warning.

This is the same gate `password-recovery/spec.md:112` already sets (*"deferred until mail is
configured and proven to deliver on both services"*). This proposal does **not** weaken it; it
makes it **checkable** and moves it from a Non-Goal to a release precondition. **The gate does
not block writing the specs, the design, or the code** — CI proves correctness with
`mail.default=array` (`phpunit.xml`) exactly as C12 already does. It blocks **shipping**.

Other dependencies:

- **A running queue worker** (`queue-runtime`). AD-3 puts it on the critical path. It exists;
  `notifications/spec.md:268-288` documents that CI's `sync` connection proves correctness, not
  deployability.
- **`BACKOFFICE_ORIGIN` set on the `api` service** — AD-5. Already required for CSP.
- **`archive/2026-08-18-admin-password-reset`** — its ratified decision is a **constraint being
  overturned**, not a blocker. AD-1 records the reversal.
- **Ratified decision #8 (BEAI holds no candidate contact data)** — a constraint, preserved by
  construction: this flow touches `users` only.

## Success Criteria

- [ ] `beai:mail-selftest` exits 0 on **both** the `api` and `worker` Railway services, confirmed in a real inbox, **before** this feature is enabled in production.
- [ ] A user who forgot their password recovers **without any engineer involvement**, in `it` and in `en`.
- [ ] `POST /api/auth/forgot-password` returns a **byte-identical** response for an existing user, an unknown email, and a deactivated user — asserted for all three.
- [ ] The response time for the unknown-email case is not systematically distinguishable from the existing-user case; no mail round trip happens in the request (AD-3).
- [ ] A reset token is single-use, expires per the ratified TTL, is hashed at rest, and a second use is refused.
- [ ] After a reset, every access token minted before it is rejected **and** every refresh family the user held is revoked — proven with a **two-family, two-device** fixture, including a `POST /api/auth/refresh` attempt that fails.
- [ ] `ResetUserPasswordCommand` and the HTTP flow produce the **same** session-revocation outcome, asserted by parallel tests.
- [ ] With `BACKOFFICE_ORIGIN` unset, no mail is sent and the refusal is logged — no mail carrying a broken link exists in any test.
- [ ] The reset mail renders legibly with CSS entirely stripped, contains no remote image, and shows the full URL as plain text below the button.
- [ ] Both new routes are throttled inline, each with a comment naming its abuse primitive; `login`, `refresh`, `logout` and `me` are diff-free.
- [ ] `openspec/specs/notifications/spec.md` is byte-unchanged and appears in no delta; no `notification_logs` row is written by this flow (asserted by test).
- [ ] No class under `app/Notifications/` implements `ShouldQueue` — the existing arch test stays green with no allowlist entry.
- [ ] `/reset-password/{token}` is reachable **without a session** — a regression test pins the `PUBLIC_PATHS` predicate against the token suffix.
- [ ] `password-recovery`'s self-service Non-Goal no longer exists, and the spec records that D2 of the archived change was overturned and why.
- [ ] Pest + Vitest + Playwright green in CI (Chromium + WebKit); coverage ≥ 85% overall, ~95% on the anti-enumeration and revocation paths.

## Proposal Question Round

Execution mode did not allow interactive questioning. These are **product** decisions —
`sdd-spec` and `sdd-design` MUST NOT silently invent answers. Assumptions are stated so a
correction is cheap.

1. **Which roles may self-serve?** The archived proposal listed *"non-admin roles for a future
   email flow"* as an open Non-Goal. Should `viewer` and `operator` reset their own passwords,
   or is self-service admin-only with everyone else routed through an admin's
   `PATCH /api/users/{user}`?
   *Assumed:* **every active user**, any role. A password is a credential, not a privilege, and
   an operator locked out at 2am is the same problem as an admin locked out at 2am.

2. **What does a deactivated user get?** AD-3 fixes the *response* (identical, always). The
   open question is the *behaviour behind it*: is a mail sent and the reset refused at
   consumption, or is no mail sent at all?
   *Assumed:* **no mail is sent**, mirroring `ResetUserPasswordCommand`'s *"refuse, do not
   reactivate"*. A reset must never be a reactivation side channel. The user is told nothing
   different, and the operator sees the refusal in the logs.

3. **Token TTL.** `config/auth.php:122` says 60 minutes. Given the C6 candidate magic link uses
   15–60 min and this is an admin credential on a desktop-only product, is 60 right?
   *Assumed:* **60 minutes, config-driven**, keeping the framework default rather than
   inventing a fourth TTL in the codebase.

4. **Throttle numbers (AD-7).** `/profile/password` uses `throttle:6,1`; the LLM-credential
   routes use `throttle:5,1`. What should the two new routes carry, and how strict should the
   **per-email** key be — noting that an aggressive per-email limit lets an attacker **deny
   recovery** to a known victim?
   *Assumed:* forgot-password **3/min per IP and 3/hour per email**; reset-password
   **6/min per IP**. The per-email hourly limit is the one that most needs a product answer:
   it trades mail-bombing against a targeted recovery-denial attack.

5. **Does a self-service reset write an `audit_logs` row?** The CLI writes
   `user.password_reset` via `AuditRecorder`, and falls back to the log for a platform
   superadmin (`organization_id IS NULL`) because `audit_logs.organization_id` is `NOT NULL`.
   Should a user resetting **their own** password produce the same row?
   *Assumed:* **yes, same action, same fallback** — the audit trail should not have a hole
   shaped like "the common case". Confirmation matters because it inherits the superadmin
   tenancy wall the CLI already documents.

6. **Mail copy: how much does it disclose?** Does the mail state *"if you did not request this,
   your password has not changed and no action is needed"*, and does it name the requesting IP
   or user agent?
   *Assumed:* **reassurance yes, IP/user-agent no.** An IP in an email is weak security theatre
   and a small privacy leak; the reassurance line measurably reduces support contacts.
