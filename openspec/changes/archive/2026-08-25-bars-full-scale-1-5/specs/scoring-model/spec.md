# Delta for Scoring Model

## MODIFIED Requirements

### Requirement: Indicator Score Domain

Each BARS indicator score MUST be exactly one value from the discrete set
**{1, 2, 3, 4, 5, -1}**. The catalog authors only three anchors per indicator
(`anchor_5`, `anchor_3`, `anchor_1`); scores 4 and 2 are **residual levels**
governed by the explicit relational rubric (see Requirement: Relational
Rubric for Residual Score Levels below) — never free LLM discretion. Values
outside this set (0, 6, any other integer, any decimal) are PROHIBITED.
(Previously: domain was {1, 3, 5}; 2 and 4 were PROHIBITED as "interpolated"
values with no anchor rule.)

#### Scenario: Answer matching the "5" anchor scores 5

- GIVEN a competency indicator with reference anchors {5, 3, 1}
- WHEN the LLM evaluates an answer matching the "5" anchor description
- THEN the indicator score is 5

#### Scenario: Answer clearly exceeding anchor-3 but not fully matching anchor-5 scores 4

- GIVEN a competency indicator with reference anchors {5, 3, 1}
- WHEN the LLM evaluates an answer that clearly exceeds the anchor-3
  description but does not fully match the anchor-5 description
- THEN the indicator score is 4

#### Scenario: Answer matching the "3" anchor scores 3

- GIVEN a competency indicator with reference anchors {5, 3, 1}
- WHEN the LLM evaluates an answer matching the "3" anchor description
- THEN the indicator score is 3

#### Scenario: Answer clearly below anchor-3 but not as weak as anchor-1 scores 2

- GIVEN a competency indicator with reference anchors {5, 3, 1}
- WHEN the LLM evaluates an answer clearly below the anchor-3 description but
  not as weak as the anchor-1 description
- THEN the indicator score is 2

#### Scenario: Answer matching the "1" anchor scores 1

- GIVEN a competency indicator with reference anchors {5, 3, 1}
- WHEN the LLM evaluates an answer matching the "1" anchor description
- THEN the indicator score is 1

#### Scenario: A genuine tie resolves to the authored anchor, never the residual level

- GIVEN evidence equally consistent with the anchor-3 description and the
  "exceeds anchor-3" residual rule
- WHEN the LLM scores that indicator
- THEN the indicator score is 3 (the authored anchor), never 4

---

### Requirement: Unassessable Indicator Sentinel

An indicator that cannot be assessed (e.g. not addressed in the transcript)
MUST carry the sentinel value **-1** (or null). The sentinel value MUST be
exempt from the {1, 2, 3, 4, 5} constraint and MUST be excluded from the
competency mean calculation.
(Previously: exempt from {1, 3, 5}.)

#### Scenario: Unassessable indicator carries -1 and is excluded from mean

- GIVEN a competency with three indicators scored [5, 3, -1]
- WHEN the competency score is computed
- THEN only the assessed indicators are averaged: (5 + 3) / 2 = 4.0
- AND the -1 indicator does NOT contribute to the mean

#### Scenario: All indicators assessed — no sentinel present

- GIVEN a competency with three indicators all assessed (e.g. [4, 3, 5])
- WHEN the competency score is computed
- THEN all three indicators contribute to the mean: (4 + 3 + 5) / 3 = 4.0

---

### Requirement: Competency Score Arithmetic

The `competency.score` MUST equal the simple arithmetic mean of the
**assessed** indicator scores (i.e. those with values in {1, 2, 3, 4, 5}).
The result MAY be fractional and MAY now land exactly on a mean-chip boundary
(2.5 or 3.5) — see `admin-backoffice`'s BARS Report Viewer requirement.
(Previously: assessed set was {1, 3, 5}, which could never produce a mean of
exactly 2.5 or 3.5.)

#### Scenario: Three assessed indicators — [5, 4, 5] → 4.67

- GIVEN a competency with assessed indicator scores [5, 4, 5]
- WHEN the competency score is computed
- THEN `competency.score` = (5 + 4 + 5) / 3 ≈ 4.67

#### Scenario: Three assessed indicators — [2, 3, 3] → 2.67

- GIVEN a competency with assessed indicator scores [2, 3, 3]
- WHEN the competency score is computed
- THEN `competency.score` = (2 + 3 + 3) / 3 ≈ 2.67

#### Scenario: Four assessed indicators reach the 3.5 boundary exactly

- GIVEN a competency with assessed indicator scores [2, 3, 4, 5]
- WHEN the competency score is computed
- THEN `competency.score` = (2 + 3 + 4 + 5) / 4 = 3.5

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
scores in `{1, 2, 3, 4, 5}` and `-1` sentinels are excluded from the numerator. A competency is
VALID iff `reliability >= T`, where T defaults to **0.50 (50%)** and MUST be injectable via
environment config without code change (V-A predicate). Reliability MUST be stored
numerically (`[0..1]`, column type `numeric(5,4)`) and rendered as a percentage integer at
the API/webhook serialization boundary using standard half-up rounding.
`competency.score` MUST be stored as `numeric(5,2)`, rounded to 2 decimal places using
standard half-up.
(Previously: assessed indicators were those with scores in `{1, 3, 5}`.)

#### Scenario: Evaluation output carries both score and reliability as separate fields

- GIVEN a completed competency evaluation
- WHEN the result is serialized
- THEN it contains both `competency.score` (arithmetic mean of assessed indicators, rounded to 2dp)
  AND a `reliability` field as separate top-level competency attributes

#### Scenario: SLF reliability computed as assessable fraction — 67%

- GIVEN competency SLF has 3 indicators with scores [4, 2, -1]
- WHEN reliability is computed
- THEN `assessed_count` = 2, `total_indicator_count` = 3, `reliability` = 2/3 ≈ 0.667

#### Scenario: All indicators -1 → reliability 0.0, score NULL (CC2)

- GIVEN a competency where all N indicators return score -1
- WHEN reliability and mean are computed
- THEN `reliability` = 0.0 and `competency.score` = NULL, and the competency is INVALID

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

### Requirement: Binding Document Correctness (This Change's Deliverable)

The following source-of-truth documents MUST be updated so they state the
**{1, 2, 3, 4, 5, -1}** scoring domain and summarize the AD-1 relational
rubric (residual levels 4/2, anchor-primacy tie-break). Any wording asserting
"score is never 4/2" or a discrete-only {1,3,5} invariant is PROHIBITED after
this change.

Files in scope: `CLAUDE.md`, `openspec/ROADMAP.md` (C9 row),
`docs/app_description/02-domain/02-evaluation.md`,
`docs/app_description/03-ux-reference/02-evaluation-output.md`, and the 4×
`AGENTS.md` files.
(Previously: required these documents to state the discrete {1,3,5} domain
and prohibit any 1–5 continuous/interpolated wording.)

#### Scenario: CLAUDE.md states the widened domain and the rubric summary

- GIVEN CLAUDE.md after this change is applied
- WHEN the binding domain constraints section is read
- THEN it states indicator scores are one of {1, 2, 3, 4, 5} plus -1
- AND it summarizes the AD-1 rubric and anchor-primacy tie-break
- AND no text claims a score is "never 4" or "never 2"

#### Scenario: ROADMAP.md C9 row references the widened domain

- GIVEN openspec/ROADMAP.md after this change
- WHEN the C9 row is read
- THEN it references "indicators {1,2,3,4,5}" (not "discrete {1,3,5}")

#### Scenario: evaluation-report-example.json values remain legal, unchanged is acceptable

- GIVEN `evaluation-report-example.json` after this change
- WHEN every per-indicator score field is read
- THEN each value is a member of {1, 2, 3, 4, 5, -1}
- AND leaving the existing {1,3,5,-1} values unchanged (a subset) satisfies this
  scenario — diversifying to include 2/4 is optional documentation value only

## ADDED Requirements

### Requirement: Relational Rubric for Residual Score Levels (AD-1)

`PromptBuilder` MUST inject an explicit, versioned rubric mapping evidence to
each of the five levels, per AD-1: `5` = matches anchor-5; `4` = clearly
exceeds anchor-3 but does not fully match anchor-5; `3` = matches anchor-3;
`2` = clearly below anchor-3 but not as weak as anchor-1; `1` = matches
anchor-1; `-1` = no assessable evidence. This rubric is prompt logic: any
future edit to its wording MUST bump `prompt_version`. The BARS catalog
(`framework_bars_indicators`) is NOT modified by this rubric — no `anchor_4`/
`anchor_2` column is introduced.

#### Scenario: The rubric is injected verbatim into every scoring prompt

- GIVEN the engine composes a scoring prompt for any competency
- WHEN the prompt is inspected
- THEN it contains the five-level rubric text verbatim, keyed to the current
  `prompt_version`

#### Scenario: Editing the rubric wording requires a prompt_version bump

- GIVEN a future change edits the rubric's wording
- WHEN that change is reviewed
- THEN `prompt_version` is bumped; leaving it unchanged is a defect

### Requirement: No Cross-Version Score Comparability

Evaluations already scored under an earlier `prompt_version` (e.g. `1.0.0`,
domain {1,3,5}) MUST keep their original scores untouched. This change MUST
NOT trigger a backfill or re-scoring of any existing `Evaluation`. The product
makes no claim that scores from different `prompt_version` regimes are
comparable.

#### Scenario: A prompt_version 1.0.0 evaluation is never rewritten

- GIVEN an `Evaluation` scored under `prompt_version 1.0.0`
- WHEN `prompt_version 2.0.0` ships
- THEN that Evaluation's stored indicator scores and competency means are
  unchanged
- AND no job re-scores it
