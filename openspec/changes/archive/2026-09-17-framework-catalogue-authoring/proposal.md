# Proposal: Framework Catalogue Authoring

## Intent

The framework catalogue — 5 roles, 18+2 competencies, 249 BARS indicators — is a
**seed-only** artifact. `FrameworkCatalogSeeder` (`api/database/seeders/FrameworkCatalogSeeder.php:169`)
reads JSON from `database_path('framework')` and writes it into `framework_roles`,
`framework_competencies`, `framework_bars_indicators` and the `framework_role_competency`
pivot. There is **no HTTP write path to any of those tables**. Changing a single anchor
means editing two JSON trees, re-running a seeder against production, and hoping.

A platform superadmin must be able to author the catalogue from the backoffice. The
product owner chose this knowing it forces the re-architecture C3 deferred, because the
trade-off was stated in the option they picked.

**The re-architecture is not optional decoration on top of a CRUD.** `framework_roles`,
`framework_competencies` and `framework_bars_indicators` carry **no version column**.
`FrameworkVersion` is tenant-scoped but is **not a snapshot** — it is an `is_locked` flag
that `Project.framework_version_id` points at, and scoring always reads the single live
catalogue. So a superadmin who fixes a typo in a COL anchor today does not change future
evaluations: they retroactively change **what every already-scored evaluation meant**.
An evaluation records `framework_version`, and that recorded value would now be a lie.

Separately, the questions the avatar asks are authored **per project and nowhere else**.
`project_questions` exists and works (see below), but its only writer is an operator
clicking in a drawer, so **every new project starts at zero questions**. There is no
catalogue-level default to inherit from.

## Verified current state

| Claim | Evidence |
|---|---|
| The per-project question layer is **built and working** — do not rebuild it | `api/database/migrations/2026_09_02_171638_create_project_questions_table.php` (org+project scoped, `competency_id` FK `restrictOnDelete`, `text` json locale map, `position`, soft deletes, partial unique on `(project_id, competency_id, position) WHERE deleted_at IS NULL`); `api/app/Http/Controllers/Api/ProjectQuestionController.php` — index/store/update/reorder/destroy |
| Its UI is built too, and **buried** | `backoffice/app/components/organisms/ProjectQuestionsPanel.vue` — 625 lines, grouped by competency, dual-locale, drag reorder, cap display. Mounted lazily **inside the project edit drawer** at `backoffice/app/pages/projects/index.vue:62` |
| The `potential` cap is a **maximum**, deliberately | `api/app/Http/Requests/StoreProjectQuestionRequest.php:162-180` — reads `PlatformSettings::maxQuestionsPerCompetency()` and refuses only `$existing >= $max`. Zero is legal |
| That cap is a superadmin knob, not a tenant one | `api/app/Support/Settings/PlatformSettings.php:26-45`; `SuperadminController:157-166` (`GET`) and `:168+` (`PATCH`). Default `['standard'=>1,'potential'=>4]` |
| Authored questions already reach the interview, additively and mandatorily | `InterviewController::authoredQuestionsFor()` (~`:1386`) → `api/app/Services/Conversation/OpeningTextComposer.php` and `SystemPromptComposer::compose()`. LLM follow-ups are never persisted — already correct |
| Catalogue tables are **global and unversioned** | `framework_roles`, `framework_competencies`, `framework_bars_indicators` carry no `organization_id` **and no version/revision column** |
| `FrameworkVersion` is a flag, not a snapshot | `openspec/specs/framework-catalog/spec.md` — `is_locked` only; nothing copies catalogue rows at pin time |
| The seeder freezes mutation **platform-wide** the instant any one tenant locks | `openspec/specs/framework-catalog/spec.md:459-516`; `api/tests/Feature/C4/Seeder/SeederLockGuardTest.php`. The guard queries `withoutGlobalScopes()` — one locked FV anywhere stops catalogue mutation for everyone |
| CI enforces the catalogue invariants by reading **JSON files**, never the DB | `scripts/ci-guards.sh:1378` (`role_competency_pairs()` reads `$1/roles.json`), `:2346-2355` (exactly 3 indicators, `scale` keys exactly `1,3,5`), `:549` (`CI_NON_ROLE_BARS_FILES`) |
| There are **two** JSON trees, kept in parity by a gate | authored `docs/app_description/02-domain/framework/` and vendored `api/database/framework/`. `scripts/framework-known-gaps.txt:45-47` records that a parity-only gate stayed green over SRX because "the two copies agreed, and both were wrong" |
| Four CI control files are keyed to those trees | `scripts/framework-{known-gaps,competency-gaps,crossrole-baseline,locale-gaps}.txt` |
| The shipped question feature has **no completed SDD record** | `openspec/changes/potential-competencies-and-authored-questions/` contains `proposal.md` and nothing else — no `specs/`, no `design.md`, no `tasks.md`, never archived. Code comments cite the change name; `openspec/specs/` has no entry |
| "4 fixed questions" is asserted in **three** documents the code contradicts | `CLAUDE.md` (binding domain constraints), `docs/app_description/02-domain/03-assessment-types.md:23`, `openspec/specs/interview-conversation/spec.md:25` |
| Superadmin RBAC precedent is a repeated inline guard, on purpose | `api/app/Http/Controllers/Api/PlatformUserController.php` — `abort_unless($this->isSuperadmin($request), 403)` at the top of **every** action, because Scramble only infers OpenAPI responses from what a controller visibly does; hiding it dropped the 403 from 3 of 5 routes. `User.is_superadmin` is not `$fillable`; `Gate::before` short-circuits globally |
| Standalone superadmin CRUD page precedent | `backoffice/app/pages/avatar-templates/index.vue` |

## Scope

### In Scope

| # | Deliverable |
|---|---|
| 1 | **Catalogue revisions.** An immutable-once-published revision is the unit `FrameworkVersion` pins. Catalogue rows become revision-scoped. This is the change; everything else is a surface on it. |
| 2 | **Superadmin CRUD over competencies** — code, name, definition, `{en,it}` locale maps, `potential`/`standard` applicability. |
| 3 | **Superadmin CRUD over roles** and their competency assignment (the `framework_role_competency` pivot). |
| 4 | **Superadmin CRUD over BARS indicators** — exactly 3 per role×competency pair, anchors `{5,3,1}`, all locale-mapped. |
| 5 | **Catalogue-level default questions per competency**, authored by the superadmin, ordered, dual-locale — the template `project_questions` rows are copied from. |
| 6 | **Copying defaults into `project_questions`** at a defined lifecycle point (**see OQ-1 — not settled**). |
| 7 | **Write-time invariant enforcement + DB constraints** for everything `scripts/ci-guards.sh` currently proves over files (D3). |
| 8 | **Backoffice platform-scope Catalogue pages** + a `catalogue.manage` ability, following `PlatformUserController`'s visible-403 doctrine and `avatar-templates/index.vue`'s page shape. |
| 9 | **Reconcile the seeder lock-guard** with revision immutability (D2). |
| 10 | **Correct "4 fixed questions" → "up to 4, default 4" in all three documents** that assert it: `CLAUDE.md`, `docs/app_description/02-domain/03-assessment-types.md:23`, `openspec/specs/interview-conversation/spec.md:25`. The PO confirmed `CLAUDE.md`; the other two are the same sentence in two more places, and leaving them is the exact defect this repo has already paid for twice. |
| 11 | **Write the missing spec for the shipped question layer** — `openspec/specs/` has no record of `project_questions` at all. |
| 12 | **Audit-log every catalogue write** (actor, revision, before/after). |
| 13 | **`DESIGN.md` updated before any UI code**, per `CLAUDE.md`. |
| 14 | Tests per project policy: Pest, Vitest, Playwright (chromium + webkit + the mobile SA-11 gate), i18n `{en,it}` in both locale files. |

### Out of Scope

- **Retargeting a live project to a newer revision.** `CLAUDE.md` ruling 3 stands untouched
  and RATIFIED: `framework_version` is pinned at project creation and never retargeted. An
  opt-in retarget mechanism is a different change with a different consent model.
- **Per-tenant catalogue authoring.** Only a platform superadmin writes. An org admin
  customises **its own project's** question copies, which already works. Nothing here gives
  an organization a write path to shared domain content.
- **Rebuilding `project_questions`, `ProjectQuestionController`, or `ProjectQuestionsPanel`.**
  They work. Relocating the panel is OQ-3; rewriting it is not in scope either way.
- **Changing how authored questions reach the interview.** `authoredQuestionsFor` →
  `OpeningTextComposer`/`SystemPromptComposer` is correct and untouched. Follow-ups stay
  adaptive and unpersisted.
- **Raising or removing the `potential` cap**, or migrating existing projects to carry 4
  questions. Up to 4, zero allowed, no backfill.
- **Deleting a competency, role or indicator that a published revision references.**
  Removal is a next-revision operation, never a destructive edit to a pinned one.
- **Authoring non-English anchor content.** Ruling 6 (`CLAUDE.md`) is unchanged — this
  change ships the surface that makes expert translation possible, not the translations.
- **Any change to the scoring engine's arithmetic**, the `{1,2,3,4,5,-1}` set, the
  `-1` exclusion rule, or `reliability`.

## Capabilities

### New Capabilities

- `catalogue-authoring`: the platform-superadmin write surface over the framework
  catalogue — revision lifecycle (draft → published → pinned → immutable), the CRUD
  contracts for roles/competencies/BARS indicators, catalogue-level default questions and
  their projection into `project_questions`, the `catalogue.manage` ability, and every
  invariant enforced at write time rather than by a file gate.

### Modified Capabilities

- `framework-catalog`: catalogue rows become revision-scoped; `FrameworkVersion` resolves
  to a revision instead of standing alone; the platform-wide seeder lock-guard
  (`spec.md:459-516`) is superseded by revision immutability (D2); the seeder becomes the
  writer of the **baseline** revision only.
- `project-config`: a new project inherits the catalogue defaults into `project_questions`
  (OQ-1); the `potential` question count is stated as a maximum, not a fixed four.
- `interview-conversation`: the out-of-scope note at `spec.md:24-27` asserting "4 fixed
  questions" is corrected. The consumption path itself does not change.
- `ci-pipeline`: the catalogue guards' **subject** is stated explicitly — the baseline JSON
  trees, not runtime rows — and the DB-side obligations that replace them are named (D3).
- `admin-backoffice`: a platform-scope Catalogue nav entry, its ability, and its route-guard
  map entry.
- `audit-log`: catalogue mutations are auditable events.

## Approach

### D1 — A revision is the snapshot; `FrameworkVersion` points at one

Today `FrameworkVersion` says *that* a tenant is pinned and never *to what*. The fix is to
give it something real to point at: an immutable catalogue **revision**, platform-global
(the catalogue is global; only the pin is tenant-scoped).

- The seeder writes the **baseline** revision from the JSON trees. That path is unchanged
  in spirit and stays the bootstrap for a fresh database.
- A superadmin edit opens (or continues) a **draft** revision. Drafts are freely mutable
  and are pinned by nothing.
- **Publishing** freezes a revision. From that point its rows are immutable, full stop —
  not "immutable while something references it", which is a rule that can silently unfreeze.
- Scoring resolves `Project → FrameworkVersion → revision → rows`. An evaluation's recorded
  `framework_version` becomes a claim that can be re-derived, which today it cannot.

**The rejected alternative** is a `snapshot_json` column on `framework_versions` capturing
the catalogue at pin time. It is cheaper and it is wrong for this product: the anchors would
stop being queryable, `BarsIndicatorLoader` would parse JSON per scoring run, and the
per-role/per-pair invariants would become unenforceable in SQL exactly when they start
being written by humans through a form.

**Migration shape** — the baseline revision must be created such that every existing
`framework_versions` row resolves to it and no already-scored evaluation changes meaning.
`CLAUDE.md`'s "no legacy backward compatibility — greenfield" governs **external contracts**
(API, webhook, ID formats) and does not license breaking our own persisted history. An
evaluation scored last month must still resolve its anchors. This is a data migration with
a correctness obligation, not a greenfield rewrite, and it is the highest-risk task in the
change.

### D2 — Revision immutability supersedes the platform-wide seeder freeze

The lock-guard (`openspec/specs/framework-catalog/spec.md:459-516`) makes the seeder purely
additive the moment **any** `FrameworkVersion` anywhere has `is_locked = true`. Projects
exist, so that condition is already true. An HTTP CRUD that honoured it verbatim would be a
feature that cannot write on the day it ships.

The honest reading is that the lock-guard is a **proxy** for the guarantee this change
delivers properly. It freezes everything because it cannot tell which rows a scored
evaluation actually read. Revisions can tell. So:

- **Published revisions**: immutable. Stricter than today — no additive insert either,
  where the guard currently permits one.
- **Draft revisions**: fully mutable, by the seeder and by the HTTP path alike.
- The guard is not relaxed, exempted or annotated around. It is **replaced by a narrower
  rule that protects more**, and `SeederLockGuardTest.php` is rewritten against the
  revision rule rather than deleted.

An HTTP CRUD that merely *ignored* the guard would defeat it silently. That outcome is the
thing this decision exists to prevent.

### D3 — The CI gates keep their subject; the DB gets its own enforcement

`role_competency_pairs()` (`ci-guards.sh:1378`) and the 3-indicator/`{1,3,5}` check
(`:2346-2355`) read `roles.json` and `bars/*.json`. A DB-writing CRUD is structurally
invisible to them. Three options were considered.

**Option A — the gate learns to read the database.** Rejected. The wrapper's guards run on
a git tree with no database; teaching them otherwise means standing up PostgreSQL, seeding
it, and granting CI credentials before a shell gate can assert anything. It also makes a
deterministic gate depend on mutable state, and the four control files
(`framework-{known-gaps,competency-gaps,crossrole-baseline,locale-gaps}.txt`) are keyed to
file trees, so each would need a second, differently-shaped form.

**Option B — DB writes regenerate the JSON.** Rejected. It only works where a git working
tree exists. A superadmin editing an anchor in production cannot commit to a repository, so
the export is either a dev-only illusion or a third copy that drifts — and this repo has
already shipped a parity gate that stayed green over two identical wrong files
(`framework-known-gaps.txt:45-47`).

**Chosen — Option C: split the subject, and enforce each half where it lives.**

- The JSON trees remain the **baseline** and the CI gates keep governing them, unchanged
  and exactly as strict. Not one `!=3` is relaxed.
- Every invariant those gates prove gets a **runtime twin**: FormRequest validation, a
  database `CHECK`/partial-unique where expressible, and Pest coverage at the ~95%
  correctness-critical tier — exactly-3-indicators per published pair, `scale` keys exactly
  `{1,3,5}`, non-blank locale maps, no cross-role duplicate anchor text, `CI_NON_ROLE_BARS_FILES`
  semantics for MTG/LAT.
- A **read-only export command** renders any revision back to the JSON shape, so a revision
  can be reviewed as a diff and the baseline trees can be refreshed deliberately by a human
  in a PR. Export, never auto-commit.
- The two counts stay distinct and are asserted separately: **83** role×competency pairs
  (ICO 15, FLL 18, MLL 18, BUL 14, SRX 18) and **85** anchored competencies (the 83 plus
  MTG and LAT, which belong to no role).

### D4 — Catalogue defaults are a template, copied; they are never read at interview time

`potential-competencies-and-authored-questions` AD-2 ruled that questions are per project,
not per framework version, so an operator can fix a typo on a live project without fighting
ruling 3's immutability. **That ruling stands.**

Catalogue defaults do not contradict it because they are a **source to copy from**, not a
source to read from. The interview path is unchanged: `authoredQuestionsFor` reads
`project_questions` and only `project_questions`. Once copied, a project's rows are its
own — editing a catalogue default never reaches back into a project that already has copies.

A default whose competency is not in the project's competency set is not copied at all.

### D5 — Superadmin-only, with the 403 visible in every action

`catalogue.manage` gates rendering; it is not the access control. Every controller action
repeats `abort_unless($this->isSuperadmin($request), 403)` inline, following
`PlatformUserController` — that repetition is deliberate and documented, because Scramble
infers OpenAPI responses from what a controller visibly does and a shared helper dropped the
403 from 3 of 5 generated routes. Publishing a new ability group means regenerating
`openapi.json` in all three repos before `AbilityKey` accepts the string.

No `organization_id` appears anywhere in this surface. There is no tenant read path to widen
and no cross-tenant surface created: the catalogue was already global, and only the writer
is new.

## Open questions — raised, deliberately not answered

These are the decisions this proposal refuses to make on the product owner's behalf.

**OQ-1 — When are catalogue defaults copied into `project_questions`?**
`Project::booted()` (`api/app/Models/Project.php:~155-191`) locks `assessment_type`,
`role_code` and the competency set only once status ∈ {`active`, `archived`}. During
`draft`, competencies can still change — so copying at creation risks seeding the wrong
competency's defaults and leaving orphan rows the operator must delete. Candidate answers:
at creation (simple, wrong-competency risk), at the draft→active transition (correct set,
but the operator cannot preview or edit questions while still drafting), or an explicit
operator "load defaults" action (honest and discoverable, one more click, and ambiguous on
re-click). Not settled.

**OQ-2 — Do default-question edits freeze under revision immutability, like anchors do?**
Anchors must freeze: they are the scoring instrument and a change rewrites what a score
meant. Default questions are not scored — they only determine what gets asked, and they are
copied rather than read. Freezing them is consistent; not freezing them is arguably more
useful and costs nothing in determinism, because a project's copies are already independent.
Not settled.

**OQ-3 — Does `ProjectQuestionsPanel` move out of the project edit drawer?**
The product owner's "non le vedo" is a discoverability report about a feature that exists
(`backoffice/app/pages/projects/index.vue:62`). Relocating it to a project-scoped tab or
page is a `DESIGN.md` decision and touches a 625-line component with its own tests. It is
listed in scope as a decision to take, not as a settled relocation.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `api/database/migrations/` | New | Revision table; revision FK on the four catalogue tables; catalogue default questions; the baseline-revision data migration (D1) |
| `api/app/Models/{Role,Competency,BarsIndicator,FrameworkVersion}.php` | Modified | Revision scoping; `FrameworkVersion` resolves a revision |
| `api/database/seeders/FrameworkCatalogSeeder.php` | Modified | Writes the baseline revision; lock-guard replaced by the revision rule (D2) |
| `api/app/Http/Controllers/Api/` (new catalogue controllers) | New | Competency / role / indicator / default-question CRUD, each action with a visible 403 (D5) |
| `api/app/Http/Requests/` (new) | New | The runtime twin of every file gate (D3) |
| `api/app/Services/Conversation/BarsIndicatorLoader.php` | Modified | Resolves indicators through the pinned revision |
| `api/app/Services/Conversation/{OpeningTextComposer,SystemPromptComposer}.php` | **Untouched** | Consumption is already correct |
| `api/app/Http/Controllers/Api/ProjectQuestionController.php`, `StoreProjectQuestionRequest.php` | **Untouched** | The per-project layer is not rebuilt |
| `api/app/Support/Authorization/UserAbilities.php` | Modified | `catalogue.manage` group |
| `api/routes/api.php` | Modified | Superadmin catalogue routes |
| `api/tests/Feature/C4/Seeder/SeederLockGuardTest.php` | Modified | Rewritten against revision immutability (D2), not deleted |
| `api/app/Console/Commands/` (new) | New | Read-only revision → JSON export (D3) |
| `scripts/ci-guards.sh` + the four `framework-*.txt` control files | **Untouched** | Must stay green and stay exactly as strict (D3) |
| `docs/app_description/02-domain/framework/`, `api/database/framework/` | Modified | Refreshed only by a deliberate human PR from the export |
| `backoffice/app/pages/catalogue/` | New | Platform-scope CRUD pages, shaped after `avatar-templates/index.vue` |
| `backoffice/app/components/organisms/SidebarNav.vue`, `middleware/03.abilities.global.ts` | Modified | Nav entry + route-guard map |
| `backoffice/app/components/organisms/ProjectQuestionsPanel.vue`, `pages/projects/index.vue:62` | Possibly moved | OQ-3 only |
| `backoffice/i18n/locales/{en,it}.json` | Modified | Every new string, both locales |
| `{api,frontend,backoffice}/openapi.json` | Modified | Three snapshots move together |
| `CLAUDE.md`, `docs/app_description/02-domain/03-assessment-types.md:23`, `openspec/specs/interview-conversation/spec.md:25` | Modified | "4 fixed" → "up to 4" in all three (scope #10) |
| `DESIGN.md` | Modified | Before any UI code |

`api` and `backoffice` are git submodules: every slice is a submodule PR plus a wrapper
pointer bump. `frontend` is not touched.

## Invariants that must not break, and how

| Invariant | How it is held |
|---|---|
| Ruling 3 — a live project is never retargeted | Retarget is explicitly out of scope; a pin resolves to one revision and publishing a newer one never moves it |
| An already-scored evaluation still means what it meant | D1's baseline revision + the data migration; a Pest test re-resolves a pre-migration evaluation's anchors and asserts byte-identical text |
| Exactly 3 indicators per pair, anchors `{5,3,1}` | File gates unchanged for the baseline; FormRequest + DB constraint + ~95% Pest for runtime writes (D3) |
| 83 role×competency pairs; 85 anchored competencies | Asserted separately, in both the file gate and the DB twin (D3) |
| Scoring determinism (`temperature=0`, versioned model/prompt/framework) | Published revisions are immutable — strictly stronger than today's guard (D2) |
| Roles are exactly five | Role CRUD may edit the five; creating a sixth is refused at the write layer, per `potential-competencies-and-authored-questions` AD-1 |
| A tenant never sees another tenant's data | No `organization_id` appears in this surface; only a platform superadmin writes; no read widens |
| MTG/LAT belong to no role | `CI_NON_ROLE_BARS_FILES` semantics mirrored in the DB twin; a role-less indicator stays role-less |
| Follow-up questions stay adaptive and unpersisted | The consumption path is untouched |

## Migration and back-compat

`CLAUDE.md` says "no legacy backward compatibility (API/webhook/ID formats): greenfield".
That rule is about **external contracts** and it applies here: no compatibility shim for any
pre-existing catalogue API shape is owed, and the read endpoints may change freely.

It does **not** apply to persisted history. Evaluations already scored carry
`framework_version`, `model_version`, `prompt_version` precisely so a score can be explained
later, and a migration that makes those unresolvable would destroy the product's audit story.
So: forward migrations reversible per D22, one baseline revision, every existing
`framework_versions` row resolving to it, and a test that proves a pre-migration evaluation
still resolves its exact anchors.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| The baseline data migration silently re-points an evaluation's anchors | **Low, severity CRITICAL** | D1; the pre-migration resolution test is written RED first, before the migration |
| A DB write violates an invariant CI can no longer see | **High without D3** | D3 — every file gate gets a runtime twin at the ~95% tier; the file gates stay unmodified |
| The seeder guard is defeated silently by the HTTP path | Med | D2 — replaced by a stricter rule, `SeederLockGuardTest` rewritten, not removed |
| The JSON trees and the DB drift into two truths | **Med** | D3 — export-only, never auto-commit; the baseline trees are refreshed by a reviewable human PR. This repo has already shipped two identical wrong files past a parity gate |
| Default questions copied for the wrong competency set | Med | OQ-1 is flagged as blocking before `sdd-design` |
| Scope is large enough to exceed the 400-line review budget several times over | **High** | Chained PRs, slice boundaries below; the revision migration ships and is verified before any CRUD surface exists |
| "4 fixed questions" is corrected in one document and left in two | Med | Scope #10 names all three files explicitly |
| `AbilityKey` rejects `catalogue.manage` until three snapshots regenerate | Med | Sequence the OpenAPI export inside the API slice; `bun run codegen:check` is the gate |

## Changed-line forecast and delivery

The revision re-architecture alone touches four tables, the seeder, the loader and a data
migration. Rough estimate **≈ 2,500–3,500 changed lines** across two submodules plus the
wrapper, excluding generated `openapi.json` churn.

Indicative slice boundaries (`sdd-tasks` owns the final split):

| PR | Slice | Repo |
|---|---|---|
| 1 | Revisions + baseline data migration + loader resolution + the pre-migration resolution test | `api` |
| 2 | Seeder rewritten against revision immutability; `SeederLockGuardTest` rewritten (D2) | `api` |
| 3 | Competency + role + indicator CRUD with the runtime invariant twins (D3) and audit | `api` |
| 4 | Catalogue default questions + the copy-into-`project_questions` path (OQ-1) | `api` |
| 5 | Export command (D3) | `api` |
| 6 | `DESIGN.md`, `CLAUDE.md`, the two other "4 fixed" documents, the missing question-layer spec | wrapper |
| 7 | Backoffice catalogue pages, ability, nav, route guard, i18n, Vitest | `backoffice` |
| 8 | Playwright E2E (chromium + webkit + mobile SA-11) | `backoffice` |

`400-line budget risk: High` · `Chained PRs recommended: Yes` · `Decision needed before apply: Yes`

## Rollback Plan

Revert in reverse chain order.

- **PR 8/7**: `backoffice` only. The pages and nav entry disappear; the API keeps answering.
- **PR 6**: documentation, reverts alone.
- **PR 5/4/3**: additive — new tables, controllers, routes, one command. Revert removes them
  with no residue; regenerate the three OpenAPI snapshots.
- **PR 2**: restores the previous seeder and its test.
- **PR 1** is the one that is **not** cheap to revert, because it carries a data migration.
  Its `down()` must restore the pre-revision shape with the baseline rows intact, and that
  reversibility is a task with its own test, not an assumption. Until PR 1 is verified in a
  Railway-like environment against real data, nothing downstream ships.

## Dependencies

- `openspec/specs/framework-catalog/spec.md` — the seeder lock-guard contract being superseded.
- `potential-competencies-and-authored-questions` — shipped in code, SDD chain incomplete.
  Its AD-1 (`role_id` nullable, not a sixth role) and AD-2 (questions per project) are
  **consumed and preserved**, not amended. Its missing spec is written here (scope #11).
- `CLAUDE.md` ruling 3 (framework pin) — consumed unchanged.
- Three `openapi.json` snapshots regenerated together, exported against **PostgreSQL**,
  never SQLite (`api/CLAUDE.md`).
- Pest run as `cd api && ./vendor/bin/pest <exact-file>` or a full run — never
  `php artisan test --filter`, observed fabricating passes in this repo.
- No new package in any submodule. Nothing touches D25.

## Success Criteria

- [ ] A platform superadmin can create, edit and reorder competencies, roles, BARS
      indicators and catalogue default questions from the backoffice.
- [ ] An org admin, operator and viewer receive **403** on every catalogue write route, and
      see no Catalogue nav entry.
- [ ] Publishing a revision freezes it: a subsequent write to any of its rows is refused.
- [ ] A project pinned before this change resolves the **same** anchor text after the
      migration — asserted byte-for-byte on a pre-migration evaluation.
- [ ] Editing an anchor in a new revision does **not** change any already-scored evaluation.
- [ ] A published revision always satisfies: exactly 3 indicators per pair, `scale` keys
      exactly `{1,3,5}`, non-blank `{en,it}` locale maps, 83 pairs, 85 anchored competencies —
      asserted against the **database**, not the files.
- [ ] `scripts/ci-guards.sh` and the four `framework-*.txt` control files pass **unmodified**.
- [ ] A new project inherits the catalogue defaults for its competencies (per OQ-1's answer),
      and editing a catalogue default afterwards does not alter that project's copies.
- [ ] A `potential` project remains savable with 0–4 questions per competency; no existing
      project is migrated.
- [ ] "4 fixed questions" reads as a default in `CLAUDE.md`,
      `docs/app_description/02-domain/03-assessment-types.md` and
      `openspec/specs/interview-conversation/spec.md`.
- [ ] `openspec/specs/` contains a spec for the `project_questions` layer.
- [ ] Every catalogue write produces an audit-log entry naming actor, revision and delta.
- [ ] Every user-facing string resolves in `en` and `it`; no hardcoded copy.
- [ ] `bun run codegen:check` green in all three repos.
- [ ] Coverage: 85% overall; ~95% on revision resolution, the invariant twins and the
      superadmin gate.
- [ ] Playwright green on chromium + webkit; the catalogue pages redirect to `/unsupported`
      on the mobile project.

## Blocking before `sdd-design`

**OQ-1** must be answered — it determines a migration, a controller action and a UI
affordance. **OQ-2** and **OQ-3** can be answered during design without re-slicing.
