# Design: Evaluator Evidence and Rigor

Decisions are numbered `D-n`. Code-verified findings are numbered `F-n` and cite the line
they were read from. Nothing here is inferred from memory; every claim about current
behaviour was read off disk on 2026-08-25.

---

## Code-verified findings

**F-1** — `TranscriptAssembler.php:34-47` takes `InterviewSession $session`, fetches
`$session->utterances()->withoutGlobalScopes()->orderBy('ts')->orderBy('id')`, maps to
`"{$u->speaker}: {$u->text}"` and joins with `\n`. One session, both speakers, one string.

**F-2** — `TranscriptAssembler.php:20-22` states the equality invariant in a docblock: the
same string goes to the prompt *and* to `ExcerptValidator`. This is the invariant D-1 repeals.

**F-3** — `ExcerptValidator.php:46` is a bare `str_contains($normalizedTranscript,
$normalizedExcerpt)`. No elision handling. `ExcerptValidator.php:37-39` short-circuits
`score === -1 && excerpts === []`.

**F-4** — `ScoreEvaluationJob.php:358-361` loads the session by
`participant_id` + `competency_code`, one per competency. `ScoreEvaluationJob.php:588` calls
`assemble($session)` and passes the result to `promptBuilder->build(transcript: $transcript)`
at line 599. The same `$transcript` reaches `ExcerptValidator` later in `scoreCompetency`.

**F-5** — `create_utterances_table.php:18` — `speaker` is an enum `{candidate, avatar}`. It
is a plain `string` column (`:39`), not a DB enum, so filtering is application-level.

**F-6** — `InterviewSession` has `UNIQUE(participant_id, competency_code)` (model docblock
`:48`) and a **nullable** `started_at` (`:69`, `Carbon|null`).

**F-7** — `app/Support/Demo/DemoWriter.php:573` validates every demo excerpt with the
production `ExcerptValidator` against `TranscriptAssembler::assemble()` before writing the
row, deliberately, so a fixture bug throws loudly. `DemoWriter.php:599` news up the assembler
directly. **The demo dataset runs in production** — this path is not test-only.

**F-8** — `PromptBuilder.php:57-75` `SCORING_PROCEDURE` is an ordered early-stopping walk;
step 5 is the only place `4`/`2` may be assigned; the anchor-primacy tie-break lives in its
closing paragraph. `PromptBuilder.php:135-161` builds the system prompt with **no** severity
guidance anywhere.

**F-9** — `config/scoring.php:110` — `prompt_version` is `2.0.0` (env `SCORING_PROMPT_VERSION`).
`:51` — `model_version` is `claude-haiku-4-5-20251001`.

---

## D-1 — One fetch, one DTO, two corpora — the subset invariant is STRUCTURAL

`TranscriptAssembler` gains one method returning a small readonly DTO:

```
assembleForParticipant(int $participantId, string $targetCompetencyCode): ScoringCorpora
ScoringCorpora { public string $prompt; public string $validation; }
```

**Both corpora are derived from a single ordered fetch of the participant's utterances.**
This is the point of the DTO and the reason it is not two independent methods: if the prompt
corpus and the validation corpus were assembled by two separate queries, the subset invariant
(spec: *every candidate utterance in the validation corpus is also in the prompt corpus*)
would be a convention that tests enforce. Built from one in-memory collection, filtered two
ways, it is **true by construction** and cannot drift.

**Why not keep two public methods for readability.** Because the failure mode of the readable
version is silent and severe: a future edit that changes the ordering in one method and not
the other produces an evaluator that is shown evidence it is then forbidden to cite, and the
symptom is a mysteriously unverifiable excerpt three layers downstream. One fetch removes the
possibility rather than documenting it.

`assemble(InterviewSession $session)` is **deleted**, not deprecated. Its four call sites in
`ScoreEvaluationJob` plus `DemoWriter` all migrate in this change (F-4, F-7). A kept-but-
unused method whose docblock still asserts the repealed equality invariant (F-2) is worse
than no method.

## D-2 — Session ordering is `orderBy('id')`, NOT `started_at`

Sessions must be ordered deterministically among themselves. `started_at` is the semantically
appealing choice and is **rejected**: F-6 says it is nullable, and NULL ordering in Postgres
is `NULLS LAST` on `ASC` by default but is a property of the query, not of the data. A
determinism-critical ordering must not depend on a default that a future query rewrite can
flip without touching this file.

`id` is monotonic, never null, and — because a session row is created as the interview
reaches that competency — equals interview order in practice. Within a session, the existing
`orderBy('ts')->orderBy('id')` dual sort is preserved verbatim (F-1): `ts` alone is not
unique under HeyGen bulk-replace, which is exactly why that dual sort exists.

Final ordering: `session.id ASC`, then within each session `utterance.ts ASC, utterance.id ASC`.

## D-3 — Segment markers live in the PROMPT corpus only

The target competency's segment is delimited by two lines:

```
=== TARGET COMPETENCY {CODE} — PRIMARY EVIDENCE BEGINS ===
=== TARGET COMPETENCY {CODE} — PRIMARY EVIDENCE ENDS ===
```

**The markers are never written into the validation corpus.** That is not a stylistic
choice — it is what makes it impossible for the model to cite a marker as evidence. The
validation corpus contains candidate utterance text and nothing else, so a quoted marker
fails validation for the same reason invented text does, through the same code path, with no
special case.

A participant whose only session is the target competency still gets markers; the whole
corpus is simply the delimited segment. The spec asserts this explicitly so the single-session
case is not accidentally special-cased into markerless output.

## D-4 — Elision matching: anchored forward walk over trimmed non-empty fragments

Both corpus and excerpt are whitespace-normalised first, exactly as today
(`preg_replace('/\s+/', ' ', …)`, F-3) — unchanged, because cross-utterance excerpts depend
on it. Then:

1. Split the normalised excerpt on `/\.\.\.|\x{2026}/u` — ASCII triple-period **or** U+2026.
2. `trim` each fragment; **discard empty ones**.
3. If no fragment survives, reject. (An excerpt made only of elision markers asserts nothing;
   accepting it would be the zero-length-needle hole the spec names.)
4. Walk: `$cursor = 0`; for each fragment, `strpos($corpus, $fragment, $cursor)`; on `false`,
   reject; else `$cursor = $pos + strlen($fragment)`.

**Why an anchored walk and not `preg_quote` + `.*`.** A wildcard regex can backtrack. This
walk cannot: each fragment must start at or after the byte where the previous one ended, so a
quote whose fragments appear in the corpus in the reverse order is rejected, and two fragments
can never share bytes. That is the difference between "tolerating an elision" and "letting the
model assemble a sentence the candidate never said". Also avoids handing user-controlled text
to the regex engine.

**Zero elisions is the same code path.** One fragment, one `strpos` from offset 0 — byte-for-
byte equivalent to today's `str_contains`. There is no `if (hasElision)` branch, so the
existing behaviour cannot regress separately from the new behaviour.

**Cursor safety.** `$cursor` can only ever reach `strlen($corpus)` exactly (a match always
fits inside the corpus), and `strpos` accepts an offset equal to the string length. It can
never exceed it, so the PHP 8 `ValueError` for an out-of-range offset is unreachable. Stated
because it is the kind of thing a reviewer must be able to check without re-deriving it.

**Byte-based matching over UTF-8 is correct** and is what ships today. UTF-8 is
self-synchronising: a byte-level match of a valid UTF-8 needle in a valid UTF-8 haystack
cannot land mid-codepoint. No `mb_*` migration, no behaviour change for Italian text.

## D-5 — EVALUATION STANDARDS is placed AFTER the procedure and scoped to step 5

Placement is load-bearing. The block goes **after** `SCORING_PROCEDURE`, and its
doubt-resolution sentence is written to name step 5 explicitly — e.g. *"at step 5, when
choosing between the two residual levels, prefer the lower"*. An unscoped "when in doubt
choose the lower one" placed before the procedure would read as a general override and would
silently repeal the anchor-primacy tie-break ratified in `bars-full-scale-1-5` **one day
earlier** (F-8).

This is the single highest-risk line in the change. A test asserts that the composed prompt
still contains the anchor-primacy paragraph verbatim and that the standards block does not
introduce a competing general tie-break.

The block is English-only (proposal OQ-2), sitting beside an English-only procedure. The
rubric stays localised and the L-2 hard-fail path is untouched.

## D-6 — `prompt_version` 2.0.0 → 3.0.0, and it is a config default change

`config/scoring.php:110` default moves to `3.0.0` (F-9). Major: every evaluation after this
change is calibrated differently and sees different evidence from every evaluation before it.
`framework/model/prompt` versioning exists so two scores are compared only when they mean the
same thing; a minor bump here would be a lie about comparability.

No migration, no backfill. Historical evaluations keep the `2.0.0` they were stamped with —
that is the record working correctly.

## D-7 — `DemoWriter` migrates and its existing guard is the regression test

`DemoWriter` (F-7) builds each demo excerpt as a sentence-index slice of a candidate
`Utterance` it just wrote, then validates it. Those excerpts are **already candidate-only**,
so the stricter validation corpus does not invalidate them — but this must be *demonstrated*,
not assumed, because the dataset ships to production. `tests/Feature/Demo/ExcerptVerbatimTest.php`
already exists and already asserts exactly this; it stays green or the change is wrong.

`DemoWriter` switches to `assembleForParticipant($participantId, $competencyCode)->validation`.

## D-9 — Speaker matching is CASE-INSENSITIVE (decided during apply, not planned)

F-5 established that `speaker` is a plain `string` column holding `{candidate, avatar}`, and
both write paths enforce that: `UtteranceController` validates `in:candidate,avatar` and
`HeygenProvider` maps provider roles through a `match` that **throws** on anything
unrecognized. An exact `=== 'candidate'` comparison is therefore correct for every row
written today, and that is what was first implemented.

`DeterminismTest` then failed, because its fixture writes `Candidate` capitalized. The
fixture is not production — but it made the real question visible: **what happens to a row
this codebase did not write?**

The two failure modes are not symmetric, and that asymmetry decides it:

- **Case-sensitive, one historic `Candidate` row** → that utterance is silently dropped from
  the validation corpus. Every excerpt then fails verbatim validation, every indicator
  becomes `excerpt_unverifiable`, and the participant scores `-1` across the board with
  nothing anywhere naming the cause. Catastrophic, silent, and indistinguishable from a
  genuinely empty interview.
- **Case-insensitive** → correct for both spellings. Case-folding cannot mistake one speaker
  for another; `Candidate` and `candidate` are unambiguously the same person.

A value that is genuinely neither speaker is still excluded either way, and that degrades to
a **visible** per-indicator `excerpt_unverifiable`, not a silent zero. Comparison is
`strtolower(trim(...))`. Two tests pin this: a capitalized fixture is recognised, and a
`system` speaker is excluded from validation while remaining visible in the prompt.

**Why this is not "silently tolerating bad data".** Tolerance here loses nothing and hides
nothing: the speaker distinction is preserved, and the only behaviour changed is that a
letter case cannot destroy an interview's evidence.

## D-10 — Markers are emitted only around a target segment that HAS content

If the target competency's session exists but holds no utterances, no markers are emitted.
Empty delimiters would announce a primary-evidence block that does not exist, and the prompt
(D-3, task 12) explicitly tells the model what those markers mean. Announcing nothing is
better than announcing an empty something.

This is why the "no utterances → both corpora empty" scenario holds even when sessions exist.

## D-8 — Context budget is checked, not assumed

Each scoring call now carries the full interview instead of one competency's slice. The calls
remain **independent** — nothing is concatenated across competencies — so the relevant limit
is one full transcript per request against `claude-haiku-4-5-20251001`'s context window (F-9),
which a 70-90 minute interview does not approach. The cost is billing, not truncation, and the
product owner ratified it on 2026-08-25 with the token multiple in front of them.

`max_tokens` governs **output** and is unchanged: the response shape is still one competency's
behaviours array.

---

## Call-site changes in `ScoreEvaluationJob::scoreCompetency`

`$transcript = $transcriptAssembler->assemble($session)` (F-4, line 588) becomes a
`ScoringCorpora`. `$corpora->prompt` goes to `promptBuilder->build()`; `$corpora->validation`
goes to `ExcerptValidator`. The `InterviewSession` lookup at `:358-361` is **kept** — it is
still how the job decides whether a competency has a session at all, and its `continue` branch
at `:363-370` is unaffected.

Nothing else in the job moves. Failure containment, resume-skip, `UnscorableReason` handling,
`persistUnscorable`, the `UniqueConstraintViolationException` CW5 branch: all untouched.

## Test plan

Correctness-critical zone → **~95%**, per CLAUDE.md. Strict TDD: red first.

| Suite | Adds |
|---|---|
| `Unit/Services/TranscriptAssemblerTest` | multi-session assembly, session ordering, marker placement, candidate-only filtering, subset invariant, empty-utterance case |
| `Unit/Services/ExcerptValidatorTest` | both markers, out-of-order rejection, overlap rejection, leading/trailing elision, invented-fragment rejection, all-elision rejection, non-elided regression |
| `Unit/Services/PromptBuilderTest` | standards block present, English under `it` locale, anchor-primacy paragraph intact, marker named in prompt |
| `Feature/Scoring/RubricAdherenceDriftTest` | must stay green — guards the procedure wording |
| `Feature/Demo/ExcerptVerbatimTest` | must stay green — guards the production demo dataset (D-7) |
| `Feature/Jobs/ScoreEvaluationJobDefensiveBranchesTest` | must stay green — guards the untouched failure paths |

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Standards block silently repeals the anchor-primacy tie-break | **CRITICAL** | D-5 scoping + explicit test asserting the paragraph survives verbatim |
| Demo dataset excerpts stop validating in production | HIGH | D-7; `ExcerptVerbatimTest` is the gate, and it already exists |
| Elision walk accepts a fabricated sentence | HIGH | D-4 anchored non-backtracking walk; out-of-order, overlap and invented-fragment scenarios all specified |
| Scoring cost rises ~10-15× | ACCEPTED | Ratified by the product owner 2026-08-25 with the multiple stated |
| Session ordering non-deterministic | MEDIUM | D-2 `orderBy('id')`, no nullable column in the sort |
