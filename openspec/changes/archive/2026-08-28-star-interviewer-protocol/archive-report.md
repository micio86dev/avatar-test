# Archive Report — star-interviewer-protocol

**Archived**: 2026-08-28 · **Mode**: hybrid (openspec files + Engram) · **Project**: `avatar-test`
**Verdict carried in**: PASS WITH WARNINGS — 0 CRITICAL, therefore not blocked.
**Status**: specs merged; folder move deliberately left to the operator (see *Folder move*).

---

## Gates

| Gate | Result |
|---|---|
| Task Completion Gate | **PASS** — 36/36 `[x]` in `tasks.md`, no reconciliation needed, no stale unchecked task. |
| CRITICAL issues in verify-report | **None.** Archive is not blocked. |
| Required artifacts present | proposal ✅ · design ✅ · specs/interview-conversation ✅ · tasks ✅ · verify-report ✅ |
| Live smoke (AD-5 / D-7, the change's own definition of done) | **PASS** — 2026-08-25, real HeyGen interview, 5 competencies, against production `api v0.32.0`. |

The change defined itself as incomplete until a live interview passed (proposal AD-5, design
D-7). That gate is satisfied and recorded in `tasks.md`; the archive is not being granted on
unit tests alone.

## Artifact traceability

| Artifact | Engram | File |
|---|---|---|
| proposal | **#1652** | `proposal.md` |
| design | — (never mirrored) | `design.md` |
| spec delta | — (never mirrored) | `specs/interview-conversation/spec.md` |
| tasks | — (never mirrored) | `tasks.md` |
| apply-progress | **#1654** | — |
| verify-report | **#1700** | `verify-report.md` (transcribed at archive time) |
| archive-report | this observation | this file |

Related: **#1656** (production deploy of `api` v0.32.0 carrying this change), **#1658** (live
smoke findings), **#1647** (the reference-log divergence register this change closes),
**#1699** (`evaluator-evidence-and-rigor` archive — the matched-pair sibling).

> **Store-integrity note.** Only proposal, apply-progress and verify-report were ever written
> to Engram for this change; `design`, `spec` and `tasks` exist as FILES ONLY. The files are
> authoritative under hybrid mode, so nothing is lost — but a reader searching Engram alone
> for `sdd/star-interviewer-protocol/design` will find nothing and must read the archived
> folder. Recorded rather than silently backfilled: inventing mirror observations at archive
> time would fabricate a provenance that never existed.
>
> Note also that the Engram project key is **`avatar-test`**, not `beai`. A search scoped to
> `beai` returns `unknown_project` and finds none of this history.

---

## Spec merge — what actually happened

The delta declared **two MODIFIED requirements**. **Neither had a same-named heading** in
`openspec/specs/interview-conversation/spec.md`, and in both cases the behaviour being
superseded was embedded in a *different* requirement. A blind append would have left the
source of truth asserting exactly what this change revoked. This is the second consecutive
archive in which that occurred.

### Delta requirement 1 — "System Prompt Composition" (declared MODIFIED)

No such heading. The nearest was **System-Prompt Composition — Pure Function**, which owns
inputs/determinism, not prompt CONTENT. The delta's substance (STAR, same-episode, minimum)
is prompt content and would have been buried inside a purity requirement had it been merged
there.

**Resolution — split across three requirements:**

1. **System-Prompt Composition — Pure Function** — *amended in place*. Input table:
   `follow_up_budget` default `2 [PROVISIONAL — OQ-1]` → **4, RATIFIED 2026-08-25**; new
   `min_questions` input row. Purity restated explicitly (no LLM/HTTP/time/randomness/IO;
   reading config is NOT a violation — F-3). Language bullet narrowed to *catalogue-derived*
   text with a pointer to the i18n requirement. `(Previously: …)` note added.
2. **STAR Coverage Protocol and Same-Episode Constraint** — **NEW requirement**, placed after
   SA-02 and before the nudge rule, mirroring the composed prompt's own section order. Carries
   the orthogonality argument (BARS = *which behaviours*; STAR = *is this episode complete
   enough to assess anything*), the Action/Result emphasis, the inapplicable-element escape,
   the same-episode constraint with its single no-assessable-behaviour exception, the
   stated-ONCE rule with its rationale, and the mandated section order. 6 scenarios (the
   delta's 4 relevant ones, plus *stated exactly once* and *STAR precedes the follow-up
   rules*, both of which the delta enforced in tasks 3.4 and 2.5 but never wrote as scenarios).
3. **Advance Rule and Minimum Question Count** — **NEW requirement** (delta requirement 2, see
   below).

The delta's *composer remains pure* scenario was NOT duplicated into the new requirement — the
existing *Deterministic composition* scenario already owns it.

### Delta requirement 2 — "Advance Rule and Minimum Question Count" (declared MODIFIED)

No such heading, and **no advance-rule requirement existed at all**. The advance condition
lived as **item 2 of `Adaptive Standard Follow-Up Questioning (SA-02)`**:

> "The avatar MUST be instructed to speak `end_phrase` only when all BARS indicators are
> addressed OR the follow-up budget is exhausted — not on the first candidate answer."

That two-term condition is precisely what this change superseded. Appending a new requirement
without touching it would have left the spec normatively asserting the pre-change rule in one
place and the post-change rule in another.

**Resolution — the new requirement was added AND SA-02 was reconciled:**

- SA-02 item 1: N default `2 (provisional OQ-1)` → **4 (RATIFIED)**.
- SA-02 item 2: rewritten to the three-term condition `(coverage OR budget exhausted) AND
  effective minimum reached`, with the arithmetic explicitly delegated to the new requirement.
- SA-02 item 5 **added**: the budget is an instruction, not a control loop; ~1 question of
  overshoot is expected. Grounded in the live smoke, where CSF ran six questions against a
  budget of 4.
- `(Previously: …)` note recording the superseded two-term condition.
- **Three scenarios repaired** (see the table below).
- New requirement **Advance Rule and Minimum Question Count** carries the clamp
  `max(1, min(configured, budget + 1))`, the no-throw rule, the `MAX_DURATION_REACHED`
  incident as the reason the clamp is a safety property rather than defensive coding, the
  both-branches conjunct rule, the verbatim-phrase preservation, and the requirement that
  reachability be proven by grid rather than by inspection. 7 scenarios (the delta's 6, plus
  *a zero or negative configured minimum floors at 1*, which the delta enforced in task 1.4
  but never wrote as a scenario).

### Scenarios that had to be repaired, not merely added

| Scenario (in SA-02) | Problem | Action |
|---|---|---|
| *follow_up_budget injected into composed prompt* | Asserted the avatar advances "only after coverage or budget exhaustion" — the repealed two-term rule, stated as an expected outcome. | Rewritten with the minimum conjunct; illustrative N raised 2 → 4 to match the ratified default. |
| *Coverage achieved before budget — end_phrase fires early* | **Directly contradicted the change.** Asserted coverage alone fires `end_phrase` early. Under the new rule coverage is necessary but NOT sufficient. | Amended to require the effective minimum to also have been reached. A new sibling scenario, *Coverage alone does not permit closing below the minimum*, makes the negative case explicit. |
| *Budget exhaustion triggers end_phrase* | Still TRUE, but only *because of* the clamp — silently load-bearing. | Preserved, with an added clause stating that it holds because the minimum is clamped to `budget + 1 = 3`. This is the reachability property made observable at the integration tier. |

### The i18n requirement — restructured, and this one is a judgement call

**Requirement: i18n — Composed Prompt in Project Language** opened with:

> "The composed system prompt (instructions, indicator descriptions, anchor texts, nudge
> instruction, follow-up guidance) MUST be entirely in the project language … Mixed-language
> prompts are PROHIBITED."

**This was false, and has been false since C8 shipped.** Finding F-2 of this change's own
design verified in code that only `buildCoverageSection()` emits localised content; the
role/style header, budget, nudge and advance sections are hardcoded English. This change then
added a *sixth* hardcoded-English section (STAR) and deliberately settled the question
(OQ-3 / D-5) — while fixing the identical false claim in the composer's class docblock.

Merging the delta while leaving that sentence would have left the spec asserting the opposite
of shipped, tested behaviour, on the very point the change had just corrected in code.

**What changed**: the SCOPE claim only. Catalogue-derived content (indicator text, anchors
`{5,3,1}`) must be in the project language and mixing catalogue languages is still PROHIBITED;
the fixed interviewer directives are documented as English by decision, with an explicit
instruction that any future localisation must take them as a SET. **The normative hard-fail is
untouched** — `anchor_translation_missing`, HTTP 422, no session row, no provider call, all
four translatable fields, per-project evaluation — and **all six scenarios are preserved
verbatim**. A `(Previously: …)` note quotes the removed sentence.

The delta asserted i18n was "UNCHANGED", so this correction is beyond its literal text. It is
reported here as a deliberate reconciliation, and it is the single edit in this merge most
worth a second opinion.

### Coverage Note

Extended with: the clamp grid (`budget ∈ {0,1,2,4,8}` × `minimum ∈ {1,2,4,6,10}`) including
the **negative-space** requirement; the STAR assertions including the exactly-once count; and
an explicit warning that an advance-rule assertion satisfied by the follow-up-budget sentence
alone does not cover the advance section — the precise shape of the weak assertion verification
found at `(x) task 4.4`. Also added the `.env.example` ↔ config parity guard and the
`min_questions ≤ followup_budget + 1` sanity invariant, with the rule that a parity guard must
be observed failing at least once.

### Purpose section

Extended to name STAR, the same-episode constraint and the clamped minimum, and to state the
INSTRUCTION-not-control-loop framing that the proposal called the thing which "shapes
everything" — it is why every requirement here is a property of a string.

### Requirements PRESERVED untouched

`BarsIndicatorLoader` · `OpeningTextComposer re-offer variant` · `Nudge Enforcement (SA-03)` ·
`Provider Payload Contract` · `QuestionContext Carries Composed Prompt` · `QuestionContext
Carries a Composed Opening Greeting` · `Testability Split`. Nothing was dropped, and no
requirement was deleted in this merge.

---

## Where the carried notes now live

| Note | Home | Why there |
|---|---|---|
| `InterviewController.php:503` stale `config('conversation.followup_budget', 2)` fallback literal | `specs/interview-conversation/spec.md` → SA-02, blockquote note | SA-02 owns the budget default. Recorded as a known stale literal owned by `project-followup-budget`, explicitly NOT a defect of this change, with the exact edit that change will make. Reachable only if the config file vanishes. |
| Evaluator "before a 4 or 5" prose overstatement | `specs/interview-conversation/spec.md` → STAR requirement | Corrected at the point of use rather than merely flagged. The merged text states that all three elements are required **before a 5**, and that a 4 requires evidence CLEARLY exceeding the Score 3 anchor — verified against `PromptBuilder::EVALUATION_STANDARDS` (`:110-121`). The delta's own wording ("4 or 5") was NOT propagated. |
| Flaky shared `beai_test` database | `ROADMAP.md` R-4 (evidence) + `specs/ci-pipeline/spec.md` (contract) | R-4 already existed and is NOT duplicated. It was un-owned ("raise a change before assigning one"); it now names an owner requirement, following the R-1 precedent. The spec holds what MUST be true and points back to R-4 for the run-by-run evidence. |

### One new finding, raised during this merge

While verifying the advance-rule text in code, the advance condition was found to be stated
**twice at two different strengths**: `buildBudgetSection()` (`:249-254`) ends with the old
two-term form — *"Advance (speak end_phrase) only after all coverage topics are addressed OR
the follow-up budget of N is exhausted"* — with **no minimum conjunct**, while
`buildAdvanceSection()` (`:278-310`) states the full three-term condition.

No harm is demonstrated: the ADVANCE RULE section is the authoritative statement and the live
smoke closed cleanly on all five competencies. But a prompt stating one rule twice at two
strengths is a plausible source of early closing, and the weaker sentence is exactly what let
the original task-4.4 test pass without ever observing the advance section. Recorded as a
non-normative **Observation** blockquote inside the new advance requirement. **Not escalated
to a ROADMAP risk** — it is a wording question for whoever next edits the prompt, not
engineering debt with a distinct owner. No code was changed.

---

## Files written

| File | Change |
|---|---|
| `openspec/specs/interview-conversation/spec.md` | Purpose extended; composition inputs amended; SA-02 reconciled (3 scenarios repaired, 1 added); 2 new requirements (13 scenarios); i18n scope restructured; Coverage Note extended. |
| `openspec/specs/ci-pipeline/spec.md` | NEW `Requirement: The api Suite MUST Be Deterministic Under Its Own Test Database` (STATUS: OPEN), owner for R-4, 2 scenarios. |
| `openspec/ROADMAP.md` | R-4 "Recorded in" cell now names its owner spec. Evidence unchanged, not duplicated. |
| `openspec/changes/star-interviewer-protocol/verify-report.md` | Transcribed from Engram #1700 + warning-disposition table. |
| `openspec/changes/star-interviewer-protocol/archive-report.md` | This file. |

**No implementation code was modified. Nothing was committed.**

---

## Folder move — NOT performed, by instruction

The operator will run the history-preserving move themselves:

```
git mv openspec/changes/star-interviewer-protocol \
       openspec/changes/archive/2026-08-28-star-interviewer-protocol
```

`archive-report.md` and `verify-report.md` were written INTO the source folder so that single
command completes the archive with all six artifacts and full git history. Hand-copying via
file writes was not done: transcribing `design.md` / `proposal.md` by hand risks silent
corruption of an audit trail and discards history. Until that command runs, the change remains
listed under active changes.

## Residual risks

1. **The i18n scope restructure exceeds the delta's literal claim of "UNCHANGED".** Justified
   above and fully reversible; the normative hard-fail and every scenario are intact.
2. **`design`, `spec` and `tasks` have no Engram mirror.** The archived folder is their only
   home. Preserve it.
3. **The advance condition is stated twice in the prompt at two strengths** — observation
   recorded, no code touched, no evidence of harm.
4. **R-4 remains open and unfixed.** The `api` suite is still flaky; it now has an owner spec
   but no change. Until then a full-suite red carries no information.
