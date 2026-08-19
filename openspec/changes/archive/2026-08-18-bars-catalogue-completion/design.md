# Design: BARS Catalogue Completion — 44 Missing Role×Competency Pairs

## Technical Approach

This is a content change with two forced code fixes. The architecture that matters is
the **authoring pipeline**, not the runtime: 396 anchor texts must be produced in an
order, against a written standard, in a shape a reviewer can actually adjudicate, and
landed in slices that keep both CI gates green at every commit.

Four artefact layers:

| Layer | Artefact | Nature |
|---|---|---|
| Standard | House voice + anti-hedge rule (this document, §Decisions 1–2) | Written once, binding |
| Judgment | Per-competency scope-shift tables, `docs/app_description/02-domain/framework-authoring/scope-shift/{COMP}.md` | Hand-written, committed, permanent |
| Content | `bars/{FLL,MLL,BUL}.json`, staged `SRX.partial.json` | Authored, gated |
| Verification | `scripts/ci-guards.sh` shape/identity checks + Pest seeder tests + advisory differentiation report | Mechanical |

Rule: **judgment is committed, derivable output is generated.** The scope-shift tables
are not reproducible from the JSON, so they are committed. The 5-role review table is
reproducible, so it is generated per PR and never committed.

---

## Architecture Decisions

### 1. House voice — extracted, not invented

Read: `bars/ICO.json` in full, plus all 24 leader pairs across FLL/MLL/BUL.

**Indicator** (leader files, the form all 44 new pairs follow):
bare infinitive, no subject, **no terminal period**, 6–16 words, one observable act,
never names the competency, uses `own` as the possessive determiner
(`own team`, `own area`, `own positions`). ICO deviates — third-person `-s` and
terminal periods (`Recognizes symptoms that indicate problems.`) — and is the wrong
model here because every new pair is a leader role.

**Anchor**: subject-elided third-person present. Leader files run **one sentence,
10–18 words**; ICO runs two sentences, 20–30 words. Follow the leader files.

| Level | Shape |
|---|---|
| 5 | Strong verb or quality/frequency adverb first (`Consistently`, `Proactively`, `Builds`, `Champions`), often closing with an impact clause (`with measurable returns`) |
| 3 | Opens with a verb naming **what is done**. This is where the house breaks (§2) |
| 1 | Deficit verb first (`Fails to`, `Struggles to`, `Rarely`, `Avoids`, `Neglects`, `Resists`, `Does not`), usually closing with a consequence clause (`leading to confusion or misalignment`) |

Register: no second person, no `the candidate`/`the employee` as subject, no modal
obligation, no numeric targets, business vocabulary no heavier than `SWOT`.
Orthography: `-ize` spellings; ASCII apostrophe only (legacy mixes U+2019 — do not
propagate); do not copy legacy typos (`memebers`, `clariry`, `Demostrate`).

An anchor names a **behaviour**, not a frequency of the indicator. The indicator is
the act; the anchor is how that act is performed and on what object.

### 2. The anti-hedge rule, and the honest limit of checking it

**Rule.** Strip every degree/hedge marker from the three anchors of one indicator. If
what remains at level 5 and level 3 is the same verb acting on the same object, the
indicator is rejected. The three levels must differ by at least one of: the **object**
acted on, the **action** taken, or the **scope/audience** reached. A degree adverb may
reinforce an already-different behaviour; it may never be the only difference.

**Is a mechanical check feasible? Partly, and it must not be sold as the control.**
Measured against the two worked examples in the catalogue:

| Legacy example | Content-token Dice(L5,L3) after hedge-strip | Caught at ≥0.6? |
|---|---|---|
| `ICO/INN #1` (bad, same sentence reworded) | ≈0.60 | Yes |
| `ICO/STG #1` (bad, degree-only but reworded) | ≈0.16 | **No** |

A hedge **word list** is worse still: it false-positives on legitimate uses (`FLL/CSF`
*"Occasionally asks for feedback"* is a correct level-3 for an indicator whose act is
itself a frequency).

**Decision**: no hedge word list as a gate. CI-blocking mechanical checks are limited
to shape, completeness and cross-role identity (§7). The similarity number and the
hedge-marker rate ship as a **non-blocking report** printed into every content PR,
with a documented ceiling: **≤30% of new level-3 anchors may carry a hedge marker**
(legacy baseline 76%; ICO 89%). Exceeding the ceiling does not fail the build; it
fails review. The binding gate is the written rubric above, applied by a human against
the scope-shift table.

### 3. SRX responsibilities — the calibration axis, authored first

`roles.json` gives four ordered rows on four axes. SRX is authored as **one step above
BUL on every axis, with no new axis invented**:

| Role | Horizon | Span | Money | Breadth |
|---|---|---|---|---|
| ICO | daily–weekly | own area | within budget | no managerial duty |
| FLL | weekly–monthly | small area / department | operating costs | one functional unit |
| MLL | ~1 year | small country | revenue vs cost | one or two related functions |
| BUL | 1–2 years | country or region | full P&L | multiple business functions |
| **SRX** | **3–5 years** | **whole organization / multi-country** | **capital allocation, consolidated P&L** | **all functions, leads other leaders** |

**Authored text** (both trees, `roles.json`, exact house sentence shape):

> Responsible for setting organizational direction and long-term strategy with a
> multi-year focus (3-5 years) across the entire organization or a multi-country
> region, owning capital allocation and consolidated P&L across business units, and
> leading other senior leaders across all business functions.

**Evidence used**, stated so it can be challenged: (a) the four-row ladder above, read
verbatim from `roles.json`; (b) `01-ruoli-e-competenze.md` line 20 *"Livello
executive"* and line 53 *"Set ampio executive"*; (c) SRX's own competency set — it
keeps `TMG`, `INS`, `SLF`, `COM`, `ITG`, `INC`, so SRX leads people and faces
customers; it is **not** a staff or advisory role, and must not be authored as one.
Nothing else was used. This text is deliverable #1 and is settled before any SRX anchor.

### 4. JDG and TMG go FIRST

**Choice**: author `{FLL,MLL,BUL,SRX} × {JDG,TMG}` before anything else.

**Rationale**: every other competency can be calibrated against an already-shipped
worked example. JDG and TMG have none, so they set their own precedent — and a
precedent set *last* is calibrated against 36 pairs of same-day draft rather than
against the 39 pairs that already shipped. A systematic ladder error in JDG discovered
early costs 4 pairs of rework; discovered last, nothing catches it at all.

**Counter-argument, honestly**: authoring them first means authoring them before the
author has re-internalised the voice by writing 36 pairs. **Resolution**: the voice
risk is removable by an artefact (§1, written before any authoring); the calibration
risk is not. Calibration wins.

Consequence: SRX responsibilities (§3) must be settled before the first sweep, because
`SRX:JDG` is in it.

### 5. The seeder's two defects

**5a — gaps are recorded and never resolved.** `FrameworkCatalogSeeder` `updateOrCreate`s
`competency_no_bars` / `role_no_bars` / `missing_role_meta` at
`FrameworkCatalogSeeder.php:173,220,310` and nothing ever moves them off
`pending_authoring`.

| Option | Tradeoff | Decision |
|---|---|---|
| One-off cleanup command | Fixes today's rows, leaves the defect for the next closed gap | Rejected |
| Delete the row | Irreversible; a re-opened gap becomes indistinguishable from a never-recorded one | Rejected |
| **Seeder-side, `status = 'resolved'`** | Reversible, keeps the audit trail, matches the success criterion's wording ("zero **pending**") | **Chosen** |

`status` is a plain `string` column with no enum constraint (migration
`2026_07_17_111655`), so `resolved` is legal today. `FrameworkGap` has **no API or
service consumer** — only the model, the seeder and tests reference it — so no read
path breaks. Four resolution points, all computed from the just-read JSON (not DB
state, so they work under lock), all exempt from the lock-guard because
`framework_gaps` is already declared an operational table in the seeder header:

- `missing_role_meta` → resolve when `responsibilities !== ''`
- `role_no_bars` → resolve when `bars/{ROLE}.json` exists
- `competency_no_bars` → resolve when the pair is covered
- `competency_no_bars` orphan → resolve when `roles.json` no longer assigns the pair
  (mirrors CI Direction 2 of `catalog_stale_competency_gap_exemptions`)

**5b — SRX `responsibilities` is silently swallowed under a locked FrameworkVersion.**
`FrameworkCatalogSeeder.php:159` skips `setTranslation` for any pre-existing `Role`
row, so the 132 new indicator rows land (new by natural key) while the one field this
change depends on does not.

**Choice**: narrow the lock-guard to a **fill-empty-only exception** for
`Role.responsibilities` — under lock, if the stored `en` value is empty/null and the
JSON supplies a non-empty one, write it and emit a `locked_fill_empty_role_meta`
FrameworkGap + `Log::warning`. `name` is never touched under lock; a non-empty value is
never overwritten.

**Rationale**: `responsibilities` is display-only — `grep` finds exactly one consumer,
`RoleResource.php:40`; it feeds no scoring and no prompt. Filling an empty descriptive
field cannot move a score in a locked version, which is what the lock exists to protect.
**Rejected**: unlock→seed→relock (defeats the contract), and manual SQL on production
(correct once, then depends on a human remembering it in the next locked environment).

### 6. Making 396 texts reviewable

A top-to-bottom diff of 396 strings is not a review. Two artefacts:

| Artefact | Where | Generated? | Why |
|---|---|---|---|
| Scope-shift table (5 rows: object / horizon / unit of accountability) | `docs/app_description/02-domain/framework-authoring/scope-shift/{COMP}.md` | **Hand-written, committed, permanent** | It is judgment, not derivable from the JSON. Authored *before* prose; two identical rows reject the sweep |
| 5-role anchor review table (`COMP` × {ICO,FLL,MLL,BUL,SRX} × levels 5/3/1) | Generated by `scripts/bars-review-table.mjs`, pasted into the PR body | **Generated, not committed** | Reproducible from the JSON; committing it creates a second copy that can drift |

`framework-authoring/` is a **sibling** of `framework/`, deliberately outside it: the
parity gate globs `*.json` under `docs/app_description/02-domain/framework` and the
documented drift fix is `cp -R docs/.../framework/* api/database/framework/`.

**SRX staging.** SRX must ship whole (proposal), but its content must be reviewed
incrementally. Staging file: `openspec/changes/bars-catalogue-completion/staging/SRX.partial.json`
— outside both trees, invisible to every gate and to the seeder. The review-table
generator reads it for the SRX column. The final SRX PR is a **mechanical
materialisation** whose diff is byte-verifiable against the already-reviewed staging
file; that is what makes its `size:exception` provable rather than pleaded.

### 7. Testing strategy (strict TDD)

**What a test can prove**: shape, completeness, parity, seeded counts, gap resolution,
API exposure, and string non-identity. **What no test can prove**: that an anchor is
behaviourally differentiated, calibrated to the ladder, or in voice. No Pest test will
be named as if it checks quality; a hedge-word assertion would pass a bad catalogue and
fail a good one.

CI-blocking mechanical checks, new in `scripts/ci-guards.sh` (each with a self-test row
in `wrapper-ci.yml`, per house pattern):

| Check | Assertion |
|---|---|
| `catalog_malformed_bars_entries` | Every competency key holds **exactly 3** entries; each has a non-empty `indicator` and a `scale` with exactly keys `5`,`3`,`1`, all non-empty, no leading/trailing whitespace. Today's `bars_competency_keys` only checks `length > 0` — a one-indicator stub with empty anchors passes it |
| `catalog_crossrole_duplicates` | For one competency, no indicator or anchor string is identical across roles |
| existing pair/role gates | Unchanged; both control files must reach zero entries |

**Discovered while designing — the cross-role check goes red on legacy content today**:
`MLL.json:142` and `BUL.json:142` carry an identical `INF` indicator, and `FLL.json:176`
and `MLL.json:176` an identical `RES` indicator. Retro-review of the 39 existing pairs
is out of scope, so the check reads a **generated** baseline
`scripts/framework-crossrole-baseline.txt` — same doctrine and both-direction
enforcement as the two existing control files (a baseline entry whose duplicate is gone
fails the build). Generated by running the checker on today's catalogue, committed
verbatim, never hand-typed. New pairs may add **zero** entries to it.

Pest (in `api/`, run as `./vendor/bin/pest tests/Feature/Seeders/{File}.php` or a full
run — **never** `php artisan test --filter`, which has been observed fabricating passes):

| Test | Layer |
|---|---|
| `Seeders/GapResolutionTest.php` (new) | All four resolution points, fixture `barsDir`, RED first |
| `Seeders/LockedRoleMetaFillTest.php` (new) | Locked FV + empty responsibilities → filled + signal; locked FV + non-empty → untouched |
| `Seeders/SeededCountCorrectnessTest.php` | Hardcoded counts bumped **in each content PR** (FLL 24→27→…→54; BUL 24→…→42; SRX 0→54). The bump is the PR's own evidence |
| `Seeders/SeededCompletenessTest.php` (new) | Derived: every `(role, competency)` in the JSON has exactly 3 indicator rows — catches the seeder dropping rows |
| `Seeders/ReseedAfterGapFixTest.php` | Its comment *"the gap may still exist … that's acceptable"* is now false; tighten to assert resolution |
| `Api/BarsAvailableFlagTest.php`, `Api/PartialCatalogApiTest.php` | `bars_available=true` for all 83 pairs; the partial-catalogue fixtures must be restated against fixtures, not against SRX |

### 8. Delivery

**Order of work (RED first at every step).**

| # | Slice | Content |
|---|---|---|
| 0 | Code | Seeder fixes 5a + 5b, RED tests first. No content change |
| 1 | Prereq | SRX `responsibilities` (both trees) + doc line 20; `missing_role_meta` resolves |
| 2 | Standard | House-voice/anti-hedge doc, scope-shift template, `ci-guards.sh` checks + self-tests, generated cross-role baseline |
| 3–4 | **JDG, TMG** | 4 pairs each; FLL/MLL/BUL into the trees, SRX column into staging |
| 5–12 | PRS, DRV, COL, NET, SLF, COM, ITG, INC | 3–4 pairs each, same shape |
| 13–15 | SRX-only: STG INN CSF OPX INS INF RES LRN | Staging only, batched ~3 competencies per PR |
| 16 | SRX materialisation | Staging → both trees; delete `SRX` from `framework-known-gaps.txt`; counts to 54; `size:exception`, justified by byte-equality to reviewed staging |
| 17 | Close-out | `framework-competency-gaps.txt` emptied, domain doc §Copertura BARS, spec delta, final assertions |

Each content PR: JSON in both trees + the matching lines deleted from
`framework-competency-gaps.txt` + the count bump. ≈9–12 indicators ≈ 200–260 changed
lines across both trees — inside the 400-line budget. Only PR 16 exceeds it, structurally.

**Production procedure** (`railway ssh`, api service):

1. **Before deploying**, record the lock state:
   `php artisan tinker --execute="echo App\Models\FrameworkVersion::withoutGlobalScopes()->where('is_locked',true)->count();"`
2. Deploy (catalogue ships in the image at `database/framework`).
3. `php artisan db:seed --class="Database\Seeders\FrameworkCatalogSeeder" --force`
4. Verify: per-role indicator rows 45/54/54/42/54; SRX `responsibilities` non-empty;
   `select kind, count(*) from framework_gaps where status='pending_authoring' group by kind`
   → zero for `role_no_bars`, `competency_no_bars`, `missing_role_meta`; presence of the
   `seeder_lock_guard_active` row agrees with step 1.
5. `GET /api/framework/roles/SRX/competencies` → `bars_available=true` ×18.

**If a FrameworkVersion is locked**: with fixes 5a and 5b, the deploy is complete, not
half-landed — new indicator rows are additive, SRX `responsibilities` lands via the
fill-empty exception, gap rows resolve (operational table, already exempt). What still
does **not** land under lock: edits to existing anchors (this change makes none) and IT
translations added later — the deferred-locale cost the proposal names. Rollback under
lock still requires a targeted delete scoped to the affected `(role_id, competency_id)`
pairs; establish the lock state before seeding, not during rollback.

---

## Open Questions

- [ ] Third control file (`framework-crossrole-baseline.txt`) — consistent with house
      doctrine, but it is a third file. Alternative is a constant inside the checker,
      which is invisible to review. Recommend the file; confirm.
- [ ] `framework-authoring/` as a new sibling directory under `02-domain/` — confirm no
      docs-index convention requires registering it.
- [ ] Proposal questions 1 (IT translations) and 2 (retro-review of the 39 pairs) remain
      product decisions; both assumed deferred, and §7 records two concrete legacy
      duplicates that question 2 would inherit.
