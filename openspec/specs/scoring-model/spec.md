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

### Requirement: Reliability Formula and Valid-Competency Predicate

Each competency result MUST carry a `reliability` value as a **separate field**, distinct
from `competency.score`. `reliability` MUST be computed as the **assessable fraction**
(R-A): `assessed_count / total_indicator_count`, where assessed indicators are those with
scores in `{1, 3, 5}` and `-1` sentinels are excluded from the numerator. A competency is
VALID iff `reliability >= T`, where T defaults to **0.50 (50%)** and MUST be injectable via
environment config without code change (V-A predicate). Reliability MUST be stored
numerically (`[0..1]`, column type `numeric(5,4)`) and rendered as a percentage integer at
the API/webhook serialization boundary using standard half-up rounding:
`(int) round($reliabilityDbValue * 100, 0, PHP_ROUND_HALF_UP)` (e.g. stored 0.6667 → 67%,
not 66%). The `round()` MUST be applied BEFORE the `(int)` cast — `(int)($value * 100)`
truncates toward zero and is incorrect. Equivalently, the boundary value may be computed
from raw counts as `(int) round($assessed / $total * 100, 0, PHP_ROUND_HALF_UP)`. When the
assessed set is empty, `ReliabilityStrategy` returns `0.0` (never NaN or throws).
`competency.score` MUST be stored as `numeric(5,2)`, rounded to 2 decimal places using
standard half-up: e.g. 3.666… → 3.67.

(Previously: "Reliability Is a Separate Value — Formula Out of Scope" — the requirement
stated the formula was NOT decided and prohibited hard-coding. C9 closes this with R-A
assessable-fraction + V-A T=50% default behind an injectable `ReliabilityStrategy` +
`ValidityPredicate`.)

#### Scenario: Evaluation output carries both score and reliability as separate fields

- GIVEN a completed competency evaluation
- WHEN the result is serialized
- THEN it contains both `competency.score` (arithmetic mean of assessed indicators, rounded to 2dp)
  AND a `reliability` field as separate top-level competency attributes

#### Scenario: SLF reliability computed as assessable fraction — 67%

- GIVEN competency SLF has 3 indicators with scores [5, 3, -1]
- WHEN reliability is computed
- THEN `assessed_count` = 2, `total_indicator_count` = 3, `reliability` = 2/3 ≈ 0.667
- AND the serialized value at the API boundary = "67%" (using `(int) round(2/3 * 100)` = 67)

#### Scenario: COL reliability 100% — all indicators assessed

- GIVEN competency COL has 3 indicators all assessed: [5, 3, 3]
- WHEN reliability is computed
- THEN `reliability` = 3/3 = 1.0 and the serialized boundary value = "100%"

#### Scenario: All indicators -1 → reliability 0.0, score NULL (CC2)

- GIVEN a competency where all N indicators return score -1 (`assessed_count = 0`)
- WHEN reliability and mean are computed
- THEN `reliability` = 0.0 (returned by `ReliabilityStrategy` for empty assessed set)
- AND `competency.score` = NULL (returned by `MeanCalculator` for empty assessed set)
- AND neither operation throws or returns NaN
- AND the competency is INVALID (reliability 0.0 < T)

#### Scenario: Competency valid at default T=50%

- GIVEN a competency with reliability = 0.50 and config T = 0.50
- WHEN the ValidityPredicate evaluates the competency
- THEN the competency is VALID (reliability >= T)

#### Scenario: Competency invalid below T

- GIVEN a competency with reliability = 0.33 and config T = 0.50
- WHEN the ValidityPredicate evaluates the competency
- THEN the competency is INVALID (reliability < T)

#### Scenario: T is overridable via config without code change

- GIVEN `SCORING_RELIABILITY_THRESHOLD=0.75` in environment config
- WHEN the ValidityPredicate evaluates a competency with reliability = 0.67
- THEN the competency is INVALID (0.67 < 0.75)

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
- **Reliability formula and valid-competency threshold** — CLOSED by C9 (R-A assessable-fraction
  + V-A T=50% default, injectable; see Requirement: Reliability Formula and Valid-Competency Predicate above).
- **Missing `bars/SRX.json`** — pre-existing C3 catalog gap; flagged as a
  dependency, not fixed here.
- **Scoring engine, LLM prompt, Evaluation model, schema validation, or tests** —
  all owned by C9.
- **Any code change** — this change is documentation only.

---

## Implementation Note (C9 — Delivered)

C9 (scoring-engine, first-pass PRs 1–3) has implemented validation that rejects any
indicator score outside **{1, 3, 5} ∪ {-1 sentinel}**, the R-A reliability formula, the
V-A validity predicate, and the 90% completion gate. Correctness-critical zones are held to
~95% test coverage. See `openspec/specs/scoring-engine/spec.md` for the full engine spec.
