# Delta for Scoring Model

## MODIFIED Requirements

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

(Previously: "Formula Out of Scope" — the requirement stated the formula was NOT decided
and prohibited hard-coding. C9 closes this with R-A assessable-fraction + V-A T=50%
default behind an injectable `ReliabilityStrategy` + `ValidityPredicate`.)

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

## Supersede Note

The "Formula Out of Scope" requirement in the base `openspec/specs/scoring-model/spec.md`
(which prohibited hard-coding the reliability formula) is **SUPERSEDED** by this delta:
C9 closes it with R-A assessable-fraction + V-A T=50% default behind injectable
`ReliabilityStrategy` + `ValidityPredicate`. This supersede note will be promoted and
the base spec updated at archive time. Do NOT edit the promoted base spec now.

---

## Unchanged Requirements (carried from scoring-model/spec.md)

The following requirements from `openspec/specs/scoring-model/spec.md` are UNCHANGED
by this delta and remain in force:

- **Indicator Score Domain** — `{1,3,5}`; no interpolated values.
- **Unassessable Indicator Sentinel** — `-1`; excluded from mean.
- **Competency Score Arithmetic** — mean of assessed indicators; server-computed; result
  may be fractional.
- **Determinism and Traceability** — `temperature=0`; `framework_version`/`model_version`/
  `prompt_version` on every Evaluation; excerpts verbatim substrings; same input → same output.
- **Binding Document Correctness** — source-of-truth docs updated for discrete `{1,3,5}`.
