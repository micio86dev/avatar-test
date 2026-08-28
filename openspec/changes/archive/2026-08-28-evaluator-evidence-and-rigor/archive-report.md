# Archive Report: evaluator-evidence-and-rigor

Archived 2026-08-28. Verdict at archive: **PASS WITH WARNINGS — intentional, warnings
carried forward** (0 CRITICAL, so no archive block applied).

## Delivered

Three evaluator-side corrections, shipped as a chained-PR set in the `api` submodule and live
in production at `prompt_version` 3.0.0:

1. **The transcript's two roles split.** `TranscriptAssembler::assembleForParticipant()`
   returns a `ScoringCorpora {prompt, validation}` readonly DTO built from ONE ordered fetch
   filtered two ways, so the subset invariant (validation ⊂ prompt) is true by construction.
   The prompt corpus GREW — the whole participant conversation, both speakers, with the target
   competency's segment delimited. The validation corpus SHRANK — candidate utterances only.
   The old `assemble(InterviewSession)` and the equality invariant in its docblock were
   DELETED, not deprecated.
2. **Elision-tolerant excerpt matching.** `ExcerptValidator` splits on `/\.\.\.|\x{2026}/u`,
   trims, drops empty fragments, and walks forward with `strpos` and a monotonic cursor — not
   a regex wildcard, so out-of-order and overlapping fragments are rejected rather than
   backtracked into a match.
3. **Severity calibration.** An `EVALUATION STANDARDS` block injected AFTER `SCORING_PROCEDURE`,
   with its doubt-downward clause scoped explicitly to step 5 so it cannot repeal the
   anchor-primacy tie-break ratified in `bars-full-scale-1-5` one day earlier.
   `prompt_version` 2.0.0 → 3.0.0 (major; no migration, no backfill).

## Artifact traceability

| Artifact | File | Engram observation |
|---|---|---|
| proposal | `proposal.md` | #1648 `sdd/evaluator-evidence-and-rigor/proposal` |
| design + spec + tasks | `design.md`, `specs/scoring-engine/spec.md`, `tasks.md` | #1649 `sdd/evaluator-evidence-and-rigor/design` |
| apply-progress | (recorded in `tasks.md` apply notes) | #1651 `sdd/evaluator-evidence-and-rigor/apply-progress` |
| verify-report | `verify-report.md` (transcribed at archive) | #1697 `sdd/evaluator-evidence-and-rigor/verify-report` |
| archive-report | this file | `sdd/evaluator-evidence-and-rigor/archive-report` |

Related context: #1647 (reference-log divergences), #1653 (Railway `SCORING_PROMPT_VERSION`
must be bumped on `api` AND `worker`).

## Task completion gate

59/59 tasks `[x]` in `tasks.md`, all verified TRUE against the code by the verify phase. No
stale-checkbox reconciliation was needed or performed.

## Specs promoted

Delta `specs/scoring-engine/spec.md` merged into `openspec/specs/scoring-engine/spec.md`.
The delta declared three `MODIFIED` requirements; two of them had no same-named requirement in
the main spec, so the merge was not purely mechanical:

| Delta requirement | Action taken in the main spec |
|---|---|
| Transcript Assembly for Scoring | **ADDED** as a new requirement (no such heading existed). The behaviour it repeals lived inside *Per-Competency Scoring Pipeline*, whose prose "(the SAME assembled string is used in the prompt and in excerpt validation)" and whose scenario line "AND the same serialized string is used in both the LLM prompt and the `ExcerptValidator`" were both amended — leaving them would have made the source of truth contradict itself on the exact invariant this change repealed. |
| Excerpt Verbatim Validation | **REPLACED** in place. Four scenarios present in the old requirement but absent from the delta were PRESERVED (non-verbatim containment, two whitespace-normalisation cases) rather than dropped. One old scenario, *Cross-utterance excerpt accepted*, was NOT preserved: its example quoted interviewer text and a `Candidate:` speaker prefix as a legal excerpt, which the new candidate-only validation corpus forbids. The delta's own cross-utterance scenario replaces it. |
| Scoring Prompt Construction | **ADDED** as a new requirement. The existing *PromptBuilder Injects the AD-1 Rubric* requirement pinned `prompt_version` at `2.0.0` and had a scenario asserting it; that pin is now marked SUPERSEDED with a pointer, and the scenario reworded to track the configured value. The requirement itself was preserved — only the version literal moved. The Railway `api`+`worker` deploy note was folded in, because the config default never reaches either service. |

Also updated in `openspec/specs/scoring-engine/spec.md`: the **Coverage Note** now names the
two-corpora split, the subset invariant, the anchored elision walk, marker placement,
case-insensitive speaker matching, and the EVALUATION STANDARDS / step-5 scoping guard.

**Observed but NOT fixed (out of scope for this archive):** `openspec/specs/scoring-engine/spec.md`
contains the requirement *Non-EN Anchor Language (L-2 Hard-Fail)* **twice**, with near-identical
text and scenarios. Pre-existing duplication from an earlier merge; flagged rather than silently
restructured.

## Warnings carried forward — deliberately outside this folder

The verification raised two WARNINGs and one SUGGESTION. An archived change folder is where
findings go to be forgotten, so each was recorded in a live document as well:

| Finding | Recorded in |
|---|---|
| **W1** — the `ai-integration` lane reports `success` over zero assertions; `RubricAdherenceDriftTest` self-skips on an empty `ANTHROPIC_API_KEY`, and the lane's `release/**` trigger has not fired since 0.33.0. Repo-level CI defect. | `openspec/specs/ci-pipeline/spec.md` → new **Requirement: A Skipped `@ai` Guard Test MUST NOT Report Success**, marked `STATUS: OPEN — specified, NOT yet implemented`, with the concrete run IDs. Cross-referenced from `openspec/specs/scoring-engine/spec.md` Quality Debt item 7. |
| **W2** — a corpora swap in `ScoreEvaluationJob` would not fail any test; the scenario *Excerpt quoting the interviewer is rejected* is PARTIAL. | `openspec/specs/scoring-engine/spec.md` → Quality Debt item 5, including the concrete fix (one job-level test citing an avatar utterance). |
| **S1** — `PerIndicatorIsolationTest` never demonstrates a surviving positive sibling. | `openspec/specs/scoring-engine/spec.md` → Quality Debt item 6. |

All three are also indexed in `openspec/ROADMAP.md` under a new **Carried-forward risk**
section (R-1, R-2, R-3), which points at the owning spec for each. They are engineering debt,
not product decisions, and were deliberately kept out of the ROADMAP's *Product decisions*
list.

## Not done here

No implementation code was touched during archive, and nothing was committed — review and
commit are the operator's.

## Next

`star-interviewer-protocol` — the fourth and last reference-log divergence (STAR coverage
model in `SystemPromptComposer`, same-episode constraint, minimum question count, follow-up
budget 2→4). Sequenced last on purpose: it is the only one that cannot be verified without a
live avatar session and a human watching.
