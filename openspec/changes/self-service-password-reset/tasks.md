# Tasks: Self-Service Password Reset

> ## ⚠ RETROSPECTIVE LEDGER — reconstructed AFTER delivery. This is NOT a forward plan.
>
> This change **shipped to production before it had a task list**: `api` v0.36.0–0.36.2 and
> `backoffice` v0.22.0–0.22.2. The normal SDD order (`proposal → spec → design → tasks →
> apply → verify`) was **not** followed — implementation ran ahead of specification, the four
> delta specs under `specs/` were authored afterwards **by reading the shipped code**, and this
> ledger was written afterwards again. Its only purpose is to give `sdd-verify` a concrete
> surface to reconcile the shipped code against, and to make the process gap legible.
>
> **Reading rule for every `[x]` below.** A box is ticked only where the corresponding code
> **and** its test were opened and named. The delta specs are **not** evidence: they were
> derived from the code, so citing them for the code would be circular. Anything not opened
> stays `[ ]` with the reason on the line.
>
> **There is deliberately no `design.md`.** That is a stated decision, not an omission awaiting
> a quiet fill-in: `proposal.md`'s **AD-1…AD-8** carry the full design load, are referenced by
> file-level docblocks throughout the shipped code (`ForgotPasswordController`,
> `SendPasswordResetLinkJob`, `routes/api.php`, `02.auth.global.ts`), and are what `sdd-verify`
> should treat as the design of record. Do not backfill a `design.md` after the fact — it would
> be a third document derived from the same code, adding no independent constraint.
>
> **Strict TDD is active** (`openspec/config.yaml: strict_tdd: true`). Red-before-green ordering
> is **not verifiable from this ledger** and is not claimed anywhere in it — see 0.3.

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | Not measured; well above 400 (2 repos, ~12 new files, ~10 modified, 17 published Blade views, 8 test files) |
| 400-line budget risk | High (retrospective — the budget was never applied to this change) |
| Chained PRs recommended | Yes |
| Suggested split | P1 → P2 → P3 → P4, `api` before `backoffice` (the shape the proposal named) |
| Delivery strategy | n/a — apply already happened |
| Chain strategy | pending (the actual branch/PR shape was not reconstructed; read git history) |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: pending
400-line budget risk: High

---

## P0 — Process reconciliation

- [x] 0.1 Delta specs written from the shipped code — `specs/{password-recovery,identity-auth,admin-backoffice,observability}/spec.md`, each carrying its own after-the-fact header.
- [x] 0.2 `design.md` deliberately absent; AD-1…AD-8 in `proposal.md` are the design of record (see banner).
- [ ] 0.3 **Red-before-green ordering unproven.** Every test named below exists and covers the shipped behaviour, but nothing here establishes that it failed first. A retrospective ledger cannot manufacture that evidence; only the commit sequence can.
- [ ] 0.4 **Full-suite / CI evidence not reconstructed.** No Pest, Vitest, Playwright or coverage run was executed for this ledger. `sdd-verify` must run them rather than inherit this file's ticks.

## P1 — Session revocation parity (`api`, AD-4)

- [x] 1.1 `RefreshTokenStore::revokeAllForUser(int $userId): int` — user-scoped, `whereNull('revoked_at')` so an already-revoked row is not re-stamped. `api/app/Support/Auth/RefreshTokenStore.php:170-175`.
- [x] 1.2 Two-family fixture proves `revokeFamily()` was insufficient — `api/tests/Unit/Auth/RefreshTokenStoreTest.php:237`; a revoked family can no longer rotate, `:254`.
- [x] 1.3 `ResetUserPasswordCommand` calls it **inside** the existing transaction — `api/app/Console/Commands/ResetUserPasswordCommand.php:133`.
- [x] 1.4 CLI parity + rollback tests — `api/tests/Feature/PasswordRecovery/ResetUserPasswordCommandTest.php:473` (every family revoked), `:496` (a rolled-back reset leaves families intact).
- [x] 1.5 `RejectStaleCredentials` and `/api/auth/refresh` untouched — the exemption at `api/routes/api.php:61-72` is unchanged; second-precision `iat` behaviour still pinned by `ResetUserPasswordCommandTest.php:200,218`.

## P2 — The two endpoints (`api`, AD-2/AD-3/AD-7)

- [x] 2.1 Both routes public, inline `throttle:6,1`, comment naming each abuse primitive — `api/routes/api.php:74-101`. `login`/`refresh`/`logout`/`me` diff-free (`:71-72`, `:103-106`).
- [x] 2.2 `ForgotPasswordController` is **branch-free**: dispatch and return `202`, no lookup, no token table, no mailer — `api/app/Http/Controllers/Auth/ForgotPasswordController.php:43-53`.
- [x] 2.3 `ForgotPasswordRequest` validates format only; `exists:users,email` deliberately absent with the reason in the docblock — `api/app/Http/Requests/ForgotPasswordRequest.php:12-37`.
- [x] 2.4 `ResetPasswordController`: deactivation check **before** the broker, one generic 422 (`fail()`), `password_changed_at = now()->startOfSecond()` + `revokeAllForUser()` in one transaction — `api/app/Http/Controllers/Auth/ResetPasswordController.php:74-104,117-122`.
- [x] 2.5 `ResetPasswordRequest` — `api/app/Http/Requests/ResetPasswordRequest.php`; payload validation runs before the token is spent, proven by `ResetPasswordEndpointTest.php:244`.
- [x] 2.6 Audit parity with the CLI, incl. the superadmin log fallback for `organization_id IS NULL` — controller `:137-160`; tests `ResetPasswordEndpointTest.php:317,345`.
- [x] 2.7 Anti-enumeration, all **three** cases byte-compared — `api/tests/Feature/PasswordRecovery/ForgotPasswordEndpointTest.php:57` (unknown), `:70` (deactivated), `:91` (body names no account), `:81` (queue is not a second oracle).
- [x] 2.8 Route throttles tested on both legs — `ForgotPasswordEndpointTest.php:132`, `ResetPasswordEndpointTest.php:297`.
- [x] 2.9 Token single-use / expired / forged / cross-user / hashed at rest / never logged — `ResetPasswordEndpointTest.php:83,110,125,136,155,265`.
- [x] 2.10 Post-reset session death — two-family revocation `:165`, stolen refresh cookie refused `:187`, pre-reset access token rejected `:209`.
- [x] 2.11 HTTP-vs-CLI outcome parity asserted by **parallel** tests (the form the proposal asked for), not one shared fixture: `ResetPasswordEndpointTest.php:165,209` against `ResetUserPasswordCommandTest.php:473,200`.
- [x] 2.12 Broker TTL config-driven, not hardcoded — `api/config/auth.php:121-133` (`AUTH_PASSWORD_RESET_EXPIRE_MINUTES`, default 60; broker throttle 60 s, commented as *not* the route limit).

## P3 — Mail (`api`, AD-5/AD-6/AD-8)

- [x] 3.1 Laravel mail views published — 17 files under `api/resources/views/vendor/mail/{html,text}/**`, the first Blade in an API-only repo.
- [x] 3.2 Theme retinted with the two DESIGN.md tokens only — `api/resources/views/vendor/mail/html/themes/default.css:1-11,58,133` (`#771AAF`, `#E45526`, with the WCAG note preserved).
- [x] 3.3 `ResetPasswordNotification` is a **non-queued** renderer; full URL twice (button + plain text); no IP/user-agent — `api/app/Notifications/ResetPasswordNotification.php:39-69`. Arch guard still green with no allowlist: `PasswordResetMailTest.php:106`.
- [x] 3.4 `SendPasswordResetLinkJob` holds every send decision off-request: unknown → silent, deactivated → logged by `user_id` only, unusable origin → refuse and log, broker mints the token, locale from the **target user** — `api/app/Jobs/SendPasswordResetLinkJob.php:90-141`; owns `tries()/backoff()/timeout()` at `:70-88`.
- [x] 3.5 `BackofficeOrigin::resolve()` extracted as the **one** shared validator — `api/app/Support/Http/BackofficeOrigin.php:29-45`, consumed by the job (`:111`) and by CSP (`api/app/Http/Middleware/SecurityHeaders.php:5,99-101`). Both consumers covered: `PasswordResetMailTest.php:74,90` and `api/tests/Feature/C2/Security/CspHeaderTest.php`. **Not in the proposal's Affected Areas** — an unplanned refactor, recorded here rather than left invisible.
- [x] 3.6 `it`/`en` mail copy — `api/lang/en/password_reset.php`, `api/lang/it/password_reset.php`; recipient locale beats worker locale, `PasswordResetMailTest.php:183`.
- [x] 3.7 Mail contract tests — link shape `:131`, no remote image `:148`, legible with CSS stripped `:158`, no `notification_logs` row `:197`, configured sender `:208`, empty `RESEND_API_KEY` harmless `:218`, token never logged `:232`, unknown address never logged `:256`.
- [ ] 3.8 **No test exists for `beai:mail-selftest`.** `api/app/Console/Commands/MailSelfTestCommand.php` is the ship gate and the only proof of deliverability, and it is the sole class in this flow with zero coverage — the `password-recovery` delta's three probe scenarios are unbacked. It predates this change, which explains it but does not close it.

## P4 — Backoffice (`backoffice`, deliverables 10–12)

- [x] 4.1 Guard predicate rewritten to a **first-path-segment** match over `PUBLIC_ROOTS`, locale prefix skipped — `backoffice/app/middleware/02.auth.global.ts:38-81`. Tests: token-bearing and locale-prefixed forms pass (`backoffice/tests/unit/middleware/auth.spec.ts:107-113`), `/projects/reset-password-settings` still redirects (`:125-131`).
- [x] 4.2 `/forgot-password` page — `backoffice/app/pages/forgot-password.vue`; 15 specs in `backoffice/tests/unit/pages/forgot-password.spec.ts`, incl. identical acknowledgement `:81`, address never echoed `:106`, own i18n copy not the server message `:124`, distinct 429 copy `:145`.
- [x] 4.3 `/reset-password/{token}` page (optional-param route) — `backoffice/app/pages/reset-password/[[token]].vue`; token read from the path segment and email from `?email=` (`backoffice/tests/unit/pages/reset-password.spec.ts:70`), truncated link explains itself `:101`, spent token cleared from the address bar `:212`, generic token 422 surfaced at form level `:250`, token never rendered `:347`.
- [x] 4.4 Locale-aware affordance on `/login` — `backoffice/app/pages/login.vue:77-83,109-113`; asserted in `backoffice/tests/unit/login.spec.ts:62-65`.
- [x] 4.5 `it`/`en` copy for both pages and the login link — `backoffice/i18n/locales/{en,it}.json` (5 recovery keys each, symmetric).
- [x] 4.6 E2E — `backoffice/tests/e2e/password-reset.spec.ts`, 13 specs across both pages incl. reachable while logged out `:75` and the address bar cleared on success `:177`.
- [x] 4.7 Typed client regenerated from Scramble — both routes present in `api/openapi.json` and `backoffice/types/api.ts`.
- [ ] 4.8 **Playwright projects not verified.** CLAUDE.md requires Chromium **and** WebKit desktop; the spec file was read, the project matrix and a green CI run were not.

## P5 — Observability redaction (`backoffice`) — undeclared in the proposal

*The reset link put a live credential in a URL path. The existing analytics/error rules were
written on the explicit assumption that never happened, so they had to change. The proposal
does not list `observability` as a modified capability; the delta spec exists because of this.*

- [x] 5.1 `/reset-password/{token}` collapsed to `:token`, query strings still stripped wholesale, deeper paths fall through unredacted — `backoffice/app/utils/analytics-path.ts:38-77`.
- [x] 5.2 Replay disabled on `/login`, `/forgot-password`, `/reset-password` (locale-prefixed forms included) — same file, `:38-39,86-90`.
- [x] 5.3 `sentry-scrub.ts`'s `redactUrl` delegates to the shared implementation rather than re-deriving it; navigation breadcrumbs scrubbed too — `backoffice/tests/unit/sentry-scrub.spec.ts:197-210`.
- [x] 5.4 Redaction unit tests — `backoffice/tests/unit/analytics-path.spec.ts:92-129`.

## P6 — Open, unshipped, or unresolved — do NOT tick these

- [ ] 6.1 **Per-email rate cap deliberately NOT shipped** (proposal Q4 / AD-7). Both routes carry `throttle:6,1` keyed on **IP only**; `api/routes/api.php:89-95` records the reason in the file: a per-email cap trades mail-bombing against a targeted **recovery-denial** attack on a known victim. That is an **open product decision for the owner**, not an implementation choice, and the `password-recovery` delta records it as a shipped deviation.
- [ ] 6.2 **Proposal Q1 — which roles may self-serve — was never answered.** The shipped code applies **no role check at all**: `ForgotPasswordController` does not look the user up, and `ResetPasswordController` gates only on existence and `deactivated_at`. Every active user can self-serve, including a platform superadmin. That may well be right — the proposal assumed it — but it was never decided.
- [ ] 6.3 **The flow is inert in production. This is the hard ship gate.** `RESEND_API_KEY` is empty and `MAIL_MAILER` is unset (resolving to `log`, which delivers nothing) on **both** the `api` and `worker` Railway services; `BACKOFFICE_ORIGIN` **is** set on both. The endpoint still answers `202` and the mail reaches nobody. Gate: `php artisan beai:mail-selftest --to=<real inbox>` exiting 0 on **both** services against a real transport — the command refuses to report success on `log`/`array`. **Owner's step; no engineering task closes it.**
- [ ] 6.4 **Runbook not updated** (proposal deliverable 14). `docs/deploy.md:152-156` still reads *"self-service email reset is not yet shipped"* and offers only `beai:reset-user-password`. It is wrong today about what exists, and silent about which path to use when and what a mail outage means.
- [ ] 6.5 **Main-spec Non-Goal still standing.** `openspec/specs/password-recovery/spec.md:104-112` still declares self-service email reset a Non-Goal. AD-1 requires its deletion and an explicit record that D2 of `archive/2026-08-18-admin-password-reset` was overturned. This is `sdd-archive`'s merge step — flagged so it cannot be missed.
- [ ] 6.6 **A proposal constraint was not honoured, and the record should say so.** The proposal required any `PUBLIC_PATHS` fix to *"preserve the existing suffix semantics the middleware's own comment relies on"*. The shipped fix **replaced** `endsWith` with a first-segment match (4.1). The outcome is strictly **tighter** — `endsWith` would have made a hypothetical `/projects/login` public and the new predicate does not — so the stated risk is **closed, not reopened**. But the constraint as written was broken, and a better predicate arrived by deviation rather than by amendment.
- [ ] 6.7 **Q2, Q3, Q5, Q6 shipped on the proposal's *assumed* answers, never ratified.** No mail to a deactivated user (`SendPasswordResetLinkJob.php:105-109`), TTL 60 min (`config/auth.php:127`), `user.password_reset` audit row with superadmin log fallback (`ResetPasswordController.php:137-160`), reassurance copy with no IP/user-agent (`ResetPasswordNotification.php:63-67`). Each is defensible and each is now production behaviour on an unconfirmed assumption.

---

## Explicitly out of scope (unchanged, and verified unchanged)

- `login`, `refresh`, `logout`, `me` — no throttle, no timing change (`api/routes/api.php:71-72,103-106`).
- `RejectStaleCredentials` on `/api/auth/refresh` — rejected by AD-4; the exemption stands.
- `openspec/specs/notifications/spec.md`, `SendOperatorNotificationJob`, `notification_logs` — AD-8; no delta, and `PasswordResetMailTest.php:197` asserts no row is written.
- Candidate-facing reset, email verification, password-strength policy, 2FA, "log out my other devices".
- Selecting or provisioning the production mail transport — a deployment decision (6.3).
