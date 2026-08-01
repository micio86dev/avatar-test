# Scoring Model Specification

## Purpose

Defines the binding BARS scoring invariants that all downstream slices
(C9 scoring-engine, C10 webhooks, C11 dashboards) MUST conform to.
This change corrects source-of-truth documents only; no engine code is
written here.

---

## Requirements

### Requirement: Indicator Score Domain

Each BARS indicator score MUST be exactly one value from the discrete set
**{1, 3, 5}**. The LLM MUST select the single closest anchor and assign
that anchor's value. Interpolated values (2, 4, or any non-anchor integer
or decimal) are PROHIBITED as indicator scores.

#### Scenario: Answer closest to the "5" anchor scores 5

- GIVEN a competency indicator with reference anchors {5, 3, 1}
- WHEN the LLM evaluates a strong answer that is closest to the "5" anchor
- THEN the indicator score is 5
- AND the score is NOT 4 or any interpolated value

#### Scenario: Answer closest to the "3" anchor scores 3

- GIVEN a competency indicator with reference anchors {5, 3, 1}
- WHEN the LLM evaluates a moderate answer that is closest to the "3" anchor
- THEN the indicator score is 3

#### Scenario: Answer equidistant between "3" and "5" anchors resolves to one anchor, never 4

- GIVEN a competency indicator with reference anchors {5, 3, 1}
- WHEN the LLM evaluates an answer that lies between the "3" and "5" anchors
- THEN the indicator score is either 3 or 5 (whichever is judged closest)
- AND the score is NEVER 4

#### Scenario: Answer closest to the "1" anchor scores 1

- GIVEN a competency indicator with reference anchors {5, 3, 1}
- WHEN the LLM evaluates a weak answer clearly closest to the "1" anchor
- THEN the indicator score is 1

---

### Requirement: Unassessable Indicator Sentinel

An indicator that cannot be assessed (e.g. not addressed in the transcript)
MUST carry the sentinel value **-1** (or null). The sentinel value MUST be
exempt from the {1, 3, 5} constraint and MUST be excluded from the
competency mean calculation.

#### Scenario: Unassessable indicator carries -1 and is excluded from mean

- GIVEN a competency with three indicators scored [5, 3, -1]
- WHEN the competency score is computed
- THEN only the assessed indicators are averaged: (5 + 3) / 2 = 4.0
- AND the -1 indicator does NOT contribute to the mean

#### Scenario: All indicators assessed — no sentinel present

- GIVEN a competency with three indicators all assessed (e.g. [5, 3, 5])
- WHEN the competency score is computed
- THEN all three indicators contribute to the mean: (5 + 3 + 5) / 3 ≈ 4.33

---

### Requirement: Competency Score Arithmetic

The `competency.score` MUST equal the simple arithmetic mean of the
**assessed** indicator scores (i.e. those with values in {1, 3, 5}).
The result MAY be fractional.

#### Scenario: Three assessed indicators — [5, 3, 5] → 4.33

- GIVEN a competency with assessed indicator scores [5, 3, 5]
- WHEN the competency score is computed
- THEN `competency.score` = (5 + 3 + 5) / 3 ≈ 4.33

#### Scenario: Three assessed indicators — [5, 3, 3] → 3.67

- GIVEN a competency with assessed indicator scores [5, 3, 3]
- WHEN the competency score is computed
- THEN `competency.score` = (5 + 3 + 3) / 3 ≈ 3.67

#### Scenario: Three assessed indicators — [1, 1, 3] → 1.67

- GIVEN a competency with assessed indicator scores [1, 1, 3]
- WHEN the competency score is computed
- THEN `competency.score` = (1 + 1 + 3) / 3 ≈ 1.67

#### Scenario: Two of three indicators assessed — partial mean

- GIVEN a competency with indicator scores [5, 3, -1] (one unassessable)
- WHEN the competency score is computed
- THEN `competency.score` = (5 + 3) / 2 = 4.0
- AND the denominator is 2 (assessed count), not 3 (total count)

---

### Requirement: Reliability Is a Separate Value — Formula Out of Scope

Each competency result MUST carry a `reliability` value as a **separate
field**, distinct from `competency.score`. The formula for `reliability`
and the "valid competency" threshold that feeds the 90% completion gate
are **NOT decided by this change** (open product decision #1). C9 MUST NOT
hard-code a reliability formula until that decision is closed.

**Non-goal (explicit):** This spec does NOT define the reliability formula,
the "valid competency" threshold, or the 90% completion gate trigger.

#### Scenario: Evaluation output carries both score and reliability as separate fields

- GIVEN a completed competency evaluation
- WHEN the result is serialized
- THEN it contains both `competency.score` (arithmetic mean of assessed indicators)
  AND a `reliability` field as separate top-level competency attributes

---

### Requirement: Determinism and Traceability

Every evaluation MUST be deterministic and traceable. The LLM invocation
MUST use `temperature = 0`. Each Evaluation record MUST store
`framework_version`, `model_version`, and `prompt_version`. Answer excerpts
cited in the evaluation MUST be verbatim substrings of the transcript
(substring-validated); invented or paraphrased excerpts are PROHIBITED.

#### Scenario: Evaluation metadata is recorded on every Evaluation record

- GIVEN an evaluation job completes
- WHEN the Evaluation record is persisted
- THEN it contains `framework_version`, `model_version`, and `prompt_version`
- AND each of those fields is non-null and non-empty

#### Scenario: Excerpt is a verbatim substring of the transcript

- GIVEN an excerpt field in an evaluation result
- WHEN the transcript text is searched for that excerpt
- THEN the excerpt is found as an exact substring of the transcript
- AND the excerpt was NOT paraphrased or summarized

#### Scenario: Re-running the same prompt+transcript at temperature=0 yields identical scores

- GIVEN the same transcript, prompt version, and model version
- WHEN the LLM is invoked twice with `temperature = 0`
- THEN both invocations produce identical indicator scores and excerpts

---

### Requirement: Binding Document Correctness (This Change's Deliverable)

The following source-of-truth documents MUST be updated so they state
the discrete {1, 3, 5} scoring invariant. Any wording implying a 1–5
continuous scale or interpolation is PROHIBITED after this change.

Files in scope:
- `CLAUDE.md` (lines 137–144)
- `openspec/ROADMAP.md` (C9 row)
- `docs/app_description/02-domain/02-valutazione.md`
- `docs/app_description/03-ux-reference/02-output-valutazione.md`
- `docs/app_description/03-ux-reference/esempio-report-valutazione.json`

#### Scenario: CLAUDE.md states discrete {1,3,5} with no interpolation language

- GIVEN CLAUDE.md after this change is applied
- WHEN lines 137–144 are read
- THEN the text states indicator scores are exactly one of {1, 3, 5} (closest anchor)
- AND the example uses only discrete values (e.g. "COL 3.67 from 5,3,3", not "4,3,4")
- AND the -1 / null unassessable sentinel rule is documented
- AND no text says "interpolation allowed" or implies a continuous 1–5 range

#### Scenario: ROADMAP.md C9 row references discrete {1,3,5}

- GIVEN openspec/ROADMAP.md after this change
- WHEN the C9 row is read
- THEN it references "discrete {1,3,5}" (not "indicators 1–5")

#### Scenario: esempio-report-valutazione.json contains only legal indicator scores

- GIVEN docs/app_description/03-ux-reference/esempio-report-valutazione.json after regeneration
- WHEN every per-indicator score field is read
- THEN each value is a member of {1, 3, 5} ∪ {-1}
- AND the SLF competency retains its -1 sentinel on the unassessable indicator
- AND each competency.score equals the arithmetic mean of that competency's assessed indicators

---

## Non-Goals (Explicit)

The following are OUT OF SCOPE for this change and MUST NOT be addressed here:

- **Framework catalog files** (`competencies.json`, `roles.json`, `bars/*.json`) —
  anchors are already {5, 3, 1}; no changes required.
- **Reliability formula** and the "valid competency" threshold feeding the
  90% completion gate — open product decision #1, not settled here.
- **Missing `bars/SRX.json`** — pre-existing C3 catalog gap; flagged as a
  dependency, not fixed here.
- **Scoring engine, LLM prompt, Evaluation model, schema validation, or tests** —
  all owned by C9.
- **Any code change** — this change is documentation only.

---

## Forward Note for C9 (Not In Scope Now)

When C9 implements the scoring engine, validation MUST reject any indicator
score outside **{1, 3, 5} ∪ {-1 sentinel}**. This correctness-critical zone
MUST be held to ~95% test coverage per `openspec/config.yaml`.
