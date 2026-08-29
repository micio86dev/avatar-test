# Verification Report — self-service-password-reset

> **Transcription.** The authoritative verify artifact was persisted to Engram as
> observation **#1704** (`sdd/self-service-password-reset/verify-report`, project
> `avatar-test`, 2026-08-28 22:30:49). This file is its verbatim transcription into the
> change folder, written by `sdd-archive` on 2026-08-29 so the archived folder is
> self-contained and does not depend on an Engram lookup to be readable.
>
> **Both WARNINGs below were fixed before archive** — see the *Post-verification status*
> section at the end. They are transcribed unedited because a verification record that is
> silently edited after the fact stops being a record.

**Mode**: Strict TDD. **Verdict**: PASS WITH WARNINGS — **archivable**. 0 CRITICAL against
this change, 2 WARNING, 4 SUGGESTION.

## Runtime evidence (all executed 2026-08-28)

- `api` full Pest: `{"tool":"pest","result":"passed","tests":2603,"passed":2597,"assertions":7425,"duration_ms":280760,"skipped":6,"risky":1}` exit 0. No flakiness this run (R-4 did not fire).
- `api` targeted (PasswordRecovery + MailSelfTest + RefreshTokenStore + arch guard): 111 tests, 111 passed, 294 assertions, **1 risky**.
- `backoffice` Vitest: 117 files, 1075 tests, all passed, exit 0.
- `backoffice` Playwright full: **188 passed, 3 failed, exit 1** — all 3 are the SAME pre-existing test, `tests/e2e/unsupported-gate.spec.ts:36` (WCAG `document-title` on `/unsupported`), across chromium/webkit/mobile. NOT this change: the backoffice diff `v0.21.0..v0.22.2` touches 18 files and none is the unsupported page, `app.vue`, `nuxt.config` or a layout.
- `backoffice` Playwright, password-reset only: **24/24 passed** = 12 specs × {chromium, webkit}.

## Changed-file coverage

**api (PCOV)**: `ForgotPasswordController` 100, `ResetPasswordController` 100,
`ForgotPasswordRequest` 100, `ResetPasswordRequest` 100, `SendPasswordResetLinkJob` 100,
`ResetPasswordNotification` 100, `RefreshTokenStore` 100, `BackofficeOrigin` 100,
`MailSelfTestCommand` **99.0** (uncovered L305, the defensive `return []` in `membersOf`).

**backoffice (v8)**: All files 94.94% stmts / 89.5% branch. `app/middleware` 100,
`app/pages` 97.62, `app/utils` 95.67, `login.vue` 100, reset-password page 99.62,
`sentry-scrub.ts` 83.49.

## Security properties — verified in code AND by a test that can fail

- Byte-identical forgot-password across existing/unknown/deactivated — `ForgotPasswordEndpointTest:57,70` compare `getStatusCode()` + `getContent()`. Controller genuinely branch-free (`ForgotPasswordController:43-53`).
- No in-request lookup / no mail round trip — structural, plus `Queue::assertPushed` for BOTH known and unknown (`:81`), so the queue is not a second oracle.
- Unknown addresses absent from logs — job returns silently (`SendPasswordResetLinkJob:98-103`). See WARNING 1.
- Token single-use / expiring / hashed at rest / never logged — `ResetPasswordEndpointTest:83,110,125,136,155,265`; hashing asserted against the real `password_reset_tokens` row.
- Reset revokes the whole refresh family + `/api/auth/refresh` 401 — `:165` (two-family fixture, both rotate to `RefreshRotateStatus::Revoked`), `:187` (real cookie replay → 401). `revokeAllForUser` user-scoped with `whereNull('revoked_at')`.
- Both endpoints throttled — `throttle:6,1`, exercised to 429 on both legs (`:132`, `:297`).
- `BACKOFFICE_ORIGIN` absent/malformed → refusal to send — `PasswordResetMailTest:74,90` (`*`, bare host, `ftp://`). One shared validator `BackofficeOrigin::resolve()` used by both CSP and the mail flow.
- Token redacted from analytics + Sentry and cleared from the address bar — `analytics-path.ts` collapses `/reset-password/:token`, `sentry-scrub`'s `redactUrl` delegates to it, `history.replaceState` clears the URL; E2E `:177` green on both browsers.

## CLAUDE.md binding constraints

UNTOUCHED. Surface is auth/mail/refresh-token only. `routes/api.php` diff is pure addition —
`login`/`refresh`/`logout`/`me` byte-identical. `RejectStaleCredentials` unchanged.
`notifications/spec.md` in no delta; `PasswordResetMailTest:197` asserts zero
`notification_logs` rows. No scoring/tenancy/candidate-state-machine file belongs to this
change (Scoring/Lifecycle files in the v0.36.0 range belong to the already-archived
`evaluator-evidence-and-rigor`).

## WARNING 1 — the single risky test in the whole 2603-test suite

`api/tests/Feature/PasswordRecovery/PasswordResetMailTest.php:256` — *"the job logs no probed
address for an unknown email"*. JUnit reports **assertions="0"**. Ghost loop: for an unknown
address the job logs nothing, so `$lines` is empty and `foreach ($lines as $line)
expect(...)` never executes. It backs a load-bearing requirement (*"An Unknown Address Is
Never Written To A Log Channel"*) while currently proving nothing. It CAN still fail if
someone adds a log line naming the address, and siblings (`:74`,
`ResetPasswordEndpointTest:341`) prove `Log::listen` works in these files — so the weakness is
bounded, not vacuous. Fix: `expect($lines)->toBeEmpty()` — stronger, and a real assertion.
Same shape at `PasswordResetMailTest:232` and `ResetPasswordEndpointTest:265`, masked there by
an unrelated assertion.

## WARNING 2 — a spec scenario half that is claimed, not held

`password-recovery` delta, *"A deactivated refusal is logged by id, not address"*: code is
correct (`Log::info('password reset refused: user is deactivated', ['user_id' => $user->id])`)
but `PasswordResetMailTest:65` asserts ONLY `Notification::assertNothingSent()`. No test
anywhere asserts that log's content; nothing would fail if it logged the address instead.
Status PARTIAL. 100% line coverage on the job is not assertion coverage — the exact trap the
retrospective-spec setup creates.

## Ledger reconciliation (file on disk read 37/41; measured 40/41 after this run)

- **0.4** CLOSED by this run (all four suites + coverage executed).
- **3.8** CLOSED and independently confirmed: 26 tests, 99.0%, and the fix is genuinely tested — failover→log, roundrobin→array, nested composite, any-name (`notifications`→array), unresolvable mailer, unsupported driver, plus a composite-that-all-delivers negative control so the gate cannot cry wolf. Refusal ORDER pinned by 3 tests using `doesntExpectOutputToContain`. The file explicitly avoids both known traps (uses `Mail::spy()` not `Mail::fake()`; one substring per `expectsOutputToContain`).
- **4.8** CLOSED: `playwright.config.ts` projects = chromium/webkit/mobile; password-reset green on chromium + webkit.
- **0.3 REMAINS OPEN, permanently.** From git: `api` commit `9632dbf` is ONE squashed commit bundling password reset + session excerpts + a deploy command. Red-before-green unprovable, and as a side effect the proposal's per-slice P1..P4 rollback plan does not exist in history.
- **6.4** is STALE — CLOSED, not open. `docs/deploy.md` *"Recovering a Locked-Out User"* now says self-service shipped, that it is inert until mail is configured, which path to use during a mail outage, and the selftest command. Flip it at archive.
- **6.1, 6.2, 6.5, 6.6, 6.7** confirmed accurate as written.
- **6.3** confirmed LIVE against Railway this session: `api` and `worker` BOTH have `RESEND_API_KEY` empty and NO `MAIL_MAILER` key at all (→ `log`); both have `BACKOFFICE_ORIGIN` set and `MAIL_FROM_ADDRESS=noreply@quint.org`. Inert in production exactly as recorded. Owner's step.

## Suggestions

1. Requirement prose says the forgot-password response is identical in status, body AND headers; tests compare status + body only (the scenario asks only for those two — prose-vs-scenario drift, not a code gap).
2. Repo-level, NOT this change: `/unsupported` has no `<title>`, failing WCAG 2.1 AA on all three Playwright projects and making `bun run test:e2e` exit 1. Needs its own change; do not let it ride in on this archive.
3. `sentry-scrub.ts` at 83.49% is the lowest-covered touched file, though the delegation path this change depends on is covered.
4. At archive execute **6.5**: delete the self-service Non-Goal at `openspec/specs/password-recovery/spec.md:104-112` and record the overturn of **D2** of `archive/2026-08-18-admin-password-reset` (AD-1). Verified still standing.

---

## Post-verification status (added by `sdd-archive`, 2026-08-29)

**Both WARNINGs are FIXED and are not open findings.** `api` `develop` commit **`520b66b`**:

- **WARNING 1** — the three ghost `foreach` loops (`PasswordResetMailTest:232`, `:256`,
  `ResetPasswordEndpointTest:265`) are now real assertions. The zero-assertion risky test is gone.
- **WARNING 2** — the deactivated-refusal log content is now asserted, and the assertion was
  **proved by mutation**: it fails when the log line is changed to carry the address.

**Suggestion 2** was NOT absorbed into this change. It is carried forward as ROADMAP risk
**R-5** with an owner-spec requirement at `openspec/specs/admin-backoffice/spec.md` →
*The `/unsupported` Page Carries A Document Title* (STATUS: OPEN). It needs its own change.

**Suggestion 4** was executed at archive — see `archive-report.md`.
