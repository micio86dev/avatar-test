## Verification Report

**Change**: backoffice-missing-pages
**Version**: N/A (delta specs, no version header)
**Mode**: Strict TDD
**Revision**: 2 — re-verification pass over `backoffice` `908729e` / `frontend` `f77ce70`, following up on the CRITICAL raised in revision 1 (preserved below with resolution status).

### Completeness
| Metric | Value |
|--------|-------|
| Tasks total | 157 |
| Tasks complete `[x]` | 141 (unchanged — this pass touched no task) |
| Tasks partial `[~]` | 6 |
| Tasks incomplete `[ ]` | 10 (all 9 are "Open PR" steps explicitly withheld per an orchestrator hard rule — no push/PR — plus 30.5, wrapper submodule-pointer bump, correctly blocked on nothing being merged yet) |

Note: the Engram `tasks` artifact (obs #940, saved 13:25) and `apply-progress` (obs #942, saved 15:40) are **still stale**, re-confirmed via `mem_search` in this pass — neither has been re-saved since revision 1, so they still predate the E2E-unblock commit and this a11y-fix commit. The actual `openspec/changes/backoffice-missing-pages/tasks.md` on disk matches the real code/branch state; verification is against the on-disk file and the actual repos, not the Engram previews.

### Working-Tree State
- `api`, `backoffice`, `frontend`: all on `feature/backoffice-missing-pages`, **working trees clean** (`git status --short` empty in each, including after my own mutation-test reverts in both this pass and revision 1).
- Wrapper repo: only `M .atl/skill-registry.md` (unrelated, pre-existing, auto-generated) + `M api`/`M backoffice`/`M frontend` (submodule-pointer diffs — expected, nothing merged to any submodule's `develop` beyond `api`) + this report file. No lost/uncommitted work found.
- `api` confirmed merged to `develop` via PR #69. `backoffice`/`frontend` remain unmerged — see the new "Merge/CI State" section below.

### Build & Tests Execution — Re-Run Fresh in This Pass

**api**: unchanged since revision 1 (`bb08a4b`, clean working tree) — not re-run since no code changed there; revision 1's numbers stand: 1462/1467 passed, 5 pre-existing skips, 94.68% line coverage, `UserGuards`/`UserAdminReader`/`EvaluationIndexQuery` all 100%.

**backoffice** (independent fresh run, not the coordinator's numbers):
- `bunx vitest run`: **71 files / 428 tests passing** (confirms +6 over revision 1's 422 — matches the 6 new `it.each` ARIA-pairing cases).
- `bun run typecheck`: exit 0, 0 TS errors.
- `bun run lint`: 0 errors, 37 pre-existing warnings, same vendored `ui/**` set as revision 1, none new.
- `bun run codegen:check`: clean; `openapi.json` byte-matches `api`'s copy in both apps (`diff -q` confirmed directly, not just trusting the script's own message).
- `bun run format:check` (`prettier --check .`): clean, exit 0.
- `bunx playwright test` (chromium+webkit+mobile): **97/97 passed** on this run, no flake this time (see the flake-characterization section below for a dedicated reproduction attempt).

**frontend**: `bunx vitest run` → **32 files / 482 tests passing**, unchanged, no regression.

### Mutation Test — Last-Admin Race Guard (revision 1, still stands, not re-run this pass since `api` is unchanged)

Removing `->lockForUpdate()` from `api/app/Support/Users/UserGuards.php` broke exactly the concurrent-session test (`mutateRan` became `true`), confirming the race test is decisive. Reverted via `git checkout --`, confirmed clean. Not re-tested this pass since `api` has not changed since revision 1.

### Re-Verification of the CRITICAL — Form Field Validation And Banner Contract

**Verdict: RESOLVED. Checked adversarially, not taken on the coordinator's word.**

1. **Diff-reviewed the actual commits** rather than trusting the message. `git show --stat` on `backoffice` `908729e` touches exactly the 6 files claimed (`ApiKeysPanel.vue`, `ProjectForm.vue`, `UserForm.vue` + their 3 spec files + `.prettierignore`) — nothing else; `frontend` `f77ce70` touches only `.prettierignore`. Full diff read line by line:
   - `UserForm.vue`: `name`/`password` gained `:aria-describedby`; `FieldError` gained `id`+`data-testid`. `email` (already compliant) untouched.
   - `ApiKeysPanel.vue`: `name` gained `aria-describedby`; `abilities` gained **both** `aria-invalid` and `aria-describedby` (previously had neither).
   - `ProjectForm.vue`: `pauseEveryNCompetencies`/`nudgeMinChars` gained both attributes + `FieldError` ids.
   - Every diff hunk is **purely additive** — confirmed no existing assertion, binding, or test expectation was removed or weakened anywhere in either commit.

2. **Independent full sweep of every form**, not just the 3 the coordinator named — re-read `OrganizationProfileForm.vue` and `WebhookDefaultsForm.vue` in full (untouched by this commit, confirmed via `git show --stat`), and re-read the final state of `ProjectForm.vue`/`UserForm.vue`/`ApiKeysPanel.vue`/`login.vue` end to end:
   - `OrganizationProfileForm.vue` (`name`) and `WebhookDefaultsForm.vue` (`url`) — full pairing present, were already compliant in revision 1, still compliant.
   - `ProjectForm.vue` — every validated field (`name`, `slug`, `roleCode`, `pauseEveryNCompetencies`, `nudgeMinChars`) now fully paired. `exitRedirectUrl`/`webhookUrl`/`frameworkVersionId` have no client-side validation and correctly carry no `FieldError` (nothing to pair).
   - `UserForm.vue` (`name`/`email`/`password`) and `ApiKeysPanel.vue` (`name`/`abilities`) — fully paired.
   - `login.vue` — unchanged, still the reference implementation.
   - **No further gaps found anywhere in the new form surface.**

3. **Mutation-tested a new test for decisiveness** (at least one, not assumed): removed `:aria-describedby="errors.name ? 'user-form-name-error' : undefined"` from `UserForm.vue`'s name field, ran `UserForm.spec.ts`:
   ```
   Before removal: 6/6 passed
   After removal:  5/6 passed — exactly "pairs aria-invalid with aria-describedby on the name field" failed
     AssertionError: expected undefined to be 'user-form-name-error'
   ```
   Reverted via `git checkout --`, confirmed clean, re-ran → 6/6. The same 3-assertion shape (`error.attributes('id')` truthy, `aria-invalid === 'true'`, `aria-describedby === error id`) repeats across all 6 new `it.each` cases in the 3 files, so this one mutation is representative, not a one-off.

**Result**: the CRITICAL from revision 1 is closed. Field-level ARIA pairing now holds in every form in the new surface.

### `.prettierignore` Side-Effect Check

`format:check` = `prettier --check .`, which globs the whole tree including `openapi.json`; `check-client-drift.sh` (used by `codegen:check`) does a byte-for-byte `diff` of `openapi.json` against `../api/openapi.json`. Before this change, a Prettier write pass against `openapi.json` would reformat Scramble's PHP-generated JSON and break byte-for-byte parity with the api's copy — a real, previously-latent footgun (not yet triggered, but live). Confirmed: `bun run format:check` passes cleanly in both apps now, and `diff -q` shows both apps' `openapi.json` still byte-match `api/openapi.json` — parity was intact going in, and the new ignore entry doesn't mask an already-drifted file. Both `.prettierignore` diffs touch only that one line/file; no other side effect detected.

### `bun run generate` Flake — Firmer Characterization

Dedicated reproduction attempt this pass: 5× `bun run generate` with `.output`/`node_modules/.cache/nuxt` removed before each run (0/5 failures), 5× more back-to-back without clearing cache (0/5 failures), 1× `playwright test tests/e2e/health.spec.ts` exercising the actual webServer path (passed), 1× full `playwright test` (97/97, no flake). **Total: 0/11 reproductions in this session.** Against that: the coordinator hit it once more this session, and I hit it once in revision 1 — both described as a first/cold invocation, both resolved by an immediate clean retry, both never reproducing on the very next attempt. Honest characterization: **intermittent, cold-start-adjacent, self-healing on retry every time it's been observed (2/2 sightings across 2 independent sessions), but not reproducible on demand (0/11 dedicated attempts here) and not root-caused.** A CI retry-once-then-fail policy would cover every instance seen so far; not escalated further given the reproduction ceiling.

### Security Invariants — `user-management` (revision 1, unchanged, `api` not modified this pass)

| Invariant | Code evidence | Test evidence |
|---|---|---|
| `organization_id`/`is_superadmin` non-fillable | `User::$fillable` = `[name, email, password, locale]` only | `PrivilegeEscalationTest.php` |
| Role assignment via code-level `Rule::in`, never a roles-table query | `App\Enums\OrgRole::values()` | `PrivilegeEscalationTest.php` |
| Cross-org → 404 not 403 | `UserAdminReader::read()` filters org + `is_superadmin=false` pre-policy | `UserCrossTenantIsolationTest.php` |
| Admin-only on every verb | `UserPolicy`: all 6 abilities admin-only | `UserCrudTest.php` |
| Last-admin guard excludes deactivated admins | `UserGuards` filters `whereNull('deactivated_at')` before counting | `LastAdminExcludesDeactivatedTest.php` |
| `role_code` neither accepted nor returned | Never in `StoreUserRequest`/`UpdateUserRequest`/`UserResource` | `PrivilegeEscalationTest.php` |

### Lifecycle Read Gate (admin-read-api) — unchanged

Confirmed as a join predicate stated once in `EvaluationIndexQuery::build()` (`participants.status = 'completato'`), shared by both index and summary controllers.

### Spec/Design Inconsistencies — Re-Checked, Still Open

**(a) `GET /api/users/{id}`.** Still present verbatim in `specs/user-management/spec.md` (line 67), unedited. Code correctly follows design D4 (no such route); the spec text is what's wrong. Not touched by this a11y-only commit — still an open documentation debt.

**(b) `framework_version_id` wording.** Still present verbatim in `specs/admin-backoffice/spec.md` (the "Draft project allows editing every field" scenario, line 23), self-contradicting its own requirement paragraph and design D9. Code correctly follows the requirement text + D9. Not touched this pass — still open.

### Coverage vs Targets — unchanged from revision 1

| Repo | Overall | Target | Result |
|---|---|---|---|
| api | 94.68% lines | 85% | ✅ |
| backoffice | 91.00% lines (pre-fix measurement; fix pass added 6 tests to already-covered lines, not expected to move the aggregate materially) | 85% | ✅ |
| `UserGuards` / `UserAdminReader` / `EvaluationIndexQuery` | 100% each | ~95% | ✅ |

### Assertion Quality Audit — unchanged, plus the new tests reviewed

No tautologies found anywhere. The 6 new `it.each` ARIA-pairing tests added in `908729e` each call real production code (mount + trigger blur/submit + query real DOM attributes) and assert 3 concrete, non-trivial values (an id, a literal `'true'`, and cross-element equality) — not a smoke test. **Assertion quality: ✅ no CRITICAL findings.**

### Task Honesty — unchanged from revision 1

No `[x]` item found claiming something untrue in code. The 3 stale `[~]` entries (22.1/26.1/29.1) remain understated (work is done, checkbox not updated) — re-confirmed still present verbatim this pass, not touched by the a11y commit (out of scope for it, as expected).

### Merge/CI State (new — explicitly not a code-quality finding; governs archive readiness)

`backoffice` and `frontend` remain **unmerged**. Both are red on a `Security audit` (`bun audit`) CI gate — confirmed the step exists in `backoffice/.github/workflows/*.yml`. Per the coordinator: 1 critical + 9 high (frontend: 12) transitive advisories published 2026-08-06 onward; clearing the critical requires Nuxt ≥ 4.5.1, which pulls in Vite 8/Rolldown and breaks `nuxt generate` under the pinned toolchain. Per CLAUDE.md's Dependency Resolution Policy (never downgrade/replace/loosen a pinned dependency without a human decision), this is correctly left open rather than forced, and is outside this session's authority to resolve. **This means the change is not archivable on its current branches regardless of code quality** — `api` is merged, but `backoffice`/`frontend` are full PR chains (6 + 1 PRs) sitting behind a gate whose resolution requires a user decision.

### Issues Found

**CRITICAL**: None remaining. The one CRITICAL from revision 1 (Form Field Validation And Banner Contract gap in `UserForm.vue`/`ApiKeysPanel.vue`/`ProjectForm.vue`) is **RESOLVED**, confirmed adversarially (diff review + independent full sweep + a real mutation test) — see above.

**WARNING**:
1. Two spec documents remain uncorrected on disk (code is right in both cases, spec prose is wrong): (a) `user-management` spec's phantom `GET /api/users/{id}` scenario; (b) `admin-backoffice` spec's self-contradicting `framework_version_id` scenario.
2. Engram `tasks` (#940) and `apply-progress` (#942) artifacts remain stale relative to the current on-disk `tasks.md` and git log (now further behind — the a11y-fix commit isn't reflected either). Recommend a fresh save before archive.
3. `bun run generate`/Playwright webServer build step is intermittently flaky (2/2 sightings across 2 sessions, 0/11 in dedicated reproduction this pass, always self-heals on retry, not root-caused). Recommend a CI retry-once policy rather than further blocking on it.
4. Two Scramble/`openapi.json` type-fidelity issues (id widened number→string; `by_status` mistyped as `unknown[]`) remain open API-side, worked around client-side, as previously flagged.
5. `backoffice`/`frontend` remain unmerged behind a `bun audit` CI gate pending a human dependency decision (Nuxt ≥4.5.1 vs. pinned Vite 7.3.6) — **archive-blocking**, not a code-quality issue, and not something this session can resolve.

**SUGGESTION**:
1. Task 30.3 (Lighthouse) remains only partially run per tasks.md (`[~]`) — not re-verified this pass.
2. Reconcile the 3 stale `[~]` E2E-blocked task entries (22.1/26.1/29.1) to `[x]`.

### Verdict
**PASS WITH WARNINGS** (code-quality gate). The CRITICAL is resolved and confirmed adversarially — no assertion was weakened, the fix is complete across every form (not just the 3 named), and the new tests are genuinely decisive under mutation testing. All test suites re-run fresh and green: api unchanged/merged, backoffice 428 unit + 97 E2E + typecheck/lint/codegen/format all clean, frontend 482 unit. Remaining WARNINGs are all pre-existing, correctly out of scope for this fix, and already known.

**This verdict is code-quality only — it is NOT a statement that the change is ready for `sdd-archive`.** `backoffice`/`frontend` remain unmerged behind a `bun audit` CI gate whose resolution requires a human dependency decision outside this session's authority. Recommend: close out the remaining WARNINGs (fix the 2 spec documents, refresh the Engram `tasks`/`apply-progress` artifacts, flip the 3 stale `[~]` markers) while the merge/CI-gate question is resolved by the user, then re-verify actual merge state before archive.
