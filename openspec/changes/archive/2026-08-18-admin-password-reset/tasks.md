# Tasks: Admin Password Reset

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~250-300 |
| 400-line budget risk | Low |
| Chained PRs recommended | No |
| Suggested split | Single PR |
| Delivery strategy | ask-on-risk |
| Chain strategy | pending |

Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: pending
400-line budget risk: Low

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Command + tests + `Pest.php` + runbook line | PR 1 | Single PR; two commits (`api` submodule + wrapper `docs/`) plus the pointer bump |

## Phase 1: Test Harness

- [x] 1.1 Add `pest()->use(RefreshDatabase::class)->in('Feature/PasswordRecovery');` to `api/tests/Pest.php`.

## Phase 2: RED/GREEN Loop (`api/app/Console/Commands/ResetUserPasswordCommand.php`, `api/tests/Feature/PasswordRecovery/ResetUserPasswordCommandTest.php`)

Use `Artisan::call()` + `Artisan::output()` for every output-inspecting test — never `$this->artisan()` (it swallows output).

- [x] 2.1 RED — unknown email (spec `password-recovery`): non-zero exit, no write, message names `beai:provision-organization`.
- [x] 2.2 GREEN — create the non-final command, signature `beai:reset-user-password {email}`; description cross-references `beai:provision-organization`. Only email lookup (`User::query()->where('email', $email)->first()`, unscoped) + not-found path.
- [x] 2.3 RED — happy path: exit 0, `Hash::check($printed, $user->fresh()->password)`.
- [x] 2.4 GREEN — `generatePassword()` (plain `Str::password(20)`), one `save()` writing `password` only, plain `writeln`.
- [x] 2.5 RED — revocation (`identity-auth` delta): pre-reset token → `GET /api/auth/me` 401 `credentials_changed`, `POST /api/auth/refresh` 401; `resetAuthGuardState()` between tokens. Genuinely red — 2.4 does not stamp yet.
- [x] 2.6 GREEN — add `password_changed_at = now()->startOfSecond()` to the same `save()`. Inherits the existing strict-`<` second-precision comparison unchanged (not tightened for CLI).
- [x] 2.7 RED — byte-exact output: local fixture subclass `FixedPasswordResetUserPasswordCommand` forces `<`, `>`, `\` in `generatePassword()`; assert printed output equals the fixture AND `Hash::check(fixture, stored)`.
- [x] 2.8 GREEN — switch to `$this->output->writeln("New password: {$password}", OutputInterface::OUTPUT_RAW)`; `generatePassword()` stays a protected, non-final override seam.
- [x] 2.9 RED — deactivated refusal: exit 1, `deactivated_at` and password hash unchanged, no `New password:` in output.
- [x] 2.10 GREEN — add the deactivated guard before the transaction, reactivate-first message; order: not-found, then deactivated.
- [x] 2.11 RED — transaction/ordering: `Event::listen('eloquent.saved: '.User::class, fn () => throw new RuntimeException('boom'))` on the per-test dispatcher; assert exit 1, hash unchanged, no `New password:` printed.
- [x] 2.12 GREEN — wrap the write in `DB::transaction()`; print after commit. Do not claim this buys atomicity for one `UPDATE` — it's a boundary for future writes; the RED test in 2.11 is what proves it matters, not the comment.

## Phase 3: Characterization Locks (green on arrival — not RED steps)

- [x] 3.1 Non-interactivity: `--no-interaction` run exits 0 without blocking, AND the command does not implement `Illuminate\Contracts\Console\PromptsForMissingInput`.
- [x] 3.2 `$command->getDefinition()->hasOption('password')` is false.
- [x] 3.3 Output shape (design D5): identity line first, then password line, then the two `$this->warn()` consequence lines.

## Phase 4: Documentation

- [x] 4.1 Add a "Recovering a Locked-Out User" section to `docs/deploy.md` (no existing runbook section — append at file end): command name, that the password prints once, that it revokes every existing session.

## Phase 5: Verification

- [x] 5.1 From `api/`: `./vendor/bin/pest tests/Feature/PasswordRecovery/ResetUserPasswordCommandTest.php` — all green. `--filter` is forbidden here (observed fabricating passes).
- [x] 5.2 `php artisan test --parallel` and `php artisan test --coverage --min=85` (matches CI).
- [x] 5.3 `./vendor/bin/pint --test` and `./vendor/bin/phpstan analyse --memory-limit=2G`.
- [x] 5.4 `DB_CONNECTION=pgsql php artisan scramble:export`, then `git diff --exit-code api/openapi.json frontend/openapi.json backoffice/openapi.json` must be empty — no OpenAPI surface moved.
- [x] 5.5 Confirm `api/routes/api.php` and `api/app/Policies/UserPolicy.php` show no diff.

## Phase 6: Post-Verification Findings (from sdd-verify, PASS WITH WARNINGS)

- [x] 6.1 Close spec coverage gap: `identity-auth` delta scenario "the second-precision comparison window is honored" had zero covering test anywhere in the repo. Added two tests using `freezeSecond()`/`travel(1)->second()` — a token with `iat` in the SAME wall-clock second as the reset survives (`iat == password_changed_at`, not `<`), and one minted a second earlier is rejected (`iat < password_changed_at`). `RejectStaleCredentials` itself is pre-existing and unmodified.
- [x] 6.2 Recorded (no code needed, comment added): print-after-commit is correct by placement, but the existing rollback test (2.11) cannot catch a regression that moves `report()` inside the `DB::transaction()` closure right after `save()` — the throwing listener fires synchronously during `save()`, so nothing placed after it runs either way regardless of placement. Documented as a known ceiling in `ResetUserPasswordCommand.php` next to the `report()` call.
- [x] 6.3 Closed: the platform-superadmin output branch (`org id=none (platform superadmin)`) was the one uncovered line in `ResetUserPasswordCommand`. Added a 2-line test (`User::factory()->create()` with no `organization_id` override). Coverage for this class is now 100% methods / 100% lines.
