# Proposal: BARS Catalogue Completion — 44 Missing Role×Competency Pairs

## Intent

`roles.json` declares 83 role×competency pairs. 39 have behavioural anchors. **44 do
not**, and every one of them is a competency the product promises to assess and then
cannot score:

| Role | Declared | Anchored | Missing |
|---|---|---|---|
| ICO | 15 | 15 | 0 |
| FLL | 18 | 8 | 10 — PRS JDG DRV SLF TMG COM COL NET ITG INC |
| MLL | 18 | 8 | 10 — same set |
| BUL | 14 | 8 | 6 — PRS JDG DRV TMG COL NET |
| SRX | 18 | 0 | 18 — no `bars/SRX.json` at all |

Consequences today: an SRX participant cannot be scored at all
(`RoleNoBarsException` / `role_no_bars`), and an FLL or MLL participant is scored on
8 of 18 declared competencies while the report implies 18. The catalogue is
knowingly incomplete, and the two CI control files exist to keep that honest rather
than to fix it.

The product owner has decided this gap closes now: **every declared pair gets
anchors, so an assessment is 100% scorable, and both gap files are emptied so
nothing stays declared-but-unanchored.**

**The one caveat that travels with this change, stated once:** the content authored
here is a *calibrated draft* — extrapolated from the complete ICO file, the 24
worked leader pairs, `competencies.json` definitions and the `roles.json` seniority
ladder. It **MUST be reviewed and signed off by an assessment specialist before it
scores a real candidate.** That sign-off is a success criterion of this change, not
a disclaimer attached to it.

**Volume**: 44 pairs × 3 indicators × 3 anchors = **132 indicators, 396 anchor
texts**, plus SRX's `responsibilities`. On completion the catalogue is 83 pairs /
249 indicators / 747 anchors.

> Measured correction to the brief: the existing authored set is **39** pairs
> (ICO 15 + FLL 8 + MLL 8 + BUL 8), not 33 — confirmed by counting 117 `"indicator"`
> keys across the four BARS files. 117 + 132 = 249.

## Scope

### In Scope

| # | Deliverable | Note |
|---|---|---|
| 1 | **SRX `responsibilities`** in `roles.json` | **Prerequisite, blocking** — see below |
| 2 | 44 pairs of anchors: 132 indicators, 396 anchor texts, EN | The change itself |
| 3 | `bars/SRX.json` created — 18 competencies, 54 indicators | Must land complete in one commit |
| 4 | `scripts/framework-known-gaps.txt` and `scripts/framework-competency-gaps.txt` emptied of entries | Same commits that fill the pairs |
| 5 | Vendored tree `api/database/framework/` updated byte-identically | Cross-Stack Consistency gate |
| 6 | `framework_gaps` row reconciliation — resolved gaps must stop reporting as pending | See Approach; the seeder has no resolution path today |
| 7 | `docs/app_description/02-domain/01-ruoli-e-competenze.md` §Copertura BARS + SRX row updated | Both become factually false on completion |
| 8 | Production re-seed via `railway ssh` | With the lock-guard check below |

### Out of Scope

- **IT translations of the new anchors** — the catalogue is EN-only with a standing
  `missing_translation` gap. Open question 1 below; assumed deferred.
- **Retro-review of the 39 existing pairs** for the level-differentiation defect
  measured below. Open question 2; assumed deferred.
- **MTG / LAT** potential competencies — a separate authoring gap, untouched.
- **Changing the number of indicators per pair.** Every existing pair carries
  exactly 3. The new pairs carry exactly 3. No pair is re-shaped.
- **Scoring engine behaviour.** `role_no_bars` skip-and-flag stays as defensive
  behaviour; only its SRX-named example scenario becomes counterfactual.
- **Framework API, seeder file-shape, migrations.** Content change, not a code change
  — except deliverable 6.

## The SRX prerequisite

`roles.json` gives SRX `"responsibilities": ""`. The domain doc says
*"responsabilità da definire in configurazione"*. The seeder already flags it
(`missing_role_meta`).

SRX's 18 pairs cannot be calibrated against responsibilities that do not exist —
every other role's anchors are pinned to a horizon, a span of control and a unit of
accountability read from that field. Authoring 54 SRX indicators against a blank
field is guesswork wearing the same shape as work.

So SRX's `responsibilities` is **deliverable #1, not a footnote**: extrapolated from
the ladder (ICO daily/weekly, own area → FLL weekly/monthly, department → MLL ~1
year, small country → BUL 1–2 years, country/region, full P&L) and from the doc's
own characterisation of SRX as the *"set ampio executive"*. It is authored, reviewed
and settled **before** any SRX anchor is written.

## Approach

### Authoring unit: per-competency, not per-role

**Position: author one competency vertically across all its roles at once**
(e.g. PRS × {FLL, MLL, BUL, SRX} in a single sitting), not one role's file at a time.

1. **The failure mode is vertical, so the work must be.** The risk the product owner
   named — "FLL's PRS is MLL's PRS with different words" — is a comparison between
   roles *for the same competency*. It is only visible when those texts sit side by
   side. Per-role authoring puts FLL:PRS and MLL:PRS in different sessions hours
   apart, where the only defence against a near-duplicate is remembering what you
   wrote.
2. **The ladder is one axis.** Scope calibration across ICO→SRX is a single ordered
   act of judgment, not five independent ones. `roles.json` proves the axis exists;
   ICO/STG *"Understand the short- and medium-term consequences of own actions"*
   versus FLL/STG *"Have a plan to achieve own team's goals"* proves it is already
   applied.
3. **The voice argument for per-role does not hold.** House voice is a property of
   the whole catalogue — ICO plus the 24 leader pairs — not of a role. It is
   protected by a written style rule and by reading ICO, which a per-competency sweep
   does anyway. Per-role authoring buys nothing here and pays for it in calibration.
4. **The gate's unit is already the pair.** `framework-competency-gaps.txt` is
   `ROLE:COMP`, so a per-competency slice maps exactly onto N deleted lines, and a
   partial `FLL.json` is an explicitly legal, gated intermediate state.

**One structural exception — SRX ships whole.** The role-level gate asks only "does
`bars/SRX.json` exist", and the pair-level gate asks its question *only* of roles
whose file exists. The moment a partial `SRX.json` lands, all 18 SRX pairs become
uncovered-and-unlisted → CI red, and listing them in
`framework-competency-gaps.txt` is exactly what that file's own header forbids. So
SRX is *authored* per-competency alongside the others but **committed as one
complete file**, in the same commit that deletes `SRX` from
`framework-known-gaps.txt`.

**Hardest subset, authored first.** JDG and TMG appear in **zero** BARS files across
the entire catalogue — grep confirms only INS among the three ICO-less competencies
has any precedent (FLL/MLL/BUL). That is 8 pairs / 24 indicators
({FLL,MLL,BUL,SRX} × {JDG,TMG}) with **no worked example anywhere**, authored from
the `competencies.json` definition alone. They go first, while calibration attention
is highest, and they are flagged for priority specialist review.

### How consistency is checked, not hoped for

1. **Scope-shift table before prose.** For each competency, a table is written first:
   one row per role stating (a) the *object* of the behaviour — what is being solved,
   decided, managed; (b) the horizon; (c) the unit of accountability. Rows are
   derived from `roles.json` responsibilities. **If two roles' rows are identical,
   the pair is a reworded copy and the sweep is rejected before a single anchor is
   written.** The tables are reviewable artefacts, not scratch work.
2. **Mechanical cross-role check.** A script over `bars/*.json`: for each competency,
   no anchor or indicator string may be identical across roles, and pairs above a
   normalised-similarity threshold are printed for human adjudication. Cheap,
   repeatable, and it converts "did we copy?" from a memory question into a command.
3. **Level-differentiation rule** — see below.

### Level differentiation: the measured house defect

The three anchors must be distinguishable by a **different observable action or
object**, not by a degree adverb bolted onto the same sentence. The existing
catalogue is **mixed**, and the failure mode dominates:

*Done right* — ICO/PRS #1: level 5 *uses symptoms as clues to underlying causes*;
level 3 *differentiates the problem from the symptom*; level 1 *focuses on surface
symptoms*. Three different behaviours.

*Done wrong* — ICO/STG #1: *"Consistently anticipates…"* / *"…in most situations but
may need occasional guidance"* / *"Rarely considers…"*. One sentence, three adverbs.
Same shape in ICO/INN #1 and ICO/ITG #3.

*Measured*: **89 of 117 level-3 anchors (76%)** contain a hedge/degree marker
(`occasional|may|generally|most|some`); ICO alone is **40 of 45 (89%)**.

**Position**: the 132 new indicators adopt the ICO/PRS pattern as the binding
standard. A degree adverb may reinforce an already-different behaviour; it may never
be the only difference between two levels. This is enforced in review against the
scope-shift table, not by grep — the marker count above diagnoses the habit, it does
not adjudicate an individual anchor.

### Seeding and the lock guard

`FrameworkCatalogSeeder` reads the **vendored** tree (`database_path('framework')`);
the wrapper doc tree is the authored source and the Cross-Stack Consistency job fails
if they diverge. Production's catalogue was seeded manually via `railway ssh`, so
re-seeding is part of delivery.

**Check `framework_versions` for `is_locked = true` on production before seeding.**
If any locked FV exists the seeder is purely additive, and the split is not
intuitive:

- the 132 **new** `framework_bars_indicators` rows and the new `SRX` pairs **DO**
  land — they are new rows by natural key;
- **SRX's `responsibilities` does NOT** — the `Role` row already exists, so
  `setTranslation` is suppressed by the `$model->exists` gate. The role ships with
  empty responsibilities and a live `missing_role_meta` gap while the doc says it was
  authored.

That is a half-landed deploy that looks green. It must be resolved explicitly
(targeted update, or a documented decision) rather than discovered later.

### Gap-row reconciliation (deliverable 6)

The seeder `updateOrCreate`s `competency_no_bars` / `role_no_bars` /
`missing_role_meta` rows but **never resolves them** — nothing sets `status` away
from `pending_authoring` or removes a row whose gap is closed. After this change
production would carry 44+ stale `pending_authoring` rows describing pairs that are
now fully anchored: *an exemption outliving its gap*, in the database, which is
precisely the failure the two CI files were written against. Closing the gap in the
files while leaving it open in the DB is not closing it. The spec phase decides the
mechanism (seeder-side resolution vs. one-off cleanup); this proposal fixes that it
must happen.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `framework-catalog`: the "Data-Gap Authoring Requirements (Tracked, Not
  Fabricated)" requirement loses its FLL/MLL/BUL/SRX BARS entries and the SRX
  `missing_role_meta` entry; the per-role seeded-count scenarios (ICO 45 / FLL 24 /
  MLL 24 / BUL 24 / SRX 0) become 45/54/54/42/54; the `bars_available=false` example
  (FLL/PRS) and the "Missing `bars/SRX.json` is skipped gracefully" scenario need
  fixture-based restatement; the explicit non-goal *"Inventing missing domain data —
  SRX BARS … C3 records the gap only"* is **directly reversed** by this change and
  must be rewritten, not quietly left standing. Gap-row resolution is a new
  requirement.
- `scoring-engine`: **no behaviour change.** `role_no_bars` skip-and-flag stays — it
  is defensive and must survive. Only the SRX-named scenario is restated
  role-agnostically against a fixture.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `docs/app_description/02-domain/framework/roles.json` | Modified | SRX `responsibilities` authored |
| `docs/…/framework/bars/{FLL,MLL,BUL}.json` | Modified | +10, +10, +6 competency keys |
| `docs/…/framework/bars/SRX.json` | New | 18 competencies, 54 indicators |
| `api/database/framework/**` | Modified | Vendored copy, byte-identical |
| `scripts/framework-known-gaps.txt` | Modified | `SRX` entry removed |
| `scripts/framework-competency-gaps.txt` | Modified | All 26 pair entries removed |
| `docs/…/02-domain/01-ruoli-e-competenze.md` | Modified | §Copertura BARS; SRX row line 20 |
| `openspec/specs/framework-catalog/spec.md` | Modified | Delta per Capabilities |
| `api/database/seeders/FrameworkCatalogSeeder.php` | Modified? | Only if gap resolution is seeder-side |
| Production DB (`railway ssh`) | Modified | Re-seed + gap reconciliation |

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Anchors are reworded copies across roles rather than genuinely role-specific | **High** | Scope-shift table authored before prose and rejected if two rows match; mechanical cross-role identity/similarity check; per-competency vertical sweep |
| Levels 1/3/5 differ only by degree adverbs — the measured 76% house habit | **High** | Binding ICO/PRS behavioural-differentiation standard; reviewed against the scope-shift table |
| JDG and TMG authored with no precedent anywhere in the catalogue | **High** | Authored first, flagged for priority specialist review, calibrated straight from `competencies.json` definitions |
| Draft content scores real candidates before specialist sign-off | **High** | Sign-off is a success criterion and a release gate, not a follow-up |
| Partial `SRX.json` turns CI red with no legal exemption path | Med | SRX ships as one complete file in one commit with the `framework-known-gaps.txt` deletion |
| Locked FV silently swallows SRX `responsibilities` on production re-seed | Med | Explicit pre-seed `is_locked` check; post-seed verification of SRX role text and of per-role indicator counts |
| Stale `framework_gaps` rows survive the fix | Med | Deliverable 6; post-seed assertion that zero `competency_no_bars` / `role_no_bars` rows remain pending |
| Two trees drift (authored vs vendored) | Low | Cross-Stack Consistency job; vendoring in the same commit |
| 396 anchor texts exceed any sane review budget in one PR | **High** | Per-competency PR chain; `400-line budget risk: High`, `Chained PRs recommended: Yes`, `Decision needed before apply: Yes` |

## Rollback Plan

Content-only, so revert is clean at the file layer: revert both framework trees, both
control files and the domain doc together — they must move as one commit per gap, so
they revert as one. The CI gates then agree with the reverted content in both
directions.

**The database does not revert as cleanly.** If no FV is locked, re-seeding after the
revert delete-stales the added indicator rows and the state is restored. **If any FV
is locked, the inserted rows cannot be removed by re-seeding** (additive-only) and
require a targeted manual delete scoped to the affected `(role_id, competency_id)`
pairs. Establish which case production is in *before* seeding, not during rollback.

## Dependencies

- **SRX `responsibilities` (deliverable 1) gates all 18 SRX pairs.** Nothing SRX
  starts until it is settled.
- An **assessment specialist** available to review before any real scoring. This is a
  people dependency, and it is the one that decides whether the change is finished.
- Production `railway ssh` access and the `framework_versions.is_locked` answer.

## Success Criteria

- [ ] `roles.json` SRX `responsibilities` is non-empty and calibrated against the ICO→BUL ladder.
- [ ] All 83 declared role×competency pairs have 3 anchored indicators; 249 indicators, 747 anchor texts.
- [ ] `scripts/framework-known-gaps.txt` and `scripts/framework-competency-gaps.txt` contain zero entries, and CI is green in **both** directions.
- [ ] Both framework trees are identical; Cross-Stack Consistency green.
- [ ] Cross-role check reports zero identical anchor or indicator strings for the same competency across roles; every flagged near-duplicate has a recorded adjudication.
- [ ] Every new indicator's levels 1/3/5 differ by observable action or object, verified against its competency's scope-shift table — not by degree adverb alone.
- [ ] Seeded counts: ICO 45, FLL 54, MLL 54, BUL 42, SRX 54 indicator rows.
- [ ] `framework_gaps` holds zero pending `competency_no_bars`, `role_no_bars` or SRX `missing_role_meta` rows.
- [ ] `GET /api/framework/roles/{role}/competencies` reports `bars_available=true` for every declared pair, all five roles.
- [ ] A participant of every role — SRX included — is scorable end-to-end with no `role_no_bars` flag.
- [ ] **An assessment specialist has reviewed and signed off the 132 new indicators before they score a real candidate**, with JDG and TMG (24 indicators, no precedent) explicitly acknowledged in that review.
- [ ] The domain doc no longer claims partial BARS coverage or undefined SRX responsibilities.

## Proposal Question Round

Not asked interactively (delegated execution). Each is a product decision the spec
phase must **not** answer on its own:

1. **IT translations of the new anchors — in scope?** The catalogue is EN-only with a
   standing `missing_translation` gap, and `translation_gap=true` already flags it.
   Assumed **deferred**: this change closes the *coverage* gap, not the *locale* gap.
   Note the coupling — if any FV is locked, adding a locale to these rows later is a
   mutation of existing rows and is suppressed until no FV is locked, so deferring has
   a real cost. Confirm, or fold IT in and double the authoring volume.
2. **Retro-review the 39 existing pairs for the degree-adverb defect while we are in
   here?** 76% of level-3 anchors carry a hedge marker. Assumed **deferred** to keep
   this change auditable as pure addition — mixing edits of existing anchors into a
   132-indicator addition makes the diff unreviewable, and under a locked FV the edits
   would be silently ignored by the seeder anyway. Confirm, or open it as its own
   change.
