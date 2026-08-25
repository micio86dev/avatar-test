# Proposal: Evaluator Evidence and Rigor

## Intent

On **2026-08-24** the product owner supplied a reference BEI interview + evaluation log
showing how a BARS assessment *should* run. Comparing it against the implementation surfaced
seven divergences. Three shipped (`bars-full-scale-1-5`, `scoring-failure-containment`); four
remain, and this change closes the three that live on the **evaluator** side of the seam.

They are not three unrelated bugs. They are one story told three times: **the evaluator is
judging the wrong evidence, and judging it too kindly.**

| Gap | Today | Consequence |
|---|---|---|
| No severity calibration | `PromptBuilder.php:135-161` has no standards block at all | Scores inflate. `5` costs the model nothing. |
| Evidence is one competency wide | `TranscriptAssembler::assemble($session)` — one `InterviewSession` | A candidate who demonstrates COL while answering the DRV question gets no credit for it. |
| Evidence may be the interviewer's own words | `ExcerptValidator` validates against the full assembled string, `avatar:` lines included | The model can quote the question back as proof the candidate said it. |

Plus one half-finished item from `scoring-failure-containment`: `ExcerptValidator` has no
ellipsis handling, so `"Nel giro di quattro mesi... il tempo medio è crollato"` — the exact
shape the reference evaluator produces naturally — is rejected outright.

Success = the evaluator sees the whole conversation, may only cite the candidate, tolerates
the elisions a real quotation contains, and holds a `5` to a standard it must earn.

**Deliberately NOT in scope: the STAR interviewer protocol.** That is the fourth remaining
divergence and it is higher value than any of these — but it is the only one that cannot be
verified without a live avatar session and a human watching. It ships as its own change
(`star-interviewer-protocol`), after this one, against the clean baseline this one establishes.

---

## AD-1 — The transcript's two roles are SPLIT; the prompt corpus and the validation corpus stop being the same string

This is the load-bearing decision of the change. Everything else follows from it.

`TranscriptAssembler.php:20-22` states the current invariant explicitly:

> This same string MUST be passed to both:
>   1. The LLM prompt (user message in PromptBuilder).
>   2. ExcerptValidator for substring validation.

That invariant was correct when both roles wanted the same thing. They no longer do:

- **The prompt corpus** must GROW: the whole conversation, all competencies, `avatar:` lines
  included. An interviewer's question is context — "tell me about a time you had to
  overrule your team" is what makes the answer legible.
- **The validation corpus** must SHRINK: `candidate:` lines only. Evidence about the
  candidate is what the candidate said. Nothing else is evidence.

So `TranscriptAssembler` grows two named methods with two different outputs, and the
one-string invariant is replaced by a **subset invariant**:

> The validation corpus MUST be a subset of the prompt corpus.

**Why the subset invariant is strictly safer than the equality invariant it replaces.**
Equality guaranteed that a verbatim quote from the prompt would validate. Subset guarantees
that *and* refuses a class of quote equality accepted: the model's own question. Validation
becomes strictly stricter — never looser. There is no input that passes the new rule and
fails the old one. That asymmetry is the whole argument, and it is why this is safe to ship
without a migration or a shadow period.

**Why not simply strip `avatar:` lines from the single string and pass that to both.**
Because it would blind the evaluator to the questions, and a BEI answer read without its
question is frequently unscoreable. The reference log carries both speakers for exactly this
reason. Stripping is a validation concern, not a prompt concern; conflating them is what
produced the defect in the first place.

## AD-2 — Full conversation, marked target segment — but STILL one LLM call per competency

The reference log runs a single evaluation call over the entire conversation. **We do not
copy that**, and the reason is not inertia.

One call per competency buys three properties we already paid for and are still using:
per-competency **failure containment** (`scoring-failure-containment` exists precisely to
stop one bad competency taking its siblings down), **resume-skip** on retry, and a
**deterministic indicator↔position mapping** that a 15-competency mega-response would make
fragile in exactly the way `PromptBuilder.php:26-29` warns about.

So: each call receives the FULL conversation with the target competency's segment
**explicitly delimited**, and the prompt instructs the model to weight that segment while
remaining free to cite corroborating evidence from anywhere the candidate spoke.

Cost is the honest tradeoff and it must be stated: N competencies × full transcript instead
of N × one segment. For a 15-competency ICO interview that is roughly a 15× increase in input
tokens on the scoring path. **This is a real cost and it is a decision the product owner
should confirm, not one this proposal should quietly make.**

**RATIFIED 2026-08-25 — full transcript, cost accepted.** The product owner was shown the
token multiple and the three cheaper alternatives (windowed context, `potential`-only,
defer) and chose full fidelity to the reference. No cap, no assessment-type carve-out.
Should the bill land badly under real load, the mitigation is additive (cap the non-target
context) and does not invalidate anything specified here. Closes OQ-1.

## AD-3 — Ellipsis tolerance is a SPLIT-AND-MATCH-IN-ORDER rule, not a wildcard

An excerpt containing an elision marker is split on that marker; each fragment must appear in
the validation corpus, **in order, each after the previous one ended**. It is not a regex
`.*` — an ordered anchored walk cannot match a quote assembled from fragments the candidate
said in the reverse order, and it cannot backtrack across the corpus to manufacture a
sentence that was never uttered.

Markers recognised: `...` (three ASCII periods) and `…` (U+2026). Both, because a model
emitting Italian text produces either, and rejecting a valid quotation over a codepoint is
the same defect class we are fixing.

Empty fragments (a quote that opens or closes with an elision) are discarded before matching,
so a leading `"... il tempo è crollato"` behaves as its non-elided remainder rather than
failing on a zero-length needle that `str_contains` would trivially accept.

## AD-4 — Rigor is prompt text, and prompt text has a version

The EVALUATION STANDARDS block is injected into `PromptBuilder`'s system prompt, carrying
the reference log's calibration: `3` is the baseline, `4-5` are rare and require **all** of
{specific situation, concrete actions, measurable outcome}, generic answers land at `1-2`,
and ties resolve **downward**.

Two constraints on how it is written:

1. It MUST NOT contradict `SCORING_PROCEDURE` (`PromptBuilder.php:57-75`). That procedure is
   an ordered early-stopping walk whose step 5 is the ONLY place `4` and `2` may be assigned,
   and whose anchor-primacy tie-break was ratified in `bars-full-scale-1-5`. "When in doubt
   choose the lower one" must be scoped to step 5's *residual* choice, never allowed to
   override an authored anchor match at steps 2-4. A rigor sentence that quietly re-opens the
   tie-break would repeal a decision ratified one day earlier.
2. `config/scoring.php:110` `prompt_version` bumps `2.0.0` → `3.0.0`. Major, because every
   evaluation produced after this change is calibrated differently from every evaluation
   before it, and `framework/model/prompt` versioning exists so that two scores are only ever
   compared when they mean the same thing.

## AD-5 — The reference is NOT followed on self-computed scores

The reference asks the LLM to compute `score` and `reliability` itself. We do not, and will
not. `MeanCalculator` and `AssessableFractionReliability` compute both server-side. A model
computing its own percentages is a determinism hole and would silently repeal ratified
product decision #1. Recorded here so no future reader "aligns to the reference" on this point.

---

## Scope

**In:** `api` only.
- `PromptBuilder` — EVALUATION STANDARDS block; target-segment instruction.
- `TranscriptAssembler` — full-participant assembly, target marking, candidate-only corpus.
- `ExcerptValidator` — ellipsis tolerance; validates against the candidate-only corpus.
- `ScoreEvaluationJob::scoreCompetency` — wires the two corpora.
- `config/scoring.php` — `prompt_version` → `3.0.0`.

**Out:** the STAR interviewer prompt (`SystemPromptComposer`, `config/conversation.php`
follow-up budget) — separate change. Frontend and backoffice: untouched. No schema change.
No change to `MeanCalculator`, `AssessableFractionReliability`, `CompletionGate`, or the
`{1,2,3,4,5,-1}` domain.

## Blast radius (from CodeGraph, verified)

`TranscriptAssembler` — 8 call sites in `ScoreEvaluationJob`, plus **`app/Support/Demo/DemoWriter.php`**.
The demo seeder writes evaluations through the same assembler; the seeded dataset runs in
**production** and is what the product is demoed with. It must keep producing excerpts that
validate. Existing guard: `tests/Feature/Demo/ExcerptVerbatimTest.php`.

Tests that must stay green: `Unit/Services/TranscriptAssemblerTest`,
`Unit/Services/ExcerptValidatorTest`, `Unit/Services/PromptBuilderTest`,
`Feature/Scoring/RubricAdherenceDriftTest`, `Feature/Demo/ExcerptVerbatimTest`,
`Feature/Jobs/ScoreEvaluationJobDefensiveBranchesTest`.

Correctness-critical zone → **~95% coverage**, per CLAUDE.md.

## Open questions — both CLOSED 2026-08-25

- **OQ-1 — RATIFIED (product owner):** full transcript, cost accepted. See AD-2.
- **OQ-2 — DECIDED (orchestrator):** the EVALUATION STANDARDS block is **English only**, not
  localised. It is calibration language addressed to the model, not text the candidate ever
  sees, and `SCORING_PROCEDURE` — the block it sits beside and must not contradict — is
  already English-only over transcripts in any language. Localising one and not the other
  would be the inconsistency, not the fix. The **rubric** (indicator text and anchors) stays
  localised and hard-fails on a missing translation exactly as today; nothing in the L-2
  hard-fail path changes.

## Non-goals

- Collapsing to a single LLM call for all competencies (AD-2).
- Asking the LLM for `score` or `reliability` (AD-5).
- Any change to the interviewer's behaviour (separate change).
