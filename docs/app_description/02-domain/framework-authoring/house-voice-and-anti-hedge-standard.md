# BARS Authoring Standard — House Voice and the Anti-Hedge Rule

**Status**: binding, written once. Applies to every new indicator and anchor
authored under `bars-catalogue-completion` (the 132 new indicators / 396
anchor texts across FLL, MLL, BUL and SRX) and to every catalogue addition
after it.

**Scope**: this document governs *content authored under this change* only.
The existing 39 pairs (ICO's 15, plus the 24 already-worked leader pairs)
are **not** retroactively rewritten — see the anti-hedge section below for
the measured extent of their drift, recorded, not fixed, by design.

**A sibling directory, deliberately.** This file lives in
`docs/app_description/02-domain/framework-authoring/`, next to — never
inside — `docs/app_description/02-domain/framework/`. The Cross-Stack
Consistency job (`.github/workflows/wrapper-ci.yml`, step (d)) globs `*.json`
under `framework/` and the documented drift fix is
`cp -R docs/.../framework/* api/database/framework/`; a markdown file living
inside `framework/` would be swept into that copy for no reason and confuse
that command's purpose. Authoring standards are read by a human before
writing, not read by the seeder or vendored anywhere.

---

## 1. House voice — extracted, not invented

The source of truth for every rule below is the catalogue itself: the
complete `bars/ICO.json` plus all 24 already-authored leader pairs across
`bars/FLL.json`, `bars/MLL.json`, `bars/BUL.json`. Read them before writing
anything. Everything here is a transcription of a pattern already present,
not a new invention — with one deliberate exception, stated below: the new
pairs follow the **leader** shape, not ICO's, because every new pair is a
leader role (FLL/MLL/BUL/SRX).

### 1.1 Indicator

The form all 44 new pairs follow (the leader-file form, not ICO's):

- **Bare infinitive**, no subject (e.g. `Identify the motives and objectives
  of the interlocutors and use them to argue own positions`, not `Identifies
  the motives...`).
- **No terminal period.**
- **6–16 words.**
- **One observable act** — a single behaviour, not a compound of two
  unrelated ones.
- **Never names the competency** (an indicator under `PRS` never contains the
  word "problem solving").
- Uses **`own`** as the possessive determiner where a possessive is needed
  (`own team`, `own area`, `own positions`) — never `their`, `the
  candidate's`, or a bare noun where `own` reads naturally.

ICO deviates from this shape — third-person `-s` verb forms and terminal
periods (`Recognizes symptoms that indicate problems.`) — and **is the wrong
model for new content**, because every new pair authored under this change is
a leader role. Read ICO for calibration of level-differentiation (§2 below),
not for indicator grammar.

### 1.2 Anchor

Subject-elided third-person present, describing what a person at that level
DOES (level 5, level 3) or fails to do (level 1) — never an instruction, never
addressed to the reader.

The leader files (FLL/MLL/BUL) run **one sentence, 10–18 words**. ICO runs
two sentences, 20–30 words, and is again the wrong model — new anchors follow
the leader shape.

| Level | Shape |
|---|---|
| 5 | A strong verb or quality/frequency adverb opens the sentence (`Consistently`, `Proactively`, `Builds`, `Champions`), often closing with an impact clause (`with measurable returns`, `earning lasting trust`). |
| 3 | Opens with a verb naming **what is done**. This is the level where the house's measured defect concentrates — see §2. |
| 1 | A deficit verb opens the sentence (`Fails to`, `Struggles to`, `Rarely`, `Avoids`, `Neglects`, `Resists`, `Does not`), usually closing with a consequence clause (`leading to confusion or misalignment`, `undermining team trust`). |

**An anchor names a behaviour, not a frequency of the indicator.** The
indicator is the act; the anchor is *how* that act is performed and *on what
object*. `"Occasionally asks for feedback"` is a legitimate level-3 anchor
**only** when the indicator's own act is itself a frequency-shaped behaviour
(e.g. an indicator about soliciting feedback) — it is not a template to reach
for generically, and §2 explains exactly why not.

### 1.3 Register and orthography

- **No second person.** Never `you`, never addresses the reader.
- **No `the candidate` / `the employee` as subject.** Anchors describe a
  behaviour in the abstract third person, not a specific evaluated person.
- **No modal obligation** (`should`, `must`, `ought to`) — anchors describe
  what someone *does*, not what they are instructed to do.
- **No numeric targets** (`increases sales by 20%`) — BARS anchors describe
  observable behaviour, not measured outcomes.
- **Business vocabulary no heavier than `SWOT`.** If a term needs a footnote
  to be understood by a generalist manager, it is too heavy.
- **`-ize` spellings** (`prioritize`, not `prioritise`).
- **ASCII apostrophe only** (`'`, U+0027). The legacy catalogue mixes in the
  curly apostrophe (U+2019, `'`) in places — **do not propagate that**; every
  new apostrophe is the plain ASCII one.
- **Do not copy legacy typos** found anywhere in the existing catalogue
  (`memebers`, `clariry`, `Demostrate`, and others like them) even as a
  pattern-matching shortcut. Every new sentence is proofread on its own
  terms.

---

## 2. The anti-hedge rule, and the honest limit of checking it mechanically

### 2.1 The rule

Strip every degree/hedge marker (`occasional`, `may`, `generally`, `most`,
`some`, `rarely`, `consistently`, and their synonyms) from the three anchor
texts of one indicator. **If what remains at level 5 and level 3 is the same
verb acting on the same object, the indicator is rejected** and must be
rewritten.

The three levels MUST differ by **at least one** of:

- the **object** acted on,
- the **action** taken, or
- the **scope/audience** reached.

A degree adverb MAY reinforce an already-different behaviour. **It may never
be the only difference between two levels.**

**Done right** — `ICO/PRS` indicator 1: level 5 *"uses symptoms as clues to
underlying causes"*; level 3 *"differentiates the problem from the
symptom"*; level 1 *"focuses on surface symptoms"*. Three genuinely different
behaviours — different verbs, different objects.

**Done wrong** — `ICO/STG` indicator 1: *"Consistently anticipates…"* /
*"…in most situations but may need occasional guidance"* / *"Rarely
considers…"*. One sentence, three adverbs bolted on. The same failure shape
recurs at `ICO/INN` indicator 1 and `ICO/ITG` indicator 3. **These three are
the counter-example this standard exists to reject in new content** — they
are not deleted (retro-review of the 39 existing pairs is out of scope for
this change, see the change proposal's Question 2), but no new indicator may
be authored in their shape.

### 2.2 Is a mechanical check feasible? Partly — and it must not be sold as the control

Measured against the two worked legacy examples above, a hedge-stripped
content-token Dice similarity between the level-5 and level-3 anchors:

| Legacy example | Dice(L5, L3) after hedge-strip | Caught at a ≥0.6 threshold? |
|---|---|---|
| `ICO/INN` #1 (bad — same sentence reworded) | ≈0.60 | Yes |
| `ICO/STG` #1 (bad — degree-only, but reworded) | ≈0.16 | **No** |

A similarity threshold catches the lazy "same sentence plus an adverb"
shape and misses the more careful "degree-only, but reworded" shape
entirely — the two bad examples above score at opposite ends of a scale a
single cutoff cannot separate.

A hedge **word list** as a hard gate is worse: it false-positives on
legitimate uses. `FLL/CSF` level 3 — *"Occasionally asks for feedback"* — is
a **correct** level-3 anchor for an indicator whose act is itself a
frequency-shaped behaviour (soliciting feedback). A blanket ban on the word
"occasionally" would reject good content to catch bad content it cannot
reliably distinguish.

### 2.3 What this means for the gate, and what it means for review

**No hedge word list is a CI-blocking gate, and no similarity threshold is
either.** CI-blocking mechanical checks are limited to what a machine can
prove without a human's judgment: shape, completeness, and cross-role string
identity (see `scripts/ci-guards.sh`: `catalog_malformed_bars_entries`,
`catalog_crossrole_duplicates`).

The similarity number and the hedge-marker rate instead ship as a
**non-blocking report**, generated per content PR (see
`scripts/bars-review-table.mjs`), with a documented ceiling:

> **≤30% of new level-3 anchors may carry a hedge marker.**
> Legacy baseline: 76% (89 of 117 level-3 anchors catalogue-wide);
> ICO alone: 89% (40 of 45).

Exceeding the ceiling does **not** fail the build. It fails **review** — the
PR reviewer treats it as a signal to re-read the flagged anchors against this
document's §2.1 rule, not as an automatic rejection.

**The binding gate is the written rubric in §2.1, applied by a human against
the pair's scope-shift table** (see
`docs/app_description/02-domain/framework-authoring/scope-shift/README.md`).
No test is named as if it checks behavioural quality — a hedge-word assertion
would pass a bad catalogue and fail a good one, which is precisely backwards
for a gate whose entire purpose is separating the two.

---

## 3. Cross-role differentiation

House voice is one axis; **role-specific calibration** is the other, and the
two are not the same failure mode.

**The rule**: anchors for the same competency MUST differ across roles by
the **object** of the behaviour, its **horizon**, or its **unit of
accountability** — all three drawn from that role's own `roles.json`
`responsibilities` text. New anchors MUST NOT be one role's text with the
role name swapped.

**Worked example already in the catalogue** (proving the axis is real and
already applied, not a new idea): `STG` for ICO reads *"Understand the
short- and medium-term consequences of own actions"*; `STG` for FLL reads
*"Have a plan to achieve own team's goals"*. Same competency, genuinely
different scope, horizon and object.

**Mechanical enforcement, two layers**:

1. **Before any prose is written** — the per-competency scope-shift table
   (§4 below). If two roles' rows are identical, the sweep is rejected
   before an anchor is drafted.
2. **After JSON is authored** — `catalog_crossrole_duplicates`
   (`scripts/ci-guards.sh`), which fails the build on any indicator or
   anchor string that is byte-identical across two roles for the same
   competency. It is a floor, not a ceiling: it catches literal copies, not
   a near-miss reword. The scope-shift table is what catches those.

---

## 4. Using this document

1. Read `bars/ICO.json` and every leader file (`FLL`, `MLL`, `BUL`) in full
   before authoring anything.
2. Author the scope-shift table for the competency first (template:
   `docs/app_description/02-domain/framework-authoring/scope-shift/README.md`).
   If any two role rows read the same, stop and fix the table before writing
   a single anchor.
3. Draft indicators and anchors following §1 (voice) and §2.1 (level
   differentiation), checked against the scope-shift table row for each
   role.
4. Run the mechanical checks locally:
   `catalog_malformed_bars_entries`, `catalog_crossrole_duplicates` (both in
   `scripts/ci-guards.sh`), and generate the review table
   (`scripts/bars-review-table.mjs`) to paste into the PR body.
5. The hedge-rate line in that generated report is advisory. If it is over
   30%, re-read the flagged anchors against §2.1 before requesting review —
   do not treat a clean report as proof of quality, and do not treat a
   flagged one as an automatic rewrite order.
