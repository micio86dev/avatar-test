# Tasks: Generated-Client Truth and Session Safety

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | 600–1200+ (Commit S alone: 10 resource files + regenerated `openapi.json`×3 + `types/api.ts`×2 + 9 call sites + 8 fixtures — likely >400 by itself; PR2–PR6 each <100) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR1 (Commit S) → PR2 (D4) → PR3 (D5) → PR4 (D6) → PR5 (CI gate, needs PR1) → PR6 (D7) |
| Delivery strategy | **Resolved**: single branch (`feature/client-truth`), no PR chaining, `size:exception` granted by the orchestrator/user before apply |
| Chain strategy | N/A — single-branch exception, superseded the chained-PR plan below |

Decision needed before apply: **No — resolved. `size:exception` granted.**
Chained PRs recommended: Yes (superseded)
400-line budget risk: High (accepted under the granted exception)

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Commit S: D1 annotations+casts, `openapi:sync`, 9 call sites, 4 cast deletions, 8 fixtures | PR1 | Base: feature branch. Ask maintainer for `size:exception` — cannot be split, no intermediate green state |
| 2 | D4 admin revocation | PR2 | Independent, base: PR1 or main once merged |
| 3 | D5 API-key list | PR3 | Independent |
| 4 | D6 avatar-template errors | PR4 | **Drop first** if `avatar-provider-templates` moved onto `AvatarTemplateController.php` (see 1.3) — checked: it had not; D6 proceeded |
| 5 | D2/CI regeneration gate | PR5 | Depends on PR1 (needs real annotations to revert for the red-run proof) |
| 6 | D7 test noise | PR6 | Independent, 3 unrelated sub-fixes, may split further |

## Phase 1: Prerequisites & Doc Reconciliation

- [x] 1.1 Determinism probe: `scramble:export`, copy, re-export, diff. If not byte-stable, plan the canonicalised-JSON fallback (reuse `wrapper-ci.yml:155-183`) for Phase 8 — **Byte-identical across two consecutive runs, unchanged code.** No fallback needed. Also discovered: `routes/api-test-isolation.php` (loaded only when `APP_ENV=testing`) leaked into the export because `api/.github/workflows/ci.yml`'s job-level `APP_ENV: testing` applies to the `scramble:export` step too — fixed by excluding `api/test-isolation` in `config/scramble.php`'s `api_path`, or the freshness gate (Phase 8) would be permanently red regardless of resource correctness.
- [x] 1.2 Confirm trailing newline / `servers[0].url` against committed file with `APP_URL=http://localhost` — confirmed `http://localhost/api` matches; `api/.github/workflows/ci.yml` did not set `APP_URL` (pinned in Phase 8).
- [x] 1.3 Re-read `openspec/changes/avatar-provider-templates/tasks.md` immediately before Phase 7 — 7.2/7.3 confirmed out-of-scope-by-decision; no collision with `AvatarTemplateController.php`/`AvatarTemplateForm.vue`. Phase 7 proceeded.
- [x] 1.4 Fix `proposal.md`'s Modified Capabilities table — add `avatar-templates`: Config Validation Errors Are Keyed Per Field (already present in `proposal.md`'s Capabilities section as reviewed; no further edit required — spec delta at `specs/avatar-templates/spec.md` exists and is implemented).

## Phase 2: RED — Contract-truth tests (D1/D8, must fail against today's code)

- [x] 2.1 Falsifiability gate: `GET` roles/competencies/BARS → `expect($json['data'][0]['name'])->toBeString()` (Role, Competency `definition` too, all 4 BARS fields). **RESULT: GREEN on today's code** (all 17 assertions passed on first run, matching `HasTranslations::getAttributeValue()`'s property-read interception — design.md's own explicit reading, "if RED, D1 is wrong"). tasks.md's inverted summary phrasing ("if green, D1 is wrong") conflicts with design.md's detailed reasoning; resolved per design.md (the reasoned, evidence-backed document) — **reported prominently, not silently resolved, in the final apply report.**
- [x] 2.2 `toBeInt()` on `id`/FKs across all ten resources, plus `pin_context.id`, `competencies.*.position` — **RESULT: GREEN on today's code** (all ids already native PHP int at the wire level once a test-setup bug was fixed). `Project.php:86-88`'s "pdo_pgsql returns bigint as string" note does NOT currently hold for JSON-serialized model attributes on this stack (PHP 8.5.7). `(int)` casts added anyway per design, as a self-documenting/future-proofing measure, not because they were observed necessary today.
- [x] 2.3 Union RED: `Participant.status`, `Project.status`, `Project.assessment_type` (+ nested), `Admin/UserResource.role` — runtime values already matched their real sets (green); the STATIC contract (openapi.json) did not (confirmed separately by inspecting Scramble's pre-annotation export).
- [x] 2.4 Nullability RED: `role_code`, `exit_redirect_url`, `webhook_url`, `pause_every_n_competencies` present-and-null (not `""`/`0`); org `default_webhook_url`/`default_webhook_events` null — green on today's code.
- Test file: `api/tests/Feature/Api/ResourceContractTruthTest.php` (17 tests, 59 assertions). Per this project's rule ("say so rather than manufacturing a RED"), no RED was manufactured — all runtime assertions were already true; the confirmed defect is exclusively in the **documented/static** contract (`openapi.json`, generated TS clients), not the wire bytes.

## Phase 3: GREEN — Resource annotations + casts (D1)

- [x] 3.1 `Admin/OrganizationResource`: `@return`+`@scramble-return`, `id:int`, nullable `default_webhook_url`/`default_webhook_events`, `has_default_webhook_secret:bool`
- [x] 3.2 `Admin/UserResource`: `id:int`, `role` union, `is_deactivated:bool`
- [x] 3.3 `Admin/Participant{,Detail}Resource`: `id`/`project_id:int`, `role_code`/`language:string|null`, `status` union, `candidate_ref`/`display_name` NOT NULL; Detail adds `timeline`/`files` shapes
- [x] 3.4 `ParticipantResource` (candidate): as 3.3 + nested `project` shape
- [x] 3.5 `ProjectResource`: ids `int`, `status`/`assessment_type` unions, `pause_every_n_competencies`/`nudge_min_chars` nullable int, webhook fields, `pin_context`, `competencies` list with `(int)` pivot
- [x] 3.6 `FrameworkVersionResource`: `id`/`organization_id:int`
- [x] 3.7 `CompetencyResource`: `id:int`, `name`/`definition:string`, `type:string`, `bars_available:bool`
- [x] 3.8 `BarsIndicatorResource`: `position:int`, `text`/`anchor_5/3/1:string`
- [x] 3.9 `RoleResource`: `name`/`responsibilities:string`, `competency_count:int`
- [x] 3.10 Phase 2 tests green via `./vendor/bin/pest <exact-file>` per file — never `--filter`. Also: `Participant.php`/`Project.php` `@property` docblocks narrowed to the real union (PHPStan level 8 requires it once the resource `@return` union is added); `Organization.php` gained a full `@property` block (previously had none, causing PHPStan to misinfer `default_webhook_events`'s type). PHPStan: 0 errors. Pint: passed.

## Phase 4: GREEN — Snapshot regen + client fixes (D2 partial, D3) — Commit S

- [x] 4.1 `task openapi:sync` (export → copy to `frontend/`+`backoffice/` → regenerate both `types/api.ts`)
- [x] 4.2 Fix compiler-hard sites: **only 2 of the design's estimated 9 sites actually broke the compiler** — `ProjectTable.vue`'s `defineEmits<{(e:'edit', id: string)}>()` (now `number`) and `pages/projects/index.vue`'s `editing` ref/`onEdit` param (now `'new' | number | null`). `ProjectForm.vue`'s `frameworkVersionId`/`pauseEveryNCompetencies`/`nudgeMinChars` refs and `UsersPanel.vue`/`UserForm.vue` did NOT independently break the compiler (see 4.3-4.5 for why).
- [x] 4.3 Delete 4 silencing casts (`ProjectForm.vue:419` `as 'standard'|'potential'`, `ProjectForm.vue:573` `String(competency.name)`, `UsersPanel.vue:29` `String(user.role)`, `UserForm.vue:151` `as`) — all four deleted. `UsersPanel.vue`'s `String(user.role)` was masking a real gap (role can be `null`); fixed with an explicit `v-if`/em-dash fallback instead of a new cast.
- [x] 4.4 `ProjectForm.vue:424-425` — read `isPauseEveryNCompetenciesValid`/`isNudgeMinCharsValid`: both take `number | null | undefined`. The existing string-ref-with-boundary-conversion pattern (`raw === '' ? null : Number(raw)`) already matches this signature and typechecks clean with the new `number | null` API type — no change needed.
- [x] 4.5 `UserForm.vue`'s `ACCESS_LEVELS` (`['admin','operator','viewer'] as const`) equals `OrgRole::values()` — confirmed, no disagreement; the `as` cast was simply redundant once removed.
- [x] 4.6 Corrected 8 fixture files (`tests/unit/components/organisms/{ProjectTable,ProjectForm,CandidateTable}.spec.ts`, `tests/unit/pages/{projects/index,participants/detail}.spec.ts`, `tests/unit/composables/useParticipants.spec.ts`, `tests/e2e/{admin-flow,projects-crud}.spec.ts`) — string ids → real number types, `webhook_events` string→array, `has_webhook_secret` added where missing. `tests/e2e/settings-tabs.spec.ts` and `tests/e2e/autocomplete-hygiene.spec.ts` also updated for the D5 unpaginated `/m2m/clients` mock shape (design's file list omitted these two; found and fixed during Phase 6).
- [x] 4.7 `bun run typecheck` and `bun run codegen:check` green in both `frontend/` (snapshot-only) and `backoffice/`.
- [x] **Commit S boundary**: 3.1–3.9 + 4.1–4.6 land together (single-branch `size:exception`, no intermediate commit boundary enforced per the granted exception).

## Phase 5: D4 — Admin revocation (own commit)

- [x] 5.1 RED: mint token, admin `PATCH .../password` → target token `401 credentials_changed` on `/auth/me` and `/auth/refresh`; admin's own token stays `200`; `store()` sets the column; PATCH with only `name` leaves token valid; cross-tenant `404` unaffected — real RED observed (3/6 failed) before GREEN.
- [x] 5.2 RED: self-reset via admin route → acting token `401`, response body has no `access_token` — included in the same RED batch; required a `travel(2)->seconds()` fix in the test to clear the same-wall-clock-second edge case (`iat` vs `password_changed_at`, both second-precision).
- [x] 5.3 GREEN: `password_changed_at = now()->startOfSecond()` in `UserController::update()` (password branch) and `store()`.
- [x] 5.4 Full `./vendor/bin/pest` green (unfiltered) — 1698/1703 passed, 5 pre-existing environment-gated skips, 0 failed, 0 risky.

## Phase 6: D5 — API-key list (own commit)

- [x] 6.1 RED: 25 org-scoped clients → `data` has 25, no `meta`; demo seeder's 3 clients present — real RED confirmed (20 vs 25).
- [x] 6.2 GREEN: `ApiClientController::index` → `orderByDesc('is_active')->orderByDesc('created_at')->get()`.
- [x] 6.3 `ApiKeysPanel.vue:308` comment-only; trimmed `meta` from `autocomplete-hygiene.spec.ts`'s AND `settings-tabs.spec.ts`'s mocks (design named only the former; the latter also needed it).
- [x] 6.4 Playwright: `settings-tabs.spec.ts` (the actual "admin-flow/settings" file testing the API-keys panel) — added a 25-key mock/assertion test; verified locally (4/4 pass).

## Phase 7: D6 — Avatar-template per-knob errors (own commit; drop first per 1.3)

- [x] 7.1 RED (Pest): two bad knobs → `422`, `assertJsonValidationErrors(['config.avatarId','config.temperature'])` (used `avatarId`+`voiceSpeed` as the two bad knobs — `temperature`-named field does not exist on heygen; `llmTemperature` does, on a different section), `assertJsonMissingValidationErrors(['config'])`; unknown knob → `config.wat`; non-array `config` → bare `config`, no `config.*` — real RED confirmed.
- [x] 7.2 GREEN: `AvatarTemplateController::assertConfigValid` → `mapWithKeys` to `config.{key}`.
- [x] 7.3 `AvatarTemplateForm.vue` watcher: match `config.` key prefix; dropped `parseConfigError` call.
- [x] 7.4 Deleted `avatar-template-config-error.ts` + its spec; dropped the reciprocal comments in both files.
- [x] 7.5 Vitest: `avatar-template-form.spec.ts` (actual filename — not under `components/organisms/`) feeds the new error shape, asserts placement per control + unknown-in-summary + bare-`config`-in-summary. `avatar-templates-page.spec.ts` also updated (design's file list omitted it; found and fixed).

## Phase 8: D2/CI — Regeneration gate (depends on Phase 4; own commit)

- [x] 8.1 Pinned `APP_URL: http://localhost` in `api/.github/workflows/ci.yml`'s `env:` block.
- [x] 8.2 Added `git diff --exit-code openapi.json` immediately after `scramble:export`. Determinism was byte-stable (1.1), so the canonicalised-JSON fallback was not needed.
- [x] 8.3 `wrapper-ci.yml`: comment-only — mutual equality ≠ freshness.
- [x] 8.4 Deliberate red run: **done locally**, not via a scratch GitHub branch (not permitted to create branches/push in this session). Reverted `RoleResource`'s `@scramble-return` annotation, re-ran the exact CI sequence (`APP_URL` pinned, `scramble:export`, `git diff --exit-code openapi.json`) — confirmed exit 1 (gate fails). Restored the annotation, re-ran — confirmed the diff shrinks back to the pre-revert baseline. PHPStan/Pint/tests all green after restoration.

## Phase 9: D7 — Test noise (independent sub-fixes, own commits)

- [x] 9.1 `TenancyTest.php:31-35`: dropped `->throwsNoExceptions()`; asserts `TenantResolver::getOrgId()` is null before **and** after `beai:demo-seed`. Risky flag confirmed gone (0 risky in the full suite run).
- [x] 9.2 `ProvisionOrganizationCommand`: extracted `generatePassword()` seam (required removing `final` from the class, following the exact precedent already in this codebase — `QueueWorkCommand`/`RecordingQueueWorkCommand`, `tests/Helpers/QueueWorkCommandFixtures.php`); RED with a password containing `<info>`,`<`,`>`,`\` — confirmed real RED (the `<info>` tag was silently swallowed by Symfony's OutputFormatter); GREEN via `OUTPUT_RAW`.
- [x] 9.3 Captured `unsupported-gate.spec.ts:78`'s failure signature: **could not reproduce** (`--project=webkit --repeat-each=10`, `--retries=0`, trace on — 10/10 green in this environment). Reported as-is, per this task's own instruction not to guess a fix. `retries: 2` in CI may be masking an environment-specific (CI-machine-only) timing issue not reproducible here.
- [x] 9.4 Independently, unconditionally: reordered `unsupported-gate.spec.ts`'s `toHaveCount(0)` after a positive settle signal (`getByRole('heading', {level: 1})` visible) — the false-pass risk fix, applied regardless of 9.3's non-reproduction.
- [x] 9.5 `autocomplete-hygiene.spec.ts:132` (original line — now `:150`, "the project creation form" test, after the D5 `meta` trim shifted line numbers): mocked `GET /framework/roles/{roleCode}/competencies` (the endpoint `mockAdminApi` was missing); replaced one-shot `count()`/`getAttribute()` with retrying `toHaveCount`/`toHaveAttribute` per input. Note: could not directly observe `roleCode` being non-empty on initial "Nuovo progetto" mount in the current code (the role `<Select>` starts unselected, so `loadCompetencyOptions()`'s guard should skip the fetch) — applied the fix as instructed regardless, since it is unconditionally correct practice.
- [x] 9.6 Both specs green ten times on `--project=webkit --repeat-each=10`, `retries:0` (120/120 assertions across both files, single run covering all their tests × 10 repeats); CI's `retries: 2` stays as belt-and-suspenders.

## Phase 10: Final verification (full, unfiltered)

- [x] 10.1 `api/`: `./vendor/bin/pint --test` (passed); `./vendor/bin/phpstan analyse --no-progress --memory-limit=1G` (0 errors, run at 2G for the full-repo pass); `php artisan test --parallel` (1698/1703 passed, 5 pre-existing skips, 0 failed, 0 risky); `php artisan test --coverage --min=85` (94.6%, exit 0).
- [x] 10.2 `backoffice/`: `bun run typecheck` (0 errors); `bun run lint` (0 errors, pre-existing warnings only); `bun run test:unit` (660/660 passed, 88 files); `bun run codegen:check` (OK); `bun run test:e2e -- --workers=1` (127/127 passed across chromium/webkit/mobile); webkit `--repeat-each=10` for the two flagged specs done separately per 9.6.
- [x] 10.3 `task openapi:sync` idempotency: reran clean, zero diff (`openapi.json`, both `types/api.ts`).
- [x] 10.4 Locally: `wrapper-ci.yml`'s cross-repo `openapi.json` equality check (ran the same Bun canonical-JSON comparison locally — identical across all three) and both `check-client-drift.sh` (both OK).

## Phase 11: Post-verification reconciliation

Independent verification (separate pass, judgment-day-style) reproduced the
apply session's core findings from scratch: broke the CI gate on a
DIFFERENT resource and watched it go red; confirmed on raw PDO that ids are
native ints on PHP 8.5.7 (the `Project.php:86-88` note no longer holds);
reverted the five app files and got exactly 2 typecheck errors, matching
this session's count, not the design's estimate of 9; reproduced the
OutputFormatter password-mangling defect directly; confirmed only two
writers of `password_changed_at` exist; and independently read
`HasTranslations::getAttributeValue()` and confirmed D1 was right and
`tasks.md`'s original (now-corrected) 2.1 summary line was the wrong one.
Verification raised three items, closed here:

- [x] 11.1 **CRITICAL** — `bun run format:check` (Prettier) failed on
      `backoffice/tests/e2e/autocomplete-hygiene.spec.ts` (task 9.5 edits).
      Task 10.2 ran typecheck/lint/test:unit/codegen:check/test:e2e but never
      `format:check` — a real gate at `backoffice/.github/workflows/ci.yml:
      63-64`, immediately before typecheck. Fixed: `bunx prettier --write`
      on the one file (Prettier 3.9.5, matching what CI installs); diff is
      whitespace/wrapping only, no semantic change. `format:check` now green
      on both `frontend/` and `backoffice/` (frontend was already clean).
      Re-verified the reformatted file still passes webkit `--repeat-each=10`.
- [x] 11.2 **CRITICAL** — two of this change's own spec deltas described
      something other than what shipped:
      - `specs/admin-backoffice/spec.md`'s "API-Keys Table Shows Every Key"
        requirement still said the paginated envelope was unchanged and
        required the panel to read `links`/`meta`. Design D5 made the
        endpoint unpaginated instead — `response.data` alone is now
        correct. Reconciled the requirement text and all three scenarios to
        D5, with the WHY recorded inline (envelope-agreement bug class,
        `UserController::index` precedent, D5's ~200-key filter-before-
        paginate ceiling). Also fixed the same wrong claim ("translatable
        fields become objects") duplicated in this file's "Generated Client
        Parity" requirement.
      - `specs/admin-read-api/spec.md` still required translatable fields
        typed as an object, never a bare string — the opposite of what D1
        decided and what verification independently confirmed correct.
        Reconciled the requirement and its scenario to `string`, with the
        `HasTranslations::getAttributeValue()` evidence and the apply-phase
        falsifiability-check result recorded inline, plus an explicit note
        that an earlier draft of this same delta had it backwards.
- [x] 11.3 **WARNING**, documented rather than fixed — `task openapi:sync`
      is DB-driver sensitive: `api/.env` defaults to `DB_CONNECTION=sqlite`,
      and exporting against it silently produces a wrong `openapi.json`
      (SQLite-vs-Postgres JSON column introspection), regressing
      `AvatarTemplateResource.config`/`persona` and
      `Admin/SessionReviewResource`'s ints — none of which this change
      touches. CI is pinned to Postgres so this cannot merge silently, but a
      developer following the documented local workflow gets a phantom CI
      failure unrelated to their change. Documented at both places the
      command is documented: `Taskfile.yml`'s `openapi:sync` comment block
      (primary — the command definition itself) and
      `docs/api-versioning.md`'s "Client Update Protocol" section (the
      closest prose doc describing the same manual steps), each stating
      what to run instead (point `DB_CONNECTION` at a real Postgres
      instance matching CI's `pgvector/pgvector:0.8.0-pg17` service).

Two smaller items, also closed:

- [x] 11.4 `proposal.md` claimed the pre-existing defect typed translatable
      fields as `string`; `git show HEAD:types/api.ts` shows it was
      `unknown[]` (e.g. `RoleResource.name: unknown[]`) — corrected in the
      Intent section, with the verification command noted inline. Also
      fixed the same wrong "objects" claim in the Success Criteria
      checklist and checked off all six criteria (all verified true).
- [x] 11.5 `specs/avatar-templates/spec.md`'s "A single invalid knob still
      routes correctly" scenario had no covering test — every existing test
      used two or more invalid knobs. Added one API test
      (`AvatarTemplateConfigErrorKeysTest.php` — exactly one invalid knob
      among an otherwise-valid config, asserts the error payload has
      exactly one key) and one client test (`avatar-template-form.spec.ts`
      — asserts the single `config.{knob}` error lands on its own control,
      not the summary banner).

### Re-verified full gate list (post-reconciliation)

- `api/`: Pint (passed), PHPStan 2G (0 errors), `php artisan test --parallel`
  (1699/1704 passed, 5 pre-existing env-gated skips, 0 failed, 0 risky),
  coverage (94.6%, exit 0).
- `backoffice/`: `format:check` (passed), `typecheck` (0 errors), `lint` (0
  errors), `test:unit` (661/661, 88 files), `codegen:check` (OK), `test:e2e
  -- --workers=1` (127/127 across chromium/webkit/mobile).
- `frontend/`: `format:check` (passed), `typecheck` (0 errors), `lint` (0
  errors), `test:unit` (498/498), `codegen:check` (OK) — confirms the
  zero-call-site-change claim still holds after the resync.
- `openapi.json` re-export: still byte-identical (idempotent) after all
  fixes; all three repos' copies still cross-repo identical.

## Verification Commands (source of truth)

- `api/composer.json`: `composer test` (`artisan config:clear && artisan test`), `composer analyse` (`phpstan analyse --memory-limit=2G`) — **not** used for TDD iteration per the `--filter` fabrication note; use `./vendor/bin/pest <file>` or full unfiltered `./vendor/bin/pest`
- `backoffice/package.json`: `bun run typecheck`, `bun run lint`, `bun run test:unit`, `bun run test:e2e` (Playwright, `--workers=1`), `bun run codegen`, `bun run codegen:check`
- `api/.github/workflows/ci.yml`: `pint --test` → `phpstan analyse --no-progress --memory-limit=1G` → `migrate --force` → `test --parallel` → `test --coverage --min=85` → `scramble:export` → **freshness gate (`git diff --exit-code openapi.json`, new)** → file/version asserts → `docker build` → image smoke tests
- `.github/workflows/wrapper-ci.yml`: compose config + image-pin check, cross-repo `openapi.json` equality, both `check-client-drift.sh`, framework-catalog match, submodule-pointer reachability, guard self-test, stack-token consistency
- Root `Taskfile.yml`: `task openapi:sync`, `task test:api`, `task test:backoffice`, `task up`
