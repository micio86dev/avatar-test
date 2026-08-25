# Delta for Scoring Engine

## MODIFIED Requirements

### Requirement: Transcript Assembly for Scoring

Transcript assembly MUST produce **two distinct corpora** from the same participant's
utterances, serving two different roles.

**The prompt corpus** MUST contain every utterance of every `InterviewSession` belonging to
the participant, both speakers included (`candidate` and `avatar`), ordered
`orderBy('ts')->orderBy('id')` — the dual sort remains determinism-critical, as `ts` alone is
not unique under HeyGen bulk-replace. Sessions MUST be ordered deterministically among
themselves. The segment belonging to the competency currently being scored MUST be
**explicitly delimited** by a marker the prompt names, so the model can weight it while
remaining free to cite corroborating evidence from elsewhere in the conversation.

**The validation corpus** MUST contain **only** utterances whose `speaker` is `candidate`,
drawn from the same participant-wide set, in the same order. The speaker comparison MUST be
**case-insensitive**: a value differing only in letter case denotes the same speaker, and an
exact comparison would silently drop such an utterance, failing every excerpt that cites it
and scoring the participant `-1` across the board with no stated cause. A `speaker` that is
genuinely neither value MUST be excluded from the validation corpus while remaining present
in the prompt corpus.

Markers MUST be emitted only around a target segment that contains at least one utterance.
An empty pair of markers would announce a primary-evidence block that does not exist.

The corpora MUST satisfy the **subset invariant**: every candidate utterance present in the
validation corpus is also present in the prompt corpus. A change that breaks this invariant
is a defect, because it would allow the model to be shown evidence it is then forbidden to
cite.

(Previously: `TranscriptAssembler::assemble(InterviewSession $session)` produced **one**
string from **one** session — the competency currently being scored — and that single string
was passed both to the LLM prompt and to `ExcerptValidator`. Evidence a candidate gave while
answering a different competency's question was invisible to the evaluator, and the
interviewer's own `avatar:` lines were a legal source of "evidence" about the candidate.)

#### Scenario: Prompt corpus spans every competency of the participant

- GIVEN a participant with three `InterviewSession` rows — COL, DRV, COM — each holding utterances
- WHEN the prompt corpus is assembled while scoring COL
- THEN it contains the utterances of all three sessions
- AND the utterances of each session appear in `ts`, then `id` order
- AND the session ordering is deterministic across repeated assembly of the same data

#### Scenario: The target competency's segment is delimited

- GIVEN the participant above and COL is the competency being scored
- WHEN the prompt corpus is assembled
- THEN the COL segment is enclosed between an explicit start marker and end marker
- AND the DRV and COM segments are present but not enclosed by those markers
- AND assembling the same data while scoring DRV instead moves the markers to the DRV segment, leaving the text otherwise identical

#### Scenario: Validation corpus excludes the interviewer entirely

- GIVEN a session containing `avatar: Tell me about a time you overruled your team` and `candidate: I overruled my team on the vendor choice`
- WHEN the validation corpus is assembled
- THEN it contains `I overruled my team on the vendor choice`
- AND it does NOT contain `Tell me about a time you overruled your team`

#### Scenario: Subset invariant holds

- GIVEN any participant with any number of sessions and utterances
- WHEN both corpora are assembled
- THEN every candidate utterance text present in the validation corpus is also present in the prompt corpus

#### Scenario: Participant with a single session behaves as before

- GIVEN a participant with exactly one `InterviewSession`, for the competency being scored
- WHEN the prompt corpus is assembled
- THEN it contains that session's utterances, both speakers, in `ts`/`id` order
- AND the whole corpus is the delimited target segment

#### Scenario: Participant with no utterances yields empty corpora

- GIVEN a participant whose sessions hold no utterances
- WHEN both corpora are assembled
- THEN both are empty strings
- AND no exception is thrown

#### Scenario: An empty target session among non-empty siblings emits no markers

- GIVEN the target competency's session holds no utterances
- AND another session holds candidate utterances
- WHEN both corpora are assembled
- THEN the prompt corpus contains the other session's utterances
- AND it contains no marker text at all

#### Scenario: A capitalized speaker is still recognized as the candidate

- GIVEN an utterance whose `speaker` is `Candidate` rather than `candidate`
- WHEN the validation corpus is assembled
- THEN that utterance's text is present in it

#### Scenario: An unknown speaker is excluded from validation but kept in the prompt

- GIVEN an utterance whose `speaker` is neither `candidate` nor `avatar`
- WHEN both corpora are assembled
- THEN its text is absent from the validation corpus
- AND its speaker-prefixed line is present in the prompt corpus

#### Scenario: Another participant's utterances never leak in

- GIVEN two participants each holding a session for the same competency
- WHEN the corpora are assembled for the first participant
- THEN neither corpus contains any of the second participant's utterances

---

### Requirement: Excerpt Verbatim Validation

Every excerpt on an `IndicatorScore` MUST be validated against the **validation corpus**
(candidate utterances only) after whitespace normalisation — collapsing runs of `\s+` to a
single U+0020 on both sides and trimming. The **original** excerpt text is persisted, never
the normalised form.

An excerpt containing an **elision marker** — `...` (three ASCII periods) or `…` (U+2026) —
MUST be accepted when its fragments appear in the validation corpus **in order, each strictly
after the previous fragment ended**. Matching MUST be an anchored forward walk with no
backtracking: it MUST NOT be implemented as a regex wildcard, and it MUST NOT accept a quote
whose fragments appear in the corpus in a different order from the one the excerpt asserts.

Empty fragments — produced when an excerpt opens or closes with an elision, or contains two
adjacent markers — MUST be discarded before matching, so that a zero-length needle can never
be the reason a quote is accepted.

An excerpt that fails validation MUST NOT discard its sibling indicators: the affected
indicator alone is persisted with `score = -1` and
`unassessable_reason = 'excerpt_unverifiable'`, as already specified by
Requirement: Per-Indicator Validation-Failure Isolation.

A `score = -1` with an empty excerpts array MUST skip excerpt validation entirely.

(Previously: validation ran against the single assembled transcript, which included the
interviewer's `avatar:` lines — so an excerpt quoting the interviewer's own question passed
as evidence about the candidate. And matching was a bare `str_contains`, so any quotation
containing an elision — the natural shape a real evaluator produces — was rejected outright.)

#### Scenario: Excerpt quoting the interviewer is rejected

- GIVEN the LLM returns the excerpt `Tell me about a time you overruled your team` for indicator I
- AND that sentence was spoken by `avatar`, not by `candidate`
- WHEN excerpt validation runs
- THEN the excerpt is not verbatim in the validation corpus
- AND indicator I alone is persisted with `score = -1` and `unassessable_reason = 'excerpt_unverifiable'`
- AND every sibling indicator of the same competency retains its own score

#### Scenario: Elided excerpt with ASCII ellipsis is accepted

- GIVEN the candidate said `Nel giro di quattro mesi abbiamo rifatto la pipeline e il tempo medio è crollato a otto minuti`
- AND the LLM returns the excerpt `Nel giro di quattro mesi... il tempo medio è crollato`
- WHEN excerpt validation runs
- THEN the excerpt is accepted
- AND the excerpt is persisted with its original text, elision marker included

#### Scenario: Elided excerpt with U+2026 is accepted

- GIVEN the same candidate utterance
- AND the LLM returns the excerpt `Nel giro di quattro mesi… il tempo medio è crollato`
- WHEN excerpt validation runs
- THEN the excerpt is accepted

#### Scenario: Out-of-order fragments are rejected

- GIVEN the candidate said `Nel giro di quattro mesi abbiamo rifatto la pipeline e il tempo medio è crollato`
- AND the LLM returns the excerpt `il tempo medio è crollato... Nel giro di quattro mesi`
- WHEN excerpt validation runs
- THEN the excerpt is rejected, because the second fragment does not occur after the first one ended
- AND indicator I is persisted with `score = -1` and `unassessable_reason = 'excerpt_unverifiable'`

#### Scenario: Fragments must not overlap

- GIVEN the candidate said `abbiamo rifatto la pipeline`
- AND the LLM returns the excerpt `abbiamo rifatto la...rifatto la pipeline`
- WHEN excerpt validation runs
- THEN the excerpt is rejected, because the second fragment's match would have to start before the first fragment ended

#### Scenario: Leading elision is discarded, not treated as an empty match

- GIVEN the candidate said `il tempo medio è crollato a otto minuti`
- AND the LLM returns the excerpt `...il tempo medio è crollato`
- WHEN excerpt validation runs
- THEN the leading empty fragment is discarded
- AND the excerpt is accepted on the strength of its non-empty remainder alone

#### Scenario: An elision does not license invented text

- GIVEN the candidate said `abbiamo rifatto la pipeline`
- AND the LLM returns the excerpt `abbiamo rifatto la pipeline... e ho licenziato il team`
- WHEN excerpt validation runs
- THEN the excerpt is rejected, because the second fragment appears nowhere in the validation corpus

#### Scenario: Non-elided excerpts keep their existing behaviour

- GIVEN the LLM returns an excerpt with no elision marker that is a verbatim substring of the validation corpus
- WHEN excerpt validation runs
- THEN the excerpt is accepted, exactly as before this change

#### Scenario: Cross-utterance excerpt from the candidate still validates

- GIVEN two consecutive `candidate` utterances whose texts, joined, contain the excerpt after whitespace normalisation
- WHEN excerpt validation runs
- THEN the excerpt is accepted

---

### Requirement: Scoring Prompt Construction

The scoring system prompt MUST carry an **EVALUATION STANDARDS** block establishing severity
calibration, in addition to the existing IMPORTANT RULES, SCORING PROCEDURE, rubric and
output-format sections. The block MUST establish that `3` is the baseline for adequate
evidence, that `4` and `5` are rare and require **all three** of a specific situation,
concrete actions and a measurable outcome, and that generic or hypothetical answers score
`1` or `2`.

The block MUST NOT contradict the SCORING PROCEDURE. Specifically, any instruction to
resolve doubt downward MUST be scoped to the residual choice at step 5 of that procedure, and
MUST NOT override the anchor-primacy tie-break: evidence equally consistent with an authored
anchor and an intermediate level still resolves to the **authored anchor**.

The block is written in **English** regardless of project locale, consistent with the
SCORING PROCEDURE it sits beside. The indicator rubric remains localised to the project
locale and continues to hard-fail via `AnchorTranslationMissingException` when any of
`{text, anchor_5, anchor_3, anchor_1}` lacks a translation.

The prompt MUST instruct the model that the transcript spans the whole interview, that the
delimited segment is the target competency, and that evidence from outside that segment is
admissible when it genuinely bears on the indicator.

`config/scoring.php` `prompt_version` MUST be bumped to a new **major** version, because
evaluations produced after this change are not comparable with evaluations produced before it.

(Previously: the system prompt carried no severity guidance of any kind, and the transcript
was presented as if it were the entire relevant evidence for the one competency being scored.)

#### Scenario: Standards block present and consistent with the procedure

- GIVEN a competency with indicators and a valid locale
- WHEN the scoring prompt is built
- THEN the system prompt contains an EVALUATION STANDARDS section
- AND it states that 3 is the baseline and that 4 and 5 are rare
- AND it names all three requirements for a high score: specific situation, concrete actions, measurable outcome
- AND it does not instruct the model to prefer an intermediate level over a matching authored anchor

#### Scenario: Standards block is English under a non-English locale

- GIVEN a project locale of `it`
- WHEN the scoring prompt is built
- THEN the EVALUATION STANDARDS section is in English
- AND the indicator rubric is in Italian

#### Scenario: Prompt explains the delimited target segment

- GIVEN a prompt corpus containing a delimited COL segment among other competencies
- WHEN the scoring prompt is built for COL
- THEN the system prompt names the delimiter
- AND instructs the model to weight the delimited segment while admitting corroborating evidence from elsewhere

#### Scenario: Missing anchor translation still hard-fails

- GIVEN an indicator lacking an `anchor_3` translation for the project locale
- WHEN the scoring prompt is built
- THEN `AnchorTranslationMissingException` is thrown
- AND no prompt is produced

#### Scenario: prompt_version reflects the recalibration

- GIVEN the scoring configuration after this change
- WHEN a scoring call records its provenance
- THEN `prompt_version` is a major version greater than the one recorded before this change
