# Delta for Scoring Engine

## ADDED Requirements

### Requirement: Role- and Assessment-Type-Scoped BARS Indicator Resolution

BARS indicator lookup for scoring MUST be scoped by role AND competency for
`standard` projects, and by `role_id IS NULL` AND competency for `potential`
projects. Exactly the 3 catalogue-anchored indicators for the pinned
role×competency pair (or the pinned role-less competency) MUST reach
`EvaluationParser`. A SINGLE shared lookup implementation MUST serve both the
conversation (C8) and scoring (C9) consumers; a second, independently
maintained query for the same lookup MUST NOT exist. Returned indicators MUST
form a reproducible TOTAL order (`position`, with an explicit secondary
tiebreaker). `PromptBuilder` MUST receive the pinned role resolved from
`project.role_code`; a placeholder/sentinel role id MUST NOT be passed.

#### Scenario: Role-scoped lookup returns exactly the pinned role's 3 indicators (ICO)
- GIVEN a `standard` project pinned to role ICO, competency PRS (15 catalogue rows exist across all 5 roles for PRS)
- WHEN indicators are loaded for scoring PRS
- THEN exactly 3 rows return, all `role_id` = ICO, none from FLL/MLL/BUL/SRX

#### Scenario: Role-scoped lookup returns exactly the pinned role's 3 indicators (FLL)
- GIVEN a `standard` project pinned to role FLL, competency STG
- WHEN indicators are loaded for scoring STG
- THEN exactly 3 rows return, all `role_id` = FLL, none from ICO/MLL/BUL/SRX

#### Scenario: Role-scoped lookup returns exactly the pinned role's 3 indicators (MLL)
- GIVEN a `standard` project pinned to role MLL, competency COL
- WHEN indicators are loaded for scoring COL
- THEN exactly 3 rows return, all `role_id` = MLL, none from ICO/FLL/BUL/SRX

#### Scenario: Role-scoped lookup returns exactly the pinned role's 3 indicators (BUL)
- GIVEN a `standard` project pinned to role BUL, competency COM
- WHEN indicators are loaded for scoring COM
- THEN exactly 3 rows return, all `role_id` = BUL, none from ICO/FLL/MLL/SRX

#### Scenario: Role-scoped lookup returns exactly the pinned role's 3 indicators (SRX)
- GIVEN a `standard` project pinned to role SRX, competency PRS
- WHEN indicators are loaded for scoring PRS
- THEN exactly 3 rows return, all `role_id` = SRX, none from ICO/FLL/MLL/BUL

#### Scenario: Potential project resolves MTG via role_id IS NULL
- GIVEN a `potential` project (`role_code = null`) and competency MTG, anchored with `role_id = null`
- WHEN indicators are loaded for scoring MTG
- THEN exactly 3 rows return via an explicit `whereNull('role_id')` predicate
- AND no row belonging to any of the 5 roles is returned

#### Scenario: Potential project resolves LAT via role_id IS NULL
- GIVEN a `potential` project and competency LAT, anchored with `role_id = null`
- WHEN indicators are loaded for scoring LAT
- THEN exactly 3 rows return via an explicit `whereNull('role_id')` predicate
- AND no row belonging to any of the 5 roles is returned

#### Scenario: A naive role filter does not silently break potential
- GIVEN the shared lookup is invoked for a `potential` project (no pinned role)
- WHEN the lookup predicate is built
- THEN it MUST use `whereNull('role_id')`, never `where('role_id', null)` (which matches no row in Postgres)
- AND MTG/LAT indicators are returned, not an empty set

#### Scenario: Single shared implementation serves both consumers
- GIVEN C8's prompt composer and C9's scoring job both need indicators for the same role×competency pair
- WHEN each requests indicators
- THEN both call the same lookup implementation and receive identical results
- AND no second, independently-maintained query for the same lookup exists in the codebase

#### Scenario: Returned order is a reproducible total order
- GIVEN indicators for one role×competency pair (or one role-less competency)
- WHEN they are loaded twice in separate requests
- THEN both loads return the same 3 rows in the same order, ordered by `position` with an explicit secondary tiebreaker

#### Scenario: PromptBuilder receives the real pinned role, not a sentinel
- GIVEN `ScoreEvaluationJob` scores a competency for a `standard` project pinned to role FLL
- WHEN `PromptBuilder::build()` is invoked
- THEN the `roleId` argument equals FLL's resolved id, never a `0` sentinel

#### Scenario: Reliability denominator is always 3 after the fix
- GIVEN any scored competency for a `standard` or `potential` project post-fix
- WHEN reliability is computed
- THEN the total indicator count is exactly 3, so `reliability_numeric` is one of `{0, 0.333…, 0.667…, 1}` — no other value (e.g. 0.4, 5/15) is producible

#### Scenario: role_no_bars becomes reachable for a genuinely unanchored pair
- GIVEN a role×competency pair with zero anchored indicators (fixture — no real declared pair is in this state)
- WHEN the pipeline scores that pair for the pinned role
- THEN the role-scoped lookup returns zero rows and the competency is marked unscorable `role_no_bars`
- AND it is NOT silently scored against another role's 3 indicators

#### Scenario: A genuine indicator-count mismatch is handled by the existing unscorable path
- GIVEN the LLM returns a `behaviors` array whose length differs from the 3 role-scoped indicators supplied
- WHEN `EvaluationParser::parse()` runs
- THEN `IndicatorCountMismatchException` is thrown and the competency is marked `llm_parse_error`, exactly as already specified (Requirement: Indicator Score Domain Validation)
- AND no new failure surface is introduced

#### Scenario: Architecture guard rejects a competency-only indicator query
- GIVEN a future code change adds a `BarsIndicator::where('competency_id', ...)` query with no accompanying role predicate (neither `role_id` equality nor `whereNull('role_id')`)
- WHEN the architecture test suite runs
- THEN it fails, naming the offending call site

#### Scenario: The architecture guard's own matcher is self-tested
- GIVEN a fixture file containing a deliberately reintroduced competency-only query
- WHEN the arch test's detection matcher runs against that fixture
- THEN it reports a violation
- AND if the matcher is edited to silently stop matching, this self-test fails (not only the production scan silently passes)

---

### Requirement: Purge of Pre-Fix Role-Contaminated Evaluations (Remediation Command)

The system MUST provide an operator-invoked command that removes stored
scoring output computed against the pre-fix, cross-role-contaminated
indicator set. Affected rows are every `Evaluation` (and its cascading
`CompetencyResult`, `IndicatorScore`, and `AiRequest` rows) produced before
the role-scoped indicator fix took effect. The command MUST support a
dry-run mode that computes and reports exact per-table row counts and the
affected-participant count WITHOUT deleting any row; dry-run reporting MUST
exist as a first-class, always-available capability, not an optional flag
that may be skipped. The command MUST NOT delete or mutate `organizations`,
`users`, `projects`, any framework-catalogue table, the `participants` row's
identity/enrolment data, `interview_sessions`, transcript utterances, or
`webhook_deliveries` rows. For each participant whose Evaluation is purged,
the command MUST transition that participant's status to `in_valutazione`
(never leave it `completato` pointing at a deleted Evaluation); the
transcript remains intact, satisfying the binding read gate and enabling a
correct re-score. The command MUST NOT attempt to recall, retract, or
re-notify calling systems for webhook deliveries already made — that
already-delivered data is accepted as-is, unremediated, per explicit product
decision (beta status).

#### Scenario: Dry-run reports counts before any deletion
- GIVEN N pre-fix Evaluations exist across M participants, each with CompetencyResult/IndicatorScore/AiRequest rows
- WHEN the command runs in dry-run mode
- THEN it reports the exact row counts per table and the affected-participant count
- AND zero rows are deleted

#### Scenario: Real purge deletes only the scoped tables for pre-fix evaluations
- GIVEN the dry-run count has been produced
- WHEN the command runs for real
- THEN every pre-fix `Evaluation`, `CompetencyResult`, `IndicatorScore`, and `AiRequest` row is deleted
- AND `organizations`, `users`, `projects`, the framework catalogue, `participants` (enrolment fields other than status), `interview_sessions`, transcript utterances, and `webhook_deliveries` are byte-for-byte unchanged

#### Scenario: Post-fix evaluations are never purged
- GIVEN an Evaluation produced after the role-scoped fix took effect
- WHEN the command runs (dry-run or real)
- THEN that Evaluation is excluded from both the count and the deletion

#### Scenario: Purged participant is not stranded in completato
- GIVEN a participant whose only Evaluation is purged
- WHEN the purge completes
- THEN the participant's status is `in_valutazione`, not `completato`
- AND their transcript remains readable, unaffected by the purge

#### Scenario: Already-delivered webhooks are not recalled or re-sent by the purge
- GIVEN a purged Evaluation had already triggered a delivered `webhook_deliveries` row before the purge
- WHEN the purge runs
- THEN the `webhook_deliveries` row is left untouched
- AND the command performs no outbound call to any calling system
