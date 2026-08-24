# Delta for interview-conversation

> Not listed under the proposal's "Modified Capabilities" section, but required by
> Decision 6 ("Requires it/en copy at minimum"). `OpeningTextComposer` and its `first` /
> `next` / `resume` variants are owned by this domain
> (`api/app/Services/Conversation/OpeningTextComposer.php`, `api/lang/{it,en}/interview.php`),
> not by `interview-session` or `interview-frontend`. Purely additive — no existing
> requirement in this domain changes.

## ADDED Requirements

### Requirement: OpeningTextComposer re-offer variant (Decision 6)

When a competency session is re-offered after a bounded single re-offer
(`interview-session`'s "Bounded single re-offer of an `error` competency", Decisions 4 &
5), `OpeningTextComposer` MUST compose the opening greeting using a NEW `retry` variant,
alongside the existing `first` / `next` / `resume` variants. The `retry` variant MUST
tell the candidate they are re-attempting this competency — it MUST NOT read as a
first-time greeting. Locale keys MUST exist for at least `it` and `en`
(`api/lang/{it,en}/interview.php`, alongside `opening.first` / `.next` / `.resume`).
`opening_text` composed under the `retry` variant MUST still respect the existing
anti-leak rule (no BARS anchor or indicator text) and MUST carry a `prompt_version`.

#### Scenario: A re-offered competency composes the retry variant

- GIVEN a competency session reset to `pending` by the bounded single re-offer
- WHEN `InterviewController` calls `OpeningTextComposer.compose()` for the next `/start`
- THEN the `retry` variant is selected, not `first`/`next`/`resume`

#### Scenario: retry copy exists in it and en

- GIVEN the `retry` variant is selected for a project with `language = 'it'` and,
  separately, `language = 'en'`
- WHEN `opening_text` is composed
- THEN a non-empty, language-correct string is produced for both locales

#### Scenario: retry copy still leaks no BARS content

- GIVEN a competency with BARS indicators, re-offered
- WHEN `opening_text` is composed under the `retry` variant
- THEN it contains no indicator or anchor text — the same guarantee already required of
  the `first`/`next`/`resume` variants

#### Scenario: A never-attempted competency never uses the retry variant

- GIVEN a competency with no prior `error` session
- WHEN its opening is composed
- THEN the variant is `first` (or `next`/`resume` per existing rules) — never `retry`
