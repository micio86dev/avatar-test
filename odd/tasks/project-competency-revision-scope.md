# Fix: project competency picker rejects valid competency ids (competency_unknown)

## Reported symptom
Org admin in backoffice, creating/editing a project: selecting competencies and
submitting fails with `422 competency_unknown` on `competency_ids.0`/`.1`, even
though the POST payload clearly carries `competency_ids: [41, 42]`.

## Root cause (verified, not the user's original guess)
NOT a frontend checkbox bug — the frontend already sends the ticked ids
correctly. It's a revision-scoping mismatch between the READ and WRITE sides
of the project's competency composition:

- WRITE (`api/app/Http/Requests/StoreProjectRequest.php:111`,
  `UpdateProjectRequest`/`ValidatesProjectComposition`): `competency_ids.*`
  must exist in `framework_competencies` scoped to the **target
  `framework_version_id`'s own pinned catalogue revision**
  (`CatalogueRevisionResolver::tryForFrameworkVersion()`).
- READ (`api/app/Http/Controllers/Api/FrameworkController.php:99`
  `roleCompetencies()`, `:144` `potentialCompetencies()` — the endpoints
  `backoffice/app/components/organisms/ProjectForm.vue`'s `CompetencyPicker`
  calls to populate the checkboxes): always scoped to `latestPublishedOrSentinel()`
  — the **globally latest published revision**, ignoring which
  `framework_version_id` is selected in the form.

Because a `FrameworkVersion.revision_id` is pinned once at creation and never
retargeted (`FrameworkVersion::assignLatestPublishedRevisionIfUnset()`,
CLAUDE.md ruling 3), and `framework_competencies` rows are a full per-revision
clone (`CatalogueRevisionResolver` class docblock — different `id` per
revision, same code), any org whose `framework_version_id` is pinned to a
revision older than "latest published" (catalogue republished since) gets a
picker showing ids from the WRONG revision. The server correctly refuses them.

## Second, related symptom (user's follow-up mid-session)
On EDIT, competencies show under the picker but no default questions appear
under them in `ProjectQuestionsPanel`, and the operator cannot override them.

Root cause: `ApplyCompetencySelection::apply()` only seeds
`project_questions` (copied from `framework_default_questions`) for the
`attached` DIFF a `sync()` call reports — never for competencies that were
already attached before this write path existed, or that got stuck
half-configured because of the bug above. `ApplyCompetencySelection::
ensureCompetencyHasQuestions()` already exists, is documented as a safe no-op
when live questions already exist, and is exactly the tool
`BackfillProjectQuestionsCommand` uses for this same situation platform-wide
— it's just never invoked from `ProjectController::update()`'s own save path.

## Fix plan
1. `api/app/Http/Controllers/Api/FrameworkController.php`: `roleCompetencies()`
   and `potentialCompetencies()` accept an optional `framework_version_id`
   query param and resolve the revision the same way
   `StoreProjectRequest::compositionRevisionId()` does — mirror, don't
   duplicate the logic ad hoc.
2. `backoffice/app/composables/useFrameworkRoles.ts`: thread
   `frameworkVersionId` through `fetchRoleCompetencies`/
   `fetchPotentialCompetencies` as a query param.
3. `backoffice/app/components/organisms/ProjectForm.vue`: pass
   `frameworkVersionId.value` to both fetch calls in `loadCompetencyOptions()`;
   add `frameworkVersionId` to the watcher that reloads options and clears the
   ticked set (currently only `[roleCode, assessmentType]`).
4. `api/app/Http/Controllers/Api/ProjectController.php::update()`: call
   `ApplyCompetencySelection::apply()`'s "attached" branch for the FULL
   currently-selected competency set post-`sync()`, not just the diff — safe
   self-heal per `ensureCompetencyHasQuestions()`'s own documented contract.
5. Tests (TDD, strict mode — RED first):
   - Pest regression in `api/tests/Feature/C4/` reproducing the exact
     production defect: two published revisions, an org's `FrameworkVersion`
     pinned to the OLDER one, `GET .../competencies?framework_version_id=`
     must return that older revision's ids, and `POST /api/projects` with them
     must succeed (was 422). Companion test: an id from the newer revision is
     still correctly refused against the older pin (precision, not "accept
     everything").
   - Pest regression for the self-heal: a project with a competency attached
     but zero `project_questions` (simulating "attached before this path
     existed") gets them populated on the next PATCH.
   - Playwright e2e (`backoffice/tests/e2e/`): this suite is FULLY
     network-mocked (documented in `projects-crud.spec.ts`'s own header) — it
     cannot exercise real backend validation, so it cannot be the test that
     "catches" the original 422. Add a mock-layer assertion that the frontend
     actually sends `framework_version_id` on the competency-options request,
     which DOES guard against a future frontend regression.
6. Re-export OpenAPI spec (Postgres, per `api/CLAUDE.md`) if the contract
   changed; regenerate backoffice's typed client (`bun run codegen`) if so.
7. `pint --dirty`, `phpstan analyse`, run the affected Pest files, run the
   affected Vitest/Playwright files.

## Status
- [x] 1. Backend: revision-scope `roleCompetencies`/`potentialCompetencies` — `FrameworkController::targetRevisionId()`
- [x] 2. Frontend: thread `framework_version_id` through the composable — `useFrameworkRoles.ts`
- [x] 3. Frontend: `ProjectForm.vue` wiring + watcher
- [x] 4. Backend: self-heal default questions on PATCH — `ProjectController::update()`
- [x] 5. Tests: Pest (5, `ProjectCompetencyRevisionScopeTest.php`), Vitest (5 across `useFrameworkRoles.spec.ts` + `ProjectForm.spec.ts`), Playwright (+1 in `projects-crud.spec.ts`) — all RED→GREEN verified
- [x] 6. OpenAPI export — byte-identical, no client regen needed (raw `$request->query()` reads, not Scramble-introspected)
- [x] 7. pint clean, phpstan clean (1 real issue found+fixed: redundant `array_values()`), api full suite 3592/3599 passed (7 pre-existing skips), backoffice eslint/typecheck/vitest/playwright all green
- [x] 8. Native review (gentle-ai, RDD): both submodule candidates reviewed and approved (medium risk), advisory findings only, none blocking — verified against existing code (cross-org/invalid `framework_version_id` degrades to latest-published, matching `StoreProjectRequest`'s own documented behavior; repeated-PATCH idempotency confirmed by `ApplyCompetencySelection`'s own no-op branch)

## Commits (local only, not pushed)
- `api` `fix/project-competency-revision-scope`: `6952b0e`
- `backoffice` `fix/project-competency-revision-scope`: `82ddc71`

## Done
Both root causes fixed, tested, reviewed. Remaining decision for the user: push branches / open PRs (not done — delivery is the user's call).

## Branches
- `api` submodule: `fix/project-competency-revision-scope` (off `develop`)
- `backoffice` submodule: `fix/project-competency-revision-scope` (off `develop`)
