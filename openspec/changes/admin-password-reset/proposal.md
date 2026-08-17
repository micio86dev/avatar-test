# Proposal: Admin Password Reset

## Intent

Production is locked out. `users` id 1 (`micio86dev@gmail.com`, org 1, role `admin`, active) has a forgotten password and **no recovery path exists**. Verified: no `ForgotPassword`/`ResetPassword` controller, no Fortify/Breeze, no `password` route in `api/routes/api.php`; `password_reset_tokens` exists (default migration) with zero rows. The only password write paths are `PUT /api/profile/password` (requires the current password) and `PATCH /api/users/{user}` (requires an authenticated admin, and already sets `password_changed_at`).

So the real gap is narrower than "no reset exists": **an admin with nobody available to reset them** — the last admin, or one whose peer is unreachable. This proposal targets that gap.

## Scope

### In Scope
- Artisan `user:reset-password` — non-interactive (`--no-interaction` safe, unlike `CreateSuperadmin`'s `ask()`), targets an existing user by email, sets a supplied or generated password, sets `password_changed_at`, transactional.
- Credential output through `OutputInterface::OUTPUT_RAW` (the `ProvisionOrganizationCommand` precedent — Symfony's `OutputFormatter` mangles `<`, `>`, `\` from `Str::password(20)`), printed exactly once, never logged.
- Operator runbook entry; feature tests including the raw-output assertion.

### Out of Scope (deferred, see Open Questions)
- Self-service email reset endpoint, reset-token table, backoffice UI.
- Any change to `PATCH /api/users/{user}` or `UserPolicy` — admin→admin reset already works.
- Rate-limit policy (belongs to `nfr-hardening`).
- First-run bootstrap for a deployment with zero admins.

## Capabilities

### New Capabilities
- `password-recovery`: operator-initiated credential recovery for a locked-out user, including session revocation and one-shot credential disclosure.

### Modified Capabilities
- `identity-auth`: a reset performed outside the authenticated session MUST also invalidate prior tokens via `password_changed_at` / `RejectStaleCredentials`.

## Approach

**Command first, email later — and defended.**

| # | Decision | Rationale |
|---|---|---|
| D1 | Ship the artisan command in slice 1 | It is the only path that unblocks the current lockout, needs no transport, no token table, no UI, and no enumeration surface. Reset is a rare operational event, not a product flow. |
| D2 | Do **not** ship email reset until deliverability is proven | `config/mail.php` line 17 defaults to `log` when `MAIL_MAILER` is unset. The repo *intends* Resend (`docs/dev-setup.md` §Mail, C12, `resend/resend-php` installed, `services.resend.key` wired) but the Railway `api` **and `worker`** variables are **unverified from this context**. Mail here is queued, so a missing key fails inside the job and lands as a `failed` row in `notification_logs` — an email reset would ship as a button that silently does nothing. |
| D3 | If a token is later introduced: single-use, short TTL, hashed at rest, MUST set `password_changed_at`, and **consumed before gate evaluation** — matching the SSO exchange precedent | A link that survives a refused attempt is a retry/probing surface. Cost: a user who trips a gate must request a new link. Consistency with SSO also avoids two contradictory token semantics in one codebase. |
| D4 | Email reset responds identically for known and unknown addresses (generic `202`) | Differentiated responses enumerate accounts. Cost: a typo gets no feedback; mitigated by explicit UI copy and operator visibility in `notification_logs`. |
| D5 | Rate limiting for the email slice is stricter than `throttle:6,1` and keyed on **both** IP and target email | Unauthenticated endpoint, side effect on another person's inbox. This compounds the open `nfr-hardening` question about ad hoc throttles — adopt whatever that change ratifies rather than inventing a third number. |
| D6 | No policy change | `UserPolicy` stays admin-only with no self-branch. Admin→admin reset already works through `PATCH /api/users/{user}`. |

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `api/app/Console/Commands/ResetUserPasswordCommand.php` | New | Non-interactive reset command |
| `api/tests/Feature/...` | New | Reset, revocation, and OUTPUT_RAW coverage |
| `openspec/specs/identity-auth/spec.md` | Modified | Out-of-session reset revokes prior tokens |
| `docs/` runbook | Modified | Operator recovery procedure |
| `api/routes/api.php` | Unchanged | No new HTTP surface in this slice |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Generated password mangled on print | Med | `OUTPUT_RAW`, asserted in test (repeat of a known past defect) |
| Attacker session survives the reset | High if missed | `password_changed_at` set in the same transaction; test asserts pre-reset tokens are rejected |
| Command becomes a privilege-escalation tool | Med | Shell access already implies full DB access; command resets existing users only — never creates, never grants roles |
| Lockout recurs for a non-shell operator | Med | Accepted for slice 1; the email flow is the durable answer, sequenced behind D2 |
| Credential leaked via shell history / CI logs | Med | Prefer generated over `--password=`; never write the value to the log channel |

## Rollback

Delete the command file, its tests, and the `identity-auth` spec delta. No migration, no route, no data change — nothing to revert in production. Passwords already reset stay reset (by design).

## Dependencies

- Production shell access to the Railway `api` service (already available).
- **Blocking the email slice only**: confirmation that `MAIL_MAILER=resend` + `RESEND_API_KEY` + a verified `MAIL_FROM_ADDRESS` are set on the `api` *and* `worker` services.

## Success Criteria

- [ ] An operator resets `micio86dev@gmail.com` with a single non-interactive command and logs in with the printed password.
- [ ] The printed password is byte-identical to the stored credential even when it contains `<`, `>` or `\`.
- [ ] Every token issued before the reset is rejected by `RejectStaleCredentials`.
- [ ] The command refuses unknown emails with a non-zero exit and no partial write.
- [ ] No new HTTP surface, no policy change, no throttle added in this slice.

## Open Questions (for the spec phase — deliberately undecided)

1. Should the backoffice surface an admin-resets-another-admin action? The API already supports it.
2. Does a first-run bootstrap concern exist for a fresh deployment with no admin at all?
3. Is production mail actually deliverable? Requires reading Railway variables — must be answered before the email slice is specced.
