# Proposal: Potential Competencies and Authored Opening Questions

## Intent

Two capabilities the product describes as existing, and does not have. They are one
change because they are blocked by the same missing thing.

**1. `assessment_type: potential` cannot be used at all.** `StoreProjectRequest`
refuses every attempt with `POTENTIAL_CATALOG_INCOMPLETE`, because
`Competency::whereIn('code', ['MTG','LAT'])->count()` is 0. `CLAUDE.md` lists MTG and
LAT as binding domain content; `FrameworkCatalogSeeder.php:584` records both as
`missing_potential_competency` / `pending_authoring` on every run.

**2. The questions the avatar asks are not stored anywhere.** There is no table, no
model, no CRUD. `SystemPromptComposer` instructs the LLM to open with a question and
add at most N follow-ups, derived from the competency's BARS indicators. An operator
cannot see, edit, reorder or replace any of it.

## Why one change and not two

The blocker is the same, and it is structural rather than editorial.

`framework_bars_indicators.role_id` is **NOT NULL**. BARS indicators are the scoring
instrument, and a `potential` project has `role_code = null` by rule — enforced by
`StoreProjectRequest::validatePotential()`. So there is currently **no way to store an
indicator for MTG or LAT at all**, and no way to store a question that is not scoped to
one of the five roles either.

Authoring the MTG/LAT text without that change would produce two competencies that
cannot carry indicators, so a `potential` project would become creatable and then fail
to score — strictly worse than refusing it up front, which is what the code does today
and is the correct behaviour under the current schema.

## Scope

- `framework_bars_indicators.role_id` becomes nullable, meaning **"not role-scoped"**.
- MTG and LAT authored in `competencies.json` and a new role-less BARS catalogue file,
  bilingual `{en, it}` like every other entry.
- The seeder loads them and records the gap **only when they are genuinely absent**
  (today it records it unconditionally).
- A `project_questions` table: the PREDEFINED questions per competency per project,
  ordered, editable, soft-deleted. One list serves both types — see AD-4.
- Backoffice CRUD with drag-and-drop ordering, for `admin` and `superadmin`.

## Out of scope, deliberately

**Follow-up questions stay adaptive.** Only the predefined ones become authored.

This is not a compromise reached to protect `CLAUDE.md`'s "adaptive questions"; the
binding domain docs already specify exactly this, and reading them corrected the design.
`docs/app_description/02-domain/03-assessment-types.md`:

  standard  — "The first question per competency MAY BE PREDEFINED; the following ones
               are decided by the AI in real time"
  potential — "4 PREDEFINED QUESTIONS per competency, followed by AI follow-ups"

So authored questions were always the specification and were simply never built. The
product owner's instruction (2026-09-02) — *"le domande principali devono essere
gestibili... quelle di followup devono rimanere adattative"* — matches the document
rather than amending it, and no ruling has to be reversed.

## AD-4 — One ordered list per (project, competency), not two shapes

`standard` allows ONE predefined question and `potential` requires FOUR. Modelling that
as two mechanisms would put the assessment type inside the storage layer, where it does
not belong and would have to be re-checked on every read.

It is one ordered list. The TYPE decides how many entries are valid, which is a
validation rule and lives where the other assessment-type invariants already live —
`StoreProjectRequest`/`UpdateProjectRequest`, beside the existing `competencies ⊆
{MTG, LAT}` and `role_code must be null` checks. `SA-08` asserts the four; nothing about
the table needs to know why.

## AD-1 — `role_id` nullable, NOT a sixth role

A synthetic `POTENTIAL` row in `framework_roles` would also let these indicators exist,
and is rejected. `CLAUDE.md` fixes the roles at exactly five — ICO, FLL, MLL, BUL, SRX —
as a binding constraint, and every read that lists roles would have to learn to hide the
sixth. A nullable FK says the true thing: this indicator belongs to a competency and to
no role.

Consequences that must be handled rather than discovered:

- `BarsIndicatorLoader::forRoleCompetency(int $roleId, int $competencyId)` takes a
  non-nullable int. It gains a role-less path; the existing signature keeps its
  cross-role contamination guarantee for `standard`.
- The uniqueness index that includes `role_id` must become a partial index, or two
  role-less indicators for one competency collide in a way NULL semantics hide.

## AD-2 — Questions are per project, not per framework version

A question is an operator's phrasing choice, not domain content. Putting it on the
framework version would freeze it behind the same immutability the catalogue has
(ruling 3: `framework_version` is pinned at project creation and never retargeted),
so an operator could never fix a typo on a live project.

`SoftDeletes`, and for a specific reason rather than as a default: a deleted question is
still referenced by interviews already conducted under it. A hard delete would make an
existing transcript unexplainable.

## AD-3 — Ordering is an integer `position`, reindexed on write

Drag-and-drop sends the whole ordered list, and the server rewrites positions in one
transaction. Fractional ranking would avoid the rewrite and is not worth it here: a
project has a handful of questions, and a scheme nobody can read in `psql` costs more in
debugging than it saves in writes.

## Decision: `POTENTIAL.json` lives in `bars/`, and is DECLARED there

`potential` is an assessment type, not a role. Its two competencies (MTG, LAT)
appear in no role's `competencies` array, so they sit outside the 83
role×competency pairs the rest of the catalogue governs.

Two options were considered:

1. Move the file out of `bars/` into its own location. Conceptually tidier, but
   it splits one authoring format across two directories, duplicates the
   vendored-tree parity check, and gives the anchors a second shape to drift
   into — for a file that is BARS in every respect that matters.
2. Keep it in `bars/` and declare it as a non-role catalogue file.

Chosen: **2**, with the exception named explicitly in
`CI_NON_ROLE_BARS_FILES` rather than inferred from the filename, and with the
missing mirror guard added: every `bars/<X>.json` must name a declared role or
appear in that list.

The mirror guard is the real fix here. Every completeness check in this repo ran
one direction — `roles.json` declares a role, does its bars file exist — so any
`.json` dropped into `bars/` was silently promoted to a role: shape-checked for
3 indicators, measured against the leader anchor ceiling, made a peer in
cross-role duplicate detection, while getting zero pair coverage and zero
role-level accounting. A file nobody listed is a file nobody decided on.
