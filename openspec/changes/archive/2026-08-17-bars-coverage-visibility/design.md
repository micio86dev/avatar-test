# Design: BARS Coverage Visibility

## Technical Approach

Three deliverables, three independent commits, one rule: **a role×competency pair either has
behavioural anchors, or every surface that can act on it says so.** The API already computes the
fact (`CompetencyResource.bars_available`); the client stops discarding it and turns it into a
selection rule. CI stops asking the role question and starts asking the pair question, reusing the
known-gaps mechanism verbatim. The doc stops stating a derived number in prose.

No API change, no migration, no snapshot regeneration. Everything server-side already exists.

---

## D0 — Is `bars_available` fit for purpose? (verified, with two ceilings)

**Yes, and it is already pair-scoped.** `FrameworkController::roleCompetencies` (`:69-90`) resolves
the role, then computes `$barsCoveredIds` as `BarsIndicator::where('role_id', $role->id)
->distinct()->pluck('competency_id')`. The endpoint is `/framework/roles/{roleCode}/competencies`,
so the flag answers *"does THIS competency have anchors for THIS role"* — exactly the question the
picker must ask. Nothing needs recomputing.

| Question | Answer |
|---|---|
| Computed against the project's selected role? | Yes — `role_id` filter, per-role endpoint |
| What when no role is selected? | The endpoint is never called. `ProjectForm.loadCompetencyOptions` returns `[]` early (`:549-552`), so there are no options and nothing to disable |
| Does it re-evaluate on role change? | Already does — `watch([roleCode, assessmentType])` (`:710-713`) refetches and clears the selection |
| `potential` assessments? | **No flag at all.** `POTENTIAL_COMPETENCIES` (MTG/LAT) is built locally (`:397-400`) and never hits the catalog. See D2's tri-state |

**Ceiling 1 — DB truth vs file truth.** `bars_available` reads `bars_indicators` rows; the CI gate
reads the vendored JSON. They agree only because `FrameworkCatalogSeeder` is the sole writer and the
parity half of step (d) keeps the two trees identical. If they ever disagree, the seeder is the
reconciliation point. Recorded, not fixed here.

**Ceiling 2 — any row counts.** The flag is true if **one** indicator exists; the authoring
convention is three per competency (5/3/1). A half-authored pair reads as covered on both surfaces.
Not addressed in this slice; the gate below inherits the same threshold deliberately, so the two
mechanisms cannot disagree with each other.

---

## D1 — Where coverage is computed and how it reaches the picker

**Chosen**: thread the server's flag through unchanged; add no client-side coverage logic beyond
aggregation.

| Option | Tradeoff | Verdict |
|---|---|---|
| Add `bars_available` to `ProjectResource.competencies[]` so the list surface gets it free | Correct semantically, but drags in `task openapi:sync`, three `openapi.json` copies, two `types/api.ts`, and `DB_CONNECTION=pgsql` — for a count on a list page. The proposal's risk table says "no API change planned" | Rejected |
| Recompute coverage client-side from `/indicators` | A second definition of a fact the server already publishes. One fact, two vocabularies to drift between | Rejected |
| **Consume `bars_available` from the catalog endpoint; a `useBarsCoverage()` composable caches it per role code and both surfaces read that one cache** | One definition client-side, none server-side. ≤5 role codes exist, so the list page makes at most 5 extra requests | **Chosen** |

`ProjectForm.vue:555-570` stops dropping the flag. The list page (`pages/projects/index.vue`) asks
`useBarsCoverage()` for each distinct non-null `role_code` among the loaded projects and renders a
per-row count. **Fetch failure renders nothing, never zero** — an advisory count that is silently
wrong is worse than an absent one.

**Recorded promotion path**: if a project *detail* page or the report surface later needs this,
promote it to `ProjectResource.competencies[].bars_available` and delete the composable's
aggregation. There is no detail page today — `pages/projects/index.vue` + the edit dialog IS the
project surface.

---

## D2 — The disabled-but-removable rule, concretely

### The predicate

```ts
// CompetencyPicker.vue
selectable(option) = option.barsAvailable !== false || persistedIds.includes(option.id)
```

**Only an explicit `false` disables.** `CompetencyOption.barsAvailable` is typed
`boolean | null` and is **required**, not optional:

| Value | Meaning | Source |
|---|---|---|
| `true` | Anchors exist for this role×competency | catalog endpoint |
| `false` | No anchors — disabled for new selection | catalog endpoint |
| `null` | The coverage question does not apply | `POTENTIAL_COMPETENCIES` (MTG/LAT are not role-anchored) |

Required-not-optional is load-bearing: an optional field lets a construction site forget, and
`undefined` would silently mean "selectable". `boolean | null` makes the compiler demand an answer
at every site, and `null` is a stated *not applicable*, not an accident. `POTENTIAL_COMPETENCIES`
sets `null` explicitly with that reason in a comment.

### Create flow

`persistedIds` is `[]` — nothing is persisted yet, so the second branch is structurally empty and
every uncovered competency is disabled. Correct: there is no existing commitment to honour.

### Edit flow, and the role-change transition

`persistedIds` is **scoped to the role the set was persisted under**:

```ts
const persistedIds = computed(() =>
  roleCode.value === props.project?.role_code
    ? (props.project?.competencies ?? []).map((c) => c.id)
    : []
)
```

Without the role comparison the escape hatch leaks: `watch([roleCode, assessmentType])` already
clears `competencyIds` on a role change, so a stale `persistedIds` would re-enable competencies that
are no longer selected under a role they were never attached to.

**`role_code` IS immutable once active — verified, three layers deep.** `Project::booted()`
(`Project.php:132-138`) throws when `role_code` is dirty and the current *or* resulting status is
`active`/`archived`; `UpdateProjectRequest::withValidator` (`:136-145`) 422s the same case;
`ProjectForm.vue:114` disables the Select via `lockedWhenLive`. So *"an attached competency becomes
uncovered because the role changed"* is reachable **only while the project is a draft** — and on a
draft the operator is still composing, so losing the selection is correct, not a trap.

### The scope finding that makes this rule implementable at all

**`ProjectForm` never hydrates and never submits `competency_ids`.** `competencyIds` is initialised
to `[]` (`:421`), never read from `props.project.competencies`, and appears in **neither** the
`createProject` nor the `updateProject` payload (`:634-663`). The picker's value is collected and
dropped. `ProjectController::update` only calls `sync()` when the key is present (`:159-165`), which
is the only reason nothing has broken.

Consequence: success criterion *"an already-selected uncovered competency … can be removed"* is
unreachable without fixing this, so hydration + submission are **in scope by necessity**.

> **Hydration and submission MUST land in the same commit.** Adding `competency_ids` to the payload
> while `competencyIds` still initialises to `[]` makes the next save of every existing project call
> `sync([])` and wipe its competency set. This is the single highest-risk line in the change.

---

## D3 — Server-side counterpart: deliberately none, stated plainly

**The API still accepts an uncovered `competency_id`.** The guard is client-only in this slice.

| Option | Tradeoff | Verdict |
|---|---|---|
| Blanket server-side rejection | 422s an existing project re-submitting its current set — the remediation path this change is building | Rejected |
| Delta-only rule (reject only newly-added uncovered ids) | Correct shape, but needs a per-request coverage query in two FormRequests, an audit of live data, and re-verification that Scramble's derived schema does not move (the repo has a determinism gate on it). Real work, and it is not what makes the operator's next click safe | Deferred, shape recorded |
| **Client-only, documented** | The picker is the only surface that composes a competency set today | **Chosen for this slice** |

**Correction to the framing: M2M and SSO are not exposed, because they cannot reach this at all.**
Project CRUD is registered once, under `auth:api` + `TenantContext` only (`api/routes/api.php:86-88`).
There is no M2M project route and no SSO project route — the SSO surface links participants to
projects that already exist. The actual uncovered paths are: a direct `/api/projects` call with an
operator JWT (curl, a script, a future client), and seeders / `DemoWriter`. That is a smaller and
more precisely stated exposure than the proposal assumed.

---

## D4 — The per-competency CI gate

### A second file, not an extension — for a mechanical reason

`scripts/framework-competency-gaps.txt`, **new**. Merging pair entries into
`framework-known-gaps.txt` would corrupt the older gate: `known_gap_roles()` (`ci-guards.sh:566-570`)
takes the first whitespace field of each line, so a `FLL:PRS` line becomes a *role code* named
`FLL:PRS`, which `catalog_stale_gap_exemptions` then looks for at `bars/FLL:PRS.json`, never finds,
and which `catalog_unexpected_missing_bars` reports as an unexplained missing role. Two questions,
two keys, two files. A separate `CI_COMPETENCY_GAPS_FILE` override also mirrors the existing
self-test seam with no interference.

### Format

`ROLE:COMP`, one per line, `#` to end of line is a comment. Ordered **by role, then by competency**,
grouped under a per-role comment header — an authoring specialist works one role at a time, and the
diff that closes a role should be contiguous. The `:` separator is unambiguous: both codes match
`^[A-Z][A-Z0-9_]{1,15}$`, so neither can contain one. **No counts in the headers** — the count is
the number of lines under it, which cannot disagree with itself.

### 26 entries, not 44 — the composition rule

The pair gate asks its question **only of roles whose `bars/<ROLE>.json` exists**. The role gate owns
"no file"; the pair gate owns "file exists but is partial". Together they cover all 83 declared pairs
with no pair declared twice.

| Role | Declared | Anchored | Pair entries |
|---|---|---|---|
| ICO | 15 | 15 | 0 |
| FLL | 18 | 8 (STG INN CSF OPX INS INF RES LRN) | 10 |
| MLL | 18 | 8 (same set) | 10 |
| BUL | 14 | 8 (same set) | 6 |
| SRX | 18 | file absent | 0 — covered by the existing role-level `SRX` entry |
| | **83** | **39** | **26** |

The proposal's 44 counts SRX's 18 pairs. Listing them would put SRX in *both* control files and make
the day `SRX.json` lands a 19-line deletion. Under this rule that day is a clean red instead: the
role exemption goes, and the pair gate names exactly which of the 18 are still missing. **This is a
deliberate departure from the proposal's number**, argued rather than assumed.

**The list is generated, not typed**: `catalog_missing_bars_pairs docs/app_description/02-domain/framework`
run against the authored tree, output committed verbatim.

### Functions added to `scripts/ci-guards.sh`

`known_gap_pairs`, `role_competency_pairs <tree>`, `bars_competency_keys <tree> <ROLE>`,
`catalog_missing_bars_pairs <tree>`, `catalog_unexpected_missing_bars_pairs <tree>`,
`catalog_stale_competency_gap_exemptions <tree>` — mirroring the existing shape exactly, and
inheriting this file's hard-won rules verbatim:

1. **Failure propagates.** `CI_PAIRS=$(role_competency_pairs "$1") || return 1`, captured to a
   variable *before* the loop. `role_competency_pairs | while` reports the loop's status and
   discards the failure — the exact defect `catalog_missing_bars` documents at `:519-525`.
2. **Fail loudly, never fall through.** The bun scripts assert shape and `process.exit(1)` with a
   diagnostic: `roles.json` an object whose every value has a `competencies` **array** of role-code-
   shaped strings; a bars file an **object** keyed by competency code. Unreadable JSON, wrong shape,
   or no bun on PATH is a guard that FAILED TO RUN — `df_guard`'s stated rule (`:127-128`).
3. **An empty array is NOT coverage.** `"PRS": []` is a stub, not an anchor set, and must count as
   missing. Without this rule the cheapest way to green the gate is to stub the key.
4. **Stale in two directions per pair.** `FLL:PRS` listed while `bars/FLL.json` now carries a
   non-empty `PRS` → error until the line is deleted. And `FLL:PRS` listed while `roles.json` no
   longer assigns PRS to FLL → also an error: the exemption excuses a pair that no longer exists,
   which is the same note-outliving-its-fact defect.
5. POSIX `sh`. `shellcheck -s sh` and `dash -n` stay clean on the file and on every `run:` block that
   sources it, with `# shellcheck disable=SC2016` where JS template literals must reach bun intact.

### Detection fixtures (step (f)) — the half that makes it a guard

A guard nobody has watched fail is not a guard. Every row below is required:

| Fixture | Must |
|---|---|
| `pair-incomplete` — FLL declares [STG, PRS], bars has STG, list has `FLL:PRS` | **PASS** — the state the repo is actually in; a gate that cannot go green gets deleted |
| same tree, list emptied | **CATCH** `FLL:PRS` — undeclared pair |
| `pair-closed-gap` — bars now has PRS, list still has `FLL:PRS` | **CATCH** — stale exemption |
| `pair-empty-anchor` — `"PRS": []`, list empty | **CATCH** as missing — proves rule 3 |
| `pair-orphan` — roles.json drops PRS from FLL, list still has `FLL:PRS` | **CATCH** — proves rule 4's second direction |
| `pair-no-file` — a role with no bars file | **emit nothing** — proves the role gate is not double-reported |
| `pair-malformed` / bars-is-an-array / `competencies`-not-an-array | **non-zero**, and `catalog_unexpected_missing_bars_pairs` must not swallow it — mirrors `:983-1009` |
| both real trees | `catalog_stale_competency_gap_exemptions` clean — mirrors `:876-883` |

Plus a **deliberate red run on a scratch branch before merge, both directions**: delete one line from
the gaps file → wrapper job red; add a competency key to `bars/FLL.json` → wrapper job red on the
stale direction. Then restore.

---

## D5 — The documentation fix

`docs/app_description/02-domain/01-roles-and-competencies.md:78` — *"File completi: ICO.json, FLL.json,
MLL.json, BUL.json"* — is replaced by a pointer, **in Italian** (the file's language), with **no
numbers in prose**:

> Copertura BARS. Non tutte le coppie ruolo×competenza dichiarate in `roles.json` hanno ancore
> comportamentali. L'elenco esatto è nei due file di controllo CI —
> `scripts/framework-known-gaps.txt` (ruoli senza alcun file BARS) e
> `scripts/framework-competency-gaps.txt` (coppie ruolo×competenza senza ancore) — mantenuti esatti
> in entrambe le direzioni dallo step (d) di `.github/workflows/wrapper-ci.yml`: una coppia scoperta
> e non elencata fa fallire la CI, e un'esenzione la cui lacuna è stata colmata fa fallire la CI
> finché non viene rimossa.

| Option | Tradeoff | Verdict |
|---|---|---|
| Per-role coverage counts in the doc table (the proposal's wording) | A derived number in prose is *precisely* the defect being fixed. It is correct on the day it is written and rots on the day the first FLL competency is authored | **Rejected** |
| Counts in the doc + a third CI mechanism that recomputes and diffs them | Honest, but a whole new gate to maintain so a doc table can carry numbers a reader can get from the control file | Rejected |
| **A pointer to the two gate-enforced files** | The authoritative count lives where CI already forces it exact in both directions. Nothing to re-derive, nothing to rot | **Chosen** |

Recorded departure from the proposal, argued here rather than silently ignored.

---

## D6 — UI copy and i18n

### Where the reason goes

The picker is `FieldSet > FieldLegend + FieldDescription + grid of Field(horizontal) > Checkbox +
FieldLabel`.

| Placement | Verdict |
|---|---|
| Tooltip | **Rejected.** A disabled control does not take focus and does not reliably emit hover events; a reason reachable only by hovering a disabled checkbox is a reason nobody reads, and it is not in the accessibility tree |
| Badge | **Rejected.** A badge is a label, not a reason — it repeats "no anchors" without saying what that costs the operator |
| **Per-option `FieldDescription` inside each option's `Field`, bound via `aria-describedby` on the `Checkbox`** | **Chosen.** Same primitive and same "disabled control with a stated reason" pattern `ProjectForm` already uses for `immutableWhenLive` (`:106-108`, `:150-152`), and the same `describedBy` a11y discipline (`:451-457`). The option `Field` is `orientation="horizontal"`, so label + description wrap in a column — a layout change, not a new primitive |
| **Group line: a second `FieldDescription` in the `FieldSet`, `v-if` count > 0** | **Chosen.** Mirrors `ProjectForm`'s conditional-second-description precedent |

An already-attached uncovered competency gets a **different** message from a disabled one: it is
selectable, and the operator's action is to remove it.

### Keys (both `it` and `en`, never a bare literal)

| Key | en | it |
|---|---|---|
| `projects.competencyPicker.noBars` | No behavioural anchors for this role yet — it cannot be assessed, so it cannot be selected. | Nessuna ancora comportamentale per questo ruolo — non è valutabile, quindi non è selezionabile. |
| `projects.competencyPicker.attachedNoBars` | Already in this project but has no behavioural anchors for this role — it will not be scored. Remove it to fix the report. | Già presente in questo progetto ma senza ancore comportamentali per questo ruolo — non verrà valutata. Rimuovila per correggere il report. |
| `projects.competencyPicker.coverageSummary` | {missing} of {total} competencies have no behavioural anchors for this role yet. | {missing} competenze su {total} non hanno ancora ancore comportamentali per questo ruolo. |
| `projects.table.uncoveredCompetencies` | {count} without anchors | {count} senza ancore |

### Arch guards — defended, not hoped

| Guard | Why it stays green |
|---|---|
| `form-contract` | Scans only files containing `<form`. `CompetencyPicker.vue` has none, so R1/R2/R3 never apply to it. `ProjectForm.vue` keeps `novalidate`, keeps its `FieldError` import, and keeps calling `applyServerFieldErrors` — R3 is file-level and already satisfied. The new composable is `.ts`, outside the scan |
| `destructive-action` | R1's regex is `\b(?:delete\|remove\|revoke\|archive\|destroy\|import\|activate\|deactivate)[A-Z]\w*\(`. **Deselection must stay inside the existing `toggle(option, checked)`** — naming anything `removeCompetency(` would force a `ConfirmDialog` import into a checkbox grid and put pressure on a deliberately empty allowlist. No new destructive-looking identifier in any `.vue` file; no `confirm(`/`alert(` (R2) |
| `date-render` | No `*_at` interpolation is added anywhere. The list-surface count renders an integer |

---

## D7 — Testing strategy (strict TDD)

**Runner discipline.** `php artisan test --filter` was observed fabricating passes in this
environment — use `./vendor/bin/pest <exact-file>` while iterating and a full unfiltered
`./vendor/bin/pest` before the PR. Playwright is `--workers=1`; **extend existing specs, add no
files**. Vitest via `bun run test:unit`.

| Claim to prove | Layer | Test |
|---|---|---|
| **Disabled but removable** | Vitest `CompetencyPicker.spec.ts` | An option with `barsAvailable: false` NOT in `persistedIds` → checkbox `disabled`. The **same** option with its id in `persistedIds` **and** in `modelValue` → not disabled, and clicking emits `update:modelValue` without that id. That pair of assertions is the entire rule |
| The reason is announced, not merely visible | Vitest | The disabled checkbox's `aria-describedby` resolves to the element rendering `noBars`; an attached-uncovered option renders `attachedNoBars` instead |
| No bare literals | Vitest | Every new key exists in **both** `i18n/locales/it.json` and `en.json` |
| **Role-change re-evaluation** | Vitest `ProjectForm.spec.ts` | Mock `fetchRoleCompetencies` with different coverage for FLL and ICO, then **drive the role `Select`** — not call `loadCompetencyOptions` directly. Assert the options' flags flip and `persistedIds` collapses to `[]`. The archived note is explicit that the last regression here survived because unit tests mocked the composable and never drove the select |
| **Hydration + submission (the data-loss guard)** | Vitest | Edit mount with `project.competencies = [{id: 7, …}]` → picker `modelValue` is `[7]`; submit → `updateProject` called with `competency_ids: [7]` |
| Omitting the key still leaves the pivot alone | Pest Feature | `PATCH /api/projects/{id}` without `competency_ids` → pivot unchanged. Documents why nothing has broken so far |
| List-surface count | Vitest `pages/projects/index.spec.ts` | Mocked coverage → row shows the count; a fully covered project shows nothing; a failed coverage fetch shows nothing (never `0`) |
| End to end | Playwright, extend `projects-crud.spec.ts` | Mock `/framework/roles/FLL/competencies` with mixed `bars_available`: uncovered checkbox disabled on create; open a project holding an uncovered competency → checked **and** enabled; untick, save, reopen, gone. Reuse `autocomplete-hygiene.spec.ts`'s framework-endpoint mock rather than writing a second one |
| **The gate catches a NEW uncovered pair** | ci-guards self-test | `pair-incomplete` with the list emptied → caught |
| **…while passing today's tree** | ci-guards self-test + wrapper (d) | `pair-incomplete` with `FLL:PRS` listed → passes; the real trees with the committed 26-line file → green |
| **The stale direction** | ci-guards self-test | `pair-closed-gap` and `pair-orphan` → both caught |
| The guard can fail for real | CI, manual | Deliberate red run on a scratch branch, both directions, before merge |
| The shell contract holds | CI | `shellcheck -s sh scripts/ci-guards.sh` and `dash -n` clean, on the file and on the new `run:` blocks |

### RED-first order of work

1. **RED (shell)** — fixture trees + `expect_caught` rows in `wrapper-ci.yml` step (f). Observed
   failing (functions undefined) before a line of implementation.
2. **GREEN (shell)** — the six functions in `ci-guards.sh`; self-test green.
3. **Generate** `scripts/framework-competency-gaps.txt` from `catalog_missing_bars_pairs`; wire step
   (d)'s two direction blocks; **deliberate red run**, both directions; restore.
4. **RED (Vitest)** — picker predicate + a11y; role-change re-evaluation; hydration + submission.
5. **GREEN (client)** — `barsAvailable: boolean | null`, `persistedIds` prop and predicate,
   per-option `FieldDescription` + `aria-describedby`, group line; `ProjectForm` mapping, hydration,
   `competency_ids` in **both** payloads; `it` + `en` keys.
6. **RED/GREEN** — `useBarsCoverage` + the list-surface count.
7. **E2E** — extend `projects-crud.spec.ts`.
8. **Doc** last: it describes the state the gate now enforces.
9. Full `./vendor/bin/pest`, `bun run test:unit`, `bun run test:e2e`, `backoffice/tests/unit/arch/`.

### Commit split (400-line review budget)

| Commit | Contents | Independently revertible |
|---|---|---|
| C1 | `ci-guards.sh` + gaps file + `wrapper-ci.yml` (d) and (f). Largest — the self-test rows are verbose | Yes |
| C2 | Picker + `ProjectForm` + i18n + unit tests. **Hydration and submission must be inside this one** | Yes |
| C3 | `useBarsCoverage` + list-surface count | Yes |
| C4 | The doc paragraph | Yes |

---

## File Changes

| File | Action | Description |
|---|---|---|
| `scripts/ci-guards.sh` | Modify | Six pair functions + `CI_COMPETENCY_GAPS_FILE` |
| `scripts/framework-competency-gaps.txt` | **Create** | 26 generated `ROLE:COMP` entries, role-grouped, with the two-direction rationale header |
| `.github/workflows/wrapper-ci.yml` | Modify | Step (d) pair blocks; step (f) fixture rows |
| `backoffice/app/components/molecules/CompetencyPicker.vue` | Modify | `barsAvailable: boolean\|null` + `persistedIds` props; predicate; per-option reason + `aria-describedby`; group line |
| `backoffice/app/components/organisms/ProjectForm.vue` | Modify | Map the flag; `persistedIds` computed; **hydrate `competencyIds`**; **submit `competency_ids` in both payloads** |
| `backoffice/app/composables/useBarsCoverage.ts` | **Create** | Per-role-code coverage cache over `useFrameworkRoles` |
| `backoffice/app/components/organisms/ProjectTable.vue` | Modify | Per-row uncovered count |
| `backoffice/app/pages/projects/index.vue` | Modify | Resolve coverage for the distinct role codes |
| `backoffice/i18n/locales/{it,en}.json` | Modify | Four keys each |
| `backoffice/tests/unit/**`, `tests/e2e/projects-crud.spec.ts` | Modify | Per D7 |
| `docs/app_description/02-domain/01-roles-and-competencies.md` | Modify | Line 78 → the pointer paragraph |
| `api/**` | **Unchanged** | `bars_available` already correct; no snapshot movement |

## Open Questions

- [ ] None blocking. The delta-only server rule (D3) is deferred by decision, with its shape
      recorded; it needs an audit of live `project_competencies` rows before it can be specified.
