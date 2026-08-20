# Delta for Interview Frontend

## ADDED Requirements

### Requirement: Error State Copy Never Promises An Unconditional Resume

`interview.error.body` MUST NOT promise that retrying will always succeed. It MUST
state that the interview can be retried now, and that if the problem persists an
operator must re-open the assessment. This is because the underlying failure is
genuinely retryable in some cases (`ClientError`/`Throttle`, which never mark the
participant) and genuinely terminal in others (`Upstream`, which writes `errore` and
requires operator recovery); the copy MUST be true in both cases and MUST NOT
contradict the terminal-403 screen the candidate may hit next.

The existing structural i18n guard
(`frontend/tests/unit/i18n-interview-keys.spec.ts`, the pattern already applied to
`session_expired`) MUST be extended to the `error` state: `interview.error.body` MUST
be added to `REQUIRED_KEYS`, and a locale-specific assertion MUST fail if the body
matches an unconditional-resume pattern — `it: /riprender|dal punto in cui/i`,
`en: /resume|where you left off/i`.

#### Scenario: interview.error.body is required to exist

- GIVEN the i18n structural guard runs
- WHEN `interview.error.body` is missing from either locale
- THEN the test fails, naming the missing key

#### Scenario: An unconditional resume promise fails the guard

- GIVEN a locale's `interview.error.body` matches that locale's resume-promise
  pattern
- WHEN the structural guard runs
- THEN the test fails

#### Scenario: The corrected copy passes the guard

- GIVEN `interview.error.body` states the interview can be retried now and, if the
  problem persists, must be re-opened by an operator
- WHEN the structural guard runs
- THEN it passes in both `it` and `en`
